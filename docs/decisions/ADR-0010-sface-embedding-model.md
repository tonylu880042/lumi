# ADR-0010 — SFace Primary Embedding Model and Intel Challenger

> Status: Accepted for implementation; production thresholds pending store validation
> Date: 2026-08-14
> Decision owner: Curves Lumi Product Owner
> Scope: Milestone 3 face embedding and local member matching
> Related: `docs/identity-recognition.md`, ADR-0004, and ADR-0005

## Context

Lumi needs to recognize a local gallery of at most about 800 members, normally
fewer than 500. Recognition is personalization, not authentication. Raw face
images and embeddings must remain on the iPad/its approved backup path and must
never be sent to OpenAI. The previously considered ArcFace commercial offering
was too expensive for the pilot.

The embedding model must therefore have a redistributable license, a practical
Core ML conversion path, sufficient performance for an iPad gallery, and a
versioned replacement path. Choosing a model does not authorize a production
similarity threshold: ADR-0004 still requires representative store validation.

## Decision

### 1. Use OpenCV Zoo SFace as the primary model

Pin the FP32 SFace artifact to:

- repository/tag: `opencv/opencv_zoo` `4.10.0`
- tag revision: `f88e9b2bafd21f1cad242fb5af6d78f2bcba16a3`
- file: `face_recognition_sface_2021dec.onnx`
- byte count: `38,696,353`
- SHA-256: `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`
- license: Apache License 2.0; the model directory explicitly applies it to all files

The pinned graph contract, inspected from the artifact, is:

- input: Float32 tensor `data`, shape `[1, 3, 112, 112]`
- channel order: RGB, following the official OpenCV `FaceRecognizerSF` path
- value range at the graph boundary: `0...255`
- graph preprocessing: subtract `127.5`, then multiply by `1/128`
- output: Float32 tensor `fc1`, shape `[1, 128]`
- matching metric: cosine similarity after L2 normalization
- alignment: the official SFace integration uses five facial landmarks

