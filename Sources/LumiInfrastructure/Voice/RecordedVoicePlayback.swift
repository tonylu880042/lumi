import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The eight owner-approved marin audition clips shipped with Lumi.
/// Selection and triggering remain outside this boundary.
public enum RecordedVoiceClip: String, CaseIterable, Equatable, Sendable {
    case welcome01 = "01-welcome"
    case welcome02 = "02-welcome"
    case welcome03 = "03-welcome"
    case returning04 = "04-returning"
    case returning05 = "05-returning"
    case returning06 = "06-returning"
    case goodbye07 = "07-goodbye"
    case goodbye08 = "08-goodbye"

    public var resource: RecordedVoiceResource {
        RecordedVoiceResource(name: rawValue)
    }
}

/// A bundled clip reference. Raw audio bytes never cross this boundary.
public struct RecordedVoiceResource: Equatable, Sendable {
    public let name: String
    public let fileExtension: String

    public init(name: String, fileExtension: String = "wav") {
        self.name = name
        self.fileExtension = fileExtension
    }

    public var fileName: String { "\(name).\(fileExtension)" }

    public func url() -> URL? {
        url(in: Bundle.module)
    }

    public func url(in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension)
    }
}

/// Infrastructure adapter for a concrete AVFoundation or test player.
/// Returning from `play` means playback completed; cancellation is requested
/// through `stop` by `RecordedVoicePlayback`.
public protocol RecordedVoicePlayer: Sendable {
    func play(_ clip: RecordedVoiceClip, resource: RecordedVoiceResource) async throws
    func stop() async
}

public enum RecordedVoicePlaybackError: Error, Equatable, Sendable {
    case alreadyPlaying
    case invalidResource
    case playbackFailed
}

/// Provider-neutral completion and cancellation boundary for one clip.
public actor RecordedVoicePlayback: Sendable {
    private let player: any RecordedVoicePlayer
    private var activeGeneration: UInt64?
    private var stoppingGeneration: UInt64?
    private var stopTask: Task<Void, Never>?
    private var nextGeneration: UInt64 = 0

    public init(player: any RecordedVoicePlayer) {
        self.player = player
    }

    public func play(_ clip: RecordedVoiceClip) async throws {
        try Task.checkCancellation()
        guard activeGeneration == nil, stoppingGeneration == nil else {
            throw RecordedVoicePlaybackError.alreadyPlaying
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        let resource = clip.resource
        let cancellationStop = RecordedVoiceCancellationTask()
        defer {
            if activeGeneration == generation { activeGeneration = nil }
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await player.play(clip, resource: resource)
                try Task.checkCancellation()
            }, onCancel: {
                let stopTask = Task { [weak self] in
                    guard let self else { return }
                    await self.cancel(generation: generation)
                }
                Task { await cancellationStop.install(stopTask) }
            })
        } catch is CancellationError {
            if Task.isCancelled { await cancellationStop.wait() }
            throw CancellationError()
        }
    }

    public func cancel() async {
        if let generation = activeGeneration {
            await cancel(generation: generation)
        } else if let stopTask {
            await stopTask.value
        }
    }

    private func cancel(generation: UInt64) async {
        guard activeGeneration == generation else { return }
        if let stopTask, stoppingGeneration == generation {
            await stopTask.value
            return
        }

        stoppingGeneration = generation
        let player = player
        let stopTask = Task { await player.stop() }
        self.stopTask = stopTask
        await stopTask.value
        if stoppingGeneration == generation {
            stoppingGeneration = nil
            self.stopTask = nil
        }
    }
}

