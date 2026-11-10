#!/usr/bin/env bash
# Idempotently sets up the html-form SSO test stack: ABS root user and book
# library, Keycloak realm "abs" with the "abs" client and the test users,
# Gitea's user and OAuth2 app if Gitea runs, and ABS pointed at one of
# them. Reads ./.env.
#   ./setup.sh [keycloak|gitea]  everything; ABS uses the given provider
#                                (default: ABS_IDP, else keycloak)
#   ./setup.sh reset-consent   forget the test users' Keycloak consents, so
#                              the next login shows the consent screen again
set -euo pipefail
cd "$(dirname "$0")"
# load_env from the main test server's env.sh (in the repo, or copied here).
for f in ../../env.sh ./env.sh; do [ -f "$f" ] && { . "$f"; break; }; done
load_env ./.env
ABS=http://localhost:${ABS_PORT:-13381}
KC=http://localhost:${KEYCLOAK_PORT:-9001}
export ABS KC

# Keycloak admin API calls, in Python for the JSON.
keycloak() {
  python3 - "$@" <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request

kc, env = os.environ["KC"], os.environ
mode = sys.argv[1] if len(sys.argv) > 1 else "setup"

def call(method, path, body=None, form=None, token=None):
    data, headers = None, {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(kc + path, data, headers, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read()
            return r.status, json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return 404, None
        sys.exit(f"{method} {path}: {e.code} {e.read()[:300]!r}")

_, t = call("POST", "/realms/master/protocol/openid-connect/token", form={
    "grant_type": "password", "client_id": "admin-cli",
    "username": "admin", "password": env["KEYCLOAK_ADMIN_PASSWORD"]})
token = t["access_token"]
api = lambda m, p, b=None: call(m, "/admin/realms" + p, b, token=token)

def user_id(name):
    _, found = api("GET", "/abs/users?exact=true&username=" + name)
    return found[0]["id"] if found else None

if mode == "reset-consent":
    for name in (env["ABS_TEST_USER"], env["ABS_OTP_USER"]):
        uid = user_id(name)
        if uid:
            api("DELETE", f"/abs/users/{uid}/consents/abs")
            api("POST", f"/abs/users/{uid}/logout")
    print("Keycloak consents reset")
    sys.exit()

if api("GET", "/abs")[0] == 404:
    print("Creating Keycloak realm abs")
    api("POST", "", {"realm": "abs", "enabled": True})

public = [env["ABS_URL"], f"http://localhost:{env.get('ABS_PORT', '13381')}"]
client = {
    "clientId": "abs", "name": "Audiobookshelf", "enabled": True,
    "protocol": "openid-connect", "publicClient": False,
    "clientAuthenticatorType": "client-secret",
    "secret": env["ABS_OIDC_CLIENT_SECRET"],
    "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
    # Shows Keycloak's grant screen on the first login of each user.
    "consentRequired": env.get("KEYCLOAK_CONSENT", "true") == "true",
    "redirectUris": [f"{u}/auth/openid/{p}" for u in public
                     for p in ("callback", "mobile-redirect")],
}
_, found = api("GET", "/abs/clients?clientId=abs")
if found:
    api("PUT", f"/abs/clients/{found[0]['id']}", {**found[0], **client})
else:
    print("Creating Keycloak client abs")
    api("POST", "/abs/clients", client)

def ensure_user(name, password, otp=None):
    profile = {"username": name, "enabled": True, "email": f"{name}@abs-wear.test",
               "emailVerified": True, "firstName": "Wear", "lastName": "Test",
               "requiredActions": []}
    uid = user_id(name)
    if uid and otp:
        _, creds = api("GET", f"/abs/users/{uid}/credentials")
        if not any(c["type"] == "otp" for c in creds):
            api("DELETE", f"/abs/users/{uid}")  # recreated with its OTP
            uid = None
    if uid:
        api("PUT", f"/abs/users/{uid}", profile)
        api("PUT", f"/abs/users/{uid}/reset-password",
            {"type": "password", "value": password, "temporary": False})
        return
    creds = [{"type": "password", "value": password, "temporary": False}]
    if otp:
        # Keycloak's own TOTP credential format: the secret's bytes are the
        # key (defaults: SHA1, 6 digits, 30 s).
        creds.append({
            "type": "otp", "userLabel": "watch",
            "secretData": json.dumps({"value": otp}),
            "credentialData": json.dumps({
                "subType": "totp", "digits": 6, "counter": 0,
                "period": 30, "algorithm": "HmacSHA1"}),
        })
    print(f"Creating Keycloak user {name}")
    api("POST", "/abs/users", {**profile, "credentials": creds})

ensure_user(env["ABS_TEST_USER"], env["ABS_TEST_PASSWORD"])
ensure_user(env["ABS_OTP_USER"], env["ABS_OTP_PASSWORD"], env["ABS_OTP_SECRET"])
print("Keycloak realm abs ready")
PY
}

if [ "${1:-}" = reset-consent ]; then keycloak reset-consent; exit; fi

j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }
wait_for() {
  for _ in $(seq 90); do curl -fs "$1" >/dev/null && return; sleep 2; done
  echo "$1 did not come up" >&2; exit 1
}

echo "Waiting for ABS and Keycloak ..."
wait_for "$ABS/status"
wait_for "$KC/realms/master"

if [ "$(curl -fs "$ABS/status" | j 'd["isInit"]')" = "False" ]; then
  echo "Creating ABS root user"
  curl -fs -X POST "$ABS/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")}" >/dev/null
