import XCTest
@testable import PDFilterParsing

final class OrderingTests: XCTestCase {
    func d(_ s: String) -> DayDate { DayDate.parse(s, referenceYear: 2026)! }

    func doc(_ name: String, number: Int? = nil, date: String? = nil, incoming: Bool = false) -> DocumentDescriptor {
        DocumentDescriptor(id: name, fileName: name, number: number, date: date.map(d),
                           dateSource: date == nil ? .none : .fileName, dateConfidence: date == nil ? .none : .high,
                           isIncoming: incoming)
    }

    func testNumberedKeepOrderAndDatedInserted() {
        let docs = [
            doc("02_Antrag.pdf", number: 2, date: "2024-12-10"),
            doc("01_Anschreiben.pdf", number: 1, date: "2024-12-01"),
            doc("Neu.pdf", date: "2024-12-05", incoming: true),
            doc("03_Erwiderung.pdf", number: 3),
        ]
        let r = DocumentOrdering.order(docs)
        XCTAssertEqual(r.ordered.map(\.fileName), ["01_Anschreiben.pdf", "Neu.pdf", "02_Antrag.pdf", "03_Erwiderung.pdf"])
        XCTAssertFalse(r.isUncertain)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testOnlyDates() {
        let docs = [doc("b.pdf", date: "2025-01-03"), doc("a.pdf", date: "2024-12-30"), doc("c.pdf", date: "2025-01-03")]
        let r = DocumentOrdering.order(docs)
        XCTAssertEqual(r.ordered.map(\.fileName), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertFalse(r.isUncertain)
    }

    func testUndatedGoesToEndAndIsUncertain() {
        let docs = [doc("a.pdf", date: "2024-12-30"), doc("x.pdf"), doc("b.pdf", date: "2025-01-03")]
        let r = DocumentOrdering.order(docs)
        XCTAssertEqual(r.ordered.map(\.fileName), ["a.pdf", "b.pdf", "x.pdf"])
        XCTAssertTrue(r.isUncertain)
    }

    func testContradictionWarning() {
        let docs = [
            doc("01_a.pdf", number: 1, date: "2025-01-10"),
            doc("02_b.pdf", number: 2, date: "2025-01-05"),
            doc("neu.pdf", date: "2025-01-07", incoming: true),
        ]
        let r = DocumentOrdering.order(docs)
        XCTAssertEqual(r.ordered.map(\.fileName).prefix(2), ["01_a.pdf", "02_b.pdf"])
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertTrue(r.warnings[0].contains("Widerspruch"))
        XCTAssertTrue(r.isUncertain)
        XCTAssertEqual(r.ordered.last?.fileName, "neu.pdf")
    }

    func testNewestAppendsToEnd() {
        let docs = [doc("01_a.pdf", number: 1, date: "2025-01-10"), doc("neu.pdf", date: "2025-02-01", incoming: true)]
        let r = DocumentOrdering.order(docs)
        XCTAssertEqual(r.ordered.map(\.fileName), ["01_a.pdf", "neu.pdf"])
        XCTAssertFalse(r.isUncertain)
    }

    func testInsertionPlanner() {
        let dates: [DayDate?] = [d("2024-11-01"), nil, d("2024-12-01"), nil, nil, d("2025-01-15")]
        XCTAssertEqual(InsertionPlanner.insertionIndex(pageDates: dates, newDate: d("2024-12-05")).pageIndex, 5)
        XCTAssertEqual(InsertionPlanner.insertionIndex(pageDates: dates, newDate: d("2024-11-15")).pageIndex, 2)
        XCTAssertEqual(InsertionPlanner.insertionIndex(pageDates: dates, newDate: d("2024-10-01")).pageIndex, 0)
        let end = InsertionPlanner.insertionIndex(pageDates: dates, newDate: d("2025-03-01"))
        XCTAssertEqual(end.pageIndex, 6)
        XCTAssertTrue(end.isCertain)
        let sameDay = InsertionPlanner.insertionIndex(pageDates: dates, newDate: d("2024-12-01"))
        XCTAssertEqual(sameDay.pageIndex, 5)
        let noDate = InsertionPlanner.insertionIndex(pageDates: dates, newDate: nil)
        XCTAssertEqual(noDate.pageIndex, 6)
        XCTAssertFalse(noDate.isCertain)
        let unsorted = InsertionPlanner.insertionIndex(pageDates: [d("2025-01-01"), d("2024-01-01")], newDate: d("2024-06-01"))
        XCTAssertEqual(unsorted.pageIndex, 2)
        XCTAssertFalse(unsorted.isCertain)
        let empty = InsertionPlanner.insertionIndex(pageDates: [nil, nil], newDate: d("2024-06-01"))
        XCTAssertEqual(empty.pageIndex, 2)
        XCTAssertFalse(empty.isCertain)
    }
}
