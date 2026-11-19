import AppKit
import Foundation
import ImageIO
import PDFKit

struct ConversionResult {
    let input: URL
    let output: URL?
    let error: String?
}

struct ConversionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

@MainActor
final class ConversionEngine {
    static let supportedExtensions: Set<String> = [
        "udf", "pdf", "tif", "tiff", "jpg", "jpeg", "png", "bmp", "gif", "html", "htm", "zip", "rar", "eyp"
    ]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "eyp"]
    private let files = FileManager.default

    private struct WorkItem {
        let source: URL
        let displayedSource: URL
        let outputFolder: URL
    }

    func convert(
        inputs: [URL],
        outputDirectory: URL,
        archivesCopyPDFOnly: Bool,
        progress: @escaping (Int, Int, String) -> Void
    ) async -> [ConversionResult] {
        let access = SecurityScopedAccess(urls: inputs + [outputDirectory])
        defer { access.close() }
        var results: [ConversionResult] = []
        var temporaryDirectories: [URL] = []
        defer {
            for directory in temporaryDirectories { try? files.removeItem(at: directory) }
        }

        let output = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var pending: [WorkItem] = []
        do {
            try ensureDirectory(output)
            let sources = try selectedFiles(inputs, excluding: output)
            guard !sources.isEmpty else {
                throw ConversionFailure("Seçimde desteklenen belge bulunamadı.")
            }
            for source in sources {
                if !Self.archiveExtensions.contains(source.pathExtension.lowercased()) {
                    pending.append(WorkItem(source: source, displayedSource: source, outputFolder: output))
                    continue
                }

                progress(0, sources.count, "Arşiv okunuyor: \(source.lastPathComponent)")
                do {
                    let temporary = try makeTemporaryDirectory()
                    temporaryDirectories.append(temporary)
                    let extensions = archivesCopyPDFOnly
                        ? "pdf"
                        : "pdf,udf,tif,tiff,jpg,jpeg,png,bmp,gif,html,htm"
                    try await Task.detached(priority: .userInitiated) {
                        try ArchiveAccess.extract(source: source, destination: temporary, extensions: extensions)
                    }.value
                    let extracted = try selectedFiles([temporary], excluding: output)
                    if extracted.isEmpty {
                        throw ConversionFailure("Arşivde işlenebilecek desteklenen belge bulunamadı.")
                    }
                    let archiveFolder = output.appendingPathComponent(source.deletingPathExtension().lastPathComponent, isDirectory: true)
                    for document in extracted {
                        let relative = String(document.path.dropFirst(temporary.path.count + 1))
                        let parent = (relative as NSString).deletingLastPathComponent
                        let folder = parent.isEmpty ? archiveFolder : archiveFolder.appendingPathComponent(parent, isDirectory: true)
                        pending.append(WorkItem(
                            source: document,
                            displayedSource: source.appendingPathComponent(relative),
                            outputFolder: folder
                        ))
                    }
                } catch {
                    results.append(ConversionResult(input: source, output: nil, error: error.localizedDescription))
                }
            }
        } catch {
            return [ConversionResult(input: outputDirectory, output: nil, error: error.localizedDescription)]
        }

        for (index, item) in pending.enumerated() {
            if Task.isCancelled {
                results.append(ConversionResult(input: item.displayedSource, output: nil, error: "İşlem durduruldu."))
                break
            }
            progress(index, pending.count, item.displayedSource.lastPathComponent)
            do {
                try ensureDirectory(item.outputFolder, beneath: output)
                let stagedPDF = item.outputFolder.appendingPathComponent(".udfpdf-\(UUID().uuidString).pdf")
                defer { try? files.removeItem(at: stagedPDF) }
                try await makePDF(input: item.source, output: stagedPDF)
                try NativePDF.validate(stagedPDF)
                let destination = try publishUnique(
                    stagedPDF,
                    folder: item.outputFolder,
                    stem: item.source.deletingPathExtension().lastPathComponent
                )
                results.append(ConversionResult(input: item.displayedSource, output: destination, error: nil))
            } catch {
                results.append(ConversionResult(input: item.displayedSource, output: nil, error: error.localizedDescription))
            }
            progress(index + 1, pending.count, item.displayedSource.lastPathComponent)
        }
        return results
    }

    func mergePDFs(inputs: [URL], output: URL) throws {
        let access = SecurityScopedAccess(urls: inputs + [output])
        defer { access.close() }
        guard !inputs.isEmpty else { throw ConversionFailure("Birleştirmek için PDF seçin.") }
        let merged = PDFDocument()
        for input in inputs {
            let document = try NativePDF.open(input)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else {
                    throw ConversionFailure("PDF sayfası okunamadı: \(input.lastPathComponent)")
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        try writeDocument(merged, output: output)
    }

    func extractPDF(input: URL, pages: [Int], output: URL) throws {
        let access = SecurityScopedAccess(urls: [input, output])
        defer { access.close() }
        let original = try NativePDF.open(input)
        guard !pages.isEmpty, pages.allSatisfy({ $0 > 0 && $0 <= original.pageCount }) else {
            throw ConversionFailure("Sayfa numaraları 1 ile \(original.pageCount) arasında olmalıdır.")
        }
        let extracted = PDFDocument()
        for number in pages {
            guard let page = original.page(at: number - 1)?.copy() as? PDFPage else {
                throw ConversionFailure("Seçili PDF sayfası okunamadı.")
            }
            extracted.insert(page, at: extracted.pageCount)
        }
        try writeDocument(extracted, output: output)
    }

    private func makePDF(input: URL, output: URL) async throws {
        let values = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConversionFailure("Yalnızca normal belge dosyaları işlenebilir.")
        }
        guard let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else {
            throw ConversionFailure("Belge boş veya 256 MB boyut sınırını aşıyor.")
        }
        switch input.pathExtension.lowercased() {
        case "pdf":
            try NativePDF.validate(input)
            try files.copyItem(at: input, to: output)
        case "udf":
            try await convertUDF(input: input, output: output)
        case "html", "htm":
            guard size <= 16 * 1024 * 1024 else {
                throw ConversionFailure("HTML belgesi 16 MB sınırını aşıyor.")
            }
            let data = try OfflineHTMLRenderer.render(input: input)
            try NativePDF.writePaginatedHTML(data: data, output: output)
        case "tif", "tiff", "jpg", "jpeg", "png", "bmp", "gif":
            try await Task.detached(priority: .userInitiated) {
                try NativePDF.convertImages(input: input, output: output)
            }.value
        default:
            throw ConversionFailure("Bu dosya türü desteklenmiyor.")
        }
    }

    private func convertUDF(input: URL, output: URL) async throws {
        let document = try await Task.detached(priority: .userInitiated) {
            try UDFDocument.load(from: input)
        }.value
        try UDFRenderer.render(document, to: output)
    }

    private func selectedFiles(_ selected: [URL], excluding output: URL) throws -> [URL] {
        var documents: [URL] = []
        var seen: Set<String> = []
        for selection in selected {
            let source = selection.standardizedFileURL
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory != true {
                if Self.supportedExtensions.contains(source.pathExtension.lowercased()), seen.insert(source.path).inserted {
                    documents.append(source)
                }
                continue
            }
            guard let enumerator = files.enumerator(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { throw ConversionFailure("Klasör okunamadı: \(source.lastPathComponent)") }
            for case let document as URL in enumerator {
                let attributes = try document.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if attributes.isSymbolicLink == true || document.standardizedFileURL == output || document.lastPathComponent == "PDF-UYAP" {
                    if attributes.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if attributes.isRegularFile == true,
                   Self.supportedExtensions.contains(document.pathExtension.lowercased()),
                   seen.insert(document.path).inserted {
                    documents.append(document)
                }
            }
        }
        return documents.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func ensureDirectory(_ directory: URL, beneath root: URL? = nil) throws {
        if let root = root {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard directory.path == root.path || directory.path.hasPrefix(prefix) else {
                throw ConversionFailure("Çıktı yolu seçilen klasörün dışında.")
            }
            var current = root
            let suffix = String(directory.path.dropFirst(root.path.count)).split(separator: "/")
            for part in suffix {
                current.appendPathComponent(String(part), isDirectory: true)
                if let attributes = try? files.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ConversionFailure("Çıktı alt klasöründe sembolik bağlantı kullanılamaz.")
                }
            }
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = files.temporaryDirectory.appendingPathComponent("UdfPdf-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func publishUnique(_ staged: URL, folder: URL, stem: String) throws -> URL {
        for suffix in 0..<10000 {
            let name = suffix == 0 ? "\(stem).pdf" : "\(stem) (\(suffix + 1)).pdf"
            let destination = folder.appendingPathComponent(name)
            do {
                try files.copyItem(at: staged, to: destination)
                return destination
            } catch {
                if files.fileExists(atPath: destination.path) { continue }
                throw error
            }
        }
        throw ConversionFailure("Çıktı için kullanılabilir bir dosya adı bulunamadı.")
    }

    private func writeDocument(_ document: PDFDocument, output: URL) throws {
        guard let data = document.dataRepresentation(), document.pageCount > 0 else {
            throw ConversionFailure("PDF oluşturulamadı.")
        }
        // NSSavePanel grants the selected file, not arbitrary siblings in its
        // parent. Stage in the app container before publishing that exact file.
        let staged = files.temporaryDirectory.appendingPathComponent(".udfpdf-\(UUID().uuidString).pdf")
        defer { try? files.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        try NativePDF.validate(staged)
        do {
            try files.copyItem(at: staged, to: output)
        } catch {
            if files.fileExists(atPath: output.path) {
                throw ConversionFailure("Bu adda dosya zaten var. Farklı bir çıktı adı seçin.")
            }
            throw error
        }
    }
}

private enum ArchiveAccess {
    static func extract(source: URL, destination: URL, extensions: String) throws {
        var message = [CChar](repeating: 0, count: 2048)
        let messageCapacity = message.count
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                extensions.withCString { selectedExtensions in
                    ah_extract_archive(sourcePath, destinationPath, selectedExtensions, &message, messageCapacity)
                }
            }
        }
        if result != 0 {
            throw ConversionFailure("Arşiv açılamadı: \(String(cString: message))")
        }
    }
}

private enum NativePDF {
    static func open(_ source: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else {
            throw ConversionFailure("PDF okunamadı veya parola korumalı: \(source.lastPathComponent)")
        }
        return document
    }

    static func validate(_ source: URL) throws {
        _ = try open(source)
    }

    static func convertImages(input: URL, output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ConversionFailure("Görsel okunamadı.")
        }
        let count = CGImageSourceGetCount(imageSource)
        guard count > 0, count <= 1000 else { throw ConversionFailure("Görselin sayfa sayısı geçersiz veya 1000 sınırını aşıyor.") }
        var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionFailure("PDF çıktı dosyası oluşturulamadı.")
        }
        defer { context.closePDF() }
        let pages = input.pathExtension.lowercased() == "gif" ? 1 : count
        for index in 0..<pages {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6400,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, index, options as CFDictionary) else {
                throw ConversionFailure("Görsel sayfası okunamadı: \(index + 1)")
            }
            let landscape = image.width > image.height
            var page = landscape ? CGRect(x: 0, y: 0, width: 841.89, height: 595.28) : mediaBox
            let pageData = Data(bytes: &page, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageData] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            let available = page.insetBy(dx: 24, dy: 24)
            let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let target = CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
            context.interpolationQuality = .high
            context.draw(image, in: target)
            context.endPDFPage()
        }
    }

    static func writePaginatedHTML(data: Data, output: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData), let original = CGPDFDocument(provider) else {
            throw ConversionFailure("HTML belgesinden PDF oluşturulamadı.")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionFailure("HTML için PDF çıktı dosyası açılamadı.")
        }
        defer { context.closePDF() }
        let content = mediaBox.insetBy(dx: 30, dy: 30)
        guard original.numberOfPages > 0 else { throw ConversionFailure("HTML PDF belgesi boş.") }
        for pageNumber in 1...original.numberOfPages {
            guard let page = original.page(at: pageNumber) else { throw ConversionFailure("HTML PDF sayfası okunamadı.") }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { throw ConversionFailure("HTML PDF boyutları geçersiz.") }
            let scale = content.width / bounds.width
            let sliceCount = max(1, Int(ceil(bounds.height * scale / content.height)))
            guard sliceCount <= 1000 else { throw ConversionFailure("HTML belgesi 1000 sayfa sınırını aşıyor.") }
            for slice in 0..<sliceCount {
                context.beginPDFPage(nil)
                context.saveGState()
                context.clip(to: content)
                context.translateBy(x: content.minX - bounds.minX * scale, y: content.maxY - bounds.maxY * scale + CGFloat(slice) * content.height)
                context.scaleBy(x: scale, y: scale)
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
        }
    }
}

