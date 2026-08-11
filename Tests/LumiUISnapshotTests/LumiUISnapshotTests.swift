import XCTest
import LumiDomain
@testable import LumiPresentation
import LumiUI

/// Pixel-based M3.4b regression matrix for the vector Avatar renderer.
///
/// These tests intentionally render the pure `LumiAvatarView` rather than
/// `AnimatedLumiAvatarView`: all time, seed, event progress and amplitude are
/// supplied by the matrix factory, so a test never depends on wall-clock time
/// or SwiftUI's animation scheduler.
@MainActor
final class LumiUISnapshotTests: XCTestCase {
    func testBaseStatesMatrix() throws {
        try SnapshotVerifier.verify(.baseStates, tiles: SnapshotMatrixFactory.baseStates())
    }

    func testEventSemanticsMatrix() throws {
        try SnapshotVerifier.verify(.events, tiles: SnapshotMatrixFactory.events())
    }

    func testAudioAndReducedMotionMatrix() throws {
        try SnapshotVerifier.verify(.audioAndAccessibility, tiles: SnapshotMatrixFactory.audioAndAccessibility())
    }

    func testVisualPrimitivesAndThemesMatrix() throws {
        try SnapshotVerifier.verify(.primitivesAndThemes, tiles: SnapshotMatrixFactory.primitivesAndThemes())
    }
}

private enum SnapshotMatrixFactory {
    private static let mapper = AvatarStateMapper()
    private static let snapshotSeed: UInt64 = 0x4C554D495F4D335B
    private static let amplitudeTime: TimeInterval = 1.25

    static func baseStates() -> [SnapshotTile] {
        [
            tile("idle", .idle),
            tile("detected-left", .detected(direction: .left)),
            tile("detected-center", .detected(direction: .center)),
            tile("detected-right", .detected(direction: .right)),
            tile("rotating", .rotating),
            tile("recognizing", .recognizing),
            tile("greeting", .greeting),
            tile("listening", .listening),
            tile("thinking", .thinking),
            tile("speaking", .speaking),
            tile("encouraging", .encouraging),
            tile("reminding", .reminding),
            tile("confused", .confused),
            tile("offline", .offline),
        ]
    }

    static func events() -> [SnapshotTile] {
        AvatarEventCommand.allCases.map { command in
            let base = mapper.map(.greeting)
            let state = composed(
                base: base,
                event: command,
                progress: 0.50,
                reducedMotion: false
            )
            return SnapshotTile(
                label: "event-\(command.snapshotLabel)",
                state: state,
                theme: .light
            )
        }
    }

    static func audioAndAccessibility() -> [SnapshotTile] {
        let listening = composed(
            base: mapper.map(.listening),
            processedAmplitude: 0.65,
            reducedMotion: false
        )
        let speaking = composed(
            base: mapper.map(.speaking),
            processedAmplitude: 0.65,
            reducedMotion: false
        )
        let greetingReduced = composed(
            base: mapper.map(.greeting),
            reducedMotion: true
        )
        let encouragingReduced = composed(
            base: mapper.map(.encouraging),
            reducedMotion: true
        )
        let eventReduced = composed(
            base: mapper.map(.greeting),
            event: .goalAchieved,
            progress: 0.50,
            reducedMotion: true
        )
        let offlineReduced = composed(
            base: mapper.map(.offline),
            reducedMotion: true
        )

        return [
            SnapshotTile(label: "listening-amp-0.65", state: listening, theme: .light),
            SnapshotTile(label: "speaking-amp-0.65", state: speaking, theme: .light),
            SnapshotTile(label: "greeting-reduced-motion", state: greetingReduced, theme: .light),
            SnapshotTile(label: "encouraging-reduced-motion", state: encouragingReduced, theme: .light),
            SnapshotTile(label: "goal-achieved-reduced", state: eventReduced, theme: .light),
            SnapshotTile(label: "offline-reduced-motion", state: offlineReduced, theme: .light),
        ]
    }

    static func primitivesAndThemes() -> [SnapshotTile] {
        let idle = mapper.map(.idle)
        let open = AvatarVisualState(
            eyeOpenAmount: 1,
            highlightIntensity: idle.highlightIntensity,
            softGlossOpacity: idle.softGlossOpacity,
            blushOpacity: idle.blushOpacity,
            mouthStyle: idle.mouthStyle,
            sparkleIntensity: idle.sparkleIntensity,
            transition: idle.transition
        )
        let half = AvatarVisualState(
            eyeOpenAmount: 0.5,
            highlightIntensity: idle.highlightIntensity,
            softGlossOpacity: idle.softGlossOpacity,
            blushOpacity: idle.blushOpacity,
            mouthStyle: idle.mouthStyle,
            sparkleIntensity: idle.sparkleIntensity,
            transition: idle.transition
        )
        let closed = AvatarVisualState(
            eyeOpenAmount: 0,
            highlightIntensity: idle.highlightIntensity,
            softGlossOpacity: idle.softGlossOpacity,
            blushOpacity: idle.blushOpacity,
            mouthStyle: idle.mouthStyle,
            sparkleIntensity: idle.sparkleIntensity,
            transition: idle.transition
        )
        let highlightsOn = AvatarVisualState(
            eyeOpenAmount: idle.eyeOpenAmount,
            highlightIntensity: 1,
            highlightScale: 1.10,
            softGlossOpacity: 1,
            blushOpacity: idle.blushOpacity,
            mouthStyle: idle.mouthStyle,
            sparkleIntensity: idle.sparkleIntensity,
            transition: idle.transition
        )
        let greeting = mapper.map(.greeting)

        return [
            SnapshotTile(label: "eyelid-open", state: open, theme: .light),
            SnapshotTile(label: "eyelid-half", state: half, theme: .light),
            SnapshotTile(label: "eyelid-closed", state: closed, theme: .light),
            SnapshotTile(label: "eyelid-happy-curve", state: greeting, theme: .light),
            SnapshotTile(label: "highlights-baseline", state: idle, theme: .lavender),
            SnapshotTile(label: "highlights-on", state: highlightsOn, theme: .lavender),
            SnapshotTile(label: "theme-light", state: greeting, theme: .light),
            SnapshotTile(label: "diagnostic-dark-contrast", state: greeting, theme: .dark),
        ]
    }

    private static func tile(_ label: String, _ state: AssistantState) -> SnapshotTile {
        SnapshotTile(
            label: label,
            state: composed(base: mapper.map(state)),
            theme: .light
        )
    }

    private static func composed(
        base: AvatarVisualState,
        event: AvatarEventCommand? = nil,
        progress: Double = 0,
        processedAmplitude: Double = 0,
        reducedMotion: Bool = false
    ) -> AvatarVisualState {
        var rng = SeededGenerator(seed: snapshotSeed)
        let schedule = BlinkSchedule(using: &rng)
        let active: ActiveEvent? = event.map {
            ActiveEvent(kind: $0, startTime: 0)
        }
        let time: TimeInterval
        if let event {
            time = EventLayer.duration(for: event) * progress
        } else {
            time = amplitudeTime
        }
        return AvatarCompositor.compose(
            base: base,
            at: time,
            blinkSchedule: schedule,
            activeEvent: active,
            processedAmplitude: processedAmplitude,
            reducedMotion: reducedMotion
        )
    }
}
