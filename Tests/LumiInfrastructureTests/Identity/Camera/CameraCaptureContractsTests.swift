import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("Camera capture contracts")
struct CameraCaptureContractsTests {
    @Test("authorized permission succeeds without requesting")
    func authorizedDoesNotRequest() async throws {
        let client = RecordingCameraPermissionClient(
            current: .authorized,
            requested: .denied
        )

        try await client.authorize()

        #expect(await client.currentStatusCallCount == 1)
        #expect(await client.requestPermissionCallCount == 0)
    }

    @Test("denied permission fails with a stable typed error")
    func deniedFailsWithoutRequesting() async {
        let client = RecordingCameraPermissionClient(
            current: .denied,
            requested: .authorized
        )

        await #expect(throws: CameraPermissionError.denied) {
            try await client.authorize()
        }

        #expect(await client.requestPermissionCallCount == 0)
    }

    @Test("restricted permission fails with a stable typed error")
    func restrictedFailsWithoutRequesting() async {
        let client = RecordingCameraPermissionClient(
            current: .restricted,
            requested: .authorized
        )

        await #expect(throws: CameraPermissionError.restricted) {
            try await client.authorize()
        }

        #expect(await client.requestPermissionCallCount == 0)
    }

    @Test("not determined permission requests exactly once")
    func notDeterminedRequestsOnce() async throws {
        let client = RecordingCameraPermissionClient(
            current: .notDetermined,
            requested: .authorized
        )

        try await client.authorize()

        #expect(await client.currentStatusCallCount == 1)
        #expect(await client.requestPermissionCallCount == 1)
    }

    @Test("a denied request remains a typed denial")
    func deniedRequestFails() async {
        let client = RecordingCameraPermissionClient(
            current: .notDetermined,
            requested: .denied
        )

        await #expect(throws: CameraPermissionError.denied) {
            try await client.authorize()
        }

        #expect(await client.requestPermissionCallCount == 1)
    }

    @Test("a restricted request remains a typed restriction")
    func restrictedRequestFails() async {
        let client = RecordingCameraPermissionClient(
            current: .notDetermined,
            requested: .restricted
        )

        await #expect(throws: CameraPermissionError.restricted) {
            try await client.authorize()
        }

        #expect(await client.requestPermissionCallCount == 1)
    }

    @Test("cancellation is preserved while permission is suspended")
    func cancellationIsPreserved() async throws {
        let client = SuspendingCameraPermissionClient()
        let request = Task {
            try await client.authorize()
        }

        #expect(await waitUntil { await client.didReadCurrentStatus })
        request.cancel()
        await client.releaseCurrentStatus()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(await client.requestPermissionCallCount == 0)
    }

    @Test("cancellation is preserved while a permission request is suspended")
    func cancellationDuringRequestIsPreserved() async throws {
        let client = SuspendingRequestPermissionClient()
        let request = Task {
            try await client.authorize()
        }

        #expect(await waitUntil { await client.requestPermissionCallCount == 1 })
        request.cancel()
        await client.releaseRequestPermission(with: .authorized)

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
    }

    @Test("orientation is one upright, non-mirrored processed-image value")
    func orientationIsUprightOnly() {
        #expect(CameraFrameOrientation.allCases == [.upright])
        #expect(CameraFrameOrientation.upright == .upright)
        acceptsSendable(CameraFrameOrientation.allCases)
    }
}

private actor RecordingCameraPermissionClient: CameraPermissionClient {
    let current: CameraPermissionStatus
    let requested: CameraPermissionStatus
    private(set) var currentStatusCallCount = 0
    private(set) var requestPermissionCallCount = 0

    init(current: CameraPermissionStatus, requested: CameraPermissionStatus) {
        self.current = current
        self.requested = requested
    }

    func currentStatus() async -> CameraPermissionStatus {
        currentStatusCallCount += 1
        return current
    }

    func requestPermission() async -> CameraPermissionStatus {
        requestPermissionCallCount += 1
        return requested
    }
}

private actor SuspendingCameraPermissionClient: CameraPermissionClient {
    private var continuation: CheckedContinuation<CameraPermissionStatus, Never>?
    private(set) var didReadCurrentStatus = false
    private(set) var requestPermissionCallCount = 0

    func currentStatus() async -> CameraPermissionStatus {
        didReadCurrentStatus = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func requestPermission() async -> CameraPermissionStatus {
        requestPermissionCallCount += 1
        return .authorized
    }

    func releaseCurrentStatus() {
        continuation?.resume(returning: .authorized)
        continuation = nil
    }
}

private actor SuspendingRequestPermissionClient: CameraPermissionClient {
    private var continuation: CheckedContinuation<CameraPermissionStatus, Never>?
    private(set) var requestPermissionCallCount = 0

    func currentStatus() async -> CameraPermissionStatus {
        .notDetermined
    }

    func requestPermission() async -> CameraPermissionStatus {
        requestPermissionCallCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func releaseRequestPermission(with status: CameraPermissionStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<64 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}
