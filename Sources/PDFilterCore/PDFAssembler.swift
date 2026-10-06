import Foundation
import PDFKit
import PDFilterParsing

/// Baut Gesamtakten zusammen und schreibt sie sicher.
public enum PDFAssembler {
    /// Fügt alle Seiten eines Dokuments an Position `index` ein und setzt ein Lesezeichen auf die erste Seite.
    /// - Returns: Anzahl eingefügter Seiten.
    @discardableResult
    public static func insert(_ source: PDFDocument, into target: PDFDocument, at index: Int, outlineTitle: String) -> Int {
        var idx = min(max(0, index), target.pageCount)
        var firstPage: PDFPage?
        var inserted = 0
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            let copy = (page.copy() as? PDFPage) ?? page
            target.insert(copy, at: idx)
            if firstPage == nil { firstPage = copy }
            idx += 1
            inserted += 1
        }
        if let fp = firstPage {
            GesamtakteOutline.addEntry(title: outlineTitle, page: fp, to: target)
        }
        return inserted
    }

    /// Neues Dokument aus mehreren Dokumenten in gegebener Reihenfolge, mit Lesezeichen.
    public static func merge(_ parts: [(document: PDFDocument, outlineTitle: String)]) -> PDFDocument {
        let result = PDFDocument()
        for part in parts {
            insert(part.document, into: result, at: result.pageCount, outlineTitle: part.outlineTitle)
        }
        return result
    }
}

/// Schreibt PDFs atomar: erst in eine temporäre Datei, zurücklesen, dann ersetzen.
public enum SafeFileWriter {
    public static func write(_ document: PDFDocument, to url: URL, expectedPageCount: Int? = nil) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).pdfilter-tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard document.write(to: tmp) else { throw PDFilterError.writeFailed(url) }
        guard let check = PDFDocument(url: tmp), check.pageCount == (expectedPageCount ?? document.pageCount), check.pageCount > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw PDFilterError.verificationFailed(url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Eindeutiger Dateiname: hängt » (2)«, » (3)« … an, falls nötig.
    public static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// Sicherungskopien von Gesamtakten (die letzten N je Akte).
public struct BackupManager {
    public let root: URL

    public init(root: URL = PDFilterSettings.appSupportDirectory.appendingPathComponent("Sicherungen", isDirectory: true)) {
        self.root = root
    }

    public func folder(for az: Aktenzeichen) -> URL {
        root.appendingPathComponent(az.fileSystemString(visibleSeparator: "-"), isDirectory: true)
    }

    /// Kopiert die Datei in den Sicherungsordner und löscht ältere Sicherungen über `keep` hinaus.
    @discardableResult
    public func backup(_ file: URL, for az: Aktenzeichen, keep: Int) throws -> URL {
        let dir = folder(for: az)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(formatter.string(from: Date()))_\(file.lastPathComponent)"
        let dest = SafeFileWriter.uniqueURL(dir.appendingPathComponent(name))
        try FileManager.default.copyItem(at: file, to: dest)
        try prune(dir: dir, keep: max(1, keep))
        return dest
    }

    func prune(dir: URL, keep: Int) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent } // Zeitstempel im Namen
        if sorted.count > keep {
            for f in sorted.prefix(sorted.count - keep) {
                try FileManager.default.removeItem(at: f)
            }
        }
    }

    public func backups(for az: Aktenzeichen) -> [URL] {
        let dir = folder(for: az)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
