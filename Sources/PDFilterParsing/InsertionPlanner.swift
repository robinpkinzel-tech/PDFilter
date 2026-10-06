import Foundation

/// Ergebnis der Einsortierungs-Entscheidung in eine bestehende Gesamtakte.
public struct InsertionDecision: Hashable, Sendable {
    /// Seitenindex (0-basiert), vor dem eingefügt wird; pageCount = ans Ende anhängen.
    public let pageIndex: Int
    public let isCertain: Bool
    public let reason: String?
}

/// Bestimmt, wo ein neues Dokument in eine Gesamtakte gehört.
public enum InsertionPlanner {
    /// - Parameters:
    ///   - pageDates: erkanntes Datum je Seite (nil = keine Datumsangabe / Folgeseite)
    ///   - newDate: Datum des neuen Dokuments
    public static func insertionIndex(pageDates: [DayDate?], newDate: DayDate?) -> InsertionDecision {
        let count = pageDates.count
        guard let newDate else {
            return InsertionDecision(pageIndex: count, isCertain: false, reason: "Das neue Dokument hat kein Datum; es wird ans Ende angehängt.")
        }
        let known = pageDates.compactMap { $0 }
        guard !known.isEmpty else {
            return InsertionDecision(pageIndex: count, isCertain: false, reason: "In der Gesamtakte wurden keine Datumsangaben erkannt; das Dokument wird ans Ende angehängt.")
        }
        for i in 1..<max(1, known.count) where known[i] < known[i - 1] {
            return InsertionDecision(pageIndex: count, isCertain: false,
                                     reason: "Die Gesamtakte ist nicht chronologisch sortiert (\(known[i - 1].german) vor \(known[i].german)); das Dokument wird ans Ende angehängt.")
        }
        if let idx = pageDates.firstIndex(where: { ($0.map { $0 > newDate }) ?? false }) {
            return InsertionDecision(pageIndex: idx, isCertain: true, reason: nil)
        }
        return InsertionDecision(pageIndex: count, isCertain: true, reason: nil)
    }
}
