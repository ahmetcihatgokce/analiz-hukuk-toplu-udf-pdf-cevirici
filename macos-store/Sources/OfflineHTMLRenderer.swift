import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports inert, self-contained receipt-style HTML into AppKit rich text.
/// Unsupported active/layout features are reported instead of being omitted.
@MainActor
enum OfflineHTMLRenderer {
    private static let maximumHTMLBytes = 16 * 1024 * 1024
    private static let maximumImageBytes = 32 * 1024 * 1024
    private static let maximumPixels = 64 * 1024 * 1024

    static func render(input: URL) throws -> Data {
        let bytes = try Data(contentsOf: input)
        guard !bytes.isEmpty, bytes.count <= maximumHTMLBytes else {
            throw ConversionFailure("HTML belgesi boş veya 16 MB sınırını aşıyor.")
        }
        var html = try decode(bytes)
        guard html.utf8.lazy.filter({ $0 == 60 }).prefix(100_001).count <= 100_000 else {
            throw ConversionFailure("HTML belgesi düğüm sınırını aşıyor.")
        }
        guard !matches("<!\\s*ENTITY\\b|<!DOCTYPE[^>]*(?:SYSTEM|PUBLIC|\\[)", in: html) else {
            throw ConversionFailure("HTML belgesinde dış kaynak tanımı kullanılamaz.")
        }
        html = replacing("<!DOCTYPE[^>]*>|<\\?xml[^>]*\\?>", in: html, with: "")
        html = replacing("(charset\\s*=\\s*[\"']?)[a-zA-Z0-9_-]+", in: html, with: "$1utf-8")
        // An XML processing instruction would force ordinary HTML (including
        // void elements such as <meta>) into the strict XML parsing path.
        html = closeVoidElements(html)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: Data(html.utf8),
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        } catch {
            let details = error as NSError
            throw ConversionFailure("HTML belgesi güvenli biçimde okunamadı (\(details.domain), \(details.code)).")
        }
        guard let root = document.rootElement() else {
            throw ConversionFailure("HTML belgesinin içeriği bulunamadı.")
        }
        var count = 0
        var imagePixels = 0
        var resourceBytes = 0
        try sanitize(root, base: input.deletingLastPathComponent(), depth: 0,
                     count: &count, pixels: &imagePixels, resourceBytes: &resourceBytes)
        let safe = document.xmlData(options: [])
        guard safe.count <= 64 * 1024 * 1024 else {
            throw ConversionFailure("HTML belgesinin kaynakları boyut sınırını aşıyor.")
        }
        // Apple's importer is a rich-text importer, not a general browser. Use
        // its bounded import timeout and stay on the main actor as documented.
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(data: safe, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .timeout: 8.0
            ], documentAttributes: nil)
        } catch {
            throw ConversionFailure("Yerel HTML metin ve tablo düzeni okunamadı: \(error.localizedDescription)")
        }
        guard attributed.length > 0, attributed.length <= 2_000_000,
              !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionFailure("HTML belgesinde desteklenen görünür metin bulunamadı.")
        }
        let width: CGFloat = 535.28
        let maximumHeight: CGFloat = 781.89 * 1000
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        layout.allowsNonContiguousLayout = false
        let container = NSTextContainer(size: NSSize(width: width, height: maximumHeight))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let range = layout.glyphRange(for: container)
        let bounds = layout.usedRect(for: container)
        let ink = layout.boundingRect(forGlyphRange: range, in: container)
        guard range.location == 0, range.length == layout.numberOfGlyphs,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.maxX <= width + 3, bounds.minX >= -3,
              bounds.maxY <= maximumHeight,
              ink.origin.x.isFinite, ink.origin.y.isFinite,
              ink.width.isFinite, ink.height.isFinite,
              ink.minX >= -3, ink.maxX <= width + 3,
              ink.minY >= -3, ink.maxY <= maximumHeight else {
            throw ConversionFailure("HTML sayfa düzeni güvenli çıktı alanına sığmıyor; içerik kesilmeden dönüştürülemedi.")
        }
        let height = max(24, ceil(max(bounds.maxY, ink.maxY)))
        // Draw the laid-out glyphs directly, using the same flipped AppKit
        // graphics context as the native UDF renderer. A text-view capture can
        // clip content when the view's frame and its container heights differ.
        let padding: CGFloat = 3
        var mediaBox = CGRect(x: 0, y: 0, width: width + 2 * padding, height: height + 2 * padding)
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionFailure("HTML metin alanının PDF boyutu oluşturulamadı.")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.saveGState()
        context.translateBy(x: padding, y: height + padding)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        layout.drawBackground(forGlyphRange: range, at: .zero)
        layout.drawGlyphs(forGlyphRange: range, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        let pdf = buffer as Data
        guard pdf.starts(with: Data("%PDF-".utf8)), pdf.count <= 256 * 1024 * 1024 else {
            throw ConversionFailure("Yerel HTML PDF çıktısı oluşturulamadı veya boyut sınırını aşıyor.")
        }
#if STORE_TESTING
        let extracted = PDFDocument(data: pdf)?.string ?? ""
        let fixtureTitle = "Vekâlet pulu makbuzu"
        let importedTitle = attributed.string.contains(fixtureTitle)
        let pdfTitle = extracted.contains(fixtureTitle)
        print("HTML_LAYOUT_DIAG importedCharacters=\(attributed.length) importedFixtureTitle=\(importedTitle) pdfCharacters=\(extracted.utf16.count) pdfFixtureTitle=\(pdfTitle) canvasHeight=\(mediaBox.height) usedHeight=\(bounds.maxY)")
#endif
        return pdf
    }

    private static func decode(_ data: Data) throws -> String {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "charset\\s*=\\s*[\"']?([a-zA-Z0-9_-]+)", options: [.caseInsensitive])
        let match = expression.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        let declared = match.flatMap { Range($0.range(at: 1), in: prefix).map { String(prefix[$0]).lowercased() } }
        let encoding: String.Encoding
        switch declared {
        case nil, "utf-8", "utf8": encoding = .utf8
        case "windows-1254", "cp1254":
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)))
        case "iso-8859-9":
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        default: throw ConversionFailure("HTML karakter kodlaması desteklenmiyor.")
        }
        guard let result = String(data: data, encoding: encoding) else {
            throw ConversionFailure("HTML karakter kodlaması ile belge içeriği uyuşmuyor.")
        }
        return result.hasPrefix("\u{feff}") ? String(result.dropFirst()) : result
    }

    private static func sanitize(_ element: XMLElement, base: URL, depth: Int,
                                 count: inout Int, pixels: inout Int,
                                 resourceBytes: inout Int) throws {
        count += 1
        guard count <= 100_000, depth <= 128 else {
            throw ConversionFailure("HTML belgesi düğüm veya derinlik sınırını aşıyor.")
        }
        let tag = element.name?.lowercased() ?? ""
        if ["script", "meta"].contains(tag) { element.detach(); return }
        let supportedTags: Set<String> = ["html", "head", "body", "title", "style", "link", "base", "div", "p", "span", "b", "strong", "i", "em", "u", "s", "strike", "del", "small", "big", "sub", "sup", "font", "br", "hr", "pre", "code", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "ol", "ul", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col", "img", "a", "noscript", "center", "address", "abbr", "cite", "q", "tt", "ins", "mark"]
        guard supportedTags.contains(tag) else {
            throw ConversionFailure("HTML belgesindeki öğe yerel metin dönüşümünde desteklenmiyor: \(tag).")
        }
        if ["iframe", "frame", "frameset", "object", "embed", "applet", "canvas", "svg", "math", "video", "audio", "form", "input", "select", "textarea", "button", "picture", "source"].contains(tag) {
            throw ConversionFailure("HTML belgesinde desteklenmeyen etkin içerik var: \(tag).")
        }
        if tag == "base" { element.detach(); return }
        if tag == "style" { try validateCSS(element.stringValue ?? "") }
        if tag == "link" {
            let relation = element.attribute(forName: "rel")?.stringValue?.lowercased() ?? ""
            guard relation == "stylesheet", let address = element.attribute(forName: "href")?.stringValue else {
                element.detach(); return
            }
            let data = try localResource(address, base: base, maximum: 1024 * 1024)
            guard data.count <= maximumImageBytes - resourceBytes else {
                throw ConversionFailure("HTML kaynaklarının toplam boyutu 32 MB sınırını aşıyor.")
            }
            resourceBytes += data.count
            guard let css = String(data: data, encoding: .utf8) else {
                throw ConversionFailure("HTML stil dosyası UTF-8 olarak okunamadı.")
            }
            try validateCSS(css)
            element.name = "style"
            element.attributes = []
            element.stringValue = css
        }
        for attribute in element.attributes ?? [] {
            let name = attribute.name?.lowercased() ?? ""
            let value = attribute.stringValue ?? ""
            if name.hasPrefix("on") { element.removeAttribute(forName: attribute.name ?? name); continue }
            if name == "style" { try validateCSS(value) }
            if ["srcset", "background", "poster", "xlink:href"].contains(name) {
                throw ConversionFailure("HTML belgesindeki kaynak türü desteklenmiyor: \(name).")
            }
            if name == "src" {
                guard tag == "img" else { throw ConversionFailure("HTML kaynağı desteklenmiyor.") }
                let data = try localResource(value, base: base, maximum: maximumImageBytes)
                guard data.count <= maximumImageBytes - resourceBytes else {
                    throw ConversionFailure("HTML kaynaklarının toplam boyutu 32 MB sınırını aşıyor.")
                }
                resourceBytes += data.count
                guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(image) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.intValue > 0, height.intValue > 0,
                      width.intValue <= 16384, height.intValue <= 16384,
                      width.intValue <= (maximumPixels - pixels) / height.intValue,
                      let mime = CGImageSourceGetType(image) as String?,
                      ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff", "com.microsoft.bmp"].contains(mime) else {
                    throw ConversionFailure("HTML görseli geçersiz veya piksel sınırını aşıyor.")
                }
                pixels += width.intValue * height.intValue
                let type = mime == "public.jpeg" ? "image/jpeg" : mime == "public.png" ? "image/png" : mime == "public.tiff" ? "image/tiff" : mime == "com.microsoft.bmp" ? "image/bmp" : "image/gif"
                attribute.stringValue = "data:\(type);base64,\(data.base64EncodedString())"
            }
            if name == "href", let scheme = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased(),
               !["http", "https", "mailto", "tel"].contains(scheme) {
                throw ConversionFailure("HTML bağlantısında etkin içerik kullanılamaz.")
            }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement {
                try sanitize(child, base: base, depth: depth + 1, count: &count, pixels: &pixels,
                             resourceBytes: &resourceBytes)
            }
        }
    }

    private static func localResource(_ raw: String, base: URL, maximum: Int) throws -> Data {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("data:") {
            guard let comma = address.firstIndex(of: ","),
                  address[..<comma].lowercased().hasSuffix(";base64"),
                  address.utf8.count <= maximum * 2,
                  let data = Data(base64Encoded: String(address[address.index(after: comma)...])),
                  !data.isEmpty, data.count <= maximum else {
                throw ConversionFailure("HTML gömülü kaynağı geçersiz veya çok büyük.")
            }
            return data
        }
        guard !address.isEmpty, !address.hasPrefix("//"), !address.hasPrefix("/"),
              let relative = URL(string: address), relative.scheme == nil,
              !address.contains("\\"), let decoded = address.removingPercentEncoding,
              !decoded.split(separator: "/").contains("..") else {
            throw ConversionFailure("HTML içindeki çevrimiçi veya klasör dışı kaynak kullanılamaz. Kaynakları belgeyle aynı klasöre kaydedip klasörü seçin.")
        }
        let realBase = base.standardizedFileURL.resolvingSymlinksInPath()
        let url = realBase.appendingPathComponent(decoded).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(realBase.path + "/") else {
            throw ConversionFailure("HTML kaynağı belge klasörünün dışına çıkıyor.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximum else {
            throw ConversionFailure("HTML yerel kaynağı bulunamadı veya boyut sınırını aşıyor.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw ConversionFailure("HTML yerel kaynağı boyut sınırını aşıyor.") }
        return data
    }

    private static func validateCSS(_ css: String) throws {
        let normalized = replacing("/\\*.*?\\*/", in: css, with: "")
        let withoutColorFunctions = replacing("(?:rgba?|hsla?)\\([^)]*\\)", in: normalized, with: "")
        guard css.utf8.count <= 1024 * 1024,
              !css.contains("\\"),
              !matches("[a-z_-]+\\s*\\(", in: withoutColorFunctions),
              !matches("@|(?:https?|file|ftp|data|javascript):|behavior\\s*:|position\\s*:\\s*(?:absolute|fixed)|display\\s*:\\s*(?:grid|flex)|(?:transform|float)\\s*:", in: normalized) else {
            throw ConversionFailure("HTML belgesindeki çevrimiçi kaynak veya gelişmiş sayfa düzeni yerel metin dönüşümünde desteklenmiyor.")
        }
    }

    private static func closeVoidElements(_ html: String) -> String {
        let voidNames: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let bytes = Array(html.utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 60 else { result.append(bytes[index]); index += 1; continue }
            let start = index
            var quote: UInt8?
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if let active = quote {
                    if byte == active { quote = nil }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if byte == 62 { break }
                index += 1
            }
            guard index < bytes.count else { result.append(contentsOf: bytes[start...]); break }
            var nameEnd = start + 1
            while nameEnd < index, (65...90).contains(bytes[nameEnd]) || (97...122).contains(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[(start + 1)..<nameEnd], as: UTF8.self).lowercased()
            var beforeClose = index - 1
            while beforeClose > start, [9, 10, 13, 32].contains(bytes[beforeClose]) { beforeClose -= 1 }
            result.append(contentsOf: bytes[start..<index])
            if voidNames.contains(name), bytes[beforeClose] != 47 { result.append(47) }
            result.append(62)
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return true }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
