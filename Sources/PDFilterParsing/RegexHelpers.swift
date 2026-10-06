import Foundation

/// Ein Treffer eines regulären Ausdrucks mit UTF-16-Positionen (NSString-Semantik).
struct RegexMatch {
    let range: NSRange
    /// Index 0 = gesamter Treffer, danach die Gruppen (nil = Gruppe nicht beteiligt).
    let groups: [String?]

    var start: Int { range.location }
    var end: Int { range.location + range.length }
    var text: String { groups.first.flatMap { $0 } ?? "" }

    func int(_ group: Int) -> Int? {
        guard group < groups.count, let s = groups[group] else { return nil }
        return Int(s)
    }
}

extension NSRegularExpression {
    /// Erzeugt einen Ausdruck aus einem bekannten, festen Muster.
    convenience init(_ pattern: String, options: NSRegularExpression.Options = []) {
        do {
            try self.init(pattern: pattern, options: options)
        } catch {
            fatalError("Ungültiges Muster »\(pattern)«: \(error)")
        }
    }

    func allMatches(in text: String) -> [RegexMatch] {
        let ns = text as NSString
        return matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { m in
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            return RegexMatch(range: m.range, groups: groups)
        }
    }

    func first(in text: String) -> RegexMatch? {
        allMatches(in: text).first
    }

    func test(_ text: String) -> Bool {
        first(in: text) != nil
    }
}

extension String {
    /// Teilstring über UTF-16-Positionen; Grenzen werden abgeschnitten statt abzustürzen.
    func utf16Substring(from: Int, to: Int) -> String {
        let ns = self as NSString
        let f = max(0, min(from, ns.length))
        let t = max(f, min(to, ns.length))
        return ns.substring(with: NSRange(location: f, length: t - f))
    }

    var utf16Length: Int { (self as NSString).length }
}
