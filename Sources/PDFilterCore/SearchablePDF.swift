import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import PDFilterParsing

/// Erzeugt durchsuchbare PDFs: unsichtbare OCR-Textebene über Scans, Bilder → PDF.
public enum SearchablePDFWriter {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// Ergebnis: neues Dokument und Anzahl der Seiten, die eine Textebene erhalten haben.
    public struct Result {
        public let document: PDFDocument
        public let ocrPages: Int
    }

    /// Versieht Seiten ohne Textebene mit unsichtbarem OCR-Text. Seiten mit Text bleiben unverändert.
    public static func makeSearchable(_ document: PDFDocument, ocr: OCRService, dpi: CGFloat = 300,
                                      progress: ((Int, Int) -> Void)? = nil) -> Result {
        let count = document.pageCount
        var needsOCR: [Int] = []
        for i in 0..<count {
            if let page = document.page(at: i), !PDFTextLayer.hasUsableText(page) { needsOCR.append(i) }
        }
        guard !needsOCR.isEmpty else { return Result(document: document, ocrPages: 0) }

        let result = PDFDocument()
        var done = 0
        for i in 0..<count {
            guard let page = document.page(at: i) else { continue }
            if needsOCR.contains(i), let newPage = ocrPage(page, ocr: ocr, dpi: dpi) {
                result.insert(newPage, at: result.pageCount)
                done += 1
                progress?(done, needsOCR.count)
            } else {
                result.insert((page.copy() as? PDFPage) ?? page, at: result.pageCount)
            }
        }
        // Lesezeichen des Originals übernehmen (sofern vorhanden) – Seitenzahl ist identisch.
        if let root = document.outlineRoot {
            let newRoot = PDFOutline()
            copyOutline(from: root, to: newRoot, source: document, target: result)
            if newRoot.numberOfChildren > 0 { result.outlineRoot = newRoot }
        }
        return Result(document: result, ocrPages: done)
    }

    static func copyOutline(from: PDFOutline, to: PDFOutline, source: PDFDocument, target: PDFDocument) {
        for i in 0..<from.numberOfChildren {
            guard let child = from.child(at: i) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            if let page = child.destination?.page {
                let idx = source.index(for: page)
                if idx >= 0, idx < target.pageCount, let tp = target.page(at: idx) {
                    copy.destination = PDFDestination(page: tp, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue))
                }
            }
            to.insertChild(copy, at: to.numberOfChildren)
            copyOutline(from: child, to: copy, source: source, target: target)
        }
    }

    /// Rendert eine Seite, erkennt den Text und baut eine neue Seite mit unsichtbarer Textebene.
    static func ocrPage(_ page: PDFPage, ocr: OCRService, dpi: CGFloat) -> PDFPage? {
        guard let cgPage = page.pageRef, let image = PDFPageRenderer.render(page, dpi: dpi) else { return nil }
        let lines = (try? ocr.recognize(image)) ?? []
        let size = PDFPageRenderer.displayedSize(of: page)
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
        drawInvisibleText(lines, in: ctx, pageRect: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let newPage = doc.page(at: 0) else { return nil }
        return newPage
    }

    /// Zeichnet OCR-Zeilen unsichtbar (Textmodus »invisible«) an ihre Position.
    static func drawInvisibleText(_ lines: [OCRLine], in ctx: CGContext, pageRect: CGRect) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: pageRect.minX + line.box.minX * pageRect.width,
                             y: pageRect.minY + line.box.minY * pageRect.height,
                             width: line.box.width * pageRect.width,
                             height: line.box.height * pageRect.height)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            let fontSize = max(2, box.height * 0.85)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let attributed = NSAttributedString(string: line.text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY + descent * 0.5)
            ctx.scaleBy(x: box.width / width, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Lädt ein Bild (JPG, PNG, HEIC, TIFF …) mit korrekter Ausrichtung.
    public static func loadImage(_ url: URL, maxPixel: Int = 4000) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Wandelt ein Bild in eine einseitige PDF (A4-Format, Bild eingepasst) mit OCR-Textebene um.
    public static func pdf(fromImage url: URL, ocr: OCRService?) -> PDFDocument? {
        guard let image = loadImage(url) else { return nil }
        return pdf(fromImage: image, ocr: ocr)
    }

    public static func pdf(fromImage image: CGImage, ocr: OCRService?) -> PDFDocument? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        let a4 = CGSize(width: 595.28, height: 841.89)
        let pageSize = w > h ? CGSize(width: a4.height, height: a4.width) : a4
        let scale = min(pageSize.width / w, pageSize.height / h)
        let drawSize = CGSize(width: w * scale, height: h * scale)
        let drawRect = CGRect(x: (pageSize.width - drawSize.width) / 2, y: (pageSize.height - drawSize.height) / 2,
                              width: drawSize.width, height: drawSize.height)
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(mediaBox)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        if let ocr, let lines = try? ocr.recognize(image) {
            drawInvisibleText(lines, in: ctx, pageRect: drawRect)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }
}
