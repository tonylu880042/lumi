# Curves Lumi — Phase 2.2 WebRTC Implementation Plan

> Plan status: Complete (automated gates)
> Task-list status: Complete
> Physical-device status: Deferred
> Date: 2026-08-11
> Decision owner: Curves Lumi Product Owner
> Related: `docs/phase-2.2-webrtc-transport.md`, `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`, `docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md`

## 1. Overview

Phase 2.2 replaces the injected test transport with an available concrete iOS
WebRTC implementation while leaving `VoiceSessionPort`, Domain state,
Presentation, UI, and the App's default mock composition unchanged.

Implementation remains incremental and test first. Each slice begins with a
test that fails for the intended missing behavior, adds only the minimum
production behavior needed to pass, and ends green before the next slice.

## 2. Dependency Graph

```text
Exact stasel/WebRTC dependency
└── WebRTC peer/media driver

Connection-purpose contract
└── Initial greeting versus reconnect behavior

Wire event codec ───────┐
SDP signaling client ──┤
Microphone permission ─┤
Audio-session control ─┼── OpenAIWebRTCTransport actor
WebRTC driver ─────────┘             │
                                     └── existing OpenAIRealtimeAdapter
```

The binary dependency and connection-purpose seam are verified first. Pure
wire and signaling behavior follows, then platform media integration, and only
then the lifecycle actor that composes every collaborator.

## 2.1 Approved Task List

The following task list is approved for execution. Each task is completed
against the Phase 2.2 transport specification and its named checkpoint before
the next dependent task begins.

### Task 1 — Exact WebRTC dependency pin (Complete)

- Add `https://github.com/stasel/WebRTC.git` at exact version `151.0.0`.
- Resolve and include a lock state that verifies the exact WebRTC
  version/revision; separately verify the upstream binary checksum against the
  official `151.0.0` manifest.
- Keep the `WebRTC` product dependency on `LumiInfrastructure` only; no inner
  layer or test target imports the framework directly.
- Acceptance: `swift package resolve`, macOS package compilation, and the
  unsigned iOS Simulator build resolve the same exact pin.

### Task 2 — Explicit connection purpose (Complete)

- Add the Infrastructure-owned `OpenAIRealtimeConnectionPurpose` with
  `initial` and `reconnect` cases.
- Make the purpose a required argument of `OpenAIRealtimeTransport.connect`.
- Have `OpenAIRealtimeAdapter` pass `initial` for the first connection and
  `reconnect` for its one automatic retry; update all test fakes and assert the
  sequence without exposing the type to Application or Domain.
- Acceptance: adapter tests prove one initial purpose, one reconnect purpose,
  and no third connection or replayed greeting.

### Checkpoint A — Dependency and contract gate (Complete)

- The exact resolved dependency and target ownership are inspectable.
- Purpose-contract tests and all existing package tests pass.
- The unsigned iOS Simulator build succeeds with the binary linked.
- `git diff --check` is clean and no layer outside Infrastructure imports
  `WebRTC` or the connection-purpose type.

### Task 3 — Realtime wire codec (Complete)

- Implement Infrastructure-only encoders for `session.update` and
  `response.create`.
- Implement privacy-safe decoding for the approved server-event subset,
  preserving well-formed future events as `.unknown(type)` and mapping
  malformed input to a redacted `.error`.
- Encode provider-default `server_vad` with `create_response` and
  `interrupt_response` enabled while omitting unapproved tuning values.
- Acceptance: deterministic codec tests cover every approved event, unknown
  events, malformed payloads, ordering data, and absence of secret/SDP/raw
  payloads in errors.

### Task 4 — Ephemeral-token SDP signaling (Complete)

- Add an injected, Foundation-only signaling client for
  `POST https://api.openai.com/v1/realtime/calls`.
- Send the exact offer SDP with `Content-Type: application/sdp` and the exact
  ephemeral token as a Bearer credential.
