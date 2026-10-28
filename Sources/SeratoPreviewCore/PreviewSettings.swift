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

    /// Un tasto del controller: Note On o Control Change con valore maggiore di zero.
    public struct MIDIControl: Codable, Equatable {
        public var kind: MIDIMessage.Kind
        /// 1-16.
        public var channel: Int
        public var number: Int

        public init(kind: MIDIMessage.Kind = .note, channel: Int, number: Int) {
            self.kind = kind
            self.channel = channel
            self.number = number
        }

        // Senza "kind" nel file vale come nota.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(MIDIMessage.Kind.self, forKey: .kind) ?? .note
            channel = try container.decode(Int.self, forKey: .channel)
            number = try container.decode(Int.self, forKey: .number)
        }

        /// Il tasto è stato premuto (il rilascio non conta).
        public func isPressed(by message: MIDIMessage) -> Bool {
            message.kind == kind && message.channel == channel && message.number == number && message.value > 0
        }
    }

    /// Tasti del controller per l'anteprima; nil = non assegnato.
    public struct MIDIMapping: Codable, Equatable {
        /// Ascolta la traccia selezionata in Serato, o ferma l'anteprima in corso.
        public var playStop: MIDIControl?
        public var back: MIDIControl?
        public var forward: MIDIControl?

        public init(playStop: MIDIControl?, back: MIDIControl?, forward: MIDIControl?) {
            self.playStop = playStop
            self.back = back
            self.forward = forward
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
    public var midi: MIDIMapping

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

    // Geometria misurata su Serato DJ Pro 5.0 con la finestra a 1440×863 (MacBook Pro M1).
    public static let defaults = PreviewSettings(
        language: .system,
        modifier: .option,
        // Pioneer DDJ-FLX10, canale 2: SHIFT+LINK e SHIFT+frecce MIX POINT SELECT. Senza SHIFT
        // quei tasti hanno funzioni fisse in Serato (Link, intonazione) che MIDI Learn non toglie.
        midi: MIDIMapping(playStop: MIDIControl(channel: 2, number: 67),
                          back: MIDIControl(channel: 2, number: 73),
                          forward: MIDIControl(channel: 2, number: 66)),
        outputDeviceUID: nil,
        outputChannels: [1, 2],
        startFraction: 0.3,
        volume: 0.8,
        seekStep: 5,
        rowHeight: 28,
        captureRows: 2,
        browserInsets: Insets(left: 306, top: 398, right: 0, bottom: 42),
        truncationGap: 14,
        minimumScore: 0.6,
        // Su Intel l'OCR accurato impiega 1-1,5 s per riga, quello veloce circa 20 ms.
        fastOCR: true,
        ocrLanguages: ["it-IT", "en-US"]
    )

    public init(language: Language, modifier: Modifier, midi: MIDIMapping, outputDeviceUID: String?, outputChannels: [Int], startFraction: Double,
                volume: Double, seekStep: Double, rowHeight: Double, captureRows: Double, browserInsets: Insets,
                truncationGap: Double, minimumScore: Double, fastOCR: Bool, ocrLanguages: [String]) {
        self.language = language
        self.modifier = modifier
        self.midi = midi
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
        midi = value(.midi, defaults.midi)
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
