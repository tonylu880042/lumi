# ADR-0005 — Development Scope and Layer Boundaries

> Status: Accepted
> Date: 2026-08-09
> Decision owner: Curves Lumi Product Owner
> Scope: Avatar M3, Phase 1, Identity result boundary, Reduced Motion
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`, `Curves_Lumi_Avatar_Visual_Spec.md`

## Context

The initial system, architecture, roadmap, identity, and Avatar specifications described several concepts at different levels of detail. Before continuing development, the product owner resolved thirteen ambiguities that would otherwise change milestone scope, Domain state, module dependencies, user-visible accessibility behavior, Simulator behavior, or hardware safety semantics.

## Decisions

### 1. Phase 1 excludes member questions

Phase 1 delivers the simulated assistant-state flow and defines mockable Application ports. Member-specific questions, `MockMemberRepository` query behavior, and tool calling remain in Phase 3.

### 2. `rotating` begins in Phase 1

`AssistantState.rotating` is introduced together with the Phase 1 deterministic State Reducer and mock `HardwareControlPort`. It is not retroactively added to the current Avatar M3 baseline.

`ending` and `returnHome` are Application actions, not `AssistantState` cases.

### 3. Encouraging and confused remain States

`AssistantState.encouraging` and `AssistantState.confused` remain long-lived semantic states. Short sparkle, question, retry, recognition, and celebration feedback belongs to the Event animation layer. Duplicate `.encouragement`, `.retry`, or `.confusion` Domain event cases are not introduced.

### 4. `LumiUI` does not depend directly on `LumiDomain`

The reusable `LumiUI` module consumes Presentation models and commands only. Domain events are mapped exhaustively to the Presentation-owned `AvatarEventCommand` before reaching `LumiUI`. The App composition layer may depend inward on Domain, Application, Presentation, and UI as required.

### 5. Identity uses internal and public result types

The confidence policy returns an internal `RecognitionDecision`, including `unknown(reason:)` for orchestration, testing, and aggregate telemetry. `IdentityRecognitionPort` exposes the simplified public `RecognitionResult`, where unknown has no low-level reason. UI never receives recognition-policy failure details.

### 6. Reduced Motion preserves semantic feedback

Reduced Motion keeps meaningful Event feedback as a static symbol or short opacity transition. It removes large translation, bounce, rotation, and looping particle motion. It must not silently erase the fact that an Event occurred.

### 7. `rotating` is directionless and visually centered

Phase 1 uses the parameterless `AssistantState.rotating`. The preceding
`detected(direction:)` state carries the visitor direction long enough for
Application to issue the hardware command; `rotating` itself does not retain
that direction. Its Avatar mapping is a centered, attentive focus expression
without a waveform or Event effect.

### 8. Illegal reducer transitions are explicit typed errors

The deterministic State Reducer throws a Domain-owned, typed illegal-transition
error and leaves the caller's current state unchanged. It must not silently
fall back to another state. Application may later translate the error into
telemetry without introducing logging into Domain.

### 9. Rotation uses validated degrees and completes on arrival

`HardwareControlPort.rotate(to:)` accepts a validated `RotationAngle` in the
inclusive `-90...90` degree range. Non-finite and out-of-range values are
rejected rather than clamped. The async operation completes only after the
adapter reports that the target angle has been reached, not merely when the
command has been accepted. Phase 1 mocks expose explicit completion control so
tests never wait on real time.

### 10. Simulator orientation uses three explicit stages

Phase 1.2 exposes Confirm Presence, Begin Rotation, and Complete Rotation as
separate debug actions. This makes `detected`, pending `rotating`, and confirmed
`recognizing` observable without inventing a wall-clock delay.

### 11. Center still crosses the hardware port

Left, center, and right map to absolute `-90°`, `0°`, and `+90°` targets. Center
still calls `rotate(to: 0°)` and waits for confirmed arrival; the adapter may
confirm immediately when real hardware is already at the target.

### 12. Failed or cancelled orientation is retryable

If rotation throws or the caller cancels, the coordinator calls `stop()` and
uses a Domain reducer event to restore the original `detected(direction:)`.
It propagates the original error and must not advance on a stale completion.

### 13. Session simulation and Avatar tuning are separate modes

The Simulator defaults to Session mode. The existing manual Avatar state/event
tuner remains available in a separate mode and must never overwrite the
coordinator's active session state.

## Alternatives Considered

- Merge member questions into Phase 1: rejected because it collapses the roadmap boundary with Phase 3.
- Model `ending` and `returnHome` as Domain states: rejected because they are orchestration actions rather than durable assistant presentation states.
- Let `LumiUI` import Domain types: rejected to preserve a strict Presentation boundary for the reusable rendering package.
- Expose `UnknownReason` to UI: rejected because it leaks policy internals and encourages technical error presentation.
- Hide all Event feedback under Reduced Motion: rejected because accessibility should reduce motion without removing semantic feedback.
- Carry direction in `rotating(direction:)`: rejected for Phase 1; the approved state is directionless and uses a centered focus expression.
- Silently ignore illegal state transitions: rejected because it hides orchestration defects and prevents reliable telemetry later.
- Clamp unsafe motor angles: rejected because invalid commands must be visible rather than silently changed.
- Skip the center hardware command: rejected because arrival semantics must be consistent for every direction.
- Hide orientation timing behind arbitrary mock delays: rejected because staged controls are deterministic and make the arrival boundary visible.
- Reset to idle or offline after orientation failure: rejected because the approved flow preserves the detected direction and permits retry.
- Mix the manual Avatar picker with coordinator state: rejected because it would create competing state owners.

## Consequences

- Avatar M3 must replace its direct `AssistantEvent` UI input with `AvatarEventCommand` before completion.
- Phase 1 must add `.rotating` and an explicit Avatar mapping in the same tested slice as the State Reducer.
- Phase 3 retains ownership of mock member questions and tool calling.
- Identity implementation must map `RecognitionDecision` to `RecognitionResult` at the Application/port boundary.
- Reduced Motion tests must verify preserved meaning as well as suppressed motion.
- The Phase 1 reducer exposes typed rejection for illegal transitions.
- Hardware adapters accept validated angles and complete `rotate(to:)` only when arrival is confirmed.
- Phase 1.2 adds a reducer-owned orientation failure transition back to the
  original detected direction.
- The App observes coordinator state but does not own or independently mutate it.
