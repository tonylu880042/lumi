import Foundation
@testable import LumiInfrastructure
import Testing

@Suite("AVFoundation camera permission client")
struct AVFoundationCameraPermissionClientTests {
    @Test("maps each injected authorization status exactly")
    func mapsEveryAuthorizationStatus() async {
        let statuses: [CameraPermissionStatus] = [
            .authorized,
            .denied,
            .restricted,
            .notDetermined
        ]

        for expected in statuses {
            let client = AVFoundationCameraPermissionClient(
                statusReader: { expected },
                accessRequester: { _ in }
            )

            #expect(await client.currentStatus() == expected)
        }
    }

    @Test("re-reads authoritative status after request completion")
    func rereadsStatusInsteadOfTrustingCompletionBool() async {
        let state = PermissionState(.notDetermined)
        let client = AVFoundationCameraPermissionClient(
            statusReader: { state.read() },
            accessRequester: { completion in
                state.update(.denied)
                completion(true)
            }
        )

        let result = await client.requestPermission()

        #expect(result == .denied)
        #expect(state.readCountSnapshot() == 1)
    }

    @Test("uses authorized status even when completion reports false")
    func ignoresFalseCompletionBool() async {
        let state = PermissionState(.notDetermined)
        let client = AVFoundationCameraPermissionClient(
            statusReader: { state.read() },
            accessRequester: { completion in
                state.update(.authorized)
                completion(false)
            }
        )

        #expect(await client.requestPermission() == .authorized)
        #expect(state.readCountSnapshot() == 1)
    }

    @Test("authorize preserves cancellation while request completion is suspended")
    func authorizePreservesCancellation() async throws {
        let state = PermissionState(.notDetermined)
        let gate = RequestGate()
        let client = AVFoundationCameraPermissionClient(
            statusReader: { state.read() },
            accessRequester: { completion in
                Task { await gate.store(completion) }
            }
        )
        let request = Task {
            try await client.authorize()
        }

        #expect(await waitUntil { await gate.hasPending })
        request.cancel()
        state.update(.authorized)
        await gate.resume(with: true)

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
    }
}

private final class PermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CameraPermissionStatus
    private(set) var readCount = 0

    init(_ value: CameraPermissionStatus) {
        self.value = value
    }

    func read() -> CameraPermissionStatus {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return value
    }

    func update(_ value: CameraPermissionStatus) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func readCountSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
}

private actor RequestGate {
    private var completion: (@Sendable (Bool) -> Void)?

    var hasPending: Bool {
        completion != nil
    }

    func store(_ completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func resume(with result: Bool) {
        completion?(result)
        completion = nil
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
