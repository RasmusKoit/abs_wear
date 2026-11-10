#!/usr/bin/env bash
# Idempotently initialises the test server: root user, test user, library,
# scan, and in-progress listening so books show under "Continue Listening".
# Reads credentials from ./.env (copy .env.example and fill in).
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh
load_env ./.env
URL=${ABS_URL:-http://localhost:13378}
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
# Build JSON safely (passwords may contain quotes or backslashes).
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }

echo "Waiting for $URL ..."
ready=
for _ in $(seq 60); do curl -fs "$URL/status" >/dev/null && { ready=1; break; }; sleep 2; done
[ -n "$ready" ] || { echo "Server at $URL did not come up" >&2; exit 1; }

if [ "$(curl -fs "$URL/status" | j 'd["isInit"]')" = "False" ]; then
  echo "Creating root user"
  curl -fs -X POST "$URL/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":$(creds "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")}" >/dev/null
fi

login() { curl -fs -X POST "$URL/login" -H 'Content-Type: application/json' \
  -d "$(creds "$1" "$2")" | j 'd["user"]["token"]'; }
ROOT=$(login "$ABS_ROOT_USER" "$ABS_ROOT_PASSWORD")
auth=(-H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json')

LIB=$(curl -fs "$URL/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Books"), "")')
if [ -z "$LIB" ]; then
  echo "Creating library"
  LIB=$(curl -fs -X POST "$URL/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
fi

echo "Scanning library $LIB"
curl -fs -X POST "$URL/api/libraries/$LIB/scan" "${auth[@]}" >/dev/null || true
n=0
for _ in $(seq 30); do
  n=$(curl -fs "$URL/api/libraries/$LIB/items?limit=50" "${auth[@]}" | j 'd["total"]')
  [ "$n" -ge 3 ] && break; sleep 2
done
echo "Library has $n items"
[ "$n" -ge 3 ] || { echo "Scan found fewer than 3 books; run generate_media.sh first" >&2; exit 1; }

if ! curl -fs "$URL/api/users" "${auth[@]}" | j '[u["username"] for u in d["users"]]' | grep -q "'$ABS_TEST_USER'"; then
  echo "Creating test user"
  body=$(creds "$ABS_TEST_USER" "$ABS_TEST_PASSWORD" | python3 -c 'import sys,json;d=json.load(sys.stdin);d.update(type="user",isActive=True,permissions=dict(download=True,update=False,delete=False,upload=False,accessAllLibraries=True,accessAllTags=True));print(json.dumps(d))')
  curl -fs -X POST "$URL/api/users" "${auth[@]}" -d "$body" >/dev/null
fi

USER_TOKEN=$(login "$ABS_TEST_USER" "$ABS_TEST_PASSWORD")
uauth=(-H "Authorization: Bearer $USER_TOKEN" -H 'Content-Type: application/json')
# Put the test books (not the generated Bulk ones) "in progress" at 25% so
# they land on the Continue Listening shelf.
curl -fs "$URL/api/libraries/$LIB/items?limit=5000&minified=1" "${uauth[@]}" \
  | j '"\n".join(i["id"]+" "+str(i["media"]["duration"]) for i in d["results"] if not i["relPath"].startswith("Bulk"))' \
  | while read -r id dur; do
      t=$(python3 -c "print(round($dur*0.25))")
      curl -fs -X PATCH "$URL/api/me/progress/$id" "${uauth[@]}" \
        -d "{\"duration\":$dur,\"currentTime\":$t,\"progress\":0.25,\"isFinished\":false}" >/dev/null
      echo "progress set: $id @ ${t}s / ${dur}s"
    done
# Podcast library (generate_media.sh puts episodes in data/podcasts).
PLIB=$(curl -fs "$URL/api/libraries" "${auth[@]}" | j 'next((l["id"] for l in d["libraries"] if l["name"]=="Test Podcasts"), "")')
if [ -z "$PLIB" ]; then
  echo "Creating podcast library"
  PLIB=$(curl -fs -X POST "$URL/api/libraries" "${auth[@]}" \
    -d '{"name":"Test Podcasts","folders":[{"fullPath":"/podcasts"}],"mediaType":"podcast","settings":{"autoScanCronExpression":null}}' | j 'd["id"]')
fi
curl -fs -X POST "$URL/api/libraries/$PLIB/scan" "${auth[@]}" >/dev/null || true
for _ in $(seq 30); do
  p=$(curl -fs "$URL/api/libraries/$PLIB/items?limit=5" "${uauth[@]}" | j 'd["total"]')
  [ "$p" -ge 1 ] && break; sleep 2
done
[ "$p" -ge 1 ] || { echo "Podcast scan found nothing" >&2; exit 1; }
# First episode in progress, so it shows under Continue Listening.
first_episode='(lambda e: e["id"] + " " + str(e["audioFile"]["duration"]))(sorted(d["media"]["episodes"], key=lambda e: e.get("index") or 0)[0])'
curl -fs "$URL/api/libraries/$PLIB/items?limit=5" "${uauth[@]}" \
  | j '" ".join(i["id"] for i in d["results"])' | tr ' ' '\n' \
  | while read -r pid; do
      [ -n "$pid" ] || continue
      read -r eid edur < <(curl -fs "$URL/api/items/$pid?expanded=1" "${uauth[@]}" | j "$first_episode")
      curl -fs -X PATCH "$URL/api/me/progress/$pid/$eid" "${uauth[@]}" \
        -d "{\"duration\":$edur,\"currentTime\":5,\"progress\":$(python3 -c "print(5/$edur)"),\"isFinished\":false}" >/dev/null
      echo "episode progress set: $pid/$eid"
    done
# Demo libraries for screenshots (generate_demo.sh), added after the test
# ones so the app's default library stays "Test Books" for E2E.
if [ -d data/demo/books ]; then
  # demo_library <name> <path> <mediaType>: prints the library id.
  demo_library() {
    local id
    id=$(curl -fs "$URL/api/libraries" "${auth[@]}" | j "next((l['id'] for l in d['libraries'] if l['name']=='$1'), '')")
    if [ -z "$id" ]; then
      id=$(curl -fs -X POST "$URL/api/libraries" "${auth[@]}" \
        -d "{\"name\":\"$1\",\"folders\":[{\"fullPath\":\"$2\"}],\"mediaType\":\"$3\",\"settings\":{\"autoScanCronExpression\":null}}" | j 'd["id"]')
    fi
    curl -fs -X POST "$URL/api/libraries/$id/scan" "${auth[@]}" >/dev/null || true
    echo "$id"
  }
  DLIB=$(demo_library "Audiobooks" /demo/books book)
  DPLIB=$(demo_library "Podcasts" /demo/podcasts podcast)
  for _ in $(seq 30); do
    n=$(curl -fs "$URL/api/libraries/$DLIB/items?limit=50" "${uauth[@]}" | j 'd["total"]')
    [ "$n" -ge 5 ] && break; sleep 2
  done
  # Three books in progress (different amounts) for Continue Listening.
  curl -fs "$URL/api/libraries/$DLIB/items?limit=50&minified=1" "${uauth[@]}" \
    | j '"\n".join(i["id"]+" "+str(i["media"]["duration"])+" "+i["media"]["metadata"]["title"].replace(" ","_") for i in d["results"])' \
    | while read -r id dur title; do
        case "$title" in
          Frankenstein) p=0.42 ;; Pride_and_Prejudice) p=0.18 ;; The_Time_Machine) p=0.67 ;; *) continue ;;
        esac
        t=$(python3 -c "print(round($dur*$p))")
        curl -fs -X PATCH "$URL/api/me/progress/$id" "${uauth[@]}" \
          -d "{\"duration\":$dur,\"currentTime\":$t,\"progress\":$p,\"isFinished\":false}" >/dev/null
        echo "demo progress: $title @ $p"
      done
  echo "Demo libraries: $DLIB (books), $DPLIB (podcasts)"
