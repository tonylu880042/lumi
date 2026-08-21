# Curves Lumi — Development Roadmap

> File: `roadmap.md`
> Status: Active
> Last updated: 2026-08-21
> Development principles: Clean Architecture + TDD + Ask-if-Unclear

## 1. Roadmap Goal

This roadmap defines the implementation sequence for **Curves Lumi**, an AI-powered smart welcome and member interaction assistant for Curves stores.

It answers:
- What is currently being implemented?
- What comes next?
- When should hardware integration begin?
- When should Apple Vision / Core ML member recognition begin?
- What must be complete before moving to the next milestone?
- Which requirements must be clarified before implementation?

This roadmap does not replace `SYSTEM_SPEC.md`, feature specifications, or ADRs.

### Language and Voice Scope

> **注意：目前 Lumi 系統僅支援中文。** UI 文案、提示詞與對話內容以
> 台灣繁體中文為基準；語音辨識與語音輸出以台灣華語口音為優先驗收目標。
> 其他語言與多語切換不在目前 roadmap 範圍內，必須經產品決策後另立里程碑。

## 2. Development Principles

### Clean Architecture

```text
UI
↓
Presentation
↓
Application / Use Cases
↓
Domain
```

Infrastructure implements Application ports.

External frameworks such as SwiftUI, AVFoundation, Vision, Core ML, OpenAI Realtime, WebSocket, Raspberry Pi GPIO, and ESP32 communication must remain outside Domain and Application business rules.

### TDD

All production behavior follows:

```text
RED → GREEN → REFACTOR
```

Requirements:
- New behavior requires a failing test first.
- Bug fixes require a regression test first.
- State transitions require tests.
- Use Cases require tests.
- Domain policies require tests.
- Adapter mappings require contract/integration tests.

### Ask-if-Unclear

If an unresolved requirement affects UX, Domain behavior, state transitions, API contracts, privacy, member data, recognition thresholds, hardware behavior, voice behavior, or acceptance criteria, stop the affected implementation and ask the product owner.

No silent product assumptions.

## 3. Current Development Status

### Avatar M0 — Domain / Presentation Model
**Status: Complete**

Completed:
- `AssistantState`
- `AvatarVisualState`
- `AvatarStateMapper`
- Clean separation between Domain and visual parameters
- Pure deterministic mapping
- Unit tests

### Avatar M1 — SwiftUI Visual Layer
**Status: Complete**

Completed:
- Lumi eye rendering
- Multi-layer iris
- pupil
- watery multi-point highlights
- eyelid masking
- scalable geometry
- SwiftUI rendering layer
- visual tokens

### Avatar M2 — Continuous Animation
**Status: Complete / tuning**

Completed:
- randomized blinking
- micro eye movement
- highlight breathing
- deterministic time injection
- reduced motion behavior
- animation composition
- iOS tuning shell
- detected left / center / right gaze behavior

Current tuning may still include iris size, pupil ratio, gaze travel, visual weight, and state distinction.

## 4. Avatar M3 — Event / State Expression Layer

**Status: Complete**

Goal: complete Lumi as a reusable animated character component before connecting full system services.

Implement:
- greeting state transition and optional short-lived recognition effect
- encouraging state animation without a duplicate Domain Event
- reminding state
- confused / retry state
- recognition transition
- speaking / listening presentation
- sparkle / heart / question effects
- event lifetime and cancellation
- state transition animation rules

Completed in the current working slice:
- Domain `AssistantEvent` taxonomy from Avatar Visual Spec §5.3
- Presentation-owned `AvatarEventCommand` and exhaustive Domain event mapper
- `LumiUI` consumes Presentation event commands without importing `LumiDomain`
- package dependency boundary enforces `LumiUI → LumiPresentation`
- pure `EventLayer` duration, effect mapping, and intensity envelope
- State → Continuous → Event → Accessibility compositor order
- vector effect shapes and Simulator trigger controls
- Event lifetime, replacement, and latest-base-state unit tests
- clamped Event decoration intensity rendered independently from ambient sparkle
- Presentation-owned replacement, explicit cancellation, and expiry through `AvatarEventPlayback`
- Reduced Motion fallback that keeps the active Event as a static, fully visible effect
- destination `AvatarTransition` consumed at the single `AnimatedLumiAvatarView` coordination point
- Presentation-owned amplitude smoothing, batch downsampling, and clamp pipeline
- one processed amplitude routed to listening waveform and speaking waveform/mouth
- Simulator amplitude controls showing raw and processed values
- constant-memory deterministic blink scheduling with no runtime horizon
- native pixel snapshot coverage for states, gaze, Events, audio, eyelids,
  highlights, themes, and Reduced Motion

