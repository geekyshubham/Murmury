#!/bin/sh
# Live VoiceOver check of both guided sheets and the Teach screen, about 3 minutes, unattended.
# VoiceOver runs with the Mac's sound muted; scripts/vo-listen.swift records every phrase it
# speaks (its caption panel), and the sheet probe (SheetProbe.swift) drives Murmury with
# VoiceOver's own keys: opening each sheet, moving through it, choosing an axis, interrupting a
# prompt, cancelling, finishing, dismissing (where VoiceOver lands after), a control that
# disappears when pressed, and a saved take. Everything is restored afterwards: VoiceOver off,
# sound as it was. Needs Accessibility and Screen Recording for this terminal.
# Output: llm-council/evidence/voiceover-<time>/ (README.md timeline, one probe log per run, captions.tsv).
set -eu
cd "$(dirname "$0")/.."
root=$PWD
app="$root/build/Murmury.app/Contents/MacOS/Murmury"
[ -x "$app" ] || { echo "Build Murmury first: scripts/build-app.sh" >&2; exit 1; }
out="$root/llm-council/evidence/voiceover-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out" "$root/.build/tools"
swiftc -O "$root/scripts/vo-listen.swift" -o "$root/.build/tools/vo-listen"

vo_was_on=no; pgrep -qx VoiceOver && vo_was_on=yes
muted_before=$(osascript -e 'output muted of (get volume settings)')
listener=; caff=; pid=
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    # The listener turns VoiceOver off as it stops (Command-F5), unless it was on before.
    touch "$out/.stop"; [ -n "$listener" ] && wait "$listener" 2>/dev/null || true; rm -f "$out/.stop"; listener=
    if [ "$vo_was_on" = no ] && pgrep -qx VoiceOver; then pkill -x VoiceOver || true; fi
    osascript -e "set volume output muted $muted_before"
    [ -n "$caff" ] && kill "$caff" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cat <<'EOF'
Murmury VoiceOver check: about 3 minutes, with the sound muted.
VoiceOver turns on and Murmury opens and closes several times. Please don't use the keyboard or
mouse until this window says it's done; everything is put back afterwards.
EOF
printf 'Press Return to start. '; read -r _

caffeinate -d & caff=$!
osascript -e 'set volume output muted true'
off=--turn-off-at-stop; [ "$vo_was_on" = yes ] && off=
"$root/.build/tools/vo-listen" "$out/captions.tsv" "$out/.stop" $off & listener=$!
pgrep -qx Murmury && osascript -e 'quit app "Murmury"' >/dev/null 2>&1 || true
open /System/Library/CoreServices/VoiceOver.app
tries=0; until pgrep -qx VoiceOver || [ "$tries" -ge 40 ]; do sleep 0.25; tries=$((tries + 1)); done
pgrep -qx VoiceOver || { echo "VoiceOver didn't start." >&2; exit 1; }
sleep 4  # first-run welcome (the listener dismisses it) and VoiceOver's own start-up speech

run() { # name appearance screen stage plan
    name=$1; appearance=$2; screen=$3; stage=$4; plan=$5
    printf '  %s… ' "$name"
    "$app" --demo "--screen=$screen" --window-size=1120x740 "--appearance=$appearance" "--stage=$stage" \
        "--sheet-probe=$out/$name.txt" "--sheet-probe-plan=$plan" > "$out/$name.launch.log" 2>&1 &
    pid=$!
    tries=0
    until [ -f "$out/$name.txt" ] || [ "$tries" -ge 120 ]; do sleep 0.5; tries=$((tries + 1)); done
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=
    sleep 1
    [ -f "$out/$name.txt" ] && echo done || echo "no output"
}

cam="open:Calibrate with camera…"
mur="open:Teach your murmur…"
next="vo:right|wait:1.6"
run calibration-open-and-dismiss light control calibration-idle "$cam|wait:3|$next|$next|$next|$next|esc|wait:3|focus"
run calibration-prompt-interrupted dark control calibration-stalled "$cam|wait:3|press:Repeat step|wait:3|press:Skip step|wait:3|esc|wait:2|esc|wait:3|focus"
run calibration-axes-and-completion light control calibration-done "$cam|wait:3|$next|$next|pick:Nod|wait:2.5|pick:Tilt|wait:2.5|press:Done|wait:3|focus"
run murmur-control-disappears dark control murmur-reading "$mur|wait:3|$next|$next|press:Done reading|wait:3|$next|esc|wait:2|esc|wait:3|focus"
run murmur-cancelled light control murmur-reading "$mur|wait:3|press:Cancel|wait:3.5|focus"
run murmur-completed dark control murmur-done "$mur|wait:3|$next|$next|$next|press:Done|wait:3|focus"
run teach-saved-take light train murmur-done "wait:2|tap:nod|wait:1.5|down:space|wait:2|up:space|wait:4|focus"

cleanup; trap - EXIT INT TERM
python3 -I "$root/scripts/voiceover-timeline.py" "$out" > "$out/README.md"
echo "Done. VoiceOver is off and the sound is back as it was."
echo "Timeline: $out/README.md"
