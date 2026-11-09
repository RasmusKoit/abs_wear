#!/usr/bin/env bash
# Generates a small "demo" library into ./data/demo for README and store
# screenshots: public-domain titles with real-looking chapters, the covers in
# ./demo_covers, and silent audio so the files stay small. Needs ffmpeg.
# Kept apart from ./data/audiobooks, which the E2E tests rely on.
set -euo pipefail
cd "$(dirname "$0")"
OUT=data/demo
COVERS=demo_covers
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# silence <seconds> <out> [extra ffmpeg args...]
silence() {
  local s=$1 o=$2; shift 2
  ffmpeg -loglevel error -y -f lavfi -i "anullsrc=r=22050:cl=mono" -t "$s" "$@" "$o"
}

# book <author> <title> <cover> <chapter-minutes> <chapter titles...>
# One M4B with embedded chapters.
book() {
  local author=$1 title=$2 cover=$3 mins=$4; shift 4
  local d="$OUT/books/$author/$title"
  [ -f "$d/$title.m4b" ] && { echo "exists: $title"; return; }
  mkdir -p "$d"
  local len=$((mins * 60)) n=$# total=$(( $# * mins * 60 ))
  {
    echo ";FFMETADATA1"
    echo "title=$title"; echo "artist=$author"; echo "album=$title"; echo "genre=Audiobook"
    local i=0
    for ch in "$@"; do
      echo "[CHAPTER]"; echo "TIMEBASE=1/1000"
      echo "START=$((i * len * 1000))"; echo "END=$(((i + 1) * len * 1000))"
      echo "title=$ch"
      i=$((i + 1))
    done
  } > "$TMP/meta.txt"
  silence "$total" "$TMP/book.m4a" -c:a aac -b:a 16k
  ffmpeg -loglevel error -y -i "$TMP/book.m4a" -i "$TMP/meta.txt" \
    -map_metadata 1 -map_chapters 1 -c copy "$d/$title.m4b"
  cp "$COVERS/$cover" "$d/cover.jpg"
  echo "book: $title ($n chapters)"
}

book "Jane Austen" "Pride and Prejudice" pride_and_prejudice.jpg 18 \
  "Chapter 1" "Chapter 2" "Chapter 3" "Chapter 4" "Chapter 5" "Chapter 6" "Chapter 7" "Chapter 8"
book "Mary Shelley" "Frankenstein" frankenstein.jpg 20 \
  "Letter 1" "Letter 2" "Letter 3" "Letter 4" "Chapter 1" "Chapter 2" "Chapter 3" "Chapter 4"
book "H. G. Wells" "The Time Machine" the_time_machine.jpg 16 \
  "The Inventor" "The Machine" "The Time Traveller Returns" "Time Travelling" "In the Golden Age" "The Sunset of Mankind"
book "Arthur Conan Doyle" "The Hound of the Baskervilles" the_hound_of_the_baskervilles.jpg 22 \
  "Mr. Sherlock Holmes" "The Curse of the Baskervilles" "The Problem" "Sir Henry Baskerville" "Three Broken Threads" "Baskerville Hall"

# A multi-file book (one chapter per file), like many MP3 rips.
d="$OUT/books/Herman Melville/Moby-Dick"
if [ ! -f "$d/03 - The Spouter-Inn.mp3" ]; then
  mkdir -p "$d"
  i=1
  for part in "Loomings" "The Carpet-Bag" "The Spouter-Inn"; do
    silence 900 "$d/0${i} - ${part}.mp3" -c:a libmp3lame -b:a 8k \
      -metadata title="$part" -metadata artist="Herman Melville" \
      -metadata album="Moby-Dick" -metadata track="${i}/3"
    i=$((i + 1))
  done
  cp "$COVERS/moby_dick.jpg" "$d/cover.jpg"
  echo "book: Moby-Dick (3 files)"
fi

# A podcast with three episodes.
d="$OUT/podcasts/Classic Tales Hour"
if [ ! -f "$d/03 The Signal-Man.mp3" ]; then
  mkdir -p "$d"
  i=1
  for ep in "The Tell-Tale Heart" "The Monkey's Paw" "The Signal-Man"; do
    silence $((1200 + i * 300)) "$d/0${i} ${ep}.mp3" -c:a libmp3lame -b:a 8k \
      -metadata title="$ep" -metadata artist="Classic Tales Hour" \
      -metadata album="Classic Tales Hour" -metadata track="$i"
    i=$((i + 1))
  done
  cp "$COVERS/classic_tales_hour.jpg" "$d/cover.jpg"
  echo "podcast: Classic Tales Hour (3 episodes)"
fi
echo "Demo media in $OUT"
