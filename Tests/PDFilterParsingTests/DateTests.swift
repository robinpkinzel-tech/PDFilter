import XCTest
@testable import PDFilterParsing

final class DateTests: XCTestCase {
    let ref = 2026
    let today = DayDate(year: 2026, month: 10, day: 6)!

    func testDayDate() {
        XCTAssertNil(DayDate(year: 2024, month: 2, day: 30))
        XCTAssertNotNil(DayDate(year: 2024, month: 2, day: 29))
        XCTAssertNil(DayDate(year: 2023, month: 2, day: 29))
        XCTAssertNil(DayDate(year: 2024, month: 13, day: 1))
        XCTAssertTrue(DayDate(year: 2024, month: 12, day: 1)! < DayDate(year: 2024, month: 12, day: 4)!)
        XCTAssertEqual(DayDate(year: 2024, month: 12, day: 1)!.german, "01.12.2024")
        XCTAssertEqual(DayDate(year: 2024, month: 12, day: 1)!.iso, "2024-12-01")
        XCTAssertEqual(DayDate.parse("1.12.2024", referenceYear: ref)?.iso, "2024-12-01")
        XCTAssertEqual(DayDate.parse("01.12.24", referenceYear: ref)?.iso, "2024-12-01")
        XCTAssertEqual(DayDate.parse("2024-12-01", referenceYear: ref)?.iso, "2024-12-01")
        XCTAssertNil(DayDate.parse("Dezember", referenceYear: ref))
    }

    func testFileNameDates() {
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "2024-12-01_Anschreiben.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "Anschreiben 01.12.2024.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "01.12.24 Anschreiben.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "241201_Anschreiben.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "20241201 Anschreiben.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertEqual(FileNameDateParser.firstDate(inFileName: "34:26_2024_12_01_Scan.pdf", referenceYear: ref)?.date.iso, "2024-12-01")
        XCTAssertNil(FileNameDateParser.firstDate(inFileName: "01_Anschreiben.pdf", referenceYear: ref))
        XCTAssertNil(FileNameDateParser.firstDate(inFileName: "34:26_Anschreiben.pdf", referenceYear: ref))
        XCTAssertNil(FileNameDateParser.firstDate(inFileName: "Rechnung 1234567.pdf", referenceYear: ref))
        // Ungültiges Datum
        XCTAssertNil(FileNameDateParser.firstDate(inFileName: "32.13.2024.pdf", referenceYear: ref))
        // Zukunft weit voraus
        XCTAssertNil(FileNameDateParser.firstDate(inFileName: "01.12.2031.pdf", referenceYear: ref))
    }

    func testLeadingNumber() {
        XCTAssertEqual(FileNaming.leadingNumber("01_Anschreiben"), 1)
        XCTAssertEqual(FileNaming.leadingNumber("02 Fristverlängerungsantrag"), 2)
        XCTAssertEqual(FileNaming.leadingNumber("3. Klageerwiderung"), 3)
        XCTAssertEqual(FileNaming.leadingNumber("34:26_05_Anlage"), 5)
        XCTAssertNil(FileNaming.leadingNumber("01.12.2024_Anschreiben"))
        XCTAssertNil(FileNaming.leadingNumber("2024-12-01_Anschreiben"))
        XCTAssertNil(FileNaming.leadingNumber("241201_Anschreiben"))
        XCTAssertNil(FileNaming.leadingNumber("Anschreiben"))
        XCTAssertNil(FileNaming.leadingNumber("34:26_Anschreiben"))
        XCTAssertEqual(FileNaming.displayName(forFileName: "34:26_02_Anschreiben.pdf"), "Anschreiben")
        XCTAssertEqual(FileNaming.displayName(forFileName: "02_Anschreiben.pdf"), "Anschreiben")
        XCTAssertEqual(FileNaming.displayName(forFileName: "Anschreiben.pdf"), "Anschreiben")
        XCTAssertEqual(FileNaming.stripLeadingNumber("02_Anschreiben"), "Anschreiben")
    }

    func testTextDateLetterHead() {
        let lines = [
            TextLine(text: "Rechtsanwälte Kinzel & Partner", isTop: true),
            TextLine(text: "Ihr Schreiben vom 15.11.2024", isTop: true),
            TextLine(text: "Berlin, den 01.12.2024", isTop: true),
            TextLine(text: "Sehr geehrte Damen und Herren,", isTop: false),
            TextLine(text: "wir bitten um Fristverlängerung bis zum 20.12.2024.", isTop: false),
        ]
        let d = TextDateFinder.decide(lines: lines, today: today, referenceYear: ref)
        XCTAssertEqual(d.date?.iso, "2024-12-01")
        XCTAssertEqual(d.confidence, .high)
    }

    func testTextDateWrittenMonth() {
        let lines = [
            TextLine(text: "Amtsgericht Musterstadt", isTop: true),
            TextLine(text: "Datum", isTop: true),
            TextLine(text: "4. Dezember 2024", isTop: true),
            TextLine(text: "Der Kläger wurde am 03.03.1980 geboren.", isTop: false),
        ]
        let d = TextDateFinder.decide(lines: lines, today: today, referenceYear: ref)
        XCTAssertEqual(d.date?.iso, "2024-12-04")
        XCTAssertNotEqual(d.confidence, .low)
    }

    func testTextDateAmbiguous() {
        let lines = [
            TextLine(text: "Termin am 01.02.2025 und am 03.02.2025", isTop: false),
        ]
        let d = TextDateFinder.decide(lines: lines, today: today, referenceYear: ref)
        XCTAssertNil(d.date)
        XCTAssertEqual(d.confidence, .low)
        XCTAssertEqual(d.candidates.count, 2)
    }

    func testTextDateNone() {
        let d = TextDateFinder.decide(lines: [TextLine(text: "Kein Datum hier", isTop: true)], today: today, referenceYear: ref)
        XCTAssertNil(d.date)
        XCTAssertEqual(d.confidence, .none)
    }

    func testIsoAndDotSpacing() {
        let lines = [TextLine(text: "Frankfurt (Oder), 2024-12-01", isTop: true)]
        XCTAssertEqual(TextDateFinder.decide(lines: lines, today: today, referenceYear: ref).date?.iso, "2024-12-01")
        let lines2 = [TextLine(text: "München, 1. 12. 2024", isTop: true)]
        XCTAssertEqual(TextDateFinder.decide(lines: lines2, today: today, referenceYear: ref).date?.iso, "2024-12-01")
    }
}
