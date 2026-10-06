import Foundation
import PDFKit
import CoreText
import XCTest
@testable import PDFilterCore
import PDFilterParsing

enum TestPDF {
    /// Erzeugt eine PDF mit sichtbarem Text (Textebene vorhanden). Jede innere Liste = eine Seite.
    static func make(pages: [[String]], at url: URL) {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fatalError("PDF-Kontext") }
        for lines in pages {
            ctx.beginPDFPage(nil)
            drawLines(lines, in: ctx, startY: 780)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func makeDocument(pages: [[String]]) -> PDFDocument {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        make(pages: pages, at: tmp)
        let doc = PDFDocument(url: tmp)!
        return doc
    }

    static func drawLines(_ lines: [String], in ctx: CGContext, startY: CGFloat, fontSize: CGFloat = 14) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var y = startY
        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(ctLine, ctx)
            y -= fontSize * 1.6
        }
    }

    /// Bitmap mit gezeichnetem Text (für OCR-Tests).
    static func image(lines: [String], width: Int = 1700, height: Int = 2400) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        var y = CGFloat(height) - 200
        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 150, y: y)
            CTLineDraw(ctLine, ctx)
            y -= 90
        }
        return ctx.makeImage()!
    }

    /// Scan-PDF ohne Textebene (nur Bild).
    static func makeScan(lines: [String], at url: URL) {
        let img = image(lines: lines)
        let doc = SearchablePDFWriter.pdf(fromImage: img, ocr: nil)!
        XCTAssertTrue(doc.write(to: url))
    }
}

func makeTempDir(_ name: String = "PDFilterTest") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Vorgegebene Antworten für Tests.
final class ScriptedInteraction: UserInteraction {
    var aktenzeichenAnswer: AktenzeichenAnswer = .skipFile
    var dateAnswer: DateAnswer = .noDate
    var folderChoice: ((Aktenzeichen, [URL]) -> URL?) = { _, c in c.first }
    var gesamtakteChoice: GesamtakteChoice = .treatAllAsSingles
    var decision: PlanDecision = .proceed
    var plans: [ProcessingPlan] = []
    var askedAktenzeichen: [String] = []
    var askedDates: [String] = []
    var statuses: [String] = []

    @MainActor func askAktenzeichen(fileName: String, suggestions: [Aktenzeichen], preview: CGImage?) async -> AktenzeichenAnswer {
        askedAktenzeichen.append(fileName)
        return aktenzeichenAnswer
    }
    @MainActor func chooseAkteFolder(for az: Aktenzeichen, candidates: [URL]) async -> URL? { folderChoice(az, candidates) }
    @MainActor func askDate(fileName: String, candidates: [DateCandidate], preview: CGImage?) async -> DateAnswer {
        askedDates.append(fileName)
        return dateAnswer
    }
    @MainActor func chooseGesamtakte(in folder: URL, candidates: [URL], all: [URL]) async -> GesamtakteChoice { gesamtakteChoice }
    @MainActor func confirm(plan: ProcessingPlan) async -> PlanDecision {
        plans.append(plan)
        return decision
    }
    @MainActor func progress(_ message: String) {}
    @MainActor func fileStatus(_ url: URL, _ status: String) { statuses.append("\(url.lastPathComponent): \(status)") }
}
