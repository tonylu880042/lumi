# ADR-0015 — Arrival Vitality and Bundled Marin Greetings

> Status: Accepted for the local pilot; automated and Simulator validation passed, physical-device acceptance pending
> Date: 2026-09-15
> Validation: 2026-09-16
> Related: ADR-0007, ADR-0014, `docs/phase-3-store-arrival-vitality-draft.md`

## Context

The owner wants Lumi to respond emotionally to arriving visitors even when they
do not converse, and to reuse the accepted Marin recordings to reduce repeated
greeting generation. Checkouts cannot establish arrival traffic. The current
camera exposes usable-face presence, not distinct-person or entrance tracking.

## Decision

Use a non-identifying arrival proxy with a latch that survives voice retries.
Continuous three-second absence rearms it; unavailable observations do not
establish absence. Domain classifies the last ten minutes as calm (0–2), happy
(3–5), or excited (6+), retaining only the latest six event times. Application
owns observation handling and time-based updates. Presentation maps vitality to
visual values while preserving higher-priority conversational expressions.

Bundle the eight accepted Marin WAVs in Infrastructure. Select a greeting from
the known/unknown category using current vitality and avoid consecutive repeats.
The two goodbye clips have playback support without a new automatic trigger.
When using a local opener, suppress provider-generated opening requests on both
cold and standby startup, protect microphone input from local playback echo, and
resume ordinary Realtime conversation after the recording completes. Reconnect
does not replay the opener. Existing consent and tool authorization stay intact.

This amends ADR-0007's provider-generated initial greeting for the configured
local pilot only. It also amends ADR-0014's generated opener while preserving
its natural-conversation, privacy and consent policy for subsequent dialogue.

## Alternatives and Consequences

Generating every opener remains available for compositions without local audio,
but does not provide the requested reuse. Exact store traffic requires another
sensor/tracking decision; it is not inferred from a single face-presence flag.
Identity enrollment or MemberID tracking is unnecessary for this feature.

The pilot cannot count simultaneous people or distinguish a returning person
after the absence reset. Its bounded in-memory events are an emotion input, not
attendance or occupancy analytics. Local playback avoids repeated audio
generation; Realtime dialogue continues to incur usage. Tests can prove control
flow and asset integrity, while physical-device audio and camera acceptance
remain separate from this local implementation.

The existing camera lifecycle also has observation gaps during recognition and
startup; this integration does not provide continuous all-day traffic sensing.
Independent verification passed 833 Swift package tests, 117 App Simulator
tests, and both standard and Live Simulator builds. All eight bundled WAVs match
the approved originals. No physical deployment or paid end-to-end API test was
performed; detailed results are recorded in the feature specification.

## Integration Note

Owner amendment (2026-09-17): the accepted recordings may be mastered offline
to reduce the reported volume mismatch with Live speech. Keep the original
recordings and reproducible measurements outside the shipped resource bundle;
the bundled derivatives preserve voice, words, sample rate, and duration while
adjusting loudness with peak protection. This supersedes byte-for-byte equality
with audition originals for calibrated resources. Physical output matching is
still a device acceptance task; see `../audio-loudness-calibration.md`.

The current GA Realtime session configuration uses `max_output_tokens`; the
older `max_response_output_tokens` key belongs to the beta schema. Preserve the
configured cap when deriving a per-visitor configuration, and serialize the GA
key so the session update is accepted. This is an integration repair, not a new
output-length policy. Source: [OpenAI Realtime client events](https://platform.openai.com/docs/api-reference/realtime-client-events/session?lang=node.js).
