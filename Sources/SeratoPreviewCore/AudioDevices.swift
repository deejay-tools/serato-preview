import AppKit
import CoreAudio

/// Un device CoreAudio con canali di uscita.
public struct AudioDevice: Hashable, Sendable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let outputChannels: Int
}

/// Elenco e stato dei device CoreAudio. Sola lettura: non modifica mai frequenza, buffer o hog mode.
public enum AudioDevices {
    public static func outputs() -> [AudioDevice] {
        var propertyAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &propertyAddress, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &propertyAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioDevice(id: id,
                               name: stringProperty(id, kAudioObjectPropertyName) ?? "?",
                               uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "?",
                               outputChannels: channels)
        }
    }

    public static func defaultOutput() -> AudioDevice? {
        guard let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                initial: AudioObjectID(0)) else { return nil }
        return outputs().first { $0.id == id }
    }

    /// Il device con quell'UID, o l'uscita di sistema se `uid` è nil.
    public static func output(uid: String?) -> AudioDevice? {
        guard let uid else { return defaultOutput() }
        return outputs().first { $0.uid == uid }
    }

    /// Il processo che tiene il device in uso esclusivo, nil se è libero.
    public static func hogOwner(of device: AudioDevice) -> pid_t? {
        guard let pid = property(device.id, kAudioDevicePropertyHogMode, initial: pid_t(-1)), pid != -1 else { return nil }
        return pid
    }

    // MARK: - Proprietà CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var propertyAddress = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
