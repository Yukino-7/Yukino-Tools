#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
flavor="${2:-public}"
case "$flavor" in
    public) export YUKINO_LOCAL_FEATURES=0 YUKINO_PUBLIC_RELEASE=1 ;;
    local)
        test -f Sources/YukinoTools/LocalFeatures/LocalFeatureIntegration.swift || { echo 'Local feature sources are not available.' >&2; exit 1; }
        export YUKINO_LOCAL_FEATURES=1 YUKINO_PUBLIC_RELEASE=0 ;;
    *) echo 'Usage: build-app.sh [release|debug] [public|local]' >&2; exit 1 ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/$flavor/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/$flavor/module-cache"
swift build --configuration "$configuration" --disable-sandbox --scratch-path ".build/$flavor" --cache-path .build/cache
binary_directory="$(swift build --configuration "$configuration" --disable-sandbox --scratch-path ".build/$flavor" --cache-path .build/cache --show-bin-path)"
app_directory="$PWD/build/$flavor/Yukino Tools.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/YukinoTools" "$app_directory/Contents/MacOS/YukinoTools"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :YukinoBuildFlavor string $flavor" "$app_directory/Contents/Info.plist"
if [ -f LICENSE ]; then
    cp LICENSE "$app_directory/Contents/Resources/LICENSE"
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$app_directory/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$app_directory"
if [ "$flavor" = public ]; then ./scripts/verify-public-app.sh "$app_directory"; fi
printf 'Built: %s\n' "$app_directory"
