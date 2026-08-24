# Curves Lumi — Identity Recognition Specification

> File: `identity-recognition.md`
> Status: In implementation
> Last updated: 2026-08-23
> Scope: Milestone 3 — Member Identity Recognition
> Principles: Clean Architecture + TDD + Ask-if-Unclear
> Decisions: `docs/decisions/ADR-0004-face-match-confidence-policy.md`, `docs/decisions/ADR-0005-development-scope-and-boundaries.md`, `docs/decisions/ADR-0010-sface-embedding-model.md`

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

### Approved MVP Policy (34A)

```text
Exactly one detected face → select that face.
Zero detected faces → no active identity target.
Two or more detected faces → no active identity target.
```

The zero-face and multiple-face paths map outward to the existing public
`RecognitionResult.unknown`; the UI does not receive a low-level reason. The
MVP deliberately does not rank by face size, screen center, detector
confidence, prior recognition, or temporal continuity. This fail-closed rule
prevents Lumi from personalizing the wrong person when several people are in
view.

### Tests

- zero faces returns no target
- exactly one face preserves that face unchanged
- two or more faces return no target regardless of ordering, geometry, or
  confidence

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

For the SFace primary path, decision 35A selects the pinned OpenCV Zoo YuNet
2023mar model as an on-device five-landmark provider. Apple Vision remains the
frame-level face-rectangle detector; YuNet is added specifically to produce the
subject-relative right eye, left eye, nose tip, right mouth corner, and left
mouth corner required by the official SFace alignment order.

YuNet post-processing initially uses the explicitly approved 36B validation
defaults: score threshold `0.9`, NMS IoU threshold `0.3`, and pre-NMS top-K
`5000`. These are temporary OpenCV C++ demo values for getting the physical
iPad pipeline running; they are not validated production thresholds and must
remain injectable and replaceable.

If store testing shows missed faces, too many or overlapping detections, or
unexpected post-processing latency, these three defaults are an early
diagnostic suspect. In particular, missed faces may be caused by the strict
`0.9` score threshold rather than by SFace embedding quality. Do not tune these
values silently: record the observed symptom, fixture/device conditions, and
replacement values before changing them.

### YuNet graph and conversion verification (2026-08-14)

The pinned source graph has one Float32 BGR input named `input`, shape
`[1, 3, 640, 640]`, values `0...255` with no explicit normalization, and 12
Float32 raw outputs (`cls_*`, `obj_*`, `bbox_*`, and `kps_*` at strides 8, 16,
and 32). The source downloaded with `--download` into the ignored
`.build/yunet-conversion/` workspace was verified before loading: `232,589`
bytes and SHA-256
`8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`.

The isolated conversion runner used macOS `26.5.1` arm64, Xcode `26.2
(17C52)`, and Python `3.12.11` with exact build pins `coremltools 9.0`,
`numpy 2.5.2`, `onnx 1.18.0`, `onnx2torch 1.5.15`, `onnxruntime 1.22.1`,
`torch 2.7.0`, and `torchvision 0.22.0`. With deterministic input seed `42`,
ONNX Runtime and Core ML produced all 12 named raw outputs with contract
shapes and finite values. Every output passed the conversion gates (maximum
absolute error `≤1e-5`, mean absolute error `≤1e-6`, cosine similarity
`≥0.99999`):

| gate | output | observed |
| --- | --- | ---: |
| maximum absolute error | `kps_32` | `3.91155481338501e-06` |
| mean absolute error | `kps_32` | `7.537053897976875e-07` |
| minimum cosine similarity | `obj_16` | `0.9999999992994741` |

The source ONNX and the `.build/yunet-conversion/` conversion workspace remain
ignored. Decision 40A separately approves repository tracking of the unchanged
converted package under the App resources and records its provenance; this graph evidence still does
not claim a 15-column `FaceDetectorYN` result or runtime post-processing parity.
The 36B YuNet score/NMS/top-K validation defaults remain separate from later
SFace identity-matching thresholds, which still require representative store
data.

### YuNet letterbox geometry decision (37A, 2026-08-14)

The product owner approved a geometry-only boundary: each complete upright,
non-mirrored frame is aspect-fit and centered into the fixed 640×640 YuNet
canvas, preserving geometry. The scaled dimension uses explicit nearest-even
rounding. Raster placement floors the left and top padding; an odd remainder
goes to the right and bottom. YuNet's lower-left normalized point/rectangle
outputs are de-letterboxed to the original frame's lower-left normalized
coordinates, and any point or rectangle entering padding fails closed.

The new SDK-free `YuNetLetterboxTransform` and its 13 focused tests are
implementation evidence only. This geometry slice does not select a pixel
resampling algorithm (nearest, bilinear, vImage, or Core Image), and does not
authorize crop, stretch, native inference, recognition thresholds, or
physical-iPad validation. App model-resource distribution is recorded
separately by 40A.

### YuNet vImage preprocessing decision (38A-1, 2026-08-15)

