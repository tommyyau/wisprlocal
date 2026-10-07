/// The default input's connection type, queried without opening the microphone.
public enum InputTransport: Sendable {
    case builtIn, bluetooth, other, unknown
}

public enum IdleInputPolicy {
    /// Opening a Bluetooth mic switches A2DP music to HFP headset mode, even without starting
    /// capture. On 2026-10-07, output volume fell from 0.68 to 0.40. Keep that input closed
    /// while idle; unknown transports retain the existing fast idle preparation behaviour.
    public static func keepInputClosedWhileIdle(vpEnabled: Bool, transport: InputTransport) -> Bool {
        vpEnabled || transport == .bluetooth
    }
}
