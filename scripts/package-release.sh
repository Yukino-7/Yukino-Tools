#!/bin/bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

./scripts/build-app.sh release
app_directory="$PWD/build/Yukino Tools.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_directory/Contents/Info.plist")"
architecture="$(lipo -archs "$app_directory/Contents/MacOS/YukinoTools")"
if [[ "$architecture" == *" "* ]]; then architecture="universal"; fi
release_directory="$PWD/build/releases/v$version"
artifact="Yukino-Tools-$version-macos-$architecture"
mkdir -p "$release_directory"
codesign --verify --deep --strict "$app_directory"

ditto -c -k --sequesterRsrc --keepParent "$app_directory" "$release_directory/$artifact.zip"
stage_directory="$(mktemp -d "$PWD/build/release-stage.XXXXXX")"
trap 'rm -rf "$stage_directory"' EXIT
ditto "$app_directory" "$stage_directory/Yukino Tools.app"
ln -s /Applications "$stage_directory/Applications"
cp LICENSE "$stage_directory/LICENSE.txt"
hdiutil create -volname 'Yukino Tools' -srcfolder "$stage_directory" -ov -format UDZO "$release_directory/$artifact.dmg"
cd "$release_directory"
shasum -a 256 "$artifact.zip" "$artifact.dmg" > SHA256SUMS.txt
printf 'Release artifacts: %s\n' "$release_directory"