Final M3 approval gate completed:
- product owner approved the checked-in visual baseline sheets on 2026-08-09
- shipping canvases are bright white and light lavender; dark UI is unsupported

### Immediate TDD Execution Order

Implement the remaining M3 work as these reviewable slices. Each slice starts
with a failing test, ends with `swift test` and the Simulator build, and must be
green before the next slice begins.

1. **M3.1 — Presentation boundary (Complete)**
   - Added the Presentation-owned `AvatarEventCommand` and exhaustive mapper tests.
   - Moved Event-layer input from `AssistantEvent` to `AvatarEventCommand`.
   - Removed `LumiDomain` from `LumiUI` source imports and package dependencies.
   - Kept Domain-to-Presentation mapping in `LumiPresentation`; the App remains
     the composition root.
2. **M3.2 — Event lifecycle and accessibility (Complete)**
   - Replaced the Reduced Motion behavior that erased Event effects with a
     static, fully visible effect fallback.
   - Applied the intensity envelope to Event decoration rendering.
   - Made replacement, explicit cancellation, expiry, and latest-base-state
     restoration observable and tested through the public Presentation API.
3. **M3.3 — Transition and audio inputs (Complete)**
   - Consumed `AvatarTransition` at the single animation coordination point,
     with immediate semantic updates under Reduced Motion.
   - Added a mock amplitude processor with smoothing, batch downsampling, and
     clamp tests for `listening` and `speaking`.
4. **M3.4 — Long-running and visual regression coverage (Complete)**
   - Replaced the one-hour array horizon with an ongoing deterministic timeline
     that has constant query cost and constant memory use.
   - Added four native pixel snapshot matrices with fixed size, scale, seed,
     time, Event progress, audio input, and Reduced Motion coverage.
   - Product owner approved the checked-in baselines; dark-background coverage
     remains diagnostic only, not a supported product theme.

Phase 1.1 completed the first vertical slice: `rotating`, the deterministic
reducer transition, validated rotation angles, mock hardware completion,
explicit Avatar mapping, snapshots, and Simulator state selection landed
together. Next, add the remaining ports, mocks, coordinator, and Simulator
controls around that tested state flow.

### TDD Acceptance

```text
greeting
→ happy visual state
→ stronger highlight
→ greeting effect active

encouraging
→ elevated sparkle
→ energetic expression

confused
→ confused expression
→ no fabricated member state

event expires
→ returns to base AssistantState visual state
```

### Exit Criteria
- All core `AssistantState` values have readable visual differences.
- Continuous animation and event animation do not conflict.
- Reduced Motion remains supported.
- Avatar can be driven entirely from mocked state input.

## 5. Phase 1 — Simulated Interaction MVP

**Status: Complete — the simulated interaction loop and all Phase 1 port
contracts are implemented and verified**

Goal: create a complete Lumi interaction loop without real hardware, real face recognition, or real Curves backend.

Architecture introduced:

```text
Domain
Application
Presentation
Infrastructure mocks
UI
Composition Root
```

Implement:
- `AssistantSessionCoordinator`
- deterministic State Reducer
- Application Use Cases
- `IdentityRecognitionPort`
- `MemberRepository`
- `VoiceSessionPort`
- `HardwareControlPort`
- Mock adapters
- debug/simulation control panel

Target flow:

```text
Idle
↓
Simulate Visitor
↓
Detected
↓
Rotating (MockHardwareControlPort)
↓
Recognizing
↓
Mock Known or Unknown Visitor
↓
Greeting
↓
Speaking (initial greeting)
↓
Listening
↓
Thinking
↓
Speaking (response)
↓
Timeout
↓
EndSession + Mock Hardware Return Home
↓
Idle
```

### Important Architecture Decision

`IdentityRecognitionPort` must be defined in this phase even though real Vision/Core ML recognition is implemented later.

```swift
protocol IdentityRecognitionPort {
    func recognizeCurrentVisitor() async throws -> RecognitionResult
}
```

