import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// The native document model deliberately contains no UYAP or Java dependency.
// Unsupported document semantics are errors, not successful partial exports.
struct UDFPageFormat {
    let width, height: Double
    let leftMargin, rightMargin, topMargin, bottomMargin: Double
    let headerOffset, footerOffset: Double
}

enum UDFAlignment { case left, center, right, justified }
enum UDFTableBorder { case none, outer, grid }
enum UDFField { case pageNumber, pageCount }

struct UDFCharacterStyle {
    let family: String
    let size: Double
    let bold, italic, underline, strikethrough: Bool
    let foregroundRGB, backgroundRGB: UInt32?
    /// 0 = normal, 1 = superscript, -1 = subscript.
    let superscript: Int
}

struct UDFParagraphStyle {
    let alignment: UDFAlignment
    let leftIndent, rightIndent, firstLineIndent: Double
    let spaceBefore, spaceAfter, lineSpacing: Double
    let tabStops: [Double]
    let keepTogether, keepWithNext, pageBreakBefore: Bool
}

struct UDFImage {
    let data: Data
    let width, height: Double?
}

struct UDFRun {
    let text: String
    let style: UDFCharacterStyle
    let image: UDFImage?
    let field: UDFField?
}

struct UDFParagraph {
    let runs: [UDFRun]
    let style: UDFParagraphStyle
}

struct UDFCell {
    let blocks: [UDFBlock]
    let columnSpan, rowSpan: Int
    let width: Double?
    let backgroundRGB: UInt32?
}

struct UDFRow { let cells: [UDFCell] }

struct UDFTable {
    let rows: [UDFRow]
    let columnWidths: [Double]
    let border: UDFTableBorder
    let width: Double?
}

indirect enum UDFBlock {
    case paragraph(UDFParagraph)
    case table(UDFTable)
    case image(UDFImage)
    case pageBreak
}

struct UDFDocument {
    let pageFormat: UDFPageFormat
    let body, header, footer: [UDFBlock]
    let content: String

    /// Extracts only declarative document resources into a private container
    /// directory. Every resource is copied into the returned value before cleanup.
    static func load(from input: URL) throws -> UDFDocument {
        let files = FileManager.default
        let attributes = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
            throw UDFParseError("UDF dosyası boş, geçersiz veya 128 MB sınırını aşıyor.")
        }
        let directory = files.temporaryDirectory.appendingPathComponent("NativeUDF-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        let result = input.path.withCString { source in
            directory.path.withCString { destination in
                "xml,png,jpg,jpeg,gif,bmp,tif,tiff".withCString { extensions in
                    ah_extract_archive(source, destination, extensions, &error, capacity)
                }
            }
        }
        guard result == 0 else {
            throw UDFParseError("UDF arşivi güvenli biçimde okunamadı: \(String(cString: error))")
        }
        let contentURL = directory.appendingPathComponent("content.xml")
        let xml = try boundedRead(contentURL, limit: 16 * 1024 * 1024)
        var resources: [String: Data] = [:]
        var total = xml.count
        guard let enumerator = files.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw UDFParseError("UDF kaynakları okunamadı.")
        }
        for case let resource as URL in enumerator {
            let values = try resource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if resource == contentURL || resource.pathExtension.lowercased() == "xml" { continue }
            let data = try boundedRead(resource, limit: 32 * 1024 * 1024)
            guard data.count <= 128 * 1024 * 1024 - total else {
                throw UDFParseError("UDF kaynaklarının toplam boyutu 128 MB sınırını aşıyor.")
            }
            total += data.count
            let relative = String(resource.path.dropFirst(directory.path.count + 1))
            resources[relative] = data
        }
        return try parse(xml: xml, resources: resources)
    }

    static func parse(xml: Data, resources: [String: Data] = [:]) throws -> UDFDocument {
        let root = try UDFXMLTree.read(xml)
        return try UDFModelBuilder(root: root, resources: resources).build()
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit else {
            throw UDFParseError("UDF kaynağı eksik veya boyut sınırını aşıyor: \(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw UDFParseError("UDF kaynağı boyut sınırını aşıyor.") }
        return data
    }
}

struct UDFParseError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class UDFXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [UDFXMLNode] = []
    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
    func child(_ name: String) -> UDFXMLNode? { children.first { $0.name == name } }
}

