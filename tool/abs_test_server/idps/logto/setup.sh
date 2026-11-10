#!/usr/bin/env bash
# Idempotently sets up the Logto test stack (docker-compose.yml): an ABS
# root user and book library, Logto's "abs" app, sign-in experience and
# test users, and ABS's OpenID settings pointing at Logto.
# Reads ./.env (copy .env.example and fill in). Run after docker compose up.
set -euo pipefail
cd "$(dirname "$0")"
load_env() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in '' | \#*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && export "$key=$value"
  done <"$1"
}
[ -f .env ] || { echo "Missing .env (copy .env.example)" >&2; exit 1; }
load_env ./.env
# The stack is reached locally; ABS and Logto know their public URLs.
ABS=http://localhost:13384
LOGTO=http://localhost:9004
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
# json key value ...: a JSON object of string values (safe for any value).
json() { python3 -c 'import sys,json;a=sys.argv[1:];print(json.dumps(dict(zip(a[::2],a[1::2]))))' "$@"; }
wait_for() {
  for _ in $(seq 90); do curl -fs "$1" >/dev/null && return; sleep 2; done
  echo "$1 did not come up" >&2; exit 1
}

# --- Audiobookshelf: root user and library ---------------------------------
wait_for "$ABS/status"
if [ "$(curl -fs "$ABS/status" | j 'd["isInit"]')" = "False" ]; then
  echo "ABS: creating root user"
  curl -fs -X POST "$ABS/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":$(json username "$ABS_ROOT_USER" password "$ABS_ROOT_PASSWORD")}" >/dev/null
fi
ROOT=$(curl -fs -X POST "$ABS/login" -H 'Content-Type: application/json' \
  -d "$(json username "$ABS_ROOT_USER" password "$ABS_ROOT_PASSWORD")" | j 'd["user"]["token"]')
