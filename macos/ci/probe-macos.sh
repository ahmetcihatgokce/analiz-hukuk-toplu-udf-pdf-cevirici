#!/bin/bash
set -euo pipefail

# UYAP's own Mac download is used for CI testing only. Never upload the
# extracted application, its Java runtime, or its JARs as workflow artifacts.
script_dir="$(cd "$(dirname "$0")" && pwd)"
report_dir="${1:-$script_dir/report}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
scratch_base="$(cd "${RUNNER_TEMP:-${TMPDIR:-/tmp}}" && pwd)"
probe_root="$(mktemp -d "$scratch_base/uyap-mac-probe.XXXXXX")"
mount_point="$probe_root/mounted"
mounted=0
cleanup() {
    if [ "${UYAP_PROBE_KEEP_RUNTIME:-0}" = 1 ]; then
        return
    fi
    if [ "$mounted" = 1 ]; then
        hdiutil detach "$mount_point" -quiet || true
    fi
    case "$probe_root" in
        "$scratch_base"/uyap-mac-probe.*) rm -rf -- "$probe_root" ;;
        *) echo 'Refusing cleanup outside the generated probe directory' >&2 ;;
    esac
}
trap cleanup EXIT

find_editor_jar() {
    python3 - "$1" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
known = next(root.rglob('editor_lib.jar'), None)
if known is not None:
    print(known)
else:
    target = 'tr/com/havelsan/uyap/system/editor/utils/tray/TrayUtils.class'
    for candidate in root.rglob('*.jar'):
        try:
            with zipfile.ZipFile(candidate) as archive:
                if target in archive.namelist():
                    print(candidate)
                    break
        except (OSError, zipfile.BadZipFile):
            continue
PY
}

case "$(uname -m)" in
    arm64) download_url='https://rayp.adalet.gov.tr/resimler/2/dosya/UyapDokumanEditoru-AppleSilicon-5.4.21.zip' ;;
    x86_64) download_url='https://rayp.adalet.gov.tr/resimler/2/dosya/UyapDokumanEditoru-Intel-5.4.21.zip' ;;
    *) echo 'Unsupported CI architecture' >&2; exit 1 ;;
esac
printf 'source=%s\narchitecture=%s\n' "$download_url" "$(uname -m)" > "$report_dir/environment.txt"
sw_vers >> "$report_dir/environment.txt"
curl --fail --location --retry 3 --connect-timeout 20 --max-time 360 \
    "$download_url" -o "$probe_root/uyap.zip"
shasum -a 256 "$probe_root/uyap.zip" >> "$report_dir/environment.txt"
ditto -x -k "$probe_root/uyap.zip" "$probe_root/extracted"
search_root="$probe_root/extracted"

# Current downloads contain the app. Handle a disk image or flat package if
# the vendor changes the ZIP's inner packaging while keeping its URL.
editor_jar="$(find_editor_jar "$search_root")"
if [ -z "$editor_jar" ]; then
    disk_image="$(find "$search_root" -type f -name '*.dmg' -print -quit)"
    if [ -n "$disk_image" ]; then
        mkdir -p "$mount_point"
        hdiutil attach "$disk_image" -nobrowse -readonly -mountpoint "$mount_point" -quiet
        mounted=1
        search_root="$mount_point"
        editor_jar="$(find_editor_jar "$search_root")"
    fi
fi
if [ -z "$editor_jar" ]; then
    package="$(find "$search_root" -name '*.pkg' -print -quit)"
    if [ -n "$package" ]; then
        pkgutil --expand-full "$package" "$probe_root/expanded-package"
        search_root="$probe_root/expanded-package"
        editor_jar="$(find_editor_jar "$search_root")"
    fi
fi
if [ -z "$editor_jar" ]; then
    find "$search_root" -maxdepth 5 -type f | sed "s|$probe_root|<temporary>|g" > "$report_dir/package-layout.txt"
    echo 'Could not find editor_lib.jar in official Mac package' >&2
    exit 1
fi

app_root="${editor_jar%%.app/*}.app"
if [ ! -d "$app_root" ]; then
    app_root="$search_root"
fi
find "$app_root" -type f \( -name '*.jar' -o -name Info.plist -o -name release \) \
    | sed "s|$probe_root|<temporary>|g" > "$report_dir/package-layout.txt"

java_path=''
while IFS= read -r candidate; do
    if [ -x "$candidate" ] && "$candidate" -version > "$probe_root/java-version.txt" 2>&1; then
        java_path="$candidate"
        break
    fi
done < <(find "$app_root" \( -type f -o -type l \) -path '*/bin/java' -print)
if [ -z "$java_path" ]; then
    echo 'Official Mac package does not contain a runnable Java runtime' >&2
    exit 1
