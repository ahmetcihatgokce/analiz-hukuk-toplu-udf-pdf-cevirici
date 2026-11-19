#!/usr/bin/env python3
"""Stage exactly eight official-writer fixtures plus one known oracle negative.

The positive cases must come from generate-canonical.js running against the
installed official UYAP public writer/editor actions. Candidate handwritten
positive fixtures are deliberately not merged into the official fidelity gate.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET
import zipfile


CANONICAL_NAMES = {
    "canonical-baseline.udf", "canonical-styles.udf", "canonical-tabs.udf",
    "canonical-table.udf", "canonical-image.udf", "canonical-page-break.udf",
    "canonical-headers-pagebreak.udf", "canonical-long-pagination.udf",
}


def safe_fixture(path: Path) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError("Canonical fixture missing, symbolic link, or too large: " + path.name)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) != 1 or entries[0].filename != "content.xml" or entries[0].file_size > 1024 * 1024:
            raise ValueError("Canonical fixture has an unexpected ZIP structure: " + path.name)
        if archive.testzip() is not None:
            raise ValueError("Canonical fixture CRC failed: " + path.name)


def emoji_oracle_negative(path: Path) -> dict:
    text = "UTF16 😀 Çağrı İĞÜŞÖÇ ıiğüşöç END_SENTINEL\n"
    root = ET.Element("template", {"format_id": "1.8"})
    ET.SubElement(root, "content").text = text
    properties = ET.SubElement(root, "properties")
    ET.SubElement(properties, "pageFormat", {
        "mediaSizeName": "1", "paperOrientation": "1", "leftMargin": "42.5",
        "rightMargin": "42.5", "topMargin": "42.5", "bottomMargin": "42.5",
        "headerFOffset": "20.0", "footerFOffset": "20.0",
    })
    elements = ET.SubElement(root, "elements", {"resolver": "hvl-default"})
    paragraph = ET.SubElement(elements, "paragraph")
    ET.SubElement(paragraph, "content", {"startOffset": "0", "length": str(len(text.encode("utf-16-le")) // 2)})
    styles = ET.SubElement(root, "styles")
    ET.SubElement(styles, "style", {"name": "hvl-default", "family": "Times New Roman", "size": "12"})
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("content.xml", ET.tostring(root, encoding="utf-8", xml_declaration=True))
    return {
        "file": path.name, "result": "oracle-reject",
        "expectedOracleError": "0xd83d is not a legal XML character",
        "schemaStatus": "official-JDOM-0.9-supplementary-character-limitation",
        "compatibilityValidated": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canonical", required=True, type=Path)
    parser.add_argument("--manifest", type=Path, help="Defaults to canonical/expectations.json")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    manifest_path = args.manifest or args.canonical / "expectations.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or manifest.get("syntheticOnly") is not True:
        raise ValueError("Expected an official-generated synthetic manifest")
    fixtures = manifest.get("fixtures", [])
    if len(fixtures) != 8 or {item["file"] for item in fixtures} != CANONICAL_NAMES:
        raise ValueError("The official comparison requires all eight canonical cases")
    for item in fixtures:
        if item.get("result") != "success" or item.get("schemaStatus") != "official-writer-serialized":
            raise ValueError("Handwritten or unvalidated positive fixtures cannot enter the official gate")
        safe_fixture(args.canonical / item["file"])
    args.output.mkdir(parents=True, exist_ok=True)
    for item in fixtures:
        source = args.canonical / item["file"]
        destination = args.output / item["file"]
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)
    staged = dict(manifest)
    staged["fixtures"] = list(fixtures)
    staged["fixtures"].append(emoji_oracle_negative(args.output / "oracle-unsupported-emoji.udf"))
    staged["scope"] = ("Eight official UYAP writer/action serialized synthetic positives plus a separately asserted "
                       "JDOM supplementary-character rejection. This is not arbitrary real-world UDF coverage.")
    (args.output / "expectations.json").write_text(json.dumps(staged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Prepared eight official-serialized positive cases and one retained oracle-negative regression")


if __name__ == "__main__":
    main()
