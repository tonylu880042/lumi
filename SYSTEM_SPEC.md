# Curves Lumi — System Specification

> File: `SYSTEM_SPEC.md`
> Status: Active Product/System Baseline
> Version: 0.5
> Last updated: 2026-08-10
> Product: Curves Lumi
> Principles: Clean Architecture + TDD + Ask-if-Unclear

---

# 1. Product Overview

**Curves Lumi** is a tabletop smart welcome and member interaction assistant designed for Curves stores.

Lumi combines:

- iPad-based animated character UI
- visitor presence detection
- motorized 180° rotating dock
- member identity recognition
- Curves member/exercise data integration
- natural realtime voice interaction
- personalized greeting and exercise encouragement
- privacy-aware member assistance

Lumi is not positioned as a generic kiosk, a simple face-recognition terminal, or a medical device.

Its intended role is:

> **A friendly AI member assistant that notices members, turns toward them, recognizes them when possible, understands their exercise context, talks naturally, and encourages continued participation.**

---

# 2. Core User Experience

Target end-to-end experience:

```text
發現會員
↓
主動轉向
↓
辨識會員
↓
個人化迎賓
↓
讀取會員運動情境
↓
聽會員說話
↓
自然回答
↓
鼓勵運動
↓
會員離開
↓
關閉語音 Session
↓
回到 Home / Idle
```

English system flow:

```text
Presence Detected
↓
Orient Toward Visitor
↓
Identify Visitor
↓
Personalized Greeting
↓
Load Member Context
↓
Realtime Conversation
↓
Exercise Guidance / Encouragement
↓
Session Ends
↓
Return Home
```

---

# 3. Product Positioning

Lumi should be understood as:

> **Curves 店內數位會員小幫手 / AI Member Assistant**

Primary product value:

- makes the store feel more responsive and intelligent
- creates immediate member recognition and welcome
- connects exercise data to everyday member interaction
- increases visibility of member progress
- helps reinforce exercise habits
- extends digital services beyond the exercise equipment screen

Lumi should not pretend to replace human coaches.

---

# 4. Product Personality

Lumi's persona:

> **年輕、親切、有活力、懂會員運動狀況的女性數位小幫手**

Characteristics:

- warm
- lively
- encouraging
- slightly playful
- not childish
- not overly cute
- natural Taiwanese Traditional Chinese
- usually concise
- aware of the member's exercise context
- never pretends to be a human coach
- never gives medical diagnosis

Baseline persona guidance:

```text
你是 Curves 店內的智慧運動小幫手。
你是一個有活力、親切、溫暖、略帶俏皮感的女性角色。
你會記得會員的運動情境，並鼓勵她持續運動。
使用台灣繁體中文。
一般回覆控制在 1–2 句。
語氣自然、口語、親切。
可愛但不要幼稚，不要過度撒嬌。
遇到達標時可以明顯表現開心。
遇到提醒時語氣溫柔。
不要診斷疾病，也不要取代教練或醫療專業人員。
```

Preferred recurring expressions:

- 「一起加油喔～」
- 「太棒了！」
- 「我來幫妳看看～」

---

# 5. Visual Identity

The Lumi UI should use:

- bright white / light lavender background
- Curves purple family
- large expressive floating eyes
- minimal facial elements
- speech/message area
- microphone or waveform feedback
- warm, friendly visual language
- no dark high-tech aesthetic

Bright white and light lavender are the supported product canvases. A dark
theme or black background is not part of the Lumi product experience; any dark
snapshot is diagnostic contrast coverage only and must not be presented as a
shipping theme.

Recommended color family:

```text
Primary Purple   #7B2CBF
Deep Purple      #5B1A8B
Light Purple     #F4ECFA
Pink             #EC407A
Green            #2E9B50
Orange           #F28C28
Navy Text        #222A54
```

---

# 6. Avatar Visual Architecture

The Avatar follows:

> **Vector-first + SwiftUI Native Animation + minimal special assets**

Core principle:

> **Visual assets define what Lumi looks like; state defines what Lumi is doing; animation defines how the state transition feels.**

Avoid:

```text
idle.png
happy.png
thinking.png
speaking.gif
...
```

Preferred structure:

```text
LumiAvatar
├── LeftEye
│   ├── EyeWhite
│   ├── IrisOuterRing
│   ├── IrisBody
│   ├── Pupil
│   ├── SoftGloss
│   ├── Highlights
│   └── Eyelid
├── RightEye
├── Eyebrows
├── Blush
├── Mouth
├── Waveform
└── Effects
    ├── Sparkles
    ├── Hearts
    ├── Question
    └── Celebration
```

---

# 7. Watery Eye Design

Lumi's eyes must not look like simple flat circles.

Each eye should contain:

- white eye shape
- layered purple iris
- darker outer iris ring
- pupil
- multiple white highlight circles/ellipses
- soft translucent gloss
- eyelid mask

Required highlight design:

- 2–4 white highlights per eye
- largest highlight near upper-left
- smaller nearby secondary highlight
- subtle lower/right reflection
- consistent light direction between both eyes
- highlights move with the iris
- highlights may change opacity/scale by state

Core goal:

> **水汪汪、閃亮、有生命感，而不是平面的圓形眼球。**

Refer to:

```text
Curves_Lumi_Avatar_Visual_Spec.md
```

---

# 8. Avatar State Model

Product state and visual state must be separate.

Phase 1 Domain state:

```swift
enum AssistantState {
    case idle
    case detected(direction: PresenceDirection)
    case rotating
    case recognizing
    case greeting
    case listening
    case thinking
    case speaking
    case encouraging
    case reminding
    case confused
    case offline
}
```

Phase 1.1 introduced `rotating` together with the deterministic State Reducer,
mock `HardwareControlPort`, unit tests, and an explicit Avatar mapping. `ending`
and `returnHome` are Application actions, not `AssistantState` cases.

The approved Phase 1 `rotating` state is parameterless. Its Avatar expression
is centered and attentive; it does not preserve the preceding detected gaze
direction and does not show a waveform. Illegal reducer transitions return a
typed Domain error rather than being silently ignored.

Presentation model:

```swift
struct AvatarVisualState {
    var eyeOpenAmount: Double
    var pupilOffsetX: Double
    var pupilOffsetY: Double
    var irisScale: Double
    var pupilScale: Double
    var blushOpacity: Double
    var sparkleIntensity: Double
    var effect: AvatarEffect?
    var effectIntensity: Double
    var highlightIntensity: Double
    var eyebrowStyle: EyebrowStyle
    var mouthStyle: MouthStyle
    var mouthOpenAmount: Double
    var audioAmplitude: Double
    var waveformMode: WaveformMode
    var transition: AvatarTransition
}
```

Mapping:

```text
AssistantState
↓
AvatarStateMapper
↓
AvatarVisualState
↓
SwiftUI animation
```

Domain must not know coordinates, opacity, SwiftUI types, or animation details.

---

# 9. Avatar Animation Layers

Lumi animation uses three conceptual layers.

## 9.1 Continuous Animation

Always-on subtle behavior:

- random blinking
- micro eye movement
- highlight breathing
- small life-like motion

The timing should not feel mechanical.

Example blink interval:

```text
random 2–6 seconds
```

## 9.2 State Animation

Driven by `AssistantState`.

Examples:

```text
detected
→ pupils look toward person
→ eyes slightly widen

recognizing
→ focused expression

greeting
→ brighter highlights
→ warmer expression

thinking
→ eyes look slightly upward

listening
→ attentive expression + input waveform

speaking
→ output waveform + expressive eyes
```

## 9.3 Event Animation

Short-lived Domain event overlays:

- playful
- member recognized
- first visit
- long time no see
- exercise goal achieved
- weekly target reached
- error

Examples:

```text
sparkle burst
heart
celebration
question mark
```

`encouraging` and `confused` remain long-lived `AssistantState` cases. Their
Presentation may use sparkle or question-mark effects, but the Domain must not
introduce duplicate `.encouragement`, `.retry`, or `.confusion` Event cases.

The UI boundary uses a Presentation-owned command:

```swift
public enum AvatarEventCommand: Equatable, Sendable {
    case playful
    case memberRecognized
    case firstVisit
    case longTimeNoSee
    case goalAchieved
    case weeklyGoalCompleted
    case error
}
```

`LumiPresentation` maps `AssistantEvent` to `AvatarEventCommand` exhaustively.
`LumiUI` consumes only `AvatarEventCommand`; it does not import or expose
`AssistantEvent`. Each delivered command is a trigger, and Presentation owns
replacement, cancellation, and expiry behavior. Only one Event is active: a
new command immediately replaces the current Event, Events are never queued or
stacked, explicit cancellation clears the active Event, and expiry returns to
the latest base State.

