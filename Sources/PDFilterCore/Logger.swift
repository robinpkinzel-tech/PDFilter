import Foundation

/// Einfaches Protokoll: schreibt in eine Datei und meldet Zeilen an die Oberfläche.
public final class PDFilterLogger: @unchecked Sendable {
    public static let shared = PDFilterLogger()

    public let fileURL: URL
    private let queue = DispatchQueue(label: "tech.robinpkinzel.pdfilter.log")
    private var handlers: [(String) -> Void] = []
    private let formatter: DateFormatter

    public init(fileURL: URL = Settings.appSupportDirectory.appendingPathComponent("protokoll.log")) {
        self.fileURL = fileURL
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    }

    /// Registriert einen Empfänger für neue Zeilen (wird auf dem Hauptthread aufgerufen).
    public func addHandler(_ handler: @escaping (String) -> Void) {
        queue.async { self.handlers.append(handler) }
    }

    public func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        queue.async {
            self.append(line)
            let hs = self.handlers
            DispatchQueue.main.async { hs.forEach { $0(line) } }
        }
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = (line + "\n").data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            }
        } catch {
            // Protokollfehler dürfen die Verarbeitung nicht stören.
        }
    }

    /// Die letzten Zeilen der Protokolldatei.
    public func recentLines(max: Int = 300) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(max))
    }
}
