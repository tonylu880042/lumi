# ADR-0011 — Phase 3 Session-Bound Member Voice Tool

> Status: Accepted
> Date: 2026-08-20
> Decision owner: Curves Lumi Product Owner
> Scope: Phase 3 mock member data, Realtime tool calling, Debug-Live composition
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`,
> `docs/decisions/ADR-0005-development-scope-and-boundaries.md`,
> `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`, and
> `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`

## Context

The first member conversation slice must validate natural voice questions
before the real Curves member system contract is available. The face-recognition
path and the local session already have a known `MemberID`, but sending that
identifier to OpenAI would unnecessarily expose identity data and would allow
the provider to choose which member record to query.

The slice also needs a deterministic data source for Debug-Live. Fixture data
must be visibly different from Curves production data, while Mock and Release
compositions must remain offline and must not accidentally enable member tools.

## Decision

### 1. Expose one no-argument weekly-summary tool

The provider-facing function is:

```text
get_member_weekly_summary()
```

Its parameters are an empty object with no additional properties. OpenAI may
request the current session's weekly summary, but it never receives or supplies
`MemberID`, display name, recognition confidence, face data, or profile data as
tool arguments.

### 2. Bind the identifier locally to a known session

`AssistantSessionCoordinator` creates the tool-call runner only after local
recognition returns a known member and the voice session uses the
`returningMember` context. A session-scoped Application router retains the
`MemberID` and invokes `GetMemberWeeklySummaryUseCase` against the injected
`MemberRepository`.

Unknown/visitor sessions do not register the tool, do not start a tool-call
runner, and cannot load member data. Calls are processed serially and results
are deterministic JSON with fixed error codes for unavailable or invalid data.

### 3. Use a fixed synthetic repository only in Debug-Live

`Debug-Live` uses one explicit `MockMemberRepository` fixture so voice behavior
can be validated without a Curves backend. The Debug-Live instructions require
the assistant to say:

> 「以下是開發測試資料」

before presenting fixture-backed answers. The generic repository has no default
records. `LumiApp` Release and `LumiApp-Live` Release-Live do not enable the
mock member tool.

### 4. Defer the real Curves adapter until its contract is approved

No `CurvesMemberAPIRepository` is inferred from the mock. Implementation waits
for verified endpoint and authentication details, identity mapping, response
schema, time-zone/week-boundary semantics, consent/privacy rules, error and
rate-limit behavior, and offline/cache policy.

## Alternatives Considered

### Send `member_id` as a tool argument

Rejected. It exposes a stable identity to the provider and gives the model
control over which member record is requested. The local session already has
the authorized binding needed by the Application layer.

### Put the member profile in the system prompt

Rejected. It increases the amount of sensitive context sent to OpenAI and
creates stale-data and prompt-disclosure risks. The tool returns only the
minimum summary required for the current question.

### Enable the tool for every voice session

Rejected. Unknown/visitor sessions must never load private member data, and
the tool should not exist in the provider session when there is no local known
member binding.

### Add the real Curves repository now

Rejected. The required API, authentication, mapping, schema, privacy, and
failure contracts are not yet supplied. Guessing them would make the mock
validation misleading and create an unstable public boundary.

## Consequences

- Debug-Live can validate a member-specific voice question with deterministic,
  explicitly labeled fixture data.
- OpenAI remains outside the identity-binding decision and never sees a
  `MemberID` through the voice tool path.
- Unknown/visitor conversations stay generic and cannot query member data.
- Release builds remain free of the synthetic repository/tool wiring.
- The Application `MemberRepository` port is ready for a future Curves adapter,
  but Milestone 4 still requires a separate contract and implementation gate.
