#!/usr/bin/env swift
// audio-test.swift — Fase 1: si può suonare un'anteprima sullo stesso device che usa Serato?
// Non modifica mai le impostazioni del device (frequenza, buffer, hog mode): le legge soltanto
// e segnala se cambiano durante la riproduzione.
//
// Uso:
//   swift Tools/audio-test.swift list
//       elenca i device CoreAudio con canali, frequenza, buffer, hog mode e stato
//   swift Tools/audio-test.swift play <file> [opzioni]
//       --device <id|UID|parte del nome>   default: uscita di sistema predefinita
//       --channels 1,2                     canali di uscita (base 1), es. 3,4 per la cuffia del controller
//       --start 0.3                        punto di partenza come frazione del brano
//       --seconds 20                       durata del test
//       --volume 0.8

import AppKit
import AVFoundation
import CoreAudio

// MARK: - Argomenti

let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

// MARK: - Proprietà CoreAudio (sola lettura)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var propertyAddress = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var propertyAddress = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, raw) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct Device {
    let id: AudioObjectID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int

    var sampleRate: Double? { property(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) }
    var bufferFrames: UInt32? { property(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) }
    var hogPID: pid_t? { property(id, kAudioDevicePropertyHogMode, initial: pid_t(-1)) }
    var isRunningSomewhere: Bool {
        (property(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0
    }

    var hogDescription: String {
        guard let pid = hogPID else { return "n/d" }
        if pid == -1 { return "libero" }
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        return "OCCUPATO da pid \(pid) (\(owner))"
    }
}

func allDevices() -> [Device] {
    var propertyAddress = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &propertyAddress, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &propertyAddress, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map {
        Device(id: $0,
               name: stringProperty($0, kAudioObjectPropertyName) ?? "?",
               uid: stringProperty($0, kAudioDevicePropertyDeviceUID) ?? "?",
               inputChannels: channelCount($0, scope: kAudioObjectPropertyScopeInput),
               outputChannels: channelCount($0, scope: kAudioObjectPropertyScopeOutput))
    }
}

func defaultOutputID() -> AudioObjectID? {
    property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
}

func seratoIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.serato.seratodj").isEmpty
}

// MARK: - list

func listDevices() {
    let defaultID = defaultOutputID()
    print("Serato in esecuzione: \(seratoIsRunning() ? "sì" : "no")\n")
    for device in allDevices() {
        let marker = device.id == defaultID ? "  ← uscita predefinita" : ""
        print("[\(device.id)] \(device.name)\(marker)")
        print("    UID: \(device.uid)")
        print("    canali: \(device.inputChannels) in, \(device.outputChannels) out")
        print("    frequenza: \(device.sampleRate.map { "\(Int($0)) Hz" } ?? "n/d"), buffer: \(device.bufferFrames.map(String.init) ?? "n/d") frame")
        print("    hog mode: \(device.hogDescription)")
        print("    in uso da qualcuno: \(device.isRunningSomewhere ? "sì" : "no")")
    }
}

// MARK: - play

func findDevice(_ query: String?) -> Device {
    let devices = allDevices().filter { $0.outputChannels > 0 }
    guard let query else {
        guard let id = defaultOutputID(), let device = devices.first(where: { $0.id == id }) else {
            fail("Nessuna uscita predefinita.")
        }
        return device
    }
    if let id = UInt32(query), let device = devices.first(where: { $0.id == id }) { return device }
    if let device = devices.first(where: { $0.uid == query }) { return device }
    let matches = devices.filter { $0.name.localizedCaseInsensitiveContains(query) }
    if matches.count == 1 { return matches[0] }
    if matches.isEmpty { fail("Nessun device di uscita corrisponde a \"\(query)\". Usa `list`.") }
    fail("\"\(query)\" è ambiguo: " + matches.map { "[\($0.id)] \($0.name)" }.joined(separator: ", "))
}

