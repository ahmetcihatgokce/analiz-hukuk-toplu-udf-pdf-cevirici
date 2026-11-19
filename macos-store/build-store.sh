#!/bin/bash
# Build the native, sandboxed Mac App Store candidate without Java/UYAP code.
# This ad-hoc signature is for CI functional tests, never App Store upload.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'A native macOS runner with Xcode is required.' >&2; exit 1; }
root="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$root/build-store}"
[[ $# -le 2 && "${2:---no-zip}" == --no-zip ]] || {
    echo 'Usage: build-store.sh [output directory] [--no-zip]' >&2; exit 1;
}
[[ "${MAC_STORE_TESTING:-0}" == 0 || "${MAC_STORE_TESTING:-0}" == 1 ]] || {
    echo 'MAC_STORE_TESTING must be 0 or 1.' >&2; exit 1;
}
mkdir -p "$output"
output="$(cd "$output" && pwd)"
app="$output/Toplu UDF PDF Cevirici.app"
[[ ! -e "$app" ]] || { echo 'Use a fresh output directory; an app already exists there.' >&2; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
xcode_description="$(xcodebuild -version)"
python3 - "$app/Contents/Info.plist" "$sdk_version" "$sdk_build" "$xcode_description" <<'PY'
import os, pathlib, plistlib, re, sys
path = pathlib.Path(sys.argv[1])
with path.open('rb') as handle:
    info = plistlib.load(handle)
version = re.search(r'^Xcode (\d+)(?:\.(\d+))?(?:\.(\d+))?', sys.argv[4], re.M)
build = re.search(r'^Build version (\S+)', sys.argv[4], re.M)
if not version or not build:
    raise SystemExit('Could not identify the installed Xcode release.')
info.update({
    'CFBundleIdentifier': 'org.analizhukuk.udfpdf.mac',
    'CFBundleShortVersionString': '1.0.4', 'CFBundleVersion': '2',
    'CFBundleSupportedPlatforms': ['MacOSX'], 'LSMinimumSystemVersion': '13.0',
    'LSApplicationCategoryType': 'public.app-category.productivity',
    'DTPlatformName': 'macosx', 'DTPlatformVersion': sys.argv[2],
    'DTSDKName': 'macosx' + sys.argv[2], 'DTSDKBuild': sys.argv[3],
    'DTPlatformBuild': sys.argv[3], 'DTXcodeBuild': build.group(1),
    'DTXcode': f'{int(version.group(1)):02d}{int(version.group(2) or 0)}{int(version.group(3) or 0)}',
    'AHStoreTestingBuild': os.environ.get('MAC_STORE_TESTING', '0') == '1',
})
with path.open('wb') as handle:
    plistlib.dump(info, handle, sort_keys=False)
PY
archive_prefix="$(brew --prefix libarchive 2>/dev/null || true)"
if [[ -z "$archive_prefix" || ! -f "$archive_prefix/include/archive.h" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install libarchive
    archive_prefix="$(brew --prefix libarchive)"
fi
architecture="$(uname -m)"
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || {
    echo 'Only Apple Silicon and Intel macOS builds are supported.' >&2; exit 1;
}
clang -O2 -arch "$architecture" -isysroot "$sdk" -mmacosx-version-min=13.0 \
    -I "$archive_prefix/include" -c "$root/Sources/ArchiveReader.c" -o "$output/ArchiveReader.o"
swift_flags=(-O)
if [[ "${MAC_STORE_TESTING:-0}" == 1 ]]; then swift_flags+=(-D STORE_TESTING); fi
swiftc -parse-as-library -swift-version 5 -sdk "$sdk" -target "$architecture-apple-macos13.0" \
    "${swift_flags[@]}" -framework AppKit -framework PDFKit -framework WebKit -framework ImageIO \
    -framework UniformTypeIdentifiers -import-objc-header "$root/Sources/ArchiveReader.h" \
    "$root"/Sources/*.swift "$output/ArchiveReader.o" -larchive \
    -o "$app/Contents/MacOS/UdfPdf"
if otool -L "$app/Contents/MacOS/UdfPdf" | grep -qE '/(opt/homebrew|usr/local)/'; then
    echo 'Unexpected non-system runtime dependency in the Store candidate.' >&2; exit 1
fi
# Copy the icon only. No Java source, bytecode, JRE, UYAP or test fixture is bundled.
iconset="$output/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
plutil -lint "$app/Contents/Info.plist" "$root/Store.entitlements" >/dev/null
codesign --force --options runtime --generate-entitlement-der \
    --entitlements "$root/Store.entitlements" --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ $# -lt 2 ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$app" \
        "$output/Analiz-Hukuk-UDF-PDF-Mac-1.04-$architecture-sandbox-ci.zip"
fi
printf '%s\n' "$app"
