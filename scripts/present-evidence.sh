#!/bin/sh
# Presented-frame evidence for a round: displayed-frame pacing (ScreenCaptureKit display times, not
# renderer callbacks) and demo motion steps from sample arrival to the first displayed change.
# Usage: scripts/present-evidence.sh <round>. Needs Screen Recording access; no buds involved.
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/present-evidence.sh round}
mkdir -p .build/ModuleCache llm-council/evidence
swiftc -O -module-cache-path "$PWD/.build/ModuleCache" scripts/present-probe.swift -o .build/present-probe
app="$PWD/build/Murmury.app/Contents/MacOS/Murmury"
out="llm-council/evidence/presented-$round.txt"
: > "$out"
for appearance in dark light; do
    log="$(mktemp -d)/steps.log"
    MURMURY_STEP_PROBE="$log" "$app" --demo --background --window-size=1120x740 --screen=control "--appearance=$appearance" > /dev/null 2>&1 &
    pid=$!
    sleep 5
    echo "$appearance (20° demo turns every second, 1120x740 Control):" >> "$out"
    .build/present-probe "$pid" 12 "$out.part" "$log"
    cat "$out.part" >> "$out"; rm -f "$out.part"
    kill "$pid" 2>/dev/null || true
    sleep 1
done
echo "Not covered: Bluetooth and sensor latency of real Buds3 Pro (software path only, from sample arrival)." >> "$out"
cat "$out"
