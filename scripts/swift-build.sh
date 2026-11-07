#!/bin/sh
# Keep Swift's build caches in the repository, including in restricted CLT environments.
set -e
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
exec swift build --disable-sandbox --cache-path .build/cache --config-path .build/configuration --security-path .build/security "$@"
