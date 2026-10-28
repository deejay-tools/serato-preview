import Foundation
import SQLite3

/// Wrapper minimo su SQLite: apre un file e itera i risultati di una query.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Apre un database. Con `immutable` SQLite non prende lock, non legge il WAL
    /// e non crea file accanto al database: è il modo più sicuro per leggere un file di Serato.
    init(url: URL, immutable: Bool = false) throws {
        let flags: Int32
        let location: String
        if immutable {
            var components = URLComponents()
            components.scheme = "file"
            components.host = ""
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            location = components.string ?? url.path
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            location = url.path
            flags = SQLITE_OPEN_READWRITE
        }
        guard sqlite3_open_v2(location, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "errore sconosciuto"
            sqlite3_close(handle)
            throw LibraryError.sqlite("\(url.lastPathComponent): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String, row: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let statement else {
                throw LibraryError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
            try row(SQLiteRow(statement: statement))
        }
    }
}

struct SQLiteRow {
    let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }

    func double(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