private actor RecordedVoiceCancellationTask {
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func install(_ task: Task<Void, Never>) {
        self.task = task
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        if let task {
            await task.value
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        if let task {
            await task.value
        }
    }
}

#if canImport(AVFoundation)
/// A small MainActor-owned playback seam. The concrete AVAudioPlayer driver
/// only reports lifecycle completion; session category and route remain owned
/// by the existing realtime audio-session composition.
enum RecordedVoicePlayerDriverCompletion: Sendable {
    case finished
    case completionFailed
    case decodeFailed
}

@MainActor
protocol RecordedVoicePlayerDriver: AnyObject {
    func start(
        url: URL,
        completion: @escaping (RecordedVoicePlayerDriverCompletion) -> Void
    ) throws
    func stop()
}

/// AVFoundation adapter for one bundled clip. All mutable playback state and
/// delegate delivery are serialized on MainActor; no audio session is changed.
@MainActor
public final class AVFoundationRecordedVoicePlayer: NSObject, RecordedVoicePlayer {
    private let driver: any RecordedVoicePlayerDriver
    private var activeGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var completion: CheckedContinuation<Void, any Error>?

    public override init() {
        driver = AVAudioPlayerDriver()
        super.init()
    }

    init(driver: any RecordedVoicePlayerDriver) {
        self.driver = driver
        super.init()
    }

    public func play(_ clip: RecordedVoiceClip, resource: RecordedVoiceResource) async throws {
        try Task.checkCancellation()
        guard let url = resource.url() else {
            throw RecordedVoicePlaybackError.invalidResource
        }
        guard activeGeneration == nil else {
            throw RecordedVoicePlaybackError.alreadyPlaying
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        defer {
            if activeGeneration == generation {
                activeGeneration = nil
                completion = nil
            }
        }

        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard activeGeneration == generation, !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    completion = continuation
                    do {
                        try driver.start(url: url) { [weak self] result in
                            self?.complete(generation: generation, result: result)
                        }
                    } catch {
                        finish(generation: generation, error: RecordedVoicePlaybackError.playbackFailed)
                    }
                }
                try Task.checkCancellation()
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.stop(generation: generation)
                }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RecordedVoicePlaybackError {
            throw error
        } catch {
            throw RecordedVoicePlaybackError.playbackFailed
        }
    }

    public func stop() async {
        guard let generation = activeGeneration else { return }
        stop(generation: generation)
    }

    private func stop(generation: UInt64) {
        finish(generation: generation, error: CancellationError())
    }

    private func complete(
        generation: UInt64,
        result: RecordedVoicePlayerDriverCompletion
    ) {
        switch result {
        case .finished:
            finish(generation: generation, error: nil)
        case .completionFailed, .decodeFailed:
            finish(generation: generation, error: RecordedVoicePlaybackError.playbackFailed)
        }
    }

    private func finish(generation: UInt64, error: (any Error)?) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        let pending = completion
        completion = nil
        driver.stop()
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: ())
        }
    }
}

@MainActor
private final class AVAudioPlayerDriver: NSObject, RecordedVoicePlayerDriver {
    private var audioPlayer: AVAudioPlayer?
    private var activeToken: UInt64?
    private var nextToken: UInt64 = 0
    private var delegateProxy: AVAudioPlayerDelegateProxy?
    private var completion: ((RecordedVoicePlayerDriverCompletion) -> Void)?

    func start(
        url: URL,
        completion: @escaping (RecordedVoicePlayerDriverCompletion) -> Void
    ) throws {
        guard audioPlayer == nil else {
            throw RecordedVoicePlaybackError.alreadyPlaying
        }

        nextToken &+= 1
        let token = nextToken
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let proxy = AVAudioPlayerDelegateProxy(token: token) { [weak self] token, result in
                self?.complete(token: token, result: result)
            }
            player.delegate = proxy
            audioPlayer = player
            activeToken = token
            delegateProxy = proxy
            self.completion = completion
            guard player.prepareToPlay(), player.play() else {
                reset()
                throw RecordedVoicePlaybackError.playbackFailed
            }
        } catch let error as RecordedVoicePlaybackError {
            reset()
            throw error
        } catch {
            reset()
            throw RecordedVoicePlaybackError.playbackFailed
        }
    }

    func stop() {
        audioPlayer?.stop()
        reset()
    }

    private func complete(
        token: UInt64,
        result: RecordedVoicePlayerDriverCompletion
    ) {
        guard activeToken == token else { return }
        let pending = completion
        reset()
        pending?(result)
    }

    private func reset() {
        audioPlayer = nil
        activeToken = nil
        delegateProxy = nil
        completion = nil
    }
}

private final class AVAudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
    private let token: UInt64
    private let completion: @MainActor @Sendable (UInt64, RecordedVoicePlayerDriverCompletion) -> Void

    init(
        token: UInt64,
        completion: @escaping @MainActor @Sendable (UInt64, RecordedVoicePlayerDriverCompletion) -> Void
    ) {
        self.token = token
        self.completion = completion
        super.init()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let token = self.token
        let completion = self.completion
        Task { @MainActor in
            completion(token, flag ? .finished : .completionFailed)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let token = self.token
        let completion = self.completion
        Task { @MainActor in
            completion(token, .decodeFailed)
        }
    }
}
#endif
