# Curves Lumi — Phase 2.2 WebRTC Transport Specification

> Status: Approved
> Implementation status: Complete (automated gates)
> Physical-device status: Deferred
> Date: 2026-08-11
> Decision owner: Curves Lumi Product Owner
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`, `docs/phase-2.2-webrtc-implementation-plan.md`, `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`, `docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md`

## 1. Objective

Phase 2.2 supplies the concrete iOS WebRTC implementation behind the
`OpenAIRealtimeTransport` seam established in Phase 2.1:

```text
OpenAIRealtimeAdapter
↓
OpenAIRealtimeTransport
↓
stasel/WebRTC 151.0.0
↓
OpenAI Realtime API
```

The slice includes:

- a real WebRTC peer connection
- iPad microphone input and remote assistant-audio playback
- the ordered `oai-events` data channel
- ephemeral-client-secret SDP exchange
- Realtime server-event decoding
- provider-default `server_vad`
- one initial proactive greeting
- interruption and deterministic shutdown behavior
- just-in-time microphone permission and voice-chat audio routing

The existing `VoiceSessionPort`, Domain states, coordinator transitions, model
(`gpt-realtime-2.1-mini`), and voice (`marin`) remain unchanged. The App
composition root continues to use `MockVoiceSessionPort` by default. A concrete
credential backend and Live/Mock UI switch are not part of this slice.

Because Phase 2.2 does not provide a real credential source or Live app mode,
physical-iPad conversation-quality testing remains a later Phase 2 acceptance
activity rather than an automated Phase 2.2 completion gate.

## 2. Tech Stack

- Swift 6
- iOS 17+ and macOS 14+ package compatibility
- Swift Package Manager
- `stasel/WebRTC`, exact version `151.0.0`
- `URLSession` for Infrastructure-only SDP signaling
- `AVAudioApplication` and `RTCAudioSession` for microphone authorization and
  voice-chat audio-session configuration
- Swift Testing

The dependency must use an exact requirement:

```swift
.package(
    url: "https://github.com/stasel/WebRTC.git",
    exact: "151.0.0"
)
```

Only `LumiInfrastructure` may depend on the `WebRTC` product. The resolved pin
must be committed. The upstream distribution uses the BSD 3-Clause License and
the binary release publishes iOS-device, iOS-Simulator, and macOS slices.

## 3. Connection Contract

Every fresh transport performs these steps in order:

1. Validate the short-lived client secret. `expiresAt <= now` is expired. Check
   once before microphone authorization and again immediately before the SDP
   request. Do not add an expiry safety margin.
2. Check and, when undetermined, request microphone permission just in time.
   A denial returns a typed error before creating a peer connection, activating
   audio, or making a network request. Existing Application behavior keeps the
   coordinator in the retryable `greeting` state.
3. Configure the iOS audio session for `playAndRecord` and `voiceChat`. Prefer
   the iPad speaker when no external route exists and preserve wired or
   Bluetooth HFP routes when present.
4. Create the WebRTC peer connection.
5. Add one local microphone audio track and enable remote audio playback.
6. Create one ordered data channel named `oai-events`.
7. Create the SDP offer and set it as the local description.
8. POST the offer SDP to `https://api.openai.com/v1/realtime/calls` with the
   exact ephemeral token as a Bearer credential and `Content-Type:
   application/sdp`.
9. Validate a successful HTTP response and set its SDP as the remote answer.
10. When `session.created` arrives, send an ordered `session.update` that
    applies the session instructions, output voice, and
    `session.audio.input.turn_detection` configuration:
    - `type: server_vad`
    - `create_response: true`
    - `interrupt_response: true`
    - omit `threshold`, `prefix_padding_ms`, and `silence_duration_ms` so the
      provider defaults remain in effect
11. On the initial connection only, send one `response.create` after the
    `session.update` to request Lumi's proactive greeting. An automatic
    reconnect must configure the new provider session but must not replay the
    greeting.
12. Publish `sessionCreated` only after the required client events have been
    accepted for sending, allowing the existing adapter to complete
    `VoiceSessionPort.start(context:)` and the coordinator to enter `speaking`.

The data channel is ordered so the provider receives `session.update` before
the initial `response.create`.

## 4. Server Event Contract

Phase 2.2 decodes only the provider events needed by the existing transport
boundary:

