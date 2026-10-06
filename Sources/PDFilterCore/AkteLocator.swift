import Foundation
import PDFilterParsing

/// Findet Aktenordner und Zielordner anhand der Einstellungen.
public struct AkteLocator {
    public let settings: Settings

    public init(settings: Settings) {
        self.settings = settings
    }

    static func subdirectories(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isHidden != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Alle Ordner, die als Akten in Frage kommen (Wurzel, optional eine Ebene tiefer).
    public func candidateFolders() throws -> [URL] {
        let root = settings.rootFolder
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw PDFilterError.rootFolderMissing(root)
        }
        var folders = Self.subdirectories(of: root)
        if settings.searchSubfolders {
            for f in folders { folders.append(contentsOf: Self.subdirectories(of: f)) }
        }
        return folders
    }

    /// Aktenordner, deren Name das Aktenzeichen enthält.
    public func findAkteFolders(for az: Aktenzeichen) throws -> [URL] {
        try candidateFolders().filter { AktenzeichenFinder.folderNameMatches($0.lastPathComponent, az) }
    }

    /// Alle erkannten Aktenzeichen vorhandener Ordner (für Vorschläge).
    public func knownAktenzeichen() -> Set<Aktenzeichen> {
        let folders = (try? candidateFolders()) ?? []
        return Set(folders.compactMap { AktenzeichenFinder.aktenzeichen(inFolderName: $0.lastPathComponent) })
    }

    /// Zielordner innerhalb der Akte laut Pfadmuster; prüft jede Ebene und meldet die fehlende.
    public func targetFolder(in akte: URL) throws -> URL {
        var current = akte
        for component in settings.templateComponents {
            let next = current.appendingPathComponent(component, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: next.path, isDirectory: &isDir), isDir.boolValue {
                current = next
                continue
            }
            // Groß-/Kleinschreibung tolerieren
            if let match = Self.subdirectories(of: current).first(where: {
                $0.lastPathComponent.compare(component, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                current = match
                continue
            }
            throw PDFilterError.targetFolderMissing(
                akte: akte, template: settings.pathTemplate, missingComponent: component,
                existing: Self.subdirectories(of: current).map(\.lastPathComponent))
        }
        return current
    }
}

/// Zustand des Zielordners.
public enum TargetState: Equatable {
    /// Keine PDF vorhanden.
    case empty
    /// Genau eine PDF bzw. eine eindeutig erkennbare Gesamtakte (ohne weitere Einzeldateien).
    case gesamtakte(URL)
    /// Mehrere PDFs, keine davon als Gesamtakte erkennbar.
    case singles([URL])
    /// Eine Gesamtakte und zusätzliche Einzel-PDFs.
    case gesamtakteWithSingles(gesamtakte: URL, singles: [URL])
    /// Mehrere PDFs könnten die Gesamtakte sein.
    case ambiguous(candidates: [URL], all: [URL])
}

public enum TargetFolderAnalyzer {
    /// PDF-Dateien direkt im Ordner (keine versteckten, keine Unterordner).
    public static func pdfFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { item in
            guard item.pathExtension.lowercased() == "pdf" else { return false }
            let values = try? item.resourceValues(forKeys: Set(keys))
            return values?.isRegularFile == true && values?.isHidden != true && !item.lastPathComponent.hasPrefix(".")
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Erkennt eine Gesamtakte am Namen: konfigurierter Name, »gesamt…« oder schlicht »Akte«.
    public static func looksLikeGesamtakte(_ url: URL, settings: Settings, az: Aktenzeichen) -> Bool {
        let name = url.lastPathComponent
        let configured = settings.gesamtakteName(for: az)
        if name.compare(configured, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return true }
        let base = FileNaming.stripAktenzeichenPrefix(FileNaming.baseName(name)).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        if base.contains("gesam") { return true } // deckt »Gesamtakte« und Tippfehler wie »gesamakte« ab
        if base == "akte" || base == "gesamtakte" || base == "die akte" { return true }
        return false
    }

    public static func analyze(folder: URL, settings: Settings, az: Aktenzeichen) -> TargetState {
        let files = pdfFiles(in: folder)
        if files.isEmpty { return .empty }
        if files.count == 1 { return .gesamtakte(files[0]) }
        let candidates = files.filter { looksLikeGesamtakte($0, settings: settings, az: az) }
        switch candidates.count {
        case 0:
            return .singles(files)
        case 1:
            return .gesamtakteWithSingles(gesamtakte: candidates[0], singles: files.filter { $0 != candidates[0] })
        default:
            return .ambiguous(candidates: candidates, all: files)
        }
    }
}