private final class UDFXMLTree: NSObject, XMLParserDelegate {
    private var root: UDFXMLNode?
    private var stack: [UDFXMLNode] = []
    private var count = 0
    private var failure: Error?

    static func read(_ data: Data) throws -> UDFXMLNode {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw UDFParseError("UDF XML verisi geçerli UTF-8 değil veya 16 MB sınırını aşıyor.")
        }
        // No DTD or entity expansion is needed by the declarative UDF format.
        guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw UDFParseError("UDF içinde DTD veya XML varlığı kullanılamaz.")
        }
        // The byte-level UTF-8 check above must agree with the declaration:
        // otherwise XMLParser can reinterpret valid UTF-8 as another encoding
        // and silently corrupt Turkish characters.
        let prefix = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if prefix.hasPrefix("<?xml"), let end = prefix.range(of: "?>") {
            let declaration = String(prefix[..<end.lowerBound])
            let expression = try NSRegularExpression(pattern: #"(?i)\bencoding\s*=\s*['"]([^'"]+)['"]"#)
            let range = NSRange(declaration.startIndex..<declaration.endIndex, in: declaration)
            if let match = expression.firstMatch(in: declaration, range: range),
               let encodingRange = Range(match.range(at: 1), in: declaration) {
                let encoding = declaration[encodingRange].lowercased()
                guard ["utf-8", "utf8", "us-ascii", "ascii"].contains(encoding),
                      !["us-ascii", "ascii"].contains(encoding) || data.allSatisfy({ $0 < 128 }) else {
                    throw UDFParseError("UDF XML karakter kodlaması desteklenmiyor; Türkçe metin değiştirilmeden dönüştürülemedi.")
                }
            }
        }
        let tree = UDFXMLTree()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = tree
        let ok = parser.parse()
        if let failure = tree.failure { throw failure }
        guard ok, let root = tree.root, tree.stack.isEmpty else {
            throw UDFParseError("UDF XML yapısı geçersiz: \(parser.parserError?.localizedDescription ?? "eksik kök öğe")")
        }
        return root
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        if failure == nil { failure = UDFParseError(message) }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 100_000, stack.count < 128, attributeDict.count <= 64,
              !elementName.contains(":"), namespaceURI == nil || namespaceURI == "" else {
            fail(parser, "UDF XML öğe, alan adı veya derinlik sınırını aşıyor.")
            return
        }
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict {
            let normalized = key.lowercased()
            guard attributes[normalized] == nil, !key.contains(":") else {
                fail(parser, "UDF XML öznitelikleri belirsiz veya desteklenmiyor.")
                return
            }
            attributes[normalized] = value
        }
        let node = UDFXMLNode(name: elementName.lowercased(), attributes: attributes)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { fail(parser, "UDF XML birden fazla kök içeriyor."); return }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard stack.last?.name == elementName.lowercased() else { fail(parser, "UDF XML kapanış öğesi geçersiz."); return }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else { fail(parser, "UDF CDATA verisi geçersiz."); return }
        stack.last?.text.append(value)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "UDF XML varlık bildirimi içeremez.") }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "UDF XML dış kaynak içeremez.") }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, "UDF XML dış kaynak içeremez.")
        return nil
    }
}

private final class UDFModelBuilder {
    private let root: UDFXMLNode
    private let resources: [String: Data]
    private var styles: [String: UDFXMLNode] = [:]
    private var buffer: NSString = ""
    private var utf16: [UInt16] = []
    private var covered: [NSRange] = []
    private let characterKeys: Set<String> = ["family", "size", "fontsize", "bold", "italic", "underline", "strikethrough", "foreground", "background", "superscript", "subscript"]
    private let paragraphKeys: Set<String> = ["alignment", "leftindent", "rightindent", "firstlineindent", "spaceabove", "spacebelow", "linespacing", "tabset", "keeptogether", "keepwithnext", "pagebreakbefore"]
    private let referenceKeys: Set<String> = ["resolver"]
    private let rangeKeys: Set<String> = ["startoffset", "length"]

    init(root: UDFXMLNode, resources: [String: Data]) {
        self.root = root
        self.resources = resources
    }