Phase 1:
```text
MockIdentityRecognitionAdapter
```

Future:
```text
VisionCoreMLIdentityAdapter
```

### Exit Criteria
The complete interaction flow runs in iPad Simulator with:
- no Raspberry Pi
- no Vision
- no Core ML
- no real Curves backend
- no mandatory OpenAI connection

All external systems must be replaceable by mocks.

Phase 1 introduces `AssistantState.rotating` together with the deterministic
State Reducer, mock `HardwareControlPort`, tests, and an explicit Avatar mapping.
`ending` and `returnHome` remain Application actions rather than state cases.

Phase 1.1 decisions:
- `rotating` is parameterless and maps to a centered attentive expression
- illegal reducer transitions throw a typed Domain error
- rotation angles are finite degrees in `-90...90`; invalid values are rejected
- mock `rotate(to:)` completes only after explicit arrival confirmation

Phase 1.1 completed:
- Domain reducer covers `idle → detected → rotating → recognizing` and rejects
  every illegal transition with a typed error
- `RotationAngle` validates finite values in the inclusive safety range
- Application owns the `HardwareControlPort`; Infrastructure provides a
  deterministic, cancellation-safe actor mock with explicit arrival control
- Presentation maps the twelfth baseline state, snapshot coverage includes
  `rotating`, and the Simulator debug state picker exposes it

Phase 1.2 decisions:
- Simulator orientation is staged as Confirm Presence → Begin Rotation →
  Complete Rotation, with no invented wall-clock delay
- left/center/right always issue absolute `-90°`/`0°`/`+90°` commands and wait
  for explicit arrival
- rotation failure or cancellation stops hardware and returns through the
  reducer to the original `detected(direction:)`, allowing retry
- Session simulation and Avatar tuning remain separate debug-control modes;
  Session mode is the default and the coordinator remains the only session
  state owner. App/Xcode wiring occurs only after the coordinator API review
  gate.

Phase 1.2 coordinator API completed:
- `AssistantSessionCoordinator` is the actor-isolated state owner and exposes
  read-only state updates for independent observers
- orientation maps left/center/right to validated absolute
  `-90°`/`0°`/`+90°` targets and advances to `recognizing` only after confirmed
  hardware arrival
- duplicate or reentrant commands are rejected through the typed Domain
  transition error without replacing an active rotation
- hardware failure and caller cancellation stop movement, restore the original
  `detected(direction:)` through the reducer, propagate the original error, and
  permit a deterministic retry

Phase 1.2 Simulator integration completed:
- the App composition root constructs one mock hardware adapter and one
  coordinator, then injects an App-side observable adapter without a singleton
- the App target links Application and Infrastructure directly while `LumiUI`
  remains Presentation-only
- Session mode is the default and exposes the explicit Confirm Presence → Begin
  Rotation → Complete Rotation sequence; Avatar tuning remains an independent
  mode and cannot overwrite coordinator state
- the full-screen Avatar stays on the supported bright canvas, with the debug
  overlay forced to the light appearance instead of adapting to a dark panel

Phase 1.3 decisions (see ADR-0006):
- `MemberID` preserves an exact non-empty value, while recognition confidence
  rejects non-finite values and values outside inclusive `0...1`
- known and unknown identity results both enter `greeting`; known may emit the
  existing member-recognized Event, but neither path queries member data
- the canonical voice flow is greeting → speaking → listening → thinking →
  speaking, driven by ready, speech-started, speech-ended, and response-ready
  events; ordinary conversation does not use Phase 3 tool-call events
- every Simulator stage is explicit and deterministic, with Unknown selected by
  default and no wall-clock delays
- identity and voice failures preserve the approved retryable state; identity
  adapter failure degrades to unknown while cancellation still propagates
- timeout and person-left share one end-session action: stop voice, stop active
  movement, return home, then enter idle only after confirmed arrival

Phase 1.3 identity slice completed:
- Domain defines validated `MemberID`, `RecognitionConfidence`, and the
  privacy-safe known/unknown `RecognitionResult`
- the reducer advances both identity outcomes from `recognizing` to `greeting`
  and keeps illegal transitions explicit
- Application defines `IdentityRecognitionPort`; Infrastructure supplies a
  deterministic cancellation-safe mock with explicit result completion
