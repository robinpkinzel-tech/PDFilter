// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PDFilter",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PDFilter", targets: ["PDFilter"]),
        .library(name: "PDFilterCore", targets: ["PDFilterCore"]),
        .library(name: "PDFilterParsing", targets: ["PDFilterParsing"]),
    ],
    targets: [
        // Reine Foundation-Logik (Aktenzeichen, Datum, Nummerierung, Sortierung) – ohne Apple-Frameworks.
        .target(name: "PDFilterParsing"),
        // macOS-spezifische Logik: PDFKit, Vision (OCR), Dateisystem, Ablaufsteuerung.
        .target(name: "PDFilterCore", dependencies: ["PDFilterParsing"]),
        // SwiftUI-App.
        .executableTarget(name: "PDFilter", dependencies: ["PDFilterCore", "PDFilterParsing"]),
        .testTarget(name: "PDFilterParsingTests", dependencies: ["PDFilterParsing"]),
        .testTarget(name: "PDFilterCoreTests", dependencies: ["PDFilterCore", "PDFilterParsing"]),
    ],
    swiftLanguageModes: [.v5]
)
