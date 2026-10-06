# ADR-0020 — Notice first, personalize after reliable recognition

> Date: 2026-09-30
> Status: Accepted direction and first interaction choices; numerical gates, blink trigger and remaining UX details pending
> Related: ADR-0004, ADR-0015, ADR-0018, ADR-0019

## Context

The owner asked whether face recognition works at a distance and accepted the direction: 「遠處先注意到人臉，靠近且身分可靠後，再叫名字與做個人提醒。」 The current continuous flow treats the first fully usable face as an arrival and immediately proceeds to identity and voice. It has no distance/face-size gate. Neither a `known` result nor an `unknown` result measures physical distance.

## Decision

Separate non-identifying face notice from permission to make a personal greeting. Member names and personal reminders require the existing reliable `known(MemberID)` identity result and an approved approach condition. The preliminary notice must not imply identity. Preserve the existing confidence policy and fail closed when identity is uncertain.

The owner then selected one generic distant 「你好」, camera-frame face size as the approach criterion, and no further speech if the person never approaches. After a reliable near-stage identity result, Lumi may use the confirmed name and an authorized reminder; it must not repeat the distant 「你好」. Lumi may blink when a face looks toward the camera. The existing Avatar already blinks naturally; a camera-triggered blink, the face-facing criterion and numeric approach gate are not yet specified or enabled. This ADR records the accepted interaction without enabling a new trigger. The remaining gates are explicit in the [feature spec](../two-stage-presence-greeting.md) and [roadmap](../roadmap.md).

## Consequences

- Profile face geometry and stage timing on the actual Live device before promising a distance or setting geometry thresholds.
- Any geometric evidence stays anonymous and originates in Infrastructure; Application orchestrates stages, Domain owns provider-neutral rules, and Presentation owns UI values.
- Existing three fresh recognition samples, 2-of-3 decision, thresholds, single-face fail-closed behavior and continuous-absence rearm remain unchanged unless separately approved and verified.
- An unknown identity must never be treated as proof of distance or converted into a member name.
