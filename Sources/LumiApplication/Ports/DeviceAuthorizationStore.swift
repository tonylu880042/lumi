import Foundation

/// An opaque, validated device authorization value.
public struct DeviceAuthorizationToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    /// The exact validated value supplied when this token was created.
    public let rawValue: String

    /// Creates a token from an unpadded base64url value containing 32 bytes.
    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 43 else { return nil }
        guard bytes.allSatisfy(Self.isBase64URLByte) else { return nil }

        var standardBase64 = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standardBase64.append("=")

        guard let decoded = Data(base64Encoded: standardBase64), decoded.count == 32 else {
            return nil
        }

        let canonicalBase64URL = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonicalBase64URL == rawValue else { return nil }

        self.rawValue = rawValue
    }

    public var description: String { "<redacted>" }

    public var debugDescription: String { "<redacted>" }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: ["<redacted>"], displayStyle: .struct)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 45, 95:
            true
        default:
            false
        }
    }
}

/// Persistence boundary for one device authorization value.
public protocol DeviceAuthorizationStore: Sendable {
    func load() async throws -> DeviceAuthorizationToken?
    func save(_ token: DeviceAuthorizationToken) async throws
    func remove() async throws
}
