// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeratoPreview",
    // ScreenCaptureKit (SCScreenshotManager) richiede macOS 14.
    platforms: [.macOS(.v14)],
    targets: [
        // Lettura in sola lettura della libreria di Serato DJ Pro 5 (SQLite) e abbinamento testo → traccia.
        .target(
            name: "SeratoLibrary",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Intercettazione del clic, cattura della riga, OCR e impostazioni.
        .target(
            name: "SeratoPreviewCore",
            dependencies: ["SeratoLibrary"]
        ),
        // Fase 2: carica l'indice e stampa statistiche, campioni e tempi.
        .executableTarget(
            name: "library-dump",
            dependencies: ["SeratoLibrary"]
        ),
        // Fase 3: ⌥+clic nel browser di Serato → log della traccia riconosciuta.
        .executableTarget(
            name: "click-identify",
            dependencies: ["SeratoLibrary", "SeratoPreviewCore"]
        ),
    ]
)
