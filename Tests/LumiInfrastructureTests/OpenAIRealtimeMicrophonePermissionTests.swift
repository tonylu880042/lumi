@testable import LumiInfrastructure
import Testing

@Suite("OpenAI Realtime microphone permission")
struct OpenAIRealtimeMicrophonePermissionTests {
    @Test("authorized status allows immediately without requesting")
    func authorizedAllowsWithoutRequesting() async throws {
        let client = FakeMicrophonePermissionClient(
            status: .authorized,
            requestedStatus: .denied
        )

        try await client.authorize()

        #expect(await client.statusCallCount == 1)
        #expect(await client.requestCallCount == 0)
    }

    @Test("denied status rejects immediately without requesting")
    func deniedRejectsWithoutRequesting() async {
        let client = FakeMicrophonePermissionClient(
            status: .denied,
            requestedStatus: .authorized
        )

        await #expect(throws: OpenAIRealtimeMicrophonePermissionError.denied) {
            try await client.authorize()
        }

        #expect(await client.statusCallCount == 1)
        #expect(await client.requestCallCount == 0)
    }

    @Test("undetermined status requests once and allows when granted")
    func undeterminedThenGrantedAllows() async throws {
        let client = FakeMicrophonePermissionClient(
            status: .undetermined,
            requestedStatus: .authorized
        )

        try await client.authorize()
        #expect(await client.statusCallCount == 1)
        #expect(await client.requestCallCount == 1)
    }

    @Test("undetermined status requests once and rejects when denied")
    func undeterminedThenDeniedRejects() async {
        let client = FakeMicrophonePermissionClient(
            status: .undetermined,
            requestedStatus: .denied
        )

        await #expect(throws: OpenAIRealtimeMicrophonePermissionError.denied) {
            try await client.authorize()
        }

        #expect(await client.statusCallCount == 1)
        #expect(await client.requestCallCount == 1)
    }

    @Test("request result is the only status used after an undetermined check")
    func requestIsMadeExactlyOnce() async throws {
        let client = FakeMicrophonePermissionClient(
            status: .undetermined,
            requestedStatus: .authorized
        )

        try await client.authorize()

        #expect(await client.requestCallCount == 1)
    }
}

private actor FakeMicrophonePermissionClient: OpenAIRealtimeMicrophonePermissionStatusClient {
    let status: OpenAIRealtimeMicrophonePermissionStatus
    let requestedStatus: OpenAIRealtimeMicrophonePermissionStatus
    private(set) var statusCallCount = 0
    private(set) var requestCallCount = 0

    init(
        status: OpenAIRealtimeMicrophonePermissionStatus,
        requestedStatus: OpenAIRealtimeMicrophonePermissionStatus
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func currentStatus() async -> OpenAIRealtimeMicrophonePermissionStatus {
        statusCallCount += 1
        return status
    }

    func requestPermission() async -> OpenAIRealtimeMicrophonePermissionStatus {
        requestCallCount += 1
        return requestedStatus
    }
}
