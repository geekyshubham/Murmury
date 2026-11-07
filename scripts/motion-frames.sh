#!/bin/sh
# Live evidence: the running app in demo mode, the window captured repeatedly while the head follows
# demo motion. Writes timestamped frames and a strip of the hero to llm-council/shots/<round>-live/.
# Usage: scripts/motion-frames.sh <round> [appearance light|dark]
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/motion-frames.sh round [light|dark]}
appearance=${2:-dark}
out="llm-council/shots/$round-live"
mkdir -p "$out" .build/ModuleCache
swiftc -module-cache-path "$PWD/.build/ModuleCache" scripts/window-id.swift -o .build/shot-window-id
app="$PWD/build/Murmury.app/Contents/MacOS/Murmury"
"$app" --demo --background --window-size=1120x740 "--appearance=$appearance" > "$out/launch.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
sleep 3
tries=0
until id=$(.build/shot-window-id "$pid" 2>/dev/null); do
    tries=$((tries + 1)); [ "$tries" -ge 12 ] && exit 1; sleep 0.5
done
: > "$out/times-$appearance.txt"
i=0
while [ "$i" -lt 12 ]; do
    f=$(printf '%s/frame-%s-%02d.png' "$out" "$appearance" "$i")
    python3 -I -c 'import time; print(f"{time.time():.3f}")' >> "$out/times-$appearance.txt"
    screencapture -l"$id" -o -x "$f"
    i=$((i + 1))
    sleep 0.35
done
echo "Captured $i frames in $out"