- the coordinator owns one recognition operation, degrades adapter failure to
  unknown, propagates cancellation, and preserves the result as session context
- Simulator defaults to Unknown and exposes one explicit Resolve Visitor stage;
  known shows the generic Taiwan Traditional Chinese「歡迎回來～」plus the
  existing member-recognized Avatar Event, while unknown shows「嗨，歡迎妳！」
  with no identity detail

Phase 1.3 mock voice slice completed:
- Domain reducer events cover the canonical `greeting → speaking → listening →
  thinking → speaking` lifecycle and reject illegal transitions explicitly
- Application defines a privacy-safe, Taiwan-Mandarin-only voice boundary;
  `VoiceContext` never carries a member ID, confidence, name, or language choice
- Infrastructure supplies a deterministic voice mock with explicit readiness,
  lifecycle events, cancellation-safe retry, and no wall-clock timing
- the coordinator is the sole voice-event subscriber and preserves the current
  semantic state on provider failure while exposing a generic retry condition
- Simulator Session mode uses Taiwan Traditional Chinese copy and explicit
  controls for startup, speech start/end, response readiness, and failure; the
  Avatar tuning mode remains isolated

Phase 1.3 end-session slice completed:
- Domain accepts one `sessionEnded` event from every active semantic state and
  rejects `idle`/`offline` without side effects; ending and Home remain actions
- the coordinator uses one operation generation to cancel or ignore stale
  orientation, identity, voice-start, and voice-event completions
- voice stops first, rotating hardware stops when needed, and `returnHome()`
  must confirm Home arrival before the reducer publishes `idle`
- Home failure or cancellation preserves the semantic state and session
  context for retry; confirmed idle clears recognition and voice-retry context
- the deterministic hardware mock exposes explicit Home completion and failure
  controls with cancellation-safe request IDs
- Simulator Session mode exposes「模擬逾時」、「模擬訪客離開」、Home
  completion, and Home failure/retry controls; confirmed idle resets direction
  to center, identity to Unknown, and cancels any transient Session Avatar Event

Phase 1 member-data boundary completed:
- Domain defines framework-free, `Sendable` `Member` and `ExerciseSummary`
  values for member profile and weekly activity data
- Application defines the `Sendable` `MemberRepository` port with only
  `profile(for:)` and `weeklySummary(for:)`
- Phase 1 does not construct a member repository, query member data, or expose
  member questions in the Simulator; mock query behavior remains Phase 3

Phase 1 defines `MemberRepository` as a port but does not implement member
questions or repository query behavior. Those remain in Phase 3 with mock member
data and tool calling.

## 6. Phase 2 — OpenAI Realtime Voice

**Status: In Progress**

Goal: replace simulated voice with natural realtime voice interaction.

Implement:
- Realtime session abstraction
- OpenAI Realtime infrastructure adapter
- short-lived credential flow
- audio input/output
- interruption
- listening/speaking state integration
- inactivity timeout
- session shutdown
- error/reconnect behavior

Architecture:

```text
Application
↓
VoiceSessionPort
↓
OpenAIRealtimeAdapter
```

OpenAI types must not leak into Domain.

Realtime becomes active only when a person is confirmed in front of Lumi. Do not keep an active session for the full store business day.

Phase 2.1 decisions:
- iOS production transport targets WebRTC; the first slice uses an injected
  transport seam so Simulator tests require no network, microphone, or provider
- initial provider configuration uses `gpt-realtime-2.1-mini` with `marin`
- session instructions require Taiwan Traditional Chinese and prioritize natural
  Taiwan Mandarin; regional accent remains a physical-device quality target,
  not an API guarantee
- `responseReady` is emitted at the first playable response audio, while the
  initial greeting remains represented by voice-session readiness
- assistant interruption is a public provider-independent voice event and maps
  to the existing speaking-to-listening Domain transition
- an unexpected disconnect retries once with a new short-lived credential; the
  retry starts a fresh provider session and does not promise transcript recovery
- the app receives only injected short-lived credentials; the standard OpenAI
  API key remains on the company backend

Phase 2.1 completed:
- provider-independent Realtime configuration and redacted short-lived client
  secret contracts
- an injected transport and factory seam requiring no network or microphone in
  tests
- deterministic provider event mapping for readiness, first playable audio,
  interruption, failures, and unknown future events
