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
    /// Altezza della fascia catturata attorno al clic, in righe. Con 2 la riga cliccata
    /// è sempre intera, ovunque cada il clic al suo interno.
    public var captureRows: Double
    /// Area della lista tracce dentro la finestra di Serato, come distanza dai bordi in punti.
    /// I clic fuori da quest'area passano a Serato senza essere toccati.
    public var browserInsets: Insets
    /// Un testo che finisce a meno di questa distanza (in punti) dal testo successivo o dal bordo
    /// destro è considerato tagliato da Serato.
    public var truncationGap: Double
    /// Sotto questo punteggio la traccia non viene considerata riconosciuta.
    public var minimumScore: Double
    /// OCR veloce invece che accurato.
    public var fastOCR: Bool
    /// Lingue per l'OCR, in ordine di priorità.
    public var ocrLanguages: [String]

    // Valori misurati con `click-identify --calibrate` su Serato DJ Pro 5.0, finestra 1680×1013.
    public static let defaults = PreviewSettings(
        rowHeight: 29.5,
        captureRows: 2,
        browserInsets: Insets(left: 285, top: 478, right: 0, bottom: 25),
        truncationGap: 14,
        minimumScore: 0.6,
        // Su Intel l'OCR accurato impiega 1-1,5 s per riga, quello veloce circa 20 ms.
        fastOCR: true,
        ocrLanguages: ["it-IT", "en-US"]
    )

    public init(rowHeight: Double, captureRows: Double, browserInsets: Insets, truncationGap: Double,
                minimumScore: Double, fastOCR: Bool, ocrLanguages: [String]) {
        self.rowHeight = rowHeight
        self.captureRows = captureRows
        self.browserInsets = browserInsets
        self.truncationGap = truncationGap
        self.minimumScore = minimumScore
        self.fastOCR = fastOCR
        self.ocrLanguages = ocrLanguages
    }

    // Le chiavi mancanti prendono il valore predefinito, così un file vecchio resta valido.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        rowHeight = try container.decodeIfPresent(Double.self, forKey: .rowHeight) ?? defaults.rowHeight
        captureRows = try container.decodeIfPresent(Double.self, forKey: .captureRows) ?? defaults.captureRows
        browserInsets = try container.decodeIfPresent(Insets.self, forKey: .browserInsets) ?? defaults.browserInsets
        truncationGap = try container.decodeIfPresent(Double.self, forKey: .truncationGap) ?? defaults.truncationGap
        minimumScore = try container.decodeIfPresent(Double.self, forKey: .minimumScore) ?? defaults.minimumScore
        fastOCR = try container.decodeIfPresent(Bool.self, forKey: .fastOCR) ?? defaults.fastOCR
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
