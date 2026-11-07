#!/bin/sh
# CPU-only evidence. No window capture, permission requests, SCNView or SCNRenderer.
set -eu
cd "$(dirname "$0")/.."
round=${1:?Usage: scripts/offline-evidence.sh round}
case "$round" in *[!A-Za-z0-9_-]*) exit 2;; esac
scripts/swift-build.sh --product murmury-tests
bin=$(scripts/swift-build.sh --show-bin-path)/murmury-tests
python3 scripts/offline-evidence.py "$round" "$bin"
