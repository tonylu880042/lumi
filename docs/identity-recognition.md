# Curves Lumi — Identity Recognition Specification

> File: `identity-recognition.md`
> Status: Draft for implementation
> Last updated: 2026-08-09
> Scope: Milestone 3 — Member Identity Recognition
> Principles: Clean Architecture + TDD + Ask-if-Unclear
> Decisions: `docs/decisions/ADR-0004-face-match-confidence-policy.md`, `docs/decisions/ADR-0005-development-scope-and-boundaries.md`

---

## 1. Purpose

This document defines the implementation specification for **Curves Lumi member identity recognition**.

The goal is to allow the iPad-based Lumi device to determine whether the person currently in front of the device is a registered Curves member, and if so resolve that person to a stable `MemberID`.

The recognition system must prefer **Unknown** over an incorrect identity claim.

This feature is not intended to provide:
- medical identification
- legal identity verification
- payment authorization
- access control
- security authentication

It is a convenience feature for personalized greeting and member interaction.

---

## 2. Product Experience

Target user flow:

```text
Person approaches Lumi
↓
Presence confirmed
↓
Rotation base points approximately toward visitor
↓
iPad camera confirms face
↓
Face is detected
↓
Face is normalized
↓
Face embedding generated
↓
Embedding compared with enrolled members
↓
Confidence policy evaluated
├─ Known member → MemberID
└─ Unknown → generic visitor
↓
AssistantSessionCoordinator
↓
Greeting
```

Known member example:

```text
RecognitionResult.known(MemberID("M123456"))
↓
LoadMemberContextUseCase
↓
「王小姐～歡迎回來！」
```

Unknown example:

```text
RecognitionResult.unknown
↓
「您好～歡迎來到 Curves！」
```

The UI must never guess or infer a display name when recognition confidence is insufficient.

---

## 3. Architecture Boundary

Identity recognition must follow Clean Architecture.

Dependency direction:

```text
LumiUI
↓
LumiPresentation
↓
LumiApplication
↓
LumiDomain

Infrastructure
↑ implements Application Ports
```

Apple frameworks must remain outside Domain/Application:

- AVFoundation
- Vision
- Core ML
- Accelerate if used
- camera hardware
- image formats
- model-specific vector dimensions

### 3.1 Application Port

Application must depend only on an abstraction similar to:

```swift
protocol IdentityRecognitionPort {
    func recognizeCurrentVisitor() async throws -> RecognitionResult
}
```

Alternative event-oriented form is acceptable if already consistent with the codebase, but Infrastructure details must not leak inward.

### 3.2 Domain Result

Domain should expose a small semantic result:

```swift
enum RecognitionResult: Equatable {
    case known(memberID: MemberID, confidence: RecognitionConfidence)
    case unknown
}
```

`RecognitionConfidence` should be a Domain value object, not a raw Vision/Core ML SDK value.

Example:

```swift
struct RecognitionConfidence: Equatable, Comparable {
    let value: Double
}
```

Domain must not know:
- face embedding length
- Core ML model type
- `VNFaceObservation`
- `CVPixelBuffer`
- `CGImage`
- Vision request classes

### 3.3 Internal Policy Decision

The confidence policy returns an internal Domain decision with a diagnostic reason:

```swift
enum RecognitionDecision: Equatable {
    case known(memberID: MemberID, confidence: RecognitionConfidence)
    case unknown(reason: UnknownReason)
}
```

Application maps that decision to the public port result:

```text
RecognitionDecision.known(memberID, confidence)
→ RecognitionResult.known(memberID, confidence)

RecognitionDecision.unknown(reason)
→ RecognitionResult.unknown
```

`UnknownReason` remains internal to Domain/Application policy and diagnostics. It must not cross `IdentityRecognitionPort`, and Presentation/UI must not branch on low-level recognition failure reasons.

---

## 4. Recommended Infrastructure Components

Suggested structure:

```text
LumiInfrastructure/
└── Identity/
    ├── Camera/
    │   ├── CameraCaptureAdapter.swift
    │   └── CameraPermissionAdapter.swift
    ├── Vision/
    │   ├── VisionFaceDetector.swift
    │   ├── FaceTargetSelector.swift
    │   └── FaceNormalizer.swift
    ├── Embedding/
    │   ├── FaceEmbeddingModelAdapter.swift
    │   └── EmbeddingNormalizer.swift
    ├── Matching/
    │   ├── MemberEmbeddingStore.swift
    │   ├── MemberMatcher.swift
    │   └── SimilarityMetric.swift
    ├── Enrollment/
    │   ├── EnrollmentService.swift
    │   └── EnrollmentRepository.swift
    └── VisionCoreMLIdentityAdapter.swift
```