| OpenAI server event | `OpenAIRealtimeProviderEvent` |
| --- | --- |
| `session.created` | `.sessionCreated` |
| `input_audio_buffer.speech_started` | `.inputAudioSpeechStarted` |
| `input_audio_buffer.speech_stopped` | `.inputAudioSpeechStopped` |
| `output_audio_buffer.started` | `.outputAudioStarted` |
| `output_audio_buffer.stopped` | `.outputAudioStopped` |
| `output_audio_buffer.cleared` | `.outputAudioCleared` |
| `response.done` with `failed` or `incomplete` status | `.responseFailed` |
| `response.done` with `cancelled` status | ignored as normal interruption |
| `error` | `.error` |
| well-formed future event | `.unknown(type)` |
| malformed JSON or missing `type` | privacy-safe `.error` |

Malformed input must not be retained or copied into errors. Unknown,
well-formed event types remain forward compatible and are ignored by the
existing event mapper.

`OpenAIRealtimeEventMapper` remains responsible for translating these events
into provider-independent `VoiceSessionEvent` values. In particular:

- the initial greeting does not emit a duplicate `.responseReady`
- the first playable response audio is represented by
  `output_audio_buffer.started`
- output start and stop/clear map to payload-free
  `.assistantOutputStarted` / `.assistantOutputEnded` lifecycle events
- speech beginning while output is active emits only
  `.assistantInterrupted`

## 5. Commands

Resolve the exact dependency:

```sh
swift package resolve
```

Run all package tests:

```sh
swift test
```

Build the iOS app for the Simulator without code signing:

```sh
xcodebuild -project App/LumiApp.xcodeproj \
  -scheme LumiApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Both required verification commands must pass before handoff.

## 6. Project Structure

The implemented responsibility layout is:

```text
Package.swift
Package.resolved

Sources/LumiInfrastructure/Voice/
├── OpenAIWebRTCTransport.swift
├── OpenAIRealtimeWebRTCPeerDriver.swift
├── OpenAIRealtimeSDPSignaling.swift
├── OpenAIRealtimeWireEvents.swift
├── OpenAIRealtimeMicrophonePermission.swift
└── OpenAIRealtimeAudioSession.swift

Tests/LumiInfrastructureTests/
├── OpenAIWebRTCTransportTests.swift
├── OpenAIRealtimeSDPSignalingTests.swift
├── OpenAIRealtimeWireEventsTests.swift
├── OpenAIRealtimeMicrophonePermissionTests.swift
├── OpenAIRealtimeWebRTCPeerDriverTests.swift
└── OpenAIRealtimeAudioSessionTests.swift

App/LumiApp.xcodeproj/project.pbxproj
docs/phase-2.2-webrtc-transport.md
docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md
docs/roadmap.md
```

The implementation plan may combine narrowly related files, but the following
responsibilities must remain separable and injectable for deterministic tests:

- transport lifecycle
- WebRTC peer/media driver
- HTTP SDP signaling
- client-event encoding and server-event decoding
- microphone authorization
- audio-session configuration

macOS `swift test` must remain buildable. iOS-only Apple APIs therefore require
platform-isolated concrete implementations while tests use injected fakes.

## 7. Code Style

Use actor isolation for the connection lifecycle, typed privacy-safe errors,
small injected dependencies, and explicit names:

```swift
public enum OpenAIWebRTCTransportError: Error, Equatable, Sendable {
    case expiredClientSecret
    case microphonePermissionDenied
    case signalingRejected(statusCode: Int)
    case invalidRemoteDescription
    case dataChannelUnavailable
}

