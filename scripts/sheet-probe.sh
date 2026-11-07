#!/bin/sh
# Drives the camera calibration and murmur sheets through the accessibility API, as VoiceOver does,
# and records focus, reading order, announcements and Esc behaviour (SheetProbe.swift).
# Usage: scripts/sheet-probe.sh <round>. Needs Accessibility permission; briefly brings Murmury forward.
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/sheet-probe.sh round}
case "$round" in *[!A-Za-z0-9_-]*) echo 'Round must be a simple directory name' >&2; exit 2;; esac
out="llm-council/evidence/sheet-probe-$round"
app="$PWD/build/Murmury.app/Contents/MacOS/Murmury"
rm -rf "$out"; mkdir -p "$out"
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi' EXIT INT TERM

probe() { # name appearance stage plan
    name=$1; appearance=$2; stage=$3; plan=$4
    "$app" --demo --screen=control --window-size=1120x740 "--appearance=$appearance" "--stage=$stage" \
        "--sheet-probe=$PWD/$out/$name.txt" "--sheet-probe-plan=$plan" > "$out/$name.launch.log" 2>&1 &
    pid=$!
    tries=0
    until [ -f "$out/$name.txt" ] || [ "$tries" -ge 90 ]; do sleep 0.5; tries=$((tries + 1)); done
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=
    [ -f "$out/$name.txt" ] && echo "$name: $(grep -c '^>' "$out/$name.txt") steps" || echo "$name: no output"
}

cam="open:Calibrate with camera…"
mur="open:Teach your murmur…"
probe calibration-idle light calibration-idle "focus|$cam|order|esc|focus"
probe calibration-stalled-repeat dark calibration-stalled "$cam|order|press:Repeat step|esc|esc|focus"
probe calibration-stalled-skip dark calibration-stalled "$cam|press:Skip step|esc|esc|focus"
probe calibration-done light calibration-done "$cam|order|label:Turn over|pick:Nod|label:Nod over|pick:Tilt|label:Tilt over|press:Done|focus"
probe murmur-reading-no-speech dark murmur-reading "$mur|order|press:Done reading|esc|esc|focus"
probe murmur-weak light murmur-weak "$mur|order|press:Use it anyway|press:Done|focus"
probe murmur-mic-denied dark murmur-denied "$mur|order|esc|focus"
