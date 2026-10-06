# ADR-0017 — Local Member Interaction Memory

> Status: Accepted; Debug-Live implementation and automated validation complete, live speech/device acceptance pending
> Date: 2026-09-18
> Decision owner: Curves Lumi Product Owner
> Scope: Debug-Live, single-device interaction history and self-reported exercise context
> Related: ADR-0011, ADR-0013, ADR-0015, ADR-0016,
> [approved feature specification](../member-interaction-memory-draft.md)

## Context

The owner wants Lumi to remember previous interactions, notice frequent or
infrequent encounters, and respond to a member who says she has just exercised.
The eventual goal is official exercise-record integration, but that database is
not available. The owner requested implementation by Luna and explicitly
accepted the proposed rules, with the requirement that those rules be documented.

A conversation, a store visit, and a completed workout are different evidence.
Existing anonymous arrival-vitality events and synthetic exercise summaries
cannot establish an individual member's real attendance or workout history.

## Decision

### Record only consented, locally bound interactions

The pilot stores structured events against the locally recognized MemberID.
Independent memory consent is required; face-enrollment consent is not reused
as authorization for this new purpose. Keep the latest 90 days of events on the
device, provide operator controls to clear or disable memory, and invalidate
derived summaries and pending writes when consent is withdrawn or memory is
cleared. No complete transcript, raw audio, free-form health story, or new cloud
sync is introduced. Backup exclusion belongs to the persistence implementation.

Unknown sessions cannot read or persist member history. Newly enrolled members
become eligible only in the next known-member session after memory consent.
An operator's memory clear must not delete the member's identity or embeddings.

### Derive encounter context from completed greetings

A known member's completed greeting records an encounter even if the member
does not speak. Count distinct encounter dates, not conversation or reconnect
counts. Use Asia/Taipei calendar days:

- Frequent: at least three distinct encounter dates in the seven-day window
  containing today and the preceding six dates.
- Long time no see: a retained previous encounter at least fourteen calendar
  days before today.
- Seen today: a completed encounter earlier on the current store date.

Read the historical snapshot before recording this greeting. A not-yet-finished
greeting cannot contribute to its own opener. Absence of retained data is
unknown history, not proof of a first visit or prolonged absence from exercise.

### Keep self-reported workout context distinct and bounded

For an authorized known session, a clear first-person statement may be recorded
through a constrained Application tool. Preparing to exercise and just having
finished apply only to the current session. An explicit report of completion
today can apply to later conversations on that store date, then expires at the
date boundary. The reporting time is not a precise workout-completion time.

Ambiguous, negated, quoted, hypothetical, third-person, or past-day statements
must not become present completion records. Allow correction of a report.
The tool cannot choose MemberID, provide arbitrary timestamps, store arbitrary
text, or claim an official data source. Application enforces current-session
binding, consent, validated values, deduplication, and stale-write rejection.
Model interpretation still requires live semantic acceptance testing.

### Personalize one opener with minimal allowed context

This extends ADR-0011 only to allow a consented known member's minimal
interaction summary to be read for a proactive opener. It does not authorize
preloading official or synthetic exercise data. MemberID and full history stay
local; the provider receives only permitted semantic context and source labels.
The broker remains member-data-free. Privacy checks still apply separately from
identity recognition.

This amends ADR-0015 for this pilot: when permitted meaningful context is
available, generate one contextual opener instead of playing the generic
recording. Otherwise retain the recording. Never stack both openers or replay
the opener on reconnect. Preserve output/microphone protection and ADR-0016's
natural closing and same-presence rearm behavior.

Respond to the member's current words first and choose a single relevant
contextual point; do not read a history list or add obligatory follow-up
questions. Speak of seeing the member, not verified workout frequency.

### Preserve a path to official records

Retain distinct provenance for encounters, self-reports, and future official
records. Do not backfill encounters as workouts or identify Curves accounts by
display name. Future MemberRepository integration requires its own approved
identity mapping, API, freshness, consent, and conflict-resolution contracts.

## Architecture and consequences

Domain owns deterministic context rules. Application owns use cases, session
binding, consent checks, and storage ports. Infrastructure implements SQLite
and provider mappings; Presentation maps to its own UI values. No new global
service, direct model-to-database path, or motor control path is introduced.

The pilot is Debug-Live only and remains isolated from synthetic member data.
Release enablement, official database integration, and device deployment are
outside this implementation authorization. The feature specification's approved
rules are the source for acceptance tests; later product changes must update
that document, this ADR where relevant, and the tests together.

## Validation requirements

Use RED → GREEN → REFACTOR for every behavior. Cover date boundaries,
read-before-write, repeat and stale events, consent, clear/write races, unknown
and cross-member access, failed storage, correction and expiration, and single
opener behavior. Run `swift test` and the unsigned LumiApp Simulator build.
Record implementation results separately from this acceptance decision; passing
unit tests does not establish real speech-interpretation accuracy.

## Persistence maintenance amendment (2026-10-06)

Welcome-time `loadBatch` prunes only the requested member using the existing
member/time index. If that member has no expired events, loading does not open
a write transaction. Actual deletion and that member's revision increment stay
in one transaction so stale session writes remain invalidated. The existing
Taipei calendar ninety-day cutoff is unchanged.

Explicit `pruneExpired` remains global and is invoked by Debug-Live startup.
Loading one member no longer deletes another member's records or increments her
revision. Other members' expired events are removed by global maintenance or
their own next load; this change adds no periodic cleanup schedule. Connection
destruction uses `sqlite3_close_v2` to defer handle release until any outstanding
statements are finalized.

Validation: the write-lock, member-scoped pruning/revision and outstanding-
statement regressions failed before their fixes and pass afterward. Full
`swift test` passes 938 Swift Testing tests plus four XCTest tests; the unsigned
generic iOS Simulator build succeeds. The App model suite passes all 32 tests,
including release/cancellation after removing an implicit strong capture of the
vitality service through the model. This maintenance change has not been
reinstalled on the physical phone or measured for greeting latency.
