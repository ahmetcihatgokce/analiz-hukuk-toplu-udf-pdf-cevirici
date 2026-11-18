#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$root/build}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
app="$output/Toplu UDF PDF Cevirici.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/JavaBridge"
cp "$root/Info.plist" "$app/Contents/Info.plist"
archive_prefix="$(brew --prefix libarchive)"
if [ ! -f "$archive_prefix/include/archive.h" ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install libarchive
fi
clang -O2 -mmacosx-version-min=13.0 -I "$archive_prefix/include" -c "$root/Sources/ArchiveReader.c" -o "$output/ArchiveReader.o"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework PDFKit -framework WebKit -framework ImageIO \
    -framework UniformTypeIdentifiers -import-objc-header "$root/Sources/ArchiveReader.h" \
    "$root"/Sources/*.swift "$output/ArchiveReader.o" -larchive \
    -o "$app/Contents/MacOS/UdfPdf"
otool -L "$app/Contents/MacOS/UdfPdf"
if otool -L "$app/Contents/MacOS/UdfPdf" | grep -qE '/(opt/homebrew|usr/local)/'; then
    echo 'Unexpected non-system runtime dependency in Mac app' >&2
    exit 1
fi
javac -encoding UTF-8 -source 8 -target 8 -d "$app/Contents/Resources/JavaBridge" "$root/Resources/UyapBridge.java"
iconset="$output/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Toplu-UDF-PDF-Mac-1.04-$(uname -m).zip"
printf '%s\n' "$app"
