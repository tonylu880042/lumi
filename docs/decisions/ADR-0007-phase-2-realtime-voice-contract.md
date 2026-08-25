# ADR-0007 — Phase 2 Realtime Voice Contract

> Status: Accepted
> Date: 2026-08-11
> Decision owner: Curves Lumi Product Owner
> Scope: Phase 2 Realtime transport, provider event mapping, credentials, and recovery
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`, `ADR-0006-phase-1-session-flow-contract.md`

## Context

Phase 1 established a provider-independent `VoiceSessionPort` and a fully
deterministic simulated conversation. Before connecting OpenAI Realtime, Phase 2
needed explicit decisions for the iOS transport, model, the semantic boundary
between thinking and speaking, interruption, connection recovery, and API-key
security.

OpenAI recommends WebRTC for mobile clients. Its Realtime server events are more
specific than Lumi's Application events, and provider details must remain in
Infrastructure. The app also cannot contain a standard OpenAI API key. Finally,
Taiwan Mandarin is a product requirement, but the Realtime API does not provide
an output-locale switch that guarantees a Taiwan accent.

## Decisions

### 1. iOS uses WebRTC behind an injected transport seam

The production transport target is WebRTC. `OpenAIRealtimeAdapter` owns provider
signaling and event mapping behind `VoiceSessionPort`; Domain and Application do
not import OpenAI or WebRTC types.

Phase 2.1 first lands an injected, deterministic transport seam. Selecting and
adding a concrete iOS WebRTC package remains a separate dependency review that
must verify maintenance, license, binary size, device and Simulator slices, and
Swift/Xcode compatibility.

### 2. The initial model and voice are cost-aware defaults

The initial session configuration uses:

```text
model: gpt-realtime-2.1-mini
voice: marin
```

Instructions require Taiwan Traditional Chinese and natural Taiwan Mandarin.
This is a prompting and device-evaluation target, not a guaranteed provider
locale or accent capability. Voice acceptance therefore requires listening tests
on a physical iPad before pilot approval.

### 3. Speaking begins at the first playable assistant audio

Lumi emits `VoiceSessionEvent.responseReady` only when the first playable audio
for a response becomes available. It does not use `response.created`, which is
too early, or `response.done`, which is too late.

The initial greeting is already represented by `start(context:)` returning and
the coordinator entering `speaking`; its first output-audio event must not emit
a second `responseReady`.

### 4. Assistant interruption is a public semantic event

`VoiceSessionEvent.assistantInterrupted` is payload-free and provider
independent. When user speech starts while assistant output is active,
Infrastructure emits only `assistantInterrupted`, not a duplicate
`userSpeechStarted`. The coordinator maps both events to the existing
`speaking → listening` Domain transition, so no provider or interruption type
enters Domain.

### 4.1 Owner amendment — 2026-08-25 output completion guards internal session end

`VoiceSessionEvent` also exposes payload-free `assistantOutputStarted` and
`assistantOutputEnded` events. They are Application lifecycle signals, not new
Domain states: the coordinator remains the sole voice-event consumer and uses
them only to protect an internally requested end from truncating audible
assistant output.

Departure monitoring may continue using the approved presence debounce, but
after it confirms departure it must wait through greeting, listening, thinking,
or active output until the current assistant turn reaches a provider-confirmed
output end. A confirmed user interruption still follows the existing
`speaking → listening` transition. Explicit, controlled `endSession()` remains
available for user/system teardown; only the continuous departure path uses the
protected completion operation.

A departure-monitor error is not departure evidence: it stops the automatic
presence loop and exposes the existing privacy-safe retry UI while preserving
the active conversation and device orientation.

### 5. Unexpected disconnect reconnects once

An unexpected transport disconnect triggers at most one automatic reconnect.
The adapter fetches a fresh short-lived credential, creates a fresh transport,
and waits for Realtime readiness. A successful reconnect does not emit
`.failure`; a failed retry emits exactly one `.failure`.

Phase 2.1 does not replay the initial greeting and does not promise conversation
history restoration across the new provider session. Conversation replay or
server-side continuity requires a separate privacy and product decision.

### 6. The app receives only short-lived client secrets

The adapter depends on an injected short-lived credential source. The standard
OpenAI API key stays on a company backend and must never enter the app binary,
logs, errors, descriptions, fixtures, or source control.

Phase 2.1 provides the credential contract and deterministic fake coverage. The
concrete company endpoint, app-to-backend authentication, refresh policy, and
deployment are deferred until the backend contract is approved.

## Alternatives Considered

- Use WebSocket on iOS: rejected as the production target because OpenAI
  recommends WebRTC for browser and mobile client media. A WebSocket diagnostic
  spike may still be used without changing Application contracts.
- Use `gpt-realtime-2.1`: rejected as the initial default because the mini model
  provides the selected lower-cost starting point. Quality must be measured and
  the model remains configurable inside Infrastructure.
- Emit `responseReady` at response creation or completion: rejected because
  those boundaries make Avatar speaking state lead or lag audible output.
- Keep interruption private to Infrastructure: rejected because Application and
  accessibility behavior need a provider-independent semantic interruption.
- Retry indefinitely: rejected because unbounded reconnect loops obscure failure
  and can increase cost. Phase 2 starts with one deterministic attempt.
- Connect directly with a standard API key: rejected as a credential leak and a
  violation of the system security boundary.

## Consequences

- Simulator tests can validate readiness, event mapping, cancellation, stale
  generations, and reconnect behavior without network, microphone, or secrets.
- A later slice can replace the injected transport with a reviewed WebRTC
  implementation without changing Domain state or the coordinator lifecycle.
- Physical iPad testing remains mandatory for microphone permission, speaker
  route, echo cancellation, barge-in latency, Taiwan Mandarin quality, and
  interruption recovery.
- The concrete credential backend and production WebRTC dependency are explicit
  remaining Phase 2 deliverables, not hidden inside the first adapter slice.
