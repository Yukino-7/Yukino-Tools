#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
configuration="${1:-release}"
swift build --configuration "$configuration" --disable-sandbox --cache-path .build/cache
binary_directory="$(swift build --configuration "$configuration" --disable-sandbox --cache-path .build/cache --show-bin-path)"
app_directory="$PWD/build/Yukino Tools.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/YukinoTools" "$app_directory/Contents/MacOS/YukinoTools"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
if [ -f LICENSE ]; then
    cp LICENSE "$app_directory/Contents/Resources/LICENSE"
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$app_directory/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$app_directory"
printf 'Built: %s\n' "$app_directory"
