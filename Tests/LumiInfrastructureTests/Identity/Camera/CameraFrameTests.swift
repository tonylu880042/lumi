import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Camera frame contract")
struct CameraFrameTests {
    @Test("copies exactly the required bytes before the source buffer changes")
    func copiesOwnedBytes() throws {
        let byteCount = 8
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        defer { pointer.deallocate() }

        for offset in 0..<byteCount {
            pointer.storeBytes(of: UInt8(offset), toByteOffset: offset, as: UInt8.self)
        }

        let source = Data(bytesNoCopy: pointer, count: byteCount, deallocator: .none)
        let frame = try CameraFrame(
            bytes: source,
            width: 1,
            height: 2,
            bytesPerRow: 4,
            orientation: .upright
        )

        pointer.storeBytes(of: UInt8(255), toByteOffset: 0, as: UInt8.self)

        #expect(frame.bytes == Data([0, 1, 2, 3, 4, 5, 6, 7]))
        #expect(frame.bytes.count == byteCount)
        #expect(frame.width == 1)
        #expect(frame.height == 2)
        #expect(frame.bytesPerRow == 4)
        acceptsSendable(frame)
    }

    @Test("discards trailing source bytes and stores exact frame storage")
    func storesExactRequiredByteCount() throws {
        let frame = try CameraFrame(
            bytes: Data([1, 2, 3, 4, 5, 6]),
            width: 1,
            height: 1,
            bytesPerRow: 4,
            orientation: .upright
        )

        #expect(frame.bytes == Data([1, 2, 3, 4]))
        #expect(frame.bytes.count == 4)
    }

    @Test("rejects non-positive dimensions")
    func rejectsNonPositiveDimensions() {
        #expect(throws: CameraFrameError.nonPositiveDimensions) {
            try CameraFrame(
                bytes: Data(repeating: 0, count: 4),
                width: 0,
                height: 1,
                bytesPerRow: 4,
                orientation: .upright
            )
        }
        #expect(throws: CameraFrameError.nonPositiveDimensions) {
            try CameraFrame(
                bytes: Data(repeating: 0, count: 4),
                width: 1,
                height: -1,
                bytesPerRow: 4,
                orientation: .upright
            )
        }
    }

    @Test("rejects invalid row stride and multiplication overflow")
    func rejectsRowStrideOverflow() {
        #expect(throws: CameraFrameError.invalidRowStride) {
            try CameraFrame(
                bytes: Data(),
                width: Int.max,
                height: 1,
                bytesPerRow: Int.max,
                orientation: .upright
            )
        }
        #expect(throws: CameraFrameError.invalidRowStride) {
            try CameraFrame(
                bytes: Data(repeating: 0, count: 8),
                width: 2,
                height: 1,
                bytesPerRow: 7,
                orientation: .upright
            )
        }
    }

    @Test("rejects storage multiplication overflow and short storage")
    func rejectsInsufficientStorage() {
        #expect(throws: CameraFrameError.insufficientBytes) {
            try CameraFrame(
                bytes: Data(),
                width: 1,
                height: Int.max,
                bytesPerRow: 4,
                orientation: .upright
            )
        }
        #expect(throws: CameraFrameError.insufficientBytes) {
            try CameraFrame(
                bytes: Data([0, 1, 2]),
                width: 1,
                height: 1,
                bytesPerRow: 4,
                orientation: .upright
            )
        }
    }
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
