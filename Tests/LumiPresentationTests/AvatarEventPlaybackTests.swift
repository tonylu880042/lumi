import Foundation
import Testing
@testable import LumiPresentation

@Test("AvatarEventPlayback 的新事件會立即取代舊事件")
func playbackReplacesActiveEvent() {
    var playback = AvatarEventPlayback()
    playback.trigger(.playful, at: 10)
    #expect(playback.activeEvent == ActiveEvent(kind: .playful, startTime: 10))

    playback.trigger(.memberRecognized, at: 10.2)
    #expect(playback.activeEvent == ActiveEvent(kind: .memberRecognized, startTime: 10.2))
}

@Test("AvatarEventPlayback 支援 explicit cancel")
func playbackCanCancelExplicitly() {
    var playback = AvatarEventPlayback()
    playback.trigger(.error, at: 2)
    playback.cancel()
    #expect(playback.activeEvent == nil)
}

@Test("AvatarEventPlayback 在 duration 到達時清除並回報 true")
func playbackRemovesExpiredEventAtDurationBoundary() {
    var playback = AvatarEventPlayback()
    playback.trigger(.playful, at: 10)
    let duration = EventLayer.duration(for: .playful)

    #expect(playback.removeExpired(at: 10 + duration) == true)
    #expect(playback.activeEvent == nil)
}

@Test("AvatarEventPlayback 可用 nonmutating isExpired 查詢邊界且不改變 activeEvent")
func playbackReportsExpiryWithoutMutating() {
    var playback = AvatarEventPlayback()
    playback.trigger(.playful, at: 10)
    let duration = EventLayer.duration(for: .playful)

    #expect(playback.isExpired(at: 10 + duration))
    #expect(playback.activeEvent == ActiveEvent(kind: .playful, startTime: 10))
    #expect(!playback.isExpired(at: 10 + duration - 0.001))
    #expect(!playback.isExpired(at: 9.999))
}

@Test("AvatarEventPlayback 對未到期與尚未開始的事件保留 activeEvent 並回報 false")
func playbackKeepsUnexpiredAndFutureEvents() {
    var playback = AvatarEventPlayback()
    playback.trigger(.goalAchieved, at: 10)
    let duration = EventLayer.duration(for: .goalAchieved)

    #expect(playback.removeExpired(at: 10 + duration - 0.001) == false)
    #expect(playback.activeEvent == ActiveEvent(kind: .goalAchieved, startTime: 10))

    playback.trigger(.error, at: 20)
    #expect(playback.removeExpired(at: 19.999) == false)
    #expect(playback.activeEvent == ActiveEvent(kind: .error, startTime: 20))
}

@Test("AvatarEventPlayback 是 Equatable 且可跨 concurrency 邊界傳遞")
func playbackIsEquatableAndSendable() {
    let first = AvatarEventPlayback()
    let second = AvatarEventPlayback()
    #expect(first == second)
    requireSendable(first)
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
