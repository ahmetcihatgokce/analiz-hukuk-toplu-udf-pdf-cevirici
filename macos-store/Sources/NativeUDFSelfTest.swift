#if STORE_TESTING
import AppKit
import Foundation
import PDFKit

/// Synthetic regression checks. These are excluded from the distributable app.
@MainActor
enum NativeUDFSelfTest {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Fixture {
        var text = ""

        mutating func paragraph(_ value: String, attributes: String = "", style: String = "") -> String {
            let start = text.utf16.count
            text += value
            return "<paragraph \(attributes)><content startOffset=\"\(start)\" length=\"\(value.utf16.count)\" \(style)/></paragraph>"
        }

        func xml(body: String, header: String = "", footer: String = "") -> Data {
            let headerXML = header.isEmpty ? "" : "<header>\(header)</header>"
            let footerXML = footer.isEmpty ? "" : "<footer>\(footer)</footer>"
            return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <template format_id="1.8"><content>\(Self.escape(text))</content>
            <properties><pageFormat mediaSizeName="1" paperOrientation="1" leftMargin="42.5" rightMargin="42.5" topMargin="42.5" bottomMargin="42.5" headerFOffset="20.0" footerFOffset="20.0"/></properties>
            <elements resolver="hvl-default">\(headerXML)\(body)\(footerXML)</elements>
            <styles><style name="hvl-default" family="Times New Roman" size="12"/></styles></template>
            """.utf8)
        }

        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    static func run(at root: URL) async -> Int32 {
        let files = FileManager.default
        var report: [String] = []
        var failures = 0

        func check(_ name: String, _ operation: () throws -> Void) {
            do {
                try operation()
                report.append("PASS \(name)")
            } catch {
                failures += 1
                report.append("FAIL \(name): \(error.localizedDescription)")
            }
            print(report.last!)
        }

        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            var baseline = Fixture()
            let baselineBody = baseline.paragraph("Analiz Hukuk macOS dönüşüm testi.\n", attributes: "Alignment=\"1\"", style: "bold=\"true\"")
                + baseline.paragraph("Türkçe: Çağrı, Şule, Iğde, Özgür, Ümit, ıİşŞğĞüÜöÖçÇ.\n")
                + baseline.paragraph("Bu dosya sentetik test verisidir.\n")
            let baselineXML = baseline.xml(body: baselineBody)

            check("native UDF matches official synthetic baseline text, A4 size and page count") {
                let input = root.appendingPathComponent("baseline.udf")
                try writeZip(entries: [("content.xml", baselineXML)], to: input)
                let parsed = try UDFDocument.load(from: input)
                let output = root.appendingPathComponent("baseline.pdf")
                try UDFRenderer.render(parsed, to: output)
                let pdf = try openPDF(output)
                try require(pdf.pageCount == 1, "Official synthetic baseline has one page")
                try requireText(pdf, contains: ["Analiz Hukuk macOS dönüşüm testi.", "Türkçe", "Çağrı", "ıİşŞğĞüÜöÖçÇ", "Bu dosya sentetik test verisidir."])
                try require(baseline.text.utf16.count == 122, "Baseline fixture no longer matches the known 122-character official example")
                try requireA4(pdf)
            }

            check("UTF16 ranges preserve Turkish text following a supplementary Unicode character") {
                var fixture = Fixture()
                let body = fixture.paragraph("UTF16 😀 Çağrı İĞÜŞÖÇ ıiğüşöç END_SENTINEL\n")
                let output = root.appendingPathComponent("utf16.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: body)), to: output)
                let pdf = try openPDF(output)
                try requireText(pdf, contains: ["UTF16", "Çağrı", "İĞÜŞÖÇ", "END_SENTINEL"])
                try require(pdf.pageCount == 1, "Short UTF16 fixture unexpectedly paginated")
            }

            check("CRLF paragraph suffix removal preserves the preceding final letter") {
                var fixture = Fixture()
                let body = fixture.paragraph("CRLF_FINAL_LETTER_Z\r\n")
                // Numeric references preserve CR+LF after XML's input newline normalization.
                let source = String(decoding: fixture.xml(body: body), as: UTF8.self)
                    .replacingOccurrences(of: "\r\n", with: "&#13;&#10;")
                let parsed = try UDFDocument.parse(xml: Data(source.utf8))
                guard let first = parsed.body.first, case .paragraph(let paragraph) = first,
                      let run = paragraph.runs.first else {
                    throw Failure(message: "CRLF test did not create a text run")
                }
                try require(run.text == "CRLF_FINAL_LETTER_Z", "CRLF trimming removed a real text character")
                let output = root.appendingPathComponent("crlf-final-letter.pdf")
                try UDFRenderer.render(parsed, to: output)
                try requireText(openPDF(output), contains: ["CRLF_FINAL_LETTER_Z"])
            }

            check("font size and bold styling survive PDF rendering") {
                var fixture = Fixture()
                let body = fixture.paragraph("BOLD_SENTINEL\n", style: "bold=\"true\" size=\"18\"")
                    + fixture.paragraph("PLAIN_SENTINEL\n", style: "size=\"12\"")
                    + fixture.paragraph("ITALIC_SENTINEL\n", style: "italic=\"true\"")
                let output = root.appendingPathComponent("styles.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: body)), to: output)
                let pdf = try openPDF(output)
                try requireText(pdf, contains: ["BOLD_SENTINEL", "PLAIN_SENTINEL", "ITALIC_SENTINEL"])
                guard let boldFont = firstFont(pdf, phrase: "BOLD_SENTINEL"),
                      let plainFont = firstFont(pdf, phrase: "PLAIN_SENTINEL") else {
                    throw Failure(message: "Rendered PDF has no readable font metadata")
                }
                try require(boldFont.pointSize > plainFont.pointSize + 3, "18-point span lost its font size")
                let traits = NSFontManager.shared.traits(of: boldFont)
                try require(traits.contains(.boldFontMask), "Bold span lost its bold face")
            }

            check("table cells remain present and occupy separate columns") {
                var fixture = Fixture()
                let before = fixture.paragraph("TABLE_START\n")
                let a1 = fixture.paragraph("CELL_A1\n")
                let b1 = fixture.paragraph("CELL_B1\n")
                let a2 = fixture.paragraph("CELL_A2\n")
                let b2 = fixture.paragraph("CELL_B2\n")
                let after = fixture.paragraph("TABLE_END\n")
                let body = before + "<table border=\"borderAll\" columnWidths=\"120,220\"><row><cell columnSpan=\"1\" rowSpan=\"1\">\(a1)</cell><cell columnSpan=\"1\" rowSpan=\"1\">\(b1)</cell></row><row><cell columnSpan=\"1\" rowSpan=\"1\">\(a2)</cell><cell columnSpan=\"1\" rowSpan=\"1\">\(b2)</cell></row></table>" + after
                let output = root.appendingPathComponent("table.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: body)), to: output)
                let pdf = try openPDF(output)
                try require(pdf.pageCount == 1, "Small table should fit one A4 page")
                try requireText(pdf, contains: ["TABLE_START", "CELL_A1", "CELL_B1", "CELL_A2", "CELL_B2", "TABLE_END"])
                guard let page = pdf.page(at: 0),
                      let left = pdf.findString("CELL_A1", withOptions: []).first,
                      let right = pdf.findString("CELL_B1", withOptions: []).first else {
                    throw Failure(message: "Table cells are not individually selectable")
                }
                let leftBounds = left.bounds(for: page)
                let rightBounds = right.bounds(for: page)
                try require(rightBounds.minX > leftBounds.minX + 40, "Table was flattened into a single column")
                try require(abs(leftBounds.midY - rightBounds.midY) < 10, "First table row no longer shares a baseline")
            }

            check("embedded image produces visible PDF pixels") {
                var fixture = Fixture()
                let marker = fixture.paragraph("IMAGE_SENTINEL\n")
                let image = try redPNG()
                let body = marker + "<image width=\"96\" height=\"48\" imageData=\"\(image.base64EncodedString())\"/>"
                let output = root.appendingPathComponent("image.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: body)), to: output)
                let pdf = try openPDF(output)
                try requireText(pdf, contains: ["IMAGE_SENTINEL"])
                guard let page = pdf.page(at: 0) else { throw Failure(message: "Image PDF has no page") }
                try require(try redPixelCount(page) > 100, "Image was missing or rendered invisibly")
            }

            check("fail closed: an image range cannot consume real document text") {
                var fixture = Fixture()
                fixture.text = "X\n"
                let image = try redPNG()
                let body = "<paragraph><image width=\"96\" height=\"48\" imageData=\"\(image.base64EncodedString())\" startOffset=\"0\" length=\"1\"/><content startOffset=\"1\" length=\"1\"/></paragraph>"
                try mustReject { _ = try UDFDocument.parse(xml: fixture.xml(body: body)) }
            }

            check("explicit page break and header/footer repeat on each page") {
                var fixture = Fixture()
                let first = fixture.paragraph("FIRST_PAGE_SENTINEL\n")
                let second = fixture.paragraph("SECOND_PAGE_SENTINEL\n")
                let header = fixture.paragraph("HEADER_SENTINEL\n")
                let footer = fixture.paragraph("FOOTER_SENTINEL\n")
                let xml = fixture.xml(body: first + "<pageBreak/>" + second, header: header, footer: footer)
                let output = root.appendingPathComponent("headers-pagebreak.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: xml), to: output)
                let pdf = try openPDF(output)
                try require(pdf.pageCount == 2, "Explicit page break did not produce exactly two pages")
                for index in 0..<2 {
                    let text = pdf.page(at: index)?.string ?? ""
                    try require(text.contains("HEADER_SENTINEL") && text.contains("FOOTER_SENTINEL"), "Header/footer missing on page \(index + 1)")
                }
                try require(pdf.page(at: 0)?.string?.contains("FIRST_PAGE_SENTINEL") == true, "First content moved to wrong page")
                try require(pdf.page(at: 0)?.string?.contains("SECOND_PAGE_SENTINEL") != true, "Page break ignored")
                try require(pdf.page(at: 1)?.string?.contains("SECOND_PAGE_SENTINEL") == true, "Second content moved to wrong page")
                try requireA4(pdf)
            }

            check("automatic pagination keeps every paragraph including the final line") {
                var fixture = Fixture()
                let markers = (0..<160).map { String(format: "LONG_LINE_%03d", $0) }
                let body = markers.map { fixture.paragraph("\($0) Türkçe doğrulama.\n") }.joined()
                let output = root.appendingPathComponent("long-pagination.pdf")
                try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: body)), to: output)
                let pdf = try openPDF(output)
                try require(pdf.pageCount == 3, "Official exporter uses three A4 pages for these 160 paragraphs; native produced \(pdf.pageCount)")
                for marker in markers {
                    try require(pdf.findString(marker, withOptions: []).count == 1, "Paragraph was omitted or duplicated: \(marker)")
                }
                try requireA4(pdf)
            }

            check("an intentional empty paragraph retains exactly one additional line of space") {
                @MainActor
                func lineGap(includeBlank: Bool, name: String) throws -> CGFloat {
                    var fixture = Fixture()
                    let first = fixture.paragraph("ABOVE_BLANK_SENTINEL\n")
                    let blank = includeBlank ? fixture.paragraph("\n") : ""
                    let last = fixture.paragraph("BELOW_BLANK_SENTINEL\n")
                    let output = root.appendingPathComponent(name + ".pdf")
                    try UDFRenderer.render(UDFDocument.parse(xml: fixture.xml(body: first + blank + last)), to: output)
                    let pdf = try openPDF(output)
                    guard pdf.pageCount == 1, let page = pdf.page(at: 0),
                          let above = pdf.findString("ABOVE_BLANK_SENTINEL", withOptions: []).first,
                          let below = pdf.findString("BELOW_BLANK_SENTINEL", withOptions: []).first else {
                        throw Failure(message: "Empty-paragraph fixture did not render both markers")
                    }
                    return abs(above.bounds(for: page).midY - below.bounds(for: page).midY)
                }
                let normal = try lineGap(includeBlank: false, name: "ordinary-line-pitch")
                let withBlank = try lineGap(includeBlank: true, name: "intentional-empty-paragraph")
                try require(normal > 5, "Ordinary paragraph line pitch is invalid")
                try require(abs(withBlank - 2 * normal) < 1, "Intentional empty paragraph was dropped or expanded twice: ordinary=\(normal), blank=\(withBlank)")
            }

            let baselineSource = String(decoding: baselineXML, as: UTF8.self)
            let malformed: [(String, String)] = [
                ("malformed XML", "<template><content>unclosed"),
                ("internal DTD", baselineSource.replacingOccurrences(of: "<template", with: "<!DOCTYPE template [<!ENTITY blocked 'NEVER_READ'>]><template")),
                ("external DTD", baselineSource.replacingOccurrences(of: "<template", with: "<!DOCTYPE template SYSTEM 'https://example.invalid/blocked.dtd'><template")),
                ("unsupported element", baselineSource.replacingOccurrences(of: "</elements>", with: "<unsupportedCriticalNode/></elements>")),
                ("unsupported paragraph attribute", baselineSource.replacingOccurrences(of: "Alignment=\"1\"", with: "Alignment=\"1\" UnsupportedCriticalAttribute=\"yes\"")),
                ("unreferenced content", baselineSource.replacingOccurrences(of: "</content>", with: "UNREFERENCED_TEXT</content>", options: [], range: baselineSource.range(of: "</content>"))),
                ("out-of-bounds range", baselineSource.replacingOccurrences(of: "length=\"34\"", with: "length=\"99999999\"")),
                ("non-finite font size", baselineSource.replacingOccurrences(of: "size=\"12\"", with: "size=\"NaN\"")),
                ("negative margin", baselineSource.replacingOccurrences(of: "leftMargin=\"42.5\"", with: "leftMargin=\"-42.5\"")),
                ("misdeclared XML encoding", baselineSource.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"ISO-8859-9\"")),
                ("oversized tab-stop list", baselineSource.replacingOccurrences(of: "Alignment=\"1\"", with: "Alignment=\"1\" TabSet=\"\(String(repeating: "1 ", count: 5000))\"")),
                ("unsupported page-break attribute", baselineSource.replacingOccurrences(of: "</elements>", with: "<pageBreak unsupported=\"1\"/></elements>")),
            ]
            for (name, xml) in malformed {
                check("fail closed: \(name)") {
                    try mustReject { _ = try UDFDocument.parse(xml: Data(xml.utf8)) }
                }
            }

            check("fail closed: UTF16 range cannot split a surrogate pair") {
                var fixture = Fixture()
                let valid = fixture.paragraph("A😀B\n")
                let source = String(decoding: fixture.xml(body: valid), as: UTF8.self)
                let split = source.replacingOccurrences(of: "length=\"5\"", with: "length=\"2\"")
                try require(split != source, "Surrogate fixture range replacement failed")
                try mustReject { _ = try UDFDocument.parse(xml: Data(split.utf8)) }
            }

            check("named style fontsize alias overrides inherited default size") {
                let xml = baselineSource.replacingOccurrences(of: "<styles>", with: "<styles><style name=\"large\" fontsize=\"18\"/>")
                    .replacingOccurrences(of: "startOffset=\"0\"", with: "resolver=\"large\" startOffset=\"0\"")
                let parsed = try UDFDocument.parse(xml: Data(xml.utf8))
                guard let first = parsed.body.first, case .paragraph(let paragraph) = first,
                      let run = paragraph.runs.first else {
                    throw Failure(message: "Named-style test did not create a text run")
                }
                try require(abs(run.style.size - 18) < 0.001, "Named fontsize style did not override inherited size")
            }

            check("fail closed: bad archive and traversal are rejected") {
                let corrupt = root.appendingPathComponent("not-a-zip.udf")
                try Data("not a ZIP archive".utf8).write(to: corrupt)
                try mustReject { _ = try UDFDocument.load(from: corrupt) }
                let traversal = root.appendingPathComponent("traversal.udf")
                try writeZip(entries: [("content.xml", baselineXML), ("../escaped.xml", Data("blocked".utf8))], to: traversal)
                try mustReject { _ = try UDFDocument.load(from: traversal) }
                try require(!files.fileExists(atPath: root.appendingPathComponent("escaped.xml").path), "UDF archive escaped its extraction directory")
            }

            check("rendering preserves source UDF bytes and reports unsupported content explicitly") {
                let input = root.appendingPathComponent("preserved.udf")
                try writeZip(entries: [("content.xml", baselineXML)], to: input)
                let before = try Data(contentsOf: input)
                let output = root.appendingPathComponent("preserved.pdf")
                try UDFRenderer.render(UDFDocument.load(from: input), to: output)
                try require(try Data(contentsOf: input) == before, "Source UDF was modified")
                let unknown = baselineSource.replacingOccurrences(of: "</elements>", with: "<unsupportedCriticalNode/></elements>")
                try mustReject { _ = try UDFDocument.parse(xml: Data(unknown.utf8)) }
                try require(try Data(contentsOf: input) == before, "Failed conversion modified a source UDF")
            }
        } catch {
            failures += 1
            report.append("FAIL native fixture setup: \(error.localizedDescription)")
            print(report.last!)
        }
        report.append("failures=\(failures)")
        try? report.joined(separator: "\n").write(to: root.appendingPathComponent("native-udf-test-results.txt"), atomically: true, encoding: .utf8)
        return failures == 0 ? 0 : 1
    }

    /// A tiny stored-ZIP writer keeps sandbox tests independent of Python or shell tools.
    /// The caller supplies fixture-only names, including unsafe names in rejection tests.
    static func writeZip(entries: [(String, Data)], to output: URL) throws {
        guard entries.count < Int(UInt16.max) else { throw Failure(message: "Too many synthetic ZIP entries") }
        var data = Data()
        var central = Data()
        for (name, value) in entries {
            let encoded = Data(name.utf8)
            guard encoded.count <= Int(UInt16.max), value.count <= Int(UInt32.max), data.count <= Int(UInt32.max) else {
                throw Failure(message: "Synthetic ZIP entry exceeds the stored ZIP limit")
            }
            let offset = UInt32(data.count)
            let checksum = crc32(value)
            append32(0x04034B50, to: &data)
            append16(20, to: &data)
            append16(0x0800, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0x0021, to: &data)
            append32(checksum, to: &data)
            append32(UInt32(value.count), to: &data)
            append32(UInt32(value.count), to: &data)
            append16(UInt16(encoded.count), to: &data)
            append16(0, to: &data)
            data.append(encoded)
            data.append(value)

            append32(0x02014B50, to: &central)
            append16(0x0314, to: &central)
            append16(20, to: &central)
            append16(0x0800, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0x0021, to: &central)
            append32(checksum, to: &central)
            append32(UInt32(value.count), to: &central)
            append32(UInt32(value.count), to: &central)
            append16(UInt16(encoded.count), to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0o100600 << 16, to: &central)
            append32(offset, to: &central)
            central.append(encoded)
        }
        let offset = data.count
        guard offset <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw Failure(message: "Synthetic ZIP central directory exceeds the ZIP limit")
        }
        data.append(central)
        append32(0x06054B50, to: &data)
        append16(0, to: &data)
        append16(0, to: &data)
        append16(UInt16(entries.count), to: &data)
        append16(UInt16(entries.count), to: &data)
        append32(UInt32(central.count), to: &data)
        append32(UInt32(offset), to: &data)
        append16(0, to: &data)
        try data.write(to: output, options: .atomic)
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xEDB88320)
            }
        }
        return value ^ 0xFFFFFFFF
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }

    private static func mustReject(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw Failure(message: "Unsupported or unsafe UDF was accepted")
    }

    private static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            throw Failure(message: "Native renderer did not produce a readable PDF")
        }
        return pdf
    }

    private static func requireText(_ pdf: PDFDocument, contains phrases: [String]) throws {
        let text = (pdf.string ?? "").precomposedStringWithCanonicalMapping
        for phrase in phrases {
            try require(text.contains(phrase.precomposedStringWithCanonicalMapping), "Rendered text missing: \(phrase)")
        }
    }

    private static func requireA4(_ pdf: PDFDocument) throws {
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { throw Failure(message: "PDF page disappeared") }
            let bounds = page.bounds(for: .mediaBox)
            try require(abs(bounds.width - 595.28) < 3 && abs(bounds.height - 841.89) < 3, "PDF media size differs from official A4 fixture")
        }
    }

    private static func firstFont(_ pdf: PDFDocument, phrase: String) -> NSFont? {
        guard let attributed = pdf.findString(phrase, withOptions: []).first?.attributedString,
              attributed.length > 0 else { return nil }
        return attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    private static func redPNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 48,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure(message: "Image fixture allocation failed")
        }
        let red = NSColor(deviceRed: 0.9, green: 0.05, blue: 0.05, alpha: 1)
        for y in 0..<48 {
            for x in 0..<96 { bitmap.setColor(red, atX: x, y: y) }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Image fixture encoding failed")
        }
        return png
    }

    private static func redPixelCount(_ page: PDFPage) throws -> Int {
        let thumbnail = page.thumbnail(of: NSSize(width: 400, height: 570), for: .mediaBox)
        guard let tiff = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            throw Failure(message: "Rendered PDF image cannot be rasterized")
        }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.6 && color.greenComponent < 0.35 && color.blueComponent < 0.35 {
                    count += 1
                }
            }
        }
        return count
    }
}
#endif
