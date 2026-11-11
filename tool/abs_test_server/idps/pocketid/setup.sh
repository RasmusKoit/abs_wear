#!/usr/bin/env bash
# Idempotently sets up the Pocket ID test stack (docker-compose.yml): ABS
# root user and library, the Pocket ID user and "abs" OIDC client, a software
# passkey for the user (passkey.py) and ABS's OpenID settings.
# Reads ./.env (copy .env.example and fill it in).
set -euo pipefail
cd "$(dirname "$0")"
# env.sh from tool/abs_test_server (copied next to this file when deployed).
if [ -f ./env.sh ]; then . ./env.sh; else . ../../env.sh; fi
load_env ./.env
URL=${ABS_URL:?set in .env}
PID=${POCKET_ID_URL:?set in .env}
# Reached from this machine (the URLs above are as the watch sees them).
ABS_LOCAL=${ABS_LOCAL_URL:-http://localhost:${ABS_PORT:-13387}}
PID_LOCAL=${POCKET_ID_LOCAL_URL:-http://localhost:${POCKET_ID_PORT:-9007}}
export POCKET_ID_LOCAL_URL=$PID_LOCAL
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }
wait_for() {
  for _ in $(seq 60); do curl -fs "$1" >/dev/null && return 0; sleep 2; done
  echo "$1 did not come up" >&2; exit 1
}

echo "Waiting for ABS and Pocket ID ..."
wait_for "$ABS_LOCAL/status"
wait_for "$PID_LOCAL/healthz"

# --- ABS: root user and a book library ---
if [ "$(curl -fs "$ABS_LOCAL/status" | j 'd["isInit"]')" = "False" ]; then
  echo "Creating ABS root user"
  curl -fs -X POST "$ABS_LOCAL/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")}" >/dev/null
fi
ROOT=$(curl -fs -X POST "$ABS_LOCAL/login" -H 'Content-Type: application/json' \
  -d "$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")" | j 'd["user"]["token"]')
auth=(-H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json')
LIB=$(curl -fs "$ABS_LOCAL/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Books"), "")')
if [ -z "$LIB" ]; then
  echo "Creating library"
  LIB=$(curl -fs -X POST "$ABS_LOCAL/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
  curl -fs -X POST "$ABS_LOCAL/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
fi

# --- Pocket ID: user, OIDC client and its secret (admin API key) ---
api=(-H "X-API-Key: $POCKET_ID_API_KEY" -H 'Content-Type: application/json')
uid=$(curl -fs "$PID_LOCAL/api/users?search=$ABS_TEST_USER" "${api[@]}" | j "next((u['id'] for u in d['data'] if u['username']=='$ABS_TEST_USER'), '')")
if [ -z "$uid" ]; then
  echo "Creating Pocket ID user $ABS_TEST_USER"
  curl -fs -X POST "$PID_LOCAL/api/users" "${api[@]}" -d "$(python3 -c '
import sys, json
u = sys.argv[1]
print(json.dumps({"username": u, "email": u + "@abs-wear.test", "emailVerified": True,
  "firstName": "Wear", "lastName": "Tester", "displayName": "Wear Tester", "isAdmin": False}))' "$ABS_TEST_USER")" >/dev/null
fi
client=$(python3 -c '
import sys, json
abs = sys.argv[1]
print(json.dumps({"id": "abs", "name": "Audiobookshelf", "isPublic": False,
  "pkceEnabled": False, "skipConsent": False,
  "callbackURLs": [abs + "/auth/openid/callback", abs + "/auth/openid/mobile-redirect"]}))' "$URL")
if ! curl -fs "$PID_LOCAL/api/oidc/clients/abs" "${api[@]}" >/dev/null 2>&1; then
  echo "Creating OIDC client abs"
  curl -fs -X POST "$PID_LOCAL/api/oidc/clients" "${api[@]}" -d "$client" >/dev/null
else
  # Again on every run, so a changed ABS address gets its callbacks too.
  curl -fs -X PUT "$PID_LOCAL/api/oidc/clients/abs" "${api[@]}" -d "$client" >/dev/null
fi
# Our secret replaces the generated one. Pocket ID only shows a secret's
# first characters, so the hash of the one we installed is kept in data/
# and a changed secret is always installed (and the old ones removed).
mkdir -p data
want=$(printf '%s' "$ABS_OIDC_CLIENT_SECRET" | sha256sum | cut -d' ' -f1)
if [ "$(cat data/client_secret.sha256 2>/dev/null)" != "$want" ]; then
  echo "Setting the client secret"
  old=$(curl -fs "$PID_LOCAL/api/oidc/clients/abs/secrets" "${api[@]}" | j "' '.join(s['id'] for s in d)")
  curl -fs -X POST "$PID_LOCAL/api/oidc/clients/abs/secrets" "${api[@]}" \
    -d "{\"secret\":\"$ABS_OIDC_CLIENT_SECRET\"}" >/dev/null
  for id in $old; do
    curl -fs -X DELETE "$PID_LOCAL/api/oidc/clients/abs/secrets/$id" "${api[@]}" >/dev/null
  done
  echo "$want" > data/client_secret.sha256
fi

# --- A passkey for the user, to approve sign-ins from "another device" ---
[ -f data/passkey.json ] || python3 ./passkey.py enroll

# --- ABS: OpenID against Pocket ID, next to password login ---
wk=$(curl -fs "$PID_LOCAL/.well-known/openid-configuration")
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
  "authOpenIDClientID": "abs",
  "authOpenIDClientSecret": sys.argv[1],
  "authOpenIDTokenSigningAlgorithm": wk["id_token_signing_alg_values_supported"][0],
  "authOpenIDButtonText": "Login with Pocket ID",
  "authOpenIDAutoLaunch": False,
  # The user exists only in Pocket ID: ABS creates it on the first login.
  "authOpenIDAutoRegister": True,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." (the web UI always sends it).
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$ABS_OIDC_CLIENT_SECRET")
curl -fs -X PATCH "$ABS_LOCAL/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
echo "Setup complete. ABS $URL uses Pocket ID at $PID; library $LIB"
