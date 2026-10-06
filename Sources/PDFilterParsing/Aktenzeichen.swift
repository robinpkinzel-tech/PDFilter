import Foundation

/// Ein Aktenzeichen im Format »Nummer/Jahr«, z. B. »34/26«.
public struct Aktenzeichen: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let number: Int
    /// Zweistelliges Jahr (0…99).
    public let year: Int

    public init?(number: Int, year rawYear: Int) {
        var y = rawYear
        if y >= 100 { y = y % 100 }
        guard number >= 0, number < 1_000_000, (0...99).contains(y) else { return nil }
        self.number = number
        self.year = y
    }

    /// Anzeigeform, z. B. »34/26«.
    public var display: String { "\(number)/\(Aktenzeichen.twoDigits(year))" }
    public var description: String { display }

    /// Vierstelliges Jahr (Schwelle 80: 00–79 → 20xx, 80–99 → 19xx).
    public var fullYear: Int { year < 80 ? 2000 + year : 1900 + year }

    /// Form für Dateinamen. macOS erlaubt kein »/« in Dateinamen; der Finder zeigt ein
    /// gespeichertes »:« als »/« an. Deshalb wird »/« auf der Platte zu »:«.
    public func fileSystemString(visibleSeparator: String) -> String {
        let sep = visibleSeparator == "/" ? ":" : visibleSeparator
        return "\(number)\(sep)\(Aktenzeichen.twoDigits(year))"
    }

    public static func twoDigits(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    public static func < (a: Aktenzeichen, b: Aktenzeichen) -> Bool {
        if a.fullYear != b.fullYear { return a.fullYear < b.fullYear }
        return a.number < b.number
    }

    private static let inputRegex = NSRegularExpression(#"^(\d{1,6})\s*[^\d\s]\s*(\d{2}|\d{4})$"#)

    /// Tolerante Auswertung einer Nutzereingabe (»34/26«, »34-26«, »34 / 2026«, »34:26«).
    public static func parse(_ input: String) -> Aktenzeichen? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = inputRegex.first(in: t), let n = m.int(1), let y = m.int(2) else { return nil }
        return Aktenzeichen(number: n, year: y)
    }
}
