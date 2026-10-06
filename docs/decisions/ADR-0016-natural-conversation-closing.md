# ADR-0016 — Brief Conversations and Explicit Goodbye

> Status: Accepted and implemented; automated checks passed, live semantic acceptance pending
> Date: 2026-09-17
> Related: ADR-0007, ADR-0014, ADR-0015, `docs/natural-conversation-closing.md`

## Context

The owner observed that Lumi encouraged continued conversation and selected
natural closing rather than a fixed-time termination. The owner also requested
that a visitor's explicit goodbye end the voice session. Existing short-answer
prompts do not provide that lifecycle behavior; the bundled goodbye recordings
previously had no automatic trigger.

## Decision

Guide Lumi toward roughly thirty-second welcoming exchanges, avoid unnecessary
follow-up questions, and continue helping when the visitor still has a question.
Thirty seconds is a conversational target, not a timer or cutoff. Preserve the
complete privacy, consent, and safety explanations required by existing rules.

Use the voice model's contextual interpretation of an explicit goodbye to
request a controlled end. Do not implement substring matching of words such as
「再見」. Negated, quoted, or language-learning uses are not goodbye intent.
Keep provider-specific tool details in Infrastructure and use a payload-free
Application lifecycle boundary for ending. The model cannot directly operate
hardware; the existing Application end-session flow controls return Home.

The Live composition uses the approved generic Marin clip `07-goodbye` once,
then ends the voice connection. This closes a conversation without assuming
the visitor is leaving the store. Suppress duplicate generated farewells and
prevent the recording from being interpreted as microphone input. Playback
failure must not keep an accepted closing session alive indefinitely.

Retain the existing presence wait after goodbye: an unchanged camera presence
does not immediately receive another greeting. The existing confirmed absence
condition rearms arrivals. No new identity tracking, checkouts, persisted data,
or inactivity threshold is introduced.

## Consequences and Verification

This amends ADR-0014's prompt-only boundary and ADR-0015's inactive goodbye
capability for the Live pilot. It retains the provider-independent Application
session ownership in ADR-0007 and the existing arrival policy.

Unit tests establish lifecycle behavior, cancellation, playback completion,
deduplication, and stale-event handling. Prompt fixtures cannot prove semantic
accuracy: positive and negative goodbye examples still require physical Live
conversation acceptance. No claim of a guaranteed thirty-second conversation
or a measured cost saving follows from this change.

Official API reference for the tool boundary:
[Realtime tools](https://developers.openai.com/api/docs/guides/realtime-mcp).