- a cancellation-safe adapter with one fresh-credential reconnect attempt and
  no provider types crossing `VoiceSessionPort`

Phase 2.2 completed scope:
- use `stasel/WebRTC` pinned to exact version `151.0.0`
- implement a concrete peer connection with local microphone input, remote
  assistant-audio playback, `oai-events`, and ephemeral-token SDP exchange
- configure provider-default `server_vad` with automatic response and
  interruption; defer threshold tuning to physical-iPad validation
- request microphone permission just in time, use a voice-chat audio session,
  prefer the iPad speaker without overriding wired or Bluetooth HFP routes, and
  add the approved microphone purpose string
- reject expired credentials before permission, media, or signaling, without
  inventing an expiry safety margin
- request the initial greeting exactly once and never replay it during the
  adapter's automatic reconnect
- keep the App on mock voice by default; concrete credential backend, Live mode,
  wall-clock timeout values, and real Avatar amplitude remain later Phase 2 work

Phase 2.2 implementation status: **Complete (automated gates)**
- resolved revision: `19aa8c1fc7120d50df987b7111f42d5024df3d54`
- upstream binary checksum:
  `64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`
- focused `OpenAIWebRTCTransportTests`: 21 tests in 1 suite passed
- Swift Testing: 247 tests in 16 suites passed; XCTest: 4 snapshot tests
  passed
- unsigned iOS Simulator build completed successfully
- automated checks used deterministic fakes and did not exercise real
  credentials, OpenAI network traffic, a microphone, or a physical iPad
- the App remains on `MockVoiceSessionPort`; physical-iPad validation of
  permission presentation, routing, echo cancellation, barge-in, interruption
  recovery, and Taiwan Mandarin quality is deferred

Phase 2.3 status: **Automated implementation/review through Task 17 complete; local checkpoint staging/commit authorized under 33A (2026-08-13), no push; Preview remains stopped and the Task 18 external gate is pending with no deployment**
- add a separately installable `LumiApp-Live` composition while preserving the
  existing offline Mock scheme
- add a minimal Vercel client-secret broker; the standard OpenAI key remains a
  server-only sensitive environment value
- authorize revocable per-iPad tokens through this-device-only Keychain storage
  and SHA-256 Vercel allowlists, with no member identity data in the broker
- keep hardware and identity mocked while real WebRTC voice drives the existing
  coordinator lifecycle
- isolate Preview and Production credentials, endpoints, and Keychain
  namespaces; require Preview review and physical-iPad evidence before explicit
  Production promotion
- defer App Attest, QR enrollment, a database registry, real identity, member
  data, timeout tuning, and Avatar amplitude

Refer to:

```text
docs/phase-2.2-webrtc-transport.md
docs/phase-2.2-webrtc-implementation-plan.md
docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md
docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md
docs/phase-2.3-live-voice.md
docs/phase-2.3-live-voice-implementation-plan.md
docs/phase-2.3-live-voice-task-list.md
docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md
```

### Exit Criteria
A simulated visitor can trigger greeting, speak naturally, interrupt Lumi, receive spoken reply, timeout, and return to idle.

## 7. Phase 3 — Mock Member Data + Tool Calling

**Status: Automated Debug-Live implementation complete; physical voice quality,
physical iPad validation, and real Curves data validation pending**

Goal: allow Lumi to answer member-specific exercise questions before integrating the real Curves backend.

Implement support for:
- member profile
- weekly visit count
- recent exercise summary
- today's goal
- activity total / MET-minutes where applicable

### Completed implementation slice

The first validated slice intentionally narrows the Phase 3 surface to one
weekly-summary tool:

- `get_member_weekly_summary` is exposed as a no-argument Realtime function
  with an empty, closed parameter object.
- Only a known local session registers the tool. The Application router binds
  the locally retained `MemberID`; OpenAI receives neither the ID nor any
  member identity field.
- Unknown/visitor sessions do not register the tool and cannot load member
  data. Tool calls are routed serially and return deterministic JSON or fixed
  redacted error codes.
- `Debug-Live` uses one fixed synthetic `MockMemberRepository` record. The
  Debug-Live instructions require the spoken answer to begin with
  「以下是開發測試資料」 so fixture data cannot be mistaken for Curves
  production data.
