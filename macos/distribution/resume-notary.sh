#!/bin/bash
# Resume an existing Apple submission. This script never uploads or signs code.
set -euo pipefail
set +x
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'Usage: resume-notary.sh <envelope.json> <new output directory>'
[[ "$(uname -s)" == Darwin ]] || fail 'Resuming requires a macOS runner.'
for variable in RUNNER_TEMP MAC_CERTIFICATE_PASSWORD APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_P8 APPROVED_SOURCE_SHA; do
    [[ -n "${!variable:-}" ]] || fail "Required input is missing: $variable"
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid Team ID.'
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid API key ID.'
[[ "$ASC_ISSUER_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Invalid issuer UUID.'
[[ "$APPROVED_SOURCE_SHA" =~ ^[[:xdigit:]]{40}$ ]] || fail 'Invalid approved source SHA.'
[[ -f "$1" && ! -L "$1" ]] || fail 'Expected an encrypted pending envelope.'
[[ ! -e "$2" ]] || fail 'Output directory already exists.'
mkdir -p "$2"
output="$(cd "$2" && pwd)"
private_root="$(mktemp -d "$RUNNER_TEMP/mac-resume.XXXXXX")"
cleanup() {
    local result=$?
    set +e
    if [[ "$private_root" == "$RUNNER_TEMP"/mac-resume.* && ! -L "$private_root" ]]; then
        rm -rf -- "$private_root"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
script_root="$(cd "$(dirname "$0")" && pwd)"
signed_zip="$private_root/submission.zip"
metadata="$private_root/metadata.json"
node "$script_root/notary-package.mjs" decrypt "$1" "$signed_zip" "$metadata"
unset MAC_CERTIFICATE_PASSWORD
notary_id="$(python3 - "$metadata" <<'PY'
import json, os, pathlib, platform, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if data['teamId'] != os.environ['APPLE_TEAM_ID']:
    raise SystemExit('Pending package belongs to another Apple team.')
if data['architecture'] != platform.machine():
    raise SystemExit('Pending package architecture does not match this runner.')
if data['sourceCommit'] != os.environ['APPROVED_SOURCE_SHA']:
    raise SystemExit('Pending package source is not the reviewed source commit.')
print(data['submissionId'])
PY
)"
asc_key="$private_root/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_PRIVATE_KEY_P8" > "$asc_key"
unset ASC_PRIVATE_KEY_P8
/usr/bin/openssl pkey -in "$asc_key" -noout >/dev/null 2>&1 || fail 'Invalid notarization private key.'
xcrun notarytool info "$notary_id" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --output-format json > "$private_root/status.json" 2> "$private_root/info.stderr" || fail 'Could not read Apple submission status.'
notary_status="$(python3 - "$private_root/status.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text()).get('status', 'Unknown')
print(value if value in {'Accepted', 'Invalid', 'Rejected', 'In Progress'} else 'Unknown')
PY
)"
printf 'Existing Apple submission %s: %s\n' "$notary_id" "$notary_status"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Existing Apple submission: `%s` - **%s**. No new upload was made.\n\n' "$notary_id" "$notary_status" >> "$GITHUB_STEP_SUMMARY"
fi
if [[ "$notary_status" == 'In Progress' ]]; then
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'state=pending\nsubmission_id=%s\n' "$notary_id" >> "$GITHUB_OUTPUT"
    fi
    printf 'Apple is still processing. Retain the original encrypted pending artifact.\n'
    exit 0
fi
xcrun notarytool log "$notary_id" --key "$asc_key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" "$private_root/notary-log.json" >/dev/null
python3 - "$private_root/notary-log.json" <<'PY'
import json, pathlib, sys
for issue in json.loads(pathlib.Path(sys.argv[1]).read_text()).get('issues') or []:
    print('Apple notarization issue:', issue.get('severity', 'unknown'), issue.get('message', 'No message'))
    raise SystemExit('Review Apple issues before distributing this package.')
PY
[[ "$notary_status" == Accepted ]] || fail 'Apple did not accept this submission. No distribution was produced.'
python3 - "$signed_zip" <<'PY'
import pathlib, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    if len(entries) > 10000 or sum(e.file_size for e in entries) > 512 * 1024 * 1024:
        raise SystemExit('Pending app archive exceeds extraction limits.')
    for entry in entries:
        name = pathlib.PurePosixPath(entry.filename)
        if (name.is_absolute() or '..' in name.parts or '\\' in entry.filename
                or not name.parts or name.parts[0] not in {'Toplu UDF PDF Cevirici.app', '__MACOSX'}
                or stat.S_ISLNK(entry.external_attr >> 16)):
            raise SystemExit('Pending app archive contains an unsafe path or link.')
PY
unpacked="$private_root/unpacked"
mkdir "$unpacked"
ditto -x -k "$signed_zip" "$unpacked"
app="$unpacked/Toplu UDF PDF Cevirici.app"
[[ -f "$app/Contents/MacOS/UdfPdf" ]] || fail 'Expected converter app was not present.'
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=4 "$app" > "$private_root/signature.txt" 2>&1
python3 - "$private_root/signature.txt" <<'PY'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
if ('Authority=Developer ID Application:' not in text
        or 'TeamIdentifier=' + os.environ['APPLE_TEAM_ID'] not in text
        or '(runtime)' not in text or 'Timestamp=' not in text):
    raise SystemExit('Pending app lacks the expected Developer ID signature and hardened runtime.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"
architecture="$(uname -m)"
archive_name="Toplu-UDF-PDF-Mac-1.04-${architecture}-notarized.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive_name"
(cd "$output" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
python3 - "$output/notarization.json" "$notary_id" "$metadata" <<'PY'
import json, pathlib, sys
metadata = json.loads(pathlib.Path(sys.argv[3]).read_text())
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'status': 'Accepted', 'submissionId': sys.argv[2],
    'architecture': metadata['architecture'], 'sourceCommit': metadata['sourceCommit'],
    'version': '1.0.4', 'signature': 'Developer ID Application',
    'hardenedRuntime': True, 'staplerValidated': True,
    'gatekeeperAssessmentPassed': True, 'resumedExistingSubmission': True,
}, indent=2) + '\n')
PY
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'state=accepted\nsubmission_id=%s\n' "$notary_id" >> "$GITHUB_OUTPUT"
fi
printf 'Recovered notarized package: %s\n' "$archive_name"
