#!/usr/bin/env bash
# Idempotently sets up Audiobookshelf + Authelia for SSO tests: test CA and
# certificate, OIDC signing key, password hashes, the containers, a TOTP
# secret for the second-factor user, then ABS's root user, library and
# OpenID settings. Reads ./.env (copy .env.example and fill in).
set -euo pipefail
cd "$(dirname "$0")"
# env.sh from the repo, or copied next to this script when deployed alone.
if [ -f env.sh ]; then . ./env.sh; else . ../../env.sh; fi
load_env ./.env
IMAGE=docker.io/authelia/authelia:4.39.28
URL=http://localhost:${ABS_PORT:-13382}
IDP=https://$IDP_HOST:${IDP_PORT:-9002}
D=data/authelia
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }
mkdir -p "$D/certs" "$D/keys" data/abs/config data/abs/metadata

# Authelia serves only HTTPS: a test CA (trusted by ABS and the tests) and
# a certificate for IDP_HOST.
# (Key usages and key ids included: strict verifiers such as Python 3.13's
# refuse certificates without them.)
changed=
if [ ! -f "$D/certs/ca.crt" ]; then
  echo "Creating test CA and certificate for $IDP_HOST"
  if [[ $IDP_HOST =~ ^[0-9.]+$ ]]; then san="IP:$IDP_HOST"; else san="DNS:$IDP_HOST"; fi
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=ABS Wear test CA" \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' \
    -keyout "$D/certs/ca.key" -out "$D/certs/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$IDP_HOST" \
    -keyout "$D/certs/authelia.key" -out "$D/certs/authelia.csr" 2>/dev/null
  openssl x509 -req -in "$D/certs/authelia.csr" -CA "$D/certs/ca.crt" -CAkey "$D/certs/ca.key" \
    -CAcreateserial -days 825 -out "$D/certs/authelia.crt" -extfile <(printf '%s\n' \
      "subjectAltName=$san" 'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' \
      'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid') 2>/dev/null
  changed=1
fi
[ -f "$D/keys/oidc.pem" ] || openssl genrsa -out "$D/keys/oidc.pem" 2048 2>/dev/null

# Password hashes, redone only when a password changes (they're salted).
# The password goes in through the environment, not the command line.
hash() { PW=$2 docker run --rm -e PW "$IMAGE" sh -c 'authelia crypto hash generate "$0" --password "$PW"' "$1" | sed -n 's/^Digest: //p'; }
sum=$(printf '%s\n' "$ABS_OIDC_CLIENT_SECRET" "$ABS_TEST_USER" "$ABS_TEST_PASSWORD" "$ABS_TOTP_USER" "$ABS_TOTP_PASSWORD" | sha256sum | cut -d' ' -f1)
if [ "$(cat "$D/secrets.sha256" 2>/dev/null)" != "$sum" ]; then
  echo "Hashing the client secret and user passwords"
  hash pbkdf2 "$ABS_OIDC_CLIENT_SECRET" > "$D/client_secret.hash"
  user() { printf '  %s:\n    displayname: "%s"\n    email: %s@abs-wear.test\n    password: "%s"\n' "$1" "$2" "$1" "$(hash argon2 "$3")"; }
  {
    echo 'users:'
    user "$ABS_TEST_USER" "ABS Wear" "$ABS_TEST_PASSWORD"
    user "$ABS_TOTP_USER" "ABS Wear TOTP" "$ABS_TOTP_PASSWORD"
  } > "$D/users_database.yml"
  echo "$sum" > "$D/secrets.sha256"
  changed=1
fi

docker compose up -d
# Both read the certificates (and Authelia the client secret's hash) only
# when they start.
[ -z "$changed" ] || docker compose restart

echo "Waiting for Authelia at $IDP ..."
ready=
for _ in $(seq 60); do curl -fs --cacert "$D/certs/ca.crt" "$IDP/api/health" >/dev/null && { ready=1; break; }; sleep 2; done
[ -n "$ready" ] || { echo "Authelia did not come up (docker compose logs authelia)" >&2; exit 1; }
docker compose exec -T authelia authelia storage user totp generate "$ABS_TOTP_USER" \
  --secret "$ABS_TOTP_SECRET" --issuer abs-wear.test --force >/dev/null
echo "TOTP set for $ABS_TOTP_USER"

echo "Waiting for $URL ..."
ready=
for _ in $(seq 60); do curl -fs "$URL/status" >/dev/null && { ready=1; break; }; sleep 2; done
[ -n "$ready" ] || { echo "ABS at $URL did not come up" >&2; exit 1; }
if [ "$(curl -fs "$URL/status" | j 'd["isInit"]')" = "False" ]; then
  echo "Creating root user"
  curl -fs -X POST "$URL/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")}" >/dev/null
fi
ROOT=$(curl -fs -X POST "$URL/login" -H 'Content-Type: application/json' \
  -d "$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")" | j 'd["user"]["token"]')
auth=(-H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json')

LIB=$(curl -fs "$URL/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Books"), "")')
if [ -z "$LIB" ]; then
  echo "Creating library"
  LIB=$(curl -fs -X POST "$URL/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
  curl -fs -X POST "$URL/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
fi

# OpenID in ABS next to password login. Users get an ABS account on their
# first SSO login.
wk=$(curl -fs --cacert "$D/certs/ca.crt" "$IDP/.well-known/openid-configuration")
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
  "authOpenIDTokenSigningAlgorithm": "RS256",
  "authOpenIDButtonText": "Login with Authelia",
  "authOpenIDAutoLaunch": False,
  "authOpenIDAutoRegister": True,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." URLs.
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$ABS_OIDC_CLIENT_SECRET")
curl -fs -X PATCH "$URL/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
echo "Setup complete: ABS $ABS_PUBLIC_URL uses Authelia at $IDP (library $LIB)"