- `LumiApp` Release and `LumiApp-Live` Release-Live do not enable the mock
  member tool. The generic mock repository has no default records.

### Completed conversation-direction slice (43A)

The voice session can be focused before startup with one payload-free,
provider-neutral direction:

- `general`, `preWorkoutReminder`, and `postWorkoutReview` apply to both known
  members and unknown visitors.
- Only the per-session Realtime instructions change; general adds no direction
  text, and the pre-workout/post-workout text is fixed and does not contain a
  `MemberID`, name, confidence, embedding, photo, or other member payload.
- A direction does not force a tool call. The weekly-summary member tool remains
  known-session-only and on-demand; unknown/visitor sessions have no private
  member data path.
- The Debug-Live UI labels are exactly `一般`, `運動前提醒`, and `運動後
  review`. The picker is compiled/displayed only for `DEBUG && LUMI_LIVE`;
  Mock Debug, Release, and Release-Live use `general` without the picker.
- The picker is selectable only before voice startup, remains selected after a
  retryable startup failure, and resets to `general` after confirmed return to
  `idle`. Direction choice is neither persisted nor telemetered.
- The broker request/body and device authentication flow remain unchanged.

The current synthetic fixture is intentionally stable for manual validation:

| Field | Debug-Live value |
| --- | --- |
| Display name | `Lumi 開發測試會員` |
| Visits this week | `2` |
| Activity total | `580.5` MET-minutes |
| Last workout | `2026-08-18T02:30:00.000Z` |
| Today completed | `false` |

Automated evidence for this slice includes the focused package
runner/coordinator/mock gate (52/52), Debug and Debug-Live fixture/composition
tests, and unsigned generic Simulator builds for Mock Debug, Mock Release,
Debug-Live, and Release-Live. The exact `swift test` and `swift test --parallel`
runs reached build and visible passing suites (including 4/4 snapshots), but
the known `swiftpm-testing-helper` lifecycle hang required interruption; they
are not recorded as clean full-suite passes or full-suite counts.

43A evidence also includes the Slice 1 RED contract failure followed by the
focused package gate (80/80) and `swift build`, then the Slice 2 Debug RED
(`xcodebuild` exit 65) followed by focused Debug and Debug-Live tests. The
focused Debug summary was 13 tests in 2 suites; both focused configurations
passed. Full App gates passed 63/63 for `LumiApp` Debug and 63/63 for
`LumiApp-Live` Debug-Live, and all four unsigned generic Simulator builds
completed with exit 0. These automated results do not replace a physical
microphone/voice-quality check.

### Deferred boundary

Replacing the synthetic repository with a real `CurvesMemberAPIRepository` is
not part of this slice. It remains blocked on the verified API endpoint and
authentication flow, face/member identity mapping, profile and weekly-summary
schema, time-zone/week-boundary semantics, privacy/consent rules, error and
rate-limit behavior, and offline/cache policy. Those details belong to
Milestone 4 and must not be inferred from the Debug-Live fixture.

Example:

```text
Member:
「我這星期來幾次？」

Lumi:
→ Application Use Case
→ MemberRepository
→ Mock Member Data
→ Realtime tool result
→ spoken response
```

### Privacy Requirement
Only the minimum required member context may be provided to the LLM.

### Exit Criteria
Mock known members can ask the supported weekly-summary question and receive a
deterministic answer grounded in Debug-Live data. Unknown/visitor sessions
cannot query member data. Physical iPad microphone/voice-quality validation and
the real Curves adapter remain explicit follow-up gates; the adapter is blocked
on the verified Curves endpoint, authentication, identity mapping, schema,
privacy, error, rate-limit, and offline/cache contracts.

## 8. Milestone 2 — Smart Rotation Base

**Status: Planned**

Goal: connect Lumi to the physical rotating dock.

Hardware:
- Raspberry Pi prototype
- 3 ultrasonic sensors
- stepper motor
- motor driver
- Home sensor
- 180° rotation
- Wi-Fi LAN

Protocol:

```text
iPad
↕ WebSocket
Rotation Base
```

Implement:
- boot
- homing
- presence detection
- left / center / right coarse direction
- rotate command
- angle limits
- return home
- emergency stop
- communication-loss behavior

### Tests
- presence debounce
- direction selection
- rotation limits
- invalid angle rejection
- homing state
- sensor noise
- motor failure
- disconnect recovery