func play() {
    guard arguments.count >= 3, !arguments[2].hasPrefix("--") else { fail("Uso: play <file> [opzioni]") }
    let url = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath)
    let device = findDevice(option("--device"))
    let channels = (option("--channels") ?? "1,2").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let startFraction = min(max(Double(option("--start") ?? "") ?? 0.3, 0), 0.95)
    let seconds = Double(option("--seconds") ?? "") ?? 20
    let volume = Float(option("--volume") ?? "") ?? 0.8

    guard channels.count == 2, channels.allSatisfy({ (1...device.outputChannels).contains($0) }) else {
        fail("--channels deve indicare 2 canali tra 1 e \(device.outputChannels) per \(device.name).")
    }

    print("Device: [\(device.id)] \(device.name), \(device.outputChannels) canali di uscita")
    print("Serato in esecuzione: \(seratoIsRunning() ? "sì" : "no"); device già in uso: \(device.isRunningSomewhere ? "sì" : "no")")
    if seratoIsRunning() && !device.isRunningSomewhere {
        print("Attenzione: nessuno sta usando questo device, quindi il test non prova la convivenza con Serato.")
    }
    print("Hog mode: \(device.hogDescription)")
    if let pid = device.hogPID, pid != -1, pid != getpid() {
        fail("Il device è in hog mode: nessun altro processo può usarlo. Il test si ferma qui.")
    }

    let initialRate = device.sampleRate
    let initialBuffer = device.bufferFrames

    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch { fail("Impossibile aprire \(url.path): \(error.localizedDescription)") }

    let engine = AVAudioEngine()
    let output = engine.outputNode
    do { try output.auAudioUnit.setDeviceID(device.id) } catch { fail("Impossibile aprire il device: \(error.localizedDescription)") }

    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    let hardwareRate = output.outputFormat(forBus: 0).sampleRate
    guard let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2) else { fail("Formato non valido.") }
    engine.connect(engine.mainMixerNode, to: output, format: stereo)
    engine.mainMixerNode.outputVolume = volume

    // Mappa canali: un elemento per canale del device; il valore è il canale stereo del client (-1 = silenzio).
    var channelMap = [Int32](repeating: -1, count: device.outputChannels)
    channelMap[channels[0] - 1] = 0
    channelMap[channels[1] - 1] = 1
    guard let unit = output.audioUnit else { fail("Audio unit di uscita non disponibile.") }
    let mapStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                                         channelMap, UInt32(channelMap.count * MemoryLayout<Int32>.size))
    guard mapStatus == noErr else { fail("Impostazione della mappa canali fallita (OSStatus \(mapStatus)).") }
    print("Mappa canali: \(channelMap) → file sui canali \(channels[0])-\(channels[1])")

    let startFrame = AVAudioFramePosition(Double(file.length) * startFraction)
    let fileRate = file.processingFormat.sampleRate
    player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)

    var configurationChanged = false
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
        configurationChanged = true
        print("!! Configurazione audio cambiata durante la riproduzione (device scollegato o modificato).")
    }

    do { try engine.start() } catch { fail("Avvio del motore audio fallito: \(error.localizedDescription)") }
    player.play()
    print("In riproduzione da \(Int(startFraction * 100))% di \(url.lastPathComponent) per \(Int(seconds)) s…\n")

    var problems: [String] = []
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        var position = Double(startFrame) / fileRate
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            position += Double(playerTime.sampleTime) / playerTime.sampleRate
        }
        let rate = device.sampleRate
        let buffer = device.bufferFrames
        print(String(format: "  %6.1f s | device %@ Hz, buffer %@ | hog: %@",
                     position,
                     rate.map { String(Int($0)) } ?? "n/d",
                     buffer.map(String.init) ?? "n/d",
                     device.hogDescription))

        if rate != initialRate, !problems.contains(where: { $0.hasPrefix("frequenza") }) {
            problems.append("frequenza del device cambiata (\(initialRate.map { String(Int($0)) } ?? "n/d") → \(rate.map { String(Int($0)) } ?? "n/d"))")
        }
        if buffer != initialBuffer, !problems.contains(where: { $0.hasPrefix("buffer") }) {
            problems.append("buffer del device cambiato (\(initialBuffer.map(String.init) ?? "n/d") → \(buffer.map(String.init) ?? "n/d"))")
        }
        if let pid = device.hogPID, pid != -1, !problems.contains(where: { $0.hasPrefix("hog") }) {
            problems.append("hog mode attivato da pid \(pid) durante la riproduzione")
        }
        if !engine.isRunning { problems.append("il motore audio si è fermato"); break }
    }

    player.stop()
    engine.stop()

    print("\n=== Esito ===")
    if configurationChanged { problems.append("configurazione audio cambiata") }
    if problems.isEmpty {
        print("Nessun problema rilevato dal lato tecnico.")
    } else {
        problems.forEach { print("- \($0)") }
    }
    print("""
    Verifica a orecchio:
    1. Hai sentito l'anteprima sui canali giusti?
    2. L'audio di Serato ha avuto click, interruzioni o cambi di velocità/intonazione?
    """)
}

// MARK: - Main

switch arguments.count > 1 ? arguments[1] : "list" {
case "list": listDevices()
case "play": play()
default: fail("Comandi: list, play <file> [--device X] [--channels 1,2] [--start 0.3] [--seconds 20] [--volume 0.8]")
}
