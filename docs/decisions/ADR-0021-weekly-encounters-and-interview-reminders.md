# ADR-0021 — Weekly Encounter Encouragement and Monthly Interview Reminders

> Date: 2026-10-01
> Status: Accepted product rules below; implementation and field acceptance pending
> Decision owner: Curves Lumi Product Owner
> Related: ADR-0017, ADR-0018, ADR-0019, ADR-0020

## Context

During the development-direction review, the owner requested progressively
warmer encouragement on the first, second, and third-or-later encounter in a
week. The owner accepted counting distinct Lumi encounter dates in Asia/Taipei,
Monday through Sunday, with each date counted at most once. These are encounters
with Lumi, not verified workouts or official store attendance.

The owner then specified the first ten calendar days of each month for
「量身面談」 reminders and selected 「每天最多一次，直到確認完成」. When asked
which completion source to use, the owner selected coach confirmation rather
than member self-report or a formal-system integration.

## Accepted decisions

### Arrival and short revisit amendment — 2026-10-06

The owner confirmed the following after testing the Live phone app:

- On the first recognized interaction of a Taipei date, the weekly arrival
  count includes this encounter: previously saved distinct observed dates in
  this Monday–Sunday week plus today. Keep writing only after greeting completion.
- Announce the exact observed weekly count with first/second/third-or-later
  encouragement, replacing the old frequent-meeting/long-absence opener. This
  describes Lumi observations, not verified workouts or first-ever attendance.
- A new interaction with the same member within thirty minutes of today's
  earliest saved greeting says only 「又見面啦，加油喔」, without repeating a count.
  Same-date revisits never increase the count or reset the first-record time.
- At or after thirty minutes, the existing departure count and encouragement
  take precedence. Continuous presence and provider reconnects do not create a
  new opener. All existing independent memory consent, known-member binding,
  read-failure fallback and recording protections remain in effect.
- Arrival context must expire on Taipei date change or clock rollback; it must
  not become yesterday's count in a still-running voice session.

This supersedes the remaining arrival ordinal, same-day wording and precedence
questions below. Monthly reminders and their unresolved contracts are unchanged.

### Customer-interview follow-up: count source and departure

- The owner selected Lumi observations as the first weekly-count and monthly
  twelve-visit milestone source: 「我們看到一次就算一次」. Seeing the same member
  multiple times on one store day still contributes at most one count.
- On 2026-10-02 the owner confirmed the existing three seconds without a usable
  face for ending/rearming the interaction. This may include occlusion or
  unusable frames; it is not person detection. Departure encouragement instead
  plays while the member is visible: reliably recognize the same member again
  at least thirty minutes after today's first saved observed greeting.
- Use the earliest valid observed greeting on the current Asia/Taipei date;
  intermediate encounters do not reset the thirty minutes or increase today's
  count. Continuous presence reaching thirty minutes does not trigger speech.
  Missing consent/history, unknown identity, invalid/future timestamps and date
  changes cannot establish eligibility. Keep existing completed-greeting writes.
- This eligible encounter's opener replaces the ordinary welcome with the
  observed calendar-week count and short encouragement: below three encourage
  reaching three; at/above three praise consistency and continuing. Do not
  claim verified workouts, ask for a reply or close via model intent. Existing
  camera absence ends the interaction. Complete one opener per interaction;
  reconnects do not replay it. No once-per-day farewell limit was introduced.
- `MemberMemorySnapshot.weeklyMeetingDayCount` now derives distinct observed
  dates in the Monday–Sunday store week through the existing consented memory
  load. It includes only already-recorded greetings, excludes future/invalid
  timestamps and member-reported events, and preserves the rolling-seven-day
  highlight. The eligible departure opener is now wired through Application's
  bound, consented memory context to Infrastructure; timestamps and IDs stay
  local, only the observed weekly count is disclosed. First/second/third arrival
  wording is wired under the 2026-10-06 amendment above. Device speech acceptance
  remains pending.

### Weekly encounter encouragement

- Use consented local Lumi encounter history, with distinct Asia/Taipei dates
  in the current Monday–Sunday calendar week. A same-day revisit does not
  increase the weekly count.
- First encounter: express happiness to see the member. Second: acknowledge
  continued participation. Third and later: give stronger encouragement while
  keeping the message brief. Exact wording is not fixed by this decision.
- Describe seeing the member; do not claim completed workouts or official
  attendance from encounter history.
- This new weekly opener differs from ADR-0017's implemented rolling-seven-day
  frequent-encounter context. The weekly opener is implemented under the
  2026-10-06 amendment; this does not remove the fourteen-day long-time-no-see rule,
  ninety-day encounter retention, independent consent, or clear/disable rules.
- Preserve existing known-member binding and recording only after a greeting
  completes. The 2026-10-06 amendment specifies the pre-write ordinal, same-day
  wording and opener precedence; history derivation and retention remain intact.

### Monthly interview reminder

- The reminder window is calendar dates 1–10 inclusive, not ten days starting
  from a deferred date. This supersedes the earlier seven-day proposal.
- For each member, remind at most once per day within that window, until the
  current month's completion has been confirmed. Each eligible later day may
  have a reminder; the member is not required to answer it.
- A coach confirms completion through an operator entry point. A member saying
  she has completed it does not by itself confirm completion. Formal API
  integration is not required as the first completion source.
- Completion for the current month stops further reminders for that month.
  An earlier month's completion cannot confirm a later month's activity.
- 「量身」 and 「面談」 remain one activity and one completion state, named
  「量身面談」.
- ADR-0018's first-day-Sunday deferral to the first business day remains in
  force; the overall window still ends on calendar date 10. Business-day data
  has not yet been selected.

## Remaining decisions before affected implementation

- Coach access control, how the coach selects a reliably bound member, and
  whether confirmation applies only to the current month or permits correction
  of another month.
- Consent for interview/reminder records, storage and retention, correction,
  clearing/disabling, and handling previously confirmed completion after a clear.
  Existing face or encounter-memory consent does not authorize this extension.
- Reminder date boundary (Asia/Taipei is recommended), whether a playback attempt
  or audible completion consumes the daily allowance, playback interruption,
  and persistent deduplication across reconnects and App restarts. The daily
  limit is accepted; the delivery/storage contract is not yet selected.
- Priority or composition when weekly encouragement and the monthly reminder
  are both available. Monthly-reminder priority was proposed, not confirmed.
- Missing history, unavailable completion status, and multiple-person privacy
  behavior; absence of a record is not proof of never visiting or not completing
  the interview.

Pending rules block only their affected implementation. Measurement and the
already-approved reliability work can continue. No new production behavior,
Release enablement, cloud sync, official workout access, recognition thresholds,
or automatic session timeout is introduced by this documentation change.

## Validation required when implemented

Use RED → GREEN → REFACTOR. Cover week boundaries, distinct dates and same-day
revisits; dates 1/10/11, same-day suppression and next-day eligibility; coach
confirmation, member self-report without confirmation, month changes, correction,
and the agreed playback/restart/consent failure semantics. Unknown or stale
sessions must not access or mutate a different member's records.

Run the required Swift tests and unsigned Simulator build, then use the Live
composition for physical acceptance of brief delivery, no obligatory reply,
daily suppression, coach confirmation, and the next member's welcome. Automated
checks alone do not establish these live behaviors.
