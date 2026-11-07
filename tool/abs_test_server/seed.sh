#!/usr/bin/env bash
# Idempotently initialises the test server: root user, test user, library,
# scan, and in-progress listening so books show under "Continue Listening".
# Reads credentials from ./.env (copy .env.example and fill in).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
URL=${ABS_URL:-http://localhost:13378}
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
# Build JSON safely (passwords may contain quotes or backslashes).
creds() { python3 -c 'import sys,json;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$1" "$2"; }

echo "Waiting for $URL ..."
for _ in $(seq 60); do curl -fs "$URL/status" >/dev/null && break; sleep 2; done

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
for _ in $(seq 30); do
  n=$(curl -fs "$URL/api/libraries/$LIB/items?limit=50" "${auth[@]}" | j 'd["total"]')
  [ "$n" -ge 3 ] && break; sleep 2
done
echo "Library has $n items"

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
echo "Seed complete. Library id: $LIB"
