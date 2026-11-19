import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Renders the parsed document with AppKit's native text layout engine. No UYAP,
/// Java, network service or secondary executable participates in this path.
@MainActor
enum UDFRenderer {
    private static let maximumPages = 1000
    private static let maximumPDFBytes = 256 * 1024 * 1024
    private static let cellBorderAttribute = NSAttributedString.Key("AnalizUDFCellBorder")

    @MainActor
    private final class CellBorder {
        let block: NSTextTableBlock
        let edges: Int // top = 1, right = 2, bottom = 4, left = 8
        let characterRange: NSRange

        init(block: NSTextTableBlock, edges: Int, characterRange: NSRange) {
            self.block = block
            self.edges = edges
            self.characterRange = characterRange
        }
    }
#if STORE_TESTING
    private static var diagnosticLayoutsPrinted = 0

    private static func diagnose(_ layout: Layout) {
        guard ProcessInfo.processInfo.environment["UDF_LAYOUT_DIAGNOSTICS"] == "1",
              diagnosticLayoutsPrinted < 8 else { return }
        diagnosticLayoutsPrinted += 1
        var lines: [String] = []
        layout.manager.enumerateLineFragments(forGlyphRange: layout.range) { rectangle, used, _, range, _ in
            lines.append("glyphs=\(range.location):\(range.length),line=\(NSStringFromRect(rectangle)),used=\(NSStringFromRect(used))")
        }
        var fontMetrics = "none"
        if layout.storage.length > 0,
           let font = layout.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            fontMetrics = "\(font.fontName),size=\(font.pointSize),ascent=\(font.ascender),descent=\(font.descender),leading=\(font.leading)"
        }
        print("UDF_LAYOUT_DIAGNOSTIC chars=\(layout.storage.length) glyphs=\(layout.range.location):\(layout.range.length) usedHeight=\(layout.usedHeight) usedRect=\(NSStringFromRect(layout.manager.usedRect(for: layout.container))) extra=\(NSStringFromRect(layout.manager.extraLineFragmentRect)) font=\(fontMetrics) lines=\(lines.joined(separator: ";"))")
    }
