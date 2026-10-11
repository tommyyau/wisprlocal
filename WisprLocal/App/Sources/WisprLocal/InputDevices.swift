import CoreAudio
import Foundation
import WisprLocalCore

/// Microphones known to Core Audio. Explicit choices are pinned inside WisprLocal by UID.
struct InputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let isBuiltIn: Bool
    var uid: String = ""
}

enum InputDevices {
    static func all() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let uid = InputTransportProbe.uid(id) else { return nil }
            return InputDevice(id: id, name: name(id) ?? "Microphone",
                               isBuiltIn: transport(id) == kAudioDeviceTransportTypeBuiltIn, uid: uid)
        }
    }

    static func selectedInputIsBuiltIn(uid: String?) -> Bool? {
        guard let id = InputTransportProbe.selectedInputID(uid: uid) else { return nil }
        return transport(id) == kAudioDeviceTransportTypeBuiltIn
    }

    static func defaultInputID() -> AudioDeviceID? {
        InputTransportProbe.defaultInputID()
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        InputTransportProbe.transport(id)
    }
}
