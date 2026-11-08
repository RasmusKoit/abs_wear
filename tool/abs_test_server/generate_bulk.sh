#!/usr/bin/env bash
# Generates N tiny books (default 1000) under ./data/audiobooks/Bulk for
# testing how the app handles large libraries (paging, memory, scrolling).
# One 2-second mp3 is encoded once and copied, so this is fast.
# Usage: ./generate_bulk.sh [count]   then rescan the library.
set -euo pipefail
cd "$(dirname "$0")"
N=${1:-1000}
OUT=data/audiobooks/Bulk
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=330:duration=2" \
  -ac 1 -ar 22050 -b:a 32k "$TMP/tone.mp3"
for i in $(seq -w 1 "$N"); do
  d="$OUT/Bulk Author $(( 10#$i % 50 ))/Bulk Book $i"
  [ -f "$d/book.mp3" ] && continue
  mkdir -p "$d"
  cp "$TMP/tone.mp3" "$d/book.mp3"
done
echo "Generated $N books in $OUT"