With Reduced Motion enabled, Event feedback must remain semantically visible as
a static symbol or short opacity transition. Large translation, bounce,
rotation, and looping particle motion must be removed.

---

# 10. Hardware Concept

Lumi is a tabletop iPad device mounted on a rotating base.

Core hardware:

- iPad
- rotating base
- stepper motor
- motor driver
- Home sensor / Hall sensor / limit sensor
- 3 ultrasonic sensors
- Raspberry Pi prototype controller
- future ESP32 product controller

Rotation coordinate:

```text
Home = 0°
Left = -90°
Right = +90°
```

Maximum intended coverage:

```text
180°
```

Software angle limits are mandatory.

Startup homing is mandatory.

---

# 11. Hardware Responsibility Split

Core architectural rule:

```text
iPad = Brain + Face + Voice + UI + Member Experience

Raspberry Pi / ESP32 = Body
                       Sensor
                       Motor
                       Safety
```

The iPad must not be treated as a GPIO controller.

Edge controller responsibilities:

- ultrasonic sampling
- presence filtering
- coarse left/center/right direction
- motor control
- homing
- angle safety
- watchdog
- hardware fault reporting

iPad responsibilities:

- system session state
- identity
- member context
- voice
- UI
- conversation
- product behavior

---

# 12. Presence Detection

Three ultrasonic sensors:

```text
LEFT
CENTER
RIGHT
```

Their role is limited to:

1. presence detection
2. rough direction estimation

They are not precision people-tracking sensors.

Example configurable behavior:

```yaml
presence:
  min_cm: 30
  max_cm: 250
  confirmation_samples: 3
  sensor_hysteresis_cm: 15
```

Exact product values must be validated.

---

# 13. Physical Orientation Behavior

Intended behavior:

```text
visitor detected on left
↓
eyes look left first
↓
rotation begins left
↓
camera sees person
↓
fine visual alignment
↓
interaction starts
```

This creates a more natural perception:

> Lumi notices first, then turns toward the member.

The motor should never be directly controlled by the LLM.

---

# 14. Edge State Machine

Suggested edge FSM:

```text
BOOT
↓
HOMING
↓
READY
↓
TARGET_DETECTED
↓
ROTATING
↓
TRACKING
↓
HOLD
↓
RETURN_HOME
```

Error states may include:

```text
ERROR
MOTOR_STALL
HOME_SENSOR_ERROR
COMMUNICATION_LOST
```

The Edge state machine is separate from the Lumi product/session state.

---

# 15. iPad ↔ Edge Communication

Recommended transport:

- local network
- WebSocket
- optional Bonjour/mDNS discovery

Example endpoint:

```text
ws://curves-lumi-base.local/ws
```

Messages must be versioned.

Example:

```json
{
  "protocol_version": 1,
  "message_id": "uuid",
  "type": "presence.detected",
  "timestamp": "2026-08-09T11:30:00+08:00",
  "payload": {
    "direction": "left",
    "distance_cm": 82
  }
}
```

Commands:

```text
rotation.goto
rotation.home
rotation.stop
```

Events:

```text
presence.detected
presence.left
rotation.started
rotation.completed
hardware.error
```

Breaking protocol changes require a new protocol version.

---

# 16. Voice Interaction

Lumi should use natural realtime speech, not traditional robotic TTS.

Preferred architecture:

```text
OpenAI Realtime speech-to-speech
```

Capabilities:

- audio input
- audio output
- natural turn-taking
- interruption
- tool calling
- conversational reasoning

Voice implementation must remain behind:

```swift
protocol VoiceSessionPort
```

OpenAI provider-specific types must stay in Infrastructure.

---

# 17. Voice Session Activation

Voice must be **event-triggered**.

Do not keep Realtime voice active for all store operating hours.

Target flow:

```text
IDLE
↓
presence confirmed
↓
rotate
↓
camera confirms person
↓
open voice session
↓
greet / converse
↓
person leaves OR inactivity timeout
↓
close voice session
↓
return HOME / IDLE
```

Potential configurable values:

```yaml
presence_confirm_ms: 1500
voice_initial_response_timeout_sec: 8
voice_idle_timeout_sec: 20
return_home_timeout_sec: 30
session_max_duration_sec: 120
```

These are design defaults only unless formally approved.

---

# 18. API Key / Realtime Security