fi
# SSO: Authentik (docker-compose.yml) as the OpenID Connect provider. The
# blueprint creates the "abs" application and the test user; here we set the
# user's password and turn on OpenID in ABS next to password login.
if [ -n "${AUTHENTIK_BOOTSTRAP_TOKEN:-}" ]; then
  AK=${AUTHENTIK_URL:?set AUTHENTIK_URL in .env (as seen from the watch)}
  akauth=(-H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" -H 'Content-Type: application/json')
  echo "Waiting for Authentik at $AK ..."
  pk=
  for _ in $(seq 90); do
    pk=$(curl -fs "$AK/api/v3/core/users/?username=$ABS_TEST_USER" "${akauth[@]}" 2>/dev/null | j 'd["results"][0]["pk"] if d["results"] else ""' || true)
    [ -n "$pk" ] && break; sleep 2
  done
  [ -n "$pk" ] || { echo "Authentik user $ABS_TEST_USER not found (blueprint not applied?)" >&2; exit 1; }
  pw=$(python3 -c 'import sys,json;print(json.dumps({"password":sys.argv[1]}))' "$ABS_TEST_PASSWORD")
  curl -fs -X POST "$AK/api/v3/core/users/$pk/set_password/" "${akauth[@]}" -d "$pw" >/dev/null
  issuer="$AK/application/o/abs/"
  wk=$(curl -fs "${issuer}.well-known/openid-configuration")
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
  "authOpenIDButtonText": "Login with Authentik",
  "authOpenIDAutoLaunch": False,
  "authOpenIDAutoRegister": False,
  "authOpenIDMatchExistingBy": "username",
  "authOpenIDMobileRedirectURIs": ["abswear://oauth"],
  # Unset, ABS builds ".../undefined/auth/openid/..." (the web UI always sends it).
  "authOpenIDSubfolderForRedirectURLs": "",
}))' "$ABS_OIDC_CLIENT_SECRET")
  curl -fs -X PATCH "$URL/api/auth-settings" "${auth[@]}" -d "$settings" >/dev/null
  echo "SSO: ABS uses Authentik at $issuer"
fi
echo "Seed complete. Library id: $LIB  Podcast library id: $PLIB"