fi
cp "$probe_root/java-version.txt" "$report_dir/java-version.txt"
printf 'java=%s\neditor=%s\n' "${java_path#"$probe_root"/}" "${editor_jar#"$probe_root"/}" >> "$report_dir/environment.txt"

mkdir -p "$probe_root/classes" "$probe_root/user-home"
javac -encoding UTF-8 --release 8 -d "$probe_root/classes" "$script_dir/UyapMacProbe.java"
python3 - "$app_root" "$probe_root/classes" "$probe_root" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
import zipfile

app_root, classes, probe_root = map(pathlib.Path, sys.argv[1:])
jars = sorted(str(path) for path in app_root.rglob('*.jar'))
(probe_root / 'classpath.txt').write_text(':'.join([str(classes), *jars]), encoding='utf-8')
lines = [
    'Analiz Hukuk macOS dönüşüm testi.\n',
    'Türkçe: Çağrı, Şule, İğde, Özgür, Ümit, ıİşŞğĞçÇöÖüÜ.\n',
    'Bu dosya sentetik test verisidir.\n',
]
template = ET.Element('template', {'format_id': '1.8'})
ET.SubElement(template, 'content').text = ''.join(lines)
properties = ET.SubElement(template, 'properties')
ET.SubElement(properties, 'pageFormat', {
    'mediaSizeName': '1', 'leftMargin': '42.5', 'rightMargin': '42.5',
    'topMargin': '42.5', 'bottomMargin': '42.5', 'paperOrientation': '1',
    'headerFOffset': '20.0', 'footerFOffset': '20.0',
})
elements = ET.SubElement(template, 'elements', {'resolver': 'hvl-default'})
offset = 0
for index, line in enumerate(lines):
    paragraph = ET.SubElement(elements, 'paragraph', {'Alignment': '1' if index == 0 else '0'})
    attributes = {'startOffset': str(offset), 'length': str(len(line))}
    if index == 0:
        attributes['bold'] = 'true'
    ET.SubElement(paragraph, 'content', attributes)
    offset += len(line)
styles = ET.SubElement(template, 'styles')
ET.SubElement(styles, 'style', {'name': 'hvl-default', 'family': 'Times New Roman', 'size': '12'})
with zipfile.ZipFile(probe_root / 'sentetik-örnek.udf', 'w', zipfile.ZIP_DEFLATED) as fixture:
    fixture.writestr('content.xml', ET.tostring(template, encoding='utf-8', xml_declaration=True))
PY
classpath="$(cat "$probe_root/classpath.txt")"
cp "$probe_root/sentetik-örnek.udf" "$report_dir/sentetik-ornek.udf"
if [ "${UYAP_PROBE_KEEP_RUNTIME:-0}" = 1 ]; then
    printf 'export UYAP_EDITOR_APP=%q\nexport UYAP_TEST_JAVA=%q\nexport UYAP_TEST_CLASSPATH=%q\n' \
        "$app_root" "$java_path" "$classpath" > "$probe_root/runtime.env"
    printf 'runtimeEnv=%s\n' "$probe_root/runtime.env" >> "$report_dir/environment.txt"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'UYAP_EDITOR_APP=%s\nUYAP_TEST_JAVA=%s\nUYAP_TEST_CLASSPATH=%s\n' \
            "$app_root" "$java_path" "$classpath" >> "$GITHUB_ENV"
    fi
fi
set +e
python3 - "$java_path" "$probe_root" "$classpath" "$report_dir" <<'PY'
import pathlib
import subprocess
import sys

java, temporary, classpath, report = sys.argv[1:]
report_path = pathlib.Path(report)
command = [
    java, '-Xmx1024m', '-Djava.awt.headless=true', '-Dsun.java2d.uiScale=1',
    '-Duser.home=' + temporary + '/user-home', '-Djavax.xml.accessExternalDTD=',
    '-Djavax.xml.accessExternalSchema=', '-cp', classpath, 'UyapMacProbe',
    temporary + '/sentetik-örnek.udf', str(report_path / 'sentetik-ornek.pdf'), report,
]
with (report_path / 'conversion.log').open('w', encoding='utf-8') as log:
    try:
        completed = subprocess.run(command, cwd=temporary, stdout=log,
                                   stderr=subprocess.STDOUT, timeout=180, check=False)
        status = completed.returncode
    except subprocess.TimeoutExpired:
        log.write('\nUYAP_MAC_EXPORT_TIMEOUT after 180 seconds\n')
        status = 124
sys.exit(status)
PY
conversion_status=$?
set -e
cat "$report_dir/conversion.log"
printf 'exitCode=%s\n' "$conversion_status" >> "$report_dir/environment.txt"
exit "$conversion_status"