The OpenAI API key must never be embedded in the iOS application binary.

Recommended:

```text
iPad
↓
Company Backend
↓
short-lived / ephemeral credential
↓
OpenAI Realtime
```

The iPad should use short-lived credentials.

---

# 19. Member Identity Recognition

Member recognition uses:

```text
iPad Camera
↓
AVFoundation
↓
Apple Vision
↓
Face Detection
↓
Face Normalization
↓
Core ML Face Embedding
↓
Member Matching
↓
RecognitionConfidencePolicy
↓
known(MemberID) / unknown
```

Important:

> Apple Vision detects faces; it does not by itself define Curves member identity matching.

Identity must be keyed by:

```text
member_id
```

not by display name.

Refer to:

```text
docs/identity-recognition.md
docs/decisions/ADR-0004-face-match-confidence-policy.md
```

---

# 20. Face Recognition Safety Rule

Core product rule:

> **Unknown is better than calling the wrong member name.**

Recognition must not use a naive highest-score-wins rule.

Required confidence evidence includes:

- top-1 score
- top-1 / top-2 margin
- face quality
- multi-frame consistency

If evidence is weak:

```text
unknown
```

Unknown is a normal product state, not a failure.

The confidence policy returns an internal `RecognitionDecision`, including
`unknown(reason:)` for orchestration, tests, and aggregate telemetry. Before the
result crosses `IdentityRecognitionPort`, Application maps it to the public
`RecognitionResult`, whose unknown case does not expose the low-level reason.
UI consumes only the public result and must not display policy failure details.

---

# 21. Identity Enrollment

Enrollment should normally collect multiple samples per member.

Suggested initial target:

- 3–5 images
- frontal
- mild left
- mild right
- normal appearance variation where appropriate

Identity relationship:

```text
Face Embeddings
↓
MemberID
```

Enrollment must not silently occur for passersby.

Consent and identity confirmation must be explicitly defined before production.

---

# 22. Member Data Integration

Lumi integrates with the Curves exercise/member system through:

```swift
protocol MemberRepository
```

Expected conceptual capabilities:

```text
GET member profile
GET weekly summary
GET recent exercise summary
GET goals
```

Potential API shape:

```text
GET /members/{member_id}
GET /members/{member_id}/weekly-summary
GET /members/{member_id}/recent-exercises
GET /members/{member_id}/goals
```

Example:

```json
{
  "member_id": "M123456",
  "display_name": "王小姐",
  "visits_this_week": 2,
  "activity_met_minutes": 580,
  "last_workout_at": "2026-08-06T10:30:00+08:00",
  "today_completed": false
}
```

---

# 23. Exercise Data Terminology

Use standardized terms consistently:

```text
代謝當量（METs）
活動總量（MET-minutes）
訓練總量（kg）
平均心率（bpm）
範圍（ROM）
次數達成率
器材表現分數
```

Rules:

```text
METs = intensity
MET-minutes = activity total
kg = training volume
```

Do not mix these meanings.

Lumi must not overstate medical implications from exercise metrics.

---

# 24. Member Interaction Examples

Supported interaction direction:

```text
「我這星期來幾次？」
```

```text
「我今天運動了嗎？」
```

```text
「我這週還差多少活動總量？」
```

```text
「今天要做什麼？」
```

Potential Lumi response:

```text
「王小姐，妳這週已經來兩次囉～今天一起完成第三次吧！」
```

Responses must be grounded in actual tool data.

---

# 25. LLM Tool Calling

Initial tools may include:

```text
get_member_profile(member_id)
get_member_weekly_summary(member_id)
get_recent_exercise_summary(member_id)
get_today_goal(member_id)
```

Rules:

- LLM does not access the database directly.
- Tool calls must enter through Application Use Cases.
- Tool output must be deterministic JSON.
- LLM cannot directly control the motor.
- Privacy policy must be checked before returning sensitive data.

Correct:

```text
Realtime Adapter
↓
ToolCall
↓
Application Use Case
↓
MemberRepository
↓
ToolResult
↓
Realtime Adapter
```

---

# 26. Session State Ownership

There must be one owner for active product state:

```text
AssistantSessionCoordinator
```

Flow:

```text
Hardware / Voice / Vision Event
↓
Domain/Application Event
↓
AssistantSessionCoordinator
↓
State Reducer
↓
AssistantState
↓
Presentation
```

No subsystem may independently own a competing product state.

