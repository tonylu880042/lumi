import LumiDomain

/// Application boundary for commands sent to the rotating hardware.
public protocol HardwareControlPort: Sendable {
    /// Completes only after the adapter confirms arrival at the target angle.
    func rotate(to angle: RotationAngle) async throws

    /// Completes only after the adapter confirms arrival at Home (0°).
    func returnHome() async throws

    func stop() async
}
