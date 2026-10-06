import Foundation
import PDFKit
import CoreGraphics
import PDFilterParsing

/// Ein geladenes Dokument (eingehend oder bereits im Zielordner liegend).
final class LoadedDocument {
    let sourceURL: URL
    var document: PDFDocument
    let isImage: Bool
    let isIncoming: Bool
    var aktenzeichen: Aktenzeichen?
    var descriptor: DocumentDescriptor
    var firstPageText: PageText?
    var preview: CGImage?

    init(sourceURL: URL, document: PDFDocument, isImage: Bool, isIncoming: Bool) {
        self.sourceURL = sourceURL
        self.document = document
        self.isImage = isImage
        self.isIncoming = isIncoming
        let base = FileNaming.baseName(sourceURL.lastPathComponent)
        descriptor = DocumentDescriptor(
            id: sourceURL.path,
            fileName: sourceURL.lastPathComponent,
            number: isIncoming ? nil : FileNaming.leadingNumber(base),
            isIncoming: isIncoming,
            pageCount: document.pageCount)
    }

    /// Bereinigter Name ohne Aktenzeichen-Präfix, Erweiterung und Nummer.
    var cleanName: String {
        FileNaming.sanitize(FileNaming.displayName(forFileName: sourceURL.lastPathComponent))
    }
}

/// Steuert den gesamten Ablauf: Laden → Aktenzeichen → Akte finden → Plan → Bestätigung → Ausführung.
public final class Processor {
    public private(set) var settings: PDFilterSettings
    let interaction: UserInteraction
    let logger: PDFilterLogger
    let ocr: OCRService
    let extractor: DocumentTextExtractor
    let indexer: GesamtakteIndexer
    let cache: PageDateCache?
    let backups: BackupManager
    let locator: AkteLocator
    private var cancelled = false

    public init(settings: PDFilterSettings, interaction: UserInteraction, logger: PDFilterLogger = .shared,
                cache: PageDateCache? = PageDateCache(), backups: BackupManager = BackupManager()) {
        self.settings = settings
        self.interaction = interaction
        self.logger = logger
        self.ocr = OCRService()
        self.extractor = DocumentTextExtractor(ocr: ocr)
        self.cache = cache
        self.indexer = GesamtakteIndexer(extractor: extractor, cache: cache)
        self.backups = backups
        self.locator = AkteLocator(settings: settings)
    }

    // MARK: - Einstieg

