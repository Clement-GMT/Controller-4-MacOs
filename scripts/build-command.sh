#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
build_dir="$(mktemp -d -t pont-manettes-build)"
trap 'rm -rf "$build_dir"' EXIT

sdk="$(xcrun --sdk macosx --show-sdk-path)"
CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" xcrun --sdk macosx clang \
    -target arm64-apple-macos15.0 -isysroot "$sdk" -O2 -fobjc-arc -Wall -Wextra -Werror \
    -framework AppKit -framework Foundation -framework IOKit -framework IOUSBHost \
    "$project_dir/Sources/Controller.m" -o "$build_dir/manette-usb"
codesign --verify --strict "$build_dir/manette-usb"

name='Pont manettes USB.command'
{
    cat <<'HEADER'
#!/bin/zsh

unpack_worker() {
    /usr/bin/base64 -D <<'PONT_MANETTES_ARM64'
HEADER
    /usr/bin/base64 -b 76 -i "$build_dir/manette-usb"
    printf '\nPONT_MANETTES_ARM64\n}\n\n'
    /usr/bin/tail -n +2 "$project_dir/Resources/launcher.zsh"
} > "$build_dir/$name"
/bin/zsh -n "$build_dir/$name"
chmod 755 "$build_dir/$name"
mv -f "$build_dir/$name" "$output_dir/$name"
printf '%s\n' "$output_dir/$name"
