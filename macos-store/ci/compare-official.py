#!/usr/bin/env python3
"""Compare synthetic native UDF output with the installed official UYAP oracle.

Run only on a disposable macOS CI runner, before loading signing credentials.
The Java runtime, JARs, bridge classes and this helper are never app resources.
This command deliberately fails when an oracle fixture fails or when any
comparison differs. A synthetic fixture accepted by our own reader is not proof
that the fixture represents the official format or preserves its layout.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


METRICS_SWIFT = r'''
import AppKit
import Darwin
import Foundation
import PDFKit

enum MetricsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

func normalize(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func colorBounds(_ page: PDFPage) throws -> [Double]? {
    let media = page.bounds(for: .mediaBox)
    let image = page.thumbnail(of: NSSize(width: media.width, height: media.height), for: .mediaBox)
    guard let encoded = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: encoded) else {
        throw MetricsError.message("Cannot rasterize PDF for image comparison")
    }
    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.6 && color.greenComponent < 0.35 && color.blueComponent < 0.35 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let scaleX = Double(media.width) / Double(bitmap.pixelsWide)
    let scaleY = Double(media.height) / Double(bitmap.pixelsHigh)
    return [Double(minX) * scaleX, Double(minY) * scaleY,
            Double(maxX - minX + 1) * scaleX, Double(maxY - minY + 1) * scaleY]
}

func run() throws {
    guard CommandLine.arguments.count == 3,
          let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])),
          document.pageCount > 0 else { throw MetricsError.message("Cannot open comparison PDF") }
    let phrasesData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let phrases = try JSONDecoder().decode([String].self, from: phrasesData)
    var pages: [[String: Any]] = []
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { throw MetricsError.message("Missing PDF page") }
        let media = page.bounds(for: .mediaBox)
        var item: [String: Any] = ["width": media.width, "height": media.height,
                                    "text": normalize(page.string ?? "")]
        if let red = try colorBounds(page) { item["redBounds"] = red }
        else { item["redBounds"] = NSNull() }
        pages.append(item)
    }
    var selections: [[String: Any]] = []
    for phrase in phrases {
        let matches = document.findString(phrase, withOptions: [])
        var locations: [[String: Any]] = []
        for selection in matches {
            for page in selection.pages {
                let bounds = selection.bounds(for: page)
                var location: [String: Any] = ["page": document.index(for: page),
                    "bounds": [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]]
                if let text = selection.attributedString, text.length > 0,
                   let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    location["fontSize"] = font.pointSize
                    let traits = NSFontManager.shared.traits(of: font)
                    location["bold"] = traits.contains(.boldFontMask)
                    location["italic"] = traits.contains(.italicFontMask)
                }
                locations.append(location)
            }
        }
        selections.append(["phrase": phrase, "locations": locations])
    }
    let result: [String: Any] = ["pageCount": document.pageCount, "pages": pages, "phrases": selections]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

do { try run() }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
'''


def invoke(command: list[str], *, timeout: int, cwd: Path | None = None) -> subprocess.CompletedProcess:
    # Commands contain public fixture paths and official runtime paths only.
    return subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)


def write_log(path: Path, result: subprocess.CompletedProcess) -> None:
    path.write_text(result.stdout, encoding="utf-8")


def compare_numbers(expected: list, actual: list, tolerance: float) -> bool:
    return (len(expected) == len(actual)
            and all(isinstance(a, (float, int)) and isinstance(b, (float, int))
                    and math.isfinite(a) and math.isfinite(b) and abs(a - b) <= tolerance
                    for a, b in zip(expected, actual)))


def compare_metrics(oracle: dict, native: dict, *, tolerance: float) -> list[str]:
    problems = []
    if oracle["pageCount"] != native["pageCount"]:
        problems.append(f"page count: official={oracle['pageCount']} native={native['pageCount']}")
    for index, (a, b) in enumerate(zip(oracle["pages"], native["pages"])):
        prefix = f"page {index + 1}"
        if not compare_numbers([a["width"], a["height"]], [b["width"], b["height"]], 1):
            problems.append(prefix + ": paper dimensions differ")
        if a["text"] != b["text"]:
            problems.append(prefix + ": normalized extracted text differs")
        if a["redBounds"] is None and b["redBounds"] is None:
            pass
        elif a["redBounds"] is None or b["redBounds"] is None:
            problems.append(prefix + ": colored image/text disappeared")
        elif not compare_numbers(a["redBounds"], b["redBounds"], tolerance):
            problems.append(prefix + ": colored image/text bounds differ")
    native_phrases = {item["phrase"]: item["locations"] for item in native["phrases"]}
    for item in oracle["phrases"]:
        phrase = item["phrase"]
        official_locations = item["locations"]
        native_locations = native_phrases.get(phrase, [])
        if not official_locations:
            problems.append(f"oracle fixture did not render required phrase: {phrase}")
            continue
        if len(official_locations) != len(native_locations):
            problems.append(f"phrase occurrence count differs: {phrase}")
            continue
        for ordinal, (a, b) in enumerate(zip(official_locations, native_locations)):
            label = f"phrase {phrase!r} occurrence {ordinal + 1}"
            if a["page"] != b["page"]:
                problems.append(label + ": page differs")
            if not compare_numbers(a["bounds"], b["bounds"], tolerance):
                problems.append(label + ": position/size differs")
            for key in ["bold", "italic"]:
                if a.get(key) != b.get(key):
                    problems.append(label + f": {key} differs or font metadata unavailable")
            if "fontSize" not in a or "fontSize" not in b or abs(a["fontSize"] - b["fontSize"]) > 0.5:
                problems.append(label + ": font size differs or unavailable")
    return problems


def print_diagnostics(name: str, oracle: dict, native: dict) -> None:
    """Keep enough public synthetic measurements in logs to diagnose CI failures."""
    def summary(metrics: dict) -> dict:
        selected = metrics["phrases"][:3]
        if len(metrics["phrases"]) > 3:
            selected = selected + metrics["phrases"][-1:]
        return {
            "pageCount": metrics["pageCount"],
            "pages": [{"width": page["width"], "height": page["height"],
                       "redBounds": page["redBounds"], "textCharacters": len(page["text"])}
                      for page in metrics["pages"][:8]],
            "phrases": [{"phrase": item["phrase"], "locations": item["locations"][:3]}
                        for item in selected],
        }
    print("DIAG " + json.dumps({"file": name, "official": summary(oracle), "native": summary(native)},
                               ensure_ascii=False, separators=(",", ":")), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True, help="native-fixtures.py output folder")
    parser.add_argument("--native", type=Path, required=True, help="STORE_TESTING native app executable")
    parser.add_argument("--native-work-root", type=Path, required=True, help="A writable folder within this test app's sandbox container")
    parser.add_argument("--bridge-source", type=Path, required=True, help="Original CI-only UyapBridge.java source")
    parser.add_argument("--output", type=Path, required=True, help="Synthetic diagnostic PDFs, metrics and logs")
    parser.add_argument("--java", default=os.environ.get("UYAP_TEST_JAVA"), help="Official UYAP bundled runtime from probe")
    parser.add_argument("--classpath", default=os.environ.get("UYAP_TEST_CLASSPATH"), help="Official UYAP CI classpath from probe")
    parser.add_argument("--bounds-tolerance", type=float, default=3.0, help="Maximum phrase/image bounds delta in PDF points")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Official comparison requires a native macOS CI runner")
    if not args.java or not args.classpath:
        parser.error("Run the official UYAP CI probe first to provide UYAP_TEST_JAVA and UYAP_TEST_CLASSPATH")
    if not math.isfinite(args.bounds_tolerance) or not 0 <= args.bounds_tolerance <= 5:
        parser.error("Bounds tolerance must be between zero and five PDF points")
    for path in [args.native, args.bridge_source, args.fixtures / "expectations.json"]:
        if not path.is_file() or path.is_symlink():
            parser.error("Missing or symbolic-link comparison input: " + str(path))

    args.output.mkdir(parents=True, exist_ok=True)
    args.native_work_root.mkdir(parents=True, exist_ok=True)
    native_root = args.native_work_root / ("official-comparison-" + uuid.uuid4().hex)
    native_root.mkdir(mode=0o700)
    manifest = json.loads((args.fixtures / "expectations.json").read_text(encoding="utf-8"))
    if manifest.get("syntheticOnly") is not True:
        parser.error("Only generated public synthetic fixtures may be used in this CI comparison")
    fixtures = [item for item in manifest["fixtures"] if item["result"] == "success"]
    results = []
    with tempfile.TemporaryDirectory(prefix="udf-oracle-tools-") as temporary:
        scratch = Path(temporary)
        classes = scratch / "classes"
        classes.mkdir()
        bridge_compile = invoke(["javac", "--release", "8", "-encoding", "UTF-8", "-d", str(classes), str(args.bridge_source)], timeout=90)
        write_log(args.output / "oracle-compile.log", bridge_compile)
        if bridge_compile.returncode:
            raise RuntimeError("CI-only official bridge did not compile; see oracle-compile.log")
        metrics_source = scratch / "PDFMetrics.swift"
        metrics_source.write_text(METRICS_SWIFT, encoding="utf-8")
        metrics_binary = scratch / "pdf-metrics"
        metrics_compile = invoke(["swiftc", "-O", "-framework", "AppKit", "-framework", "PDFKit", str(metrics_source), "-o", str(metrics_binary)], timeout=120)
        write_log(args.output / "metrics-compile.log", metrics_compile)
        if metrics_compile.returncode:
            raise RuntimeError("PDF metrics helper did not compile; see metrics-compile.log")
        for item in fixtures:
            name = item["file"]
            if Path(name).name != name or not name.endswith(".udf"):
                raise RuntimeError("Unexpected synthetic fixture name")
            fixture = args.fixtures / name
            if fixture.is_symlink() or not fixture.is_file():
                raise RuntimeError("Synthetic fixture is missing or a symbolic link")
            case = args.output / fixture.stem
            case.mkdir(exist_ok=True)
            native_case = native_root / fixture.stem
            native_case.mkdir()
            native_input = native_case / name
            native_output = native_case / "output"
            shutil.copyfile(fixture, native_input)
            official_pdf = case / "official.pdf"
            classpath = str(classes) + os.pathsep + args.classpath
            oracle = invoke([args.java, "-Xmx1024m", "-Djava.awt.headless=true", "-Dsun.java2d.uiScale=1",
                             "-Djavax.xml.accessExternalDTD=", "-Djavax.xml.accessExternalSchema=", "-cp", classpath,
                             "UyapBridge", str(fixture), str(official_pdf)], timeout=120, cwd=scratch)
            write_log(case / "official.log", oracle)
            if oracle.returncode or not official_pdf.is_file():
                results.append({"file": name, "status": "oracle-rejected-fixture", "problems": ["Official exporter did not accept this fixture; compatibility is unvalidated"]})
                print("FAIL " + name + ": official exporter did not accept fixture")
                print("ORACLE_ERROR " + json.dumps({"file": name, "exitCode": oracle.returncode,
                                                    "logTail": oracle.stdout[-2500:]},
                                                   ensure_ascii=False, separators=(",", ":")), flush=True)
                continue
            native = invoke([str(args.native), "--batch", str(native_input), str(native_output)], timeout=120)
            write_log(case / "native.log", native)
            native_pdf_source = native_output / (fixture.stem + ".pdf")
            if native.returncode or not native_pdf_source.is_file():
                results.append({"file": name, "status": "native-render-failed", "problems": ["Native app did not produce a PDF for an official-exporter-accepted fixture"]})
                print("FAIL " + name + ": native renderer failed")
                print("NATIVE_ERROR " + json.dumps({"file": name, "exitCode": native.returncode,
                                                    "logTail": native.stdout[-2500:]},
                                                   ensure_ascii=False, separators=(",", ":")), flush=True)
                continue
            native_pdf = case / "native.pdf"
            shutil.copyfile(native_pdf_source, native_pdf)
            phrases = case / "phrases.json"
            phrases.write_text(json.dumps(item["phrases"], ensure_ascii=False), encoding="utf-8")
            snapshots = []
            for label, pdf in [("official", official_pdf), ("native", native_pdf)]:
                metric_result = invoke([str(metrics_binary), str(pdf), str(phrases)], timeout=90)
                write_log(case / (label + "-metrics.log"), metric_result)
                if metric_result.returncode:
                    raise RuntimeError("PDF metrics failed for " + name + "/" + label)
                metrics = json.loads(metric_result.stdout)
                (case / (label + "-metrics.json")).write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                snapshots.append(metrics)
            print_diagnostics(name, snapshots[0], snapshots[1])
            problems = compare_metrics(snapshots[0], snapshots[1], tolerance=args.bounds_tolerance)
            if item.get("pageCount") is not None and snapshots[0]["pageCount"] != item["pageCount"]:
                problems.append("Oracle page count does not match fixture design; the assumed schema is unvalidated")
            status = "mismatch" if problems else "matched-synthetic-fixture"
            results.append({"file": name, "status": status, "problems": problems})
            print(("FAIL " if problems else "PASS ") + name + (": " + "; ".join(problems[:3]) if problems else ""))

    failures = [result for result in results if result["status"] != "matched-synthetic-fixture"]
    report = {"schemaVersion": 1, "syntheticOnly": True, "boundsTolerancePoints": args.bounds_tolerance,
              "scope": "Synthetic comparison only; not a compatibility claim for arbitrary UDF documents",
              "results": results, "failures": len(failures)}
    (args.output / "comparison-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Compared {len(results)} synthetic fixtures; failures={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, RuntimeError) as error:
        print("Official UDF comparison failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
