import Foundation

/// Ein Kalendertag ohne Uhrzeit und Zeitzone.
public struct DayDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              day >= 1, day <= DayDate.daysInMonth(month, year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    public static func < (a: DayDate, b: DayDate) -> Bool {
        if a.year != b.year { return a.year < b.year }
        if a.month != b.month { return a.month < b.month }
        return a.day < b.day
    }

    /// »2024-12-01«
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    /// »01.12.2024«
    public var german: String { String(format: "%02d.%02d.%04d", day, month, year) }
    public var description: String { german }

    public static func today(calendar: Calendar = Calendar(identifier: .gregorian)) -> DayDate {
        let c = calendar.dateComponents([.year, .month, .day], from: Date())
        return DayDate(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1) ?? DayDate(year: 2000, month: 1, day: 1)!
    }

    private static let germanRegex = NSRegularExpression(#"^\s*(\d{1,2})\s*\.\s*(\d{1,2})\s*\.\s*(\d{4}|\d{2})\s*$"#)
    private static let isoRegex = NSRegularExpression(#"^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$"#)

    /// Tolerante Auswertung einer Nutzereingabe: »1.12.2024«, »01.12.24«, »2024-12-01«.
    public static func parse(_ input: String, referenceYear: Int = AktenzeichenFinder.referenceYear) -> DayDate? {
        if let m = germanRegex.first(in: input), let d = m.int(1), let mo = m.int(2), let y = m.int(3) {
            return FileNameDateParser.make(year: y, month: mo, day: d, referenceYear: referenceYear, allowAnyYear: true)
        }
        if let m = isoRegex.first(in: input), let y = m.int(1), let mo = m.int(2), let d = m.int(3) {
            return DayDate(year: y, month: mo, day: d)
        }
        return nil
    }
}