    public func process(files: [URL]) async -> [ProcessingOutcome] {
        cancelled = false
        var outcomes: [ProcessingOutcome] = []
        var loaded: [LoadedDocument] = []
        let known = locator.knownAktenzeichen()

        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.standardizedFileURL.path).inserted }

        for url in unique {
            if cancelled { break }
            await interaction.fileStatus(url, "Wird gelesen …")
            do {
                let doc = try load(url, isIncoming: true)
                if let az = AktenzeichenFinder.aktenzeichen(inFileName: url.lastPathComponent) {
                    doc.aktenzeichen = az
                    logger.log("»\(url.lastPathComponent)«: Aktenzeichen \(az.display) aus Dateiname.")
                } else {
                    await interaction.fileStatus(url, "Aktenzeichen wird gesucht …")
                    let text = extractor.firstPageText(of: doc.document)
                    doc.firstPageText = text
                    let suggestions = AktenzeichenFinder.rankedSuggestions(from: text.fullText, knownAktenzeichen: known)
                    doc.preview = Self.preview(doc.document)
                    let answer = await interaction.askAktenzeichen(fileName: url.lastPathComponent, suggestions: suggestions, preview: doc.preview)
                    switch answer {
                    case .value(let az):
                        doc.aktenzeichen = az
                        logger.log("»\(url.lastPathComponent)«: Aktenzeichen \(az.display) vom Nutzer eingegeben.")
                    case .skipFile:
                        await interaction.fileStatus(url, "Übersprungen")
                        outcomes.append(ProcessingOutcome(aktenzeichen: nil, success: false, title: "»\(url.lastPathComponent)« übersprungen",
                                                          details: ["Kein Aktenzeichen angegeben."]))
                        continue
                    case .cancelAll:
                        cancelled = true
                        await interaction.fileStatus(url, "Abgebrochen")
                        continue
                    }
                }
                await interaction.fileStatus(url, "Aktenzeichen \(doc.aktenzeichen!.display)")
                loaded.append(doc)
            } catch {
                logger.log("Fehler bei »\(url.lastPathComponent)«: \(error.localizedDescription)")
                await interaction.fileStatus(url, "Fehler")
                outcomes.append(ProcessingOutcome(aktenzeichen: nil, success: false, title: "»\(url.lastPathComponent)« konnte nicht verarbeitet werden",
                                                  details: [error.localizedDescription]))
            }
        }

        if cancelled {
            outcomes.append(ProcessingOutcome(aktenzeichen: nil, success: false, title: "Verarbeitung abgebrochen", details: ["Es wurde nichts verändert."]))
            return outcomes
        }

        let groups = Dictionary(grouping: loaded, by: { $0.aktenzeichen! })
        for az in groups.keys.sorted() {
            if cancelled { break }
            let docs = groups[az]!
            let outcome = await processGroup(az: az, incoming: docs)
            outcomes.append(outcome)
            for d in docs { await interaction.fileStatus(d.sourceURL, outcome.success ? (outcome.isDraft ? "Entwurf erstellt" : "Erledigt") : "Nicht verarbeitet") }
        }
        if cancelled {
            outcomes.append(ProcessingOutcome(aktenzeichen: nil, success: false, title: "Verarbeitung abgebrochen", details: ["Weitere Akten wurden nicht bearbeitet."]))
        }
        return outcomes
    }

    // MARK: - Laden

    func load(_ url: URL, isIncoming: Bool) throws -> LoadedDocument {
        if SearchablePDFWriter.isPDF(url) {
            guard let doc = PDFDocument(url: url) else { throw PDFilterError.cannotOpenPDF(url) }
            if doc.isLocked || doc.pageCount == 0 { throw PDFilterError.cannotOpenPDF(url) }
            return LoadedDocument(sourceURL: url, document: doc, isImage: false, isIncoming: isIncoming)
        }
        if SearchablePDFWriter.isImage(url) {
            guard let doc = SearchablePDFWriter.pdf(fromImage: url, ocr: settings.makeSearchable ? ocr : nil) else {
                throw PDFilterError.imageConversionFailed(url)
            }
            logger.log("»\(url.lastPathComponent)«: Bild in PDF umgewandelt.")
            return LoadedDocument(sourceURL: url, document: doc, isImage: true, isIncoming: isIncoming)
        }
        throw PDFilterError.unsupportedFile(url)
    }

    static func preview(_ document: PDFDocument) -> CGImage? {
        guard let page = document.page(at: 0) else { return nil }
        return PDFPageRenderer.render(page, dpi: 90)
    }

    // MARK: - Eine Akte

    func processGroup(az: Aktenzeichen, incoming: [LoadedDocument]) async -> ProcessingOutcome {
        do {
            await interaction.progress("Akte \(az.display): Aktenordner wird gesucht …")
            let folders = try locator.findAkteFolders(for: az)
            let akte: URL
            if folders.isEmpty {
                throw PDFilterError.noAkteFound(az, root: settings.rootFolder)
            } else if folders.count == 1 {
                akte = folders[0]
            } else {
                guard let chosen = await interaction.chooseAkteFolder(for: az, candidates: folders) else {
                    return cancelledOutcome(az)
                }
                akte = chosen
            }
            let target = try locator.targetFolder(in: akte)
            logger.log("Akte \(az.display): Zielordner »\(target.path)«.")

            var state = TargetFolderAnalyzer.analyze(folder: target, settings: settings, az: az)
            if case .ambiguous(let candidates, let all) = state {
                switch await interaction.chooseGesamtakte(in: target, candidates: candidates, all: all) {
                case .file(let f): state = .gesamtakteWithSingles(gesamtakte: f, singles: all.filter { $0 != f })
                case .treatAllAsSingles: state = .singles(all)
                case .cancel: return cancelledOutcome(az)
                }
            }

            // Bestehende Einzeldateien laden
            var existing: [LoadedDocument] = []
            var singleURLs: [URL] = []
            var gesamtakteURL: URL?
            switch state {
            case .empty: break
            case .gesamtakte(let g): gesamtakteURL = g
            case .gesamtakteWithSingles(let g, let singles): gesamtakteURL = g; singleURLs = singles
            case .singles(let singles): singleURLs = singles
            case .ambiguous: break
            }
            for url in singleURLs {
                existing.append(try load(url, isIncoming: false))
            }

            // Daten bestimmen
            var all = incoming + existing
            var kept: [LoadedDocument] = []
            for d in all {
                await interaction.progress("Akte \(az.display): Datum von »\(d.sourceURL.lastPathComponent)« wird ermittelt …")
                let keep = await determineDate(d)
                if cancelled { return cancelledOutcome(az) }
                if keep { kept.append(d) }
            }
            all = kept
            let keptIncoming = all.filter { $0.isIncoming }
            guard !keptIncoming.isEmpty else {
                return ProcessingOutcome(aktenzeichen: az, success: false, title: "Akte \(az.display): keine Dokumente", details: ["Alle Dateien wurden übersprungen."])
            }
            let keptExisting = all.filter { !$0.isIncoming }

            // Plan
            let plan: ProcessingPlan
            if let g = gesamtakteURL {
                plan = try await planInsert(az: az, akte: akte, target: target, gesamtakte: g, docs: keptIncoming + keptExisting)
            } else if keptExisting.isEmpty {
                plan = planMerge(kind: .createNew, az: az, akte: akte, target: target, docs: keptIncoming)
            } else {
                plan = planMerge(kind: .rebuildFromSingles, az: az, akte: akte, target: target, docs: keptIncoming + keptExisting)
            }

            // Bestätigung
            var decision = PlanDecision.proceed
            if settings.needsConfirmation(for: az) || plan.isUncertain || !plan.warnings.isEmpty {
                decision = await interaction.confirm(plan: plan)
                guard decision.execute else { return cancelledOutcome(az) }
                if decision.rememberNoConfirm, !settings.noConfirmAkten.contains(az.display) {
                    settings.noConfirmAkten.append(az.display)
                    try? settings.save()
                }
            }

            return try await execute(plan: plan, decision: decision, docs: all)
        } catch {
            logger.log("Akte \(az.display): FEHLER – \(error.localizedDescription)")
            return ProcessingOutcome(aktenzeichen: az, success: false, title: "Akte \(az.display): Fehler", details: [error.localizedDescription, "Es wurde nichts verändert."])
        }
    }

    func cancelledOutcome(_ az: Aktenzeichen) -> ProcessingOutcome {
        logger.log("Akte \(az.display): vom Nutzer abgebrochen.")
        return ProcessingOutcome(aktenzeichen: az, success: false, title: "Akte \(az.display): abgebrochen", details: ["Es wurde nichts verändert."])
    }

    /// Datum eines Dokuments bestimmen. Rückgabe false = Datei überspringen.
    func determineDate(_ d: LoadedDocument) async -> Bool {
        if let m = FileNameDateParser.firstDate(inFileName: d.sourceURL.lastPathComponent) {
            d.descriptor.date = m.date
            d.descriptor.dateSource = .fileName
            d.descriptor.dateConfidence = .high
            return true
        }
        let text = d.firstPageText ?? extractor.firstPageText(of: d.document)
        d.firstPageText = text
        let decision = TextDateFinder.decide(lines: text.lines)
        switch decision.confidence {
        case .high, .medium:
            d.descriptor.date = decision.date
            d.descriptor.dateSource = .document
            d.descriptor.dateConfidence = decision.confidence
            logger.log("»\(d.sourceURL.lastPathComponent)«: Datum \(decision.date?.german ?? "-") aus Dokument (\(decision.confidence.german)).")
            return true
        case .low, .none:
            // Nummerierte Bestandsdateien: Nummer hat Vorrang, kein Nachfragen nötig.
            if d.descriptor.number != nil, !d.isIncoming {
                d.descriptor.dateConfidence = decision.confidence
                return true
            }
            if d.preview == nil { d.preview = Self.preview(d.document) }
            let answer = await interaction.askDate(fileName: d.sourceURL.lastPathComponent, candidates: decision.candidates, preview: d.preview)
            switch answer {
            case .date(let date):
                d.descriptor.date = date
                d.descriptor.dateSource = .user
                d.descriptor.dateConfidence = .high
                logger.log("»\(d.sourceURL.lastPathComponent)«: Datum \(date.german) manuell eingegeben.")
                return true
            case .noDate:
                d.descriptor.dateSource = .none
                d.descriptor.dateConfidence = .none
                return true
            case .skipFile:
                logger.log("»\(d.sourceURL.lastPathComponent)«: übersprungen.")
                return false
            case .cancelAll:
                cancelled = true
                return false
            }
        }
    }

    // MARK: - Planung

    func gesamtakteDestination(target: URL, az: Aktenzeichen) -> URL {
        target.appendingPathComponent(settings.gesamtakteName(for: az))
    }

    func draftDestination(target: URL, az: Aktenzeichen) -> URL {
        target.appendingPathComponent(settings.draftFolderName, isDirectory: true).appendingPathComponent(settings.gesamtakteName(for: az))
    }

    func planMerge(kind: PlanKind, az: Aktenzeichen, akte: URL, target: URL, docs: [LoadedDocument]) -> ProcessingPlan {
        let ordering = DocumentOrdering.order(docs.map(\.descriptor))
        var warnings = ordering.warnings
        for d in docs where d.descriptor.dateConfidence == .medium {
            warnings.append("Datum von »\(d.descriptor.fileName)« (\(d.descriptor.dateText)) wurde als »wahrscheinlich« erkannt – bitte prüfen.")
        }
        var steps: [String] = []
        steps.append("Zielordner: \(target.path)")
        if kind == .rebuildFromSingles {
            steps.append("Vorhandene Einzeldokumente (\(docs.filter { !$0.isIncoming }.count)) und neue Dokumente (\(docs.filter { $0.isIncoming }.count)) werden sortiert.")
        }
        for (i, d) in ordering.ordered.enumerated() {
            let tag = d.isIncoming ? "NEU" : "vorhanden"
            steps.append("\(FileNaming.numberPrefix(i + 1)). \(d.fileName) – \(d.dateText) (\(d.dateSource.german)) [\(tag)]")
        }
        let dest = gesamtakteDestination(target: target, az: az)
        let draft = draftDestination(target: target, az: az)
        if ordering.isUncertain {
            steps.append("Wegen unsicherer Sortierung wird die Gesamtakte im Entwurfsordner angelegt: \(draft.path). Die Akte bleibt unverändert.")
        } else {
            steps.append("Gesamtakte wird angelegt: \(dest.path)")
            if kind == .rebuildFromSingles {
                steps.append("Die vorhandenen Einzeldokumente werden nummeriert in den Unterordner »\(settings.einzeldokumenteFolderName)« verschoben.")
            }
            if settings.keepCopiesInEinzeldokumente {
                steps.append("Von den neuen Dokumenten bleibt je eine Kopie im Unterordner »\(settings.einzeldokumenteFolderName)«.")
            }
            if settings.moveOriginalsToTrash {
                steps.append("Die Originaldateien werden in den Papierkorb gelegt.")
            }
        }
        return ProcessingPlan(
            aktenzeichen: az, akteFolder: akte, targetFolder: target, kind: kind,
            existingGesamtakte: nil, gesamtakteURL: dest, draftURL: draft,
            einzeldokumenteFolder: target.appendingPathComponent(settings.einzeldokumenteFolderName, isDirectory: true),
            orderedDocuments: ordering.ordered, insertions: [],
            singlesToMove: docs.filter { !$0.isIncoming }.map(\.sourceURL),
            warnings: warnings, uncertainReasons: ordering.uncertainReasons,
            incomingCount: docs.filter { $0.isIncoming }.count, steps: steps)
    }

    func planInsert(az: Aktenzeichen, akte: URL, target: URL, gesamtakte: URL, docs: [LoadedDocument]) async throws -> ProcessingPlan {
        guard let existingDoc = PDFDocument(url: gesamtakte), !existingDoc.isLocked, existingDoc.pageCount > 0 else {
            throw PDFilterError.cannotOpenPDF(gesamtakte)
        }
        await interaction.progress("Akte \(az.display): Gesamtakte »\(gesamtakte.lastPathComponent)« wird analysiert (\(existingDoc.pageCount) Seiten) …")
        let ui = self.interaction
        let pageInfo = indexer.pageDates(of: existingDoc, at: gesamtakte, maxOCRPages: settings.maxOCRPagesForSorting) { message in
            Task { @MainActor in ui.progress(message) }
        }
        var warnings: [String] = []
        if !pageInfo.complete {
            warnings.append("\(pageInfo.skippedOCRPages) Seiten der Gesamtakte ohne Textebene wurden wegen der Obergrenze (\(settings.maxOCRPagesForSorting)) nicht per OCR gelesen. Die Einsortierung kann dadurch ungenau sein; im Zweifel wird ans Ende angehängt.")
        }
        for d in docs where d.descriptor.dateConfidence == .medium {
            warnings.append("Datum von »\(d.descriptor.fileName)« (\(d.descriptor.dateText)) wurde als »wahrscheinlich« erkannt – bitte prüfen.")
        }

        let sorted = docs.sorted { a, b in
            switch (a.descriptor.date, b.descriptor.date) {
            case let (da?, db?) where da != db: return da < db
            case (nil, .some(_)): return false
            case (.some(_), nil): return true
            default: return a.descriptor.fileName.localizedStandardCompare(b.descriptor.fileName) == .orderedAscending
            }
        }
        var simulated = pageInfo.dates
        var insertions: [PlannedInsertion] = []
        for d in sorted {
            let decision = InsertionPlanner.insertionIndex(pageDates: simulated, newDate: d.descriptor.date)
            insertions.append(PlannedInsertion(
                id: d.descriptor.id, fileName: d.descriptor.fileName, displayName: d.descriptor.displayName,
                date: d.descriptor.date, dateSource: d.descriptor.dateSource,
                pageIndex: decision.pageIndex, pagesBefore: simulated.count, pageCount: d.document.pageCount,
                isCertain: decision.isCertain, reason: decision.reason))
            var newDates = [DayDate?](repeating: nil, count: max(1, d.document.pageCount))
            newDates[0] = d.descriptor.date
            simulated.insert(contentsOf: newDates, at: min(decision.pageIndex, simulated.count))
            if let reason = decision.reason {
                warnings.append("»\(d.descriptor.fileName)«: \(reason)")
            }
        }

        let dest = gesamtakteDestination(target: target, az: az)
        var steps: [String] = []
        steps.append("Bestehende Gesamtakte: \(gesamtakte.path) (\(existingDoc.pageCount) Seiten)")
        steps.append("Vorher wird eine Sicherungskopie angelegt (\(settings.backupCount) werden aufbewahrt).")
        for ins in insertions {
            let tag = docs.first(where: { $0.descriptor.id == ins.id })?.isIncoming == true ? "NEU" : "vorhanden"
            steps.append("»\(ins.fileName)« (\(ins.date?.german ?? "ohne Datum"), \(ins.pageCount) S.) → \(ins.positionText) [\(tag)]\(ins.isCertain ? "" : " – unsicher, daher am Ende")")
        }
        if gesamtakte.lastPathComponent != dest.lastPathComponent {
            steps.append("Die Gesamtakte wird in »\(dest.lastPathComponent)« umbenannt.")
        }
        let singles = docs.filter { !$0.isIncoming }.map(\.sourceURL)
        if !singles.isEmpty {
            steps.append("Die \(singles.count) vorhandenen Einzeldokumente werden nach dem Einfügen in den Unterordner »\(settings.einzeldokumenteFolderName)« verschoben.")
        }
        if settings.keepCopiesInEinzeldokumente {
            steps.append("Von den neuen Dokumenten bleibt je eine Kopie im Unterordner »\(settings.einzeldokumenteFolderName)«.")
        }
        if settings.moveOriginalsToTrash {
            steps.append("Die Originaldateien werden in den Papierkorb gelegt.")
        }
        return ProcessingPlan(
            aktenzeichen: az, akteFolder: akte, targetFolder: target, kind: .insertIntoExisting,
            existingGesamtakte: gesamtakte, gesamtakteURL: dest, draftURL: draftDestination(target: target, az: az),
            einzeldokumenteFolder: target.appendingPathComponent(settings.einzeldokumenteFolderName, isDirectory: true),
            orderedDocuments: sorted.map(\.descriptor), insertions: insertions, singlesToMove: singles,
            warnings: warnings, uncertainReasons: [], incomingCount: docs.filter { $0.isIncoming }.count, steps: steps)
    }

    // MARK: - Ausführung

    func execute(plan: ProcessingPlan, decision: PlanDecision, docs: [LoadedDocument]) async throws -> ProcessingOutcome {
        let az = plan.aktenzeichen
        var details: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: docs.map { ($0.descriptor.id, $0) })

        // 1. Durchsuchbar machen (nur neue Dokumente; Bilder haben bereits eine Textebene)
        if settings.makeSearchable {
            for d in docs where d.isIncoming && !d.isImage {
                await interaction.progress("Akte \(az.display): »\(d.sourceURL.lastPathComponent)« wird per OCR durchsuchbar gemacht …")
                let result = SearchablePDFWriter.makeSearchable(d.document, ocr: ocr)
                if result.ocrPages > 0 {
                    d.document = result.document
                    details.append("»\(d.sourceURL.lastPathComponent)«: \(result.ocrPages) Seite(n) per OCR durchsuchbar gemacht.")
                    logger.log("»\(d.sourceURL.lastPathComponent)«: \(result.ocrPages) Seiten per OCR durchsuchbar gemacht.")
                }
            }
        }

        let useDraft = plan.usesDraftByDefault && !decision.writeIntoAkteDespiteUncertainty
        var finalURL = plan.gesamtakteURL
        var finalPageDates: [DayDate?] = []

        switch plan.kind {
        case .createNew, .rebuildFromSingles:
            var parts: [(document: PDFDocument, outlineTitle: String)] = []
            for desc in plan.orderedDocuments {
                guard let d = byID[desc.id] else { continue }
                parts.append((d.document, GesamtakteOutline.title(date: desc.date, name: desc.displayName)))
                var dates = [DayDate?](repeating: nil, count: max(1, d.document.pageCount))
                dates[0] = desc.date
                finalPageDates.append(contentsOf: dates)
            }
            await interaction.progress("Akte \(az.display): Gesamtakte wird zusammengesetzt …")
            let merged = PDFAssembler.merge(parts)
            finalURL = useDraft ? SafeFileWriter.uniqueURL(plan.draftURL) : SafeFileWriter.uniqueURL(plan.gesamtakteURL)
            try SafeFileWriter.write(merged, to: finalURL)
            logger.log("Akte \(az.display): Gesamtakte geschrieben: \(finalURL.path) (\(merged.pageCount) Seiten).")
            details.append("Gesamtakte mit \(merged.pageCount) Seiten angelegt: \(finalURL.path)")

        case .insertIntoExisting:
            guard let existing = plan.existingGesamtakte, let doc = PDFDocument(url: existing), !doc.isLocked else {
                throw PDFilterError.cannotOpenPDF(plan.existingGesamtakte ?? plan.gesamtakteURL)
            }
            let backup = try backups.backup(existing, for: az, keep: settings.backupCount)
            details.append("Sicherungskopie: \(backup.path)")
            logger.log("Akte \(az.display): Sicherung \(backup.path)")

            // Seitendaten für den Cache rekonstruieren
            var dates = indexerDatesForCache(doc: doc, url: existing)
            var expected = doc.pageCount
            for ins in plan.insertions {
                guard let d = byID[ins.id] else { continue }
                let index = decision.appendAtEnd ? doc.pageCount : min(ins.pageIndex, doc.pageCount)
                let title = GesamtakteOutline.title(date: ins.date, name: ins.displayName)
                let n = PDFAssembler.insert(d.document, into: doc, at: index, outlineTitle: title)
                expected += n
                var newDates = [DayDate?](repeating: nil, count: max(1, n))
                newDates[0] = ins.date
                dates.insert(contentsOf: newDates.prefix(max(n, 0)), at: min(index, dates.count))
                let where_ = index >= doc.pageCount - n ? "ans Ende" : "vor Seite \(index + 1)"
                details.append("»\(ins.fileName)« (\(n) S.) \(where_) eingefügt.")
                logger.log("Akte \(az.display): »\(ins.fileName)« \(where_) eingefügt.")
            }
            await interaction.progress("Akte \(az.display): Gesamtakte wird gespeichert …")
            try SafeFileWriter.write(doc, to: existing, expectedPageCount: expected)
            finalURL = existing
            if existing.lastPathComponent != plan.gesamtakteURL.lastPathComponent {
                if FileManager.default.fileExists(atPath: plan.gesamtakteURL.path) {
                    details.append("Hinweis: »\(plan.gesamtakteURL.lastPathComponent)« existiert bereits; die Gesamtakte behält den Namen »\(existing.lastPathComponent)«.")
                } else {
                    try FileManager.default.moveItem(at: existing, to: plan.gesamtakteURL)
                    finalURL = plan.gesamtakteURL
                    details.append("Gesamtakte umbenannt in »\(plan.gesamtakteURL.lastPathComponent)«.")
                }
            }
            finalPageDates = dates
            details.append("Gesamtakte hat jetzt \(expected) Seiten: \(finalURL.path)")
        }
        cache?.store(finalPageDates, for: finalURL)

        // 2. Einzeldokumente, Kopien, Papierkorb
        if useDraft {
            // Entwurf: zusätzlich die neuen Dokumente umbenannt in den Entwurfsordner legen; Akte und Originale bleiben unverändert.
            let draftFolder = finalURL.deletingLastPathComponent()
            for d in docs where d.isIncoming {
                let name = "\(settings.prefix(for: az))_\(d.cleanName).pdf"
                let dest = SafeFileWriter.uniqueURL(draftFolder.appendingPathComponent(name))
                try SafeFileWriter.write(d.document, to: dest)
            }
            details.append("Die Akte wurde NICHT verändert. Bitte Entwurf prüfen und bei Bedarf von Hand übernehmen: \(draftFolder.path)")
            logger.log("Akte \(az.display): Entwurf erstellt in \(draftFolder.path)")
            return ProcessingOutcome(aktenzeichen: az, success: true, title: "Akte \(az.display): Entwurf erstellt (Sortierung unsicher)",
                                     details: plan.uncertainReasons + details, resultURL: finalURL, isDraft: true)
        }

        let einzel = plan.einzeldokumenteFolder
        let needEinzel = !plan.singlesToMove.isEmpty || (settings.keepCopiesInEinzeldokumente && plan.incomingCount > 0)
        if needEinzel {
            try FileManager.default.createDirectory(at: einzel, withIntermediateDirectories: true)
        }
        // Position je Dokument (für Nummerierung beim Neuaufbau)
        var position: [String: Int] = [:]
        if plan.kind != .insertIntoExisting {
            for (i, desc) in plan.orderedDocuments.enumerated() { position[desc.id] = i + 1 }
        }
        for d in docs where !d.isIncoming {
            let base = FileNaming.stripLeadingNumber(FileNaming.baseName(d.sourceURL.lastPathComponent))
            let name: String
            if let pos = position[d.descriptor.id] {
                name = "\(FileNaming.numberPrefix(pos))_\(FileNaming.sanitize(base)).pdf"
            } else {
                name = d.sourceURL.lastPathComponent
            }
            let dest = SafeFileWriter.uniqueURL(einzel.appendingPathComponent(name))
            try FileManager.default.moveItem(at: d.sourceURL, to: dest)
            details.append("»\(d.sourceURL.lastPathComponent)« → \(settings.einzeldokumenteFolderName)/\(dest.lastPathComponent)")
        }
        for d in docs where d.isIncoming {
            var name = "\(settings.prefix(for: az))_\(d.cleanName).pdf"
            if let pos = position[d.descriptor.id] { name = "\(FileNaming.numberPrefix(pos))_\(name)" }
            if settings.keepCopiesInEinzeldokumente {
                let dest = SafeFileWriter.uniqueURL(einzel.appendingPathComponent(name))
                try SafeFileWriter.write(d.document, to: dest)
                details.append("Kopie: \(settings.einzeldokumenteFolderName)/\(dest.lastPathComponent)")
            }
            if settings.moveOriginalsToTrash {
                do {
                    try FileManager.default.trashItem(at: d.sourceURL, resultingItemURL: nil)
                    details.append("Original »\(d.sourceURL.lastPathComponent)« in den Papierkorb gelegt.")
                } catch {
                    details.append("Original »\(d.sourceURL.lastPathComponent)« konnte nicht in den Papierkorb gelegt werden: \(error.localizedDescription)")
                }
            }
        }
        logger.log("Akte \(az.display): fertig.")
        return ProcessingOutcome(aktenzeichen: az, success: true, title: "Akte \(az.display): \(plan.incomingCount) Dokument(e) verarbeitet",
                                 details: details, resultURL: finalURL)
    }

    /// Seitendaten aus Cache/Lesezeichen für die Fortschreibung des Caches (ohne erneute OCR).
    func indexerDatesForCache(doc: PDFDocument, url: URL) -> [DayDate?] {
        if let cached = cache?.dates(for: url, pageCount: doc.pageCount) { return cached }
        var dates = [DayDate?](repeating: nil, count: doc.pageCount)
        for e in GesamtakteOutline.entries(of: doc) where e.pageIndex < doc.pageCount { dates[e.pageIndex] = e.date }
        return dates
    }
}
