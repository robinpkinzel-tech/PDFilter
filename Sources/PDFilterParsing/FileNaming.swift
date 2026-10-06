import Foundation

/// Hilfsfunktionen rund um Dateinamen.
public enum FileNaming {
    public static func baseName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    private static let numberPrefixRegex = NSRegularExpression(#"^(\d{1,3})(?:[_\-.]+|\s+)"#)

    /// Entfernt ein führendes Aktenzeichen (»34:26_«, »34-26 «).
    public static func stripAktenzeichenPrefix(_ base: String) -> String {
        guard let c = AktenzeichenFinder.candidates(in: base, separators: AktenzeichenFinder.fileNameSeparators)
            .first(where: { $0.location == 0 }) else { return base }
        let rest = base.utf16Substring(from: c.matchedText.utf16Length, to: base.utf16Length)
        return String(rest.drop(while: { "_- ".contains($0) }))
    }

    /// Führende Ordnungsnummer (»01_Anschreiben« → 1). Ein führendes Datum zählt nicht als Nummer.
    public static func leadingNumber(_ base: String) -> Int? {
        let s = stripAktenzeichenPrefix(base)
        if let d = FileNameDateParser.firstDate(inFileName: s), d.location == 0 { return nil }
        guard let m = numberPrefixRegex.first(in: s), let n = m.int(1) else { return nil }
        return n
    }

    /// Entfernt eine führende Ordnungsnummer.
    public static func stripLeadingNumber(_ base: String) -> String {
        let s = stripAktenzeichenPrefix(base)
        if let d = FileNameDateParser.firstDate(inFileName: s), d.location == 0 { return s }
        guard let m = numberPrefixRegex.first(in: s) else { return s }
        return s.utf16Substring(from: m.end, to: s.utf16Length)
    }

    /// Lesbarer Name ohne Erweiterung, Aktenzeichen und Nummer (»34:26_02_Anschreiben.pdf« → »Anschreiben«).
    public static func displayName(forFileName fileName: String) -> String {
        let base = baseName(fileName)
        let stripped = stripLeadingNumber(stripAktenzeichenPrefix(base))
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        return stripped.isEmpty ? base : stripped
    }

    /// Macht einen Text als Dateinamen verwendbar.
    public static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = t.replacingOccurrences(of: "\0", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Dokument" : t
    }

    /// Zweistellige Nummer, dreistellig ab 100.
    public static func numberPrefix(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
