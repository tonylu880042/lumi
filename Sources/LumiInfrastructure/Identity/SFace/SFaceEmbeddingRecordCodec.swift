import Foundation

/// Stable, payload-free failure for the SFace embedding record codec.
enum SFaceEmbeddingRecordCodecError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    var description: String {
        "SFace embedding record codec failed."
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// Deterministic binary representation for one versioned SFace embedding.
///
/// The model version is stored in SQLite's adjacent text column, so the
/// payload is exactly 128 IEEE754 Float32 values in little-endian order with
/// no header or checksum.
struct SFaceEmbeddingRecordCodec: Sendable {
    static let modelVersion = SFaceCoreMLInference.modelVersion
    static let componentCount = 128
    static let byteCount = 512

    init() {}

    static func encode(
        _ embedding: FaceEmbedding
    ) throws(SFaceEmbeddingRecordCodecError) -> Data {
        guard embedding.modelVersion == modelVersion,
              embedding.components.count == componentCount,
              embedding.components.allSatisfy(\.isFinite) else {
            throw .failed
        }

        var payload = Data(capacity: byteCount)
        for component in embedding.components {
            var littleEndianBits = component.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { bytes in
                payload.append(contentsOf: bytes)
            }
        }

        guard payload.count == byteCount else {
            throw .failed
        }
        return payload
    }

    static func decode(
        _ data: Data,
        modelVersion: String
    ) throws(SFaceEmbeddingRecordCodecError) -> FaceEmbedding {
        guard modelVersion == Self.modelVersion,
              data.count == byteCount else {
            throw .failed
        }

        var components: [Float] = []
        components.reserveCapacity(componentCount)
        do {
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard bytes.count == byteCount else {
                    throw SFaceEmbeddingRecordCodecError.failed
                }

                for offset in stride(from: 0, to: byteCount, by: 4) {
                    let bits = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                    let component = Float(bitPattern: bits)
                    guard component.isFinite else {
                        throw SFaceEmbeddingRecordCodecError.failed
                    }
                    components.append(component)
                }
            }
        } catch {
            throw .failed
        }

        guard components.count == componentCount else {
            throw .failed
        }

        let squaredMagnitude = components.reduce(Float.zero) {
            $0 + $1 * $1
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > 0 else {
            throw .failed
        }

        do {
            return try FaceEmbedding(
                modelVersion: modelVersion,
                components: components
            )
        } catch {
            throw .failed
        }
    }
}
