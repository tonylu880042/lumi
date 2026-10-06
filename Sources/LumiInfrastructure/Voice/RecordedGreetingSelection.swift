import LumiApplication
import LumiDomain

/// Chooses one of the owner-approved prerecorded clips for a visitor event.
///
/// The selector is stateful only so consecutive clips in the same greeting
/// class differ. The vitality value chooses the preferred variation; the
/// remaining variations are used in order when that preference would repeat.
public struct RecordedGreetingSelector: Sendable {
    private var lastVisitorClip: RecordedVoiceClip?
    private var lastReturningMemberClip: RecordedVoiceClip?
    private var lastGoodbyeClip: RecordedVoiceClip?
    private var lastVisitorVitality: StoreArrivalVitality?
    private var lastReturningMemberVitality: StoreArrivalVitality?
    private var visitorCursor = 0
    private var returningMemberCursor = 0
    private var goodbyeCursor = 0

    public init() {}

    /// Selects a visitor or returning-member welcome for the current vitality.
    public mutating func select(
        context: VoiceContext,
        vitality: StoreArrivalVitality
    ) -> RecordedVoiceClip {
        switch context {
        case .visitor:
            if lastVisitorClip == nil || lastVisitorVitality != vitality {
                visitorCursor = vitality.preferredClipIndex
            }
            let selection = select(
                from: [.welcome01, .welcome02, .welcome03],
                startIndex: visitorCursor,
                lastClip: lastVisitorClip
            )
            lastVisitorClip = selection.clip
            lastVisitorVitality = vitality
            visitorCursor = (selection.index + 1) % 3
            return selection.clip
        case .returningMember:
            if lastReturningMemberClip == nil || lastReturningMemberVitality != vitality {
                returningMemberCursor = vitality.preferredClipIndex
            }
            let selection = select(
                from: [.returning04, .returning05, .returning06],
                startIndex: returningMemberCursor,
                lastClip: lastReturningMemberClip
            )
            lastReturningMemberClip = selection.clip
            lastReturningMemberVitality = vitality
            returningMemberCursor = (selection.index + 1) % 3
            return selection.clip
        }
    }

    /// Selects a goodbye clip for an explicit caller-triggered playback.
    /// There is intentionally no automatic departure trigger here.
    public mutating func selectGoodbye() -> RecordedVoiceClip {
        let selection = select(
            from: [.goodbye07, .goodbye08],
            startIndex: goodbyeCursor,
            lastClip: lastGoodbyeClip
        )
        lastGoodbyeClip = selection.clip
        goodbyeCursor = (selection.index + 1) % 2
        return selection.clip
    }

    private func select(
        from clips: [RecordedVoiceClip],
        startIndex: Int,
        lastClip: RecordedVoiceClip?
    ) -> (clip: RecordedVoiceClip, index: Int) {
        for offset in 0 ..< clips.count {
            let index = (startIndex + offset) % clips.count
            let clip = clips[index]
            guard clip != lastClip else { continue }
            return (clip, index)
        }

        // A non-empty clip class always has a choice. Keeping this fallback
        // makes the invariant explicit if a future class is reduced to one
        // clip while preserving deterministic behavior.
        let index = startIndex % clips.count
        return (clips[index], index)
    }
}

private extension StoreArrivalVitality {
    var preferredClipIndex: Int {
        switch self {
        case .calm: return 0
        case .happy: return 1
        case .excited: return 2
        }
    }
}

/// Adapter-facing boundary for a selected prerecorded greeting.
///
/// Implementations must preserve cancellation. The required stop hook ends
/// active playback when the Realtime generation is stopped or lost.
public protocol RecordedGreetingPlayer: Sendable {
    func play(context: VoiceContext) async throws
    /// Plays the generic, provider-independent conversational farewell.
    func playGoodbye() async throws
    func stop() async
}

public extension RecordedGreetingPlayer {
    /// Legacy compositions without a dedicated farewell fail closed. The
    /// natural-closing tool is only advertised when the composition explicitly
    /// enables it with a player that implements this operation.
    func playGoodbye() async throws {
        throw RecordedVoicePlaybackError.playbackFailed
    }
}

/// Infrastructure composition of vitality selection and the validated WAV
/// playback adapter. It has no arrival or departure trigger of its own.
public actor RecordedGreetingCoordinator: RecordedGreetingPlayer {
    private let playback: RecordedVoicePlayback
    private let vitalityProvider: @Sendable () async -> StoreArrivalVitality
    private var selector = RecordedGreetingSelector()

    public init(
        playback: RecordedVoicePlayback,
        vitalityProvider: @escaping @Sendable () async -> StoreArrivalVitality
    ) {
        self.playback = playback
        self.vitalityProvider = vitalityProvider
    }

    public func play(context: VoiceContext) async throws {
        let vitality = await vitalityProvider()
        let clip = selector.select(context: context, vitality: vitality)
        try await playback.play(clip)
    }

    /// Ends a conversation without assuming the visitor is leaving the store.
    public func playGoodbye() async throws {
        try await playback.play(.goodbye07)
    }

    public func stop() async {
        await playback.cancel()
    }
}
