import CoreGraphics
import Foundation

/// Impostazioni lette da ~/Library/Application Support/SeratoPreview/settings.json.
/// La geometria del browser sta qui e non nel codice: se Serato cambia layout basta modificare il file.
public struct PreviewSettings: Codable, Equatable {
    public struct Insets: Codable, Equatable {
        public var left: Double
        public var top: Double
        public var right: Double
        public var bottom: Double

        public init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    /// Altezza di una riga del browser, in punti.
    public var rowHeight: Double
    /// Quante righe catturare attorno al clic: un po' di contesto aiuta l'OCR.
    public var captureRows: Double
    /// Area della lista tracce dentro la finestra di Serato, come distanza dai bordi in punti.
    /// I clic fuori da quest'area passano a Serato senza essere toccati.
    public var browserInsets: Insets
    /// Sotto questo punteggio la traccia non viene considerata riconosciuta.
    public var minimumScore: Double
    /// Lingue per l'OCR, in ordine di priorità.
    public var ocrLanguages: [String]

    public static let defaults = PreviewSettings(
        rowHeight: 18,
        captureRows: 3,
        browserInsets: Insets(left: 0, top: 0, right: 0, bottom: 0),
        minimumScore: 0.6,
        ocrLanguages: ["it-IT", "en-US"]
    )

    public init(rowHeight: Double, captureRows: Double, browserInsets: Insets, minimumScore: Double, ocrLanguages: [String]) {
        self.rowHeight = rowHeight
        self.captureRows = captureRows
        self.browserInsets = browserInsets
        self.minimumScore = minimumScore
        self.ocrLanguages = ocrLanguages
    }

    // Le chiavi mancanti prendono il valore predefinito, così un file vecchio resta valido.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        rowHeight = try container.decodeIfPresent(Double.self, forKey: .rowHeight) ?? defaults.rowHeight
        captureRows = try container.decodeIfPresent(Double.self, forKey: .captureRows) ?? defaults.captureRows
        browserInsets = try container.decodeIfPresent(Insets.self, forKey: .browserInsets) ?? defaults.browserInsets
        minimumScore = try container.decodeIfPresent(Double.self, forKey: .minimumScore) ?? defaults.minimumScore
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? defaults.ocrLanguages
    }

    /// Rettangolo della lista tracce, nelle stesse coordinate globali della finestra.
    public func browserRect(in window: CGRect) -> CGRect {
        CGRect(x: window.minX + browserInsets.left,
               y: window.minY + browserInsets.top,
               width: max(window.width - browserInsets.left - browserInsets.right, 0),
               height: max(window.height - browserInsets.top - browserInsets.bottom, 0))
    }

    // MARK: - File

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SeratoPreview/settings.json")
    }

    /// Legge il file; se manca lo crea con i valori predefiniti.
    public static func load() throws -> PreviewSettings {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(PreviewSettings.self, from: Data(contentsOf: url))
        }
        try defaults.save()
        return defaults
    }

    public func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
