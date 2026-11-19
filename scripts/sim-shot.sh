#!/bin/bash
# Relaunches the simulator build on a screen and saves a screenshot.
# Usage: scripts/sim-shot.sh <out.png> [InniOpen value, e.g. "study:Goethe A1 Sorted"] [seconds]
set -euo pipefail
OUT="$1"
OPEN="${2:-}"
WAIT="${3:-3}"
xcrun simctl terminate booted dev.inni.mobile 2>/dev/null || true
if [ -n "$OPEN" ]; then
  xcrun simctl launch booted dev.inni.mobile -InniOpen "$OPEN" ${EXTRA:-} >/dev/null
else
  xcrun simctl launch booted dev.inni.mobile >/dev/null
fi
sleep "$WAIT"
xcrun simctl io booted screenshot "$OUT" >/dev/null 2>&1
echo "$OUT"
