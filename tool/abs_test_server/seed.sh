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
# Put every book "in progress" at 25% so it lands on the Continue Listening shelf.
curl -fs "$URL/api/libraries/$LIB/items?limit=50" "${uauth[@]}" \
  | j '"\n".join(i["id"]+" "+str(i["media"]["duration"]) for i in d["results"])' \
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
echo "Seed complete. Library id: $LIB  Podcast library id: $PLIB"