- Validate non-2xx responses, empty answers, invalid remote SDP, and
  cancellation with typed, privacy-safe errors.
- Acceptance: fake-URLSession tests verify URL, method, headers, body,
  cancellation, validation, and redaction without real network access.

### Checkpoint B — Wire and signaling gate (Complete)

- Wire and signaling tests pass deterministically without microphone, network,
  or real credentials.
- Provider-default VAD JSON omits all unapproved threshold, padding, and
  silence-duration fields.
- Unknown events remain forward compatible and malformed data cannot leak.
- The full package suite remains green.

### Task 5 — Just-in-time microphone permission (Complete)

- Add an injected permission client that checks status immediately before
  startup and requests only when undetermined.
- Return the approved typed denial error before peer creation, audio-session
  activation, or signaling; preserve retryable Application behavior.
- Acceptance: fake permission tests cover granted, undetermined/granted,
  undetermined/denied, and already-denied paths with zero forbidden side
  effects.

### Task 6 — Voice-chat audio session (Complete)

- Add an injected iOS audio-session controller for `playAndRecord` and
  `voiceChat`.
- Prefer the built-in iPad speaker only when no external route exists and
  preserve wired or Bluetooth HFP routes.
- Keep Apple-only implementation platform-isolated so macOS tests compile.
- Acceptance: audio-session fakes verify category, mode, route policy,
  activation, and cleanup intent.

### Task 7 — WebRTC peer/media driver (Complete)

- Hide `WebRTC` behind an Infrastructure peer/media driver.
- Create the peer, one local microphone track, remote playback, one ordered
  `oai-events` data channel, SDP offer/answer handling, delegate forwarding,
  and cleanup through injectable boundaries.
- Re-enter actor isolation for callbacks and do not introduce unchecked shared
  mutable state.
- Acceptance: driver tests create the media/data offer and cover delegate
  events and cleanup without real network or microphone input.

### Checkpoint C — Platform media gate (Complete)

- Permission denial produces no peer, media, audio, or signaling side effect.
- Audio-session intent and route policy are verified with fakes.
- The concrete driver creates an audio/data offer without external effects.
- macOS tests and the unsigned iOS Simulator build both pass.

### Task 8 — Startup ordering and credential expiry (Complete)

- Compose injected clock, permission, audio, peer, and signaling collaborators
  with ordered startup effects.
- Reject `expiresAt <= now` before permission and check again immediately
  before SDP signaling, without adding a safety margin.
- Acceptance: tests cover already-expired secrets and expiry during permission,
  proving no forbidden side effects or secret leakage.

### Task 9 — Provider handshake and event stream (Complete)

- On each fresh provider session, wait for `session.created`, send the ordered
  `session.update`, and publish readiness only after required client events are
  accepted for sending.
- Send exactly one initial `response.create` for `initial` purpose and none
  for `reconnect`.
- Decode and publish the approved provider event stream while preserving the
  existing mapper semantics for first playable audio and interruption.
- Acceptance: handshake tests prove ordering, initial-only greeting, event
  mapping, forward-compatible unknowns, malformed errors, and clean stream
  completion.

### Task 10 — Cancellation and deterministic shutdown (Complete)

- Make task cancellation cancel signaling and release peer, audio, and data
  channel resources.
- Make `close()` idempotent, finish the event stream cleanly, and suppress
  callbacks from closed or superseded generations.
- Preserve the adapter's one-reconnect policy and typed failure behavior.
- Acceptance: lifecycle tests cover cancellation, repeated close, stale
  callbacks, reconnect failure, and no post-close events.

### Checkpoint D — End-to-end transport gate (Complete)

- All Phase 2.2 transport acceptance tests pass without microphone, network, or
  secrets.
- Existing mapper and adapter regression tests remain green with only the
  explicit purpose contract added.
- The complete package suite and unsigned iOS Simulator build pass.

