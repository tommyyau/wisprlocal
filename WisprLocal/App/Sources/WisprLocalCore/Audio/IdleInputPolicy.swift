/// The default input's connection type, queried without opening the microphone.
public enum InputTransport: Sendable {
    case builtIn, bluetooth, other, unknown
}

public enum IdleInputPolicy {
    /// Opening a Bluetooth mic switches A2DP music to HFP headset mode, even without starting
    /// capture. On 2026-10-07, output volume fell from 0.68 to 0.40. Keep that input closed
    /// during idle preparation; unknown transports retain fast idle preparation.
    /// Raw Bluetooth capture follows readiness settings; VPIO/HFP must never stay open idle.
    public static func canKeepWarm(vpEnabled: Bool, transport: InputTransport) -> Bool {
        !(vpEnabled && transport == .bluetooth)
    }

    public static func keepInputClosedWhileIdle(vpEnabled: Bool, transport: InputTransport) -> Bool {
        vpEnabled || transport == .bluetooth
    }
}