The product owner corrected this channel contract on 2026-08-17. OpenCV
4.10.0's [`FaceRecognizerSF` implementation](https://raw.githubusercontent.com/opencv/opencv/4.10.0/modules/objdetect/src/face_recognize.cpp)
passes the aligned conventional-BGR image to
[`blobFromImage`](https://docs.opencv.org/4.10.0/d6/d0f/group__dnn.html) with
`swapRB=true`, so the graph receives RGB ordering; the pinned
[Zoo demo](https://raw.githubusercontent.com/opencv/opencv_zoo/4.10.0/models/face_recognition_sface/demo.py)
starts from `cv.imread` without an additional channel swap. This is a
contract/metadata and documentation correction only: it does not alter the
ONNX/Core ML graph conversion, random parity inputs or metrics, model hash, or
physical quality and threshold decisions.

### 1.1 Use YuNet 2023mar for the five alignment landmarks

The product owner approved decision 35A on 2026-08-14: use the OpenCV Zoo
YuNet 2023mar model, converted to Core ML, as the on-device provider of the five
facial landmarks required by SFace alignment. Apple Vision remains responsible
for frame-level face rectangle detection; YuNet is not authorization to replace
that boundary.

Pin the FP32 YuNet artifact to:

- repository/tag: `opencv/opencv_zoo` `4.10.0`
- tag revision: `f88e9b2bafd21f1cad242fb5af6d78f2bcba16a3`
- file: `face_detection_yunet_2023mar.onnx`
- byte count: `232,589`
- SHA-256: `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`
- directory license: MIT

The pinned raw graph contract is one Float32 BGR input named `input`, shape
`[1, 3, 640, 640]`, values `0...255` with no explicit normalization, and 12
Float32 raw outputs: `cls_*`, `obj_*`, `bbox_*`, and `kps_*` at strides 8, 16,
and 32. The SDK-free raw-output postprocessor now implements the official
decode, score filtering, and NMS behavior with injectable 36B validation
defaults. Production threshold selection, Vision-to-YuNet pairing and
inference adapter wiring, and physical-iPad validation remain separate work.

### 1.2 Start physical validation with the OpenCV C++ demo defaults (36B)

The product owner approved 36B on 2026-08-14. YuNet post-processing initially
uses score threshold `0.9`, NMS IoU threshold `0.3`, and pre-NMS top-K `5000`.
These values must be explicit, injectable configuration even when supplied by
a convenience validation default.

This is a temporary pilot assumption, not evidence that the values fit Lumi's
camera distance, lighting, member demographics, or iPad performance. When the
pipeline appears ineffective, investigate this decision before blaming SFace:

- missed or intermittent faces may indicate that `0.9` is too strict;
- excess or overlapping faces may indicate an unsuitable score or NMS value;
- post-processing latency or memory pressure may indicate that `5000` is too
  large for the observed scene and device.

Any replacement requires recorded physical-device evidence. These detector
post-processing values are distinct from the later top-1 cosine and ambiguity
thresholds used to decide member identity; 36B does not authorize those
identity thresholds.

YuNet output must map explicitly, in the official OpenCV order, to subject
right eye, subject left eye, nose tip, subject right mouth corner, and subject
left mouth corner. No Apple Vision landmark-region averaging or inferred point
substitution is allowed. The artifact revision, byte count, checksum, graph
contract, conversion parity gate, and directory license must be verified and
recorded. Decision 40A now records the unchanged converted package as an
approved App resource for offline distribution.

The pinned YuNet directory applies the MIT License, which differs from the
Apache License 2.0 used by the selected SFace directory. Both notices must be
retained independently in the App resources by decision 40A.

`Tools/ModelConversion/build_yunet_coreml.py` provides the pinned manifest,
raw-graph validation, conversion path, and per-output parity gates. The
conversion was executed on 2026-08-14 in an isolated `.build/yunet-conversion/`
environment using macOS `26.5.1` arm64, Xcode `26.2 (17C52)`, and Python
`3.12.11` with the exact build pins `coremltools 9.0`, `numpy 2.5.2`, `onnx
1.18.0`, `onnx2torch 1.5.15`, `onnxruntime 1.22.1`, `torch 2.7.0`, and
`torchvision 0.22.0`.

The `--download` run verified the source before loading it: `232,589` bytes
and SHA-256
`8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`. With
the deterministic input generated from seed `42`, ONNX Runtime and Core ML
returned all 12 named raw outputs, each with its exact contract shape and only
finite values. All 12/12 outputs passed the conversion gates:

| gate | output | observed |
| --- | --- | ---: |
| maximum absolute error | `kps_32` | `3.91155481338501e-06` |
| mean absolute error | `kps_32` | `7.537053897976875e-07` |
| minimum cosine similarity | `obj_16` | `0.9999999992994741` |

The source ONNX and conversion workspace remain ignored. Decision 40A approves
repository tracking of the unchanged `YuNet.mlpackage` under App resources and
records its provenance.
This evidence covers raw graph conversion; it does not claim a 15-column
`FaceDetectorYN` result or runtime post-processing parity. The 36B detector
defaults remain separate from the later SFace identity-matching thresholds.

### 1.3 YuNet letterbox geometry (37A)

The product owner approved decision 37A on 2026-08-14. A complete upright,
non-mirrored frame is aspect-fit and centered into the fixed 640×640 canvas,
preserving geometry. The scaled dimension uses explicit nearest-even rounding;
raster left/top padding is floored, with any odd remainder assigned to
right/bottom. YuNet's lower-left normalized detections are de-letterboxed to
the original-frame lower-left normalized coordinates. A point or rectangle that
enters padding fails closed.

The pure SDK-free transform and its 13 focused tests are implementation
evidence only. This geometry decision does not choose a pixel resampling
algorithm (nearest, bilinear, vImage, or Core Image), and does not authorize
crop/stretch, native inference, recognition thresholds, or physical-iPad
validation. App model-resource distribution is recorded separately by 40A.

### 1.4 Use vImage's default Lanczos-3 resampling (38A-1)

The product owner approved decision 38A-1 on 2026-08-15. Every complete
upright, non-mirrored BGRA frame follows the 37A aspect-fit transform onto a
fixed 640×640 canvas with black padding. Pixel scaling uses Apple's
[`vImageScale_ARGB8888`](https://developer.apple.com/documentation/accelerate/vimagescale_argb8888%28_%3A_%3A_%3A_%3A%29)
with the literal `vImage_Flags(kvImageNoFlags)`, selecting vImage's default
Lanczos-3 resampling. `kvImageHighQualityResampling` (Lanczos-5) is explicitly
not used. The output contract is exact Float BGR NCHW `[1, 3, 640, 640]`,
values `0...255`, no normalization, alpha ignored, and the 37A transform
attached.

This resampling choice can affect small-face and boundary-detail results. If
field results are poor, 38A-1 resampling is a diagnostic variable; it must be
considered separately from 36B detector defaults and SFace identity
thresholds. This decision does not define Core ML runtime or inference
orchestration, camera sampling, crop, SFace thresholds, or physical-iPad
validation, and it makes no physical-quality claim. 40A separately records
the approved App resource distribution.

Implementation evidence is limited to the new
`YuNetVImagePreprocessor.swift` and
`YuNetVImagePreprocessorTests.swift`: six focused tests pass. Root's
independent YuNet chain passed 29/29, and the unsigned Simulator build
succeeded. The full gate was attempted with no visible test failure, but the
existing `swift-test`/testing-helper lifecycle hang prevented clean completion;
no full-suite count or pass is claimed. These are engineering gates, not
physical quality evidence.

### 1.5 Core ML raw inference adapter (38A-2)

The product owner approved this adapter boundary on 2026-08-17. A
framework-free `Sendable` facade and driver protocol isolate Core ML in
Infrastructure. A concrete actor owns the `sending MLModel`, validates model
metadata once at construction, and validates every prediction output before
returning `YuNetRawTensor` values. It uses Apple's [`MLModel`](https://developer.apple.com/documentation/coreml/mlmodel)
async prediction API and [`MLMultiArray`](https://developer.apple.com/documentation/coreml/mlmultiarray)
buffer contract; no Core ML object crosses the driver seam.

The exact input is Float32 BGR NCHW `[1, 3, 640, 640]` with values `0...255`.
The adapter requires these 12 names in canonical order: `cls_8`, `cls_16`,
`cls_32`, `obj_8`, `obj_16`, `obj_32`, `bbox_8`, `bbox_16`, `bbox_32`, `kps_8`,
`kps_16`, `kps_32`. For each stride `s`, `cls_s` and `obj_s` have shape
`[1, (640/s)^2, 1]`, `bbox_s` has `[1, (640/s)^2, 4]`, and `kps_s` has
`[1, (640/s)^2, 10]`. Output arrays must be Float32, rank three, and use
positive strides. The logical copier handles the positive padded strides
emitted by the real model (the `kps` channel stride is 16 for 10 logical
channels), excludes physical padding values, and preserves caller
cancellation. Failures are represented by one payload-free redacted error.

Evidence for this boundary is implementation-only: initial missing-symbol RED,
a separate padded-`kps` exact-stride RED, focused 11/11, YuNet chain 40/40,
direct arm64 iOS 17 strict typecheck, and root's ignored conversion copy
`.build/yunet-conversion/YuNet.mlpackage` runtime integration returning all 12
names, shapes, logical counts, and finite values. The unsigned Simulator build
succeeded. The full `swift test` gate was attempted with XCTest snapshots 4/4
visible and no visible test failure, but the existing `swift-test`/testing-helper
lifecycle did not cleanly exit; root terminated only its own PIDs, so no
full-suite pass or count is claimed. The scoped diff check was clean. The
generated absent-before `App/LumiApp.xcodeproj/project.xcworkspace` and root
`/tmp` runtime harness were cleaned. The source ONNX and conversion workspace
remain ignored; 40A approves repository tracking of the unchanged package under
App resources, and Xcode compiles it into the bundled `.mlmodelc` resource.

This adapter decision does not choose or implement runtime model
discovery/loading or compute-unit policy; callers pass an already-loaded
`MLModel`. 40A separately records App/PBX package membership and compiled
bundle outputs. This decision does not choose Vision↔YuNet candidate pairing.
The 38A-3 candidate pipeline composes this adapter with preprocessing,
postprocessing, and de-letterboxing. 39A defines the strict candidate pairer,
and subsequent Infrastructure slices implement SFace crop, embedding, and
storage; 40A/41A add bundled resources and lazy DEBUG calibration composition.
It does not claim physical-iPad quality or performance and does not select
thresholds. Keep the 36B detector defaults separate from SFace identity
thresholds.

### 1.6 YuNet face-candidate pipeline (38A-3, 2026-08-17)

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
were cleaned. The source ONNX and conversion workspace remain ignored; 40A
approves repository tracking of the unchanged package under App resources, and
Xcode compiles it into the bundled `.mlmodelc` resource.

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

### 1.7 Vision/YuNet candidate pairing (39A/39A-1A, 2026-08-17)

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

### 1.8 App-bundled Core ML resources (40A, 2026-08-17)

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

This resource decision did not itself implement runtime Core ML loading or live
`IdentityRecognitionPort` composition. 41A now performs lazy loading of the
bundled models for its DEBUG calibration graph and supplies the camera/UI
composition; the production port, formal enrollment, physical-device
quality/performance validation, and detector/identity thresholds remain
deferred.

### 1.9 DEBUG physical calibration tool (41A, 2026-08-17)

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

### 1.10 DEBUG photo-library import fallback (42A, 2026-08-17; Photos update 2026-08-21)

The product owner approved 42A on 2026-08-17 as a DEBUG-only fallback for
calibration before a physical iPad is available. On 2026-08-21 the App entry
point changed from Files to SwiftUI
[`PhotosPicker`](https://developer.apple.com/documentation/photosui/photospicker).
It selects one image with the current representation and exposes access only
to that selected item, without a full-library authorization request. The item
is loaded once as transient `Data`; UI passes the bytes to Presentation,
Presentation creates the Application photo value, and Infrastructure opens it
with
[`CGImageSourceCreateWithData`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatewithdata%28_%3A_%3A%29).
The decoder accepts only an actual JPEG, PNG, or HEIC source UTI and exactly one
image. The security-scoped URL decoder remains a compatibility seam, but the
DEBUG UI no longer presents Files. ImageIO applies
[`CGImagePropertyOrientation`](https://developer.apple.com/documentation/imageio/cgimagepropertyorientation),
and emits an owned upright, non-mirrored, top-left BGRA8 `CameraFrame` with a
64-byte padded row stride. The implementation uses
[`CGImageSourceCreateThumbnailFromImageAlways`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways)
and
[`CGImageSourceCreateThumbnailWithTransform`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)
with a maximum edge of 2048. This is a DEBUG memory bound, not a recognition
threshold.

Photo enrollment and return import reuse the existing Vision → YuNet → SFace
→ SQLite graph and one-operation gate. Enrollment stores only the embedding;
return ranks the full temporary gallery and never saves. The import path does
not request camera or full-library photo permission, does not start the camera,
and never stores or logs photos, picker items, encoded/decoded data, or
previews. Picker cancellation is a no-op, other errors
are fixed/redacted, and `CancellationError` is preserved. Release builds omit
the tool. This fallback does not establish physical quality, known/unknown
behavior, thresholds, or formal enrollment.

The runbook now places test images in the iPhone, iPad, or Simulator Photos
library, selects them with `匯入 enrollment 照片`, and uses a separate item with
`匯入回訪照片`. The feature does not use the Mac camera and does not claim iPad
camera quality.

The 2026-08-21 Photos update has implementation/connectivity evidence only:
tests-first RED covered the absent in-memory photo contract and the corrected
UI → Presentation boundary. GREEN passed decoder 11/11, Application port 4/4,
Infrastructure service 23/23, Presentation 27/27, and App focused 14/14 in
both Debug and Debug-Live. The exact full `swift test` gate completed with 655
tests across 53 suites plus 4 XCTest snapshots. Full App Debug passed 69/69.
The first Debug-Live full run had one unrelated existing authorization-start
timing failure at 68/69; its exact rerun passed and the immediate full rerun
passed 69/69. The unsigned generic Simulator build succeeded. A signed Debug
build was installed and launched on the connected iPhone 15 Plus `TonyLu`.
That is deployment/connectivity evidence, not manual picker or recognition
quality evidence. Scoped checks were clean. Existing Release-exclusion
evidence remains applicable because the picker remains inside the DEBUG-only
tool.

### 1.11 DEBUG live-preview field console (selected option A, 2026-08-21)

The product owner selected the Google Stitch “Lumi Field Identity Console”
option A. The DEBUG calibration route now uses a camera-first dark console with
a dominant live preview, static face guide, honest camera state, compact
temporary-member/sample context, and a fixed bottom safe-area capture deck for
enrollment/return mode, the manual shutter, and Photos import. The visual
language is scoped to this DEBUG field tool and does not change the production
avatar or establish a global dark-theme decision.

The Application boundary carries an owned, transient BGRA preview value with
dimensions and row stride only. Infrastructure keeps one camera iterator and a
bounded newest-one preview buffer while retaining the independent next-frame
capture gate. Presentation maps the preview for UI consumption. SwiftUI creates
a labeled `CGImage`, aspect-fills it, and mirrors only the display; Vision,
YuNet, and SFace still receive the original upright, non-mirrored frame.
Preview data is never persisted, logged, encoded, or exposed to Domain.

The guide is intentionally static and makes no face-detected/readiness claim.
No auto-capture, detector or identity threshold, `known`/`unknown` decision, or
production enrollment route is authorized. Visual QA found and fixed one P1:
the first shutter location was below the initial viewport, so the capture deck
was moved to a bottom safe-area inset. The signed-device step may verify camera
preview operation, but does not by itself validate recognition quality.

TDD evidence: focused GREEN passed Application 6/6, Infrastructure 30/30,
Presentation 32/32, and App 21/21 in both Debug configurations after the visual
fix. The full Swift gate passed 669 tests across 53 suites plus 4 XCTest
snapshots. Full App Debug and Debug-Live passed 76/76 before the layout-only
safe-area fix, and the changed App suite then passed 21/21 in both
configurations. The required unsigned generic Simulator build succeeded, and
same-viewport visual comparison against the selected Stitch reference found no
remaining P0/P1 issue. On 2026-08-22 the signed Debug build was installed and
launched on the connected iPhone 15 Plus `TonyLu`; this is deployment and launch
connectivity evidence only, not physical preview or recognition-quality proof.

A 2026-08-22 physical-device regression report found a blank preview and an ID
editor that was not practically reachable. RED tests pinned both causes. The
App renderer now treats the fourth BGRA byte as skipped/opaque instead of
premultiplied alpha, and the editable temporary-ID controls now live in the
fixed capture deck. Debug and Debug-Live focused suites passed; Simulator
automation entered/applied `tony2`, and the corrected signed build was installed
and launched on `TonyLu`. Direct operator confirmation of the physical preview
remains required.

On 2026-08-22 the product owner selected Scheme A as an identity-first
replacement for the original camera-first entry. The DEBUG tool now confirms
one `會員 ID／暫時 ID`, loads its existing sample count, and starts the camera
only after the combined `套用並開始相機` action succeeds. Camera preview and
capture controls exist only in the subsequent capture stage, and that stage
does not repeat the ID editor. `更換會員` stops the camera and returns to ID
selection without deleting stored embeddings; sample deletion stays behind the
separate confirmed `清除目前會員樣本` action. The 3–5 count remains guidance,
not a cap or progress denominator.

This decision does not give the temporary ID production-member semantics and
does not create, bind, rename, or delete a member-management account. Same-size
visual comparison found and fixed one duplicate-title P1, then recorded a
passing result in `design-qa.md`. Focused TDD evidence passed Presentation
34/34 and App 24/24 after the new ordering, validation, and title regressions.

### 1.12 DEBUG-Live confidence pilot and voice routing (44B, 2026-08-22)

The product owner approved a bounded Debug/Debug-Live field pilot after manually
checking three temporary identities on the connected device. This observation
is enough to authorize a diagnostic pilot, but it is not the representative
store dataset required by ADR-0004 and therefore does not change this ADR's
production-threshold status.

The pilot pins top-1 cosine `>= 0.70`, top-1/top-2 margin `>= 0.20`, exactly
three fresh observations, and at least two accepted observations for the same
member. Equality passes; missing top-2 fails closed. A known result reports the
minimum accepted confirming score. The policy lives in Domain, while the
DEBUG-only Infrastructure adapter owns the camera/Core ML/SQLite evidence and
maps internal reasons to the existing public known/unknown port contract.

Debug-Live App composition lazily builds the bundled SFace/YuNet graph and the
same dedicated calibration SQLite path when the operator first requests
recognition. Mock Debug keeps deterministic manual identity controls. Release
composition does not enable this pilot policy. The existing coordinator maps a
known result to the provider-neutral `.returningMember` voice context and an
unknown result to `.visitor`; it does not send face data, embeddings, raw
scores, or a member ID through that voice context.

The temporary calibration ID is not a production CMS identity. No recognized
ID is mapped to `DebugMemberFixture`, so 44B does not fabricate member profile
or exercise data. CMS lookup, account binding, formal enrollment/consent,
recognition timeout, and representative threshold validation remain separate
blocking work.

RED-to-GREEN evidence: confidence policy 12/12, pilot adapter 7/7, focused
known/unknown session-to-voice routing 2/2, Debug App composition 27/27, and
Debug-Live App composition/runtime 48/48. Full hosted App gates passed 88/88 in
both Debug and Debug-Live after a tests-first fix for the early mock-arrival
race. These results prove deterministic wiring only, not
false-accept/false-reject performance. The exact package-wide `swift test`
gate built, passed 4/4 XCTest snapshots, and showed no visible Swift Testing
failure after the race fixes, but the existing testing-helper lifecycle hang
required interruption (exit 130); it is not recorded as a clean package-wide
pass.

### 1.13 Continuous recognition and proactive welcome pilot (2026-08-23)

The product owner approved a Debug-Live kiosk loop using the existing 44B
policy rather than a separate recognition threshold. App automatically waits
for one usable face, performs the three-observation identity decision, starts
the matching returning-member or visitor voice context, and accepts no second
arrival until ten continuous seconds without a usable face have elapsed. A
usable face resets that absence interval. The existing coordinator owns
session transitions; the new presence port observes only arrival/departure and
does not expose frames, embeddings, scores, or identity.

This loop does not change SFace, YuNet, the SQLite gallery, the 0.70/0.20 pilot
gates, or the unknown-over-guessing rule. It removes the visible manual pilot
panel from the visitor surface and keeps reset/calibration as administrative
controls. Realtime may preserve a validated known label and add exactly one
approved playful nickname; unknown visitors retain the explicit consented
enrollment gate. User volume adjustment is delegated to Apple's native
`MPVolumeView`; it is not an embedding or recognition responsibility.

### 2. Convert reproducibly to Core ML

`Tools/ModelConversion/build_sface_coreml.py` downloads only when explicitly
requested, verifies the pinned byte count/checksum, converts ONNX through a
traced PyTorch model into an iOS 17 ML Program, and numerically compares the
Core ML output with ONNX Runtime using a deterministic input.

The build-time toolchain is pinned in
`Tools/ModelConversion/requirements-sface.txt`. It is not an App runtime
dependency. Decision 40A approves the unchanged converted packages for
repository tracking and App distribution; future artifact updates still require
a separate release and provenance decision.

The conversion gate requires:

- exactly 128 output components
- maximum absolute error no greater than `1e-5`
- mean absolute error no greater than `1e-6`
- ONNX/Core ML output cosine similarity at least `0.99999`

The 2026-08-13 PoC passed with maximum error `1.5944242477416992e-6`,
mean error `5.584515747614205e-7`, and cosine similarity
`0.9999999999985524`.

### 3. Keep Intel `face-reidentification-retail-0095` as challenger

The Intel Open Model Zoo model is not shipped in the first SFace build. It is
the preselected challenger if SFace misses latency, thermal, false-accept, or
false-reject requirements on actual store data.

Its documented contract is:

- Apache License 2.0 Open Model Zoo source
- aligned BGR face input, `128 × 128`
- 256-component embedding
- cosine-based comparison
- 1.107 million parameters and 0.588 GFLOPs

Challenger embeddings use a different `modelVersion` and must never be compared
with SFace embeddings. Switching models requires re-embedding enrollment
fixtures or an explicit migration/re-enrollment flow.

### 4. Use an exact local matcher at pilot scale

For at most 800 members with 3–5 enrollment samples, use an exact linear cosine
scan and take the best sample per member before ranking distinct members. Do not
introduce a vector database or approximate-nearest-neighbor service unless
physical-iPad measurements prove it necessary.

The current Mac test ranks 4,000 normalized 128-dimensional samples, but this is
only an algorithmic scale check. iPad latency, memory, and thermal behavior must
be measured separately.

### 5. Do not adopt published example thresholds

OpenCV/Intel demo thresholds and public benchmark accuracy are reference data,
not Lumi production acceptance criteria. Known identity remains unavailable
until store validation selects all of:

- minimum face-quality gates
- top-1 cosine threshold
- top-1/top-2 margin
- required temporal confirmations
- timeout/fallback behavior

Until then, fixtures may exercise ranking but the App must not claim that the
production confidence policy is validated.

### 6. Use closed, payload-free local diagnostics

Debug-Live records fixed OSLog categories at the model factory, camera,
presence monitor, and frame-pipeline boundaries. Camera events distinguish
configuration failures, interruption reasons, media-services reset, and
unsupported runtime rotation. Frame events distinguish Vision, YuNet,
alignment crop, and SFace inference failures.

These events carry no associated runtime values. They must not contain an
image, embedding, member name or ID, spoken label, similarity score, framework
error description, or model input. Application and UI error contracts remain
payload-free and unchanged; detailed framework diagnosis stays in
Infrastructure.

For the owner-approved Debug-Live presence loop, one frame-pipeline failure is
treated as a temporarily unusable presence frame and the next fresh frame is
requested on the same camera lease. The diagnostic stage remains visible, but
the presence operation does not fail solely because that frame was unusable.
Camera start/stream failures and every calibration, enrollment, or identity
pipeline failure keep their existing fail-closed behavior.

## Consequences

- SFace avoids the ArcFace commercial license cost for the pilot.
- YuNet supplies the exact landmark semantics expected by the official SFace
  alignment flow without sending face data off-device.
- Model inference and matching can remain entirely on-device and offline.
- Domain/Application remain independent of Core ML and vector dimensions.
- SQLite records retain `modelVersion`, multiple samples per member, and exact
  deletion by `MemberID`.
- A future Intel comparison does not require changing the matcher or inward
  architecture.
- Before App Store or commercial distribution, Curves should retain Apache 2.0
  notices and obtain its own legal review; this ADR is technical evidence, not
  legal advice.
- Physical-iPad and representative-member validation remain blocking gates.
- Fixed diagnostics make a generic UI failure traceable without widening the
  privacy or Clean Architecture boundaries.

## Sources

- OpenCV Zoo SFace model and directory license:
  <https://github.com/opencv/opencv_zoo/tree/4.10.0/models/face_recognition_sface>
- OpenCV Zoo Apache 2.0 license:
  <https://github.com/opencv/opencv_zoo/blob/4.10.0/LICENSE>
- OpenCV Zoo YuNet 4.10.0 model, demo, and directory license:
  <https://github.com/opencv/opencv_zoo/tree/4.10.0/models/face_detection_yunet>
- Apple Core ML PyTorch conversion workflow:
  <https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html>
- Apple `vImageScale_ARGB8888` API:
  <https://developer.apple.com/documentation/accelerate/vimagescale_argb8888%28_%3A_%3A_%3A_%3A%29>
- Apple vImage resampling guidance:
  <https://developer.apple.com/documentation/accelerate/resampling-in-vimage>
- Intel model specification:
  <https://github.com/openvinotoolkit/open_model_zoo/blob/master/models/intel/face-reidentification-retail-0095/README.md>
- Intel Open Model Zoo Apache 2.0 license:
  <https://github.com/openvinotoolkit/open_model_zoo/blob/master/LICENSE>