### Task 11 — Final review and documentation (Complete)

- Review the complete diff for Clean Architecture boundaries, privacy-safe
  diagnostics, Swift concurrency isolation, dependency ownership, and
  unnecessary complexity.
- Confirm the App composition remains on mocks and no deferred credential,
  timeout, VAD tuning, amplitude, or Phase 3 behavior was added.
- Record completion evidence and deferred physical-iPad validation in the
  feature spec, this plan, applicable ADR consequences, and roadmap.
- Acceptance: final review checklist, verification command output, and
  documentation links are available for the Phase 2.2 handoff.

### Recorded completion evidence (2026-08-11)

- **Task 1 / Checkpoint A:** `stasel/WebRTC` is exact-pinned at `151.0.0`,
  revision `19aa8c1fc7120d50df987b7111f42d5024df3d54`, with upstream binary
  checksum `64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`.
  The package resolves and the unsigned iOS Simulator build succeeds.
- **Task 2 / Checkpoint A:** the adapter contract and tests cover one
  `.initial` connection followed by at most one `.reconnect`; the transport
  keeps that purpose internal to Infrastructure.
- **Tasks 3–4 / Checkpoint B:** wire codec and SDP signaling tests cover the
  approved event/request shapes, status handling, cancellation, and redaction
  with deterministic fakes; no network or credential is used.
- **Tasks 5–7 / Checkpoint C:** permission, audio-session, and peer-driver tests
  cover platform-isolated behavior and cleanup through injected boundaries;
  macOS tests and the unsigned Simulator build remain green.
- **Tasks 8–10 / Checkpoint D:** the focused transport suite passed 21 tests in
  1 suite, covering ordered startup, expiry, handshake/event forwarding,
  cancellation, close, and stale-generation suppression. The complete package
  Swift Testing passed 247 tests in 16 suites, and XCTest passed 4 snapshot
  tests.
- **Task 11:** this spec, the roadmap, and ADR-0008 record the same evidence.
  The App remains on `MockVoiceSessionPort`; no real credential, OpenAI network
  session, microphone, or physical iPad was exercised. Permission presentation,
  route behavior, echo cancellation, barge-in, interruption recovery, and
  Taiwan Mandarin quality remain deferred physical-iPad validation.

## 3. Architecture Decisions

- `stasel/WebRTC` is exact-pinned at `151.0.0` and imported only by
  `LumiInfrastructure`.
- `OpenAIRealtimeAdapter` explicitly tells a transport whether a connection is
  initial or an automatic reconnect. The concrete transport does not infer the
  purpose from provider state.
- Foundation-only JSON and HTTP components stay independent from WebRTC for
  fast deterministic tests.
- iOS microphone and audio-session implementations are platform isolated so
  macOS `swift test` remains supported.
- The WebRTC framework is hidden behind an internal peer/media driver. The
  transport actor owns the full operation generation and ignores callbacks from
  closed or superseded generations.
- Errors expose stable typed categories and safe numeric status codes only.
  Secrets, Authorization values, SDP, raw audio, and raw provider payloads are
  never included in diagnostics.
- No phase-owned wall-clock timeout, real credential backend, Live app mode,
  VAD tuning, or Avatar amplitude is added.

## 4. Implementation Sequence

### Stage 1 — Dependency and Transport Contract

- Add and resolve exact `stasel/WebRTC` `151.0.0`.
- Prove the framework imports on macOS and iOS Simulator.
- Extend the Infrastructure transport contract with explicit initial/reconnect
  intent.
- Test that the existing adapter sends initial intent once and reconnect intent
  only on its automatic retry.

### Checkpoint A (Complete)

- Exact dependency and resolved state are inspectable.
- Existing tests pass.
- The unsigned iOS Simulator build succeeds with the binary linked.
- No layer outside Infrastructure imports `WebRTC`.

### Stage 2 — Wire Protocol and SDP Signaling

