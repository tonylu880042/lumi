import Foundation
import Testing
@testable import LumiInfrastructure

@Suite("Recorded voice playback")
struct RecordedVoicePlaybackTests {
    @Test("catalog exposes exactly the eight validated clips")
    func catalogContainsValidatedClips() throws {
        #expect(RecordedVoiceClip.allCases.count == 8)
        #expect(RecordedVoiceClip.allCases.map(\.rawValue) == [
            "01-welcome", "02-welcome", "03-welcome",
            "04-returning", "05-returning", "06-returning",
            "07-goodbye", "08-goodbye",
        ])
    }

    @Test("every catalog clip resolves to a bundled WAV")
    func everyClipResolvesToBundledResource() {
        for clip in RecordedVoiceClip.allCases {
            #expect(clip.resource.url() != nil)
            #expect(clip.resource.fileName.hasSuffix(".wav"))
        }
    }

    @Test("play waits for provider-neutral completion")
    func playWaitsForCompletion() async throws {
        let player = ControlledRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let task = Task { try await playback.play(.welcome01) }

        await player.waitForPlay()
        #expect(!task.isCancelled)
        await player.finish()
        try await task.value
        #expect(await player.played == [.welcome01])
    }

    @Test("cancellation stops playback and preserves CancellationError")
    func cancellationStopsPlayback() async {
        let player = ControlledRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let task = Task { try await playback.play(.welcome01) }

        await player.waitForPlay()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await player.stopCount == 1)
    }

    @Test("overlapping play requests fail without replacing the active clip")
    func overlappingPlayIsRejected() async throws {
        let player = ControlledRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let first = Task { try await playback.play(.welcome01) }
        await player.waitForPlay()

        await #expect(throws: RecordedVoicePlaybackError.alreadyPlaying) {
            try await playback.play(.welcome02)
        }
        first.cancel()
        await player.finish()
        _ = try? await first.value
        #expect(await player.played == [.welcome01])
    }

    @Test("a cancelled play stays active until its gated stop finishes")
    func cancellationWaitsForGatedStop() async throws {
        let player = GatedRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let first = Task { try await playback.play(.welcome01) }

        await player.waitForPlay()
        first.cancel()
        await player.waitForStopRequest()

        #expect(await player.stopFinished == false)
        await #expect(throws: RecordedVoicePlaybackError.alreadyPlaying) {
            try await playback.play(.welcome02)
        }

        await player.releaseStop()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let second = Task { try await playback.play(.welcome02) }
        await player.waitForPlay()
        await player.finish()
        try await second.value
        #expect(await player.played == [.welcome01, .welcome02])
    }

    @Test("task cancellation and explicit stop share one pending teardown")
    func concurrentCancellationStopsOnce() async throws {
        let player = GatedRecordedVoicePlayer()
        let playback = RecordedVoicePlayback(player: player)
        let first = Task { try await playback.play(.welcome01) }
        await player.waitForPlay()
        first.cancel()
        await player.waitForStopRequest()

        let explicitStop = Task { await playback.cancel() }
        // Keep teardown suspended while both independent cancellation paths
        // have an opportunity to run. No audio or production timer is used.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await player.stopCount == 1)
        await #expect(throws: RecordedVoicePlaybackError.alreadyPlaying) {
            try await playback.play(.welcome02)
        }

        await player.releaseStop()
        await explicitStop.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await player.stopCount == 1)
    }