    func build() throws -> UDFDocument {
        guard root.name == "template" else { throw UDFParseError("UDF kök öğesi template olmalıdır.") }
        try validate(root, allowed: ["format_id"])
        if let format = root.attributes["format_id"], !["1.7", "1.8"].contains(format) {
            throw UDFParseError("Bu UDF biçim sürümü henüz doğrulanmadı: \(format)")
        }
        guard Set(root.children.map(\.name)).isSubset(of: ["content", "properties", "elements", "styles"]) else {
            throw UDFParseError("UDF şablonunda desteklenmeyen bir belge bölümü var.")
        }
        for name in ["content", "properties", "elements", "styles"] {
            guard root.children.filter({ $0.name == name }).count <= 1 else { throw UDFParseError("UDF bölüm adı tekrarlanıyor: \(name)") }
        }
        guard let content = root.child("content"), content.children.isEmpty, content.attributes.isEmpty,
              let elements = root.child("elements") else { throw UDFParseError("UDF metni veya belge öğeleri eksik.") }
        guard content.text.utf16.count <= 8 * 1024 * 1024 else { throw UDFParseError("UDF metni boyut sınırını aşıyor.") }
        buffer = content.text as NSString
        utf16 = Array(content.text.utf16)
        if let collection = root.child("styles") {
            try validate(collection, allowed: [])
            for style in collection.children {
                guard style.name == "style", style.children.isEmpty else { throw UDFParseError("UDF stil yapısı desteklenmiyor.") }
                try validate(style, allowed: characterKeys.union(paragraphKeys).union(["name", "description", "resolver"]))
                guard let name = style.attributes["name"], !name.isEmpty, styles[name] == nil else { throw UDFParseError("UDF stil adı eksik veya yineleniyor.") }
                styles[name] = style
            }
        }
        try validate(elements, allowed: referenceKeys)
        let defaults = styles["default"]?.attributes ?? styles["hvl-default"]?.attributes ?? [:]
        let inherited = try resolved(elements, inherited: defaults)
        var body: [UDFBlock] = [], header: [UDFBlock] = [], footer: [UDFBlock] = []
        for child in elements.children {
            switch child.name {
            case "header", "footer":
                try validate(child, allowed: referenceKeys)
                let blocks = try child.children.map { try block($0, inherited: try resolved(child, inherited: inherited)) }
                if child.name == "header" {
                    guard header.isEmpty else { throw UDFParseError("Birden fazla üst bilgi bölümü desteklenmiyor.") }
                    header = blocks
                } else {
                    guard footer.isEmpty else { throw UDFParseError("Birden fazla alt bilgi bölümü desteklenmiyor.") }
                    footer = blocks
                }
            default: body.append(try block(child, inherited: inherited))
            }
        }
        guard !body.isEmpty else { throw UDFParseError("UDF belgesinde yazdırılabilir gövde bulunamadı.") }
        try validateCoverage()
        return UDFDocument(pageFormat: try pageFormat(), body: body, header: header, footer: footer, content: content.text)
    }

