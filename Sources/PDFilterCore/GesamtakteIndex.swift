import Foundation
import PDFKit
import PDFilterParsing

/// Lesezeichen-Eintrag einer Gesamtakte (von PDFilter geschrieben: »01.12.2024 – Anschreiben«).
public struct OutlineEntry: Sendable, Hashable {
    public let pageIndex: Int
    public let title: String
    public let date: DayDate?
}

/// Liest und schreibt die Lesezeichen (Outline) einer Gesamtakte und ermittelt Datumsangaben je Seite.
public enum GesamtakteOutline {
    public static let noDateLabel = "ohne Datum"

    public static func title(date: DayDate?, name: String) -> String {
        "\(date?.german ?? noDateLabel) – \(name)"
    }

    private static let titleRegex = NSRegularExpression(#"^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\b"#)

    public static func entries(of document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineEntry] = []
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page {
                    let idx = document.index(for: page)
                    if idx >= 0 {
                        let label = child.label ?? ""
                        var date: DayDate?
                        if let m = titleRegex.first(in: label), let d = m.int(1), let mo = m.int(2), let y = m.int(3) {
                            date = DayDate(year: y, month: mo, day: d)
                        }
                        result.append(OutlineEntry(pageIndex: idx, title: label, date: date))
                    }
                }
                walk(child)
            }
        }
        walk(root)
        return result.sorted { $0.pageIndex < $1.pageIndex }
    }

    /// Fügt ein Lesezeichen für eine Seite ein (nach Seitenindex sortiert).
    public static func addEntry(title: String, page: PDFPage, to document: PDFDocument) {
        let root: PDFOutline
        if let existing = document.outlineRoot {
            root = existing
        } else {
            root = PDFOutline()
            document.outlineRoot = root
        }
        let item = PDFOutline()
        item.label = title
        item.destination = PDFDestination(page: page, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue))
        let pageIndex = document.index(for: page)
        var insertAt = root.numberOfChildren
        for i in 0..<root.numberOfChildren {
            if let child = root.child(at: i), let p = child.destination?.page, document.index(for: p) > pageIndex {
                insertAt = i
                break
            }
        }
        root.insertChild(item, at: insertAt)
    }
}

/// Zwischenspeicher für erkannte Seitendaten (vermeidet wiederholte OCR großer Gesamtakten).
public final class PageDateCache: @unchecked Sendable {
    private struct Entry: Codable {
        var dates: [String?]
        var touched: Date
    }

    public let fileURL: URL
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(fileURL: URL = Settings.appSupportDirectory.appendingPathComponent("seitendaten-cache.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(Int(mtime))"
    }

    public func dates(for url: URL, pageCount: Int) -> [DayDate?]? {
        guard let key = Self.key(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], e.dates.count == pageCount else { return nil }
        return e.dates.map { $0.flatMap { DayDate.parse($0) } }
    }

    public func store(_ dates: [DayDate?], for url: URL) {
        guard let key = Self.key(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(dates: dates.map { $0?.iso }, touched: Date())
        if entries.count > 200 {
            let sorted = entries.sorted { $0.value.touched < $1.value.touched }
            for (k, _) in sorted.prefix(entries.count - 200) { entries.removeValue(forKey: k) }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // Cache-Fehler sind unkritisch.
        }
    }
}

/// Ermittelt je Seite einer Gesamtakte das Dokumentdatum (Lesezeichen → Textebene → OCR, begrenzt).
public final class GesamtakteIndexer: @unchecked Sendable {
    public struct PageDates: Sendable {
        public let dates: [DayDate?]
        /// false, wenn OCR-Seiten wegen der Obergrenze ausgelassen wurden.
        public let complete: Bool
        public let skippedOCRPages: Int
        public let fromCache: Bool
    }

    let extractor: DocumentTextExtractor
    let cache: PageDateCache?

    public init(extractor: DocumentTextExtractor, cache: PageDateCache?) {
        self.extractor = extractor
        self.cache = cache
    }

    public func pageDates(of document: PDFDocument, at url: URL?, maxOCRPages: Int,
                          progress: ((String) -> Void)? = nil) -> PageDates {
        let count = document.pageCount
        var dates = [DayDate?](repeating: nil, count: count)
        var fromOutline = [Bool](repeating: false, count: count)
        for e in GesamtakteOutline.entries(of: document) where e.pageIndex < count {
            fromOutline[e.pageIndex] = true
            dates[e.pageIndex] = e.date
        }

        if let url, let cached = cache?.dates(for: url, pageCount: count) {
            var merged = cached
            for i in 0..<count where fromOutline[i] { merged[i] = dates[i] }
            return PageDates(dates: merged, complete: true, skippedOCRPages: 0, fromCache: true)
        }

        var needsOCR: [Int] = []
        for i in 0..<count where !fromOutline[i] {
            guard let page = document.page(at: i) else { continue }
            if PDFTextLayer.hasUsableText(page) {
                dates[i] = Self.headerDate(extractor.text(for: page, allowOCR: false))
            } else {
                needsOCR.append(i)
            }
        }

        var skipped = 0
        if needsOCR.count <= maxOCRPages {
            for (n, i) in needsOCR.enumerated() {
                progress?("Lese Gesamtakte per OCR: Seite \(i + 1) von \(count) (\(n + 1)/\(needsOCR.count))")
                if let page = document.page(at: i) {
                    dates[i] = Self.headerDate(extractor.text(for: page, allowOCR: true))
                }
            }
        } else {
            skipped = needsOCR.count
        }

        if skipped == 0, let url { cache?.store(dates, for: url) }
        return PageDates(dates: dates, complete: skipped == 0, skippedOCRPages: skipped, fromCache: false)
    }

    /// Datum im Kopfbereich einer Seite, nur bei ausreichender Sicherheit.
    static func headerDate(_ text: PageText) -> DayDate? {
        let decision = TextDateFinder.decideTopOnly(lines: text.lines)
        switch decision.confidence {
        case .high, .medium: return decision.date
        default: return nil
        }
    }
}
