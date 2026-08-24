/// Stable failure for the automatic visitor-presence boundary.
///
/// Camera, Vision, timing, and frame diagnostics remain inside Infrastructure.
public enum VisitorPresenceMonitoringError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    public var description: String {
        "Visitor presence monitoring failed."
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Provider-neutral presence boundary for Lumi's continuous welcome loop.
///
/// `waitForVisitor` completes only after Infrastructure observes one usable
/// face. `waitForDeparture` completes only after the configured continuous
/// absence period. Neither operation exposes frames, scores, or identity.
public protocol VisitorPresenceMonitoringPort: Sendable {
    func waitForVisitor() async throws
    func waitForDeparture() async throws
    func stop() async
}
