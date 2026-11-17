#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(mktemp -d -t pont-manettes-build)"
trap 'rm -rf "$build_dir"' EXIT

volume='Controller 4 MacOs'
app="$build_dir/image/$volume.app"
resources="$app/Contents/Resources"
helpers="$app/Contents/Helpers"
architecture="${XBOX_BRIDGE_ARCH:-arm64}"
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Architecture inconnue : %s\n' "$architecture" >&2; exit 2 ;;
esac
mkdir -p "$app/Contents/MacOS" "$resources" "$helpers"
cp -X "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp -X "$project_dir/Resources/launcher.zsh" "$resources/launcher.zsh"
/bin/zsh -n "$resources/launcher.zsh"

iconset="$build_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_dir/Resources/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina="$((size * 2))"
    sips -z "$retina" "$retina" "$project_dir/Resources/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" xcrun --sdk macosx clang \
    -target "$architecture-apple-macos15.0" -isysroot "$sdk" -O2 -fobjc-arc -Wall -Wextra -Werror \
    -framework AppKit -framework Foundation -framework IOKit -framework IOUSBHost \
    "$project_dir/Sources/Controller.m" -o "$helpers/xbox-usb"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
    -target "$architecture-apple-macos15.0" -sdk "$sdk" -module-cache-path "$build_dir/swift-cache" \
    "$project_dir"/Sources/*.swift -o "$app/Contents/MacOS/PontManettes"

xattr -cr "$app"
sign_identity="${XBOX_BRIDGE_SIGN_IDENTITY:--}"
sign_options=()
if [[ "$sign_identity" != '-' ]]; then sign_options+=(--options runtime --timestamp); fi
codesign --force --sign "$sign_identity" ${sign_options[@]+"${sign_options[@]}"} "$helpers/xbox-usb"
codesign --force --sign "$sign_identity" ${sign_options[@]+"${sign_options[@]}"} "$app"
codesign --verify --deep --strict "$app"

ln -s /Applications "$build_dir/image/Applications"
cp -X "$project_dir/README.md" "$build_dir/image/Lisez-moi.md"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
image_name="Controller-4-MacOs-$version-$architecture.dmg"
hdiutil create -volname "$volume" -srcfolder "$build_dir/image" -format UDZO "$build_dir/$image_name"
if [[ "$sign_identity" != '-' ]]; then
    codesign --force --sign "$sign_identity" --timestamp "$build_dir/$image_name"
fi
hdiutil verify -quiet "$build_dir/$image_name"
mv -f "$build_dir/$image_name" "$output_dir/$image_name"
printf '%s\n' "$output_dir/$image_name"
