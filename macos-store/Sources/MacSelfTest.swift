#if STORE_TESTING
import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import CoreFoundation
import CoreText

@MainActor
enum MacSelfTest {
    static func run(at root: URL) async -> Int32 {
        let files = FileManager.default
        var report: [String] = []
        var failures = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw ConversionFailure(message) }
        }
        func check(_ name: String, _ operation: () async throws -> Void) async {
            do {
                try await operation()
                report.append("PASS \(name)")
            } catch {
                failures += 1
                report.append("FAIL \(name): \(error.localizedDescription)")
            }
            print(report.last!)
        }
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            let inputs = root.appendingPathComponent("inputs", isDirectory: true)
            let output = root.appendingPathComponent("pdf", isDirectory: true)
            try files.createDirectory(at: inputs, withIntermediateDirectories: true)
            let png = inputs.appendingPathComponent("01 Çağrı.png")
            let tiff = inputs.appendingPathComponent("02 iki sayfa.tiff")
            let original = inputs.appendingPathComponent("03 original.pdf")
            try createImage(at: png, type: UTType.png.identifier, colors: [NSColor.systemBlue])
            try createImage(at: tiff, type: UTType.tiff.identifier, colors: [NSColor.systemRed, NSColor.systemGreen])
            try createPDF(at: original, labels: ["PAGE_ALPHA", "PAGE_BETA", "PAGE_GAMMA"])
            let originals = try [png, tiff, original].map { ($0, try Data(contentsOf: $0)) }
            let engine = ConversionEngine()
            var imagePDF: URL?

            await check("native images, multipage TIFF and PDF") {
                let results = await engine.convert(inputs: [png, tiff, original], outputDirectory: output, archivesCopyPDFOnly: false) { _, _, _ in }
                try require(results.count == 3 && results.allSatisfy { $0.error == nil }, results.compactMap(\.error).joined(separator: "; "))
                imagePDF = results.first(where: { $0.input == png })?.output
                try require(imagePDF?.lastPathComponent == "01 Çağrı.pdf", "Turkish file name was not preserved")
                let tiffPDF = results.first(where: { $0.input == tiff })?.output
                try require(tiffPDF.flatMap { PDFDocument(url: $0)?.pageCount } == 2, "TIFF pages were lost")
                for result in results {
                    try require(result.output.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0 > 0, "Unreadable PDF output")
                }
            }

            await check("ordered PDF merge and extraction") {
                guard let imagePDF = imagePDF else { throw ConversionFailure("PNG PDF missing") }
                let fixtureText = PDFDocument(url: original)?.page(at: 0)?.string ?? "<no text>"
                try require(fixtureText.contains("PAGE_ALPHA"), "Original PDF fixture lost text: \(fixtureText.debugDescription)")
                let merged = root.appendingPathComponent("merged.pdf")
                try engine.mergePDFs(inputs: [original, imagePDF], output: merged)
                let document = PDFDocument(url: merged)
                try require(document?.pageCount == 4, "Merged page count changed")
                try require(document?.page(at: 0)?.string?.contains("PAGE_ALPHA") == true, "Merge input order changed: \((document?.page(at: 0)?.string ?? "<no text>").debugDescription)")
                let extracted = root.appendingPathComponent("reordered.pdf")
                try engine.extractPDF(input: original, pages: [3, 1, 2], output: extracted)
                let reordered = PDFDocument(url: extracted)
                for (index, label) in ["PAGE_GAMMA", "PAGE_ALPHA", "PAGE_BETA"].enumerated() {
                    try require(reordered?.page(at: index)?.string?.contains(label) == true, "Page order was lost")
                }
                do {
                    try engine.extractPDF(input: original, pages: [0], output: root.appendingPathComponent("invalid-pages.pdf"))
                    throw ConversionFailure("Invalid page selection was accepted")
                } catch let error as ConversionFailure {
                    try require(error.message != "Invalid page selection was accepted", error.message)
                }
            }

            await check("local HTML, Turkish CP1254 and inert JavaScript") {
                let html = "<html><head><meta charset=\"windows-1254\"><style>td{border:1px solid;padding:6px}</style></head><body><h1>Vekâlet pulu makbuzu</h1><p>Şığüöç</p><table><tr><td>125,00 TL</td></tr></table><script>document.body.textContent='SCRIPT_RAN'</script><img src=\"https://example.invalid/never-request.png\"></body></html>"
                let url = inputs.appendingPathComponent("makbuz.htm")
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)))
                guard let data = html.data(using: encoding) else { throw ConversionFailure("CP1254 fixture encoding failed") }
                try data.write(to: url)
                let results = await engine.convert(inputs: [url], outputDirectory: root.appendingPathComponent("html"), archivesCopyPDFOnly: false) { _, _, _ in }
                try require(results.count == 1 && results[0].error == nil, results.first?.error ?? "HTML output missing")
                let text = results.first?.output.flatMap { PDFDocument(url: $0)?.string } ?? ""
                for expected in ["Vekâlet pulu makbuzu", "Şığüöç", "125,00 TL"] {
                    try require(text.contains(expected), "HTML text missing: \(expected)")
                }
                try require(!text.contains("SCRIPT_RAN"), "HTML script executed")
            }

            await check("native UDF conversion and malformed file isolation") {
                guard let fixture = ProcessInfo.processInfo.environment["UYAP_FIXTURE"] else { throw ConversionFailure("UYAP fixture not supplied by CI") }
                let good = inputs.appendingPathComponent("04 Türkçe.udf")
                try files.copyItem(at: URL(fileURLWithPath: fixture), to: good)
                let invalid = inputs.appendingPathComponent("05 bozuk.udf")
                try Data("invalid zip".utf8).write(to: invalid)
                let results = await engine.convert(inputs: [good, invalid], outputDirectory: root.appendingPathComponent("udf"), archivesCopyPDFOnly: false) { _, _, _ in }
                let details = results.map { "\($0.input.lastPathComponent): \($0.error ?? "OK")" }.joined(separator: "; ")
                try require(results.filter { $0.error == nil }.count == 1, "Expected one UDF success: \(details)")
                try require(results.filter { $0.error != nil }.count == 1, "Malformed UDF should fail independently")
                let goodPDF = results.first(where: { $0.input == good })?.output
                let text = goodPDF.flatMap { PDFDocument(url: $0)?.string } ?? ""
                try require(text.contains("Analiz Hukuk") && text.contains("sentetik test"), "UDF PDF lost text")
                try require(goodPDF?.lastPathComponent == "04 Türkçe.pdf", "UDF output name changed")
            }

            await check("ZIP and EYP preserve subfolders and PDF-only mode") {
                let zip = root.appendingPathComponent("belgeler.zip")
                let eyp = root.appendingPathComponent("belgeler.eyp")
                try NativeUDFSelfTest.writeZip(entries: [
                    ("Ekler/görsel.png", try Data(contentsOf: png)),
                    ("Ekler/hazır.pdf", try Data(contentsOf: original)),
                    ("Imza.xml", Data("<synthetic/>".utf8))
                ], to: zip)
                try files.copyItem(at: zip, to: eyp)
                let archiveOutput = root.appendingPathComponent("archives")
                let results = await engine.convert(inputs: [zip, eyp], outputDirectory: archiveOutput, archivesCopyPDFOnly: false) { _, _, _ in }
                try require(results.count == 4 && results.allSatisfy { $0.error == nil }, results.compactMap(\.error).joined(separator: "; "))
                try require(results.allSatisfy { $0.output?.path.contains("/Ekler/") == true }, "Archive directory names changed")
                let only = await engine.convert(inputs: [zip], outputDirectory: root.appendingPathComponent("pdf-only"), archivesCopyPDFOnly: true) { _, _, _ in }
                try require(only.count == 1 && only[0].error == nil, "PDF-only archive mode failed")
            }

            await check("RAR image and PDF extraction") {
                guard let fixture = ProcessInfo.processInfo.environment["MAC_RAR_FIXTURE"] else { throw ConversionFailure("RAR fixture not provided") }
                let results = await engine.convert(inputs: [URL(fileURLWithPath: fixture)], outputDirectory: root.appendingPathComponent("rar"), archivesCopyPDFOnly: false) { _, _, _ in }
                try require(results.count == 2 && results.allSatisfy { $0.error == nil }, results.compactMap(\.error).joined(separator: "; "))
            }

            await check("archive traversal rejected without output escape") {
                let malicious = root.appendingPathComponent("traversal.zip")
                try NativeUDFSelfTest.writeZip(entries: [("../escaped.pdf", Data("bad".utf8))], to: malicious)
                let results = await engine.convert(inputs: [malicious], outputDirectory: root.appendingPathComponent("blocked"), archivesCopyPDFOnly: false) { _, _, _ in }
                try require(results.count == 1 && results[0].error != nil, "Unsafe archive path was accepted")
                try require(!files.fileExists(atPath: root.appendingPathComponent("escaped.pdf").path), "Archive escaped its output folder")
            }

            await check("repeat conversion preserves prior PDFs and source bytes") {
                guard let originalPDF = imagePDF else { throw ConversionFailure("Missing initial image output") }
                let prior = try Data(contentsOf: originalPDF)
                let repeatResults = await engine.convert(inputs: [png], outputDirectory: output, archivesCopyPDFOnly: false) { _, _, _ in }
                try require(repeatResults.first?.error == nil && repeatResults.first?.output != originalPDF, "Repeated conversion overwrote a PDF")
                let after = try Data(contentsOf: originalPDF)
                try require(prior == after, "Prior output bytes changed")
                for (input, bytes) in originals {
                    let current = try Data(contentsOf: input)
                    try require(bytes == current, "Input was modified")
                }
            }
        } catch {
            failures += 1
            report.append("FAIL fixture setup: \(error.localizedDescription)")
            print(report.last!)
        }
        report.append("failures=\(failures)")
        try? report.joined(separator: "\n").write(to: root.appendingPathComponent("test-results.txt"), atomically: true, encoding: .utf8)
        return failures == 0 ? 0 : 1
    }

    private static func createPDF(at url: URL, labels: [String]) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw ConversionFailure("PDF consumer failed") }
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw ConversionFailure("PDF context failed") }
        for label in labels {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 42, y: 760)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func createImage(at url: URL, type: String, colors: [NSColor]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, colors.count, nil) else {
            throw ConversionFailure("Image destination failed")
        }
        for color in colors {
            guard let context = CGContext(data: nil, width: 720, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionFailure("Image context failed") }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 360))
            guard let image = context.makeImage() else { throw ConversionFailure("Image creation failed") }
            CGImageDestinationAddImage(destination, image, nil)
        }
        if !CGImageDestinationFinalize(destination) { throw ConversionFailure("Image fixture failed") }
    }

}
#endif
