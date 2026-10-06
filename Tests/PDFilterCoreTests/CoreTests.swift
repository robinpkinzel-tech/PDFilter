import XCTest
import PDFKit
@testable import PDFilterCore
import PDFilterParsing

final class CoreTests: XCTestCase {
    func testTextLayerAndDate() {
        let doc = TestPDF.makeDocument(pages: [["Rechtsanwalt Mustermann", "Berlin, den 01.12.2024", "Sehr geehrte Damen und Herren,", "Ihr Schreiben vom 15.11.2024 haben wir erhalten."]])
        let page = doc.page(at: 0)!
        XCTAssertTrue(PDFTextLayer.hasUsableText(page))
        let text = DocumentTextExtractor().text(for: page, allowOCR: false)
        XCTAssertFalse(text.usedOCR)
        XCTAssertTrue(text.fullText.contains("01.12.2024"))
        let decision = TextDateFinder.decide(lines: text.lines)
        XCTAssertEqual(decision.date?.iso, "2024-12-01")
    }

    func testAkteLocatorAndTarget() throws {
        let root = makeTempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("34:26 - Kinzel ./. Robin/01_Akte/01_Gesamtakte"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("35:26 - Müller ./. Meier/01_Akte"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Archiv/12:20 - Alt/01_Akte/01_Gesamtakte"), withIntermediateDirectories: true)
        var settings = Settings(rootFolderPath: root.path)
        let locator = AkteLocator(settings: settings)
        let az = Aktenzeichen(number: 34, year: 26)!
        let found = try locator.findAkteFolders(for: az)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "34:26 - Kinzel ./. Robin")
        let target = try locator.targetFolder(in: found[0])
        XCTAssertEqual(target.lastPathComponent, "01_Gesamtakte")

        // Fehlende Struktur wird klar gemeldet
        let az35 = Aktenzeichen(number: 35, year: 26)!
        let f35 = try locator.findAkteFolders(for: az35)
        XCTAssertThrowsError(try locator.targetFolder(in: f35[0])) { error in
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("01_Gesamtakte"), msg)
            XCTAssertTrue(msg.contains("01_Akte"), msg)
        }

        // Archiv nur mit Unterordnersuche
        let az12 = Aktenzeichen(number: 12, year: 20)!
        XCTAssertTrue(try locator.findAkteFolders(for: az12).isEmpty)
        settings.searchSubfolders = true
        XCTAssertEqual(try AkteLocator(settings: settings).findAkteFolders(for: az12).count, 1)

        XCTAssertTrue(locator.knownAktenzeichen().contains(az))
        XCTAssertThrowsError(try AkteLocator(settings: Settings(rootFolderPath: root.appendingPathComponent("gibtsnicht").path)).candidateFolders())
    }

    func testTargetAnalyzer() throws {
        let folder = makeTempDir()
        let settings = Settings()
        let az = Aktenzeichen(number: 34, year: 26)!
        XCTAssertEqual(TargetFolderAnalyzer.analyze(folder: folder, settings: settings, az: az), .empty)

        TestPDF.make(pages: [["Seite 1"]], at: folder.appendingPathComponent("Akte.pdf"))
        XCTAssertEqual(TargetFolderAnalyzer.analyze(folder: folder, settings: settings, az: az), .gesamtakte(folder.appendingPathComponent("Akte.pdf")))

        TestPDF.make(pages: [["Seite 1"]], at: folder.appendingPathComponent("02_Antrag.pdf"))
        if case .gesamtakteWithSingles(let g, let singles) = TargetFolderAnalyzer.analyze(folder: folder, settings: settings, az: az) {
            XCTAssertEqual(g.lastPathComponent, "Akte.pdf")
            XCTAssertEqual(singles.map(\.lastPathComponent), ["02_Antrag.pdf"])
        } else {
            XCTFail("Erwartet: Gesamtakte mit Einzeldateien")
        }

        try FileManager.default.removeItem(at: folder.appendingPathComponent("Akte.pdf"))
        TestPDF.make(pages: [["Seite 1"]], at: folder.appendingPathComponent("01_Anschreiben.pdf"))
        if case .singles(let files) = TargetFolderAnalyzer.analyze(folder: folder, settings: settings, az: az) {
            XCTAssertEqual(files.count, 2)
        } else {
            XCTFail("Erwartet: Einzeldateien")
        }

        TestPDF.make(pages: [["Seite 1"]], at: folder.appendingPathComponent("Gesamtakte.pdf"))
        TestPDF.make(pages: [["Seite 1"]], at: folder.appendingPathComponent("gesamakte alt.pdf"))
        if case .ambiguous(let candidates, let all) = TargetFolderAnalyzer.analyze(folder: folder, settings: settings, az: az) {
            XCTAssertEqual(candidates.count, 2)
            XCTAssertEqual(all.count, 4)
        } else {
            XCTFail("Erwartet: mehrdeutig")
        }
    }

