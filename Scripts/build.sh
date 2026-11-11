#!/bin/zsh
# Builds a universal (arm64 + x86_64) release app into dist/Tobken.app, ad hoc signed.
set -euo pipefail
cd "${0:A:h:h}"
cache="${TMPDIR:-/tmp}"
export CLANG_MODULE_CACHE_PATH="$cache/tobken-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/tobken-swift-module-cache"
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox \
  --cache-path "$cache/tobken-swiftpm/cache" --config-path "$cache/tobken-swiftpm/config" \
  --security-path "$cache/tobken-swiftpm/security"
binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tobken"
version="$(<VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || print 1)"
app_dir="$PWD/dist/Tobken.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Licenses"
cp "$binary" "$app_dir/Contents/MacOS/Tobken"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/Licenses/Tobken.txt"
cp Vendor/AgentSpeed/LICENSE "$app_dir/Contents/Resources/Licenses/AgentSpeed.txt"
cp Vendor/AgentSpeed/Sources/CZstd/LICENSE "$app_dir/Contents/Resources/Licenses/Zstd.txt"
cp Vendor/CodexBar/LICENSE "$app_dir/Contents/Resources/Licenses/CodexBar.txt"
codesign --force --sign - "$app_dir"
print "$app_dir"
