#!/bin/bash
# Runs a debug build/Inni.app on a collection copy; the app draws one of its windows into a PNG and quits.
# Works without screen access, but card web views come out blank. Build first with `./scripts/bundle.sh debug`.
# Usage: scripts/mac-shot.sh <out.png> <collection.anki2> [InniOpen value] [window title] [seconds]
set -euo pipefail
OUT="$1"
COL="$2"
OPEN="${3:-}"
WINDOW="${4:-}"
WAIT="${5:-3}"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Inni.app/Contents/MacOS/Inni"
pkill -f "$APP" 2>/dev/null || true
rm -f "$OUT"
ARGS=(-collectionPath "$COL" -syncOnOpen NO -InniSnapshot "$OUT" -InniSnapshotDelay "$WAIT")
[ -n "$OPEN" ] && ARGS+=(-InniOpen "$OPEN")
[ -n "$WINDOW" ] && ARGS+=(-InniSnapshotWindow "$WINDOW")
"$APP" "${ARGS[@]}" >/dev/null 2>&1 || true
# The app writes collectionPath back; keep the installed app on its own collection.
defaults delete dev.inni.app collectionPath 2>/dev/null || true
[ -f "$OUT" ] && echo "$OUT"
