# ADR-0004 — Face Match Confidence Policy

> Status: Proposed — Pending Validation
> Date: 2026-08-09
> Owners: Curves Lumi Product / iOS / ML
> Scope: Milestone 3 — Member Identity Recognition
> Related: `docs/identity-recognition.md`, `docs/roadmap.md`, `docs/decisions/ADR-0005-development-scope-and-boundaries.md`

---

## 1. Context

Curves Lumi uses the iPad camera, Apple Vision, and a Core ML face-embedding model to determine whether the current visitor matches an enrolled Curves member.

A recognition mistake has asymmetric product impact:

- **False Accept**: Lumi identifies the wrong person and calls them by another member's name.
- **False Reject**: Lumi fails to recognize a real member and falls back to a generic greeting.

For this product, a false accept is materially more harmful than a false reject because it can:

- create an embarrassing member experience
- expose another member's identity
- lead to inappropriate use of personalized exercise context
- reduce trust in Lumi
- create privacy concerns in a multi-person environment

Therefore the recognition system must not use a naive "highest score wins" rule.

This ADR defines the confidence policy architecture and decision rules.
It intentionally does **not** hard-code production thresholds before a representative validation dataset exists.

---

## 2. Decision

Curves Lumi will use a **conservative confidence policy** with the following rule:

> **Unknown is preferred over an uncertain identity claim.**

A visitor may be resolved to `known(MemberID)` only when all required confidence gates pass.

The confidence decision must consider more than one signal.

Minimum required signals:

1. **Top-1 match score**
2. **Top-1 vs Top-2 ambiguity margin**
3. **Face quality gate**
4. **Temporal consistency across multiple observations**

The production policy must not be based on one frame and one similarity score alone.

---

## 3. Decision Flow

The recognition decision follows:

```text
Query Face
↓
Face Quality Gate
├─ fail → unknown
└─ pass
    ↓
Generate Embedding
    ↓
Rank Member Candidates
    ↓
Top-1 Score Gate
├─ fail → unknown
└─ pass
    ↓
Top-1 / Top-2 Margin Gate
├─ ambiguous → unknown
└─ clear
    ↓
Temporal Confirmation
├─ inconsistent → unknown
└─ consistent
    ↓
known(MemberID)
```

---

## 4. Required Policy Inputs

The confidence policy should receive a model-independent input similar to:

```swift
struct RecognitionEvidence {
    let bestCandidate: MemberID?
    let bestScore: Double?
    let secondBestScore: Double?
    let faceQuality: FaceQuality
    let observations: [RecognitionObservation]
}
```

The Domain/Application layer must not depend on:

- Core ML tensor types
- embedding vector dimensions
- Vision request objects
- camera frame types

Model-specific values must be normalized or mapped before entering the confidence policy.

---

## 5. Policy Components

### 5.1 Face Quality Gate

Recognition should not proceed to a known identity when the source face is inadequate.

Possible inputs include:

- face bounding-box size
- detector confidence
- distance from image edge
- excessive blur, if measured reliably
- severe pose, if supported by the selected pipeline

The final quality thresholds must be validated.

Until validated, development values may be used only if clearly marked as provisional.

---

### 5.2 Top-1 Match Score Gate

The best candidate must exceed a production-approved acceptance threshold.

Conceptually:

```text
bestScore >= ACCEPT_THRESHOLD
```

If not:

```text
unknown
```

The threshold must be selected using validation data from the actual embedding model and target iPad environment.

No universal face-match threshold may be assumed.

---

### 5.3 Ambiguity Margin Gate

Even if the best candidate has a high score, Lumi must reject the identity if the second-best candidate is too close.

Conceptually:

```text
bestScore - secondBestScore >= MIN_MARGIN
```

If the margin is too small:

```text
unknown
```

This protects against visually similar members and crowded candidate spaces.

If the selected model uses distance rather than similarity, the equivalent distance formulation should be used.

---

### 5.4 Temporal Confirmation

A known identity should normally require confirmation over multiple observations.

Example acceptable pattern:

```text
Frame 1 → Wang 0.84
Frame 2 → Wang 0.86
Frame 3 → Wang 0.83

→ consistent candidate
```

Ambiguous pattern:

```text
Frame 1 → Wang 0.84
Frame 2 → Chen 0.82
Frame 3 → Wang 0.81

→ inconsistent
→ unknown
```

The production policy must define:

- minimum number of confirming observations
- maximum observation window
- allowable missed frames
- whether candidate continuity is required

These values remain pending validation.

---

## 6. Result Types

The policy returns an internal semantic decision, not raw scores alone:

```swift
enum RecognitionDecision: Equatable {
    case known(memberID: MemberID, confidence: RecognitionConfidence)
    case unknown(reason: UnknownReason)
}
```

Suggested internal reasons:

```swift
enum UnknownReason: Equatable {
    case noFace
    case lowFaceQuality
    case scoreBelowThreshold
    case ambiguousCandidates
    case inconsistentObservations
    case timeout
    case modelFailure
}
```

Application maps the internal decision to the public port result:

```text
RecognitionDecision
↓
RecognitionResult.known(memberID, confidence) / RecognitionResult.unknown
↓
IdentityRecognitionPort
```

`UnknownReason` remains internal to Domain/Application policy and diagnostics. It is not exposed through `IdentityRecognitionPort`, and Presentation/UI must not branch on it.

---

## 7. Product Behavior

### Known

When the policy returns:

```text
known(MemberID)
```

Lumi may:

- load the member profile
- use the approved display name
- enter personalized greeting flow
- load approved exercise context

### Unknown

When the policy returns:

```text
unknown
```

Lumi must:

- avoid guessing a name
- use a generic greeting
- avoid loading a member's private exercise context
- continue interaction where possible without identity

Example:

```text
「您好～歡迎來到 Curves！」
```

Unknown is a normal system outcome, not an error state.

---

## 8. Multi-Person Privacy

If multiple people are present, a known face match does not automatically imply that private member metrics may be spoken aloud.

Identity confidence and privacy permission are separate decisions.

Conceptually:

```text
IdentityRecognitionPolicy
↓
known(MemberID)

PLUS

ConversationPrivacyPolicy
↓
personalized_private_data_allowed?
```

A future ADR should define the nearby-person privacy behavior.

---

## 9. Threshold Selection Process

Production values for:

```text
ACCEPT_THRESHOLD
MIN_MARGIN
MIN_FACE_QUALITY
CONFIRMATION_COUNT
CONFIRMATION_WINDOW
```

must be selected through validation.

Required dataset characteristics:

- enrolled members
- multiple sessions / different days
- frontal and mild pose variation
- typical store lighting
- glasses where common
- unknown visitors
- similar-looking people where practical
- multiple-person scenes

Metrics should include:

- True Accept Rate (TAR)
- False Accept Rate (FAR)
- False Reject Rate (FRR)
- Unknown Rate
- recognition latency

The primary optimization objective for Lumi is:

> **Minimize False Accepts before maximizing recognition rate.**

A lower recognition rate is acceptable if it substantially reduces wrong-name greetings.

---

## 10. Validation Requirement

Before moving this ADR from `Proposed` to `Accepted`, the team must record:

1. Selected face embedding model
2. Matching metric
3. Validation dataset description
4. Sample size
5. Tested thresholds
6. FAR / FRR results
7. Selected production threshold
8. Selected ambiguity margin
9. Multi-frame confirmation rule
10. Performance on supported iPad hardware

The final values should be added in an appendix or a successor ADR if materially model-specific.

---

## 11. TDD Requirements

The confidence policy must be developed test-first.

### Required Unit Tests

#### Accept clear known member

```text
Given:
- good face quality
- best score above threshold
- sufficient margin
- consistent observations

Then:
known(MemberID)
```

#### Reject low score

```text
Given:
best score below threshold

Then:
unknown(.scoreBelowThreshold)
```

#### Reject ambiguous candidates

```text
Given:
best score above threshold
but top-1/top-2 margin insufficient

Then:
unknown(.ambiguousCandidates)
```

#### Reject inconsistent frames

```text
Given:
different top candidates across confirmation frames

Then:
unknown(.inconsistentObservations)
```

#### Reject low-quality face

```text
Given:
face quality below approved gate

Then:
unknown(.lowFaceQuality)
```

#### Boundary tests

Tests must cover values:
- immediately below threshold
- exactly at threshold
- immediately above threshold
- margin boundary
- confirmation-count boundary
- timeout boundary

---

## 12. Clean Architecture Constraints

`RecognitionConfidencePolicy`, `RecognitionDecision`, and `UnknownReason` live in Domain. Application maps `RecognitionDecision` to the public `RecognitionResult` returned through `IdentityRecognitionPort`.

It must be:

