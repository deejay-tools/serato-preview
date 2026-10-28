import AppKit
import AVFoundation

/// Riproduce l'anteprima su un device e una coppia di canali, in contemporanea a Serato.
/// Il device non viene mai riconfigurato: frequenza e buffer restano quelli scelti da Serato,
/// e se un altro processo lo tiene in uso esclusivo la riproduzione non parte.
/// Da usare sul main thread.
public final class PreviewPlayer {
    public enum PlayerError: Error, CustomStringConvertible {
        case deviceNotFound
        case deviceBusy(pid_t)
        case invalidChannels([Int], available: Int)
        case unreadableFile(String)
        case engine(String)

        public var description: String {
            switch self {
            case .deviceNotFound:
                return "Uscita audio non trovata: controlla le impostazioni."
            case .deviceBusy(let pid):
                let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                return "Uscita audio in uso esclusivo da \(owner)."
            case .invalidChannels(let channels, let available):
                return "Canali \(channels.map(String.init).joined(separator: "-")) non disponibili: l'uscita ne ha \(available)."
            case .unreadableFile(let name):
                return "Impossibile leggere \(name)."
            case .engine(let message):
                return "Errore audio: \(message)"
            }
        }
    }

    public private(set) var url: URL?
    public private(set) var duration: TimeInterval = 0
    public var isPlaying: Bool { engine != nil }
    /// Chiamato sul main thread quando il brano finisce o il device cambia o si scollega.
    public var onStop: (() -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var file: AVAudioFile?
    private var segmentStart: AVAudioFramePosition = 0
    /// Cambia a ogni nuova programmazione: le callback di segmenti vecchi vengono ignorate.
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?

    public init() {}

    public var position: TimeInterval {
        guard let file, let player else { return 0 }
        var frames = Double(segmentStart)
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            frames += Double(playerTime.sampleTime)
        }
        return min(max(frames / file.processingFormat.sampleRate, 0), duration)
    }

    public func play(url: URL, deviceUID: String?, channels: [Int], startFraction: Double, volume: Float) throws {
        stop(notify: false)

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw PlayerError.unreadableFile(url.lastPathComponent) }
        guard let device = AudioDevices.output(uid: deviceUID) else { throw PlayerError.deviceNotFound }
        if let owner = AudioDevices.hogOwner(of: device), owner != getpid() { throw PlayerError.deviceBusy(owner) }
        guard channels.count == 2, channels.allSatisfy({ (1...device.outputChannels).contains($0) }) else {
            throw PlayerError.invalidChannels(channels, available: device.outputChannels)
        }

        let engine = AVAudioEngine()
        let output = engine.outputNode
        do { try output.auAudioUnit.setDeviceID(device.id) } catch { throw PlayerError.engine(error.localizedDescription) }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        let hardwareRate = output.outputFormat(forBus: 0).sampleRate
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2) else {
            throw PlayerError.engine("formato di uscita non valido")
        }
        engine.connect(engine.mainMixerNode, to: output, format: stereo)
        engine.mainMixerNode.outputVolume = volume

        // Mappa canali: un elemento per canale del device; il valore è il canale stereo del client (-1 = silenzio).
        var channelMap = [Int32](repeating: -1, count: device.outputChannels)
        channelMap[channels[0] - 1] = 0
        channelMap[channels[1] - 1] = 1
        guard let unit = output.audioUnit else { throw PlayerError.engine("unità di uscita non disponibile") }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                                          channelMap, UInt32(channelMap.count * MemoryLayout<Int32>.size))
        guard status == noErr else { throw PlayerError.engine("mappa canali (OSStatus \(status))") }

        self.engine = engine
        self.player = player
        self.file = file
        self.url = url
        self.duration = Double(file.length) / file.processingFormat.sampleRate

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.stop(notify: true)
        }

        do {
            try engine.start()
        } catch {
            stop(notify: false)
            throw PlayerError.engine(error.localizedDescription)
        }
        let fraction = min(max(startFraction, 0), 0.95)
        schedule(from: AVAudioFramePosition(Double(file.length) * fraction))
    }

    /// Sposta la posizione di `seconds` (negativo = indietro).
    public func seek(by seconds: TimeInterval) {
        guard let file else { return }
        let target = min(max(position + seconds, 0), max(duration - 1, 0))
        schedule(from: AVAudioFramePosition(target * file.processingFormat.sampleRate))
    }

    public func stop() {
        stop(notify: false)
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let player, let file else { return }
        generation += 1
        let current = generation
        player.stop()
        segmentStart = frame
        let remaining = file.length - frame
        guard remaining > 0 else {
            stop(notify: true)
            return
        }
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.stop(notify: true)
            }
        }
        player.play()
    }

    private func stop(notify: Bool) {
        guard engine != nil else { return }
        generation += 1
        player?.stop()
        engine?.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
        player = nil
        file = nil
        url = nil
        duration = 0
        segmentStart = 0
        if notify { onStop?() }
    }
}
