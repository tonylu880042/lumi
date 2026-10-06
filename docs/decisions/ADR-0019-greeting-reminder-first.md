# ADR-0019 — Greeting and Reminder First

> Date: 2026-09-23
> Status: Accepted product direction; implementation/verification tracked in the feature spec
> Owner: Curves Lumi product owner
> Related: ADR-0013, ADR-0014, ADR-0016, ADR-0017, ADR-0018

## Context and authority

The owner explicitly clarified: 「客戶希望的應用並非是讓會員與 lumi 聊天，
而是可以打招呼與提醒的互動；我們系統只需要在這一點上用力發揮即可」,
and requested implementation be delegated to Luna.

## Decision

Lumi focuses on noticing members, briefly greeting them and delivering useful,
authorized reminders. Routine greetings and reminders do not require an answer.
Choose one relevant point and leave silence after it. Do not invite small talk,
open another topic, or try to sustain a roughly thirty-second conversation.

Retain necessary interactions: informed consent, naming during enrollment,
corrections, and brief responses to member-initiated service questions. This
is a scope priority, not authorization to add an arbitrary refusal classifier
or to ignore a member who needs a direct reply.

The initial implementation is a bounded Infrastructure prompt/catalog slice,
with RED/GREEN composed-configuration tests and full repository verification.
It amends ADR-0014's expression policy and supersedes ADR-0016's duration target.
ADR-0016's explicit-goodbye lifecycle remains unchanged.

## Boundaries

- No reply required is an expression policy. It does not mean auto-disconnect,
  microphone muting, a newly invented silence timeout, or falsely completing
  required consent/name collection without an answer.
- No new official workout access, counts, departure inference, retention,
  recognition thresholds or sample-count rules are authorized by this decision.
- Existing on-demand tools and minimally disclosed consented encounter context
  remain distinct; pending ADR-0018 data decisions still block corresponding
  reminders and milestones.
- Preset audio must also align with the positioning. The currently accepted
  `07-goodbye` contains 「來跟我聊天」; a prompt edit cannot alter that recording.
  Track replacement and audio acceptance separately, without switching to an
  inappropriate leaving-the-store clip.
- Keep Clean Architecture and Application session ownership. No new generic
  conversation platform or parallel state controller is needed.

## Validation

Review named/anonymous returning members, unknown visitors, enrollment, available
memory, no-data cases, pre/post-workout directions and explicit goodbye. Test
what instructions are actually composed and preserve permission/tool boundaries.
Actual brevity, no forced response and audio consistency require Live field
acceptance; configuration assertions alone do not establish model compliance.

See [feature specification and work order](../greeting-reminder-first.md).