- Implement the `session.update` and `response.create` encoders.
- Implement privacy-safe decoding of the approved server-event subset.
- Implement an injected `URLSession`-backed SDP exchange.
- Verify request shape, response validation, cancellation, and redacted errors
  without real network access.

### Checkpoint B (Complete)

- Wire and signaling tests pass deterministically.
- Provider-default VAD JSON omits all unapproved tuning values.
- Unknown events remain forward compatible and malformed data cannot leak.
- The full package suite remains green.

### Stage 3 — Permission, Audio Session, and WebRTC Driver

- Implement just-in-time microphone authorization.
- Add the approved microphone purpose string to every App configuration.
- Implement play-and-record voice-chat audio-session behavior and route policy.
- Implement the framework driver for peer creation, local audio, remote audio,
  ordered data channel, SDP descriptions, delegate forwarding, and cleanup.

### Checkpoint C (Complete)

- Permission denial produces no media, peer, or signaling side effect.
- Audio-session intent is verified using fakes.
- The concrete driver creates an audio/data offer without real network access.
- macOS tests and iOS Simulator build both pass.

### Stage 4 — Concrete Transport Lifecycle

- Compose clock, permission, audio, peer, signaling, and wire collaborators in
  one actor-owned transport lifecycle.
- Enforce both credential-expiry checks and ordered startup side effects.
- Send session configuration on every provider session and an initial response
  only for initial intent.
- Publish decoded provider events, finish the stream on disconnect, and preserve
  the existing adapter reconnect behavior.
- Implement cancellation, idempotent close, and stale-generation suppression.

### Checkpoint D (Complete)

- All Phase 2.2 transport acceptance tests pass without microphone, network, or
  secrets.
- The existing event mapper and adapter regression tests pass unchanged except
  for the explicit connection-purpose contract.
- The complete package suite and unsigned iOS Simulator build pass.

### Stage 5 — Final Review and Documentation

- Review the complete diff for architecture, privacy, concurrency, and
  unnecessary complexity.
- Confirm that the App composition still uses mocks.
- Update the feature spec, plan, ADR consequences, and roadmap with actual
  completion evidence and deferred physical-device validation.

## 5. Parallelization

After Checkpoint A fixes the shared contracts, the wire/signaling work and the
permission/audio work are technically independent. The WebRTC driver can also
begin after the dependency compiles. Integration into `OpenAIWebRTCTransport`
must remain sequential because it depends on all three branches and owns the
shared lifecycle semantics.

Implementation was delegated across Luna workers with non-overlapping ownership
after the shared contracts were agreed. Integration into the transport remained
sequential to preserve the repository's RED → GREEN → REFACTOR audit trail and
avoid overlapping edits to the same Infrastructure contracts.

## 6. Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| XCFramework or Xcode incompatibility | High | Resolve and build both supported platforms before transport implementation. |
| Objective-C delegates crossing Swift 6 isolation | High | Re-enter one actor owner and test stale-generation suppression; introduce no global mutable state. |
| Continuation double-resume during close/cancel | High | Use one-shot completion ownership and cancellation regression tests. |
| Reconnect replays greeting | High | Pass explicit connection purpose from the adapter and assert initial/reconnect sequences. |
| Secret or SDP leaks through errors | High | Use typed redacted errors and assert diagnostic strings contain no sensitive fixtures. |
| Audio route behavior differs on hardware | Medium | Unit-test requested configuration and defer real route/echo acceptance to the recorded physical-iPad gate. |
| Provider adds new events | Low | Preserve well-formed unknown types as `.unknown` and ignore them at the existing mapper. |

## 7. Verification Commands

```sh
swift package resolve
```

```sh
swift test
```

```sh
xcodebuild -project App/LumiApp.xcodeproj \
  -scheme LumiApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The full test and build commands run at every major checkpoint and immediately
before handoff.

## 8. Open Questions

None.
