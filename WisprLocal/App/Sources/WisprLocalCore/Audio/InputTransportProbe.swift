import CoreAudio
import Foundation

/// Read-only CoreAudio queries. These never create an engine or open its input node.
public enum InputTransportProbe {
    /// Device IDs can change after reconnection; persist the stable UID instead.
    public static func uid(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// A disconnected explicit choice must not silently fall back to a different microphone.
    public static func selectedInputID(uid: String?) -> AudioDeviceID? {
        guard let uid else { return defaultInputID() }
        var value = uid as CFString
        var id: AudioDeviceID = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &value) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    public static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Raw transport value for callers that distinguish additional CoreAudio transports.
    /// Zero preserves InputDevices' existing fallback when the query fails.
    public static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return 0 }
        return t
    }

    public static func defaultInputTransport() -> InputTransport {
        guard let id = defaultInputID() else { return .unknown }
        return classify(transport(id))
    }

    static func classify(_ transport: UInt32) -> InputTransport {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case 0, kAudioDeviceTransportTypeUnknown: return .unknown
        default: return .other
        }
    }
}