actor OpenAIWebRTCTransport: OpenAIRealtimeTransport {
    func connect(
        clientSecret: OpenAIRealtimeClientSecret,
        configuration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose
    ) async throws {
        // The concrete actor remains internal to Infrastructure.
    }
}
```

WebRTC delegate callbacks must re-enter actor isolation. Do not solve Swift
concurrency errors by introducing unchecked shared mutable state. Framework
errors are translated at the Infrastructure boundary and never enter Domain.

## 8. Testing Strategy

All production behavior follows RED → GREEN → REFACTOR. Tests use fake
permission, clock, audio-session, peer-driver, data-channel, and HTTP
dependencies; no test may require a real microphone, network connection,
provider credential, or OpenAI session.

Required coverage:

- exact package resolution and macOS/iOS-Simulator compatibility
- expired credential rejection before permission, WebRTC, or network effects
- a credential that expires during permission handling is rejected before SDP
- permission denial creates no RTC or signaling side effect
- SDP URL, method, content type, Bearer authorization, and exact offer body
- typed handling of non-2xx responses, empty answers, and invalid remote SDP
- secrets, SDP, authorization headers, and raw provider payloads do not appear
  in error descriptions
- `session.update` carries `server_vad`, both automatic behavior flags, the
  session instructions, and selected voice without custom VAD thresholds
- exactly one initial `response.create` per Lumi session
- automatic reconnect configures the fresh session without replaying greeting
- all event mappings in section 4, including future and malformed events
- first-playable-audio, output lifecycle, and interruption behavior remain
  compatible with the existing mapper tests
- task cancellation cancels signaling and releases peer, audio, and data-channel
  resources
- repeated `close()` performs cleanup at most once
- callbacks from a closed or superseded generation publish no further events
- the event stream finishes cleanly so the existing adapter can apply its
  single-reconnect policy

The Info.plist build setting must provide this exact usage description in every
App configuration:

```text
Lumi 需要使用麥克風，才能與您進行即時語音互動。
```

## 9. Boundaries

### Always

- Import `WebRTC` only from `LumiInfrastructure`.
- Pin and resolve exact version `151.0.0`.
- Accept only injected short-lived client secrets.
- Treat permission denial and expiry as typed, retryable start failures.
- Test cancellation, idempotent close, and stale callbacks.
- Keep the App's default composition on mocks in this slice.
- Preserve one session-state owner in `AssistantSessionCoordinator`.

### Ask First

- Define the company credential endpoint, app authentication, refresh policy,
  or safety identifier.
- Add a Live/Mock app mode or wire real credentials into the composition root.
- Choose startup, initial-response, inactivity, maximum-session, or return-home
  timeout values.
- Tune VAD threshold, padding, or silence duration.
- Connect real audio amplitude to Presentation or the Avatar.
- Upgrade or replace the WebRTC dependency.
- Change an Application port, Domain state, or user-facing error flow.

### Never

- Put a standard OpenAI API key in the App binary, source, fixtures, logs,
  diagnostics, or errors.
- Log a client secret, Authorization header, SDP, raw audio, or complete
  provider payload.
- Let UI call WebRTC, AVFoundation, or URLSession directly.
- Expose WebRTC or OpenAI types to Application or Domain.
- Introduce a global service singleton.
- Replay the initial greeting after automatic reconnect.
- Add Phase 3 tool calling, member-data access, or hardware control here.

## 10. Out of Scope

- concrete company credential backend
- App Live/Mock switching
- production deployment
- product timeout policies
- real audio-amplitude delivery to the Avatar
- VAD threshold tuning
- Phase 3 tool calling
- final physical-iPad acceptance for permission presentation, speaker routing,
  wired/Bluetooth routes, echo cancellation, barge-in latency, Taiwan Mandarin
  quality, and interruption recovery

## 11. Success Criteria and Completion Evidence

Phase 2.2 is complete when:

- `stasel/WebRTC` exact `151.0.0` is integrated and resolved.
- The concrete transport performs ephemeral-token WebRTC signaling with OpenAI.
- A local microphone track and remote assistant-audio playback are configured.
- The data channel sends session/VAD/greeting events and decodes the required
  provider events.
- The initial greeting is requested exactly once and never replayed on the
  adapter's automatic reconnect.
- Permission denial and expired credentials produce no RTC or network side
  effects.
- Interruption, response readiness, one reconnect, and shutdown preserve
  ADR-0007 semantics.
- The App continues to run with mocks and requires no secret for automated
  verification.
- `swift test` and the unsigned iOS Simulator build pass.
- Domain, Application, Presentation, and UI boundaries remain unchanged.

Automated completion evidence recorded on 2026-08-11:

- `stasel/WebRTC` is resolved at exact version `151.0.0`, revision
  `19aa8c1fc7120d50df987b7111f42d5024df3d54`; the upstream binary checksum is
  `64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`.
- `swift test --filter OpenAIWebRTCTransportTests` passed 21 tests in 1 suite.
- Swift Testing passed 247 tests in 16 suites, and XCTest passed 4 snapshot
  tests.
- The unsigned iOS Simulator `xcodebuild` completed successfully with
  `CODE_SIGNING_ALLOWED=NO`.
- These checks use deterministic fakes and compile the production integration;
  no real credential, OpenAI network session, microphone, or physical device
  was exercised.
- The App composition remains on `MockVoiceSessionPort` by default. A concrete
  credential backend and Live/Mock switch remain out of scope.
- Physical-iPad validation remains deferred for permission presentation,
  speaker and wired/Bluetooth route behavior, echo cancellation, barge-in,
  interruption recovery, and Taiwan Mandarin conversation quality.

## 12. Open Questions

None.