Suggested test targets:

```text
Tests/
├── LumiDomainTests/
├── LumiApplicationTests/
└── LumiInfrastructureTests/
    └── Identity/
```

---

## 5. Identity Pipeline

The full recognition pipeline is:

```text
AVFoundation Camera
↓
Frame Sampling
↓
Vision Face Detection
↓
Target Face Selection
↓
Face Crop
↓
Orientation / Alignment / Normalization
↓
Core ML Face Embedding
↓
Embedding Normalization
↓
Member Matching
↓
RecognitionConfidencePolicy
↓
known(MemberID) / unknown
```

Each stage must be independently testable.

---

# 6. I1 — Camera Capture

## Goal

Acquire front-camera frames from iPad in a form suitable for Vision processing.

Technology:
- AVFoundation

Responsibilities:
- request camera permission
- configure front camera
- start/stop capture session
- provide frames
- handle orientation
- respond to app lifecycle
- recover from camera interruptions where practical

### Must Not

Camera adapter must not:
- determine identity
- perform member lookup
- access Curves member data
- decide recognition confidence

### Frame Sampling

Do not process every camera frame unless performance measurements justify it.

Use configurable sampling, for example:

```text
camera 30 fps
recognition processing 3–10 fps
```

Exact rate must be measured and configurable.

### Tests

Use abstractions/fakes for:
- permission granted
- permission denied
- camera unavailable
- capture session interruption
- frame delivery

---

# 7. I2 — Vision Face Detection

## Goal

Detect human faces in captured frames.

Technology:
- Apple Vision

Expected output:

```swift
struct DetectedFace {
    let boundingBox: NormalizedRect
    let confidence: Double
}
```

Use an Infrastructure-owned type or mapping type; do not expose Vision request objects to Application.

### Required Cases

- no face
- one face
- multiple faces
- partially visible face
- low confidence detection
- rotated input
- camera orientation changes

### Face Quality Gate

A face may be rejected before embedding if it fails configurable quality criteria such as:
- too small in frame
- too close to image edge
- insufficient detector confidence
- excessive blur if a reliable local metric is implemented

Do not silently invent thresholds. Thresholds require validation and an ADR.

---

# 8. I3 — Active Face Target Selection

## Goal

When multiple faces are visible, select one person as the current Lumi interaction target.

Only one active identity target is supported in MVP.

Potential signals:
- face size
- face distance from screen center
- physical direction from ultrasonic sensors
- previously tracked target continuity
- recognition status

### Unresolved Product Decision

If the target-selection policy has not been explicitly approved, implementation must stop and ask.

Recommended MVP candidate:

```text
1. Use the face nearest the current rotation / visual center.
2. Prefer temporal continuity with the previous selected face.
3. If ambiguous, avoid personalized identity interaction.
```

Do not automatically prioritize "recognized member" if doing so could cause Lumi to switch attention unexpectedly between people.

### Tests

- one face
- two faces, clear center winner
- two similarly centered faces
- current target persists across frames
- current target exits
- ambiguous selection

---

# 9. I4 — Face Normalization

## Goal

Transform a detected face into a consistent model input.

Responsibilities may include:
- crop face ROI
- include configurable margin
- correct orientation
- resize
- normalize pixel values
- optional alignment if supported by selected embedding model

The exact preprocessing pipeline must follow the chosen embedding model specification.

### Important Rule

Do not invent preprocessing from intuition.

If the selected model expects:
- specific input size
- RGB/BGR order
- mean/std normalization
- landmark alignment

those requirements become part of the implementation contract.

### Determinism

Given the same source image and face box, normalization must produce deterministic output.

Tests should use fixed image fixtures.

---

# 10. I5 — Face Embedding

## Goal

Convert the normalized face into a numerical vector suitable for similarity matching.

Technology:
- Core ML

Architecture:

```text
FaceEmbeddingPort / adapter abstraction
↓
Core ML model implementation
```

Suggested Infrastructure interface:

```swift
protocol FaceEmbeddingEngine {
    func embedding(for normalizedFace: NormalizedFace) async throws -> FaceEmbedding
}
```

`FaceEmbedding` must remain Infrastructure-side unless the existing architecture explicitly places it in an adapter-neutral internal layer.

Domain should not depend on embedding dimensions.

### Model Selection

The exact face embedding model is a blocking specification decision.

Before implementation, document:
- model name
- source / license
- input format
- embedding dimension
- preprocessing requirements
- expected similarity metric
- on-device performance
- redistribution constraints

If the model is not yet selected, Codex must ask before implementing the real embedding adapter.

Mocks may be created earlier.

---

# 11. I6 — Member Embedding Storage

## Goal

Store one or more enrolled face embeddings for each member.

Identity key:

```text
MemberID
```

Never use display name as the primary key.

Suggested data:

```swift
struct EnrolledIdentityRecord {
    let memberID: MemberID
    let embeddings: [StoredFaceEmbedding]
    let createdAt: Date
    let modelVersion: String
}
```

Store model version because embeddings from different models may not be compatible.

### Security / Privacy

Face embeddings are sensitive biometric-style identity data.

Requirements:
- never log raw embeddings
- encrypt at rest where practical
- restrict access to identity subsystem
- separate display/member profile data from recognition vectors
- support deletion when enrollment is revoked
- version model metadata

Do not send face embeddings to the LLM.

---

# 12. I7 — Member Matching

## Goal

Match a query embedding against enrolled member embeddings.

Candidate metrics:
- cosine similarity
- Euclidean distance

The final metric must follow the selected embedding model recommendation.

### Multiple Embeddings Per Member

A member should support multiple enrollment samples.

Possible aggregation methods:
- best match
- average similarity
- centroid embedding
- top-k average

This is a product/algorithm decision and must be validated.

Recommended initial implementation for simplicity:

```text
compare query against all stored embeddings
↓
take best score per member
↓
rank members
↓
apply confidence policy
```

### Matching Result

Infrastructure may produce:

```swift
struct MatchCandidate {
    let memberID: MemberID
    let score: Double
}
```

Then map through the confidence policy.

---

# 13. I8 — Recognition Confidence Policy

## Goal

Convert raw match scores into a safe semantic identity decision.

Core product rule:

> **Unknown is better than calling the wrong member name.**

### Required Outcomes

```text
clear high-confidence winner
→ known(MemberID)

score below threshold
→ unknown

top candidates too close
→ unknown

image quality insufficient
→ unknown
```

### Suggested Policy Inputs

- best match score
- second-best match score
- score margin
- face quality
- number of observations
- temporal consistency across frames

### Do Not Use One Frame Only by Default

For production quality, prefer confirmation over multiple observations.

Example concept:

```text
frame 1 → Wang 0.82
frame 2 → Wang 0.85
frame 3 → Wang 0.84
→ consistent known result
```

versus:

```text
frame 1 → Wang 0.82
frame 2 → Chen 0.81
frame 3 → unknown
→ ambiguous → unknown
```

Exact confirmation count and thresholds must be validated, not guessed.

### Threshold Decision

The following must be defined through a validation dataset and documented in an ADR:

```text
accept threshold
ambiguity margin
minimum face size / quality
number of confirming frames
timeout before fallback to unknown
```

---

# 14. I9 — Enrollment

## Goal

Create high-quality face references for registered members.

Recommended initial capture:
- 3–5 samples per member
- frontal
- mild left angle
- mild right angle
- typical appearance variation where practical

Possible enrollment flow:

```text
Member identified through existing Curves system
↓
Consent / enrollment action
↓
Capture multiple face images
↓
Vision confirms quality
↓
Normalize
↓
Generate embeddings
↓
Store under MemberID
```

### Enrollment Must Not

- silently enroll anyone who walks past
- use face recognition alone to decide the enrollment identity
- store display name as the identity key
- overwrite previous model version without migration strategy

### Enrollment Quality Checks

Possible checks:
- exactly one face
- sufficient face size
- sufficient detector confidence
- pose diversity
- duplicate sample rejection

Thresholds require validation.

---

# 15. End-to-End Identity Adapter

Suggested implementation:

```swift
final class VisionCoreMLIdentityAdapter: IdentityRecognitionPort {
    // camera
    // detector
    // selector
    // normalizer
    // embedding engine
    // embedding store
    // matcher
    // confidence policy
}
```

