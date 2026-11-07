#!/bin/sh
# Reproducible window captures; requires an unlocked desktop and Screen Recording access.
# Usage: scripts/shots.sh <round> [--states] [--pointer] [--surfaces]
#   default   24 windows: six screens x light/dark x 1120x740 and 1600x1000
#   --states  scenario states at 1120x740 in light and dark, plus one accessibility dump per screen
# Captures are checked with sips and the window display's backing scale; see manifests.
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/shots.sh round [--states]}
case "$round" in *[!A-Za-z0-9_-]*) echo 'Round must be a simple directory name' >&2; exit 2;; esac
out="llm-council/shots/$round"
app="$PWD/build/Murmury.app/Contents/MacOS/Murmury"
mkdir -p "$out" .build/ModuleCache
swiftc -module-cache-path "$PWD/.build/ModuleCache" scripts/window-id.swift -o .build/shot-window-id
mismatches=0
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi' EXIT INT TERM

launch() { # wait-seconds args...
    wait_s=$1; shift
    "$app" --demo --background "$@" > "$out/launch.log" 2>&1 &
    pid=$!
    sleep "$wait_s"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Murmury exited before its window appeared; see $out/launch.log" >&2
        pid=
        exit 1
    fi
}
finish() {
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    pid=
}
capture() { # file size args...
    file=$1; size=$2; shift 2
    launch 8 "--window-size=$size" "$@"
    tries=0
    until id=$(.build/shot-window-id "$pid" 2>/dev/null); do
        tries=$((tries + 1))
        if [ "$tries" -ge 12 ]; then .build/shot-window-id "$pid"; exit 1; fi
        sleep 0.5
    done
    screencapture -l"$id" -o "$out/$file"
    scale=$(.build/shot-window-id "$pid" --scale)
    finish
    w=$(sips -g pixelWidth "$out/$file" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$out/$file" | awk '/pixelHeight/ {print $2}')
    want_w=$(awk "BEGIN {print ${size%x*} * $scale}"); want_h=$(awk "BEGIN {print ${size#*x} * $scale}")
    status=ok
    if [ "$w" != "$want_w" ] || [ "$h" != "$want_h" ]; then status=SIZE-MISMATCH; mismatches=$((mismatches + 1)); fi
    printf '%s %s %sx%s %sx%s %s\n' "$file" "$size" $(awk "BEGIN {print $w / $scale}") $(awk "BEGIN {print $h / $scale}") "$w" "$h" "$status" >> "$manifest"
}

shift
[ "$#" -gt 0 ] || set -- default
for mode in "$@"; do
case "$mode" in default|--pointer|--states|--surfaces) ;; *) echo "Unknown capture mode: $mode" >&2; exit 2;; esac
manifest="$out/manifest-$mode.txt"
printf '%s\n' "# name requested actual(points) pixels status" > "$manifest"
if [ "$mode" = "--pointer" ]; then
    for screen in control buds motion teach model detect; do
        for point in 0.25,0.35 0.80,0.70; do
            capture "$screen-dark-pointer-$point.png" 1120x740 "--screen=$screen" --appearance=dark "--pointer-at=$point"
        done
    done
    for point in 0.25,0.35 0.80,0.70; do
        capture "control-light-pointer-$point.png" 1120x740 --screen=control --appearance=light "--pointer-at=$point"
    done
    summary="14 pointer windows"
elif [ "$mode" = "--surfaces" ]; then
    for surface in settings-pointer settings-voice settings-capture settings-detection settings-model settings-buds settings-recording signals dataset evaluation detections commands calibration menu; do
        for appearance in light dark; do
            capture "surface-$surface-$appearance.png" 1120x740 "--evidence-surface=$surface" "--appearance=$appearance"
        done
    done
    summary="settings, sheets, calibration and menu presentation windows"
elif [ "$mode" = "--states" ]; then
    for scenario in control-voice-denied control-voice-lost control-running control-calibration-failed \
                    control-pointer-only control-voice-off control-voice-retrying control-voice-recovery-failed \
                    control-calibrating teach-recording model-failed detect-feedback model-gestures control-buds-lost control-buds-escalated; do
        for appearance in light dark; do
            capture "state-$scenario-$appearance-1120x740.png" 1120x740 "--scenario=$scenario" "--appearance=$appearance"
        done
    done
    for screen in control buds motion teach model detect; do
        launch 7 --window-size=1120x740 "--screen=$screen" "--dump-ax=$PWD/$out/ax-$screen.txt"
        finish
        [ -s "$out/ax-$screen.txt" ] || { echo "No accessibility dump for $screen" >&2; exit 1; }
    done
    summary="state windows and 6 accessibility dumps"
else
    for screen in control buds motion teach model detect; do
        for appearance in light dark; do
            for size in 1120x740 1600x1000; do
                capture "$screen-$appearance-$size.png" "$size" "--screen=$screen" "--appearance=$appearance"
            done
        done
    done
    summary="24 windows"
fi
rm -f "$out/launch.log"
echo "Captured $summary in $out (manifest: $manifest)"
done
if [ "$mismatches" -gt 0 ]; then
    echo "SIZE CHECK FAILED: $mismatches capture(s) differ from the requested size; see $manifest" >&2
    exit 1
fi
