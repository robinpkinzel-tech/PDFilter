import Foundation

public enum DateSource: String, Codable, Sendable {
    case fileName, document, user, none

    public var german: String {
        switch self {
        case .fileName: return "aus Dateiname"
        case .document: return "aus Dokument"
        case .user: return "manuell eingegeben"
        case .none: return "kein Datum"
        }
    }
}

/// Beschreibung eines Dokuments für die Sortierung.
public struct DocumentDescriptor: Identifiable, Hashable, Sendable {
    public var id: String
    public var fileName: String
    public var displayName: String
    public var number: Int?
    public var date: DayDate?
    public var dateSource: DateSource
    public var dateConfidence: Confidence
    public var isIncoming: Bool
    public var pageCount: Int

    public init(id: String, fileName: String, displayName: String? = nil, number: Int? = nil,
                date: DayDate? = nil, dateSource: DateSource = .none, dateConfidence: Confidence = .none,
                isIncoming: Bool = false, pageCount: Int = 0) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName ?? FileNaming.displayName(forFileName: fileName)
        self.number = number
        self.date = date
        self.dateSource = dateSource
        self.dateConfidence = dateConfidence
        self.isIncoming = isIncoming
        self.pageCount = pageCount
    }

    public var dateText: String { date?.german ?? "ohne Datum" }
}

public struct OrderingResult: Sendable {
    public let ordered: [DocumentDescriptor]
    public let warnings: [String]
    public let uncertainReasons: [String]
    public var isUncertain: Bool { !uncertainReasons.isEmpty }
}

/// Bestimmt die Reihenfolge von Einzeldokumenten.
///
/// 1. Dateien mit Ordnungsnummer behalten ihre Reihenfolge (Nummer hat Vorrang).
/// 2. Dateien ohne Nummer werden nach Datum zwischen die nummerierten einsortiert.
/// 3. Dateien ohne Datum und ohne Nummer kommen ans Ende – die Sortierung gilt dann als unsicher.
public enum DocumentOrdering {
    public static func order(_ docs: [DocumentDescriptor]) -> OrderingResult {
        var warnings: [String] = []
        var uncertain: [String] = []

        var numbered = docs.filter { $0.number != nil }
        numbered.sort { a, b in
            if a.number! != b.number! { return a.number! < b.number! }
            if let da = a.date, let db = b.date, da != db { return da < db }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }

        // Doppelte Nummern
        var seen: [Int: String] = [:]
        for d in numbered {
            if let other = seen[d.number!] {
                warnings.append("Doppelte Nummer \(d.number!): »\(other)« und »\(d.fileName)«.")
            } else {
                seen[d.number!] = d.fileName
            }
        }

        // Widersprüche zwischen Nummerierung und Datum
        var monotonic = true
        var lastDated: DocumentDescriptor?
        for d in numbered {
            guard let date = d.date else { continue }
            if let last = lastDated, let lastDate = last.date, date < lastDate {
                monotonic = false
                warnings.append(
                    "Widerspruch: »\(d.fileName)« (Nr. \(d.number!), Datum \(date.german)) steht laut Nummerierung nach "
                    + "»\(last.fileName)« (Nr. \(last.number!), Datum \(lastDate.german)), ist aber älter. "
                    + "Die Nummerierung wurde beibehalten.")
            }
            lastDated = d
        }

        var result = numbered
        var unnumbered = docs.filter { $0.number == nil }
        unnumbered.sort { a, b in
            switch (a.date, b.date) {
            case let (da?, db?) where da != db: return da < db
            case (nil, .some(_)): return false
            case (.some(_), nil): return true
            default: return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
        }

        for u in unnumbered {
            guard let date = u.date else {
                result.append(u)
                uncertain.append("»\(u.fileName)« hat weder Nummer noch erkennbares Datum und wurde ans Ende gestellt.")
                continue
            }
            if !monotonic && !numbered.isEmpty {
                result.append(u)
                uncertain.append("Die nummerierten Dateien sind nicht chronologisch; »\(u.fileName)« (\(date.german)) wurde deshalb ans Ende gestellt.")
                continue
            }
            if let idx = result.firstIndex(where: { ($0.date.map { $0 > date }) ?? false }) {
                result.insert(u, at: idx)
            } else {
                result.append(u)
            }
        }

        return OrderingResult(ordered: result, warnings: warnings, uncertainReasons: uncertain)
    }
}
