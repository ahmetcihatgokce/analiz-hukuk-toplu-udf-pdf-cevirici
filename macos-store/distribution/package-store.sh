#!/bin/bash
# Run only in the protected manual Store workflow, after native sandbox tests.
# Produces a signed Store .pkg, validates it, and optionally uploads the build.
# Successful upload is not App Review approval or publication.
set -euo pipefail
set +x
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'Usage: package-store.sh <tested universal .app> <new output directory>'
[[ "$(uname -s)" == Darwin ]] || fail 'A macOS runner with Xcode is required.'
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || fail 'RUNNER_TEMP is required.'
RUNNER_TEMP="$(cd "$RUNNER_TEMP" && pwd)"
for variable in APPLE_DISTRIBUTION_P12_BASE64 APPLE_DISTRIBUTION_P12_PASSWORD INSTALLER_DISTRIBUTION_P12_BASE64 INSTALLER_DISTRIBUTION_P12_PASSWORD APPLE_TEAM_ID MAC_STORE_SOURCE_SHA ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_P8; do
    [[ -n "${!variable:-}" ]] || fail "Missing input: $variable"
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid Apple Team ID.'
[[ "$MAC_STORE_SOURCE_SHA" =~ ^[[:xdigit:]]{40}$ ]] || fail 'MAC_STORE_SOURCE_SHA must be an immutable source commit.'
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid App Store Connect key ID.'
[[ "$ASC_ISSUER_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Invalid Team API key issuer.'
[[ "${MAC_STORE_UPLOAD:-0}" == 0 || "${MAC_STORE_UPLOAD:-0}" == 1 ]] || fail 'MAC_STORE_UPLOAD must be 0 or 1.'
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -d "$app" && ! -L "$app" && "$app" == *.app ]] || fail 'Expected the tested app bundle.'
script_root="$(cd "$(dirname "$0")" && pwd)"
entitlements_source="$script_root/../Store.entitlements"
[[ -f "$entitlements_source" ]] || fail 'Store.entitlements is required.'
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/UdfPdf" -verify_arch arm64 x86_64
if otool -L "$app/Contents/MacOS/UdfPdf" | grep -qE '/(opt/homebrew|usr/local)/'; then
    fail 'The Store app has a non-system runtime dependency.'
fi
# Inspect bundle data without executing any bundled code.
python3 - "$app" "$entitlements_source" <<'PY'
import os, pathlib, plistlib, sys, subprocess
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
expected = {
    'CFBundleIdentifier': 'org.analizhukuk.udfpdf.mac',
    'CFBundleShortVersionString': '1.0.4', 'CFBundleVersion': '2',
    'CFBundleExecutable': 'UdfPdf', 'CFBundleSupportedPlatforms': ['MacOSX'],
    'LSMinimumSystemVersion': '13.0',
    'LSApplicationCategoryType': 'public.app-category.productivity',
    'AHStoreTestingBuild': False,
}
if any(info.get(key) != value for key, value in expected.items()):
    raise SystemExit('The Store bundle metadata differs from the reviewed release.')
entitlements = plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
if entitlements != {'com.apple.security.app-sandbox': True,
                    'com.apple.security.files.user-selected.read-write': True}:
    raise SystemExit('Unexpected Store entitlements.')
