import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("SFace embedding record codec")
struct SFaceEmbeddingRecordCodecTests {
    @Test("encodes a negative unit component as little-endian Float32")
    func encodesKnownLittleEndianBytes() throws {
        let embedding = try makeEmbedding(first: -1)

        let data = try SFaceEmbeddingRecordCodec.encode(embedding)

        #expect(data.count == 512)
        #expect(Array(data.prefix(4)) == [0x00, 0x00, 0x80, 0xBF])
        #expect(data.dropFirst(4).allSatisfy { $0 == 0 })
    }

    @Test("uses the fixed 128-component and 512-byte contract")
    func fixedShapeAndByteCount() {
        #expect(SFaceEmbeddingRecordCodec.componentCount == 128)
        #expect(SFaceEmbeddingRecordCodec.byteCount == 512)
    }

    @Test("roundtrips an exactly representable unit vector and model version")
    func roundTripsUnitVector() throws {
        let embedding = try makeEmbedding(first: 1)
        let encoded = try SFaceEmbeddingRecordCodec.encode(embedding)

        let decoded = try SFaceEmbeddingRecordCodec.decode(
            encoded,
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion
        )

        #expect(decoded == embedding)
        #expect(decoded.modelVersion == "sface-opencv-zoo-4.10.0-fp32")
        #expect(decoded.components.count == 128)
    }

    @Test("decodes a valid Data slice with a nonzero start index")
    func decodesNonzeroStartIndexSlice() throws {
        let embedding = try makeEmbedding(first: 1)
        let encoded = try SFaceEmbeddingRecordCodec.encode(embedding)
        let prefixed = Data([0xAA, 0xBB, 0xCC, 0xDD]) + encoded
        let sliced = prefixed.dropFirst(4)

        let decoded = try SFaceEmbeddingRecordCodec.decode(
            sliced,
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion
        )

        #expect(decoded == embedding)
    }

    @Test("rejects wrong version, short payload, and trailing bytes")
    func rejectsWrongVersionAndLengths() throws {
        let encoded = try SFaceEmbeddingRecordCodec.encode(
            makeEmbedding(first: 1)
        )

        #expect(
            throws: SFaceEmbeddingRecordCodecError.failed,
            performing: {
                _ = try SFaceEmbeddingRecordCodec.decode(
                    encoded,
                    modelVersion: "other-model"
                )
            }
        )
        #expect(
            throws: SFaceEmbeddingRecordCodecError.failed,
            performing: {
                _ = try SFaceEmbeddingRecordCodec.decode(
                    Data(encoded.dropLast()),
                    modelVersion: SFaceEmbeddingRecordCodec.modelVersion
                )
            }
        )
        #expect(
            throws: SFaceEmbeddingRecordCodecError.failed,
            performing: {
                _ = try SFaceEmbeddingRecordCodec.decode(
                    encoded + Data([0]),
                    modelVersion: SFaceEmbeddingRecordCodec.modelVersion
                )
            }
        )
    }

    @Test("rejects non-finite and zero payload values")
    func rejectsNonFiniteAndZeroValues() {
        let malformed = [
            payload(first: .nan),
            payload(first: .infinity),
            Data(repeating: 0, count: SFaceEmbeddingRecordCodec.byteCount)
        ]

        for data in malformed {
            #expect(
                throws: SFaceEmbeddingRecordCodecError.failed,
                performing: {
                    _ = try SFaceEmbeddingRecordCodec.decode(
                        data,
                        modelVersion: SFaceEmbeddingRecordCodec.modelVersion
                    )
                }
            )
        }
    }

    @Test("encode rejects a different model version or component count")
    func encodeRejectsWrongMetadata() throws {
        let wrongVersion = try FaceEmbedding(
            modelVersion: "other-model",
            components: [1]
        )
        let wrongCount = try FaceEmbedding(
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            components: [1, 0]
        )

        #expect(
            throws: SFaceEmbeddingRecordCodecError.failed,
            performing: {
                _ = try SFaceEmbeddingRecordCodec.encode(wrongVersion)
            }
        )
        #expect(
            throws: SFaceEmbeddingRecordCodecError.failed,
            performing: {
                _ = try SFaceEmbeddingRecordCodec.encode(wrongCount)
            }
        )
    }

    @Test("codec failure is fixed and redacted")
    func errorIsRedacted() throws {
        do {
            _ = try SFaceEmbeddingRecordCodec.decode(
                Data(),
                modelVersion: SFaceEmbeddingRecordCodec.modelVersion
            )
            Issue.record("expected codec failure")
        } catch let error as SFaceEmbeddingRecordCodecError {
            #expect(error == .failed)
            #expect(String(describing: error) == "SFace embedding record codec failed.")
            #expect(String(reflecting: error) == "SFace embedding record codec failed.")
            #expect(Mirror(reflecting: error).children.isEmpty)
            #expect(!String(reflecting: error).contains("Data"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("codec and error are Sendable values")
    func valuesAreSendable() {
        acceptsSendable(SFaceEmbeddingRecordCodec())
        acceptsSendable(SFaceEmbeddingRecordCodecError.failed)
    }

    private func makeEmbedding(first: Float) throws -> FaceEmbedding {
        try FaceEmbedding(
            modelVersion: SFaceEmbeddingRecordCodec.modelVersion,
            components: [first] + Array(repeating: Float.zero, count: 127)
        )
    }

    private static func payload(first: Float) -> Data {
        var data = Data(
            repeating: 0,
            count: SFaceEmbeddingRecordCodec.byteCount
        )
        var littleEndianBits = first.bitPattern.littleEndian
        let firstBytes = withUnsafeBytes(of: &littleEndianBits) {
            Array($0)
        }
        data.replaceSubrange(0..<4, with: firstBytes)
        return data
    }

    private func payload(first: Float) -> Data {
        Self.payload(first: first)
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