---

# 27. State Transition Examples

```text
idle + PersonConfirmed
→ detected
```

```text
detected + BeginOrientation
→ rotating

rotating + RotationCompleted
→ recognizing
```

```text
rotating + OrientationFailed(originalDirection)
→ detected(originalDirection)
```

Phase 1.2 exposes this orientation flow as three explicit Simulator actions:
confirm presence, begin rotation, and confirm mock arrival. Center still issues
an absolute `rotate(to: 0°)` command and waits for the adapter to confirm
arrival. If rotation fails or is cancelled, the coordinator stops the hardware,
applies `OrientationFailed`, and returns to the original detected direction so
the operation can be retried.

```text
recognizing + KnownMember
→ greeting
```

```text
recognizing + Unknown
→ greeting
```

```text
greeting + VoiceSessionReady
→ speaking
```

```text
speaking + UserSpeechStarted
→ listening
```

```text
listening + UserSpeechEnded
→ thinking
```

```text
thinking + ResponseReady
→ speaking
```

`ToolCallRequested` is reserved for Phase 3 tool calling and is not the normal
Phase 1 transition into `thinking`. In Phase 1, `VoiceSessionPort.start` returns
only when ready and later lifecycle changes arrive through typed voice events
consumed only by `AssistantSessionCoordinator`.

```text
any active state + PersonLeft
→ EndSession action
→ HardwareControlPort.returnHome() action
→ idle
```

`EndSession` and `returnHome()` are orchestration actions and must not be added
as durable `AssistantState` cases.

Illegal transitions must be tested.

---

# 28. Clean Architecture

Lumi must follow Clean Architecture.

Dependency direction:

```text
UI
↓
Presentation
↓
Application
↓
Domain
```

Infrastructure implements Application ports.

The reusable `LumiUI` module depends on Presentation and SwiftUI only. It must
not import `LumiDomain`. The App composition layer may depend inward on Domain,
Application, Presentation, and UI to assemble the system.

Domain must not import:

- SwiftUI
- AVFoundation
- Vision
- Core ML
- OpenAI
- URLSession
- WebSocket
- GPIO

Refer to:

```text
docs/architecture.md
```

---

# 29. Recommended iOS Modules

```text
Sources/
├── LumiDomain/
├── LumiApplication/
├── LumiPresentation/
├── LumiInfrastructure/
└── LumiUI/
```

Responsibilities:

```text
LumiDomain
→ entities, value objects, policies

LumiApplication
→ use cases, ports, orchestration

LumiPresentation
→ UI state, Avatar mapping

LumiInfrastructure
→ OpenAI, Vision, API, WebSocket, persistence

LumiUI
→ SwiftUI rendering
```

---

# 30. Core Application Ports

Examples:

```swift
protocol MemberRepository
```

```swift
protocol VoiceSessionPort
```

```swift
protocol HardwareControlPort
```

```swift
protocol IdentityRecognitionPort
```

```swift
protocol PresenceEventPort
```

```swift
protocol TelemetryPort
```

All external effects must cross a Port.

---

# 31. Composition Root

Only the App Composition Root constructs concrete adapters.

Conceptually:

```text
CurvesLumiApp
├── CurvesMemberAPIRepository
├── OpenAIRealtimeAdapter
├── VisionCoreMLIdentityAdapter
├── EdgeWebSocketAdapter
├── TelemetryAdapter
├── Application Use Cases
├── AssistantSessionCoordinator
└── ViewModels
```

Do not use global service singletons as the default architecture.

---

# 32. TDD Requirement

All development must follow:

```text
RED
→ GREEN
→ REFACTOR
```

Rules:

1. New Use Case requires a failing test first.
2. Bug fix requires failing regression test first.
3. Domain Policy requires boundary tests.
4. State transitions require tests.
5. Adapter contracts require tests.
6. Refactor only with green tests.
7. Coverage percentage does not replace TDD.
8. Do not weaken tests simply to pass them.

---

# 33. Testing Layers

## Domain Tests

Must require no:

- iOS Simulator
- network
- OpenAI
- Vision
- Core ML
- hardware

Test:

- state reducer
- value objects
- policies
- confidence logic
- timeout logic
- privacy rules

## Application Tests

Use mock/fake Ports.

Test:

- Use Case orchestration
- coordinator behavior
- tool routing
- error mapping
- timeout
- known/unknown flows

## Infrastructure Tests

