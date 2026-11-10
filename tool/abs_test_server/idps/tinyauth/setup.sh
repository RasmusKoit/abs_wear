#!/usr/bin/env bash
# Idempotently sets up the tinyauth SSO test stack: a throwaway test CA and
# certificate (tinyauth's OpenID provider insists on https), tinyauth's users
# file (a password-only user and one with TOTP), the containers, the ABS root
# user and book library, and ABS pointed at tinyauth. Reads ./.env.
#   ./setup.sh                 everything
#   ./setup.sh reset-consent   forget the remembered consents (tinyauth's
#                              database), so the next login asks again
set -euo pipefail
cd "$(dirname "$0")"
for f in ./env.sh ../../env.sh; do [ -f "$f" ] && { . "$f"; break; }; done
load_env ./.env
ABS=http://localhost:${ABS_PORT:-13383}
TA=$TINYAUTH_URL
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }

wait_for() {
  for _ in $(seq 60); do
    curl -fs --cacert data/tls/ca.crt "$1" >/dev/null && return 0; sleep 2
  done
  echo "$1 did not come up" >&2; return 1
}

if [ "${1:-}" = reset-consent ]; then
  docker compose stop tinyauth
  rm -f data/tinyauth/tinyauth.db data/tinyauth/tinyauth.db-*
  docker compose up -d tinyauth
  wait_for "$TA/.well-known/openid-configuration"
  echo "tinyauth consents cleared"
  exit 0
fi

mkdir -p data/config data/metadata data/tinyauth data/tls
# Test CA (clients trust data/tls/ca.crt) and tinyauth's certificate.
host=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlsplit(sys.argv[1]).hostname)' "$TINYAUTH_URL")
tls_changed=
if ! openssl x509 -in data/tls/server.crt -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' ||
  ! openssl verify -x509_strict -CAfile data/tls/ca.crt data/tls/server.crt >/dev/null 2>&1; then
  echo "Making test certificate for $host"
  (
    cd data/tls
    # Strict verifiers (Python 3.13) want key usages and key identifiers.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj '/CN=ABS Wear test CA' -keyout ca.key -out ca.crt \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" \
      -keyout server.key -out server.csr 2>/dev/null
    printf '%s\n' "subjectAltName=DNS:$host" 'basicConstraints=CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' \
      'extendedKeyUsage=serverAuth' 'subjectKeyIdentifier=hash' \
      'authorityKeyIdentifier=keyid,issuer' > ext.cnf
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
      -days 825 -extfile ext.cnf -out server.crt 2>/dev/null
    chmod 644 server.key # read by Caddy's user in the container
    rm -f server.csr ext.cnf
  )
  tls_changed=1
fi

# The users file, rebuilt only when a user, password or secret changes (the
# bcrypt hashes differ every run, so a fingerprint decides).
want=$(printf '%s\n' "$ABS_TEST_USER:$ABS_TEST_PASSWORD" \
  "$TOTP_USER:$TOTP_PASSWORD:$TOTP_SECRET" | sha256sum | cut -d' ' -f1)
users_changed=
if [ "$(cat data/tinyauth/users.sha 2>/dev/null)" != "$want" ]; then
  echo "Writing tinyauth users"
  img=$(docker compose config --images | grep tinyauth)
  # tinyauth's own CLI makes the bcrypt hash; the password goes in on stdin.
  hash() {
    printf '%s\n' "$1" | docker run --rm -i --entrypoint sh "$img" -c \
      'read -r pw; tinyauth user create --username x --password "$pw"' \
      | grep -o '\$2[aby]\$[0-9][0-9]\$[./A-Za-z0-9]\{53\}' | head -1
  }
  {
    echo "$ABS_TEST_USER:$(hash "$ABS_TEST_PASSWORD")"
    echo "$TOTP_USER:$(hash "$TOTP_PASSWORD"):$TOTP_SECRET"
  } > data/tinyauth/users.txt.new
  mv data/tinyauth/users.txt.new data/tinyauth/users.txt
  echo "$want" > data/tinyauth/users.sha
  users_changed=1
fi

docker compose up -d
# tinyauth reads the users file, Caddy the certificate and ABS the CA only at
# start.
if [ -n "$users_changed" ]; then docker compose restart tinyauth; fi
if [ -n "${tls_changed:-}" ]; then docker compose restart tls audiobookshelf; fi
wait_for "$ABS/status"
wait_for "$TA/.well-known/openid-configuration"

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
  echo "Creating library"
  LIB=$(curl -fs -X POST "$ABS/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
  curl -fs -X POST "$ABS/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
fi

# ABS on tinyauth. Both test users get an ABS account on their first SSO
# login (auto-register, matched by username).
settings=$(curl -fs --cacert data/tls/ca.crt "$TA/.well-known/openid-configuration" | python3 -c '
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
  "authOpenIDButtonText": "Login with tinyauth",
  "authOpenIDAutoLaunch": False,
  "authOpenIDAutoRegister": True,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." URLs.
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$ABS_OIDC_CLIENT_SECRET")
curl -fs -X PATCH "$ABS/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
echo "Setup complete. ABS $ABS_URL (library $LIB) uses tinyauth at $TINYAUTH_URL"
