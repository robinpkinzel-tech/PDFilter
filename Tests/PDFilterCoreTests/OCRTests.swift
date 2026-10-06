import XCTest
import PDFKit
@testable import PDFilterCore
import PDFilterParsing

final class OCRTests: XCTestCase {
    func testImageToSearchablePDF() throws {
        let image = TestPDF.image(lines: ["Rechtsanwalt Mustermann", "Berlin, den 01.12.2024", "Betreff: Klage"])
        let ocr = OCRService()
        guard let doc = SearchablePDFWriter.pdf(fromImage: image, ocr: ocr) else { return XCTFail("keine PDF") }
        XCTAssertEqual(doc.pageCount, 1)
        let text = doc.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Mustermann"), "Textebene fehlt: \(text)")
        XCTAssertTrue(text.contains("01.12.2024"), "Datum fehlt: \(text)")
        // Nach dem Schreiben/Lesen bleibt der Text erhalten
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("scan.pdf")
        try SafeFileWriter.write(doc, to: url)
        let reloaded = PDFDocument(url: url)!
        XCTAssertTrue((reloaded.page(at: 0)?.string ?? "").contains("Mustermann"))
        XCTAssertTrue(PDFTextLayer.hasUsableText(reloaded.page(at: 0)!))
    }

    func testScanDateViaOCR() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("scan.pdf")
        TestPDF.makeScan(lines: ["Amtsgericht Musterstadt", "Datum: 04.12.2024", "Beschluss"], at: url)
        let doc = PDFDocument(url: url)!
        XCTAssertFalse(PDFTextLayer.hasUsableText(doc.page(at: 0)!))
        let extractor = DocumentTextExtractor()
        let text = extractor.text(for: doc.page(at: 0)!)
        XCTAssertTrue(text.usedOCR)
        let decision = TextDateFinder.decide(lines: text.lines)
        XCTAssertEqual(decision.date?.iso, "2024-12-04", "Zeilen: \(text.lines)")

        // Durchsuchbar machen
        let result = SearchablePDFWriter.makeSearchable(doc, ocr: OCRService())
        XCTAssertEqual(result.ocrPages, 1)
        XCTAssertTrue((result.document.page(at: 0)?.string ?? "").contains("Musterstadt"))
    }
}