The class may internally delegate to smaller components.

Avoid a single giant adapter containing all algorithm logic.

Preferred orchestration:

```text
IdentityRecognitionPort
↓
IdentityRecognitionService
├─ CameraFrameProvider
├─ FaceDetector
├─ FaceTargetSelector
├─ FaceNormalizer
├─ FaceEmbeddingEngine
├─ MemberEmbeddingRepository
├─ MemberMatcher
└─ RecognitionConfidencePolicy
```

---

# 16. Integration with Assistant State

Identity recognition participates in the existing state flow:

```text
detected
↓
rotating
↓
recognizing
├─ KnownMember(MemberID)
│   ↓
│ greeting
│
└─ Unknown
    ↓
  generic greeting
```

`AssistantSessionCoordinator` remains the single owner of the session state.

Vision infrastructure must not directly mutate UI state.

Correct:

```text
VisionCoreMLIdentityAdapter
↓
RecognitionResult
↓
Use Case / Coordinator
↓
AssistantState
↓
Presentation
```

Incorrect:

```text
Vision callback
↓
SwiftUI View directly changes to greeting
```

---

# 17. Timeout / Fallback

Recognition must not block the greeting indefinitely.

If no safe identity can be established within a configurable timeout:

```text
recognizing
↓
timeout
↓
RecognitionResult.unknown
↓
generic greeting
```

The exact timeout is a product decision.

Do not invent a final timeout value without confirmation.

A provisional dev default may exist only if clearly marked as non-product behavior.

---

# 18. Multi-Person Privacy

When multiple people are visible:
- avoid speaking private exercise metrics unless privacy policy allows
- do not announce uncertain identity
- do not switch member context rapidly between people
- maintain one active session target

If identity is known but another person is within close proximity, the application may need a privacy-safe greeting mode.

The exact privacy behavior must be confirmed and documented.

---

# 19. Failure Modes

Required failure handling:

### Camera Permission Denied
- do not crash
- show/voice generic interaction where possible
- identity recognition unavailable

### Camera Unavailable
- return unknown
- telemetry event

### Vision Failure
- return recoverable identity error / unknown based on Use Case policy

### Core ML Failure
- do not expose model error to user
- fallback to unknown
- record non-sensitive telemetry

### Embedding Store Failure
- do not guess identity
- fallback to generic greeting

### No Enrolled Members
- recognition returns unknown cleanly

### Network Offline
Identity recognition should remain on-device if the selected architecture supports local embeddings.

Do not require cloud connectivity solely for face matching unless explicitly decided.

---

# 20. Performance Requirements

Targets must be measured on the actual supported iPad hardware.

Track:
- camera-to-face-detection latency
- embedding latency
- match latency
- end-to-end recognition latency
- CPU/GPU/Neural Engine utilization where available
- thermal behavior
- memory usage

Do not hard-code performance assumptions from Simulator measurements.

Recognition should feel responsive enough that Lumi can greet naturally after turning toward the visitor.

---

# 21. Telemetry

Allowed telemetry examples:

```text
identity_session_started
face_detected
face_not_detected
multiple_faces_detected
recognition_known
recognition_unknown
recognition_timeout
camera_permission_denied
vision_error
embedding_error
matching_error
```

Metrics:
- recognition attempts/day
- known recognition rate
- unknown rate
- false-recognition validation rate
- average recognition latency
- multi-face frequency
- timeout rate

Never log:
- raw face images by default
- face embeddings
- member names in diagnostic logs
- full member profiles
- model inputs unless explicitly enabled in secure development mode

---

# 22. TDD Strategy

All identity behavior follows RED → GREEN → REFACTOR.

## Domain / Policy Tests

Test:
- confidence value validation
- known / unknown decision rules
- ambiguity margin
- multi-frame consensus
- timeout fallback policy

These tests require:
- no camera
- no Vision
- no Core ML
- no network

## Application Tests

Use mocked `IdentityRecognitionPort`.

Example:

```text
Given:
IdentityRecognitionPort returns known(M123456)

When:
RecognizeVisitorUseCase executes

Then:
member context loading begins for M123456
```

and:

```text
Given:
IdentityRecognitionPort returns unknown

Then:
generic greeting context is used
```

## Infrastructure Tests