- deterministic
- synchronous if possible
- independent of Vision
- independent of Core ML
- independent of AVFoundation
- independent of network
- independently unit-testable

Incorrect:

```text
VNFaceObservation
↓
RecognitionConfidencePolicy
```

Correct:

```text
Infrastructure mapping
↓
RecognitionEvidence
↓
RecognitionConfidencePolicy
```

---

## 13. Configuration

Production thresholds must not be scattered as magic numbers.

Use one versioned configuration source.

Conceptual example:

```yaml
identity:
  confidence_policy_version: 1
  accept_threshold: TBD
  minimum_margin: TBD
  confirmation_count: TBD
  confirmation_window_ms: TBD
  minimum_face_quality: TBD
```

`TBD` values must block production acceptance.

Development defaults may exist only if clearly labeled:

```text
DEV_ONLY
NOT_VALIDATED
```

---

## 14. Model Versioning

Thresholds are coupled to the selected embedding model.

Therefore store:

```text
embedding_model_version
confidence_policy_version
```

with identity data and telemetry where appropriate.

Changing the embedding model may invalidate:

- existing embeddings
- score distributions
- thresholds
- ambiguity margins

A model change requires revalidation before production deployment.

---

## 15. Telemetry

Allowed aggregate events:

```text
identity_known
identity_unknown_low_score
identity_unknown_ambiguous
identity_unknown_quality
identity_unknown_inconsistent
identity_timeout
```

Allowed metrics:

- score distribution
- score-margin distribution
- known / unknown rate
- timeout rate
- latency
- validation false-accept rate

Do not log:

- raw embeddings
- face images by default
- member names
- sensitive profile details

If member identifiers are needed for secure debugging, use an approved pseudonymized identifier.

---

## 16. Consequences

### Positive

- Reduces wrong-name greetings
- Improves privacy
- Creates explicit Unknown behavior
- Makes matching behavior testable
- Avoids coupling to a single Core ML model
- Supports safe threshold tuning
- Allows future model replacement

### Negative

- Some real members will be classified as Unknown
- Enrollment quality becomes important
- Validation dataset is required
- Multi-frame confirmation adds some latency
- More policy parameters must be maintained

These tradeoffs are accepted because Lumi is a member-service assistant, not a high-security identity system, and trust is more important than maximum recognition coverage.

---

## 17. Alternatives Considered

### Alternative A — Highest Score Always Wins

Rejected.

Reason:
- forces a known identity even when all candidates are weak
- high false-accept risk
- unacceptable member experience

### Alternative B — Single Threshold Only

Rejected as insufficient.

Reason:
- does not detect ambiguous top candidates
- ignores temporal instability
- ignores face quality

### Alternative C — One-Frame Recognition

Rejected for production default.

Reason:
- vulnerable to transient frame quality
- more likely to produce unstable or incorrect identity

### Alternative D — Cloud Face Recognition

Not selected for this milestone.

Reasons:
- privacy complexity
- network dependency
- latency
- cost
- current architecture favors on-device Vision/Core ML

May be revisited only through a separate ADR.

---

## 18. Open Questions

The following remain unresolved and must be confirmed before this ADR becomes `Accepted`:

1. Which face embedding model will be used?
2. Which matching metric does that model recommend?
3. What validation dataset size is acceptable for the pilot?
4. What maximum false-accept rate is acceptable?
5. What recognition latency target is acceptable?
6. How many confirming frames should be required?
7. What recognition timeout should trigger generic greeting?
8. Should confidence thresholds be identical across all stores/devices?
9. How should model upgrades migrate stored embeddings?

Codex must not invent answers to these questions.

---

## 19. Acceptance Criteria for This ADR

This ADR may change from:

```text
Proposed
```

to:

```text
Accepted
```

only when:

- the embedding model is selected
- matching metric is selected
- validation dataset exists
- thresholds are measured
- ambiguity margin is measured
- temporal confirmation rule is measured
- false-accept behavior is reviewed
- TDD tests cover all policy branches
- the product owner approves the resulting tradeoff

---

## 20. Final Decision Summary

Curves Lumi face recognition will use a conservative multi-gate decision policy:

```text
Face Quality
+
Top-1 Match Strength
+
Top-1 / Top-2 Separation
+
Temporal Consistency
↓
Known or Unknown
```

The system will **not** force a member identity when evidence is weak or ambiguous.

> **A missed personalization is acceptable. A confidently wrong identity is not.**