The product owner approved 38A-1 on 2026-08-15. Each complete upright,
non-mirrored BGRA frame follows the 37A aspect-fit transform onto a fixed
640×640 canvas with black padding. Pixel scaling uses Apple's
[`vImageScale_ARGB8888`](https://developer.apple.com/documentation/accelerate/vimagescale_argb8888%28_%3A_%3A_%3A_%3A%29)
with the literal `vImage_Flags(kvImageNoFlags)`, which selects vImage's default
Lanczos-3 resampling. The implementation does not use
`kvImageHighQualityResampling` (Lanczos-5). The output is exact Float BGR
NCHW `[1, 3, 640, 640]`, with values `0...255`, no normalization, alpha
ignored, and the 37A transform attached.

This fixed resampling choice may affect small-face and boundary-detail results.
If field results are poor, treat 38A-1 resampling as a diagnostic variable,
separate from the 36B YuNet detector defaults and from SFace identity
thresholds. The product decision does not define Core ML runtime or inference
orchestration, camera sampling, crop, SFace thresholds, or physical-iPad
validation. It makes no claim about physical quality; 40A separately records
the approved App resource distribution. Apple's
[vImage resampling guidance](https://developer.apple.com/documentation/accelerate/resampling-in-vimage)
is the source for the resampling behavior.

Implementation evidence is limited to the new
`YuNetVImagePreprocessor.swift` and
`YuNetVImagePreprocessorTests.swift`: six focused tests pass. Root's
independent YuNet chain passed 29/29, and the unsigned Simulator build
succeeded. The full gate was attempted with no visible test failure, but the
existing `swift-test`/testing-helper lifecycle hang prevented clean completion;
no full-suite count or pass is claimed. These are engineering gates, not
physical quality evidence.

### YuNet Core ML raw inference adapter (38A-2, 2026-08-17)

The product owner approved the raw-inference adapter boundary on 2026-08-17.
The framework-free `Sendable` facade and driver protocol keep Core ML details
in Infrastructure. The concrete actor owns the `sending MLModel`, validates
model metadata once at construction, and validates every prediction's output
provider before returning raw tensors. It uses Apple's [`MLModel`](https://developer.apple.com/documentation/coreml/mlmodel)
async prediction API and [`MLMultiArray`](https://developer.apple.com/documentation/coreml/mlmultiarray)
buffer contract; Core ML objects do not cross the driver boundary.

The input contract is the exact Float32 BGR NCHW tensor `[1, 3, 640, 640]`,
with values in `0...255`. The adapter accepts exactly these 12 raw outputs in
the pinned canonical order: `cls_8`, `cls_16`, `cls_32`, `obj_8`, `obj_16`,
`obj_32`, `bbox_8`, `bbox_16`, `bbox_32`, `kps_8`, `kps_16`, `kps_32`. For each
stride `s`, `cls_s` and `obj_s` have shape `[1, (640/s)^2, 1]`, `bbox_s` has
`[1, (640/s)^2, 4]`, and `kps_s` has `[1, (640/s)^2, 10]`.
Core ML output arrays must be Float32, three-dimensional, and use positive
strides. The copier supports the positive padded strides emitted by the real
model (for example, `kps_8` has a physical channel stride of 16 while only 10
logical channel values are copied); padding values are never returned. Caller
cancellation is preserved, and all adapter failures use one payload-free
redacted error.

Implementation evidence is limited to the new
`YuNetCoreMLRawInference.swift` and
`YuNetCoreMLRawInferenceTests.swift`: the initial missing-symbol RED and a
separate padded-`kps` exact-stride RED were followed by 11/11 focused tests,
the independent YuNet chain passing 40/40, and a direct arm64 iOS 17 strict
typecheck. Root's ignored conversion copy `.build/yunet-conversion/YuNet.mlpackage`
runtime integration returned all 12 names, shapes, logical counts, and finite
values. The unsigned Simulator build succeeded. The full `swift test` gate was
attempted: XCTest snapshots showed 4/4 visible with no visible test failure,
but the existing `swift-test`/testing-helper lifecycle did not cleanly exit;
root terminated only its own PIDs, so no full-suite pass or count is claimed.
The scoped diff check was clean. The generated absent-before
`App/LumiApp.xcodeproj/project.xcworkspace` and root `/tmp` runtime harness
were cleaned. The source ONNX and `.build/yunet-conversion/` conversion
environment remain ignored; 40A approves repository tracking of the unchanged
package under App resources, and Xcode compiles it into the bundled `.mlmodelc`
resource.

This adapter slice does not choose or implement runtime model
discovery/loading or compute-unit policy; callers pass an already-loaded
`MLModel`. The 40A App resource slice records package membership and compiled
bundle outputs separately. It does not choose Vision↔YuNet candidate pairing.
The 38A-3 candidate pipeline composes this adapter with preprocessing,
postprocessing, and de-letterboxing. 39A defines the strict candidate pairer,
and subsequent Infrastructure slices implement SFace crop, embedding, and
storage; 40A/41A add bundled resources and lazy DEBUG calibration composition.
It makes no physical-iPad quality or performance claim and does not select
detector or identity thresholds. Keep the 36B YuNet detector defaults separate
from SFace identity thresholds.

### YuNet face-candidate pipeline (38A-3, 2026-08-17)

The product owner approved 38A-3 on 2026-08-17. The candidate pipeline composes
the fixed 38A-1 vImage preprocessor → existing Core ML raw inference → 36B
postprocessor → 37A de-letterbox transform. It returns ordered,
confidence-preserving `[DetectedFace]` YuNet candidates in original-frame
lower-left normalized coordinates, with the exact five SFace roles. Apple
Vision remains authoritative for frame-level rectangles: these candidates MUST
be paired with Vision observations in a later slice. The pipeline never selects
an identity or replaces Vision.

The contract is strict fail-closed. Any bbox or landmark overlapping letterbox
padding, malformed or missing geometry, or any stage error fails the whole
frame; it never drops, clamps, or returns a partial result. Failures use a
single payload-free redacted error, while `CancellationError` is preserved and
wins a generic failure race.

Implementation evidence is limited to the new
`YuNetFaceCandidatePipeline.swift` and
`YuNetFaceCandidatePipelineTests.swift`: tests-only missing-symbol RED followed
by 11/11 focused tests. Root's independent YuNet chain passed 51/51 across
five suites. Root's local ignored conversion copy `.build/yunet-conversion/YuNet.mlpackage`
and the production candidate pipeline, run on a black 640×640 BGRA frame,
returned zero candidates with clean completion; this is a connectivity smoke
check only, not accuracy or quality evidence. The unsigned Simulator
`BUILD SUCCEEDED` and the diff was clean. The generated absent-before
`App/LumiApp.xcodeproj/project.xcworkspace` and root `/tmp` runtime harness
were cleaned. The source ONNX and `.build/yunet-conversion/` conversion
environment remain ignored; 40A approves repository tracking of the unchanged
package under App resources, and Xcode compiles it into the bundled `.mlmodelc`
resource.

The full `swift test` gate was attempted: XCTest snapshots showed 4/4 visible,
and pipeline tests were visibly passing with no observed failure, but the
existing `swift-test`/testing-helper lifecycle did not cleanly exit; root
terminated only its exact own PIDs, so no full-suite pass or count is claimed.

At 38A-3, Vision↔YuNet candidate pairing policy (including IoU or other
pairing thresholds) and target selection were deferred. The subsequent 39A
pairer, SFace crop/alignment/embedding slices, embedding codec, typed SQLite
samples, and sample recorder now implement those internal pieces. 40A adds
the approved bundled model resources, and 41A adds lazy runtime loading and a
DEBUG calibration composition. The production `IdentityRecognitionPort`,
conversational/formal enrollment, and physical iPad accuracy/performance
validation remain deferred. Keep the 36B detector defaults separate from
identity thresholds.

### Vision/YuNet candidate pairing (39A/39A-1A, 2026-08-17)

The product owner approved 39A and 39A-1A on 2026-08-17. The pure pairer
accepts exactly one Vision face and exactly one YuNet candidate. It requires
strict mutual containment of the two bbox centers using `>` and `<`; boundary
centers are excluded, with no epsilon, IoU, ranking, or configurable threshold.
All other inputs fail closed with `nil`.

On success, the new `DetectedFace` value owns the authoritative Vision bbox and
confidence and YuNet's nonnil typed five-role SFace landmarks. Vision
landmarks are ignored; YuNet bbox and confidence are never returned. This
pairer performs no identity selection and uses no SDK.

Implementation evidence is limited to the new
`VisionYuNetCandidatePairer.swift` and
`VisionYuNetCandidatePairerTests.swift`: missing-symbol RED followed by 8/8
focused tests. Root's independent YuNet chain passed 74/74 across eight suites,
including `FaceTargetSelector`. The full `swift test` gate was attempted:
XCTest snapshots showed 4/4 and no visible test failure, but the known
`swift-test`/testing-helper lifecycle hang prevented clean completion; no
full-suite pass or count is claimed. Unsigned Simulator `xcodebuild`
`BUILD SUCCEEDED`. The generated absent-before
`App/LumiApp.xcodeproj/project.xcworkspace` was cleaned.

At 39A, SFace crop/alignment/embedding were deferred; subsequent internal
Infrastructure slices now implement SFace crop, Core ML embedding, the frame
pipeline, embedding codec, typed SQLite samples, and the sample recorder. 40A
adds the bundled model resources, and 41A now composes lazy runtime loading,
camera fresh-frame capture, and the DEBUG calibration tool. The production
`IdentityRecognitionPort`, conversational/formal enrollment, and
physical-device calibration remain deferred. Keep the 36B detector defaults
and 38A processing contracts separate from identity thresholds.

### App-bundled Core ML resources (40A, 2026-08-17)

The product owner approved 40A on 2026-08-17. The exact converted OpenCV Zoo
`SFace.mlpackage` (approximately 37 MB) and `YuNet.mlpackage` (approximately
300 KB) are present unchanged under `App/LumiApp/Resources/Models/` and
approved for repository tracking with narrow ignore exceptions. Xcode includes
both packages as Core ML compile inputs and emits the optimized
`SFace.mlmodelc` and `YuNet.mlmodelc` resources in the App bundle; runtime
model downloads are not used. This follows Apple's
[`Core ML app integration guidance`](https://developer.apple.com/documentation/coreml/integrating-a-core-ml-model-into-your-app)
and compiled-model loading contract
([`MLModel.load(contentsOf:configuration:)`](https://developer.apple.com/documentation/coreml/mlmodel/load%28contentsof%3Aconfiguration%3A%29)).

The App ships exact Apache-2.0 and MIT notices for SFace and YuNet
independently. `ModelProvenance.json` records the pinned source ONNX byte
counts/checksums and SHA-256 hashes for every copied package component. The
source ONNX files and conversion virtual environments remain ignored build
inputs; the App packages are the approved offline distribution artifacts.

Implementation evidence: tests first produced the expected missing-locator
symbol RED; the root focused hosted rerun passed 6/6 resource tests. The build
log emitted `CoreMLModelCompile` for both packages and the unsigned generic
Simulator build exited 0. The full `swift test` gate was attempted: all
visible tests/snapshots showed no failures, but the existing
`swift-test`/testing-helper lifecycle hung and required termination, so no
clean full-suite pass or count is claimed.

This resource slice did not itself implement runtime Core ML loading or live
`IdentityRecognitionPort` composition. 41A now performs lazy loading of the
bundled models for its DEBUG calibration graph and supplies the camera/UI
composition; the production port, formal enrollment, physical-device
quality/performance validation, and detector/identity thresholds remain
deferred.

### DEBUG physical calibration tool (41A, 2026-08-17)

The product owner approved 41A on 2026-08-17 as a DEBUG-only, manually gated
physical calibration tool. The Application boundary exposes only
`IdentityCalibrationPort` results/evidence: sample outcomes, selected-member
counts, and score-only candidates. Infrastructure owns the lazy bundled
`.mlmodelc` model graph, Vision → YuNet → SFace processing, camera fresh-frame
capture, and the SQLite full-gallery matcher. Presentation maps that boundary
to UI-owned strings, counts, raw top-1/top-2 cosine scores, and margin. App
composition retains one model per App root and loads the bundled
`SFace.mlmodelc`/`YuNet.mlmodelc` graph only on the first explicit Start; both
Mock Debug and Debug-Live use the same real camera/Core ML/SQLite calibration
graph. The database URL is exactly
`Library/Application Support/Lumi/IdentityCalibration.sqlite`; the loader
creates the `Lumi` parent after resolving bundle resources. No photographs are
saved.

The tool requires explicit Start/Stop. Every capture arms the camera for
exactly the next fresh frame; pre-arm buffered/stale frames are discarded.
The same camera cursor also publishes a bounded newest-one transient preview,
without changing the fresh-capture rule. There is no warmup, timeout, or image
persistence, and stop or cancellation is fail-closed. Samples for a temporary
member ID are deleted only through explicit reset confirmation. The suggested 3–5 enrollment
samples is soft guidance, not a cap or automatic completion. Return captures
rank the full temporary gallery and show raw top-1/top-2 IDs, cosine scores,
and margin only.

This tool does not set detector or identity thresholds, produce
`known`/`unknown`, implement the production `IdentityRecognitionPort`, conduct
conversational/formal enrollment, call OpenAI or CloudKit, download or compile
models at runtime, or claim physical-device quality. It is not a production
recognition route.

#### Physical iPad calibration runbook

1. Install a signed Debug `LumiApp` build on the iPad.
2. Open `DEBUG 身份校準`, enter temporary ID `person-a`, then tap
   `套用並開始相機`. The tool loads that ID's sample count before starting the
   camera; grant camera permission when requested.
3. First tap `拍攝回訪` before adding samples and record the score-only
   evidence (if any).
4. Capture 3–5 varied frontal/slight-angle samples with `非正式 enrollment`.
5. Tap `拍攝回訪`; record gallery count, top-1/top-2 temporary IDs, cosines,
   and margin.
6. Select `person-b`, load it, capture 3–5 samples, then make return captures
   for person A and then person B; compare candidate ordering evidence only.
7. Reset only the selected temporary ID between reruns after confirmation.

The DEBUG console now shows a display-only mirrored preview while recognition
continues to consume the original upright, non-mirrored frame. Keep the face
inside the static guide and remember that each shutter press consumes the next
fresh frame. Successful automation and simulator gates do not claim physical
accuracy, quality, or threshold validity.

Implementation/TDD evidence: tests-first App RED reported missing composition
and view symbols. A later lazy-start stop-race regression also went RED when a
suspended start completed after Stop without issuing the required post-start
stop; GREEN added that drain. Focused Presentation passed 15/15, Application
3/3, Infrastructure 15/15, and App composition 7/7 in both Debug and
Debug-Live. At this checkpoint Swift reported 545 tests across 47 suites plus
4 XCTest snapshots passing. Full App Debug and Debug-Live runs passed 51/51
each on the iPad Pro 11-inch M5 iOS 26.3.1 simulator. Generic Simulator
Debug, Release, Debug-Live, and Release-Live builds all exited 0; built Debug
and Debug-Live Info.plists contain the exact camera usage copy
`Lumi 需要使用相機，才能進行現場人臉校準與辨識測試。`.
Release and Release-Live binaries contain neither `DEBUG 身份校準` nor
`非正式 enrollment`. Diff/whitespace checks were clean and the generated
workspace was removed. These are simulator and automation gates only; no
physical iPad run is claimed.

### DEBUG photo-library import fallback (42A, 2026-08-17; Photos update 2026-08-21)

The product owner approved 42A on 2026-08-17 as a DEBUG-only fallback for
calibration before a physical iPad is available. On 2026-08-21 the picker was
changed from Files to SwiftUI
[`PhotosPicker`](https://developer.apple.com/documentation/photosui/photospicker)
so a tester can choose one image directly from Photos. The picker filters for
images and uses the current representation; Infrastructure still accepts only
JPEG, PNG, or HEIC after inspecting the actual source UTI. A selected
[`PhotosPickerItem`](https://developer.apple.com/documentation/photosui/photospickeritem)
is loaded once as transient `Data`. UI passes those bytes to Presentation;
Presentation wraps them in the Application photo value; Infrastructure opens
them with
[`CGImageSourceCreateWithData`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatewithdata%28_%3A_%3A%29).
The picker grants access only to the selected item and this route does not ask
for full-library photo authorization. The existing security-scoped URL decoder
remains as a compatibility seam, but the DEBUG UI no longer presents Files.
ImageIO validates the source UTI and exactly one image, applies the
EXIF orientation via
[`CGImagePropertyOrientation`](https://developer.apple.com/documentation/imageio/cgimagepropertyorientation),
and creates an owned upright, non-mirrored, top-left BGRA8 `CameraFrame` with a
64-byte padded row stride. The ImageIO thumbnail path uses
[`CGImageSourceCreateThumbnailFromImageAlways`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways)
and
[`CGImageSourceCreateThumbnailWithTransform`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform),
with a maximum edge of 2048. That limit is a DEBUG import memory bound only,
not a detector or identity threshold.

Photo enrollment and live-camera enrollment share the same one-operation gate
and the same Vision → YuNet → SFace → SQLite graph. Enrollment persists only
the embedding; return-photo import ranks the full temporary gallery and never
saves. The flow never requests camera permission or starts the camera, and it
does not persist or log a photo, picker item, encoded/decoded data, or preview. Picker
cancellation is a no-op; other failures are fixed/redacted and
`CancellationError` is preserved. The entire tool is excluded from Release
builds. It makes no physical-quality, `known`/`unknown`, threshold, or formal
enrollment claim.

#### Photo-library calibration runbook

1. Make the JPEG/PNG/HEIC test images available in the iPhone, iPad, or
   Simulator Photos library.
2. Open `DEBUG 身份校準`, enter and load a temporary member ID, then use
   `匯入 enrollment 照片` for 3–5 varied frontal/slight-angle photos.
3. Use `匯入回訪照片` with a separate photo and record gallery count, raw
   top-1/top-2 temporary IDs, cosine scores, and margin. Add another temporary
   ID only by explicitly selecting it; reset only the selected ID after
   confirmation.

The picker is the system Photos UI; cancelling it does nothing. It does not use
the Mac camera and does not claim iPad camera quality. The picker item and
encoded bytes remain transient, and the feature never stores a photo.

Implementation/TDD evidence was refreshed for the 2026-08-21 Photos update.
Tests-first RED failed on the absent in-memory photo contract; a later boundary
RED proved that UI still depended on the Application photo type before that
construction moved into Presentation. GREEN passed Application 4/4, decoder
11/11, Infrastructure service 23/23, Presentation 27/27, and App composition
14/14 in both Debug and Debug-Live. The exact full `swift test` gate completed
cleanly with 655 tests across 53 suites plus 4 XCTest snapshots. Full App Debug
passed 69/69. The first full Debug-Live run passed 68/69 with one unrelated
existing authorization-start timing failure; that exact test then passed and
the immediate full Debug-Live rerun passed 69/69. The required unsigned generic
Simulator build succeeded. A signed Debug build was installed and launched on
the connected iPhone 15 Plus `TonyLu`; this proves deployment/connectivity only,
not manual picker behavior or recognition quality. Scoped diff/whitespace
checks were clean. Release exclusion evidence from the original 42A checkpoint
remains applicable because all App picker code is inside the existing DEBUG
boundary.

### DEBUG live-preview field console (selected option A, 2026-08-21)

The product owner selected Google Stitch option A, “Lumi Field Identity
Console,” on 2026-08-21. The DEBUG calibration sheet is now camera-first: a
dark field-console surface gives the live preview visual priority, overlays a
static face-position guide and honest camera status, and keeps enrollment or
return mode, a manual shutter, and Photos import in a fixed bottom safe-area
deck. A compact temporary-ID/sample-count summary remains visible while aiming.
This dark console is a DEBUG calibration-tool decision only; it does not change
the production Lumi avatar or establish a product-wide dark theme.

The Application preview value contains only owned transient BGRA bytes and
width/height/row-stride metadata. Infrastructure preserves a single camera
stream iterator, publishes preview frames with `.bufferingNewest(1)`, and keeps
the capture gate independent so a shutter press still waits for the next frame
after it is armed. Presentation owns the preview value exposed to SwiftUI. App
renders it as a labeled `CGImage`, aspect-fills the preview, and mirrors only
the displayed image. The bytes sent through Vision → YuNet → SFace remain
upright and non-mirrored. Preview frames are not persisted, logged, encoded,
or passed to the identity domain.

The console remains fully manual. The static guide does not assert that a face
was detected or is ready; no auto-capture, recognition threshold,
`known`/`unknown` decision, or production enrollment behavior was introduced.
The first implementation placed the shutter below the initial viewport. Visual
comparison against the selected Stitch reference found that P1 issue; the
capture deck was moved to a fixed bottom safe-area inset so the shutter and
Photos action remain visible while positioning the face. The comparison and
decision record are in `design-qa.md`.

Tests-first RED covered the absent preview DTO/stream/model/renderer and App
proxy contracts. Focused GREEN passed Application 6/6, Infrastructure 30/30,
Presentation 32/32, and App 21/21 in both Debug and Debug-Live after the visual
correction. The exact full `swift test` gate passed 669 tests across 53 suites
plus 4 XCTest snapshots. Full App Debug and Debug-Live each passed 76/76 before
the layout-only safe-area correction; the changed App suite then passed 21/21
in each configuration. The required unsigned generic Simulator build
succeeded. Simulator visual QA used an iPhone 16 Plus portrait viewport and
found no remaining P0/P1 issue. These gates do not establish physical camera
preview quality. On 2026-08-22 a signed Debug build was installed and launched
successfully on the connected iPhone 15 Plus `TonyLu`; that proves deployment
and launch connectivity only. The operator must still observe the live preview
and capture flow on-device before any physical-camera conclusion is recorded.

The first physical-device report on 2026-08-22 found a blank preview and an ID
field that was not practically reachable. Tests-first regressions reproduced
both contracts: the renderer incorrectly treated the fourth BGRA byte as
premultiplied alpha, and the member editor lived only in scrolled content below
the camera. GREEN renders camera BGRA with the fourth byte skipped/opaque and
moves the ID editor plus Apply action into the fixed capture deck. Focused App
tests passed in Debug and Debug-Live, Simulator accessibility automation entered
and applied `tony2`, and a new signed build was installed and launched on
`TonyLu`. The operator still needs to confirm the corrected live image on the
physical device.

On 2026-08-22 the product owner selected Scheme A for the field-console entry:
identity context is confirmed before camera work begins. The initial stage asks
`這是誰？`, accepts one `會員 ID／暫時 ID`, loads that ID's existing sample
count, and starts the camera only after `套用並開始相機` succeeds. The capture
stage then shows the preview, mode, shutter, Photos, score evidence, and a
compact member/sample summary; it does not repeat the ID editor. `更換會員`
stops the camera and returns to the initial stage without deleting embeddings.
Deletion remains the distinct, confirmed `清除目前會員樣本` action. The
3–5-sample copy remains soft guidance and the UI no longer presents a capped
ratio such as `6/5`.

This is still a DEBUG calibration workflow. Entering a value does not create,
bind, rename, or delete a production member account. Visual QA compared the
old signed-device screenshot and the new same-size Simulator state; it found
and fixed one duplicate-title P1 before recording `final result: passed` in
`design-qa.md`. Tests-first evidence includes two Presentation regressions for
confirm/load/start ordering and invalid-ID gating plus an App regression for
the duplicate title. Focused GREEN passed Presentation 34/34 and App 24/24.

### DEBUG-Live known/unknown pilot (44B, 2026-08-22)

After a three-person physical-device calibration check produced clearly
separated top-1/top-2 evidence in the owner's test (for example, one captured
return visit showed top-1 `0.847634`, top-2 `0.298046`, margin `0.549588`), the
product owner approved 44B as a **temporary Debug/Debug-Live field pilot**. This
is not representative-store validation and does not approve a Release
threshold.

The pilot confidence policy is pure Domain code and fixes all four temporary
gates together:

- top-1 cosine similarity must be at least `0.70`;
- top-1 minus top-2 margin must be at least `0.20`;
- exactly three newly armed camera observations are measured;
- at least two accepted observations must name the same `MemberID`.

Boundary equality is accepted. Missing top-2 evidence fails the margin gate.
The known confidence is the lowest accepted top-1 score among the confirming
observations. Any low score, insufficient margin, missing face/candidate,
inconsistent identity, or malformed evidence fails safely to public `unknown`.
Stage failures use the existing generic error path, while `CancellationError`
is preserved even when it races a generic source failure. Internal
`UnknownReason` never crosses `IdentityRecognitionPort`.

Owner amendment (2026-08-24): for the Debug/Debug-Live 44B pilot, the
top-1/top-2 margin gate applies only when the second candidate belongs to a
different `MemberID`. A single candidate, or a second gallery sample carrying
the same `MemberID`, still must pass the unchanged `0.70` top-1 score gate,
exactly three observations, and at least two observations confirming the same
`MemberID`; its confidence remains the lowest confirming top-1 score. A
second candidate from a different `MemberID` retains the unchanged `0.20`
ambiguity margin. This amendment does not deduplicate or merge local profiles,
and it does not change any threshold or the fail-closed behavior for low score,
insufficient observations, or inconsistent identities.

In Debug-Live, the session Simulator now lazily loads the same bundled
SFace/YuNet graph and `Library/Application Support/Lumi/IdentityCalibration.sqlite`
gallery used by the calibration tool. The operator advances the existing
presence/rotation flow and presses `辨識目前訪客`; Mock Debug keeps its manual
known/unknown controls. A known result produces the generic returning-member
greeting and the existing privacy-safe `.returningMember` voice context when
voice is started. An unknown result uses the generic visitor path. Face frames,
embeddings, confidence scores, and raw member IDs are not sent through the
voice context.

#### Owner-approved temporary spoken address (Option A, 2026-08-22)

After physical testing confirmed that the 44B pilot could distinguish the
owner's three enrollment IDs, the owner approved a narrow **Debug-Live-only**
exception to the preceding anonymous voice rule. When 44B returns `known`, App
composition may convert that exact enrollment `MemberID` into
`VoiceMemberAddress` and send only its validated `spokenLabel` directly to the
Realtime session instructions. The accepted label is 1–32 Unicode letters or
numbers only; separators, spaces, punctuation, control text, and long/free-form
prompt content fail closed to an anonymous returning-member
greeting. Unknown visitors and unmapped members remain anonymous. Release
composition does not install this resolver.

The Debug-Live session UI uses that same resolver after a known decision and
shows `<spokenLabel>，歡迎回來～` before voice startup. This makes the local
identity result explicit without asking OpenAI to repeat it. If resolution is
unknown or the label fails validation, the UI never displays the enrollment
ID; Release remains anonymous.

This label is a temporary way to address the owner during the field pilot; it
is not a verified name or a member profile. It does not authorize visit,
exercise, or weekly-summary values. OpenAI may use it only with the returning
greeting and must not infer missing data. The broker request remains bodyless
and receives no member identity. A real Curves member-system binding will
replace the enrollment label with a system-provided preferred name later.

44B does not bind temporary IDs to a Curves member-management account and does
not provide a member name, visit history, exercise data, or real weekly
summary. The existing Debug fixture is not remapped to a recognized real ID;
real member context remains blocked on the separately designed CMS API and
identity-binding contract. At the 44B checkpoint, recognition timeout,
automatic continuous recognition, formal enrollment/consent, and production
thresholds were still unresolved; the later 2026-08-23 pilots below supersede
the first three items for Debug-Live only. Production thresholds remain
unresolved.

TDD evidence for the original slice: policy 12/12, pilot adapter 7/7, exact
known/unknown session-to-voice paths 2/2, Debug App composition 27/27, and
Debug-Live App composition/runtime 48/48. The Option A addition captured a
missing-contract RED before production code; focused GREEN passed coordinator
40/40, Realtime adapter 26/26, Mock voice 14/14, and App composition 28/28 in
both Debug and Debug-Live. Full hosted App gates passed 88/88 in both Debug and
Debug-Live after a tests-first fix for an existing early mock-arrival race.
These automated gates prove the contract and wiring, not field accuracy,
false-accept rate, or production readiness. The exact package-wide `swift test`
gate built successfully, passed its 4/4 XCTest snapshots, and showed no visible
Swift Testing failure after the race fixes, but the existing
`swiftpm-testing-helper` lifecycle hang required interruption (exit 130); no
clean package-wide pass or total count is claimed.

### Owner-approved conversational enrollment pilot (2026-08-23)

For a Debug-Live visitor whose recognition result is public `unknown`, Lumi may
say: `我好像還不認識你，可以跟你認識嗎？如果你願意，我會拍幾張照片，下次就記得你啦。`
Only a clear affirmative response authorizes the provider-neutral
`begin_visitor_enrollment` tool. The App then captures exactly three newly
armed, usable camera samples into memory; it does not persist a provisional
embedding or expose any frame, embedding, score, or raw identity to OpenAI.

After the three samples are ready, Lumi asks `我該怎麼稱呼您呢？`. A valid
short answer is normalized into the existing `VoiceMemberAddress` contract and
sent through `complete_visitor_enrollment`. The App creates a local UUID-backed
`MemberID` and atomically stores the local spoken label, consent timestamp, and
all three SFace embeddings. The label is not a primary key and duplicate labels
do not merge identities. Tool output confirms only capture/completion status
and the voluntarily provided spoken label; it never returns the generated ID.

Refusal performs no enrollment. Cancellation, visitor departure, session end,
capture failure, or failure to complete naming discards all in-memory samples.
The assistant may retry a failed capture only after explaining the failure; it
must never infer consent or invent a name. This pilot does not create or bind a
Curves CMS account, does not upload biometric data, and does not enable Release
enrollment. A future CMS binding must map the local UUID to a system member ID
without changing the user-visible name flow.

The Debug-Live implementation is now connected end to end: the Unknown voice
session alone receives the two enrollment tools; Application sequences and
cleans them up; the existing camera/Vision/YuNet/SFace service holds three
pending embeddings in memory; SQLite atomically writes the generated local
profile, consent time, and three samples; and later recognition resolves the
stored spoken label for both the on-device greeting and privacy-safe voice
context. Known sessions retain only the weekly-summary tool, and Release builds
receive neither enrollment tools nor the conversational enrollment port.

TDD evidence: visitor router `10/10`, visitor session runner `3/3`, Core ML plus
SQLite enrollment `13/13`, Realtime wire `14/14`, combined Realtime/router/
coordinator `121/121`, and full hosted Debug-Live App `92/92`. Generic unsigned
Simulator Debug, Mock Release, and Release-Live builds plus `swift build -c
release` succeeded. The exact package `swift test` run passed `4/4` XCTest
snapshots and showed no visible Swift Testing failure, including every new
enrollment test, but the known `swiftpm-testing-helper` lifecycle hang required
interruption and prevented a clean aggregate pass/count claim. No physical
camera or natural voice enrollment claim is made by these automated gates.

### Owner-approved continuous welcome pilot (2026-08-23)

The product owner approved replacing the visible Debug-Live session controls
with an automatic visitor loop. Once an authorized App reaches the Avatar,
Debug-Live automatically waits for one usable face, runs the existing
three-observation 44B recognition policy, and starts the appropriate Realtime
voice session without an operator button. The Avatar shows its recognizing
state while waiting. The manual simulator panel and calibration entry are not
part of this visitor surface; device reset remains a compact administrative
gear action.

One arrival may produce only one greeting. Lumi rearms only after the presence
monitor observes ten continuous seconds with no usable face; any usable face
inside that interval resets the absence timer. After departure, Application
ends the session through the existing `visitorLeft` path, returns the Avatar to
idle, and begins waiting again. Cancellation stops the camera and preserves
`CancellationError`; stage errors use one redacted failure. This is a
Debug-Live field workflow, not a Release threshold or representative-store
accuracy claim.

Presence observation runs the camera-to-embedding face gate only. It does not
load SQLite enrollment samples or rank the 800-member gallery on every waiting
frame; the gallery is queried only by the existing three-observation identity
decision after an arrival.

For a known member with a validated spoken label, the local UI still exposes
`<名稱>，歡迎回來～`, while Realtime instructions require the first spoken
sentence to start with `<名稱>，歡迎回來`. Lumi may then choose exactly one of
`漂亮姊姊`, `寶貝`, or `公主殿下` and add one short positive sentence. It must
not stack the nicknames or use them to infer age or private data. An unknown
visitor begins with `漂亮姊姊，我好像還不認識妳` before the existing disclosure,
spoken consent, three-sample enrollment, and naming flow.

The ready Avatar also embeds Apple's native
[`MPVolumeView`](https://developer.apple.com/documentation/mediaplayer/mpvolumeview)
volume slider. This changes the user's system output volume; Lumi does not
attempt to write
[`AVAudioSession.outputVolume`](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume),
which is read-only. Existing Live audio routing continues to prefer the speaker
through
[`.defaultToSpeaker`](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/defaulttospeaker).
The slider changes volume only—it does not alter recognition confidence,
microphone gain, the OpenAI voice, or audio-session routing policy.

TDD and integration evidence for this amendment: the focused presence,
identity-service, Realtime, and deterministic-hardware suites passed `80/80`;
the continuous App flow passed `21/21`; and the complete hosted App target
passed `99/99` in both Mock Debug and Debug-Live. Swift Release plus unsigned
Mock Debug, Debug-Live, and Release-Live Simulator builds succeeded. The exact
package `swift test` run passed `4/4` XCTest snapshots and showed no visible
Swift Testing failure, but the known `swiftpm-testing-helper` lifecycle hang
again required interruption, so no clean full-package aggregate exit or count
is claimed. These automated gates do not replace physical-device voice-volume,
camera-presence, or natural-conversation validation.

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

ADR-0010 selects OpenCV Zoo SFace as the primary embedding model and Intel
`face-reidentification-retail-0095` as the challenger. Both have Apache 2.0
source terms. SFace uses a pinned 112×112 RGB FP32 input and produces a
128-component embedding; cosine matching follows L2 normalization.

The product owner corrected the SFace channel contract on 2026-08-17. The
official [OpenCV 4.10.0 `FaceRecognizerSF` source](https://raw.githubusercontent.com/opencv/opencv/4.10.0/modules/objdetect/src/face_recognize.cpp)
passes the conventional-BGR aligned image to
[`blobFromImage`](https://docs.opencv.org/4.10.0/d6/d0f/group__dnn.html) with
`swapRB=true`, so the graph input is RGB; the pinned
[Zoo demo](https://raw.githubusercontent.com/opencv/opencv_zoo/4.10.0/models/face_recognition_sface/demo.py)
starts from `cv.imread` without another channel swap. This corrects only the
converter metadata and documented graph contract; conversion/parity values,
the model hash, and physical quality or threshold decisions are unchanged.

The model artifact, conversion toolchain, and numerical parity gate are fixed
by ADR-0010. Physical-iPad performance and production confidence thresholds
remain blocking validation work.

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
