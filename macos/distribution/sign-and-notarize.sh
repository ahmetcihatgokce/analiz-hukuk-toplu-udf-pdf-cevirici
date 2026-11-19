#!/bin/bash
# Developer ID distribution only. This is not a Mac App Store upload.
set -euo pipefail
set +x
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'Usage: sign-and-notarize.sh <built .app> <new output directory>'
[[ "$(uname -s)" == Darwin ]] || fail 'Signing requires a macOS runner with Xcode.'
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || fail 'RUNNER_TEMP is required.'

for variable in MAC_CERTIFICATE_P12_BASE64 MAC_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_SIGNING_IDENTITY ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_P8 MAC_SOURCE_SHA; do
    [[ -n "${!variable:-}" ]] || fail "Required input is missing: $variable"
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID must be a 10-character Team ID.'
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'ASC_KEY_ID must be a 10-character key ID.'
[[ "$ASC_ISSUER_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'ASC_ISSUER_ID must be a team-key issuer UUID.'
[[ "$MAC_SOURCE_SHA" =~ ^[[:xdigit:]]{40}$ ]] || fail 'MAC_SOURCE_SHA must be an immutable commit SHA.'
[[ "$APPLE_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || fail 'Use a Developer ID Application identity, not an App Store distribution certificate.'

app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -d "$app" && "$app" == *.app && -f "$app/Contents/MacOS/UdfPdf" ]] || fail 'Expected the built converter app bundle.'
[[ ! -e "$2" ]] || fail 'The output directory must not already exist.'
mkdir -p "$2"
output="$(cd "$2" && pwd)"
private_root="$(mktemp -d "$RUNNER_TEMP/mac-signing.XXXXXX")"
keychain="$private_root/signing.keychain-db"
original_keychains=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [[ -z "$line" ]] || original_keychains+=("$line")
done < <(security list-keychains -d user)

cleanup() {
    local result=$?
    set +e
    if [[ ${#original_keychains[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1
    if [[ -n "$private_root" && "$private_root" == "$RUNNER_TEMP"/mac-signing.* ]]; then
        rm -rf -- "$private_root"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

p12="$private_root/signing.p12"
printf '%s' "$MAC_CERTIFICATE_P12_BASE64" | base64 --decode > "$p12"
keychain_password="$(/usr/bin/openssl rand -hex 32)"
printf '::add-mask::%s\n' "$keychain_password"
security create-keychain -p "$keychain_password" "$keychain" >/dev/null
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -P "$MAC_CERTIFICATE_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Windows-exported P12 files may omit the public Developer ID G2 intermediate.
curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 120 --retry 2 \
    'https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer' -o "$private_root/DeveloperIDG2CA.cer"
security import "$private_root/DeveloperIDG2CA.cer" -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
rm -f -- "$p12"
unset MAC_CERTIFICATE_P12_BASE64 keychain_password

security find-identity -v -p codesigning "$keychain" > "$private_root/identities.txt"
identity_sha="$(python3 - "$private_root/identities.txt" <<'PY'
import os, pathlib, re, sys
expected = os.environ['APPLE_SIGNING_IDENTITY']
team = os.environ['APPLE_TEAM_ID']
matches = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    match = re.search(r'\b([0-9A-Fa-f]{40})\s+"([^"]+)"', line)
    if match and match.group(2) == expected and expected.endswith('(' + team + ')'):
        matches.append(match.group(1))
if len(matches) != 1:
    raise SystemExit('Expected exactly one valid matching Developer ID Application identity for this team.')
print(matches[0])
PY
)"

# Sign the single nested Mach-O first, then seal the outer app. Java .class is data.
codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity_sha" "$app/Contents/MacOS/UdfPdf"
codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity_sha" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=4 "$app" > "$private_root/signature.txt" 2>&1
python3 - "$private_root/signature.txt" <<'PY'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
if 'Authority=Developer ID Application:' not in text or 'TeamIdentifier=' + os.environ['APPLE_TEAM_ID'] not in text:
    raise SystemExit('The bundle does not have the expected Developer ID team signature.')
if '(runtime)' not in text or 'Timestamp=' not in text:
    raise SystemExit('Hardened Runtime and secure timestamp are required.')
PY

# Runtime conversion tests run before credentials are introduced by the workflow.
# No app or UYAP process is started while signing/notarization secrets are present.
if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${original_keychains[@]}"
fi
security delete-keychain "$keychain"

asc_key="$private_root/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_PRIVATE_KEY_P8" > "$asc_key"
unset ASC_PRIVATE_KEY_P8
/usr/bin/openssl pkey -in "$asc_key" -noout >/dev/null 2>&1 || fail 'ASC_PRIVATE_KEY_P8 is not a valid unencrypted PEM private key.'
submission_zip="$private_root/submission.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
notary_json="$private_root/submission.json"
xcrun notarytool submit "$submission_zip" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --output-format json > "$notary_json" 2> "$private_root/submit.stderr" || fail 'Apple notarization upload failed.'
notary_id="$(python3 - "$notary_json" <<'PY'
import json, pathlib, re, sys
try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (ValueError, OSError):
    raise SystemExit('Apple did not return a complete notarization response. Inspect the tool error above.')
identifier = data.get('id', '')
if not re.fullmatch(r'[0-9a-fA-F-]{36}', identifier):
    raise SystemExit('Apple did not return a valid submission identifier.')
print(identifier)
PY
)"
printf 'Apple notarization submission %s uploaded.\n' "$notary_id"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Apple notarization submission: `%s` - uploaded; waiting for Apple.\n\n' "$notary_id" >> "$GITHUB_STEP_SUMMARY"
fi
set +e
xcrun notarytool wait "$notary_id" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --timeout 15m --output-format json > "$private_root/wait.json" 2> "$private_root/wait.stderr"
wait_result=$?
set -e
xcrun notarytool info "$notary_id" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --output-format json > "$private_root/status.json" 2> "$private_root/info.stderr" || fail 'Could not read Apple submission status; retain the submission ID above.'
notary_status="$(python3 - "$private_root/status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text()).get('status', 'Unknown')
print(status if status in {'Accepted', 'Invalid', 'In Progress', 'Rejected'} else 'Unknown')
PY
)"
printf 'Apple notarization submission %s: %s\n' "$notary_id" "$notary_status"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Apple notarization submission: `%s` — **%s**\n\n' "$notary_id" "$notary_status" >> "$GITHUB_STEP_SUMMARY"
fi
if [[ "$notary_status" == 'In Progress' ]]; then
    pending="$RUNNER_TEMP/notary-pending-output"
    [[ ! -e "$pending" ]] || fail 'Pending package output already exists.'
    mkdir "$pending"
    python3 - "$private_root/pending-metadata.json" "$notary_id" <<'PY'
import json, os, pathlib, platform, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'schemaVersion': 1, 'submissionId': sys.argv[2],
    'architecture': platform.machine(), 'sourceCommit': os.environ['MAC_SOURCE_SHA'],
    'teamId': os.environ['APPLE_TEAM_ID'],
}) + '\n')
PY
    script_root="$(cd "$(dirname "$0")" && pwd)"
    node "$script_root/notary-package.mjs" encrypt "$submission_zip" "$pending/envelope.json" "$private_root/pending-metadata.json"
    unset MAC_CERTIFICATE_PASSWORD
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'state=pending\nsubmission_id=%s\n' "$notary_id" >> "$GITHUB_OUTPUT"
    fi
    printf 'Apple is still processing. Exact signed package saved as an encrypted pending artifact.\n'
    exit 0