Use fixed fixtures to test:
- Vision face box mapping
- normalization
- model input formatting
- embedding normalization
- similarity math
- member ranking
- serialization
- model version compatibility

## Regression Tests

Every false-positive identity bug must add a regression test before the fix.

---

# 23. Acceptance Test Matrix

Minimum acceptance scenarios:

| Scenario | Expected Result |
|---|---|
| registered member, good frontal image | known member |
| registered member, mild angle | known or safe unknown |
| registered member, glasses variation | validated expected behavior |
| stranger | unknown |
| two similar candidates | unknown if ambiguous |
| low-quality face | unknown |
| no face | unknown / continue search until timeout |
| two faces | target-selection policy applied |
| camera denied | generic fallback |
| model unavailable | generic fallback |
| enrollment record deleted | unknown |

Do not define accuracy targets without a validation dataset.

---

# 24. Validation Dataset

Before setting production thresholds, build a representative validation dataset.

It should include:
- enrolled members
- multiple images per enrolled member
- different visit days
- typical lighting
- mild pose variation
- glasses if common
- unknown non-members
- similar-looking people if available
- multi-person frames

Measure:
- True Accept Rate
- False Accept Rate
- False Reject Rate
- Unknown rate
- latency

For Lumi, false accepts are especially costly because they cause Lumi to call someone by the wrong name.

Therefore threshold selection should prioritize low false-accept rate over maximum recognition rate.

---

# 25. Blocking Decisions — Ask Before Implementation

Codex must ask the product owner if any of the following are unresolved:

1. Which face embedding model will be used?
2. What license constraints are acceptable?
3. Which supported iPad models are targeted?
4. Is identity storage device-local, server-side, or both?
5. How is member enrollment consent handled?
6. What is the active-face selection rule for multiple people?
7. What recognition timeout is acceptable?
8. What validation target is required before pilot?
9. How many enrollment images are mandatory?
10. How should Lumi behave when a member is recognized but others are nearby?
11. Is recognition expected to work fully offline?
12. How should embeddings be deleted when enrollment is revoked?
13. What threshold / ambiguity margin is approved after validation?

Do not silently choose product answers.

---

# 26. Non-Goals for Milestone 3

Do not implement:
- full anti-spoofing / liveness authentication unless separately specified
- security access control
- payment authentication
- legal identity verification
- age estimation
- gender inference
- emotion inference
- race/ethnicity inference
- health inference from face
- cloud face-recognition service unless approved
- LLM-based face identity decisions

---

# 27. Milestone Exit Criteria

Milestone 3 is complete only when:

- `IdentityRecognitionPort` is implemented by a Vision/Core ML adapter.
- Camera capture works on supported iPad hardware.
- Vision face detection is stable.
- Multi-face target-selection behavior is confirmed and tested.
- Face normalization is deterministic.
- Embedding model and license are documented.
- Member enrollment supports multiple samples.
- Matching works with multiple embeddings/member.
- Confidence/Unknown policy is validated.
- Stranger cases default safely to Unknown.
- Recognition timeout falls back to generic greeting.
- Domain/Application do not import Vision/Core ML/AVFoundation.
- Tests pass.
- Validation results are documented.
- Important decisions are recorded as ADRs.

---

# 28. Recommended ADRs

Create as decisions are confirmed:

```text
docs/decisions/
├── ADR-identity-001-face-embedding-model.md
├── ADR-identity-002-matching-metric.md
├── ADR-identity-003-confidence-threshold.md
├── ADR-identity-004-multi-face-target-selection.md
├── ADR-identity-005-enrollment-storage.md
├── ADR-identity-006-recognition-timeout.md
└── ADR-identity-007-privacy-nearby-people.md
```

---

# 29. Final Architecture Summary

```text
                LumiApplication
                      │
          IdentityRecognitionPort
                      ▲
                      │ implements
       VisionCoreMLIdentityAdapter
                      │
      ┌───────────────┼────────────────┐
      │               │                │
 AVFoundation       Vision          Core ML
 Camera Capture   Face Detection   Face Embedding
      │               │                │
      └───────────────┴────────┬───────┘
                               │
                         MemberMatcher
                               │
                  RecognitionConfidencePolicy
                         ┌─────┴─────┐
                         │           │
                    known(MemberID) unknown
```

Core rule:

> **Lumi may fail to recognize someone, but it must not confidently call the wrong person by name.**
