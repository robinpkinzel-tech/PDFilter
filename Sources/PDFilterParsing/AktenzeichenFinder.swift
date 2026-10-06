import Foundation

/// Fundstelle eines Aktenzeichens in einem Text.
public struct AktenzeichenCandidate: Hashable, Sendable {
    public let aktenzeichen: Aktenzeichen
    public let matchedText: String
    /// UTF-16-Position im Text.
    public let location: Int
    /// Kontextbewertung (höher = wahrscheinlicher unser Aktenzeichen).
    public let score: Int
}

/// Sucht Aktenzeichen in Dateinamen, Ordnernamen und Dokumenttexten.
public enum AktenzeichenFinder {
    public static var referenceYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    /// Trennzeichen, die in Dateinamen zwischen Nummer und Jahr vorkommen dürfen.
    public static let fileNameSeparators = "/:-_"
    /// Trennzeichen in Ordnernamen (zusätzlich Punkt und Leerzeichen).
    public static let folderNameSeparators = "/:-_. "

    static func isPlausibleYear(_ y: Int, reference: Int) -> Bool {
        if y >= 1000 { return y >= 1990 && y <= reference + 1 }
        let maxTwo = (reference + 1) % 100
        return y >= 0 && y <= maxTwo
    }

    /// Findet alle Aktenzeichen-Kandidaten in einem Text.
    ///
    /// Zahlenketten mit demselben Trennzeichen (z. B. das Datum »2024-12-01«) werden
    /// nicht als Aktenzeichen gewertet.
    public static func candidates(in text: String,
                                  separators: String = fileNameSeparators,
                                  referenceYear: Int = referenceYear) -> [AktenzeichenCandidate] {
        let cls = separators.map { "\\\($0)" }.joined()
        // Lookahead, damit sich überlappende Fundstellen (z. B. »12-01_34-26«) nicht gegenseitig verdecken.
        let regex = NSRegularExpression("(?=((?<!\\d)(\\d{1,5}) ?([" + cls + "]) ?(\\d{4}|\\d{2})(?!\\d)))")
        let length = text.utf16Length
        var result: [AktenzeichenCandidate] = []
        for m in regex.allMatches(in: text) {
            guard let whole = m.groups[1], let n = m.int(2), let sep = m.groups[3], let y = m.int(4) else { continue }
            guard isPlausibleYear(y, reference: referenceYear) else { continue }
            let end = m.start + whole.utf16Length
            let before = text.utf16Substring(from: max(0, m.start - 8), to: m.start)
            let after = text.utf16Substring(from: end, to: min(length, end + 8))
            let sepEsc = "\\" + sep
            if NSRegularExpression("\\d ?" + sepEsc + " ?$").test(before) { continue }
            if NSRegularExpression("^ ?" + sepEsc + " ?\\d").test(after) { continue }
            guard let az = Aktenzeichen(number: n, year: y) else { continue }
            let score = contextScore(text: text, matchStart: m.start)
            result.append(AktenzeichenCandidate(aktenzeichen: az, matchedText: whole, location: m.start, score: score))
        }
        return result
    }

    private static let courtPrefix = NSRegularExpression(#"(\d+\s+)?\b([A-Za-z]{1,4})\s+$"#)
    private static let azWord = NSRegularExpression(#"\baz\b\.?"#, options: [.caseInsensitive])

    /// Bewertet den Kontext vor einer Fundstelle.
    static func contextScore(text: String, matchStart: Int) -> Int {
        let before = text.utf16Substring(from: max(0, matchStart - 40), to: matchStart)
        let lower = before.lowercased()
        var score = 0
        if lower.contains("unser zeichen") || lower.contains("unser az") || lower.contains("u. z.") || lower.contains("u.z.") { score += 3 }
        if lower.contains("ihr zeichen") || lower.contains("ihr az") { score += 3 }
        if lower.contains("aktenzeichen") {
            score += 3
        } else if azWord.test(lower) {
            score += 2
        } else if lower.contains("zeichen") || lower.contains("gz.") || lower.contains("gz:") {
            score += 1
        }
        // Gerichtliche Aktenzeichen wie »12 O 345/24« oder »3 Ca 12/25« abwerten.
        if let m = courtPrefix.first(in: before) {
            let token = (m.groups[2] ?? "").lowercased()
            let allowed: Set<String> = ["az", "gz", "nr", "zu"]
            if !allowed.contains(token) {
                score -= (m.groups[1] != nil) ? 4 : 2
            }
        }
        return score
    }

    /// Erstes Aktenzeichen in einem Dateinamen (Erweiterung wird ignoriert).
    public static func aktenzeichen(inFileName name: String, referenceYear: Int = referenceYear) -> Aktenzeichen? {
        let base = (name as NSString).deletingPathExtension
        return candidates(in: base, separators: fileNameSeparators, referenceYear: referenceYear)
            .min { $0.location < $1.location }?
            .aktenzeichen
    }

    /// Erstes Aktenzeichen in einem Ordnernamen.
    public static func aktenzeichen(inFolderName name: String, referenceYear: Int = referenceYear) -> Aktenzeichen? {
        candidates(in: name, separators: folderNameSeparators, referenceYear: referenceYear)
            .min { $0.location < $1.location }?
            .aktenzeichen
    }

    /// Prüft, ob ein Ordnername das Aktenzeichen enthält (beliebige Trennzeichen, »34/26« = »34:26« = »34-26«).
    public static func folderNameMatches(_ folderName: String, _ az: Aktenzeichen, referenceYear: Int = referenceYear) -> Bool {
        candidates(in: folderName, separators: folderNameSeparators, referenceYear: referenceYear)
            .contains { $0.aktenzeichen == az }
    }

    /// Vorschläge aus einem Dokumenttext, bekannte Akten (vorhandene Ordner) zuerst.
    public static func rankedSuggestions(from text: String,
                                         knownAktenzeichen: Set<Aktenzeichen>,
                                         referenceYear: Int = referenceYear,
                                         limit: Int = 5) -> [Aktenzeichen] {
        var scores: [Aktenzeichen: Int] = [:]
        var counts: [Aktenzeichen: Int] = [:]
        for c in candidates(in: text, separators: "/:-", referenceYear: referenceYear) {
            counts[c.aktenzeichen, default: 0] += 1
            scores[c.aktenzeichen] = max(scores[c.aktenzeichen] ?? Int.min, c.score)
        }
        var ranked: [(Aktenzeichen, Int)] = []
        for (az, score) in scores {
            let known = knownAktenzeichen.contains(az)
            var total = score + min(2, (counts[az] ?? 1) - 1)
            if known { total += 5 }
            if total < 0 && !known { continue }
            ranked.append((az, total))
        }
        ranked.sort { a, b in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }
        return Array(ranked.prefix(limit).map { $0.0 })
    }
}