main = app / 'Contents/MacOS/UdfPdf'
mach_magic = {bytes.fromhex(value) for value in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
for path in [app, *app.rglob('*')]:
    if 'com.apple.quarantine' in subprocess.check_output(['/usr/bin/xattr', str(path)], text=True).splitlines():
        raise SystemExit('Remove quarantine metadata from the built app before Store upload.')
    if path.is_symlink():
        raise SystemExit('The reviewed single-executable bundle must not contain symlinks.')
    if not path.is_file():
        continue
    if path.suffix.lower() in {'.java', '.jar', '.class', '.jmod', '.dylib'} or any(part.lower() in {'javabridge', 'jre', 'jdk', 'fixtures'} for part in path.parts):
        raise SystemExit('Java, UYAP, extra libraries or test fixtures must not be bundled.')
    if path != main:
        with path.open('rb') as handle:
            if handle.read(4) in mach_magic:
                raise SystemExit('Unexpected nested executable in the Store bundle.')
PY
[[ ! -e "$2" ]] || fail 'Use a new output directory.'
mkdir -p "$2"
output="$(cd "$2" && pwd)"
private_root="$(mktemp -d "$RUNNER_TEMP/mac-store-signing.XXXXXX")"
keychain="$private_root/signing.keychain-db"
original_keychains=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -z "$line" ]] || original_keychains+=("$line")
done < <(security list-keychains -d user)
cleanup() {
    local result=$?
    set +e
    if [[ ${#original_keychains[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1
    if [[ -n "$private_root" && "$private_root" == "$RUNNER_TEMP"/mac-store-signing.* && ! -L "$private_root" ]]; then
        rm -rf -- "$private_root"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$private_root" <<'PY'
import base64, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for variable, filename in [('APPLE_DISTRIBUTION_P12_BASE64', 'application.p12'),
                           ('INSTALLER_DISTRIBUTION_P12_BASE64', 'installer.p12')]:
    value = ''.join(os.environ[variable].split())
    (root / filename).write_bytes(base64.b64decode(value, validate=True))
if os.environ.get('MAC_STORE_PROFILE_BASE64'):
    value = ''.join(os.environ['MAC_STORE_PROFILE_BASE64'].split())
    (root / 'store.provisionprofile').write_bytes(base64.b64decode(value, validate=True))
PY
keychain_password="$(/usr/bin/openssl rand -hex 32)"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::add-mask::%s\n' "$keychain_password"; fi
security create-keychain -p "$keychain_password" "$keychain" >/dev/null
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$private_root/application.p12" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security import "$private_root/installer.p12" -P "$INSTALLER_DISTRIBUTION_P12_PASSWORD" -k "$keychain" -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/security >/dev/null
curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 120 --retry 2 \
    'https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer' -o "$private_root/AppleWWDRCAG3.cer"
security import "$private_root/AppleWWDRCAG3.cer" -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
else
    security list-keychains -d user -s "$keychain"
fi
rm -f -- "$private_root/application.p12" "$private_root/installer.p12"
unset APPLE_DISTRIBUTION_P12_BASE64 APPLE_DISTRIBUTION_P12_PASSWORD INSTALLER_DISTRIBUTION_P12_BASE64 INSTALLER_DISTRIBUTION_P12_PASSWORD keychain_password
security find-identity -v "$keychain" > "$private_root/identities.txt"
python3 - "$private_root/identities.txt" "$private_root" <<'PY'
import os, pathlib, re, sys
identities = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    match = re.search(r'\b([0-9A-Fa-f]{40})\s+"([^"]+)"', line)
    if match and match.group(2).endswith('(' + os.environ['APPLE_TEAM_ID'] + ')'):
        identities.append((match.group(1), match.group(2)))
for name, prefixes in [('application', ('Apple Distribution: ', '3rd Party Mac Developer Application: ')),
                       ('installer', ('3rd Party Mac Developer Installer: ',))]:
    matches = [item for item in identities if item[1].startswith(prefixes)]
    if len(matches) != 1:
        raise SystemExit('Expected exactly one valid ' + name + ' Store identity for the team.')
    value = matches[0][0] if name == 'application' else matches[0][1]
    (pathlib.Path(sys.argv[2]) / (name + '.identity')).write_text(value + '\n')
PY
application_identity="$(cat "$private_root/application.identity")"
installer_identity="$(cat "$private_root/installer.identity")"
cp "$entitlements_source" "$private_root/Store.entitlements"
if [[ -f "$private_root/store.provisionprofile" ]]; then
    security cms -D -i "$private_root/store.provisionprofile" > "$private_root/profile.plist"
    python3 - "$private_root/profile.plist" "$private_root/Store.entitlements" "$application_identity" <<'PY'
import datetime, hashlib, os, pathlib, plistlib, sys
profile = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
team = os.environ['APPLE_TEAM_ID']
if team not in profile.get('TeamIdentifier', []):
    raise SystemExit('The Store profile belongs to another team.')
expiry = profile.get('ExpirationDate')
if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('The Store profile has expired.')
if not any(value in profile.get('Platform', []) for value in ('OSX', 'macOS')):
    raise SystemExit('Expected a macOS Store provisioning profile.')
allowed = profile.get('Entitlements', {})
identifier = team + '.org.analizhukuk.udfpdf.mac'
if allowed.get('com.apple.application-identifier') != identifier or allowed.get('get-task-allow') or allowed.get('com.apple.security.get-task-allow'):
    raise SystemExit('The Store profile has an unexpected app ID or enables debugging.')
if not any(hashlib.sha1(value).hexdigest().upper() == sys.argv[3].upper() for value in profile.get('DeveloperCertificates', [])):
    raise SystemExit('The Store profile does not include the application signing certificate.')
path = pathlib.Path(sys.argv[2])
entitlements = plistlib.loads(path.read_bytes())
entitlements.update({'com.apple.application-identifier': identifier,
                     'com.apple.developer.team-identifier': team})
path.write_bytes(plistlib.dumps(entitlements))
PY
    cp "$private_root/store.provisionprofile" "$app/Contents/embedded.provisionprofile"
elif [[ -e "$app/Contents/embedded.provisionprofile" ]]; then
    fail 'An embedded profile must be supplied and validated explicitly.'
fi
# No application code is executed after the signing identities are imported.
codesign --force --timestamp --options runtime --generate-entitlement-der --keychain "$keychain" \
    --entitlements "$private_root/Store.entitlements" --sign "$application_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=4 "$app" > "$private_root/signature.txt" 2>&1
codesign --display --entitlements :- "$app" > "$private_root/signed-entitlements.plist" 2>/dev/null
python3 - "$private_root/signature.txt" "$private_root/signed-entitlements.plist" "$private_root/Store.entitlements" <<'PY'
import os, pathlib, plistlib, sys
signature = pathlib.Path(sys.argv[1]).read_text()
if ('Authority=Apple Distribution:' not in signature and 'Authority=3rd Party Mac Developer Application:' not in signature) or 'TeamIdentifier=' + os.environ['APPLE_TEAM_ID'] not in signature:
    raise SystemExit('Unexpected Store signing authority or team.')
if 'Identifier=org.analizhukuk.udfpdf.mac\n' not in signature or 'Timestamp=' not in signature:
    raise SystemExit('Expected the final Store identifier and secure timestamp.')
actual = plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
expected = plistlib.loads(pathlib.Path(sys.argv[3]).read_bytes())
if actual != expected:
    raise SystemExit('The signed entitlements differ from the reviewed Store entitlements.')
PY
pkg="$output/Analiz-Hukuk-UDF-PDF-Mac-1.04-Store.pkg"
productbuild --keychain "$keychain" --sign "$installer_identity" --component "$app" /Applications "$pkg"
pkgutil --check-signature "$pkg" > "$private_root/package-signature.txt"
grep -F '3rd Party Mac Developer Installer:' "$private_root/package-signature.txt" >/dev/null || fail 'The package lacks a Mac Installer Distribution signature.'
grep -F "($APPLE_TEAM_ID)" "$private_root/package-signature.txt" >/dev/null || fail 'Unexpected package signing team.'
if [[ ${#original_keychains[@]} -gt 0 ]]; then security list-keychains -d user -s "${original_keychains[@]}"; fi
security delete-keychain "$keychain"
asc_directory="$private_root/private_keys"
mkdir "$asc_directory"
asc_key="$asc_directory/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_PRIVATE_KEY_P8" > "$asc_key"
unset ASC_PRIVATE_KEY_P8
/usr/bin/openssl pkey -in "$asc_key" -noout >/dev/null 2>&1 || fail 'Invalid App Store Connect private key.'
export API_PRIVATE_KEYS_DIR="$asc_directory"
if ! xcrun altool --validate-app --file "$pkg" --type osx --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json > "$private_root/validate.json" 2> "$private_root/validate.stderr"; then
    fail 'App Store Connect package validation failed. No upload occurred.'
fi
state=validated
if [[ "${MAC_STORE_UPLOAD:-0}" == 1 ]]; then
    xcrun altool --upload-app --file "$pkg" --type osx --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json > "$private_root/upload.json" 2> "$private_root/upload.stderr" || fail 'App Store Connect upload failed.'
    state=uploaded
fi
(
    cd "$output"
    shasum -a 256 "$(basename "$pkg")" > "$(basename "$pkg").sha256"
)
python3 - "$output/store-package.json" "$state" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'bundleIdentifier': 'org.analizhukuk.udfpdf.mac', 'version': '1.0.4', 'build': '2',
    'architectures': ['arm64', 'x86_64'], 'sourceCommit': os.environ['MAC_STORE_SOURCE_SHA'],
    'teamId': os.environ['APPLE_TEAM_ID'], 'sandboxed': True, 'javaBundled': False,
    'appStoreValidation': 'passed', 'uploadState': sys.argv[2],
    'appReviewSubmitted': False, 'published': False,
}, indent=2) + '\n')
PY
printf 'Mac App Store package: %s; state: %s. App Review submission and publication are separate steps.\n' "$(basename "$pkg")" "$state"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'state=%s\n' "$state" >> "$GITHUB_OUTPUT"; fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Mac App Store package\n\nVersion 1.0.4 (2), universal, sandboxed, native UDF renderer.\n\nPackage state: **%s**. App Review has not been submitted by this script.\n' "$state" >> "$GITHUB_STEP_SUMMARY"
fi
