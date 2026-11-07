#!/bin/sh
# Runs the swift-testing suite. Extra args go to the runner, e.g. --filter "SPP framing".
set -e
cd "$(dirname "$0")/.."
scripts/swift-build.sh --product murmury-tests
exec "$(scripts/swift-build.sh --show-bin-path)/murmury-tests" "$@"