Test:

- API DTO mapping
- WebSocket protocol
- Vision mapping
- Core ML adapter
- member matching
- persistence
- OpenAI event mapping

## Presentation Tests

Test:

- AvatarStateMapper
- UI state
- error presentation
- waveform modes

---

# 34. Specification Clarification Protocol

If a product requirement is ambiguous and the choice affects:

- UX
- state transitions
- API contracts
- data model
- privacy
- member identity
- recognition threshold
- hardware behavior
- voice behavior
- cost
- safety
- acceptance criteria

Codex must:

```text
ASK
↓
STOP affected implementation
↓
WAIT for product decision
```

Question format:

1. explain uncertainty
2. explain impact
3. give 2–4 concrete options where possible
4. optionally recommend one
5. do not treat recommendation as decided

---

# 35. ADR Decision Records

Important decisions should be saved under:

```text
docs/decisions/
```

ADR structure:

```text
Context
Question
Decision
Alternatives
Reason
Impact
Date
```

Examples:

```text
ADR-0004-face-match-confidence-policy.md
ADR-identity-embedding-model.md
ADR-multi-face-target-selection.md
ADR-voice-session-timeout.md
```

---

# 36. Privacy

Face embeddings and member exercise information are sensitive.

Requirements:

- never log raw embeddings
- raw audio logging disabled by default
- raw face image logging disabled by default
- minimize data sent to LLM
- do not send face embeddings to LLM
- do not announce uncertain identities
- avoid speaking private metrics when multiple people are nearby
- unknown identity must not load private member context
- deletion/revocation of enrollment must be supported

Privacy policy is distinct from recognition confidence.

---

# 37. Safety and Scope

Lumi may:

- discuss a member's own exercise history
- give general exercise encouragement
- explain store process
- provide approved exercise goals
- remind about hydration or attendance

Lumi must not:

- diagnose disease
- prescribe medication
- replace physician advice
- claim medical treatment
- infer medical conditions from face
- infer sensitive traits from face
- make autonomous hardware decisions outside defined safety logic

---

# 38. Failure Behavior

## Camera Failure

```text
identity unavailable
→ generic greeting
```

## Recognition Failure

```text
unknown
→ generic greeting
```

## Member API Failure

```text
avoid fabricated member data
→ apologize briefly
→ continue generic interaction
```

## Realtime Failure

```text
fallback UI state
→ optional local/static message
```

## Hardware Failure

```text
stop unsafe movement
→ report error
→ UI remains usable where possible
```

A system failure must never cause Lumi to fabricate private member information.

---

# 39. Offline Behavior

Identity recognition should remain on-device where practical.

If network is unavailable:

- Avatar still runs
- presence may still work
- rotation may still work
- local identity may work if data is available
- Curves member API may be unavailable
- Realtime may be unavailable
- Lumi should fall back gracefully

Final offline capability must be explicitly defined before pilot.

---

# 40. Telemetry

Suggested events:

```text
presence_detected
rotation_started
rotation_completed
face_known
face_unknown
recognition_timeout
voice_session_started
voice_session_ended
tool_called
member_api_error
realtime_error
hardware_error
```

Suggested metrics:

- sessions/day
- average session duration
- known recognition rate
- unknown rate
- false-recognition validation rate
- tool latency
- realtime latency
- failed sessions
- rotations/day
- estimated cost/store/day

Do not log secrets or sensitive identity data.

---

# 41. Initial Development Roadmap

Current and planned sequence:

```text
Avatar M0        ✅ Domain / Presentation
Avatar M1        ✅ SwiftUI Visual Layer
Avatar M2        ✅ Continuous Animation / tuning
Avatar M3        ✅ Event & Expression Layer

Phase 1          ✅ Simulated Interaction MVP — Complete
Phase 2          ▶ OpenAI Realtime Voice — Next
Phase 3          Mock Member Data + Tool Calling

Milestone 2      Smart Rotation Base

Milestone 3      Vision + Core ML Identity Recognition

Milestone 4      Real Curves Member API

Milestone 5      Integrated Store MVP

Milestone 6      Pilot Store Hardening

Productization   ESP32 Smart Dock
```

Refer to:

```text
docs/roadmap.md
```

---

# 42. Phase 1 Definition of Done

The Simulator MVP must support:

