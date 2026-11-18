import AppKit
import Darwin
import PDFKit
import UniformTypeIdentifiers

@main
struct ConverterApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "--self-test", arguments.count == 2 {
            application.setActivationPolicy(.prohibited)
            Task {
                let status = await MacSelfTest.run(at: URL(fileURLWithPath: arguments[1], isDirectory: true))
                exit(status)
            }
            application.run()
            return
        }

        if arguments.first == "--batch", arguments.count == 3 {
            application.setActivationPolicy(.prohibited)
            Task {
                let engine = ConversionEngine()
                let results = await engine.convert(
                    inputs: [URL(fileURLWithPath: arguments[1])],
                    outputDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true),
                    archivesCopyPDFOnly: false
                ) { completed, total, name in
                    print("[\(completed)/\(total)] \(name)")
                }
                for result in results {
                    if let error = result.error {
                        fputs("HATA: \(result.input.lastPathComponent): \(error)\n", stderr)
                    } else if let output = result.output {
                        print("PDF: \(output.path)")
                    }
                }
                exit(results.isEmpty || results.contains(where: { $0.error != nil }) ? 1 : 0)
            }
            application.run()
            return
        }

        var uiSmokeDestination: URL?
        if arguments.first == "--ui-smoke", arguments.count == 2 {
            uiSmokeDestination = URL(fileURLWithPath: arguments[1])
        } else if !arguments.isEmpty {
            fputs("Kullanım: --batch <kaynak dosya veya klasör> <çıktı klasörü> veya --ui-smoke <PNG dosyası>\n", stderr)
            exit(2)
        }

        application.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate(uiSmokeDestination: uiSmokeDestination)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var converter: ConverterWindowController?
    private let uiSmokeDestination: URL?

    init(uiSmokeDestination: URL? = nil) {
        self.uiSmokeDestination = uiSmokeDestination
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ConverterWindowController()
        converter = controller
        installMenu(for: controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let destination = uiSmokeDestination {
            Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try controller.captureInitialWindow(to: destination)
                    print("UI_SMOKE_OK \(destination.path)")
                    exit(0)
                } catch {
                    fputs("UI_SMOKE_FAILED: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu(for controller: ConverterWindowController) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "Hakkımızda", action: #selector(ConverterWindowController.showAbout), keyEquivalent: "")
        about.target = controller
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Dosya")
        let choose = NSMenuItem(title: "Dosya seç…", action: #selector(ConverterWindowController.chooseFiles), keyEquivalent: "o")
        choose.target = controller
        fileMenu.addItem(choose)
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Düzenle")
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

@MainActor
private final class ConverterWindowController: NSWindowController {
    private let engine = ConversionEngine()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "Henüz dosya veya klasör seçilmedi.")
    private let outputLabel = NSTextField(string: "")
    private let progress = NSProgressIndicator()
    private let log = NSTextView()
    private var inputs: [URL] = []
    private var outputDirectory: URL?
    private var isRunning = false
    private var selectionButtons: [NSButton] = []
    private var mergeController: MergeWindowController?
    private var splitController: SplitWindowController?

    private lazy var chooseOutputButton = NSButton(title: "Çıktı klasörünü seç", target: self, action: #selector(chooseOutput))
    private lazy var startButton = NSButton(title: "PDF’ye dönüştür", target: self, action: #selector(startConversion))
    private lazy var openButton = NSButton(title: "PDF klasörünü aç", target: self, action: #selector(openOutput))
    private lazy var archiveOnly = NSButton(checkboxWithTitle: "Arşivlerden yalnız hazır PDF’leri çıkar", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Toplu UDF PDF Çevirici · Mac 1.04 Önizleme"
        window.minSize = NSSize(width: 690, height: 590)
        window.center()
        super.init(window: window)
        buildContents()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])

        let title = NSTextField(labelWithString: "Toplu UDF PDF Çevirici")
        title.font = .boldSystemFont(ofSize: 23)
        column.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "UDF, HTML ve görselleri topluca PDF’ye dönüştürün. ZIP, RAR ve ZIP tabanlı EYP arşivlerindeki belgeleri işleyin.")
        intro.font = .systemFont(ofSize: 13)
        column.addArrangedSubview(intro)

        let folder = NSButton(title: "Klasör seç", target: self, action: #selector(chooseFolder))
        let udf = NSButton(title: "UDF seç", target: self, action: #selector(chooseUdf))
        let files = NSButton(title: "Dosya seç", target: self, action: #selector(chooseFiles))
        selectionButtons = [folder, udf, files]
        column.addArrangedSubview(buttonRow(selectionButtons))
        sourceLabel.maximumNumberOfLines = 2
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.isSelectable = true
        column.addArrangedSubview(sourceLabel)
        column.addArrangedSubview(archiveOnly)
        column.addArrangedSubview(NSTextField(labelWithString: "PDF’lerin kaydedileceği klasör"))
        outputLabel.isEditable = false
        outputLabel.isSelectable = true
        outputLabel.lineBreakMode = .byTruncatingMiddle
        column.addArrangedSubview(outputLabel)
        chooseOutputButton.isEnabled = false
        startButton.isEnabled = false
        startButton.bezelStyle = .rounded
        openButton.isEnabled = false
        column.addArrangedSubview(buttonRow([chooseOutputButton, startButton, openButton]))

        let merge = NSButton(title: "PDF birleştir", target: self, action: #selector(showMerge))
        let split = NSButton(title: "PDF ayır / sayfa çıkar", target: self, action: #selector(showSplit))
        let about = NSButton(title: "Hakkımızda ve uygulamalar", target: self, action: #selector(showAbout))
        column.addArrangedSubview(buttonRow([merge, split, about]))

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        column.addArrangedSubview(progress)

        log.isEditable = false
        log.isSelectable = true
        log.setAccessibilityLabel("İşlem günlüğü")
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = log
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        column.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let requirements = NSTextField(wrappingLabelWithString: "Belgeler bilgisayarınızda işlenir. UDF dönüşümü için Mac’e uygun UYAP Doküman Editörü kurulu olmalıdır.")
        requirements.font = .systemFont(ofSize: 11)
        requirements.textColor = .secondaryLabelColor
        column.addArrangedSubview(requirements)
        let fullWidthViews: [NSView] = [intro, sourceLabel, outputLabel, progress, scroll, requirements]
        for view in fullWidthViews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    func captureInitialWindow(to destination: URL) throws {
        guard let window = window, window.isVisible, let content = window.contentView,
              !isRunning, inputs.isEmpty, selectionButtons.count == 3,
              selectionButtons.allSatisfy({ $0.isEnabled && !$0.isHidden }),
              !startButton.isEnabled, !chooseOutputButton.isEnabled else {
            throw ValidationError("Ana pencere veya başlangıç denetimleri beklenen durumda değil.")
        }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard content.bounds.width >= 600, content.bounds.height >= 500,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw ValidationError("Ana pencerenin görüntüsü oluşturulamadı.")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ValidationError("Ana pencerenin PNG çıktısı oluşturulamadı.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    @objc func chooseFolder() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Belgelerin bulunduğu klasörü seçin"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let folder = panel.url {
            setSelection([folder], defaultBase: folder)
        }
    }

    @objc func chooseUdf() { selectFiles(udfOnly: true) }
    @objc func chooseFiles() { selectFiles(udfOnly: false) }

    private func selectFiles(udfOnly: Bool) {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = udfOnly ? "UDF belgelerini seçin" : "Dönüştürülecek belgeleri seçin"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let extensions = udfOnly ? ["udf"] : ConversionEngine.supportedExtensions.sorted()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        if panel.runModal() == .OK, let first = panel.urls.first {
            setSelection(panel.urls, defaultBase: first.deletingLastPathComponent())
        }
    }

    private func setSelection(_ urls: [URL], defaultBase: URL) {
        inputs = urls
        sourceLabel.stringValue = urls.count == 1 ? urls[0].path : "\(urls.count) dosya seçildi. İlk dosya: \(urls[0].lastPathComponent)"
        outputDirectory = defaultBase.appendingPathComponent("PDF-UYAP", isDirectory: true)
        outputLabel.stringValue = outputDirectory?.path ?? ""
        chooseOutputButton.isEnabled = true
        startButton.isEnabled = true
        openButton.isEnabled = false
        log.string = ""
        progress.doubleValue = 0
    }

    @objc private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "PDF çıktı klasörünü seçin"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let folder = panel.url {
            outputDirectory = folder
            outputLabel.stringValue = folder.path
        }
    }

    @objc private func startConversion() {
        guard !isRunning, !inputs.isEmpty, let output = outputDirectory else { return }
        isRunning = true
        setBusy(true)
        log.string = "İşlem başladı.\n"
        let selectedInputs = inputs
        let copyPDFOnly = archiveOnly.state == .on
        Task { @MainActor in
            let results = await engine.convert(inputs: selectedInputs, outputDirectory: output, archivesCopyPDFOnly: copyPDFOnly) { [weak self] completed, total, name in
                guard let self = self else { return }
                self.progress.maxValue = Double(max(total, 1))
                self.progress.doubleValue = Double(completed)
                self.appendLog("[\(completed)/\(total)] \(name)")
            }
            var successes = 0
            for result in results {
                if let error = result.error {
                    appendLog("HATA · \(result.input.lastPathComponent): \(error)")
                } else if let file = result.output {
                    successes += 1
                    appendLog("PDF · \(file.lastPathComponent)")
                }
            }
            appendLog(results.isEmpty ? "Desteklenen dosya bulunamadı." : "Tamamlandı. \(successes) PDF oluşturuldu, \(results.filter { $0.error != nil }.count) işlem başarısız.")
            isRunning = false
            setBusy(false)
            openButton.isEnabled = FileManager.default.fileExists(atPath: output.path)
        }
    }

    private func setBusy(_ busy: Bool) {
        selectionButtons.forEach { $0.isEnabled = !busy }
        chooseOutputButton.isEnabled = !busy
        startButton.isEnabled = !busy
        archiveOnly.isEnabled = !busy
        openButton.isEnabled = !busy && outputDirectory != nil
    }

    private func appendLog(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        log.scrollToEndOfDocument(nil)
    }

    @objc private func openOutput() {
        guard let folder = outputDirectory else { return }
        NSWorkspace.shared.open(folder)
    }

    @objc private func showMerge() {
        if mergeController == nil { mergeController = MergeWindowController(engine: engine) }
        mergeController?.showWindow(nil)
        mergeController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSplit() {
        if splitController == nil { splitController = SplitWindowController(engine: engine) }
        splitController?.showWindow(nil)
        splitController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Toplu UDF PDF Çevirici · Mac 1.04 Önizleme"
        alert.informativeText = "Analiz Hukuk\n\nKlasör veya dosya seçerek belgeleri PDF’ye hazırlamak için ücretsiz yardımcı uygulama. Belgeler bilgisayarınızda işlenir.\n\nMac sürümü geliştirme ve uyumluluk testi aşamasındadır."
        alert.addButton(withTitle: "Tamam")
        alert.addButton(withTitle: "Diğer uygulamalar")
        alert.addButton(withTitle: "Gizlilik")
        let response = alert.runModal()
        let destination: String?
        switch response {
        case .alertSecondButtonReturn: destination = "https://analizhukukburosu.org/uygulamalar"
        case .alertThirdButtonReturn: destination = "https://analizhukukburosu.org/uygulamalar/toplu-udf-pdf/gizlilik"
        default: destination = nil
        }
        if let address = destination, let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
private final class MergeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let engine: ConversionEngine
    private let table = NSTableView()
    private var files: [URL] = []
    private let status = NSTextField(wrappingLabelWithString: "PDF’leri ekleyin ve birleştirme sırasını düzenleyin.")
    private lazy var mergeButton = NSButton(title: "Birleştir ve kaydet…", target: self, action: #selector(merge))

    init(engine: ConversionEngine) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "PDF birleştir"
        window.minSize = NSSize(width: 580, height: 350)
        window.center()
        super.init(window: window)
        buildContents()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        column.addArrangedSubview(status)
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        name.title = "PDF dosyaları · Yukarıdan aşağıya birleştirilir"
        name.width = 650
        table.addTableColumn(name)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        column.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let add = NSButton(title: "PDF dosyaları ekle…", target: self, action: #selector(addFiles))
        let remove = NSButton(title: "Kaldır", target: self, action: #selector(removeFile))
        let up = NSButton(title: "Yukarı", target: self, action: #selector(moveSelectedPDFUp))
        let down = NSButton(title: "Aşağı", target: self, action: #selector(moveSelectedPDFDown))
        column.addArrangedSubview(buttonRow([add, remove, up, down]))
        mergeButton.isEnabled = false
        column.addArrangedSubview(mergeButton)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "\(row + 1). \(files[row].lastPathComponent)")
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = files[row].path
        return field
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Birleştirilecek PDF dosyalarını seçin"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for file in panel.urls where !files.contains(file) { files.append(file) }
            table.reloadData()
            mergeButton.isEnabled = files.count >= 2
            status.stringValue = "\(files.count) PDF eklendi. Sıra için dosyayı seçip Yukarı veya Aşağı düğmesini kullanın."
        }
    }

    @objc private func removeFile() {
        let row = table.selectedRow
        guard files.indices.contains(row) else { return }
        files.remove(at: row)
        table.reloadData()
        if !files.isEmpty { table.selectRowIndexes(IndexSet(integer: min(row, files.count - 1)), byExtendingSelection: false) }
        mergeButton.isEnabled = files.count >= 2
    }

    @objc private func moveSelectedPDFUp() { moveSelection(by: -1) }
    @objc private func moveSelectedPDFDown() { moveSelection(by: 1) }

    private func moveSelection(by offset: Int) {
        let row = table.selectedRow
        let destination = row + offset
        guard files.indices.contains(row), files.indices.contains(destination) else { return }
        files.swapAt(row, destination)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        table.scrollRowToVisible(destination)
    }

    @objc private func merge() {
        guard files.count >= 2, let output = pdfSaveDestination(title: "Birleştirilmiş PDF’yi kaydedin", name: "Birlesik.pdf") else { return }
        do {
            try engine.mergePDFs(inputs: files, output: output)
            status.stringValue = "Kaydedildi: \(output.path)"
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            showError(error)
        }
    }
}

@MainActor
private final class SplitWindowController: NSWindowController {
    private let engine: ConversionEngine
    private var input: URL?
    private let source = NSTextField(wrappingLabelWithString: "Bir PDF dosyası seçin.")
    private let pageRange = NSTextField(string: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var exportButton = NSButton(title: "Seçili sayfaları kaydet…", target: self, action: #selector(exportPages))
    private lazy var splitButton = NSButton(title: "Her sayfayı ayrı PDF yap…", target: self, action: #selector(splitEveryPage))

    init(engine: ConversionEngine) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PDF ayır ve sayfa çıkar"
        window.center()
        super.init(window: window)
        buildContents()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])
        column.addArrangedSubview(NSButton(title: "PDF seç…", target: self, action: #selector(choosePDF)))
        source.isSelectable = true
        source.maximumNumberOfLines = 2
        column.addArrangedSubview(source)
        column.addArrangedSubview(NSTextField(labelWithString: "Sayfalar · Örneğin 1-3, 5, 8"))
        pageRange.placeholderString = "1-3, 5"
        column.addArrangedSubview(pageRange)
        pageRange.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        exportButton.isEnabled = false
        splitButton.isEnabled = false
        column.addArrangedSubview(buttonRow([exportButton, splitButton]))
        column.addArrangedSubview(status)
        source.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    @objc private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let file = panel.url {
            guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else {
                showError(ValidationError("PDF açılamadı veya parola ile kilitli."))
                return
            }
            input = file
            source.stringValue = "\(file.lastPathComponent) · \(document.pageCount) sayfa"
            pageRange.stringValue = "1-\(document.pageCount)"
            status.stringValue = ""
            exportButton.isEnabled = true
            splitButton.isEnabled = true
        }
    }

    @objc private func exportPages() {
        guard let file = input, let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else { return }
        do {
            let pages = try Self.parsePages(pageRange.stringValue, total: document.pageCount)
            guard let output = pdfSaveDestination(title: "Seçili sayfaları kaydedin", name: file.deletingPathExtension().lastPathComponent + "-sayfalar.pdf") else { return }
            try engine.extractPDF(input: file, pages: pages, output: output)
            status.stringValue = "\(pages.count) sayfa kaydedildi."
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            showError(error)
        }
    }

    @objc private func splitEveryPage() {
        guard let file = input, let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else { return }
        let panel = NSOpenPanel()
        panel.title = "Ayrı PDF’lerin kaydedileceği klasörü seçin"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputFolder = panel.url else { return }
        let stem = file.deletingPathExtension().lastPathComponent
        let destinations = (1...document.pageCount).map { outputFolder.appendingPathComponent("\(stem)-sayfa-\($0).pdf") }
        if destinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            showError(ValidationError("Çıktı klasöründe aynı adlı dosyalar var. Boş bir klasör seçin."))
            return
        }
        var completed = 0
        do {
            for (index, destination) in destinations.enumerated() {
                try engine.extractPDF(input: file, pages: [index + 1], output: destination)
                completed += 1
            }
            status.stringValue = "\(completed) ayrı PDF kaydedildi."
            NSWorkspace.shared.open(outputFolder)
        } catch {
            status.stringValue = "\(completed) sayfa kaydedildi. İşlem tamamlanamadı."
            showError(error)
        }
    }

    static func parsePages(_ text: String, total: Int) throws -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        for token in text.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            guard !trimmed.isEmpty, parts.count <= 2,
                  let first = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  first >= 1, first <= total else {
                throw ValidationError("Sayfaları 1-3, 5 biçiminde ve 1 ile \(total) arasında girin.")
            }
            let last: Int
            if parts.count == 2 {
                guard let endpoint = Int(parts[1].trimmingCharacters(in: .whitespaces)), endpoint >= first, endpoint <= total else {
                    throw ValidationError("Sayfa aralığının başlangıcı ve sonu geçerli olmalıdır.")
                }
                last = endpoint
            } else {
                last = first
            }
            for page in first...last where seen.insert(page).inserted { result.append(page) }
        }
        guard !result.isEmpty else { throw ValidationError("En az bir sayfa seçin." ) }
        return result
    }
}

private struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}

@MainActor
private func pdfSaveDestination(title: String, name: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let result = panel.url else { return nil }
    return result
}

@MainActor
private func showError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "İşlem tamamlanamadı"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Tamam")
    alert.runModal()
}
