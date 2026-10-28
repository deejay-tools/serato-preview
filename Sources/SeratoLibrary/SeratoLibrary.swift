import Foundation

// Libreria di Serato DJ Pro 5:
// - ~/Library/Application Support/Serato/Library/master.sqlite contiene tutte le tracce (tabella `asset`)
//   con un percorso relativo (`portable_id`) e una `location`.
// - Ogni location ha un UUID: quello di root.sqlite (disco interno, radice "/") oppure quello di
//   <volume>/_Serato_/Library/location.sqlite (disco esterno, radice = volume).
// - Le tracce in streaming hanno portable_id "streaming://…".
//
// Nessun file di Serato viene mai aperto in scrittura: master.sqlite (in modalità WAL e scritto da
// Serato mentre è aperto) viene copiato in una cartella temporanea e letto dalla copia; gli altri
// database vengono aperti in modalità immutable, che non prende lock né crea file.

public struct Track: Sendable {
    public enum Source: Sendable {
        case file(path: String)
        case streaming(uri: String)
        /// La location non corrisponde a nessun disco collegato.
        case unresolved(locationID: Int64, portableID: String)
    }

    public let id: Int64
    public let title: String
    public let artist: String
    public let album: String
    public let bpm: Double?
    public let key: String
    public let lengthMs: Int64?
    public let source: Source
    /// Serato segnala il file come mancante.
    public let isMissing: Bool

    public var path: String? {
        if case .file(let path) = source { return path }
        return nil
    }
}

public struct LibraryLocation: Sendable {
    public let id: Int64
    public let uuid: Data?
    /// Cartella radice a cui sono relativi i percorsi, nil se il disco non è collegato.
    public let root: String?
}

public struct LibraryIndex: Sendable {
    public let tracks: [Track]
    public let locations: [LibraryLocation]
    public let snapshotDuration: TimeInterval
    public let queryDuration: TimeInterval
}

public enum LibraryError: Error, CustomStringConvertible {
    case notFound(String)
    case unstableSnapshot
    case sqlite(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "File non trovato: \(path)"
        case .unstableSnapshot: return "Serato sta scrivendo la libreria: copia non stabile dopo vari tentativi."
        case .sqlite(let message): return "SQLite: \(message)"
        }
    }
}

public struct SeratoLibraryReader {
    public var libraryFolder: URL
    public var volumesFolder: URL

    public init(
        libraryFolder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Serato/Library"),
        volumesFolder: URL = URL(fileURLWithPath: "/Volumes")
    ) {
        self.libraryFolder = libraryFolder
        self.volumesFolder = volumesFolder
    }

    public func load() throws -> LibraryIndex {
        let master = libraryFolder.appendingPathComponent("master.sqlite")
        guard FileManager.default.fileExists(atPath: master.path) else { throw LibraryError.notFound(master.path) }

        let snapshotStart = Date()
        let copy = try snapshot(of: master)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let snapshotDuration = Date().timeIntervalSince(snapshotStart)

        let queryStart = Date()
        let database = try SQLiteDatabase(url: copy)
        let locations = try resolveLocations(in: database)
        let roots = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.root) })

        var tracks: [Track] = []
        try database.query("""
            SELECT id, location_id, portable_id, name, artist, album, bpm, key, length_ms, is_missing
            FROM asset
            """) { row in
            let locationID = row.int(1) ?? -1
            let portableID = row.text(2)
            let source: Track.Source
            if portableID.hasPrefix("streaming://") {
                source = .streaming(uri: portableID)
            } else if let root = roots[locationID] ?? nil {
                source = .file(path: root == "/" ? "/" + portableID : root + "/" + portableID)
            } else {
                source = .unresolved(locationID: locationID, portableID: portableID)
            }
            tracks.append(Track(
                id: row.int(0) ?? -1,
                title: row.text(3),
                artist: row.text(4),
                album: row.text(5),
                bpm: row.double(6),
                key: row.text(7),
                lengthMs: row.int(8),
                source: source,
                isMissing: (row.int(9) ?? 0) != 0
            ))
        }

        return LibraryIndex(
            tracks: tracks,
            locations: locations,
            snapshotDuration: snapshotDuration,
            queryDuration: Date().timeIntervalSince(queryStart)
        )
    }

    // MARK: - Copia coerente di master.sqlite

    /// Copia database e WAL in una cartella temporanea. Se Serato modifica i file durante la copia
    /// (dimensione o data cambiate), riprova.
    private func snapshot(of database: URL) throws -> URL {
        let fileManager = FileManager.default
        let wal = URL(fileURLWithPath: database.path + "-wal")

        for _ in 0..<5 {
            let folder = fileManager.temporaryDirectory.appendingPathComponent("SeratoPreview-\(UUID().uuidString)")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(database.lastPathComponent)

            let before = fingerprint(database, wal)
            try fileManager.copyItem(at: database, to: copy)
            if fileManager.fileExists(atPath: wal.path) {
                try fileManager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            if fingerprint(database, wal) == before { return copy }

            try? fileManager.removeItem(at: folder)
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LibraryError.unstableSnapshot
    }

    private func fingerprint(_ urls: URL...) -> [String] {
        urls.map { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
            let size = attributes[.size] as? Int64 ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size)@\(modified)"
        }
    }

    // MARK: - Location → cartella radice

    private func resolveLocations(in database: SQLiteDatabase) throws -> [LibraryLocation] {
        var rootsByUUID: [Data: String] = [:]
        if let uuid = databaseUUID(at: libraryFolder.appendingPathComponent("root.sqlite")) {
            rootsByUUID[uuid] = "/"
        }
        let volumes = (try? FileManager.default.contentsOfDirectory(at: volumesFolder, includingPropertiesForKeys: nil)) ?? []
        for volume in volumes {
            let file = volume.appendingPathComponent("_Serato_/Library/location.sqlite")
            if let uuid = databaseUUID(at: file), rootsByUUID[uuid] == nil {
                rootsByUUID[uuid] = volume.path
            }
        }

        var locations: [LibraryLocation] = []
        try database.query("SELECT id, uuid FROM location") { row in
            let uuid = row.blob(1)
            locations.append(LibraryLocation(id: row.int(0) ?? -1, uuid: uuid, root: uuid.flatMap { rootsByUUID[$0] }))
        }
        return locations
    }

    private func databaseUUID(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? SQLiteDatabase(url: url, immutable: true) else { return nil }
        var uuid: Data?
        try? database.query("SELECT uuid FROM serato_db LIMIT 1") { uuid = $0.blob(0) }
        return uuid
    }
}