```text
Simulate Visitor
↓
idle → detected → rotating → recognizing
↓
Mock known or unknown visitor
↓
greeting
↓
mock speaking → listening → thinking → speaking
↓
timeout
↓
EndSession + mock returnHome action
↓
idle
```

No physical Pi is required.

No real Vision is required.

No real Curves API is required.

Phase 1 defines `MemberRepository` as a mockable port but does not implement
member-specific questions or repository query behavior. Mock member questions,
member data responses, and tool calling belong to Phase 3.

Phase 1 identity and session behavior follows ADR-0006:

- `MemberID` is an exact non-empty string value; `RecognitionConfidence` is
  finite and within inclusive `0...1`; invalid values are rejected
- known and unknown both transition to `greeting`; unknown never exposes an
  internal reason, and Phase 1 performs no private member lookup
- Simulator identity and voice stages are explicit actions with no timer-driven
  advancement and Unknown selected by default
- recognition adapter errors degrade to unknown, while cancellation propagates;
  voice failures retain a retryable semantic state
- timeout and person-left share an end-session action that stops voice, stops
  active rotation, returns home, and enters idle only after confirmed arrival

---

# 43. Milestone 3 Definition of Done

Identity recognition is complete when:

- AVFoundation camera capture works
- Vision face detection works
- target selection is defined and tested
- face normalization is deterministic
- Core ML embedding model is selected/documented
- enrollment supports multiple samples/member
- matching supports multiple embeddings/member
- confidence policy is validated
- strangers safely become Unknown
- timeout falls back to generic greeting
- Vision/Core ML remain isolated in Infrastructure
- tests pass
- validation results are documented

---

# 44. Pilot Store Hardening

Before store pilot, add:

- kiosk mode
- app recovery
- watchdog
- hardware reconnect
- network reconnect
- telemetry
- cost monitoring
- privacy behavior
- recognition validation
- crash diagnostics
- update strategy

Operational success must be measured on real store hardware.

---

# 45. Product Evolution

Prototype:

```text
iPad:
Avatar + Voice + UI

Raspberry Pi:
Sensors + Motor
```

MVP:

```text
iPad:
UI + Voice + Curves Data

Raspberry Pi:
Sensors + Motor
```

V2:

```text
iPad:
UI + Voice + Vision + Identity + Data

Raspberry Pi:
Sensors + Motor
```

Product:

```text
Curves Cloud
↓
Curves Lumi iPad App
↓
ESP32 Smart Rotation Dock
```

---

# 46. Architecture Acceptance Questions

Before accepting a new subsystem, confirm:

1. Can it be mocked?
2. Does Domain remain framework-free?
3. Does Application depend only on Ports?
4. Does UI avoid direct API/hardware access?
5. Is there one AssistantState owner?
6. Can OpenAI be replaced without Domain changes?
7. Can Vision be replaced without Domain changes?
8. Can Pi become ESP32 without Domain changes?
9. Are product thresholds decision-backed?
10. Is the behavior testable before hardware integration?
11. Are errors safely mapped?
12. Does uncertain identity become Unknown?

Any `No` requires architecture review.

---

# 47. Non-Goals

Unless separately approved, Lumi does not include:

- payment processing
- medical diagnosis
- security-grade authentication
- legal identity verification
- age inference
- gender inference
- emotion inference
- health inference from face
- autonomous LLM motor control
- multi-person simultaneous conversations
- continuous 8-hour Realtime sessions

---

# 48. Related Documents

The following files form the current Lumi development baseline:

```text
SYSTEM_SPEC.md
docs/architecture.md
docs/roadmap.md
docs/identity-recognition.md
docs/decisions/ADR-0004-face-match-confidence-policy.md
docs/decisions/ADR-0005-development-scope-and-boundaries.md
docs/decisions/ADR-0006-phase-1-session-flow-contract.md
Curves_Lumi_Avatar_Visual_Spec.md
```

When documents conflict:

1. explicit product decision / latest ADR
2. `SYSTEM_SPEC.md`
3. `docs/architecture.md`
4. feature specification
5. implementation detail

If the conflict is materially ambiguous, ask the product owner.

---

# 49. Final Product Principle

Curves Lumi should feel like a responsive, warm digital member assistant rather than a machine waiting for commands.

The desired perception is:

> **她先發現我、看向我、轉過來、認出我、知道我的運動狀況，然後自然地和我說話。**

The technical architecture exists to support that experience safely, testably, and without coupling Lumi to any single AI, vision, network, or hardware technology.
