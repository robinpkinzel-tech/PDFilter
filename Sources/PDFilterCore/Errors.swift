import Foundation
import PDFilterParsing

public enum PDFilterError: LocalizedError {
    case unsupportedFile(URL)
    case cannotOpenPDF(URL)
    case imageConversionFailed(URL)
    case rootFolderMissing(URL)
    case noAkteFound(Aktenzeichen, root: URL)
    case targetFolderMissing(akte: URL, template: String, missingComponent: String, existing: [String])
    case writeFailed(URL)
    case verificationFailed(URL)
    case fileExists(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "»\(url.lastPathComponent)« ist weder PDF noch ein unterstütztes Bildformat (JPG, PNG, HEIC, TIFF)."
        case .cannotOpenPDF(let url):
            return "Die PDF »\(url.lastPathComponent)« konnte nicht geöffnet werden (beschädigt oder passwortgeschützt?)."
        case .imageConversionFailed(let url):
            return "Das Bild »\(url.lastPathComponent)« konnte nicht in eine PDF umgewandelt werden."
        case .rootFolderMissing(let url):
            return "Der Wurzelordner »\(url.path)« existiert nicht oder ist nicht lesbar."
        case .noAkteFound(let az, let root):
            return "Keine Akte mit dem Aktenzeichen \(az.display) in »\(root.path)« gefunden. Erwartet wird ein Ordner, dessen Name das Aktenzeichen enthält (z. B. »\(az.display) - Mandant ./. Gegner«)."
        case .targetFolderMissing(let akte, let template, let missing, let existing):
            let list = existing.isEmpty ? "keine Unterordner" : existing.map { "»\($0)«" }.joined(separator: ", ")
            return "Die Ordnerstruktur der Akte »\(akte.lastPathComponent)« passt nicht zum Muster »\(template)«: Der Unterordner »\(missing)« fehlt. Vorhanden: \(list). Es wurde nichts verändert."
        case .writeFailed(let url):
            return "Die Datei »\(url.lastPathComponent)« konnte nicht geschrieben werden."
        case .verificationFailed(let url):
            return "Die geschriebene Datei »\(url.lastPathComponent)« ließ sich nicht fehlerfrei zurücklesen. Die Akte wurde nicht verändert."
        case .fileExists(let url):
            return "Die Datei »\(url.lastPathComponent)« existiert bereits."
        case .cancelled:
            return "Abgebrochen."
        }
    }
}