### Exit Criteria
A person approaching left/center/right causes Lumi to orient approximately toward the visitor while respecting motor limits.

## 9. Milestone 3 — Member Identity Recognition

**Status: In progress — 42A DEBUG physical calibration and photo-library
import fallback implemented; physical-iPad validation pending**

> **Apple Vision / Core ML member recognition begins here.**

Goal: use the iPad camera to determine whether the current visitor is a registered Curves member.

This milestone must use the existing `IdentityRecognitionPort`; Domain/Application must not be redesigned to accommodate Vision.

The 41A checkpoint now supplies a DEBUG-only, manually gated physical
calibration path using the real front-camera, Vision, YuNet, SFace, exact
cosine gallery, and a dedicated SQLite calibration database. It exposes raw
top-1/top-2 scores and margin for measurement; it does not make a production
known/unknown decision or replace `IdentityRecognitionPort`.

The 42A checkpoint adds a DEBUG-only photo-library fallback: SwiftUI
`PhotosPicker` selects one image and loads its current representation as
transient in-memory data. It enters the same Vision → YuNet → SFace → SQLite
gate without requesting camera or full-library photo permission and without
starting the camera. Infrastructure accepts only an actual JPEG/PNG/HEIC UTI
with one image, applies EXIF orientation, and emits an owned
upright/non-mirrored top-left BGRA8 frame with a 64-byte padded stride; ImageIO
downsamples to a maximum edge of 2048 as a memory bound only. Enrollment stores
only the embedding; return import ranks the full gallery and never saves
photos. Picker items and encoded/decoded image data are never persisted or
logged, and Release builds omit the tool. Physical-iPad quality and production
recognition policy remain pending.

### I0 — Identity Port Validation
Verify:
```text
IdentityRecognitionPort
RecognitionResult
MemberID
RecognitionConfidencePolicy
```

### I1 — Camera Capture
Technology: AVFoundation

Implement:
- front camera session
- frame delivery
- permission handling
- camera unavailable behavior
- app lifecycle handling

### I2 — Face Detection
Technology: Apple Vision

```text
Camera Frame
↓
Vision Face Detection
↓
Face Bounding Boxes
```

Test:
- no face
- one face
- multiple faces
- partial face
- low-quality input

### I3 — Active Face Target Selection
Select exactly one conversation target.

Possible rules:
- largest face
- face closest to screen center
- closest confirmed physical target
- recognized member priority

**If not already decided, this policy must be confirmed before implementation.**

### I4 — Face Normalization
Implement:
- crop
- orientation normalization
- scale
- alignment if needed
- image normalization

Must be deterministic and testable.

### I5 — Face Embedding
Technology: Core ML face embedding model

```text
Normalized Face
↓
Core ML
↓
Embedding Vector
```

ADR-0010 selects OpenCV Zoo SFace as the primary model and Intel
`face-reidentification-retail-0095` as the challenger. The pinned SFace ONNX →
Core ML conversion PoC passes its numerical parity gate. The approved SFace and
YuNet packages are present under App resources, Xcode compiles them into bundled
`.mlmodelc` resources, and 41A/42A load them lazily after an explicit DEBUG
camera start or first photo import. Physical-iPad quality/performance,
validation data, thresholds, and the production recognition route remain gates.
Domain must never depend on vector dimensions or Core ML types.

### I6 — Member Matching

```text
Query Embedding
↓
Similarity / Distance
↓
Candidate Members
↓
RecognitionConfidencePolicy
```

Each member should support multiple registered embeddings.

Possible measures:
- cosine similarity
- Euclidean distance

Final choice must be documented.

The initial exact cosine matcher and model-version isolation are implemented.
At the target upper bound of 800 members × 5 samples, no vector database is
planned unless physical-iPad measurements require one.

### I7 — Confidence / Unknown Policy

Critical rule:

> **Unknown is safer than calling the wrong member name.**

```text
high confidence
→ known(MemberID)

insufficient confidence
→ unknown

ambiguous candidates
→ unknown
```

Tests:
- correct known member
- stranger
- similar-looking candidates
- low-quality image
- threshold boundary

Threshold must not be silently invented. It must be established using validation data and documented in an ADR.

### I8 — Member Enrollment

Recommended initial enrollment:
- 3–5 images per member
- frontal
- mild left/right angle
- common appearance variation