#if canImport(AVFoundation)
    @Test("backend rejects a missing resource before starting its driver")
    @MainActor
    func backendRejectsMissingResource() async {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let missing = RecordedVoiceResource(name: "missing-recorded-voice")

        await #expect(throws: RecordedVoicePlaybackError.invalidResource) {
            try await player.play(.welcome01, resource: missing)
        }
        #expect(driver.startCount == 0)
    }

    @Test("backend maps driver start failures to playback failure")
    @MainActor
    func backendMapsStartFailure() async {
        let driver = ControlledRecordedVoiceDriver()
        driver.startError = true
        let player = AVFoundationRecordedVoicePlayer(driver: driver)

        await #expect(throws: RecordedVoicePlaybackError.playbackFailed) {
            try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource)
        }
        #expect(driver.startCount == 1)
    }

    @Test("backend maps an unsuccessful completion to playback failure")
    @MainActor
    func backendMapsUnsuccessfulCompletion() async {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let task = Task { try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource) }

        await driver.waitForStart()
        driver.complete(.completionFailed)

        await #expect(throws: RecordedVoicePlaybackError.playbackFailed) {
            try await task.value
        }
    }

    @Test("backend maps a delayed decode failure to playback failure")
    @MainActor
    func backendMapsDecodeFailure() async {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let task = Task { try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource) }

        await driver.waitForStart()
        driver.complete(.decodeFailed)

        await #expect(throws: RecordedVoicePlaybackError.playbackFailed) {
            try await task.value
        }
    }

    @Test("backend ignores an old callback after a later play starts")
    @MainActor
    func backendIgnoresOldCallbackAfterNewPlayStarts() async throws {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let first = Task { try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource) }

        await driver.waitForStart()
        let firstRequest = try #require(driver.activeRequestID)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let second = Task { try await player.play(.welcome02, resource: RecordedVoiceClip.welcome02.resource) }
        await driver.waitForStart()
        let secondRequest = try #require(driver.activeRequestID)
        #expect(secondRequest != firstRequest)

        driver.complete(.finished, requestID: firstRequest)
        #expect(!second.isCancelled)
        driver.complete(.finished, requestID: secondRequest)
        try await second.value
    }

    @Test("backend pre-cancellation does not start its driver")
    @MainActor
    func backendPreCancellationDoesNotStartDriver() async {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let task = Task { try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(driver.startCount == 0)
    }

    @Test("backend rejects overlapping requests without replacing the active one")
    @MainActor
    func backendRejectsOverlappingPlay() async throws {
        let driver = ControlledRecordedVoiceDriver()
        let player = AVFoundationRecordedVoicePlayer(driver: driver)
        let first = Task { try await player.play(.welcome01, resource: RecordedVoiceClip.welcome01.resource) }

        await driver.waitForStart()
        await #expect(throws: RecordedVoicePlaybackError.alreadyPlaying) {
            try await player.play(.welcome02, resource: RecordedVoiceClip.welcome02.resource)
        }
        #expect(driver.startCount == 1)
        driver.complete(.finished)
        try await first.value
    }
#endif
}

private actor ControlledRecordedVoicePlayer: RecordedVoicePlayer {
    private(set) var played: [RecordedVoiceClip] = []
    private(set) var stopCount = 0
    private var playContinuation: CheckedContinuation<Void, any Error>?

    func play(_ clip: RecordedVoiceClip, resource: RecordedVoiceResource) async throws {
        played.append(clip)
        try await withCheckedThrowingContinuation { continuation in
            playContinuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
        playContinuation?.resume(throwing: CancellationError())
        playContinuation = nil
    }

    func waitForPlay() async {
        while playContinuation == nil { await Task.yield() }
    }

    func finish() {
        playContinuation?.resume(returning: ())
        playContinuation = nil
    }
}

private actor GatedRecordedVoicePlayer: RecordedVoicePlayer {
    private(set) var played: [RecordedVoiceClip] = []
    private(set) var stopCount = 0
    private(set) var stopFinished = false
    private var playContinuation: CheckedContinuation<Void, any Error>?
    private var stopGates: [CheckedContinuation<Void, Never>] = []
    private var stopReleased = false

    func play(_ clip: RecordedVoiceClip, resource: RecordedVoiceResource) async throws {
        played.append(clip)
        stopFinished = false
        stopReleased = false
        try await withCheckedThrowingContinuation { continuation in
            playContinuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
        playContinuation?.resume(throwing: CancellationError())
        playContinuation = nil
        if !stopReleased {
            await withCheckedContinuation { continuation in
                stopGates.append(continuation)
            }
        }
        stopFinished = true
    }

    func waitForPlay() async {
        while playContinuation == nil {
            await Task.yield()
        }
    }

    func waitForStopRequest() async {
        while stopGates.isEmpty {
            await Task.yield()
        }
    }

    func releaseStop() {
        stopReleased = true
        let pending = stopGates
        stopGates.removeAll()
        for gate in pending { gate.resume() }
    }

    func finish() {
        playContinuation?.resume(returning: ())
        playContinuation = nil
    }
}

#if canImport(AVFoundation)
@MainActor
private final class ControlledRecordedVoiceDriver: RecordedVoicePlayerDriver {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeRequestID: Int?
    var startError = false

    private var nextRequestID = 0
    private var completions: [Int: (RecordedVoicePlayerDriverCompletion) -> Void] = [:]

    func start(
        url: URL,
        completion: @escaping (RecordedVoicePlayerDriverCompletion) -> Void
    ) throws {
        startCount += 1
        guard !startError else {
            throw RecordedVoicePlaybackError.playbackFailed
        }
        let requestID = nextRequestID
        nextRequestID += 1
        activeRequestID = requestID
        completions[requestID] = completion
    }

    func stop() {
        stopCount += 1
        activeRequestID = nil
    }

    func complete(
        _ result: RecordedVoicePlayerDriverCompletion,
        requestID: Int? = nil
    ) {
        guard let requestID = requestID ?? activeRequestID,
              let completion = completions[requestID]
        else { return }
        completion(result)
    }

    func waitForStart() async {
        while activeRequestID == nil {
            await Task.yield()
        }
    }
}
#endif
