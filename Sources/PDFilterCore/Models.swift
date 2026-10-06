import Foundation
import CoreGraphics
import PDFilterParsing

public enum AktenzeichenAnswer: Sendable {
    case value(Aktenzeichen)
    case skipFile
    case cancelAll
}

public enum DateAnswer: Sendable {
    case date(DayDate)
    case noDate
    case skipFile
    case cancelAll
}

public enum GesamtakteChoice: Sendable {
    case file(URL)
    case treatAllAsSingles
    case cancel
}

public struct PlanDecision: Sendable {
    public var execute: Bool
    /// Alle neuen Dokumente ans Ende anhängen statt einzusortieren.
    public var appendAtEnd: Bool
    /// Trotz unsicherer Sortierung direkt in die Akte schreiben (statt in den Entwurfsordner).
    public var writeIntoAkteDespiteUncertainty: Bool
    /// Für diese Akte künftig keine Vorschau mehr zeigen.
    public var rememberNoConfirm: Bool

    public init(execute: Bool, appendAtEnd: Bool = false, writeIntoAkteDespiteUncertainty: Bool = false, rememberNoConfirm: Bool = false) {
        self.execute = execute
        self.appendAtEnd = appendAtEnd
        self.writeIntoAkteDespiteUncertainty = writeIntoAkteDespiteUncertainty
        self.rememberNoConfirm = rememberNoConfirm
    }

    public static let cancel = PlanDecision(execute: false)
    public static let proceed = PlanDecision(execute: true)
}

public enum PlanKind: String, Sendable {
    /// Zielordner leer → neue Gesamtakte anlegen.
    case createNew
    /// Bestehende Gesamtakte → Dokumente nach Datum einsortieren.
    case insertIntoExisting
    /// Einzel-PDFs vorhanden → sortieren und Gesamtakte erzeugen.
    case rebuildFromSingles

    public var german: String {
        switch self {
        case .createNew: return "Neue Gesamtakte anlegen"
        case .insertIntoExisting: return "In bestehende Gesamtakte einsortieren"
        case .rebuildFromSingles: return "Einzeldokumente sortieren und Gesamtakte erzeugen"
        }
    }
}

/// Geplante Einfügung in eine bestehende Gesamtakte.
public struct PlannedInsertion: Identifiable, Sendable, Hashable {
    public let id: String
    public let fileName: String
    public let displayName: String
    public let date: DayDate?
    public let dateSource: DateSource
    /// Seitenindex (0-basiert) im Dokumentzustand unmittelbar vor dieser Einfügung.
    public let pageIndex: Int
    /// Seitenzahl der Gesamtakte unmittelbar vor dieser Einfügung.
    public let pagesBefore: Int
    public let pageCount: Int
    public let isCertain: Bool
    public let reason: String?

    public var isAppend: Bool { pageIndex >= pagesBefore }

    public var positionText: String {
        isAppend ? "ans Ende (nach Seite \(pagesBefore))" : "vor Seite \(pageIndex + 1)"
    }
}

/// Vollständiger Plan für eine Akte – wird dem Nutzer zur Bestätigung gezeigt.
public struct ProcessingPlan: Identifiable, Sendable {
    public let id = UUID()
    public let aktenzeichen: Aktenzeichen
    public let akteFolder: URL
    public let targetFolder: URL
    public let kind: PlanKind
    public let existingGesamtakte: URL?
    /// Endgültiger Ort der Gesamtakte in der Akte.
    public let gesamtakteURL: URL
    /// Ort im Entwurfsordner (bei unsicherer Sortierung).
    public let draftURL: URL
    public let einzeldokumenteFolder: URL
    public let orderedDocuments: [DocumentDescriptor]
    public let insertions: [PlannedInsertion]
    public let singlesToMove: [URL]
    public let warnings: [String]
    public let uncertainReasons: [String]
    public let incomingCount: Int
    public let steps: [String]

    public var isUncertain: Bool { !uncertainReasons.isEmpty }
    /// Bei unsicherer Sortierung wird standardmäßig in den Entwurfsordner geschrieben (nicht beim Einsortieren).
    public var usesDraftByDefault: Bool { isUncertain && kind != .insertIntoExisting }
    public var canAppendAtEnd: Bool { kind == .insertIntoExisting }

    public init(aktenzeichen: Aktenzeichen, akteFolder: URL, targetFolder: URL, kind: PlanKind,
                existingGesamtakte: URL?, gesamtakteURL: URL, draftURL: URL, einzeldokumenteFolder: URL,
                orderedDocuments: [DocumentDescriptor], insertions: [PlannedInsertion], singlesToMove: [URL],
                warnings: [String], uncertainReasons: [String], incomingCount: Int, steps: [String]) {
        self.aktenzeichen = aktenzeichen
        self.akteFolder = akteFolder
        self.targetFolder = targetFolder
        self.kind = kind
        self.existingGesamtakte = existingGesamtakte
        self.gesamtakteURL = gesamtakteURL
        self.draftURL = draftURL
        self.einzeldokumenteFolder = einzeldokumenteFolder
        self.orderedDocuments = orderedDocuments
        self.insertions = insertions
        self.singlesToMove = singlesToMove
        self.warnings = warnings
        self.uncertainReasons = uncertainReasons
        self.incomingCount = incomingCount
        self.steps = steps
    }
}

/// Ergebnis der Verarbeitung einer Akte (oder einer einzelnen fehlgeschlagenen Datei).
public struct ProcessingOutcome: Identifiable, Sendable {
    public let id = UUID()
    public let aktenzeichen: Aktenzeichen?
    public let success: Bool
    public let title: String
    public let details: [String]
    public let resultURL: URL?
    public let isDraft: Bool

    public init(aktenzeichen: Aktenzeichen?, success: Bool, title: String, details: [String] = [], resultURL: URL? = nil, isDraft: Bool = false) {
        self.aktenzeichen = aktenzeichen
        self.success = success
        self.title = title
        self.details = details
        self.resultURL = resultURL
        self.isDraft = isDraft
    }
}

/// Rückfragen an den Nutzer. Die App setzt dieses Protokoll mit Dialogen um, Tests mit festen Antworten.
public protocol UserInteraction: AnyObject {
    @MainActor func askAktenzeichen(fileName: String, suggestions: [Aktenzeichen], preview: CGImage?) async -> AktenzeichenAnswer
    @MainActor func chooseAkteFolder(for az: Aktenzeichen, candidates: [URL]) async -> URL?
    @MainActor func askDate(fileName: String, candidates: [DateCandidate], preview: CGImage?) async -> DateAnswer
    @MainActor func chooseGesamtakte(in folder: URL, candidates: [URL], all: [URL]) async -> GesamtakteChoice
    @MainActor func confirm(plan: ProcessingPlan) async -> PlanDecision
    @MainActor func progress(_ message: String)
    @MainActor func fileStatus(_ url: URL, _ status: String)
}
