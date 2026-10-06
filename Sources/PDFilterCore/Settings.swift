import Foundation
import PDFilterParsing

/// Einstellungen der App. Werden als JSON unter ~/Library/Application Support/PDFilter/settings.json gespeichert.
public struct Settings: Codable, Equatable, Sendable {
    /// Wurzelordner, in dem die Aktenordner liegen (Standard: Schreibtisch).
    public var rootFolderPath: String
    /// Auch Unterordner des Wurzelordners (eine Ebene) nach Akten durchsuchen.
    public var searchSubfolders: Bool
    /// Pfadmuster vom Aktenordner zum Zielordner, z. B. »01_Akte/01_Gesamtakte«.
    public var pathTemplate: String
    /// Dateiname der Gesamtakte; »{AZ}« wird durch das Aktenzeichen ersetzt.
    public var gesamtakteFileName: String
    /// Sichtbares Trennzeichen im Aktenzeichen-Präfix (»/« wird auf der Platte zu »:«).
    public var visibleSeparator: String
    /// Originaldateien nach erfolgreicher Verarbeitung in den Papierkorb legen.
    public var moveOriginalsToTrash: Bool
    /// Anzahl aufzubewahrender Sicherungen je Akte.
    public var backupCount: Int
    /// Scans ohne Textebene per OCR durchsuchbar machen.
    public var makeSearchable: Bool
    /// Vor dem Schreiben eine Vorschau zur Bestätigung zeigen.
    public var confirmBeforeWriting: Bool
    /// Akten (Anzeigeform »34/26«), für die nicht mehr nachgefragt wird.
    public var noConfirmAkten: [String]
    /// Höchstzahl Seiten einer Gesamtakte, die für die Einsortierung per OCR gelesen werden.
    public var maxOCRPagesForSorting: Int
    /// Kopien der eingefügten Dokumente im Unterordner »Einzeldokumente« aufbewahren.
    public var keepCopiesInEinzeldokumente: Bool
    public var einzeldokumenteFolderName: String
    public var draftFolderName: String

    public init(rootFolderPath: String = Settings.defaultRootFolder.path,
                searchSubfolders: Bool = false,
                pathTemplate: String = "01_Akte/01_Gesamtakte",
                gesamtakteFileName: String = "Gesamtakte.pdf",
                visibleSeparator: String = "/",
                moveOriginalsToTrash: Bool = true,
                backupCount: Int = 5,
                makeSearchable: Bool = true,
                confirmBeforeWriting: Bool = true,
                noConfirmAkten: [String] = [],
                maxOCRPagesForSorting: Int = 150,
                keepCopiesInEinzeldokumente: Bool = true,
                einzeldokumenteFolderName: String = "Einzeldokumente",
                draftFolderName: String = "_PDFilter_Entwurf") {
        self.rootFolderPath = rootFolderPath
        self.searchSubfolders = searchSubfolders
        self.pathTemplate = pathTemplate
        self.gesamtakteFileName = gesamtakteFileName
        self.visibleSeparator = visibleSeparator
        self.moveOriginalsToTrash = moveOriginalsToTrash
        self.backupCount = backupCount
        self.makeSearchable = makeSearchable
        self.confirmBeforeWriting = confirmBeforeWriting
        self.noConfirmAkten = noConfirmAkten
        self.maxOCRPagesForSorting = maxOCRPagesForSorting
        self.keepCopiesInEinzeldokumente = keepCopiesInEinzeldokumente
        self.einzeldokumenteFolderName = einzeldokumenteFolderName
        self.draftFolderName = draftFolderName
    }

    public static let `default` = Settings()

    public static var defaultRootFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    public var rootFolder: URL { URL(fileURLWithPath: rootFolderPath, isDirectory: true) }

    /// Pfadbestandteile des Musters (leere Teile werden ignoriert).
    public var templateComponents: [String] {
        pathTemplate.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Dateiname der Gesamtakte für ein Aktenzeichen.
    public func gesamtakteName(for az: Aktenzeichen) -> String {
        var name = gesamtakteFileName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Gesamtakte.pdf" }
        name = name.replacingOccurrences(of: "{AZ}", with: az.fileSystemString(visibleSeparator: visibleSeparator))
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        return FileNaming.sanitize(name)
    }

    /// Präfix für Dateinamen, z. B. »34:26«.
    public func prefix(for az: Aktenzeichen) -> String {
        az.fileSystemString(visibleSeparator: visibleSeparator)
    }

    public func needsConfirmation(for az: Aktenzeichen) -> Bool {
        confirmBeforeWriting && !noConfirmAkten.contains(az.display)
    }

    // MARK: - Persistenz

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PDFilter", isDirectory: true)
    }

    public static var storageURL: URL { appSupportDirectory.appendingPathComponent("settings.json") }

    public static func load(from url: URL = storageURL) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? .default
    }

    public func save(to url: URL = Settings.storageURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // Vorwärtskompatibles Decodieren: fehlende Schlüssel erhalten Standardwerte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        rootFolderPath = try c.decodeIfPresent(String.self, forKey: .rootFolderPath) ?? d.rootFolderPath
        searchSubfolders = try c.decodeIfPresent(Bool.self, forKey: .searchSubfolders) ?? d.searchSubfolders
        pathTemplate = try c.decodeIfPresent(String.self, forKey: .pathTemplate) ?? d.pathTemplate
        gesamtakteFileName = try c.decodeIfPresent(String.self, forKey: .gesamtakteFileName) ?? d.gesamtakteFileName
        visibleSeparator = try c.decodeIfPresent(String.self, forKey: .visibleSeparator) ?? d.visibleSeparator
        moveOriginalsToTrash = try c.decodeIfPresent(Bool.self, forKey: .moveOriginalsToTrash) ?? d.moveOriginalsToTrash
        backupCount = try c.decodeIfPresent(Int.self, forKey: .backupCount) ?? d.backupCount
        makeSearchable = try c.decodeIfPresent(Bool.self, forKey: .makeSearchable) ?? d.makeSearchable
        confirmBeforeWriting = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeWriting) ?? d.confirmBeforeWriting
        noConfirmAkten = try c.decodeIfPresent([String].self, forKey: .noConfirmAkten) ?? d.noConfirmAkten
        maxOCRPagesForSorting = try c.decodeIfPresent(Int.self, forKey: .maxOCRPagesForSorting) ?? d.maxOCRPagesForSorting
        keepCopiesInEinzeldokumente = try c.decodeIfPresent(Bool.self, forKey: .keepCopiesInEinzeldokumente) ?? d.keepCopiesInEinzeldokumente
        einzeldokumenteFolderName = try c.decodeIfPresent(String.self, forKey: .einzeldokumenteFolderName) ?? d.einzeldokumenteFolderName
        draftFolderName = try c.decodeIfPresent(String.self, forKey: .draftFolderName) ?? d.draftFolderName
    }
}