Identity relationship:

```text
Face Embeddings
↓
member_id
```

Do not use display name as the recognition database primary key.

### I9 — End-to-End Identity Flow

```text
Presence Detected
↓
Rotate
↓
Camera Confirms Person
↓
Vision Detects Face
↓
Core ML Embedding
↓
Member Matcher
↓
RecognitionConfidencePolicy
├─ known(MemberID)
└─ unknown
↓
AssistantSessionCoordinator
↓
Greeting
```

### Exit Criteria
- Known-member test set meets agreed validation criteria.
- Stranger cases do not produce unsafe false identity claims.
- Recognition integrates without changing Domain/Application boundaries.
- Failed recognition gracefully falls back to generic greeting.

## 10. Milestone 4 — Real Curves Member / Exercise API

**Status: Planned**

Goal: replace mock data with actual Curves member and exercise data.

Implement:
```text
CurvesMemberAPIRepository
```

Expected capabilities:
- member profile
- visit history
- weekly summary
- recent exercise
- goals
- relevant activity metrics

Architecture:

```text
MemberRepository
↑
CurvesMemberAPIRepository
```

Use standardized exercise terms where applicable:
- 代謝當量（METs）
- 活動總量（MET-minutes）
- 訓練總量（kg）
- 平均心率（bpm）
- 範圍（ROM）
- 次數達成率
- 器材表現分數

Do not invent medical meaning from exercise metrics.

### Exit Criteria
Real member questions are answered using verified backend data.

## 11. Milestone 5 — Integrated Store MVP

**Status: Planned**

Goal: combine all major subsystems.

```text
Presence
↓
Rotation
↓
Camera
↓
Identity
↓
Member Context
↓
Realtime Voice
↓
Exercise Interaction
```

### Exit Criteria

```text
member approaches
→ Lumi notices
→ eyes look toward visitor
→ dock rotates
→ member recognized
→ personalized greeting
→ member asks question
→ Lumi answers from member data
→ member leaves
→ Realtime closes
→ Lumi returns home
```

## 12. Milestone 6 — Pilot Store Hardening

**Status: Future**

Areas:
- kiosk mode
- crash recovery
- watchdog
- app auto-recovery
- hardware reconnect
- network reconnect
- telemetry
- Realtime cost monitoring
- privacy behavior
- face recognition validation
- operation logging
- OTA/update strategy

Metrics:
- sessions/day
- recognition success rate
- false recognition rate
- unknown rate
- voice session duration
- tool latency
- Realtime latency
- hardware errors
- rotations/day
- estimated cost/store/day

## 13. Productization — ESP32 Smart Dock

**Status: Future**

After Raspberry Pi prototype behavior is stable:

```text
Raspberry Pi
↓
ESP32 Smart Rotation Dock
```

The iPad Application / Domain should not require changes if the hardware Port contract remains compatible.

Final architecture:

```text
Curves Cloud
↓
Curves Lumi iPad App
↓
ESP32 Smart Rotation Dock
```

## 14. Roadmap Summary

```text
Avatar M0        ✅ Domain / Presentation
Avatar M1        ✅ SwiftUI Visual Layer
Avatar M2        ✅ Continuous Animation / tuning
Avatar M3        ✅ Event & Expression Layer

Phase 1          ✅ Simulated Interaction MVP
Phase 2          ▶ OpenAI Realtime Voice
Phase 3          Mock Member Data + Tool Calling

Milestone 2      Smart Rotation Base

Milestone 3      Vision + Core ML Identity Recognition
                 ├─ Camera
                 ├─ Vision Face Detection
                 ├─ Target Selection
                 ├─ Face Normalization
                 ├─ Core ML Embedding
                 ├─ Member Matching
                 ├─ Confidence / Unknown Policy
                 └─ Enrollment

Milestone 4      Real Curves Member API
Milestone 5      Integrated Store MVP
Milestone 6      Pilot Store Hardening
Productization   ESP32 Smart Dock
```

## 15. Rule for Roadmap Changes

A roadmap change that affects product behavior or milestone order must be documented.

Use:

```text
docs/decisions/ADR-xxxx-*.md
```

Update this roadmap whenever:
- a milestone begins
- a milestone is completed
- a major dependency changes
- a product decision changes milestone scope
- implementation reveals a new required milestone
