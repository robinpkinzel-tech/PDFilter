import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFilterCore
import PDFilterParsing

/// Hält eine wartende Fortsetzung, bis der Dialog beantwortet ist.
final class Resumer<T> {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

enum DialogKind {
    case aktenzeichen(fileName: String, suggestions: [Aktenzeichen], preview: NSImage?, resumer: Resumer<AktenzeichenAnswer>)
    case akteFolder(az: Aktenzeichen, candidates: [URL], resumer: Resumer<URL?>)
    case date(fileName: String, candidates: [DateCandidate], preview: NSImage?, resumer: Resumer<DateAnswer>)
    case gesamtakte(folder: URL, candidates: [URL], all: [URL], resumer: Resumer<GesamtakteChoice>)
    case plan(ProcessingPlan, resumer: Resumer<PlanDecision>)
    case report([ProcessingOutcome])
}

struct DialogRequest: Identifiable {
    let id = UUID()
    let kind: DialogKind
}

struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var status: String
}

@MainActor
final class AppModel: ObservableObject, UserInteraction {
    static let shared = AppModel()

    @Published var settings: Settings {
        didSet { if settings != oldValue { try? settings.save() } }
    }
    @Published var queue: [QueueItem] = []
    @Published var dialog: DialogRequest?
    @Published var isProcessing = false
    @Published var progressText = ""
    @Published var logLines: [String] = []
    @Published var showLog = false

    init() {
        settings = Settings.load()
        logLines = PDFilterLogger.shared.recentLines(max: 200)
        PDFilterLogger.shared.addHandler { [weak self] line in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 2000 { self.logLines.removeFirst(self.logLines.count - 2000) }
        }
    }

    // MARK: - Warteschlange

    static func isSupported(_ url: URL) -> Bool {
        SearchablePDFWriter.isPDF(url) || SearchablePDFWriter.isImage(url)
    }

    /// Dateien (und Ordnerinhalte, eine Ebene) in die Warteschlange aufnehmen.
    func enqueue(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: items.filter(Self.isSupported).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            } else if Self.isSupported(url) {
                files.append(url)
            } else {
                PDFilterLogger.shared.log("»\(url.lastPathComponent)« ignoriert: kein PDF/Bild.")
            }
        }
        for f in files where !queue.contains(where: { $0.url.standardizedFileURL == f.standardizedFileURL }) {
            queue.append(QueueItem(url: f, status: "Bereit"))
        }
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    func clearQueue() {
        guard !isProcessing else { return }
        queue.removeAll()
    }

    func clearFinished() {
        queue.removeAll { $0.status == "Erledigt" || $0.status == "Entwurf erstellt" }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let s = item as? String {
                    url = URL(string: s)
                }
                if let url {
                    Task { @MainActor in self.enqueue([url]) }
                }
            }
        }
        return handled
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "PDFs oder Scans auswählen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf, .jpeg, .png, .heic, .heif, .tiff, .image]
        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.title = "Wurzelordner der Akten auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.rootFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.rootFolderPath = url.path
        }
    }

    // MARK: - Verarbeitung

    func startProcessing() {
        guard !isProcessing else { return }
        let urls = queue.filter { $0.status != "Erledigt" && $0.status != "Entwurf erstellt" }.map(\.url)
        guard !urls.isEmpty else { return }
        isProcessing = true
        progressText = "Verarbeitung gestartet …"
        PDFilterLogger.shared.log("Verarbeitung von \(urls.count) Datei(en) gestartet.")
        let processor = Processor(settings: settings, interaction: self)
        Task.detached(priority: .userInitiated) { [processor] in
            let outcomes = await processor.process(files: urls)
            let newSettings = processor.settings
            await MainActor.run {
                AppModel.shared.finishProcessing(outcomes, settings: newSettings)
            }
        }
    }

    private func finishProcessing(_ outcomes: [ProcessingOutcome], settings newSettings: Settings) {
        isProcessing = false
        progressText = ""
        if newSettings != settings { settings = newSettings }
        dialog = DialogRequest(kind: .report(outcomes))
    }

    func completeDialog(_ action: () -> Void) {
        action()
        dialog = nil
    }

    static func nsImage(_ cg: CGImage?) -> NSImage? {
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - UserInteraction

    func askAktenzeichen(fileName: String, suggestions: [Aktenzeichen], preview: CGImage?) async -> AktenzeichenAnswer {
        await withCheckedContinuation { c in
            dialog = DialogRequest(kind: .aktenzeichen(fileName: fileName, suggestions: suggestions, preview: Self.nsImage(preview), resumer: Resumer(c)))
        }
    }

    func chooseAkteFolder(for az: Aktenzeichen, candidates: [URL]) async -> URL? {
        await withCheckedContinuation { c in
            dialog = DialogRequest(kind: .akteFolder(az: az, candidates: candidates, resumer: Resumer(c)))
        }
    }

    func askDate(fileName: String, candidates: [DateCandidate], preview: CGImage?) async -> DateAnswer {
        await withCheckedContinuation { c in
            dialog = DialogRequest(kind: .date(fileName: fileName, candidates: candidates, preview: Self.nsImage(preview), resumer: Resumer(c)))
        }
    }

    func chooseGesamtakte(in folder: URL, candidates: [URL], all: [URL]) async -> GesamtakteChoice {
        await withCheckedContinuation { c in
            dialog = DialogRequest(kind: .gesamtakte(folder: folder, candidates: candidates, all: all, resumer: Resumer(c)))
        }
    }

    func confirm(plan: ProcessingPlan) async -> PlanDecision {
        await withCheckedContinuation { c in
            dialog = DialogRequest(kind: .plan(plan, resumer: Resumer(c)))
        }
    }

    func progress(_ message: String) {
        progressText = message
    }

    func fileStatus(_ url: URL, _ status: String) {
        if let idx = queue.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            queue[idx].status = status
        }
    }

    // MARK: - Finder

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLogFile() {
        let url = PDFilterLogger.shared.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            revealInFinder(url)
        } else {
            revealInFinder(url.deletingLastPathComponent())
        }
    }

    func revealBackups() {
        let url = BackupManager().root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
