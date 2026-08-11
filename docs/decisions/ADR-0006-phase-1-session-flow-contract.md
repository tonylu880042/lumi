# ADR-0006 — Phase 1 Session Flow Contract

> Status: Accepted
> Date: 2026-08-10
> Decision owner: Curves Lumi Product Owner
> Scope: Phase 1 identity, simulated voice, Simulator controls, and session end
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`, `ADR-0005-development-scope-and-boundaries.md`

## Context

Phase 1.2 completed the deterministic orientation flow through
`recognizing`. The remaining Phase 1 specifications described known and unknown
identity, voice activity, timeout, and session shutdown, but did not define a
single canonical event order or the failure and privacy contracts needed to
implement them safely.

In particular, generic conversation was previously described using
`ToolCallRequested`, even though tool calling and member questions belong to
Phase 3. Voice readiness, response completion, identity value validation,
Simulator timing, and shutdown failure behavior also needed explicit decisions.

## Decisions

### 1. The canonical simulated voice flow is event driven

Phase 1 uses this sequence:

```text
greeting
+ VoiceSessionReady
→ speaking (initial greeting)
+ UserSpeechStarted
→ listening
+ UserSpeechEnded
→ thinking
+ ResponseReady
→ speaking (response)
```

`ToolCallRequested` is not used for ordinary conversation. Tool calls and
`ToolResult` remain Phase 3 behavior.

### 2. Voice startup completion means ready

`VoiceSessionPort.start(context:)` returns only when the voice session is ready.
Later user-speech and response lifecycle changes arrive through a typed event
stream. `AssistantSessionCoordinator` is the sole subscriber and the sole owner
of the resulting `AssistantState` transitions.

The Phase 1 voice port does not expose `sendToolResult`. Audio payloads,
interruption details, reconnect behavior, and the OpenAI Realtime adapter are
Phase 2 concerns.

### 3. Public identity values are validated and privacy safe

`MemberID` wraps the exact caller-provided, non-empty `String`. Empty values are
rejected; values are not trimmed, reformatted, or normalized.

`RecognitionConfidence` accepts only finite values in the inclusive `0...1`
range. Invalid values are rejected rather than clamped.

`RecognitionResult` is either `known(memberID:confidence:)` or `unknown`.
Internal recognition-policy reasons never cross `IdentityRecognitionPort` and
never reach UI.

### 4. Known and unknown converge on greeting without private lookup

Both identity results transition `recognizing → greeting`.

A known result may trigger the existing transient
`AssistantEvent.memberRecognized` and uses generic “welcome back” copy. An
unknown result uses generic visitor copy and does not trigger the member event.
Phase 1 does not query `MemberRepository`, invent a member name, or load private
member context.

### 5. Simulator progress is always explicit

Every identity and voice stage is advanced by an explicit Simulator action.
There are no automatic delays. The identity choice defaults to Unknown, and
known/unknown resolution remains a deliberate action so every durable state can
be inspected.

### 6. Recoverable failures preserve semantic state

- A non-cancellation identity error degrades to `unknown` and continues to
  `greeting`.
- Identity cancellation propagates and leaves the coordinator in
  `recognizing`.
- Voice startup failure leaves the coordinator in `greeting` and permits retry.
- Later voice failures keep the current state and present a generic retry path.
- Technical adapter errors and internal recognition reasons are not displayed
  directly to users.

### 7. Timeout and person-left share one end-session action

Timeout and person-left invoke the same Application end flow from every active
state except `idle` and `offline`:

```text
stop voice
→ stop movement when rotation is active
→ returnHome
→ idle after confirmed home arrival
```

`ending` and `returnHome` remain actions, not `AssistantState` cases. If the end
flow fails, the current semantic state is retained and the action can be
retried. The coordinator must prevent stale completions from an earlier
identity, voice, or orientation operation from advancing state after shutdown.

### 8. Session context is cleared only after confirmed Home arrival

The coordinator retains `recognitionResult` and the voice retry condition while
`returnHome()` is pending. A failed or cancelled return therefore preserves the
current semantic state and its session context so the same end action can be
retried safely.

Only after the hardware adapter confirms Home arrival and the reducer enters
`idle` does the coordinator clear identity and voice retry context. The App then
clears the generic greeting and any transient session Avatar Event. This avoids
both premature privacy-state changes during a recoverable failure and stale
member context leaking into the next session.

## Alternatives Considered

- Use `ToolCallRequested` for every utterance: rejected because it conflates
  ordinary conversation with Phase 3 tool calling.
- Skip directly from greeting to listening: rejected because the initial Lumi
  greeting must be observable as speaking.
- Clamp or normalize identity values: rejected because invalid boundary data
  must remain visible to adapter authors and tests.
- Expose recognition failure reasons in UI: rejected for privacy and because
  unknown is a normal product result.
- Personalize known visitors with fabricated names: rejected because Phase 1
  performs no member lookup.
- Advance Simulator states using timers: rejected because deterministic manual
  controls make async completion boundaries observable.
- Reset to idle before `returnHome()` succeeds: rejected because state must not
  claim the session is safely home before the hardware contract completes.
- Clear identity context when shutdown starts: rejected because a failed Home
  return must retain a coherent, retryable session state. Context is cleared
  immediately after confirmed arrival instead.
- Add durable `ending` or `returnHome` states: rejected because they are
  orchestration actions rather than assistant presentation states.

## Consequences

- Phase 1.3 can be delivered incrementally: identity result and greeting first,
  then the mock voice lifecycle, then shared end-session orchestration.
- The OpenAI Realtime adapter in Phase 2 must map provider callbacks into the
  typed voice events without changing Domain transition semantics.
- The coordinator requires operation ownership robust enough to ignore stale
  async completions during end-session.
- A new session always starts without the previous recognition result or voice
  retry condition, while a failed end remains retryable with coherent context.
- Phase 3 may add tool-call events and member data without redefining the basic
  conversation lifecycle.