    private func block(_ node: UDFXMLNode, inherited: [String: String]) throws -> UDFBlock {
        let attributes = try resolved(node, inherited: inherited)
        switch node.name {
        case "paragraph":
            try validate(node, allowed: characterKeys.union(paragraphKeys).union(referenceKeys).union(rangeKeys))
            var runs: [UDFRun] = []
            if node.children.isEmpty {
                runs = [try textRun(node, inherited: attributes, fallback: node.text)]
            } else {
                guard node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UDFParseError("UDF paragrafında karışık metin yapısı desteklenmiyor.") }
                for child in node.children { runs.append(try inline(child, inherited: attributes)) }
            }
            if let index = runs.indices.last, runs[index].image == nil, runs[index].field == nil {
                let run = runs[index]
                var text = run.text
                if text.hasSuffix("\r\n") { text.removeLast(2) }
                else if text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
                runs[index] = UDFRun(text: text, style: run.style, image: nil, field: nil)
            }
            return .paragraph(UDFParagraph(runs: runs, style: try paragraphStyle(attributes)))
        case "table": return .table(try table(node, inherited: attributes))
        case "image":
            try validate(node, allowed: imageKeys.union(referenceKeys).union(rangeKeys))
            if hasRange(node) { _ = try slice(node, fallback: "") }
            return .image(try image(node))
        case "page-break", "pagebreak":
            try validate(node, allowed: [])
            guard node.children.isEmpty else { throw UDFParseError("Sayfa sonu öğesi içerik barındıramaz.") }
            return .pageBreak
        default: throw UDFParseError("Bu UDF öğesi yerleşimi korunarak henüz dönüştürülemiyor: \(node.name)")
        }
    }

    private func inline(_ node: UDFXMLNode, inherited: [String: String]) throws -> UDFRun {
        guard node.children.isEmpty else { throw UDFParseError("UDF satır içi öğesi alt öğe içeremez: \(node.name)") }
        let attributes = try resolved(node, inherited: inherited)
        let characterStyle = try characterStyle(attributes)
        switch node.name {
        case "content":
            try validate(node, allowed: characterKeys.union(referenceKeys).union(rangeKeys))
            return try textRun(node, inherited: attributes, fallback: node.text)
        case "space", "tab":
            try validate(node, allowed: characterKeys.union(referenceKeys).union(rangeKeys))
            return try textRun(node, inherited: attributes, fallback: node.name == "tab" ? "\t" : " ")
        case "image":
            try validate(node, allowed: imageKeys.union(characterKeys).union(referenceKeys).union(rangeKeys))
            if hasRange(node) { _ = try slice(node, fallback: "") }
            return UDFRun(text: "", style: characterStyle, image: try image(node), field: nil)
        case "field":
            try validate(node, allowed: characterKeys.union(referenceKeys).union(rangeKeys).union(["fieldname"]))
            guard let name = node.attributes["fieldname"]?.lowercased() else { throw UDFParseError("UDF alan adı eksik.") }
            let field: UDFField
            switch name {
            case "pagenumber", "page-number": field = .pageNumber
            case "pagecount", "page-count": field = .pageCount
            default: throw UDFParseError("Bu UDF alanı henüz desteklenmiyor: \(name)")
            }
            if hasRange(node) { _ = try slice(node, fallback: "") }
            return UDFRun(text: "", style: characterStyle, image: nil, field: field)
        default: throw UDFParseError("Bu UDF satır içi öğesi henüz desteklenmiyor: \(node.name)")
        }
    }

    private func textRun(_ node: UDFXMLNode, inherited: [String: String], fallback: String) throws -> UDFRun {
        UDFRun(text: try slice(node, fallback: fallback), style: try characterStyle(inherited), image: nil, field: nil)
    }

    private func table(_ node: UDFXMLNode, inherited: [String: String]) throws -> UDFTable {
        try validate(node, allowed: characterKeys.union(paragraphKeys).union(referenceKeys).union(["border", "width", "columnwidths"]))
        guard !node.children.isEmpty, node.children.count <= 4096 else { throw UDFParseError("UDF tablosunun satır sayısı geçersiz.") }
        let rows = try node.children.map { row -> UDFRow in
            guard row.name == "row" else { throw UDFParseError("UDF tablosunda desteklenmeyen öğe: \(row.name)") }
            try validate(row, allowed: characterKeys.union(paragraphKeys).union(referenceKeys))
            guard !row.children.isEmpty, row.children.count <= 128 else { throw UDFParseError("UDF tablo sütun sayısı geçersiz.") }
            let rowAttributes = try resolved(row, inherited: inherited)
            return UDFRow(cells: try row.children.map { cell in
                guard cell.name == "cell" else { throw UDFParseError("UDF satırında desteklenmeyen öğe: \(cell.name)") }
                try validate(cell, allowed: characterKeys.union(paragraphKeys).union(referenceKeys).union(["colspan", "columnspan", "rowspan", "width"]))
                let attributes = try resolved(cell, inherited: rowAttributes)
                let columnSpan = try integer(cell.attributes["columnspan"] ?? cell.attributes["colspan"], fallback: 1, min: 1, max: 128, name: "columnSpan")
                let rowSpan = try integer(cell.attributes["rowspan"], fallback: 1, min: 1, max: 4096, name: "rowSpan")
                return UDFCell(blocks: try cell.children.map { try block($0, inherited: attributes) }, columnSpan: columnSpan, rowSpan: rowSpan,
                    width: try optionalNumber(cell.attributes["width"], min: 1, max: 5000, name: "cell width"), backgroundRGB: try color(attributes["background"]))
            })
        }
        let border: UDFTableBorder
        switch node.attributes["border"]?.lowercased() ?? "borderall" {
        case "none", "bordernone": border = .none
        case "borderouter", "outer": border = .outer
        case "borderall", "all", "grid": border = .grid
        default: throw UDFParseError("UDF tablo kenarlığı henüz desteklenmiyor.")
        }
        let widths = try numberList(node.attributes["columnwidths"], min: 1, max: 5000, name: "columnWidths")
        return UDFTable(rows: rows, columnWidths: widths, border: border,
            width: try optionalNumber(node.attributes["width"], min: 1, max: 5000, name: "table width"))
    }

    private let imageKeys: Set<String> = ["imagedata", "src", "filename", "width", "height"]
    private func image(_ node: UDFXMLNode) throws -> UDFImage {
        let data: Data
        if let encoded = node.attributes["imagedata"] {
            let compact = encoded.filter { !$0.isWhitespace }
            guard compact.utf8.count <= 44 * 1024 * 1024, let decoded = Data(base64Encoded: compact), !decoded.isEmpty else {
                throw UDFParseError("UDF görselinin Base64 verisi geçersiz.")
            }
            data = decoded
        } else if let path = node.attributes["src"] ?? node.attributes["filename"] {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), let resource = resources[path] else {
                throw UDFParseError("UDF görsel kaynağı arşivde bulunamadı veya yol güvenli değil.")
            }
            data = resource
        } else { throw UDFParseError("UDF görsel verisi eksik.") }
        guard data.count <= 32 * 1024 * 1024 else { throw UDFParseError("UDF görseli 32 MB sınırını aşıyor.") }
        return UDFImage(data: data,
            width: try optionalNumber(node.attributes["width"], min: 0.1, max: 5000, name: "image width"),
            height: try optionalNumber(node.attributes["height"], min: 0.1, max: 5000, name: "image height"))
    }

    private func pageFormat() throws -> UDFPageFormat {
        let properties = root.child("properties")
        if let properties = properties {
            try validate(properties, allowed: [])
            guard properties.children.allSatisfy({ $0.name == "pageformat" }), properties.children.count <= 1 else {
                throw UDFParseError("UDF belge özellikleri henüz desteklenmiyor.")
            }
        }
        let node = properties?.child("pageformat")
        if let node = node {
            try validate(node, allowed: ["mediasizename", "paperorientation", "leftmargin", "rightmargin", "topmargin", "bottommargin", "headerfoffset", "footerfoffset", "width", "height"])
            guard node.children.isEmpty else { throw UDFParseError("UDF sayfa biçimi iç içe öğe içeremez.") }
        }
        let a = node?.attributes ?? [:]
        var width: Double, height: Double
        switch a["mediasizename"]?.lowercased() ?? "1" {
        case "1", "a4", "iso-a4": (width, height) = (595.2756, 841.8898)
        case "a3", "iso-a3": (width, height) = (841.8898, 1190.5512)
        case "a5", "iso-a5": (width, height) = (419.5276, 595.2756)
        case "letter", "na-letter": (width, height) = (612, 792)
        case "legal", "na-legal": (width, height) = (612, 1008)
        case "custom":
            width = try number(a["width"], fallback: 0, min: 72, max: 5000, name: "page width")
            height = try number(a["height"], fallback: 0, min: 72, max: 5000, name: "page height")
        default: throw UDFParseError("UDF kâğıt boyutu henüz desteklenmiyor.")
        }
        switch a["paperorientation"]?.lowercased() ?? "1" {
        case "1", "portrait": break
        case "2", "landscape": swap(&width, &height)
        default: throw UDFParseError("UDF kâğıt yönü geçersiz.")
        }
        let left = try number(a["leftmargin"], fallback: 42.5, min: 0, max: width / 2, name: "leftMargin")
        let right = try number(a["rightmargin"], fallback: 42.5, min: 0, max: width / 2, name: "rightMargin")
        let top = try number(a["topmargin"], fallback: 42.5, min: 0, max: height / 2, name: "topMargin")
        let bottom = try number(a["bottommargin"], fallback: 42.5, min: 0, max: height / 2, name: "bottomMargin")
        guard width - left - right >= 36, height - top - bottom >= 36 else { throw UDFParseError("UDF sayfasında yazdırılabilir alan kalmıyor.") }
        return UDFPageFormat(width: width, height: height, leftMargin: left, rightMargin: right, topMargin: top, bottomMargin: bottom,
            headerOffset: try number(a["headerfoffset"], fallback: 20, min: 0, max: top, name: "headerFOffset"),
            footerOffset: try number(a["footerfoffset"], fallback: 20, min: 0, max: bottom, name: "footerFOffset"))
    }

    private func characterStyle(_ a: [String: String]) throws -> UDFCharacterStyle {
        let family = a["family"] ?? "Times New Roman"
        guard !family.isEmpty, family.utf16.count <= 128, !family.unicodeScalars.contains(where: { $0.value < 32 }) else { throw UDFParseError("UDF yazı tipi adı geçersiz.") }
        let superscript = try boolean(a["superscript"], name: "superscript")
        let subscriptValue = try boolean(a["subscript"], name: "subscript")
        guard !(superscript && subscriptValue) else { throw UDFParseError("UDF metni aynı anda alt ve üst simge olamaz.") }
        return UDFCharacterStyle(family: family,
            size: try number(a["size"] ?? a["fontsize"], fallback: 12, min: 1, max: 500, name: "font size"),
            bold: try boolean(a["bold"], name: "bold"), italic: try boolean(a["italic"], name: "italic"),
            underline: try boolean(a["underline"], name: "underline"), strikethrough: try boolean(a["strikethrough"], name: "strikethrough"),
            foregroundRGB: try color(a["foreground"]), backgroundRGB: try color(a["background"]),
            superscript: superscript ? 1 : subscriptValue ? -1 : 0)
    }

    private func paragraphStyle(_ a: [String: String]) throws -> UDFParagraphStyle {
        let alignment: UDFAlignment
        switch a["alignment"]?.lowercased() ?? "0" {
        case "0", "left": alignment = .left
        case "1", "center": alignment = .center
        case "2", "right": alignment = .right
        case "3", "justify", "justified": alignment = .justified
        default: throw UDFParseError("UDF paragraf hizalaması desteklenmiyor.")
        }
        return UDFParagraphStyle(alignment: alignment,
            leftIndent: try number(a["leftindent"], fallback: 0, min: -1000, max: 5000, name: "LeftIndent"),
            rightIndent: try number(a["rightindent"], fallback: 0, min: -1000, max: 5000, name: "RightIndent"),
            firstLineIndent: try number(a["firstlineindent"], fallback: 0, min: -1000, max: 5000, name: "FirstLineIndent"),
            spaceBefore: try number(a["spaceabove"], fallback: 0, min: 0, max: 1000, name: "SpaceAbove"),
            spaceAfter: try number(a["spacebelow"], fallback: 0, min: 0, max: 1000, name: "SpaceBelow"),
            lineSpacing: try number(a["linespacing"], fallback: 0, min: 0, max: 10, name: "LineSpacing"),
            tabStops: try numberList(a["tabset"], min: 0, max: 5000, name: "TabSet"),
            keepTogether: try boolean(a["keeptogether"], name: "keepTogether"),
            keepWithNext: try boolean(a["keepwithnext"], name: "keepWithNext"),
            pageBreakBefore: try boolean(a["pagebreakbefore"], name: "pageBreakBefore"))
    }

    private func resolved(_ node: UDFXMLNode, inherited: [String: String]) throws -> [String: String] {
        var result = inherited
        var visited: Set<String> = []
        func apply(_ name: String) throws {
            guard visited.insert(name).inserted, visited.count <= 32, let style = styles[name] else {
                throw UDFParseError("UDF stil başvurusu eksik veya döngüsel: \(name)")
            }
            if let parent = style.attributes["resolver"] { try apply(parent) }
            result.merge(style.attributes) { _, new in new }
            if let fontSize = style.attributes["fontsize"] { result["size"] = fontSize }
        }
        if let reference = node.attributes["resolver"] { try apply(reference) }
        result.merge(node.attributes) { _, new in new }
        if let fontSize = node.attributes["fontsize"] { result["size"] = fontSize }
        return result
    }

    private func validate(_ node: UDFXMLNode, allowed: Set<String>) throws {
        let unknown = Set(node.attributes.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw UDFParseError("UDF biçiminde henüz desteklenmeyen özellik: \(node.name).\(unknown.sorted().joined(separator: ","))") }
        if node.name != "content", node.name != "paragraph" {
            guard node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UDFParseError("UDF öğesinde beklenmeyen doğrudan metin: \(node.name)") }
        }
    }

    private func hasRange(_ node: UDFXMLNode) -> Bool { node.attributes["startoffset"] != nil || node.attributes["length"] != nil }
    private func slice(_ node: UDFXMLNode, fallback: String) throws -> String {
        guard hasRange(node) else { return fallback }
        guard let startText = node.attributes["startoffset"], let lengthText = node.attributes["length"],
              let start = Int(startText), let length = Int(lengthText), start >= 0, length >= 0,
              start <= buffer.length, length <= buffer.length - start else {
            throw UDFParseError("UDF metin konumu UTF-16 sınırlarının dışında.")
        }
        let range = NSRange(location: start, length: length)
        // NSString offsets are Java/Swing UTF-16 offsets. Reject ranges splitting
        // a surrogate pair rather than replacing or losing document characters.
        func insidePair(_ offset: Int) -> Bool {
            offset > 0 && offset < utf16.count && (0xD800...0xDBFF).contains(utf16[offset - 1]) && (0xDC00...0xDFFF).contains(utf16[offset])
        }
        guard !insidePair(start), !insidePair(start + length) else { throw UDFParseError("UDF metin aralığı bir Unicode karakterini bölüyor.") }
        if length > 0 { covered.append(range) }
        return buffer.substring(with: range)
    }

    private func validateCoverage() throws {
        let ranges = covered.sorted { $0.location < $1.location }
        var end = 0
        for range in ranges {
            if range.location > end {
                let gap = buffer.substring(with: NSRange(location: end, length: range.location - end))
                guard gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UDFParseError("UDF metninin bir bölümü belge öğelerinde temsil edilmiyor; eksik PDF üretilmedi.") }
            }
            end = max(end, range.location + range.length)
        }
        if end < buffer.length {
            let gap = buffer.substring(from: end)
            guard gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UDFParseError("UDF metninin son bölümü belge öğelerinde temsil edilmiyor; eksik PDF üretilmedi.") }
        }
    }

    private func number(_ raw: String?, fallback: Double, min: Double, max: Double, name: String) throws -> Double {
        let value: Double
        if let raw = raw { guard let parsed = Double(raw) else { throw UDFParseError("UDF sayısal alanı geçersiz: \(name)") }; value = parsed }
        else { value = fallback }
        guard value.isFinite, value >= min, value <= max else { throw UDFParseError("UDF sayısal alanı sınırların dışında: \(name)") }
        return value
    }
    private func optionalNumber(_ raw: String?, min: Double, max: Double, name: String) throws -> Double? {
        guard let raw = raw else { return nil }
        return try number(raw, fallback: min, min: min, max: max, name: name)
    }
    private func integer(_ raw: String?, fallback: Int, min: Int, max: Int, name: String) throws -> Int {
        guard let raw = raw else { return fallback }
        guard let value = Int(raw), value >= min, value <= max else { throw UDFParseError("UDF tamsayı alanı geçersiz: \(name)") }
        return value
    }
    private func numberList(_ raw: String?, min: Double, max: Double, name: String) throws -> [Double] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        guard raw.utf8.count <= 4096 else { throw UDFParseError("UDF sayısal listesi boyut sınırını aşıyor: \(name)") }
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard parts.count <= 128 else { throw UDFParseError("UDF sayısal listesi çok uzun: \(name)") }
        return try parts.map { try number(String($0), fallback: 0, min: min, max: max, name: name) }
    }
    private func boolean(_ raw: String?, name: String) throws -> Bool {
        switch raw?.lowercased() {
        case nil, "false", "0": return false
        case "true", "1": return true
        default: throw UDFParseError("UDF mantıksal alanı geçersiz: \(name)")
        }
    }
    private func color(_ raw: String?) throws -> UInt32? {
        guard let raw = raw else { return nil }
        if raw.hasPrefix("#"), raw.count == 7, let value = UInt32(raw.dropFirst(), radix: 16) { return value }
        if let value = Int64(raw), value >= Int64(Int32.min), value <= Int64(UInt32.max) { return UInt32(truncatingIfNeeded: value) & 0xFFFFFF }
        throw UDFParseError("UDF renk değeri geçersiz.")
    }
}
