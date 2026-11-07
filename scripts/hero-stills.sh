#!/bin/sh
# Offline hero evidence with SCNRenderer (needs a Metal device; exits 3 without one).
# Usage: scripts/hero-stills.sh <round> [extra flags, e.g. --hero-debug-eyes or --only=head]
# Writes llm-council/shots/<round>/*.png and metrics.json, and the asset tree to
# llm-council/evidence/r2-head-hierarchy.txt.
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/hero-stills.sh round [flags]}
shift
case "$round" in *[!A-Za-z0-9_-]*) echo 'Round must be a simple directory name' >&2; exit 2;; esac
scripts/swift-build.sh --product Murmury >/dev/null
bin="$(scripts/swift-build.sh --show-bin-path)/Murmury"
"$bin" --dump-scene=Resources/Models/head.scn > llm-council/evidence/r2-head-hierarchy.txt
"$bin" "--render-hero-stills=$PWD/llm-council/shots/$round" --asset=Resources/Models/head.scn "$@"
echo "Rendered hero stills and metrics.json in llm-council/shots/$round"
