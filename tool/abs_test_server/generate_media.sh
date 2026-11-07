#!/usr/bin/env bash
# Generates small synthetic audiobooks into ./data/audiobooks.
# Needs ffmpeg. Tones are used instead of speech so files stay tiny.
set -euo pipefail
cd "$(dirname "$0")"
OUT=data/audiobooks
mkdir -p "$OUT"

tone() { # <freq> <seconds> <out> [extra ffmpeg args...]
  local f=$1 s=$2 o=$3; shift 3
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=${f}:duration=${s}" -ac 1 -ar 22050 "$@" "$o"
}

# 1) Single-file M4B with 3 embedded chapters (60s each).
d="$OUT/Test Author A/Single File Book"
mkdir -p "$d"
cat > /tmp/chapters.txt <<META
;FFMETADATA1
title=Single File Book
artist=Test Author A
album=Single File Book
genre=Audiobook
[CHAPTER]
TIMEBASE=1/1000
START=0
END=60000
title=Chapter One
[CHAPTER]
TIMEBASE=1/1000
START=60000
END=120000
title=Chapter Two
[CHAPTER]
TIMEBASE=1/1000
START=120000
END=180000
title=Chapter Three
META
tone 440 180 /tmp/single.m4a -c:a aac -b:a 32k
ffmpeg -loglevel error -y -i /tmp/single.m4a -i /tmp/chapters.txt -map_metadata 1 -map_chapters 1 -c copy "$d/Single File Book.m4b"

# 2) Multi-file MP3 book: 3 files x 45s (ABS makes one chapter per file).
d="$OUT/Test Author B/Multi File Book"
mkdir -p "$d"
i=1
for f in 330 550 770; do
  tone "$f" 45 "$d/Part 0${i}.mp3" -c:a libmp3lame -b:a 32k \
    -metadata title="Part ${i}" -metadata artist="Test Author B" \
    -metadata album="Multi File Book" -metadata track="${i}/3"
  i=$((i+1))
done

# 3) A long-ish single file without chapters (10 min) for seek/sync tests.
d="$OUT/Test Author C/No Chapters Book"
mkdir -p "$d"
tone 262 600 "$d/No Chapters Book.mp3" -c:a libmp3lame -b:a 24k \
  -metadata title="No Chapters Book" -metadata artist="Test Author C" -metadata album="No Chapters Book"

find "$OUT" -type f | sort
