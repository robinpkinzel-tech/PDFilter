import Foundation
import PDFKit
import Vision
import CoreGraphics
import PDFilterParsing

/// Text einer Seite mit Zeileninformation.
public struct PageText: Sendable {
    public let lines: [TextLine]
    public let fullText: String
    public let usedOCR: Bool

    public static let empty = PageText(lines: [], fullText: "", usedOCR: false)
}

/// Rendert PDF-Seiten als Bitmap (für OCR und Vorschau).
public enum PDFPageRenderer {
    public static func render(_ page: PDFPage, dpi: CGFloat = 200) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let box = cgPage.getBoxRect(.mediaBox)
        var width = box.width
        var height = box.height
        if cgPage.rotationAngle % 180 != 0 { swap(&width, &height) }
        let scale = dpi / 72.0
        let pxW = Int((width * scale).rounded())
        let pxH = Int((height * scale).rounded())
        guard pxW > 0, pxH > 0, pxW < 20000, pxH < 20000,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high
        let target = CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH))
        ctx.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }

    /// Seitengröße in Punkten, wie sie angezeigt wird (Rotation berücksichtigt).
    public static func displayedSize(of page: PDFPage) -> CGSize {
        guard let cgPage = page.pageRef else {
            let b = page.bounds(for: .mediaBox)
            return CGSize(width: b.width, height: b.height)
        }
        let box = cgPage.getBoxRect(.mediaBox)
        if cgPage.rotationAngle % 180 != 0 { return CGSize(width: box.height, height: box.width) }
        return CGSize(width: box.width, height: box.height)
    }
}

/// Liest die vorhandene Textebene einer Seite.
public enum PDFTextLayer {
    /// Mindestens 20 Buchstaben/Ziffern → brauchbare Textebene.
    public static func hasUsableText(_ page: PDFPage) -> Bool {
        let s = page.string ?? ""
        var count = 0
        for ch in s.unicodeScalars where CharacterSet.alphanumerics.contains(ch) {
            count += 1
            if count >= 20 { return true }
        }
        return false
    }

    public static func pageText(_ page: PDFPage, topFraction: CGFloat = 0.4) -> PageText {
        let full = page.string ?? ""
        let bounds = page.bounds(for: .mediaBox)
        let topRect = CGRect(x: bounds.minX, y: bounds.maxY - bounds.height * topFraction,
                             width: bounds.width, height: bounds.height * topFraction)
        let topString = page.selection(for: topRect)?.string ?? ""
        let topLines = Set(splitLines(topString))
        var lines = splitLines(full).map { TextLine(text: $0, isTop: topLines.contains($0)) }
        if topLines.isEmpty, !lines.isEmpty {
            // Rückfall: die ersten Zeilen als Kopfbereich werten.
            lines = lines.enumerated().map { TextLine(text: $0.element.text, isTop: $0.offset < 12) }
        }
        return PageText(lines: lines, fullText: full, usedOCR: false)
    }

    static func splitLines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Eine erkannte Textzeile mit normierter Box (Ursprung unten links, 0…1).
public struct OCRLine: Sendable {
    public let text: String
    public let box: CGRect
    public let confidence: Float
}

/// Texterkennung mit Apple Vision (auf dem Gerät, deutsch).
public final class OCRService: @unchecked Sendable {
    public let languages: [String]

    public init(languages: [String] = ["de-DE", "en-US"]) {
        self.languages = languages
    }

    public func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        let lines: [OCRLine] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, box: obs.boundingBox, confidence: candidate.confidence)
        }
        return lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.008 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
    }

    /// Zeilen als Seitentext; oberes 40 % der Seite gilt als Kopfbereich.
    public static func pageText(from lines: [OCRLine]) -> PageText {
        let textLines = lines.map { TextLine(text: $0.text, isTop: $0.box.minY > 0.6) }
        return PageText(lines: textLines, fullText: lines.map(\.text).joined(separator: "\n"), usedOCR: true)
    }
}

/// Liefert den Text einer Seite: Textebene, sonst OCR.
public final class DocumentTextExtractor: @unchecked Sendable {
    public let ocr: OCRService

    public init(ocr: OCRService = OCRService()) {
        self.ocr = ocr
    }

    public func text(for page: PDFPage, allowOCR: Bool = true, dpi: CGFloat = 200) -> PageText {
        if PDFTextLayer.hasUsableText(page) {
            return PDFTextLayer.pageText(page)
        }
        guard allowOCR, let image = PDFPageRenderer.render(page, dpi: dpi) else { return .empty }
        guard let lines = try? ocr.recognize(image) else { return .empty }
        return OCRService.pageText(from: lines)
    }

    /// Text der ersten Seite eines Dokuments.
    public func firstPageText(of document: PDFDocument, allowOCR: Bool = true) -> PageText {
        guard let page = document.page(at: 0) else { return .empty }
        return text(for: page, allowOCR: allowOCR)
    }
}
