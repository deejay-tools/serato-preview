// midi-monitor.swift — stampa i messaggi MIDI in arrivo da tutte le sorgenti (controller compresi).
// Serve a scoprire cosa manda un tasto prima di mapparlo. Non invia nulla.
//
// Uso:
//   swift Tools/midi-monitor.swift            tutti i messaggi
//   swift Tools/midi-monitor.swift --notes    solo Note On/Off e Control Change, senza i valori ripetuti
// Ctrl-C per uscire.

import CoreMIDI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let onlyNotes = CommandLine.arguments.contains("--notes")

func name(of endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
    return value?.takeRetainedValue() as String? ?? "?"
}

func describe(_ bytes: [UInt8]) -> String? {
    guard let status = bytes.first else { return nil }
    let channel = Int(status & 0x0F) + 1
    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    switch status & 0xF0 {
    case 0x90 where bytes.count >= 3:
        return String(format: "%@  Note %@ ch %2d nota %3d vel %3d", hex, bytes[2] > 0 ? "On " : "Off", channel, bytes[1], bytes[2])
    case 0x80 where bytes.count >= 3:
        return String(format: "%@  Note Off ch %2d nota %3d", hex, channel, bytes[1])
    case 0xB0 where bytes.count >= 3:
        return String(format: "%@  CC       ch %2d cc   %3d val %3d", hex, channel, bytes[1], bytes[2])
    default:
        return onlyNotes ? nil : "\(hex)  altro"
    }
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("midi-monitor" as CFString, &client, nil)
var port = MIDIPortRef()
let status = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, source in
    let sourceName = source.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
    list.unsafeSequence().forEach { packet in
        // Universal MIDI Packet MIDI 1.0 (tipo 2): un messaggio di canale in una parola da 32 bit.
        let word = packet.pointee.words.0
        guard word >> 28 == 0x2 else { return }
        let bytes = [UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)]
        if let text = describe(bytes) { print("[\(sourceName)] \(text)") }
    }
}
guard status == noErr else { fputs("Porta MIDI non creata: \(status)\n", stderr); exit(1) }

let count = MIDIGetNumberOfSources()
print("Sorgenti MIDI: \(count)")
var names: [NSString] = []
for i in 0..<count {
    let source = MIDIGetSource(i)
    let label = name(of: source) as NSString
    names.append(label)
    MIDIPortConnectSource(port, source, Unmanaged.passUnretained(label).toOpaque())
    print("  \(label)")
}
print("In ascolto. Premi i tasti del controller; Ctrl-C per uscire.\n")
CFRunLoopRun()