auth=(-H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json')
LIB=$(curl -fs "$ABS/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Books"), "")')
if [ -z "$LIB" ]; then
  echo "ABS: creating library"
  LIB=$(curl -fs -X POST "$ABS/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
  curl -fs -X POST "$ABS/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
fi

# --- Logto: Management API access ------------------------------------------
# A fresh Logto has no API client and no admin user, so a machine-to-machine
# app with the seeded "Logto Management API access" role goes straight into
# its database.
wait_for "$LOGTO/oidc/.well-known/openid-configuration"
docker compose exec -T logto-db psql -q -v ON_ERROR_STOP=1 -U postgres \
  -d logto -v secret="$LOGTO_M2M_SECRET" >/dev/null <<'SQL'
insert into applications (tenant_id, id, name, secret, type,
  oidc_client_metadata)
values ('default', 'abs-wear-setup', 'ABS Wear setup', :'secret',
  'MachineToMachine', '{"redirectUris":[],"postLogoutRedirectUris":[]}')
on conflict (id) do update set secret = excluded.secret;
insert into application_secrets (tenant_id, application_id, name, value)
values ('default', 'abs-wear-setup', 'setup', :'secret')
on conflict (tenant_id, application_id, name)
do update set value = excluded.value;
insert into applications_roles (tenant_id, id, application_id, role_id)
select 'default', 'abs-wear-setup-mapi', 'abs-wear-setup', id from roles
where tenant_id = 'default' and name = 'Logto Management API access'
on conflict do nothing;
SQL
TOKEN=$(curl -fs -u "abs-wear-setup:$LOGTO_M2M_SECRET" \
  -d grant_type=client_credentials -d scope=all \
  -d resource=https://default.logto.app/api "$LOGTO/oidc/token" | j 'd["access_token"]')
api() { # api METHOD PATH [JSON]
  curl -fsS -X "$1" "$LOGTO/api$2" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' ${3:+-d "$3"}
}

# --- Logto: sign-in experience, the "abs" app, test users -------------------
# Username + password sign-in, and TOTP for the users who set it up.
api PATCH /sign-in-exp '{
  "signIn": {"methods": [{"identifier": "username", "password": true,
    "verificationCode": false, "isPasswordPrimary": true}]},
  "mfa": {"factors": ["Totp"], "policy": "UserControlled"}
}' >/dev/null
uris=$(python3 -c 'import sys,json;u=sys.argv[1];print(json.dumps({"redirectUris":[u+"/auth/openid/callback",u+"/auth/openid/mobile-redirect"],"postLogoutRedirectUris":[u+"/login"]}))' "$ABS_URL")
# app NAME THIRD_PARTY: creates the OIDC app (or updates its redirect URIs)
# and prints its id. Logto asks for consent only for third-party apps.
app() {
  local id
  id=$(api GET '/applications?page_size=100' | j "next((a['id'] for a in d if a['name']=='$1'), '')")
  if [ -z "$id" ]; then
    id=$(api POST /applications "{\"name\":\"$1\",\"type\":\"Traditional\",\"isThirdParty\":$2,\"oidcClientMetadata\":$uris}" | j 'd["id"]')
  else
    api PATCH "/applications/$id" "{\"oidcClientMetadata\":$uris}" >/dev/null
  fi
  echo "$id"
}
# ABS uses "abs"; LOGTO_CONSENT=1 switches it to the third-party app.
if [ "${LOGTO_CONSENT:-0}" = 1 ]; then
  APP=$(app abs-third-party true)
  # Third-party apps get only the user scopes they're granted.
  api POST "/applications/$APP/user-consent-scopes" \
    '{"userScopes": ["profile", "email"]}' >/dev/null
else
  APP=$(app abs false)
fi
APP_SECRET=$(api GET "/applications/$APP/secrets" | j 'd[0]["value"]')

# user USERNAME PASSWORD: creates the Logto user or resets its password, and
# prints its id.
user() {
  local id
  id=$(api GET "/users?search.username=$1&mode.username=exact" | j 'd[0]["id"] if d else ""')
  if [ -z "$id" ]; then
    id=$(api POST /users "$(json username "$1" password "$2")" | j 'd["id"]')
  else
    api PATCH "/users/$id/password" "$(json password "$2")" >/dev/null
  fi
  echo "$id"
}
user "$ABS_TEST_USER" "$ABS_TEST_PASSWORD" >/dev/null
# Logto suggests adding MFA until the user skips it once; forget the skip so
# every run sees the suggestion (the watch skips it).
docker compose exec -T logto-db psql -q -v ON_ERROR_STOP=1 -U postgres \
  -d logto -v name="$ABS_TEST_USER" >/dev/null <<'SQL'
update users set logto_config = logto_config - 'mfa'
where tenant_id = 'default' and username = :'name';
SQL
MFA_ID=$(user "$ABS_MFA_USER" "$ABS_MFA_PASSWORD")
if [ "$(api GET "/users/$MFA_ID/mfa-verifications" | j '"Totp" in [v["type"] for v in d]')" = "False" ]; then
  api POST "/users/$MFA_ID/mfa-verifications" \
    "$(json type Totp secret "$ABS_MFA_TOTP_SECRET")" >/dev/null
fi
echo "Logto: users $ABS_TEST_USER and $ABS_MFA_USER (TOTP)"

# --- ABS: OpenID Connect with Logto ----------------------------------------
# From the public URL: Logto names its endpoints after the requested host.
wk=$(curl -fs "$LOGTO_URL/oidc/.well-known/openid-configuration")
settings=$(printf '%s' "$wk" | python3 -c '
import sys, json
wk = json.load(sys.stdin)
print(json.dumps({
  "authActiveAuthMethods": ["local", "openid"],
  "authOpenIDIssuerURL": wk["issuer"],
  "authOpenIDAuthorizationURL": wk["authorization_endpoint"],
  "authOpenIDTokenURL": wk["token_endpoint"],
  "authOpenIDUserInfoURL": wk["userinfo_endpoint"],
  "authOpenIDJwksURL": wk["jwks_uri"],
  "authOpenIDLogoutURL": wk.get("end_session_endpoint"),
  "authOpenIDClientID": sys.argv[1],
  "authOpenIDClientSecret": sys.argv[2],
  "authOpenIDTokenSigningAlgorithm":
    wk["id_token_signing_alg_values_supported"][0],
  "authOpenIDButtonText": "Login with Logto",
  "authOpenIDAutoLaunch": False,
  # Logto users get an ABS account on their first login.
  "authOpenIDAutoRegister": True,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." (the web UI sends it).
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$APP" "$APP_SECRET")
client() { j '(d["authOpenIDClientID"], d["authOpenIDAuthorizationURL"])'; }
before=$(curl -fs "$ABS/api/auth-settings" "${auth[@]}" | client)
curl -fs -X PATCH "$ABS/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
# ABS keeps its OpenID client until it restarts.
if [ "$before" != "(None, None)" ] &&
  [ "$before" != "$(curl -fs "$ABS/api/auth-settings" "${auth[@]}" | client)" ]; then
  echo "ABS: restarting for the new OpenID client"
  docker compose restart audiobookshelf >/dev/null
  wait_for "$ABS/status"
fi
echo "Setup complete: ABS $ABS_URL uses Logto at $(printf '%s' "$wk" | j 'd["issuer"]')"
