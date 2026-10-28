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

    /// Tasti da tenere premuti durante il clic per l'anteprima.
    public enum Modifier: String, Codable, CaseIterable, Identifiable {
        case option
        case control
        case commandOption
        case controlOption

        public var id: String { rawValue }

        public var flags: CGEventFlags {
            switch self {
            case .option: return .maskAlternate
            case .control: return .maskControl
            case .commandOption: return [.maskCommand, .maskAlternate]
            case .controlOption: return [.maskControl, .maskAlternate]
            }
        }

        public var symbol: String {
            switch self {
            case .option: return "⌥"
            case .control: return "⌃"
            case .commandOption: return "⌘⌥"
            case .controlOption: return "⌃⌥"
            }
        }
    }

    /// Lingua dell'interfaccia.
    public enum Language: String, Codable, CaseIterable, Identifiable {
        case system
        case italian
        case english

        public var id: String { rawValue }

        /// Lingua effettiva: con `system` l'italiano se è la prima lingua di macOS, altrimenti l'inglese.
        public var resolved: Language {
            guard self == .system else { return self }
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("it") ? .italian : .english
        }
    }

    // MARK: Interfaccia

    public var language: Language

    // MARK: Attivazione

    public var modifier: Modifier

    // MARK: Audio

    /// UID del device CoreAudio; nil = uscita di sistema.
    public var outputDeviceUID: String?
    /// Coppia di canali di uscita (base 1), es. [3, 4] per la cuffia del controller.
    public var outputChannels: [Int]
    /// Punto di partenza come frazione della durata.
    public var startFraction: Double
    public var volume: Double
    /// Secondi di spostamento per ogni pressione di ← o →.
    public var seekStep: Double

    // MARK: Geometria del browser

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

    // MARK: Riconoscimento

    /// Sotto questo punteggio la traccia non viene considerata riconosciuta.
    public var minimumScore: Double
    /// OCR veloce invece che accurato.
    public var fastOCR: Bool
    /// Lingue per l'OCR, in ordine di priorità.
    public var ocrLanguages: [String]

    // Geometria misurata con `click-identify --calibrate` su Serato DJ Pro 5.0, finestra 1680×1013.
    public static let defaults = PreviewSettings(
        language: .system,
        modifier: .option,
        outputDeviceUID: nil,
        outputChannels: [1, 2],
        startFraction: 0.3,
        volume: 0.8,
        seekStep: 5,
        rowHeight: 29.5,
        captureRows: 2,
        browserInsets: Insets(left: 285, top: 478, right: 0, bottom: 25),
        truncationGap: 14,
        minimumScore: 0.6,
        // Su Intel l'OCR accurato impiega 1-1,5 s per riga, quello veloce circa 20 ms.
        fastOCR: true,
        ocrLanguages: ["it-IT", "en-US"]
    )

    public init(language: Language, modifier: Modifier, outputDeviceUID: String?, outputChannels: [Int], startFraction: Double,
                volume: Double, seekStep: Double, rowHeight: Double, captureRows: Double, browserInsets: Insets,
                truncationGap: Double, minimumScore: Double, fastOCR: Bool, ocrLanguages: [String]) {
        self.language = language
        self.modifier = modifier
        self.outputDeviceUID = outputDeviceUID
        self.outputChannels = outputChannels
        self.startFraction = startFraction
        self.volume = volume
        self.seekStep = seekStep
        self.rowHeight = rowHeight
        self.captureRows = captureRows
        self.browserInsets = browserInsets
        self.truncationGap = truncationGap
        self.minimumScore = minimumScore
        self.fastOCR = fastOCR
        self.ocrLanguages = ocrLanguages
    }

    // Le chiavi mancanti o non valide prendono il valore predefinito, così un file vecchio resta valido.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        language = value(.language, defaults.language)
        modifier = value(.modifier, defaults.modifier)
        outputDeviceUID = value(.outputDeviceUID, defaults.outputDeviceUID)
        outputChannels = value(.outputChannels, defaults.outputChannels)
        startFraction = value(.startFraction, defaults.startFraction)
        volume = value(.volume, defaults.volume)
        seekStep = value(.seekStep, defaults.seekStep)
        rowHeight = value(.rowHeight, defaults.rowHeight)
        captureRows = value(.captureRows, defaults.captureRows)
        browserInsets = value(.browserInsets, defaults.browserInsets)
        truncationGap = value(.truncationGap, defaults.truncationGap)
        minimumScore = value(.minimumScore, defaults.minimumScore)
        fastOCR = value(.fastOCR, defaults.fastOCR)
        ocrLanguages = value(.ocrLanguages, defaults.ocrLanguages)
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
