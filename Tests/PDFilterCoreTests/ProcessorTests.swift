import XCTest
import PDFKit
import ImageIO
@testable import PDFilterCore
import PDFilterParsing

final class ProcessorTests: XCTestCase {
    var root: URL!
    var inbox: URL!
    var target: URL!
    var settings: Settings!

    override func setUpWithError() throws {
        root = makeTempDir("Root")
        inbox = makeTempDir("Inbox")
        target = root.appendingPathComponent("34:26 - Kinzel ./. Robin/01_Akte/01_Gesamtakte", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        settings = Settings(rootFolderPath: root.path, moveOriginalsToTrash: false, makeSearchable: false)
    }

    func makeProcessor(_ interaction: ScriptedInteraction) -> Processor {
        Processor(settings: settings, interaction: interaction, logger: PDFilterLogger(fileURL: root.appendingPathComponent("log.txt")),
                  cache: nil, backups: BackupManager(root: root.appendingPathComponent("Sicherungen")))
    }

    func testCreateThenInsertThenRebuild() async throws {
        // 1. Leerer Zielordner → neue Gesamtakte
        let f1 = inbox.appendingPathComponent("34:26_Anschreiben.pdf")
        TestPDF.make(pages: [["Kanzlei", "Berlin, den 01.11.2024", "Anschreiben"]], at: f1)
        let f2 = inbox.appendingPathComponent("34-26 Erwiderung 2024-12-01.pdf")
        TestPDF.make(pages: [["Erwiderung Seite 1"], ["Erwiderung Seite 2"]], at: f2)

        let i1 = ScriptedInteraction()
        let p1 = makeProcessor(i1)
        let out1 = await p1.process(files: [f2, f1])
        XCTAssertEqual(out1.count, 1)
        XCTAssertTrue(out1[0].success, out1[0].details.joined(separator: "\n"))
        XCTAssertEqual(i1.plans.count, 1)
        XCTAssertEqual(i1.plans[0].kind, .createNew)
        XCTAssertEqual(i1.plans[0].orderedDocuments.map(\.fileName), ["34:26_Anschreiben.pdf", "34-26 Erwiderung 2024-12-01.pdf"])
        let gesamt = target.appendingPathComponent("Gesamtakte.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gesamt.path))
        let doc1 = PDFDocument(url: gesamt)!
        XCTAssertEqual(doc1.pageCount, 3)
        XCTAssertEqual(GesamtakteOutline.entries(of: doc1).map { $0.date?.iso }, ["2024-11-01", "2024-12-01"])
        let einzel = target.appendingPathComponent("Einzeldokumente")
        let copies = try FileManager.default.contentsOfDirectory(atPath: einzel.path).sorted()
        XCTAssertEqual(copies, ["01_34:26_Anschreiben.pdf", "02_34:26_Erwiderung 2024-12-01.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f1.path)) // Papierkorb deaktiviert

        // 2. Bestehende Gesamtakte → einsortieren (Datum zwischen den beiden)
        let f3 = inbox.appendingPathComponent("Fristverlängerung.pdf")
        TestPDF.make(pages: [["Rechtsanwälte", "München, den 15.11.2024", "Antrag auf Fristverlängerung"]], at: f3)
        let i2 = ScriptedInteraction()
        i2.aktenzeichenAnswer = .value(Aktenzeichen(number: 34, year: 26)!)
        let p2 = makeProcessor(i2)
        let out2 = await p2.process(files: [f3])
        XCTAssertTrue(out2[0].success, out2[0].details.joined(separator: "\n"))
        XCTAssertEqual(i2.askedAktenzeichen, ["Fristverlängerung.pdf"])
        XCTAssertEqual(i2.plans[0].kind, .insertIntoExisting)
        XCTAssertEqual(i2.plans[0].insertions.first?.pageIndex, 1)
        XCTAssertEqual(i2.plans[0].insertions.first?.isCertain, true)
        let doc2 = PDFDocument(url: gesamt)!
        XCTAssertEqual(doc2.pageCount, 4)
        XCTAssertTrue(doc2.page(at: 1)!.string!.contains("Fristverlängerung"))
        XCTAssertEqual(GesamtakteOutline.entries(of: doc2).map { $0.date?.iso }, ["2024-11-01", "2024-11-15", "2024-12-01"])
        // Sicherung vorhanden
        XCTAssertEqual(BackupManager(root: root.appendingPathComponent("Sicherungen")).backups(for: Aktenzeichen(number: 34, year: 26)!).count, 1)

        // 3. Neuestes Dokument → ans Ende; Gesamtakte mit abweichendem Namen wird umbenannt
        try FileManager.default.moveItem(at: gesamt, to: target.appendingPathComponent("Akte.pdf"))
        let f4 = inbox.appendingPathComponent("34:26_Urteil_2025-01-10.pdf")
        TestPDF.make(pages: [["Urteil"]], at: f4)
        let i3 = ScriptedInteraction()
        let out3 = await makeProcessor(i3).process(files: [f4])
        XCTAssertTrue(out3[0].success, out3[0].details.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gesamt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Akte.pdf").path))
        XCTAssertEqual(PDFDocument(url: gesamt)!.pageCount, 5)
        XCTAssertEqual(i3.plans[0].insertions.first?.isAppend, true)
    }

    func testRebuildFromSinglesWithNumbering() async throws {
        TestPDF.make(pages: [["Anschreiben"]], at: target.appendingPathComponent("01_Anschreiben.pdf"))
        TestPDF.make(pages: [["Antrag"]], at: target.appendingPathComponent("02_Antrag_2024-12-10.pdf"))
        let f = inbox.appendingPathComponent("34:26_Stellungnahme_2024-12-05.pdf")
        TestPDF.make(pages: [["Stellungnahme"]], at: f)
        let i = ScriptedInteraction()
        let out = await makeProcessor(i).process(files: [f])
        XCTAssertTrue(out[0].success, out[0].details.joined(separator: "\n"))
        XCTAssertEqual(i.plans[0].kind, .rebuildFromSingles)
        // Nummerierte Dateien zuerst (01 ohne Datum, 02 mit 10.12.), die neue (05.12.) wird vor 02 einsortiert
        XCTAssertEqual(i.plans[0].orderedDocuments.map(\.fileName), ["01_Anschreiben.pdf", "34:26_Stellungnahme_2024-12-05.pdf", "02_Antrag_2024-12-10.pdf"])
        let gesamt = target.appendingPathComponent("Gesamtakte.pdf")
        XCTAssertEqual(PDFDocument(url: gesamt)!.pageCount, 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        XCTAssertEqual(files, ["Einzeldokumente", "Gesamtakte.pdf"])
        let einzel = try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("Einzeldokumente").path).sorted()
        XCTAssertEqual(einzel, ["01_Anschreiben.pdf", "02_34:26_Stellungnahme_2024-12-05.pdf", "03_Antrag_2024-12-10.pdf"])
    }

    func testUncertainGoesToDraft() async throws {
        TestPDF.make(pages: [["Irgendwas ohne Datum"]], at: target.appendingPathComponent("Notiz.pdf"))
        TestPDF.make(pages: [["Noch etwas ohne Datum"]], at: target.appendingPathComponent("Zettel.pdf"))
        let f = inbox.appendingPathComponent("34:26_Neu_2024-12-05.pdf")
        TestPDF.make(pages: [["Neu"]], at: f)
        let i = ScriptedInteraction()
        i.dateAnswer = .noDate
        let out = await makeProcessor(i).process(files: [f])
        XCTAssertTrue(out[0].success, out[0].details.joined(separator: "\n"))
        XCTAssertTrue(out[0].isDraft)
        XCTAssertTrue(i.plans[0].isUncertain)
        let draft = target.appendingPathComponent("_PDFilter_Entwurf/Gesamtakte.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.path))
        XCTAssertEqual(PDFDocument(url: draft)!.pageCount, 3)
        // Akte unverändert
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Notiz.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Gesamtakte.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testMissingAkteAndStructureErrors() async throws {
        let f = inbox.appendingPathComponent("99:26_Fremd.pdf")
        TestPDF.make(pages: [["x"]], at: f)
        let i = ScriptedInteraction()
        let out = await makeProcessor(i).process(files: [f])
        XCTAssertFalse(out[0].success)
        XCTAssertTrue(out[0].details[0].contains("Keine Akte"), out[0].details[0])

        try FileManager.default.createDirectory(at: root.appendingPathComponent("99:26 - Fremd/01_Akte"), withIntermediateDirectories: true)
        let out2 = await makeProcessor(ScriptedInteraction()).process(files: [f])
        XCTAssertFalse(out2[0].success)
        XCTAssertTrue(out2[0].details[0].contains("01_Gesamtakte"), out2[0].details[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testCancelAndSkip() async throws {
        let f = inbox.appendingPathComponent("Unbekannt.pdf")
        TestPDF.make(pages: [["x"]], at: f)
        let i = ScriptedInteraction()
        i.aktenzeichenAnswer = .skipFile
        let out = await makeProcessor(i).process(files: [f])
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].success)
        XCTAssertTrue(out[0].title.contains("übersprungen"))

        let i2 = ScriptedInteraction()
        i2.aktenzeichenAnswer = .cancelAll
        let out2 = await makeProcessor(i2).process(files: [f])
        XCTAssertTrue(out2.last!.title.contains("abgebrochen"))

        // Plan abgelehnt → nichts geändert
        let g = inbox.appendingPathComponent("34:26_Test.pdf")
        TestPDF.make(pages: [["Berlin, den 01.01.2025"]], at: g)
        let i3 = ScriptedInteraction()
        i3.decision = .cancel
        let out3 = await makeProcessor(i3).process(files: [g])
        XCTAssertFalse(out3[0].success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Gesamtakte.pdf").path))
    }

    func testImageInput() async throws {
        let img = TestPDF.image(lines: ["Kanzlei", "Hamburg, den 02.02.2025", "Scan"], width: 1200, height: 1600)
        let imgURL = inbox.appendingPathComponent("34:26_Scan.png")
        let dest = CGImageDestinationCreateWithURL(imgURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        settings.makeSearchable = true
        let i = ScriptedInteraction()
        let out = await makeProcessor(i).process(files: [imgURL])
        XCTAssertTrue(out[0].success, out[0].details.joined(separator: "\n"))
        let gesamt = PDFDocument(url: target.appendingPathComponent("Gesamtakte.pdf"))!
        XCTAssertEqual(gesamt.pageCount, 1)
        XCTAssertTrue((gesamt.page(at: 0)?.string ?? "").contains("Hamburg"))
        XCTAssertEqual(i.plans[0].orderedDocuments[0].date?.iso, "2025-02-02")
    }
}
