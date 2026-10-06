import Foundation

/// Eine Textzeile aus Textebene oder OCR, mit Lageinformation.
public struct TextLine: Hashable, Sendable {
    public let text: String
    /// Liegt die Zeile im oberen Seitenbereich (Briefkopf)?
    public let isTop: Bool

    public init(text: String, isTop: Bool) {
        self.text = text
        self.isTop = isTop
    }
}

/// Datumskandidat aus einem Dokumenttext.
public struct DateCandidate: Hashable, Sendable, Identifiable {
    public let date: DayDate
    public let score: Int
    public let matchedText: String
    /// Text unmittelbar vor der Fundstelle (zur Anzeige im Dialog).
    public let context: String
    public let isTop: Bool

    public var id: String { "\(date.iso)|\(score)|\(matchedText)|\(context)" }
}

/// Wie sicher ist die Datumserkennung?
public enum Confidence: String, Codable, Sendable {
    case high, medium, low, none

    public var german: String {
        switch self {
        case .high: return "sicher"
        case .medium: return "wahrscheinlich"
        case .low: return "unsicher"
        case .none: return "nicht erkannt"
        }
    }
}

public struct DateDecision: Sendable {
    public let date: DayDate?
    public let confidence: Confidence
    /// Zusammengefasste Kandidaten, bester zuerst.
    public let candidates: [DateCandidate]

    public static let none = DateDecision(date: nil, confidence: .none, candidates: [])
}

