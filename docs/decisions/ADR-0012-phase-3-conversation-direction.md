# ADR-0012 — Phase 3 Conversation Direction Focus

> Status: Accepted
> Date: 2026-08-21
> Decision owner: Curves Lumi Product Owner
> Scope: Phase 3 voice-session direction selection and Debug-Live controls
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`,
> `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`,
> `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`, and
> `docs/decisions/ADR-0011-phase-3-session-bound-member-tool.md`

## Context

Lumi needs to validate two repeatable member-interaction moments before the
physical voice-quality gate: a short reminder before exercise and a concise
review after exercise. The focus must be selectable without putting identity or
member data into the provider boundary, and it must work for both known members
and unknown visitors.

The existing Realtime session already has a provider-neutral Application port,
and the Phase 3 member tool is deliberately bound locally to a known session.
The direction feature must not turn the broker into a conversation proxy,
change tool authorization, or make the LLM responsible for hardware or member
identity decisions.

## Decision

### 1. Use three payload-free directions

The App-owned choice maps to the provider-neutral Application enum:

| UI label | Direction |
| --- | --- |
| `一般` | `general` |
| `運動前提醒` | `preWorkoutReminder` |
| `運動後 review` | `postWorkoutReview` |

The enum has no associated values. It applies to known and unknown sessions
alike and contains no `MemberID`, name, confidence, embedding, photo,
transcript, exercise data, or other private payload.

The legacy `VoiceSessionPort.start(context:)` contract remains available and
means `general`. The additive direction-aware start contract maps the App choice
to the Application enum; concrete provider adapters receive only that enum.

### 2. Append fixed focus instructions per Realtime session

`general` appends no direction text. The other directions append only these
fixed Traditional Chinese instructions to the current session instructions:

```text
preWorkoutReminder:
本次對話方向是運動前提醒。主動給予簡短、溫柔的運動前提醒；若需要會員數據，只能使用工具回傳，不得自行推測或捏造。

postWorkoutReview:
本次對話方向是運動後 review。主動用簡短、正向的問題引導使用者回顧本次運動；若需要會員數據，只能使用工具回傳，不得自行推測或捏造。
```

The addition is session-scoped. It does not alter the broker request, request
body, device token, authentication flow, or provider-independent session
context. The LLM receives no identity payload through this feature.

### 3. Keep member tools known-only and on-demand

A direction is a conversation focus, not a data-access grant and does not force
a tool call. The existing `get_member_weekly_summary` tool remains available
only for a locally known member session and only when requested by the
conversation. Unknown/visitor sessions do not register the tool and cannot load
private member data. A direction never authorizes hardware control; hardware
commands remain outside the voice tool path.

### 4. Keep direction controls Debug-Live-only

The picker is compiled and displayed only under `DEBUG && LUMI_LIVE`. Mock
Debug, Release, and Release-Live have no picker and use `general`. In
Debug-Live:

- the choice is made once before the voice session starts;
- the picker is disabled whenever voice cannot start, including after startup
  begins;
- a retryable startup failure leaves the selected direction unchanged; and
- confirmed return to `idle` resets the choice to `general`.

The choice is not persisted and does not emit telemetry. ContentView owns the
temporary UI state; `SimulatorControlsView` receives its binding, while only
the picker itself is conditionally compiled.

## Alternatives Considered

### Send the direction to the broker

Rejected. The broker mints ephemeral credentials and must remain bodyless and
member-data-free. Direction is a per-session provider instruction, not broker
authorization or routing state.

### Send a member identifier or profile with the direction

Rejected. Direction is intentionally payload-free. The existing local
known-session router is the only place that retains the member binding, and
unknown sessions must not load private data.

### Force a weekly-summary tool call for the exercise directions

Rejected. A reminder or review can be useful without member metrics, and
forcing a tool call would broaden data access and make the LLM less predictable.
The tool remains known-only and on-demand.

### Show and persist the picker in every build

Rejected. The first validation target is Debug-Live; exposing it in Mock or
Release would expand the shipped UI contract. Persistence would make a
diagnostic focus unexpectedly cross session boundaries.

## Consequences

- The Application and Infrastructure boundaries stay provider-neutral and
  backward-compatible.
- Debug-Live can validate pre-workout and post-workout conversation behavior
  without member payloads or a real Curves backend.
- Mock and release configurations remain deterministic and direction-neutral.
- The real Curves adapter remains a separate gate; this decision does not infer
  its endpoint, authentication, schema, privacy, or offline behavior.
- Physical microphone routing, barge-in, Taiwan Mandarin quality, and overall
  voice quality still require manual iPad validation.

## Evidence and Verification

- Slice 1 followed RED (missing direction contract) with focused package tests
  passing `80/80` and `swift build` succeeding.
- Slice 2 followed tests-only RED with `xcodebuild` exit `65`; focused Debug and
  Debug-Live tests then passed (Debug reported 13 tests in 2 suites).
- Full App gates passed `63/63` for `LumiApp` Debug and `63/63` for
  `LumiApp-Live` Debug-Live.
- Four unsigned generic Simulator builds completed with exit `0`.
- Exact `swift test` snapshot coverage reached `4/4`, with visible passing
  suites; the known `swiftpm-testing-helper` lifecycle hang was interrupted
  with exit `130`, so this is not recorded as a clean full-suite pass or a
  full-suite count.
