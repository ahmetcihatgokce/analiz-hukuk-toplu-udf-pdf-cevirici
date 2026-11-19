#!/usr/bin/env python3
"""Generate public, synthetic UDF fixtures; no UYAP or private documents needed.

The baseline mirrors the already verified official UYAP synthetic fixture.  The
remaining cases exercise the native reader's explicit supported XML contract;
they do not establish compatibility with arbitrary real-world UDF documents.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zipfile
import zlib


def utf16_length(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def red_png(width: int = 96, height: int = 48) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)

    pixels = b"".join(b"\0" + bytes([230, 20, 30]) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels))
            + chunk(b"IEND", b""))


class Document:
    def __init__(self) -> None:
        self.parts: list[str] = []
        self.root = ET.Element("template", {"format_id": "1.8"})
        self.content = ET.SubElement(self.root, "content")
        properties = ET.SubElement(self.root, "properties")
        ET.SubElement(properties, "pageFormat", {
            "mediaSizeName": "1", "paperOrientation": "1",
            "leftMargin": "42.5", "rightMargin": "42.5",
            "topMargin": "42.5", "bottomMargin": "42.5",
            "headerFOffset": "20.0", "footerFOffset": "20.0",
        })
        self.elements = ET.SubElement(self.root, "elements", {"resolver": "hvl-default"})
        styles = ET.SubElement(self.root, "styles")
        ET.SubElement(styles, "style", {"name": "hvl-default", "family": "Times New Roman", "size": "12"})

    def paragraph(self, value: str, parent: ET.Element | None = None,
                  paragraph_attrs: dict[str, str] | None = None,
                  text_attrs: dict[str, str] | None = None) -> ET.Element:
        offset = utf16_length("".join(self.parts))
        self.parts.append(value)
        paragraph = ET.SubElement(self.elements if parent is None else parent, "paragraph", paragraph_attrs or {})
        ET.SubElement(paragraph, "content", {
            "startOffset": str(offset), "length": str(utf16_length(value)), **(text_attrs or {}),
        })
        return paragraph

    def xml(self) -> bytes:
        self.content.text = "".join(self.parts)
        return ET.tostring(self.root, encoding="utf-8", xml_declaration=True)


def write_udf(path: Path, content: bytes, extra: list[tuple[str, bytes]] | None = None) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, value in [("content.xml", content), *(extra or [])]:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o600 << 16
            info.flag_bits |= 0x800
            archive.writestr(info, value)


def generate(directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    manifest: dict = {"schemaVersion": 1, "syntheticOnly": True, "fixtures": []}

    def good(name: str, document: Document, phrases: list[str], pages: int | None = None) -> bytes:
        xml = document.xml()
        write_udf(directory / name, xml)
        manifest["fixtures"].append({"file": name, "result": "success", "phrases": phrases,
                                     "pageCount": pages, "width": 595.28, "height": 841.89})
        return xml

    baseline = Document()
    baseline.paragraph("Analiz Hukuk macOS dönüşüm testi.\n", paragraph_attrs={"Alignment": "1"}, text_attrs={"bold": "true"})
    baseline.paragraph("Türkçe: Çağrı, Şule, Iğde, Özgür, Ümit, ıİşŞğĞüÜöÖçÇ.\n")
    baseline.paragraph("Bu dosya sentetik test verisidir.\n")
    baseline_xml = good("baseline.udf", baseline, ["Analiz Hukuk", "Türkçe", "sentetik test"], 1)

    unicode_document = Document()
    unicode_document.paragraph("UTF16 😀 Çağrı İĞÜŞÖÇ ıiğüşöç END_SENTINEL\n")
    good("utf16.udf", unicode_document, ["UTF16", "Çağrı", "END_SENTINEL"], 1)

    styled = Document()
    styled.paragraph("BOLD_SENTINEL\n", text_attrs={"bold": "true", "size": "18"})
    styled.paragraph("ITALIC_SENTINEL\n", text_attrs={"italic": "true", "size": "12"})
    # Java's Color.getRGB() serializes opaque red as signed ARGB -65536.
    styled.paragraph("UNDERLINE_SENTINEL\n", text_attrs={"underline": "true", "foreground": "-65536"})
    good("styles.udf", styled, ["BOLD_SENTINEL", "ITALIC_SENTINEL", "UNDERLINE_SENTINEL"], 1)

    table_document = Document()
    table_document.paragraph("TABLE_START\n")
    table = ET.SubElement(table_document.elements, "table", {"border": "borderAll", "columnWidths": "120,220"})
    for row_values in [("CELL_A1\n", "CELL_B1\n"), ("CELL_A2\n", "CELL_B2\n")]:
        row = ET.SubElement(table, "row")
        for value in row_values:
            cell = ET.SubElement(row, "cell", {"columnSpan": "1", "rowSpan": "1"})
            table_document.paragraph(value, parent=cell)
    table_document.paragraph("TABLE_END\n")
    good("table.udf", table_document, ["TABLE_START", "CELL_A1", "CELL_B1", "CELL_A2", "CELL_B2", "TABLE_END"], 1)

    image_document = Document()
    image_document.paragraph("IMAGE_SENTINEL\n")
    ET.SubElement(image_document.elements, "image", {
        "width": "96", "height": "48", "imageData": base64.b64encode(red_png()).decode("ascii"),
    })
    good("image.udf", image_document, ["IMAGE_SENTINEL"], 1)

    paginated = Document()
    paginated.paragraph("FIRST_PAGE_SENTINEL\n")
    ET.SubElement(paginated.elements, "pageBreak")
    paginated.paragraph("SECOND_PAGE_SENTINEL\n")
    header = ET.SubElement(paginated.elements, "header")
    paginated.paragraph("HEADER_SENTINEL\n", parent=header)
    footer = ET.SubElement(paginated.elements, "footer")
    paginated.paragraph("FOOTER_SENTINEL\n", parent=footer)
    good("headers-pagebreak.udf", paginated, ["FIRST_PAGE_SENTINEL", "SECOND_PAGE_SENTINEL", "HEADER_SENTINEL", "FOOTER_SENTINEL"], 2)

    long_document = Document()
    for index in range(160):
        long_document.paragraph(f"LONG_LINE_{index:03d} Türkçe doğrulama.\n")
    good("long-pagination.udf", long_document, [f"LONG_LINE_{i:03d}" for i in range(160)])

    invalid_xml = {
        "malformed.udf": b"<template><content>unclosed",
        "doctype.udf": b'<!DOCTYPE template [<!ENTITY secret "blocked">]>' + baseline_xml.split(b"?>", 1)[1],
        "external-entity.udf": b'<!DOCTYPE template SYSTEM "https://example.invalid/blocked.dtd">' + baseline_xml.split(b"?>", 1)[1],
        "unknown-element.udf": baseline_xml.replace(b"</elements>", b"<unsupportedCriticalNode/></elements>"),
        "unknown-attribute.udf": baseline_xml.replace(b'<paragraph Alignment="1"', b'<paragraph Alignment="1" UnsupportedCriticalAttribute="yes"'),
        "unreferenced-content.udf": baseline_xml.replace(b"</content>", b"UNREFERENCED_TEXT</content>", 1),
        "out-of-range.udf": baseline_xml.replace(b'length="34"', b'length="99999999"', 1),
        "invalid-font-size.udf": baseline_xml.replace(b'size="12"', b'size="NaN"', 1),
        "invalid-margin.udf": baseline_xml.replace(b'leftMargin="42.5"', b'leftMargin="-42.5"', 1),
    }
    for name, xml in invalid_xml.items():
        write_udf(directory / name, xml)
        manifest["fixtures"].append({"file": name, "result": "reject"})
    write_udf(directory / "archive-traversal.udf", baseline_xml, [("../escaped.xml", b"blocked")])
    manifest["fixtures"].append({"file": "archive-traversal.udf", "result": "reject"})
    (directory / "invalid-archive.udf").write_bytes(b"not a ZIP archive")
    manifest["fixtures"].append({"file": "invalid-archive.udf", "result": "reject"})

    (directory / "expectations.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = generate(args.directory)
    print(f"Generated {len(result['fixtures'])} synthetic UDF fixtures in {args.directory}")