/// Findet und bewertet Datumsangaben im Text einer Seite (Textebene oder OCR).
public enum TextDateFinder {
    static let numeric = NSRegularExpression(#"(?<!\d)(\d{1,2})\. ?(\d{1,2})\. ?(\d{4}|\d{2})(?!\d)"#)
    static let iso = NSRegularExpression(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    static let written = NSRegularExpression(
        #"(?<!\d)(\d{1,2})\.? ?(Januar|Februar|März|Maerz|Mär|Mrz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|Jan|Feb|Apr|Jun|Jul|Aug|Sept|Sep|Okt|Nov|Dez)\.? ?(\d{4})(?!\d)"#,
        options: [.caseInsensitive])

    static let monthNames: [String: Int] = [
        "januar": 1, "jan": 1, "februar": 2, "feb": 2, "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "april": 4, "apr": 4, "mai": 5, "juni": 6, "jun": 6, "juli": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9, "oktober": 10, "okt": 10, "november": 11, "nov": 11,
        "dezember": 12, "dez": 12,
    ]

    static let negativeContext = NSRegularExpression(
        #"\b(vom|v\.|geb\.|geboren|bis|zum|seit|ab|frist|eingang|eingegangen|verkündet|zugestellt|erlassen|gültig|fällig|termin|beschluss vom|urteil vom)\s*(am|zum|den)?\s*:?\s*$"#,
        options: [.caseInsensitive])
    static let amContext = NSRegularExpression(#"\bam\s*$"#, options: [.caseInsensitive])
    static let denContext = NSRegularExpression(#", ?den\s*$"#, options: [.caseInsensitive])
    static let cityComma = NSRegularExpression(#"[A-Za-zÄÖÜäöüß][A-Za-zÄÖÜäöüß.\- ]{2,}(?: ?\([A-Za-zÄÖÜäöüß. ]+\))?,\s*$"#)
    static let plainDen = NSRegularExpression(#"\bden\s*$"#, options: [.caseInsensitive])
    static let timeAfter = NSRegularExpression(#"^\s*,?\s*(um\s*)?\d{1,2}[:.]\d{2}"#, options: [.caseInsensitive])

    /// Alle Datumskandidaten der Seite (unaggregiert).
    public static func candidates(in lines: [TextLine],
                                  today: DayDate = .today(),
                                  referenceYear: Int = AktenzeichenFinder.referenceYear) -> [DateCandidate] {
        var out: [DateCandidate] = []
        for (i, line) in lines.enumerated() {
            let prev = i > 0 ? lines[i - 1].text : ""
            func handle(_ m: RegexMatch, _ date: DayDate?) {
                guard let date else { return }
                var context = line.text.utf16Substring(from: max(0, m.start - 30), to: m.start)
                if m.start < 3, !prev.isEmpty {
                    context = String(prev.suffix(30)) + " " + context
                }
                let after = line.text.utf16Substring(from: m.end, to: m.end + 10)
                let rating = Self.score(context: context, after: after, isTop: line.isTop, date: date, today: today)
                out.append(DateCandidate(date: date, score: rating, matchedText: m.text,
                                         context: context.trimmingCharacters(in: .whitespacesAndNewlines),
                                         isTop: line.isTop))
            }
            for m in numeric.allMatches(in: line.text) {
                guard let d = m.int(1), let mo = m.int(2), let y = m.int(3) else { continue }
                handle(m, FileNameDateParser.make(year: y, month: mo, day: d, referenceYear: referenceYear))
            }
            for m in iso.allMatches(in: line.text) {
                guard let y = m.int(1), let mo = m.int(2), let d = m.int(3) else { continue }
                handle(m, FileNameDateParser.make(year: y, month: mo, day: d, referenceYear: referenceYear))
            }
            for m in written.allMatches(in: line.text) {
                guard let d = m.int(1), let name = m.groups[2], let y = m.int(3),
                      let mo = monthNames[name.lowercased()] else { continue }
                handle(m, FileNameDateParser.make(year: y, month: mo, day: d, referenceYear: referenceYear))
            }
        }
        return out
    }

    static func score(context: String, after: String, isTop: Bool, date: DayDate, today: DayDate) -> Int {
        let c = context
        let lower = c.lowercased()
        var s = 1
        if isTop { s += 3 }
        if lower.contains("datum") { s += 3 }
        if denContext.test(c) {
            s += 3
        } else if cityComma.test(c) {
            s += 2
        } else if plainDen.test(c) {
            s += 1
        }
        if negativeContext.test(c) { s -= 3 }
        if amContext.test(c) { s -= 1 }
        if timeAfter.test(after) { s -= 1 }
        if date > today { s -= 3 }
        if date.year < today.year - 15 { s -= 1 }
        return s
    }

    /// Fasst Kandidaten je Datum zusammen und entscheidet.
    public static func decide(_ cands: [DateCandidate]) -> DateDecision {
        guard !cands.isEmpty else { return .none }
        var best: [DayDate: DateCandidate] = [:]
        var counts: [DayDate: Int] = [:]
        for c in cands {
            counts[c.date, default: 0] += 1
            if let b = best[c.date] {
                if c.score > b.score { best[c.date] = c }
            } else {
                best[c.date] = c
            }
        }
        var aggregated = best.values.map { c in
            DateCandidate(date: c.date, score: c.score + min(2, (counts[c.date] ?? 1) - 1),
                          matchedText: c.matchedText, context: c.context, isTop: c.isTop)
        }
        aggregated.sort { a, b in a.score != b.score ? a.score > b.score : a.date > b.date }
        let top = aggregated[0]
        // Abstand zum zweitbesten Kandidaten; bei nur einem Kandidaten gilt der Abstand als groß.
        let margin = aggregated.count > 1 ? top.score - aggregated[1].score : 1000
        let confidence: Confidence
        if top.score >= 5 && margin >= 2 {
            confidence = .high
        } else if top.score >= 3 && margin >= 1 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return DateDecision(date: confidence == .low ? nil : top.date, confidence: confidence, candidates: aggregated)
    }

    /// Bequemlichkeit: Kandidaten finden und entscheiden.
    public static func decide(lines: [TextLine], today: DayDate = .today(),
                              referenceYear: Int = AktenzeichenFinder.referenceYear) -> DateDecision {
        decide(candidates(in: lines, today: today, referenceYear: referenceYear))
    }

    /// Entscheidung nur anhand von Kandidaten im Briefkopfbereich (für die Seitenanalyse einer Gesamtakte).
    public static func decideTopOnly(lines: [TextLine], today: DayDate = .today(),
                                     referenceYear: Int = AktenzeichenFinder.referenceYear) -> DateDecision {
        decide(candidates(in: lines, today: today, referenceYear: referenceYear).filter { $0.isTop })
    }
}
