import CoreMIDI
import Foundation

/// Un messaggio MIDI di canale ricevuto da un controller.
public struct MIDIMessage: Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case note
        case controlChange
    }

    public let kind: Kind
    /// 1-16.
    public let channel: Int
    /// Numero della nota o del controller.
    public let number: Int
    /// Velocity (0 = Note Off) o valore del controller.
    public let value: Int

    public var description: String {
        "\(kind == .note ? "nota" : "CC") \(number) canale \(channel) valore \(value)"
    }
}

/// Ascolta tutte le sorgenti MIDI, anche quelle collegate dopo l'avvio, senza togliere nulla alle
/// altre app: Serato continua a ricevere gli stessi messaggi. Non invia nulla.
/// `onMessage` gira sul main thread e riceve Note On/Off e Control Change.
public final class MIDIInput {
    public enum StartError: Error, CustomStringConvertible {
        case coreMIDI(OSStatus)

        public var description: String {
            switch self {
            case .coreMIDI(let status): return "CoreMIDI non disponibile (errore \(status))."
            }
        }
    }

    public var onMessage: (MIDIMessage) -> Void = { _ in }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []

    public init() {}

    public func start() throws {
        guard client == 0 else { return }
        var status = MIDIClientCreateWithBlock("SeratoPreview" as CFString, &client) { [weak self] notification in
            // Un controller collegato o scollegato: si ricollegano le sorgenti.
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectSources() }
        }
        guard status == noErr else { throw StartError.coreMIDI(status) }

        status = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { [weak self] list, _ in
            let messages = list.unsafeSequence().compactMap { Self.message(from: $0.pointee.words.0) }
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                messages.forEach(self.onMessage)
            }
        }
        guard status == noErr else { throw StartError.coreMIDI(status) }
        connectSources()
    }

    private func connectSources() {
        let sources = Set((0..<MIDIGetNumberOfSources()).map(MIDIGetSource))
        for source in sources.subtracting(connected) { MIDIPortConnectSource(port, source, nil) }
        connected = sources
    }

    /// Universal MIDI Packet MIDI 1.0 (tipo 2): un messaggio di canale in una parola da 32 bit.
    private static func message(from word: UInt32) -> MIDIMessage? {
        guard word >> 28 == 0x2 else { return nil }
        let status = UInt8(word >> 16 & 0xFF)
        let number = Int(word >> 8 & 0x7F), value = Int(word & 0x7F)
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0x90: return MIDIMessage(kind: .note, channel: channel, number: number, value: value)
        case 0x80: return MIDIMessage(kind: .note, channel: channel, number: number, value: 0)
        case 0xB0: return MIDIMessage(kind: .controlChange, channel: channel, number: number, value: value)
        default: return nil
        }
    }
}
