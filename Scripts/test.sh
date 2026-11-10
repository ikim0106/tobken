#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/tobken-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/tobken-swift-module-cache"
swift test --disable-sandbox --cache-path "${TMPDIR:-/tmp}/tobken-swiftpm/cache" --config-path "${TMPDIR:-/tmp}/tobken-swiftpm/config" --security-path "${TMPDIR:-/tmp}/tobken-swiftpm/security" "$@"
