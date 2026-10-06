# ADR-0018 — Store Experience Recovery Roadmap

> Date: 2026-09-23
> Status: Accepted scope/order and three product decisions; remaining rules pending owner clarification
> Scope: roadmap maintenance, profiling, and planning; not blanket approval to implement undecided behavior or enable Release

## Context

After a customer demonstration, the owner reported verbose speech and apparent
non-response, and requested concise welcoming, weekly exercise encouragement,
monthly milestones and measurement reminders. The owner subsequently requested
known/unknown recognition profiling and an actionable `docs/roadmap.md` containing
only unfinished work. Existing implementation, deployment and field acceptance
must not be conflated.

## Confirmed decisions

1. If the first day of a month is Sunday, defer the month-opening reminder to
   the first business day. This does not settle whether the overall window is
   calendar days 1–7, seven days from the deferred date, or a single reminder.
   Business-day data and reminder frequency remain unresolved.
2. Measurement and interview are one activity and one completion concept,
   consistently named 「量身面談」.
3. The special sound for reaching twelve workouts in a month plays at most once
   per member per month. The count source, month boundaries, late/corrected data,
   playback-failure semantics and persistence/consent details remain decisions
   to resolve before implementation.
4. Profile before accelerating recognition. Report known/unknown, cold/warm and
   stage timing separately, and distinguish host microbenchmarks from physical
   camera and first-audible-greeting latency. Do not silently change the current
   three-fresh-observation confidence policy or thresholds.
5. Replace the historical roadmap checklist with remaining, dependency-ordered
   tasks. Retain unfinished physical acceptance, production identity gates,
   member API, hardware, integrated store validation and productization.

## Follow-up owner direction (2026-09-23)

[ADR-0019](ADR-0019-greeting-reminder-first.md) now prioritizes greetings and
reminders over member chat and authorizes the bounded Luna prompt-policy slice.
Routine reminders need no answer; only simultaneous-reminder ordering remains
open within D8. Other unresolved data and lifecycle decisions below remain open.

## Plan and boundaries

Follow-up (2026-10-01): [ADR-0021](ADR-0021-weekly-encounters-and-interview-reminders.md)
settles the monthly reminder window as calendar dates 1–10, at most once daily
per member until coach-confirmed completion. It also accepts calendar-week Lumi
encounter encouragement, separately from official workout counts. Remaining
delivery, consent, storage, access and priority decisions are listed there;
the unresolved choices below describe this record's original scope.

Prioritize P0 measurement/recovery/concise interaction, then P1 trustworthy
exercise counts and explicit departure, then P2 measurement interviews,
monthly celebration and weekly wording. Detailed task IDs, dependencies,
acceptance criteria and unresolved questions live in [the roadmap](../roadmap.md).
Existing feature specifications and ADRs remain the implementation history.

The previous conversation's recommendations are not approvals: no workout data
source, departure trigger, week/month counting rule, retention extension,
proactive official-data access, timeout value, new voice or reminder priority
is selected here. Pending decisions block only affected implementation.

Existing encounter memory cannot become official workout history. Face consent
cannot be reused as authorization for new exercise or interview records.
Current enrollment stores features, not photos. Application retains current
member/session binding and event deduplication; models cannot control motors or
choose arbitrary member IDs or dates.

## Consequences

A feature is removed from the roadmap only after its own required evidence is
recorded. Implemented features with uncompleted field acceptance retain only
the missing acceptance task. No historical test count proves the current dirty
working tree or customer-demonstration binary is correct.

Profiling artifacts contain synthetic data or anonymous technical timing, not
raw faces, embeddings, names, voice or transcripts. Automated checks and
physical-device results are reported separately. Physical testing follows
AGENTS.md: only LumiApp-Live / Debug-Live / com.curves.lumi.live.
