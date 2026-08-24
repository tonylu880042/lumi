# ADR-0013 — Conversational Face Enrollment Pilot

> Status: Implemented for Debug-Live pilot
> Date: 2026-08-23
> Decision owner: Curves Lumi Product Owner
> Scope: Unknown-visitor consent, local enrollment, naming, and voice tools
> Related: `SYSTEM_SPEC.md`, `docs/identity-recognition.md`, ADR-0004, ADR-0009, ADR-0010

## Context

The 44B pilot can recognize locally enrolled identities, but an Unknown visitor
still needs an operator to open the DEBUG calibration tool and enter a temporary
ID. The product goal is for Lumi to ask permission, learn the visitor's face,
and ask how to address them without silently enrolling passersby or using a
display name as an identity key.

## Decision

For Debug-Live only, Lumi offers this sequence to a public-Unknown visitor:

1. Explain that face features will be captured so Lumi can remember the visitor.
2. On a clear affirmative response, invoke `begin_visitor_enrollment`.
3. Capture exactly three fresh usable samples into an in-memory pending value.
4. Ask `我該怎麼稱呼您呢？`.
5. Validate the answer as `VoiceMemberAddress`, generate a local UUID-backed
   `MemberID`, and invoke `complete_visitor_enrollment`.
6. Atomically persist the local profile, consent timestamp, and three SFace
   embeddings, then confirm the voluntarily provided label to the assistant.

Refusal invokes no enrollment tool. Cancellation, departure, session end,
capture failure, invalid naming, or an incomplete flow discards all pending
samples. No provisional embedding is written. No image, embedding, score, or
generated member ID crosses the voice tool boundary or leaves the device.

The provider interprets conversational consent and the volunteered label, but
it does not make face-identity decisions. Application owns the two normalized
tool contracts, sequencing, and generated local identity; Infrastructure owns
camera, Vision/Core ML, temporary embeddings, and atomic SQLite persistence.
The next visit uses the existing confidence policy and resolves the local UUID
to its stored spoken label.

## Consequences

- The local profile schema is additive and keyed by generated UUID, not name.
- Existing manual pilot IDs remain readable through the current safe-label
  fallback until CMS migration is available.
- Known-member weekly-summary tools and Unknown enrollment tools are mutually
  exclusive per voice session.
- Release enrollment, production confidence thresholds, legal consent copy,
  CloudKit backup, deletion UI, and Curves CMS binding remain separate gates.

## Acceptance criteria

- A refusal stores nothing and does not start the enrollment camera.
- Begin succeeds only after three usable samples are pending in memory.
- Complete is impossible before begin and rejects invalid labels.
- Commit is atomic; failure leaves no profile or embedding rows.
- Ending any incomplete session clears pending samples and stops the camera.
- A subsequent recognition resolves the generated UUID to the stored label and
  may greet `<名稱>，歡迎回來～`.

## Implementation evidence

The 2026-08-23 implementation keeps the provider boundary to two normalized
tools. Application owns their order, opaque-call replay, cancellation cleanup,
and generated local identity. Infrastructure captures three new frames through
the existing Vision → YuNet → SFace graph, holds the embeddings in actor memory,
and commits the local profile plus exactly three embeddings in one SQLite
transaction. Debug-Live recognition, conversational enrollment, and subsequent
spoken-label lookup share one lazily loaded Core ML service and database.

TDD evidence includes focused Application router `10/10`, session runner `3/3`,
Infrastructure enrollment/SQLite `13/13`, Realtime wire `14/14`, the combined
Realtime/router/coordinator gate `121/121`, and the hosted Debug-Live App gate
`92/92`. The generic unsigned Simulator build, Swift release build, Mock
Release build, and Release-Live build succeeded. The exact package-wide
`swift test` gate built, passed its `4/4` XCTest snapshots, and showed no
visible Swift Testing failure (including all new suites), but the existing
`swiftpm-testing-helper` lifecycle hang again prevented a clean completion
summary; no package-wide pass count is claimed.

These automated results do not prove physical-camera enrollment quality,
natural spoken-consent behavior, or a successful next-visit conversation on
the owner's device. Those remain manual Debug-Live checks before any Release
or production-enrollment decision.
