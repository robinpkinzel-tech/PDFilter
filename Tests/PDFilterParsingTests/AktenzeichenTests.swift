import XCTest
@testable import PDFilterParsing

final class AktenzeichenTests: XCTestCase {
    let ref = 2026

    func testParseInput() {
        XCTAssertEqual(Aktenzeichen.parse("34/26")?.display, "34/26")
        XCTAssertEqual(Aktenzeichen.parse(" 34 / 2026 ")?.display, "34/26")
        XCTAssertEqual(Aktenzeichen.parse("34-26")?.display, "34/26")
        XCTAssertEqual(Aktenzeichen.parse("7:26")?.display, "7/26")
        XCTAssertNil(Aktenzeichen.parse("3426"))
        XCTAssertNil(Aktenzeichen.parse("abc"))
        XCTAssertNil(Aktenzeichen.parse(""))
    }

    func testFileSystemString() {
        let az = Aktenzeichen(number: 34, year: 26)!
        XCTAssertEqual(az.fileSystemString(visibleSeparator: "/"), "34:26")
        XCTAssertEqual(az.fileSystemString(visibleSeparator: "-"), "34-26")
        XCTAssertEqual(az.fileSystemString(visibleSeparator: "_"), "34_26")
        XCTAssertEqual(az.display, "34/26")
        XCTAssertEqual(Aktenzeichen(number: 3, year: 2026)?.display, "3/26")
    }

    func testFileNameDetection() {
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFileName: "34:26_Anschreiben.pdf", referenceYear: ref)?.display, "34/26")
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFileName: "34-26 Anschreiben.pdf", referenceYear: ref)?.display, "34/26")
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFileName: "Schreiben 12_25.pdf", referenceYear: ref)?.display, "12/25")
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFileName: "34:26_2024-12-01_Anschreiben.pdf", referenceYear: ref)?.display, "34/26")
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFileName: "2024-12-01_34-26_Anschreiben.pdf", referenceYear: ref)?.display, "34/26")
        // Datumsangaben sind keine Aktenzeichen
        XCTAssertNil(AktenzeichenFinder.aktenzeichen(inFileName: "2024-12-01_Anschreiben.pdf", referenceYear: ref))
        XCTAssertNil(AktenzeichenFinder.aktenzeichen(inFileName: "Anschreiben 01.12.2024.pdf", referenceYear: ref))
        XCTAssertNil(AktenzeichenFinder.aktenzeichen(inFileName: "Scan 2025-01-05.pdf", referenceYear: ref))
        XCTAssertNil(AktenzeichenFinder.aktenzeichen(inFileName: "Anschreiben.pdf", referenceYear: ref))
        // Unplausibles Jahr
        XCTAssertNil(AktenzeichenFinder.aktenzeichen(inFileName: "Rechnung 12-45.pdf", referenceYear: ref))
    }

    func testFolderMatching() {
        let az = Aktenzeichen(number: 34, year: 26)!
        XCTAssertTrue(AktenzeichenFinder.folderNameMatches("34:26 - Kinzel ./. Robin", az, referenceYear: ref))
        XCTAssertTrue(AktenzeichenFinder.folderNameMatches("34-26 - Kinzel ./. Robin", az, referenceYear: ref))
        XCTAssertTrue(AktenzeichenFinder.folderNameMatches("34_26 Kinzel", az, referenceYear: ref))
        XCTAssertTrue(AktenzeichenFinder.folderNameMatches("34/2026 Kinzel", az, referenceYear: ref))
        XCTAssertTrue(AktenzeichenFinder.folderNameMatches("Kinzel ./. Robin (34/26)", az, referenceYear: ref))
        XCTAssertFalse(AktenzeichenFinder.folderNameMatches("35:26 - Müller ./. Meier", az, referenceYear: ref))
        XCTAssertFalse(AktenzeichenFinder.folderNameMatches("34:25 - Müller ./. Meier", az, referenceYear: ref))
        XCTAssertFalse(AktenzeichenFinder.folderNameMatches("Archiv", az, referenceYear: ref))
        XCTAssertEqual(AktenzeichenFinder.aktenzeichen(inFolderName: "7:26 - Test", referenceYear: ref)?.display, "7/26")
    }

    func testTextSuggestions() {
        let text = """
        Rechtsanwalt Max Mustermann
        Unser Zeichen: 12 O 345/24      Ihr Zeichen: 34/26
        Berlin, den 01.12.2024
        """
        let known: Set<Aktenzeichen> = [Aktenzeichen(number: 34, year: 26)!]
        let ranked = AktenzeichenFinder.rankedSuggestions(from: text, knownAktenzeichen: known, referenceYear: ref)
        XCTAssertEqual(ranked.first?.display, "34/26")
        // Das gerichtliche Aktenzeichen wird abgewertet, taucht aber ggf. auf
        let rankedUnknown = AktenzeichenFinder.rankedSuggestions(from: text, knownAktenzeichen: [], referenceYear: ref)
        XCTAssertEqual(rankedUnknown.first?.display, "34/26")
    }

    func testCourtPrefixPenalty() {
        let c = AktenzeichenFinder.candidates(in: "Az.: 3 Ca 120/25", separators: "/", referenceYear: ref)
        XCTAssertEqual(c.count, 1)
        XCTAssertLessThan(c[0].score, 2)
        let d = AktenzeichenFinder.candidates(in: "Aktenzeichen: 120/25", separators: "/", referenceYear: ref)
        XCTAssertEqual(d.count, 1)
        XCTAssertGreaterThanOrEqual(d[0].score, 3)
    }
}