    func testMergeOutlineRoundtripAndInsert() throws {
        let dir = makeTempDir()
        let a = TestPDF.makeDocument(pages: [["A1"], ["A2"]])
        let b = TestPDF.makeDocument(pages: [["B1"]])
        let d1 = DayDate(year: 2024, month: 11, day: 1)!
        let d2 = DayDate(year: 2024, month: 12, day: 1)!
        let merged = PDFAssembler.merge([(a, GesamtakteOutline.title(date: d1, name: "Anschreiben")), (b, GesamtakteOutline.title(date: d2, name: "Antrag"))])
        XCTAssertEqual(merged.pageCount, 3)
        let url = dir.appendingPathComponent("Gesamtakte.pdf")
        try SafeFileWriter.write(merged, to: url)

        let reloaded = PDFDocument(url: url)!
        let entries = GesamtakteOutline.entries(of: reloaded)
        XCTAssertEqual(entries.map(\.pageIndex), [0, 2])
        XCTAssertEqual(entries.map { $0.date?.iso }, ["2024-11-01", "2024-12-01"])

        // Seitendaten aus Lesezeichen, dann Einfügen in der Mitte
        let indexer = GesamtakteIndexer(extractor: DocumentTextExtractor(), cache: nil)
        let info = indexer.pageDates(of: reloaded, at: url, maxOCRPages: 10)
        XCTAssertEqual(info.dates.map { $0?.iso }, ["2024-11-01", nil, "2024-12-01"])
        let newDate = DayDate(year: 2024, month: 11, day: 15)!
        let decision = InsertionPlanner.insertionIndex(pageDates: info.dates, newDate: newDate)
        XCTAssertEqual(decision.pageIndex, 2)
        XCTAssertTrue(decision.isCertain)

        let c = TestPDF.makeDocument(pages: [["C1"], ["C2"]])
        PDFAssembler.insert(c, into: reloaded, at: decision.pageIndex, outlineTitle: GesamtakteOutline.title(date: newDate, name: "Mitte"))
        XCTAssertEqual(reloaded.pageCount, 5)
        try SafeFileWriter.write(reloaded, to: url, expectedPageCount: 5)
        let again = PDFDocument(url: url)!
        XCTAssertEqual(again.pageCount, 5)
        XCTAssertEqual(again.page(at: 2)?.string?.contains("C1"), true)
        XCTAssertEqual(again.page(at: 4)?.string?.contains("B1"), true)
        let entries2 = GesamtakteOutline.entries(of: again)
        XCTAssertEqual(entries2.map(\.pageIndex), [0, 2, 4])
        XCTAssertEqual(entries2[1].title, "15.11.2024 – Mitte")
    }

    func testBackupPrune() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("Gesamtakte.pdf")
        TestPDF.make(pages: [["x"]], at: file)
        let manager = BackupManager(root: dir.appendingPathComponent("Sicherungen"))
        let az = Aktenzeichen(number: 34, year: 26)!
        for _ in 0..<7 {
            try manager.backup(file, for: az, keep: 5)
        }
        XCTAssertEqual(manager.backups(for: az).count, 5)
    }

    func testSafeWriterUnique() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("Test.pdf")
        TestPDF.make(pages: [["x"]], at: url)
        XCTAssertEqual(SafeFileWriter.uniqueURL(url).lastPathComponent, "Test (2).pdf")
    }

    func testSettingsRoundtrip() throws {
        let dir = makeTempDir()
        var s = Settings()
        s.pathTemplate = "01_Akte/01_Gesamtakte"
        s.noConfirmAkten = ["34/26"]
        s.backupCount = 3
        try s.save(to: dir.appendingPathComponent("settings.json"))
        let loaded = Settings.load(from: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(loaded, s)
        XCTAssertEqual(loaded.templateComponents, ["01_Akte", "01_Gesamtakte"])
        XCTAssertEqual(loaded.gesamtakteName(for: Aktenzeichen(number: 34, year: 26)!), "Gesamtakte.pdf")
        var s2 = s
        s2.gesamtakteFileName = "{AZ}_Gesamtakte"
        XCTAssertEqual(s2.gesamtakteName(for: Aktenzeichen(number: 34, year: 26)!), "34:26_Gesamtakte.pdf")
        // Alte Datei ohne neue Schlüssel
        let partial = #"{"pathTemplate":"Akte"}"#.data(using: .utf8)!
        try partial.write(to: dir.appendingPathComponent("alt.json"))
        let p = Settings.load(from: dir.appendingPathComponent("alt.json"))
        XCTAssertEqual(p.pathTemplate, "Akte")
        XCTAssertEqual(p.backupCount, 5)
    }
}