fi
unset MAC_CERTIFICATE_PASSWORD
if [[ "$notary_status" != 'In Progress' ]]; then
    xcrun notarytool log "$notary_id" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" "$private_root/notary-log.json" >/dev/null
    python3 - "$private_root/notary-log.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
issues = data.get('issues') or []
if issues:
    for issue in issues:
        print('Apple notarization issue:', issue.get('severity', 'unknown'), issue.get('message', 'No message'))
    raise SystemExit('Review Apple notarization issues before distributing this build.')
PY
fi
[[ "$notary_status" == Accepted ]] || fail 'Apple has not accepted this submission. No distributable package was produced.'
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"

architecture="$(uname -m)"
archive_name="Toplu-UDF-PDF-Mac-1.04-${architecture}-notarized.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive_name"
(
    cd "$output"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
python3 - "$output/notarization.json" "$notary_id" "$architecture" <<'PY'
import json, os, pathlib, sys
path, submission, architecture = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    'status': 'Accepted', 'submissionId': submission, 'architecture': architecture,
    'sourceCommit': os.environ['MAC_SOURCE_SHA'], 'version': '1.0.4',
    'signature': 'Developer ID Application', 'hardenedRuntime': True,
    'staplerValidated': True, 'gatekeeperAssessmentPassed': True,
}, indent=2) + '\n')
PY
printf 'Notarized package: %s\n' "$archive_name"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'state=accepted\nsubmission_id=%s\n' "$notary_id" >> "$GITHUB_OUTPUT"
fi
