import CoreAudio

/// Read-only CoreAudio queries. These never create an engine or open its input node.
public enum InputTransportProbe {
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
