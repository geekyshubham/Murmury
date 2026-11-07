#!/bin/sh
# Guided field test with the buds on (about 12 minutes). Murmury records a journal while you follow
# the steps in this window (FieldJournal.swift): head frames and their gaps, motion samples and
# their gaps, sample-to-frame latency, the reporting bud, what Murmury said, commands acted or
# ignored, buds and voice loss and recovery, the front app. Step 1's camera fit measures how late
# the buds' motion arrives, so physical motion to display can be estimated.
# This window stays in front throughout, so recovery is tested with another app foregrounded.
# Output: llm-council/evidence/field-<time>/ (journal.jsonl, steps.jsonl, report.md).
# Usage: scripts/field-test.sh [--skip-camera]
set -eu
cd "$(dirname "$0")/.."
root=$PWD
app="$root/build/Murmury.app"
[ -d "$app" ] || { echo "Build Murmury first: scripts/build-app.sh" >&2; exit 1; }
camera=yes
[ "${1:-}" = "--skip-camera" ] && camera=no

out="$root/llm-council/evidence/field-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
journal="$out/journal.jsonl"; steps="$out/steps.jsonl"
dark_before=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' 2>/dev/null || echo unknown)
restore() {
    if [ "$dark_before" = true ] || [ "$dark_before" = false ]; then
        osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark_before" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT INT TERM

mark() { python3 -I -c 'import json,sys,time; print(json.dumps({"wall": round(time.time(), 3), "step": sys.argv[1], "phase": sys.argv[2]}))' "$1" "$2" >> "$steps"; }
countdown() {
    left=$1
    while [ "$left" -gt 0 ]; do printf '\r  %3d s left ' "$left"; sleep 1; left=$((left - 1)); done
    printf '\r  done.        \a\n'
}
# step <id> <seconds, 0 = until Return> <instructions>
step() {
    id=$1; secs=$2; shift 2
    printf '\n\033[1m%s\033[0m\n' "$id"
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '  Press Return to start. '; read -r _
    mark "$id" start
    if [ "$secs" -gt 0 ]; then countdown "$secs"; else printf '  Press Return when done. '; read -r _; fi
    mark "$id" end
}

cat <<'EOF'
Murmury field test, about 12 minutes. Keep this window in front unless a step says otherwise.
Murmury restarts with recording on. Nothing leaves this Mac.
EOF
osascript -e 'quit app "Murmury"' >/dev/null 2>&1 || true
sleep 1
open -n --env "MURMURY_FIELD_LOG=$journal" "$app"
sleep 3

step setup 0 \
    "Put both buds in. In Murmury, connect them and choose Start on Control so the pointer follows your head." \
    "Then click back into this window."
if [ "$camera" = yes ]; then
    step camera-fit 0 \
        "In Murmury choose … › Calibrate with camera… and follow it to the end (about a minute)." \
        "It measures how late the buds' motion reaches the Mac. Click back here afterwards."
fi
step limited-movement 60 \
    "Keep your shoulders still and use small head turns only." \
    "Move the pointer to each corner of this window and back, slowly. Say \"click\" quietly at each corner."
step quiet-murmur 60 \
    "Murmur these one at a time, barely voiced, with a pause after each:" \
    "  scroll down … scroll up … click … scroll down … scroll up … click"
step conversation 30 \
    "Talk normally for a moment, in sentences, for example:" \
    "  \"I'll click on the first one and then scroll down to read the rest.\""
printf '\n\033[1mnearby-speech\033[0m\n  Stay quiet. This Mac speaks sentences and lone command words aloud, as someone nearby would.\n  Press Return to start. '
read -r _
mark nearby-speech start
for line in "I clicked the button and then scrolled down the page." "Click." "Can you scroll up a little and click on it?" "Scroll down." \
    "We should pause the meeting and resume after lunch." "Click."; do
    say -r 170 "$line"; sleep 2.5
done
mark nearby-speech end
step reporting-bud 75 \
    "Take the LEFT bud out, hold it still for 10 seconds, put it back." \
    "Then the RIGHT bud: out for 10 seconds, back in. Keep moving your head gently between."
step both-lost 0 \
    "Leave this window in front and don't touch Murmury." \
    "Put both buds in the case and close the lid. Wait until Murmury says the buds are disconnected." \
    "Wait 20 seconds more, then take them out and put them in. Murmury should reconnect and resume" \
    "on its own. Press Return once the pointer follows your head again (or after 2 minutes)."
printf '\n\033[1mappearance\033[0m\n  Keep turning your head gently. The Mac switches between light and dark twice.\n  Press Return to start. '
read -r _
mark appearance start
for _ in 1 2; do
    sleep 4; osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode' >/dev/null 2>&1 || echo "  (couldn't switch appearance)"
    sleep 4; osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode' >/dev/null 2>&1 || true
done
sleep 3
mark appearance end
restore
step sustained 120 \
    "Use the pointer as you normally would: point, scroll, read, for two minutes."

osascript -e 'quit app "Murmury"' >/dev/null 2>&1 || true
sleep 2
python3 -I "$root/scripts/field-report.py" "$journal" "$steps" > "$out/report.md"
echo
echo "Report: $out/report.md"