fi
ROOT=$(curl -fs -X POST "$ABS/login" -H 'Content-Type: application/json' \
  -d "$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")" | j 'd["user"]["token"]')
auth=(-H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json')
LIB=$(curl -fs "$ABS/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Books"), "")')
if [ -z "$LIB" ]; then
  echo "Creating ABS library"
  LIB=$(curl -fs -X POST "$ABS/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
  curl -fs -X POST "$ABS/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
fi

keycloak setup
CLIENT_ID=abs
CLIENT_SECRET=$ABS_OIDC_CLIENT_SECRET

# Gitea (docker compose --profile gitea up -d): a user and an OAuth2 app.
# Gitea makes up the app's client id and secret; they are kept in
# data/gitea-oauth.env.
GITEA=http://localhost:${GITEA_PORT:-9011}
GITEA_USER=${ABS_GITEA_USER:-wear-gitea}
if curl -fs "$GITEA/api/healthz" >/dev/null 2>&1; then
  gitea() { docker compose exec -T -u git gitea gitea "$@"; }
  users=$(gitea admin user list)
  ensure_gitea_user() { # name password [--admin]
    if printf '%s\n' "$users" | awk '{print $2}' | grep -qx "$1"; then
      gitea admin user change-password --username "$1" --password "$2" \
        --must-change-password=false >/dev/null
    else
      echo "Creating Gitea user $1"
      gitea admin user create --username "$1" --password "$2" \
        --email "$1@abs-wear.test" --must-change-password=false "${@:3}" >/dev/null
    fi
  }
  ensure_gitea_user abs-admin "$GITEA_ADMIN_PASSWORD" --admin
  # Not "wear": ABS links each account to one provider's user.
  ensure_gitea_user "$GITEA_USER" "$ABS_TEST_PASSWORD"
  GITEA_OTP_USER=${ABS_GITEA_OTP_USER:-wear-gitea-otp}
  ensure_gitea_user "$GITEA_OTP_USER" "$ABS_OTP_PASSWORD"
  # Gitea has no API for TOTP: enrol through its settings page, as a
  # browser would. The (base32) secret goes to data/gitea-otp.env.
  if [ ! -f data/gitea-otp.env ]; then
    echo "Enrolling TOTP for Gitea user $GITEA_OTP_USER"
    (umask 077; GITEA=$GITEA python3 - "$GITEA_OTP_USER" "$ABS_OTP_PASSWORD" > data/gitea-otp.env <<'PY'
import base64, hashlib, hmac, http.cookiejar, os, re, struct, sys, time
import urllib.parse, urllib.request
g = os.environ["GITEA"]
web = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
post = lambda path, form: web.open(g + path, urllib.parse.urlencode(form).encode())
post("/user/login", {"user_name": sys.argv[1], "password": sys.argv[2]})
page = web.open(g + "/user/settings/security/two_factor/enroll").read().decode()
m = re.search(r"enter the secret: ([A-Z2-7]+)", page)
if not m:
    sys.exit("No TOTP secret on Gitea's enrol page (already enrolled?)")
secret = m.group(1)
key = base64.b32decode(secret + "=" * (-len(secret) % 8))
h = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
o = h[-1] & 15
code = (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10**6
post("/user/settings/security/two_factor/enroll", {"passcode": "%06d" % code})
print("GITEA_OTP_SECRET=" + secret)
PY
    ) || { rm -f data/gitea-otp.env; exit 1; }
  fi
  gauth=(-u "abs-admin:$GITEA_ADMIN_PASSWORD" -H 'Content-Type: application/json')
  redirects=$(python3 -c 'import sys,json;print(json.dumps([u+"/auth/openid/"+p for u in sys.argv[1:] for p in ("callback","mobile-redirect")]))' "$ABS_URL" "$ABS")
  app=$(curl -fs "$GITEA/api/v1/user/applications/oauth2" "${gauth[@]}" | j 'next((str(a["id"]) for a in d if a["name"]=="Audiobookshelf"), "")')
  body="{\"name\":\"Audiobookshelf\",\"confidential_client\":true,\"redirect_uris\":$redirects}"
  # Made anew on every run: that forgets the users' grants (so the consent
  # screen shows again), and Gitea hands out a new secret either way.
  if [ -n "$app" ]; then
    curl -fs -X DELETE "$GITEA/api/v1/user/applications/oauth2/$app" "${gauth[@]}"
  fi
  echo "Creating Gitea OAuth2 app"
  (umask 077; curl -fs -X POST "$GITEA/api/v1/user/applications/oauth2" "${gauth[@]}" -d "$body" \
    | j '"GITEA_CLIENT_ID="+d["client_id"]+"\nGITEA_CLIENT_SECRET="+d["client_secret"]' > data/gitea-oauth.env)
  load_env data/gitea-oauth.env
  echo "Gitea ready"
fi

# ABS: OpenID next to password login. SSO users get an ABS account on their
# first login (auto-register), matched by username.
IDP=${1:-${ABS_IDP:-keycloak}}
case "$IDP" in
  keycloak) issuer="$KEYCLOAK_URL/realms/abs" ;;
  gitea)
    issuer="${GITEA_URL%/}"
    CLIENT_ID=${GITEA_CLIENT_ID:?start Gitea first: docker compose --profile gitea up -d}
    CLIENT_SECRET=$GITEA_CLIENT_SECRET
    ;;
  *) echo "Unknown provider $IDP (keycloak or gitea)" >&2; exit 1 ;;
