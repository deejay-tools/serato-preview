// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeratoPreview",
    platforms: [.macOS(.v13)],
    targets: [
        // Lettura in sola lettura della libreria di Serato DJ Pro 5 (SQLite).
        .target(
            name: "SeratoLibrary",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Fase 2: carica l'indice e stampa statistiche, campioni e tempi.
        .executableTarget(
            name: "library-dump",
            dependencies: ["SeratoLibrary"]
        ),
    ]
)
