import Foundation

/// Datumsfund in einem Dateinamen.
public struct FileNameDateMatch: Hashable, Sendable {
    public let date: DayDate
    /// UTF-16-Position im Namen.
    public let location: Int
    public let length: Int
}

/// Erkennt Datumsangaben in Dateinamen: »2024-12-01«, »01.12.2024«, »01.12.24«, »20241201«, »241201«.
public enum FileNameDateParser {
    static let iso = NSRegularExpression(#"(?<!\d)(\d{4})[-_.](\d{1,2})[-_.](\d{1,2})(?!\d)"#)
    static let germanLong = NSRegularExpression(#"(?<!\d)(\d{1,2})[.\-_](\d{1,2})[.\-_](\d{4})(?!\d)"#)
    static let germanShort = NSRegularExpression(#"(?<!\d)(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)"#)
    static let compact8 = NSRegularExpression(#"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)"#)
    static let compact6 = NSRegularExpression(#"(?<!\d)(\d{2})(\d{2})(\d{2})(?!\d)"#)

    /// Erstes (am weitesten links stehendes) Datum im Dateinamen.
    public static func firstDate(inFileName name: String,
                                 referenceYear: Int = AktenzeichenFinder.referenceYear) -> FileNameDateMatch? {
        let base = (name as NSString).deletingPathExtension
        return allDates(in: base, referenceYear: referenceYear).first
    }

    /// Alle Datumsfunde, nach Position sortiert, ohne Überlappungen.
    public static func allDates(in text: String, referenceYear: Int) -> [FileNameDateMatch] {
        var out: [FileNameDateMatch] = []
        func add(_ m: RegexMatch, y: Int?, mo: Int?, d: Int?) {
            guard let y, let mo, let d,
                  let date = make(year: y, month: mo, day: d, referenceYear: referenceYear) else { return }
            out.append(FileNameDateMatch(date: date, location: m.start, length: m.range.length))
        }
        for m in iso.allMatches(in: text) { add(m, y: m.int(1), mo: m.int(2), d: m.int(3)) }
        for m in germanLong.allMatches(in: text) { add(m, y: m.int(3), mo: m.int(2), d: m.int(1)) }
        for m in germanShort.allMatches(in: text) { add(m, y: m.int(3), mo: m.int(2), d: m.int(1)) }
        for m in compact8.allMatches(in: text) { add(m, y: m.int(1), mo: m.int(2), d: m.int(3)) }
        for m in compact6.allMatches(in: text) { add(m, y: m.int(1), mo: m.int(2), d: m.int(3)) }
        // Längere Treffer gewinnen bei Überlappung.
        out.sort { a, b in a.location != b.location ? a.location < b.location : a.length > b.length }
        var result: [FileNameDateMatch] = []
        var coveredUntil = -1
        for m in out where m.location >= coveredUntil {
            result.append(m)
            coveredUntil = m.location + m.length
        }
        return result
    }

    /// Baut ein Datum und prüft die Plausibilität des Jahres (1990 … Referenzjahr + 1).
    /// Zweistellige Jahre: 00 … (Referenzjahr+1) → 20xx, 90 … 99 → 19xx.
    public static func make(year y: Int, month: Int, day: Int, referenceYear: Int, allowAnyYear: Bool = false) -> DayDate? {
        var year = y
        if year < 100 {
            let maxTwo = (referenceYear + 1) % 100
            if year <= maxTwo { year += 2000 } else if year >= 90 { year += 1900 } else if allowAnyYear { year += 2000 } else { return nil }
        }
        if !allowAnyYear {
            guard year >= 1990, year <= referenceYear + 1 else { return nil }
        }
        return DayDate(year: year, month: month, day: day)
    }
}
