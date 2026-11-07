#!/bin/sh
# Renders the shared V3 vector mark on the CPU and packages it.
set -eu
cd "$(dirname "$0")/.."
mkdir -p llm-council/backups llm-council/shots/r3-icon
[ -f llm-council/backups/AppIcon-r1.icns ] || cp Resources/AppIcon.icns llm-council/backups/AppIcon-r1.icns
scripts/swift-build.sh --product Murmury
bin="$(scripts/swift-build.sh --show-bin-path)/Murmury"
rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset
if ! "$bin" "--render-icon=$PWD/build/AppIcon.iconset"; then
    echo 'CPU icon export failed; Resources/AppIcon.icns is unchanged.' >&2
    exit 3
fi
if ! iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns; then
    printf '%s\n' 'iconutil encoding failed; using the ImageIO-tested native ICNS container.' >&2
    "$bin" "--render-icon=$PWD/build/AppIcon.iconset" "--render-icns=$PWD/Resources/AppIcon.icns"
fi
"$bin" "--icon-previews-of=$PWD/Resources/AppIcon.icns" "--icon-previews-to=$PWD/llm-council/shots/r3-icon"
echo 'Rendered Resources/AppIcon.icns (previews in llm-council/shots/r3-icon)'
