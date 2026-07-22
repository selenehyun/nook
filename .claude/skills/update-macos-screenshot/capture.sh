#!/usr/bin/env bash
# Capture the running Nook macOS window — with its drop shadow and rounded
# corners on a transparent background — to a PNG. Defaults to the README hero
# image path. Run from the repo root (or pass an absolute output path).
#
# Usage: .claude/skills/update-macos-screenshot/capture.sh [output.png]
set -euo pipefail

OUT="${1:-docs/screenshots/main.png}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! pgrep -xq Nook; then
  echo "Nook isn't running. Open it (and set up the window/article you want) first." >&2
  exit 1
fi

osascript -e 'tell application "Nook" to activate' >/dev/null 2>&1
sleep 1

WID="$(swift "$DIR/winid.swift" 2>/dev/null || true)"
if [ -z "$WID" ]; then
  echo "Couldn't find Nook's window id (Screen Recording permission may be needed)." >&2
  exit 1
fi

# -l<id> captures just that window and keeps the shadow (omit -o, which drops it).
screencapture -x -l"$WID" -t png "$OUT"
echo "Captured Nook window $WID -> $OUT"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$OUT" 2>/dev/null | tail -3 || true