esac
# Fetched as ABS sees it (the LAN address, like the watch).
wk=$(curl -fs "$issuer/.well-known/openid-configuration")
settings=$(printf '%s' "$wk" | python3 -c '
import sys, json
wk = json.load(sys.stdin)
algs = wk.get("id_token_signing_alg_values_supported") or ["RS256"]
print(json.dumps({
  "authActiveAuthMethods": ["local", "openid"],
  "authOpenIDIssuerURL": wk["issuer"],
  "authOpenIDAuthorizationURL": wk["authorization_endpoint"],
  "authOpenIDTokenURL": wk["token_endpoint"],
  "authOpenIDUserInfoURL": wk["userinfo_endpoint"],
  "authOpenIDJwksURL": wk["jwks_uri"],
  "authOpenIDLogoutURL": wk.get("end_session_endpoint"),
  "authOpenIDClientID": sys.argv[3],
  "authOpenIDClientSecret": sys.argv[1],
  "authOpenIDTokenSigningAlgorithm": "RS256" if "RS256" in algs else algs[0],
  "authOpenIDButtonText": "Login with " + sys.argv[2],
  "authOpenIDAutoLaunch": False,
  "authOpenIDAutoRegister": True,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." URLs.
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$CLIENT_SECRET" "$IDP" "$CLIENT_ID")
client='[d.get(k) for k in ("authOpenIDIssuerURL", "authOpenIDClientID", "authOpenIDClientSecret")]'
old=$(curl -fs "$ABS/api/auth-settings" "${auth[@]}" | j "$client")
curl -fs -X PATCH "$ABS/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
if [[ $old != "[None, None, None]" ]] &&
  [ "$old" != "$(curl -fs "$ABS/api/auth-settings" "${auth[@]}" | j "$client")" ]; then
  # ABS 2.37 keeps the old provider and client until it restarts.
  echo "Restarting ABS for the new provider"
  docker compose restart audiobookshelf >/dev/null 2>&1
  wait_for "$ABS/status"
fi
echo "SSO: ABS at $ABS_URL uses $issuer. Library id: $LIB"