#endif

    static func render(_ document: UDFDocument, to output: URL) throws {
        let format = document.pageFormat
        let width = CGFloat(format.width)
        let height = CGFloat(format.height)
        let left = CGFloat(format.leftMargin)
        let top = CGFloat(format.topMargin)
        let bodySize = CGSize(width: width - left - CGFloat(format.rightMargin),
                              height: height - top - CGFloat(format.bottomMargin))
        guard width.isFinite, height.isFinite, width >= 72, height >= 72,
              width <= 2880, height <= 2880, bodySize.width >= 24, bodySize.height >= 24 else {
            throw ConversionFailure("UDF sayfa veya kenar boşluğu ölçüleri geçersiz.")
        }

        let builder = AttributedBuilder(availableWidth: bodySize.width, pageNumber: nil, pageCount: nil)
        let planner = PagePlanner(size: bodySize)
        var group: [UDFBlock] = []
        var groupIsAtomic = false
        func flush() throws {
            guard !group.isEmpty else { return }
            let text = try builder.build(group)
            try planner.append(text, atomic: groupIsAtomic)
            group.removeAll(keepingCapacity: true)
            groupIsAtomic = false
        }
        for block in document.body {
            if case .pageBreak = block {
                try flush()
                try planner.pageBreak(includeEmptyPage: true)
                continue
            }
            var keepWithNext = false
            if case .paragraph(let paragraph) = block {
                if paragraph.style.pageBreakBefore {
                    try flush()
                    try planner.pageBreak()
                }
                keepWithNext = paragraph.style.keepWithNext
                groupIsAtomic = groupIsAtomic || paragraph.style.keepTogether || keepWithNext
            }
            group.append(block)
            if !keepWithNext { try flush() }
        }
        try flush()
        if planner.pages.isEmpty { try planner.pageBreak() }
        guard !planner.pages.isEmpty, planner.pages.count <= maximumPages else {
            throw ConversionFailure("UDF belgesi 1000 sayfa sınırını aşıyor.")
        }
        for page in planner.pages {
            for fragment in page { try fragment.layout.validateBounds() }
        }

        // Resolve running page fields only after body pagination is complete.
        // Headers and footers never consume or overwrite body space.
        func decorations(for index: Int) throws -> (Layout?, CGPoint, Layout?, CGPoint) {
            let decorationBuilder = AttributedBuilder(availableWidth: bodySize.width,
                                                      pageNumber: index + 1,
                                                      pageCount: planner.pages.count)
            let headerOffset = CGFloat(format.headerOffset)
            let footerOffset = CGFloat(format.footerOffset)
            let headerSpace = top - headerOffset - 4
            let footerSpace = CGFloat(format.bottomMargin) - footerOffset - 4
            let header = try decorationLayout(document.header, builder: decorationBuilder,
                                              width: bodySize.width, height: headerSpace, name: "Üstbilgi")
            let footer = try decorationLayout(document.footer, builder: decorationBuilder,
                                              width: bodySize.width, height: footerSpace, name: "Altbilgi")
            let footerY = height - footerOffset - (footer?.usedHeight ?? 0)
            guard headerOffset >= 0, footerOffset >= 0,
                  header == nil || headerOffset + (header?.usedHeight ?? 0) <= top - 3,
                  footer == nil || footerY >= height - CGFloat(format.bottomMargin) + 3 else {
                throw ConversionFailure("UDF üstbilgi veya altbilgisi belge alanıyla çakışıyor.")
            }
            return (header, CGPoint(x: left, y: headerOffset), footer, CGPoint(x: left, y: footerY))
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw ConversionFailure("UDF için PDF belleği oluşturulamadı.")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let metadata: [CFString: Any] = [
            kCGPDFContextCreator: "Analiz Hukuk Toplu UDF PDF Çevirici",
            kCGPDFContextTitle: "PDF belgesi"
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw ConversionFailure("UDF PDF bağlamı oluşturulamadı.")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (index, page) in planner.pages.enumerated() {
            try autoreleasepool {
                // Release decoded running-header images after each page instead
                // of retaining one full decoded copy for every output page.
                let decoration = try decorations(for: index)
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(mediaBox)
                context.saveGState()
                context.translateBy(x: 0, y: height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                for fragment in page {
                    fragment.layout.draw(at: CGPoint(x: left, y: top + fragment.y), in: context)
                }
                if let header = decoration.0 { header.draw(at: decoration.1, in: context) }
                if let footer = decoration.2 { footer.draw(at: decoration.3, in: context) }
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPDFPage()
                guard data.length <= maximumPDFBytes else {
                    throw ConversionFailure("UDF PDF çıktısı 256 MB sınırını aşıyor.")
                }
            }
        }
        context.closePDF()
        closed = true
        let result = data as Data
        guard result.count <= maximumPDFBytes,
              let pdf = PDFDocument(data: result), pdf.pageCount == planner.pages.count else {
            throw ConversionFailure("UDF PDF çıktısının sayfaları doğrulanamadı.")
        }
        try result.write(to: output, options: .atomic)
    }

    private static func decorationLayout(_ blocks: [UDFBlock], builder: AttributedBuilder,
                                         width: CGFloat, height: CGFloat, name: String) throws -> Layout? {
        guard !blocks.isEmpty else { return nil }
        guard height >= 1 else { throw ConversionFailure("\(name) için ayrılan alan yetersiz.") }
        let text = try builder.build(blocks)
        let layout = Layout(text: text, size: CGSize(width: width, height: height))
        guard layout.isComplete, layout.usedHeight <= height + 0.5 else {
            throw ConversionFailure("\(name) ayrılan alana sığmıyor; içeriği kesilmeden dönüştürülemedi.")
        }
        try layout.validateBounds()
        return layout
    }

    @MainActor
    private final class Layout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let range: NSRange
        let size: CGSize
        let usedHeight: CGFloat

        init(text: NSAttributedString, size: CGSize) {
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            // Ordinary paragraph heights already include native font leading
            // before rounding to Swing's line advance. Adding TextKit leading
            // again causes a cumulative 0.5098pt drift for Times New Roman 12.
            manager.usesFontLeading = false
            manager.allowsNonContiguousLayout = false
            let container = NSTextContainer(containerSize: size)
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            self.storage = storage
            self.manager = manager
            self.container = container
            self.range = manager.glyphRange(for: container)
            self.size = size
            self.usedHeight = Self.contentHeight(manager: manager, container: container)
#if STORE_TESTING
            UDFRenderer.diagnose(self)
#endif
        }

        init(storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer,
             range: NSRange, size: CGSize) {
            self.storage = storage
            self.manager = manager
            self.container = container
            self.range = range
            self.size = size
            self.usedHeight = Self.contentHeight(manager: manager, container: container)
#if STORE_TESTING
            UDFRenderer.diagnose(self)
#endif
        }

        var isComplete: Bool { NSMaxRange(range) == manager.numberOfGlyphs }

        private static func contentHeight(manager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
            let used = manager.usedRect(for: container)
            let extra = manager.extraLineFragmentRect
            // The insertion-point line after a terminal paragraph separator has
            // no glyph. It is useful to an editable text view, but it must not
            // become a second blank line after every independently laid-out UDF
            // paragraph. Real blank paragraphs have their own newline glyphs;
            // their line fragments remain before this extra fragment.
            if manager.extraLineFragmentTextContainer === container,
               !extra.isEmpty, extra.origin.y.isFinite, extra.height.isFinite,
               extra.minY >= 0, extra.minY <= used.maxY + 0.5 {
                return min(used.maxY, extra.minY)
            }
            return used.maxY
        }

        func validateBounds() throws {
            let used = manager.usedRect(for: container)
            let ink = manager.boundingRect(forGlyphRange: range, in: container)
            guard manager.glyphRange(for: container) == range,
                  abs(Self.contentHeight(manager: manager, container: container) - usedHeight) <= 0.5,
                  used.origin.x.isFinite, used.origin.y.isFinite, used.width.isFinite, used.height.isFinite,
                  used.minX >= -3, used.maxX <= size.width + 3,
                  used.minY >= -0.5, used.maxY <= size.height + 0.5 else {
                throw ConversionFailure("UDF içeriği sayfa alanının dışına taşıyor; kesik PDF oluşturulmadı.")
            }
            if !ink.isEmpty {
                guard ink.origin.x.isFinite, ink.origin.y.isFinite, ink.width.isFinite, ink.height.isFinite,
                      ink.minX >= -3, ink.maxX <= size.width + 3,
                      ink.minY >= -3, ink.maxY <= size.height + 3 else {
                    throw ConversionFailure("UDF harf veya görsel sınırları sayfa alanına sığmıyor.")
                }
            }
            for (overlay, _, frame) in borderFrames() {
                guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                      frame.width.isFinite, frame.height.isFinite,
                      frame.width > 0, frame.height > 0,
                      frame.minX >= -3, frame.maxX <= size.width + 3,
                      overlay.edges > 0 else {
                    throw ConversionFailure("UDF tablo kenarlığının yerleşimi doğrulanamadı.")
                }
            }
        }

        private func borderFrames() -> [(CellBorder, NSRange, NSRect)] {
            guard range.length > 0 else { return [] }
            let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            var seen: Set<ObjectIdentifier> = []
            var result: [(CellBorder, NSRange, NSRect)] = []
            storage.enumerateAttribute(UDFRenderer.cellBorderAttribute, in: characters) { value, _, _ in
                guard let overlays = value as? [CellBorder] else { return }
                for overlay in overlays where seen.insert(ObjectIdentifier(overlay)).inserted {
                    let glyphs = manager.glyphRange(forCharacterRange: overlay.characterRange, actualCharacterRange: nil)
                    let visible = NSIntersectionRange(glyphs, range)
                    guard visible.length > 0 else { continue }
                    let frame = manager.boundsRect(for: overlay.block, at: visible.location, effectiveRange: nil)
                    result.append((overlay, glyphs, frame))
                }
            }
            return result
        }

        func draw(at point: CGPoint, in context: CGContext) {
            context.saveGState()
            // TextKit's glyph ink can extend slightly beyond its advance box
            // (especially italics). Preserve the same bounded overhang that the
            // validation above permits, rather than validating then clipping it.
            context.clip(to: CGRect(origin: point, size: size).insetBy(dx: -3, dy: -3))
            manager.drawBackground(forGlyphRange: range, at: point)
            // UYAP draws cell borders over the row geometry; borders do not add
            // padding or one extra point to every line of a long table.
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(0.5)
            for (overlay, glyphs, frame) in borderFrames() {
                let box = frame.offsetBy(dx: point.x, dy: point.y).insetBy(dx: 0.25, dy: 0.25)
                if overlay.edges & 1 != 0 && range.location <= glyphs.location {
                    context.move(to: CGPoint(x: box.minX, y: box.minY))
                    context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                }
                if overlay.edges & 2 != 0 {
                    context.move(to: CGPoint(x: box.maxX, y: box.minY))
                    context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                }
                if overlay.edges & 4 != 0 && NSMaxRange(range) >= NSMaxRange(glyphs) {
                    context.move(to: CGPoint(x: box.minX, y: box.maxY))
                    context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                }
                if overlay.edges & 8 != 0 {
                    context.move(to: CGPoint(x: box.minX, y: box.minY))
                    context.addLine(to: CGPoint(x: box.minX, y: box.maxY))
                }
                context.strokePath()
            }
            manager.drawGlyphs(forGlyphRange: range, at: point)
            context.restoreGState()
        }
    }

    private struct Fragment {
        let layout: Layout
        let y: CGFloat
    }

    @MainActor
    private final class PagePlanner {
        let size: CGSize
        var pages: [[Fragment]] = []
        private var y: CGFloat = 0

        init(size: CGSize) { self.size = size }

        func pageBreak(includeEmptyPage: Bool = false) throws {
            guard pages.count < UDFRenderer.maximumPages else {
                throw ConversionFailure("UDF belgesi 1000 sayfa sınırını aşıyor.")
            }
            // A page-break-before at the start must not invent an empty page.
            if pages.isEmpty { pages.append([]) }
            if includeEmptyPage || !pages[pages.count - 1].isEmpty {
                guard pages.count < UDFRenderer.maximumPages else {
                    throw ConversionFailure("UDF belgesi 1000 sayfa sınırını aşıyor.")
                }
                pages.append([])
            }
            y = 0
        }

        func append(_ text: NSAttributedString, atomic: Bool) throws {
            guard text.length > 0 else { return }
            if pages.isEmpty { try pageBreak() }
            if atomic {
                let full = Layout(text: text, size: size)
                guard full.isComplete else {
                    throw ConversionFailure("Birlikte tutulması gereken UDF paragrafı bir sayfaya sığmıyor.")
                }
                try full.validateBounds()
                let remaining = size.height - y
                if full.usedHeight > remaining + 0.5 { try pageBreak() }
                let selected = y == 0 ? full : Layout(text: text, size: CGSize(width: size.width, height: size.height - y))
                guard selected.isComplete else {
                    throw ConversionFailure("UDF paragrafının birlikte tutulma kuralı uygulanamadı.")
                }
                try selected.validateBounds()
                pages[pages.count - 1].append(Fragment(layout: selected, y: y))
                y += selected.usedHeight
                return
            }

            // Use a shared TextKit storage across page containers so continuation
            // lines, tables, ligatures and attachments retain their glyph mapping.
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            // Font leading is included once by paragraphAttributes, not added
            // again to every explicit line fragment by the layout manager.
            manager.usesFontLeading = false
            manager.allowsNonContiguousLayout = false
            storage.addLayoutManager(manager)
            var previousEnd = 0
            while true {
                if size.height - y < 1 { try pageBreak() }
                let available = CGSize(width: size.width, height: size.height - y)
                let container = NSTextContainer(containerSize: available)
                container.lineFragmentPadding = 0
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                let range = manager.glyphRange(for: container)
                if range.length == 0 {
                    if y == 0 {
                        throw ConversionFailure("UDF paragrafı, tablo satırı veya görseli boş bir sayfaya sığmıyor.")
                    }
                    try pageBreak()
                    continue
                }
                guard range.location == previousEnd else {
                    throw ConversionFailure("UDF sayfalaması sırasında metin sırası doğrulanamadı.")
                }
                let layout = Layout(storage: storage, manager: manager, container: container,
                                    range: range, size: available)
                try layout.validateBounds()
                pages[pages.count - 1].append(Fragment(layout: layout, y: y))
                y += layout.usedHeight
                previousEnd = NSMaxRange(range)
                if previousEnd >= manager.numberOfGlyphs { break }
                try pageBreak()
            }
        }
    }

    @MainActor
    private final class AttributedBuilder {
        let availableWidth: CGFloat
        let pageNumber: Int?
        let pageCount: Int?
        private var decodedImagePixels = 0

        init(availableWidth: CGFloat, pageNumber: Int?, pageCount: Int?) {
            self.availableWidth = availableWidth
            self.pageNumber = pageNumber
            self.pageCount = pageCount
        }

        func build(_ blocks: [UDFBlock]) throws -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for block in blocks { try append(block, to: result, parents: [], width: availableWidth, depth: 0) }
            return result
        }

        private func append(_ block: UDFBlock, to result: NSMutableAttributedString,
                            parents: [NSTextBlock], width: CGFloat, depth: Int) throws {
            guard depth <= 16 else { throw ConversionFailure("UDF tablo iç içe geçme sınırı aşıldı.") }
            switch block {
            case .paragraph(let paragraph):
                if paragraph.style.pageBreakBefore && (!parents.isEmpty || pageNumber != nil) {
                    throw ConversionFailure("Tablo hücresi, üstbilgi veya altbilgide açık sayfa sonu desteklenmiyor.")
                }
                if !parents.isEmpty && (paragraph.style.keepTogether || paragraph.style.keepWithNext) {
                    throw ConversionFailure("Tablo hücresi içindeki birlikte tutma kuralı henüz desteklenmiyor.")
                }
                if paragraph.runs.contains(where: { $0.text.contains("\t") }) {
                    switch paragraph.style.alignment {
                    case .left: break
                    default:
                        throw ConversionFailure("Sola hizalı olmayan paragraftaki UDF sekmeleri henüz desteklenmiyor.")
                    }
                }
                let value = NSMutableAttributedString(string: "")
                var last: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
                for run in paragraph.runs {
                    let attributes = try characterAttributes(run.style)
                    last = attributes
                    if let image = run.image {
                        guard run.text.isEmpty || run.text == "\u{fffc}" else {
                            throw ConversionFailure("Görsel ile aynı UDF aralığında ek metin bulundu.")
                        }
                        value.append(try imageText(image, width: width))
                    } else if let field = run.field {
                        guard let number = pageNumber, let count = pageCount else {
                            throw ConversionFailure("Gövde içindeki dinamik sayfa alanı desteklenmiyor.")
                        }
                        let text: String
                        switch field {
                        case .pageNumber: text = String(number)
                        case .pageCount: text = String(count)
                        }
                        value.append(NSAttributedString(string: text, attributes: attributes))
                    } else {
                        value.append(NSAttributedString(string: run.text, attributes: attributes))
                    }
                }
                if !value.string.hasSuffix("\n") && !value.string.hasSuffix("\r") {
                    value.append(NSAttributedString(string: "\n", attributes: last))
                }
                var ordinaryLineHeight: CGFloat?
                if paragraph.runs.allSatisfy({ run in
                    run.image == nil && run.style.superscript == 0 &&
                    !run.text.unicodeScalars.contains(where: { $0.value > 0xffff })
                }) {
                    var natural: CGFloat = 0
                    var roundedHeights: Set<Int> = []
                    value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, _, _ in
                        if let font = font as? NSFont {
                            let measured = font.ascender - font.descender + font.leading
                            if measured.isFinite && measured > 0 {
                                natural = max(natural, measured)
                                roundedHeights.insert(Int(ceil(measured)))
                            }
                        }
                    }
                    if natural > 0 && natural.isFinite {
                        if roundedHeights.count > 1 {
                            let text = value.string as NSString
                            let terminatorLength = value.string.hasSuffix("\r\n") ? 2 : 1
                            let body = text.substring(to: max(0, text.length - terminatorLength))
                            let available = width - CGFloat(max(paragraph.style.leftIndent,
                                paragraph.style.leftIndent + paragraph.style.firstLineIndent))
                                - CGFloat(paragraph.style.rightIndent)
                            // Applying one maximum height to wrapped mixed-size
                            // text can move every subsequent line. Until per-line
                            // Swing metrics are verified, reject that layout
                            // instead of silently changing its pagination.
                            guard body.rangeOfCharacter(from: .newlines) == nil,
                                  available > 0, value.size().width <= available + 0.25 else {
                                throw ConversionFailure("Farklı yazı yüksekliği içeren çok satırlı UDF paragrafının düzeni henüz doğrulanmadı.")
                            }
                        }
                        // The official Swing exporter advances ordinary lines
                        // by its rounded natural font metrics (Times 12 -> 14pt),
                        // rather than Cocoa's larger default line fragment.
                        ordinaryLineHeight = ceil(natural) * CGFloat(1 + paragraph.style.lineSpacing)
                    }
                }
                let style = paragraphAttributes(paragraph.style, parents: parents,
                                                ordinaryLineHeight: ordinaryLineHeight)
                value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
                result.append(value)
            case .image(let image):
                let value = NSMutableAttributedString(attributedString: try imageText(image, width: width))
                let style = NSMutableParagraphStyle()
                style.textBlocks = parents
                value.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1)]))
                value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
                result.append(value)
            case .table(let source):
                try appendTable(source, to: result, parents: parents, width: width, depth: depth)
            case .pageBreak:
                throw ConversionFailure("Üstbilgi, altbilgi veya tablo içinde açık sayfa sonu desteklenmiyor.")
            }
        }

        private func appendTable(_ source: UDFTable, to result: NSMutableAttributedString,
                                 parents: [NSTextBlock], width: CGFloat, depth: Int) throws {
            guard !source.rows.isEmpty else { throw ConversionFailure("UDF tablosunda satır bulunamadı.") }
            var occupied = Array(repeating: Set<Int>(), count: source.rows.count)
            var positions: [[Int]] = []
            var columns = source.columnWidths.count
            for (rowIndex, row) in source.rows.enumerated() {
                var rowPositions: [Int] = []
                var column = 0
                for cell in row.cells {
                    while occupied[rowIndex].contains(column) { column += 1 }
                    guard cell.columnSpan >= 1, cell.rowSpan >= 1,
                          rowIndex + cell.rowSpan <= source.rows.count,
                          column + cell.columnSpan <= 128 else {
                        throw ConversionFailure("UDF tablo hücre birleşimi geçersiz.")
                    }
                    for r in rowIndex..<(rowIndex + cell.rowSpan) {
                        for c in column..<(column + cell.columnSpan) {
                            guard occupied[r].insert(c).inserted else {
                                throw ConversionFailure("UDF tablo hücreleri çakışıyor.")
                            }
                        }
                    }
                    rowPositions.append(column)
                    column += cell.columnSpan
                    columns = max(columns, column)
                }
                positions.append(rowPositions)
            }
            guard columns > 0, columns <= 128,
                  occupied.allSatisfy({ $0.count == columns }) else {
                throw ConversionFailure("UDF tablosunun sütun yerleşimi tamamlanamıyor.")
            }
            // Canonical UYAP columnSpans are proportional weights across the
            // available document width. Its serialized table width is not a
            // fixed rendered width (120,220 -> 180,330 in a 510pt body).
            let tableWidth = width
            guard tableWidth > 0, tableWidth.isFinite else {
                throw ConversionFailure("UDF tablosu sayfa genişliğine sığmıyor.")
            }
            let widths: [CGFloat]
            if !source.columnWidths.isEmpty {
                guard source.columnWidths.count == columns else {
                    throw ConversionFailure("UDF tablo sütun ölçülerinin sayısı uyuşmuyor.")
                }
                let weights = source.columnWidths.map { CGFloat($0) }
                let total = weights.reduce(0, +)
                guard weights.allSatisfy({ $0.isFinite && $0 > 0 }), total.isFinite, total > 0 else {
                    throw ConversionFailure("UDF tablo sütun oranları geçersiz.")
                }
                widths = weights.map { tableWidth * $0 / total }
            } else {
                widths = Array(repeating: tableWidth / CGFloat(columns), count: columns)
            }
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setContentWidth(tableWidth, type: .absoluteValueType)
            table.setWidth(0, type: .absoluteValueType, for: .padding)
            table.setWidth(0, type: .absoluteValueType, for: .border)
            table.setWidth(0, type: .absoluteValueType, for: .margin)
            for (rowIndex, row) in source.rows.enumerated() {
                for (index, cell) in row.cells.enumerated() {
                    let column = positions[rowIndex][index]
                    let tableBlock = NSTextTableBlock(table: table, startingRow: rowIndex,
                                                     rowSpan: cell.rowSpan, startingColumn: column,
                                                     columnSpan: cell.columnSpan)
                    let cellWidth = widths[column..<(column + cell.columnSpan)].reduce(0, +)
                    guard cellWidth > 4, cellWidth <= tableWidth + 1 else {
                        throw ConversionFailure("UDF tablo hücresinin genişliği geçersiz.")
                    }
                    if cell.width != nil {
                        throw ConversionFailure("Ayrı sabit hücre genişliği bu UDF tablo düzeninde henüz doğrulanmadı.")
                    }
                    let contentWidth = cellWidth
                    tableBlock.setContentWidth(contentWidth, type: .absoluteValueType)
                    tableBlock.setWidth(0, type: .absoluteValueType, for: .padding)
                    tableBlock.setWidth(0, type: .absoluteValueType, for: .border)
                    tableBlock.setWidth(0, type: .absoluteValueType, for: .margin)
                    tableBlock.verticalAlignment = .topAlignment
                    if let color = cell.backgroundRGB { tableBlock.backgroundColor = rgb(color) }
                    let nested = parents + [tableBlock]
                    let start = result.length
                    if cell.blocks.isEmpty {
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = nested
                        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style]))
                    } else {
                        for block in cell.blocks {
                            try append(block, to: result, parents: nested, width: contentWidth, depth: depth + 1)
                        }
                    }
                    var edges = 0
                    switch source.border {
                    case .none: break
                    case .grid: edges = 15
                    case .outer:
                        if rowIndex == 0 { edges |= 1 }
                        if column + cell.columnSpan == columns { edges |= 2 }
                        if rowIndex + cell.rowSpan == source.rows.count { edges |= 4 }
                        if column == 0 { edges |= 8 }
                    }
                    if edges != 0 {
                        let characters = NSRange(location: start, length: result.length - start)
                        let overlay = CellBorder(block: tableBlock, edges: edges, characterRange: characters)
                        var ranges: [(NSRange, [CellBorder])] = []
                        result.enumerateAttribute(UDFRenderer.cellBorderAttribute, in: characters) { value, range, _ in
                            ranges.append((range, (value as? [CellBorder] ?? []) + [overlay]))
                        }
                        for (range, overlays) in ranges {
                            result.addAttribute(UDFRenderer.cellBorderAttribute, value: overlays, range: range)
                        }
                    }
                }
            }
        }

        private func imageText(_ source: UDFImage, width available: CGFloat) throws -> NSAttributedString {
            guard source.data.count <= 64 * 1024 * 1024,
                  let imageSource = CGImageSourceCreateWithData(source.data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= 20000, pixelHeight <= 20000,
                  pixelWidth <= 64_000_000 / pixelHeight else {
                throw ConversionFailure("UDF içindeki görsel okunamadı veya boyut sınırını aşıyor.")
            }
            let pixels = pixelWidth * pixelHeight
            guard pixels <= 64_000_000 - decodedImagePixels else {
                throw ConversionFailure("UDF görsellerinin toplamı 64 milyon piksel sınırını aşıyor.")
            }
            decodedImagePixels += pixels
            let natural = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            let width = CGFloat(source.width ?? source.height.map { $0 * Double(natural.width / natural.height) } ?? Double(natural.width))
            let height = CGFloat(source.height ?? Double(width * natural.height / natural.width))
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= available + 1, height <= 2880 else {
                throw ConversionFailure("UDF görseli ayrılan alana sığmıyor; boyutu değiştirilmedi.")
            }
            guard let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ConversionFailure("UDF içindeki görsel çözümlenemedi.")
            }
            let image = NSImage(cgImage: decoded, size: NSSize(width: width, height: height))
            let attachment = NSTextAttachment()
            image.size = NSSize(width: width, height: height)
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let cell = NSTextAttachmentCell(imageCell: image)
            attachment.attachmentCell = cell
            return NSAttributedString(attachment: attachment)
        }

        private func characterAttributes(_ style: UDFCharacterStyle) throws -> [NSAttributedString.Key: Any] {
            let family = style.family.trimmingCharacters(in: .whitespacesAndNewlines)
            var traits: NSFontTraitMask = []
            if style.bold { traits.insert(.boldFontMask) }
            if style.italic { traits.insert(.italicFontMask) }
            guard style.size.isFinite, style.size >= 1, style.size <= 300,
                  let font = NSFontManager.shared.font(withFamily: family, traits: traits,
                                                       weight: style.bold ? 9 : 5, size: CGFloat(style.size)) else {
                throw ConversionFailure("UDF yazı tipi bu Mac'te bulunamadı: \(family). Düzen değiştirilmeden dönüştürülemedi.")
            }
            // Swing/AWT does not request optional kerning or ligatures by
            // default. CoreText otherwise enables font kerning implicitly;
            // this changes legal-document line wraps (TA/PA pairs, fi, etc.).
            // Zero optional ligatures still preserves shaping required by the
            // writing system, such as Arabic ligatures.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.black,
                .kern: 0, .ligature: 0
            ]
            if let color = style.foregroundRGB { attributes[.foregroundColor] = rgb(color) }
            if let color = style.backgroundRGB { attributes[.backgroundColor] = rgb(color) }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if style.superscript != 0 { attributes[.superscript] = style.superscript }
            return attributes
        }

        private func paragraphAttributes(_ source: UDFParagraphStyle, parents: [NSTextBlock],
                                         ordinaryLineHeight: CGFloat?) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            switch source.alignment {
            case .left: style.alignment = .left
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            case .justified: style.alignment = .justified
            }
            style.headIndent = CGFloat(source.leftIndent)
            style.firstLineHeadIndent = CGFloat(source.leftIndent + source.firstLineIndent)
            style.tailIndent = -CGFloat(source.rightIndent)
            style.paragraphSpacingBefore = CGFloat(source.spaceBefore)
            style.paragraphSpacing = CGFloat(source.spaceAfter)
            // Swing's lineSpacing is a multiplier of the ordinary line height,
            // with 0 meaning single spacing, 0.5 meaning one-and-a-half spacing.
            if let height = ordinaryLineHeight {
                style.minimumLineHeight = height
                style.maximumLineHeight = height
                style.lineHeightMultiple = 1
            } else {
                // Attachments, supplementary fallback glyphs and superscripts
                // must retain their own (possibly taller) line fragments.
                style.lineHeightMultiple = CGFloat(1 + source.lineSpacing)
            }
            style.lineBreakMode = .byWordWrapping
            style.tabStops = source.tabStops.map { NSTextTab(textAlignment: .left, location: CGFloat($0), options: [:]) }
            style.defaultTabInterval = 72
            style.textBlocks = parents
            return style
        }

        private func rgb(_ value: UInt32) -> NSColor {
            // The model's historical *RGB names contain Java's full ARGB
            // color value. Preserve opacity, including genuinely invisible
            // text; #RRGGBB parsing supplies an opaque alpha byte upstream.
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255,
                    alpha: CGFloat((value >> 24) & 255) / 255)
        }
    }
}
