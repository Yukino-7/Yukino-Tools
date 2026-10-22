#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
flavor="${1:-public}"
case "$flavor" in
    public) export YUKINO_LOCAL_FEATURES=0 YUKINO_PUBLIC_RELEASE=1 ;;
    local) export YUKINO_LOCAL_FEATURES=1 YUKINO_PUBLIC_RELEASE=0 ;;
    *) echo 'Usage: test.sh [public|local]' >&2; exit 1 ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/$flavor/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/$flavor/module-cache"
swift test --disable-sandbox --scratch-path ".build/$flavor" --cache-path .build/cache
