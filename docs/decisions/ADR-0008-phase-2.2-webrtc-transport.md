# ADR-0008 — Phase 2.2 WebRTC Transport

> Status: Accepted
> Date: 2026-08-11
> Decision owner: Curves Lumi Product Owner
> Scope: Phase 2.2 WebRTC dependency, media, signaling, permission, VAD, and deferred work
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`, `docs/phase-2.2-webrtc-transport.md`, `ADR-0007-phase-2-realtime-voice-contract.md`

## Context

Phase 2.1 established the provider-independent voice adapter, injected
transport seam, short-lived credential contract, event mapper, and one-reconnect
policy. Phase 2.2 requires a concrete WebRTC implementation, but adding that
implementation without explicit decisions would leave package selection,
microphone permission, audio routing, turn detection, initial greeting,
credential expiry, testing scope, and milestone boundaries ambiguous.

OpenAI recommends WebRTC for mobile Realtime clients. Its ephemeral-token flow
allows the app to exchange local SDP directly with the Realtime endpoint while
keeping the standard API key on a trusted backend. The media and provider-event
details must remain inside Infrastructure.

## Decisions

### 1. Phase 2.2 implements the concrete transport but not Live app wiring

Phase 2.2 adds a real peer connection, microphone and remote-audio tracks, the
`oai-events` data channel, ephemeral-token SDP exchange, provider-event
decoding, initial greeting, and clean shutdown behind the Phase 2.1 transport
seam.

The App composition root continues to use the voice mock by default. The
company credential backend, app authentication, and a Live/Mock UI mode require
a later approved contract.

### 2. Use `stasel/WebRTC` exact version `151.0.0`

Swift Package Manager uses an exact `151.0.0` requirement, and only
`LumiInfrastructure` depends on its `WebRTC` product. The resolved dependency is
committed. Version upgrades require a new review of maintenance, compatibility,
binary slices, size, license, and security implications.

The selected distribution publishes iOS-device, iOS-Simulator, and macOS
XCFramework slices and uses the BSD 3-Clause License.

### 3. Use Server VAD with Infrastructure-controlled response and interruption

Every fresh provider session receives `session.update` with:

```text
turn_detection.type: server_vad
create_response: false
interrupt_response: false
```

Phase 2.2 omits `threshold`, `prefix_padding_ms`, and `silence_duration_ms`.
The provider therefore identifies speech candidates but cannot cancel output
or create a response by itself.

Owner amendment (2026-08-24): after increased remote-audio gain exposed false
interruptions from speaker echo, the product owner selected controlled local
barge-in. Infrastructure learns three normalized microphone-level samples at
80 ms intervals while output is active, then requires three candidate samples
whose median is at least `max(1.8 × baseline, baseline + 0.02)`. Missing or
invalid statistics fail closed. A confirmed candidate cancels only an actively
generating response, clears buffered WebRTC playout, and causes one new
response only after its committed input turn ends and the prior cancellation
completes. Speech before playout has no output echo, so it is accepted directly
and cancels any active generation; stale output arriving before cancellation
completion is cleared without reaching the semantic voice lifecycle. Rejected echo input is
deleted from provider conversation state. No audio samples, transcripts, or
level history are persisted. These values are approved pilot tuning and remain
subject to physical-device acceptance.

### 4. Request microphone permission just in time

The transport checks permission immediately before starting the voice session
and requests it only when the system status is undetermined. If permission is
denied, connection startup returns a typed error and creates no peer connection,
audio-session activation, or signaling request. Existing coordinator behavior
keeps `greeting` retryable. The App does not automatically open Settings.

The App includes this microphone purpose string:

```text
Lumi 需要使用麥克風，才能與您進行即時語音互動。
```

### 5. Use a voice-chat audio session and respect external routes

On iOS, the transport uses play-and-record voice-chat behavior to support
WebRTC voice processing and echo cancellation. It prefers the built-in iPad
speaker only when no external route is present and preserves wired or Bluetooth
HFP routes.

### 5.1 Apply the approved remote-audio gain

The product owner approved a `2.0` gain for decoded Realtime remote audio on
2026-08-24. The Infrastructure peer driver applies the pinned WebRTC
`RTCAudioTrack.source.volume` value to remote audio tracks from both the legacy
`didAddStream` callback and the Unified Plan `didAddReceiver` callback. This
does not modify `AVAudioSession.outputVolume`, force `overrideOutputAudioPort`,
or change the external-route policy in section 5.

### 5.2 Owner amendment — 2026-08-24 WebRTC default route correction

WebRTC's public `RTCAudioSessionConfiguration.webRTCConfiguration()` is
updated before the WebRTC audio unit is created, and the result is applied
through `setWebRTCConfiguration`. The existing category options are preserved
and `.defaultToSpeaker` plus `.allowBluetoothHFP` are added. This addresses
WebRTC's later configuration pass replacing the App's pre-activation speaker
preference, while retaining external Bluetooth HFP routing. The correction does
not write system output volume, use private API/KVC, or force
`overrideOutputAudioPort(.speaker)`.

### 6. Reject expired short-lived credentials locally

A credential with `expiresAt <= now` is rejected before microphone permission,
peer creation, or network signaling. The transport checks again immediately
before posting SDP in case the permission interaction consumed the remaining
lifetime. Phase 2.2 adds no arbitrary expiry safety margin.

### 7. Initial greeting occurs only on the initial connection

After the initial provider session emits `session.created`, the transport sends
the session configuration and exactly one `response.create`. A fresh session
created by ADR-0007's automatic reconnect receives the session update but does
not replay the greeting.

### 8. No Phase 2.2 wall-clock policies or real Avatar amplitude

Phase 2.2 adds no startup, initial-response, inactivity, maximum-duration, or
return-home timeout. It also does not connect WebRTC audio amplitude to
Presentation. The transport remains cancellation-safe, surfaces errors through
existing boundaries, and allows the adapter to apply its one-reconnect policy.

Timeout values and the real amplitude stream require separate product approval
in later Phase 2 work.

### 9. Automated verification uses no microphone, network, or secret

Concrete framework code is isolated behind internal injectable collaborators.
Unit tests use fake permission, clock, audio-session, peer-driver, data-channel,
and signaling dependencies. The real binary integration is proven by macOS
package tests and an unsigned iOS Simulator build.

Final device acceptance remains mandatory before pilot for permission UI,
speaker and external routes, echo cancellation, barge-in latency, Taiwan
Mandarin quality, and interruption recovery.

## Alternatives Considered

- Use another WebRTC distribution: rejected after the Phase 2.2 package review;
  `stasel/WebRTC` `151.0.0` is the approved dependency.
- Use a version range or `latest` branch: rejected because binary changes must
  not enter builds without explicit review.
- Implement the credential backend and Live UI in the same slice: rejected
  because endpoint authentication, deployment, and operational behavior are
  separate contracts.
- Use `semantic_vad` or change provider Server VAD thresholds: still rejected.
  The 2026-08-24 owner amendment instead adds an Infrastructure-local,
  fail-closed level policy whose pilot values require physical-device
  acceptance.
- Keep the microphone active or request permission at app launch: rejected
  because Realtime sessions are event-triggered and microphone access should be
  requested only when needed.
- Continue receive-only after permission denial: rejected because it creates an
  asymmetric conversation mode not present in the product state contract.
- Let OpenAI reject an already expired token: rejected because it creates
  unnecessary permission, media, and network side effects.
- Add an expiry safety window: rejected until a measured value is approved.
- Replay the greeting after reconnect: rejected by ADR-0007 because the fresh
  transport session must not appear to restart the user interaction.
- Add timeout values or Avatar amplitude now: rejected because both require
  separate product behavior and acceptance criteria.

## Consequences

- `Package.swift` and the resolved package state gain a large binary WebRTC
  dependency, isolated to `LumiInfrastructure`.
- The existing transport seam may gain Infrastructure-only connection intent
  needed to distinguish the initial connection from an automatic reconnect;
  `VoiceSessionPort` and Domain remain unchanged.
- Concrete WebRTC, AVFoundation, and URLSession code is testable through
  injected internal boundaries without real external effects.
- Permission denial and expiry remain retryable voice-start failures rather
  than new Domain states.
- The default app continues to demonstrate the deterministic simulated flow.
- Live credential delivery, timeout policy, amplitude visualization, and final
  physical-device quality validation remain visible follow-up work.

## Implementation Confirmation (2026-08-11)

The Phase 2.2 implementation and automated gates are complete. The approved
`stasel/WebRTC` `151.0.0` dependency resolves to revision
`19aa8c1fc7120d50df987b7111f42d5024df3d54`; the upstream binary checksum is
`64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`.

The focused `OpenAIWebRTCTransportTests` suite passed 21 tests in 1 suite; the
Swift Testing passed 247 tests in 16 suites, and XCTest passed 4 snapshot
tests; the unsigned iOS Simulator build completed successfully. These are
deterministic tests and a compile/integration check only: no real credential,
OpenAI network session,
microphone, or physical iPad was exercised. The App remains on
`MockVoiceSessionPort` by default, while permission presentation, route
behavior, echo cancellation, barge-in, interruption recovery, and Taiwan
Mandarin quality remain deferred physical-iPad validation.
