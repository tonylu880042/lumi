# Curves Lumi — System Architecture

> File: `docs/architecture.md`
> Status: Active Architecture Baseline
> Last updated: 2026-08-10
> Applies to: iPad App, Identity Recognition, Realtime Voice, Member Data, Smart Rotation Base
> Principles: Clean Architecture + TDD + Ask-if-Unclear

---

# 1. Purpose

This document defines the authoritative technical architecture for **Curves Lumi**.

Lumi is an iPad-based AI welcome and member interaction assistant for Curves stores. It combines:

- animated SwiftUI avatar
- visitor presence detection
- smart rotating dock
- member identity recognition
- Curves member/exercise data
- OpenAI Realtime voice interaction
- privacy-aware personalized greeting
- store operation telemetry

This document defines:

- architectural layers
- dependency rules
- module boundaries
- ports and adapters
- state ownership
- subsystem integration
- data flow
- error boundaries
- testing expectations
- prohibited coupling

Detailed feature behavior belongs in feature specifications and ADRs.

---

# 2. Architecture Goals

The architecture must support the following without major redesign:

1. Run a complete simulated MVP without hardware.
2. Replace Raspberry Pi with ESP32 later.
3. Replace mock member data with the real Curves API.
4. Add Vision/Core ML identity recognition without changing Domain/Application.
5. Replace OpenAI Realtime with another provider if needed.
6. Keep Avatar UI independent from network, hardware, and AI SDKs.
7. Allow deterministic TDD at Domain/Application level.
8. Avoid global singleton-driven architecture.
9. Keep product rules separate from framework implementation.
10. Make ambiguous requirements visible instead of silently assumed.

---

# 3. Clean Architecture

Lumi follows Clean Architecture.

Dependency direction is inward only:

```text
┌─────────────────────────────────────────────┐
│ Frameworks / Drivers                        │
│ SwiftUI / AVFoundation / Vision / Core ML   │
│ OpenAI / URLSession / WebSocket / GPIO      │
└──────────────────────┬──────────────────────┘
                       │ implements
┌──────────────────────▼──────────────────────┐
│ Interface Adapters / Infrastructure         │
│ API Repositories / SDK Adapters / Mappers   │
│ Hardware Gateways / Vision Adapters         │
└──────────────────────┬──────────────────────┘
                       │ depends on
┌──────────────────────▼──────────────────────┐
│ Application                                 │
│ Use Cases / Ports / Coordinators            │
└──────────────────────┬──────────────────────┘
                       │ depends on
┌──────────────────────▼──────────────────────┐
│ Domain                                      │
│ Entities / Value Objects / Policies         │
│ Domain Events / Domain Errors               │
└─────────────────────────────────────────────┘
```

## 3.1 Dependency Rule

Inner layers must never import outer-layer frameworks.

### Domain must not import

- SwiftUI
- UIKit
- AVFoundation
- Vision
- Core ML
- OpenAI SDK
- URLSession
- WebSocket frameworks
- GPIO libraries
- persistence frameworks

### Application may depend on

- Domain
- Port protocols
- application DTOs
- orchestration logic

Application must not depend on concrete SDKs.

### Infrastructure may depend on

- Application ports
- Domain value objects as needed
- Apple frameworks
- OpenAI APIs
- Curves APIs
- hardware/network frameworks

### UI may depend on

- Presentation
- app-level composition
- SwiftUI

UI must not directly call APIs, Vision, Realtime, or motor control.

The reusable `LumiUI` package must not import or depend directly on
`LumiDomain`. Domain state and events are mapped to Presentation models or
commands before reaching UI. The App composition layer may depend inward on all
required modules to assemble concrete dependencies.

---

# 4. Repository Architecture

Recommended structure:

```text
lumi/
├── AGENTS.md
├── SYSTEM_SPEC.md
├── README.md
├── docs/
│   ├── architecture.md
│   ├── roadmap.md
│   ├── identity-recognition.md
│   ├── testing-strategy.md
│   └── decisions/
│       └── ADR-*.md
│
├── App/
│   └── LumiApp.xcodeproj
│
├── Sources/
│   ├── LumiDomain/
│   │   ├── Entities/
│   │   ├── ValueObjects/
│   │   ├── Events/
│   │   ├── Policies/
│   │   └── Errors/
│   │
│   ├── LumiApplication/
│   │   ├── UseCases/
│   │   ├── Ports/
│   │   │   ├── Input/
│   │   │   └── Output/
│   │   ├── Coordinators/
│   │   ├── DTO/
│   │   └── Errors/
│   │
│   ├── LumiPresentation/
│   │   ├── ViewModels/
│   │   ├── Presenters/
│   │   ├── UIState/
│   │   ├── Avatar/
│   │   └── Mappers/
│   │
│   ├── LumiInfrastructure/
│   │   ├── Identity/
│   │   ├── Voice/
│   │   ├── MemberAPI/
│   │   ├── Hardware/
│   │   ├── Persistence/
│   │   ├── Networking/
│   │   └── Telemetry/
│   │
│   └── LumiUI/
│       ├── Screens/
│       ├── Avatar/
│       ├── Components/
│       └── Theme/
│
├── Tests/
│   ├── LumiDomainTests/
│   ├── LumiApplicationTests/
│   ├── LumiPresentationTests/
│   ├── LumiInfrastructureTests/
│   └── LumiUITests/
│
├── edge/
│   ├── domain/
│   ├── application/
│   ├── adapters/
│   ├── infrastructure/
│   └── tests/
│
├── protocol/
│   └── v1/
│       ├── messages.schema.json
│       └── examples/
│
└── config/
    ├── app.example.yaml
    └── edge.example.yaml
```

The exact folder structure may evolve, but dependency boundaries must remain.

---

# 5. Domain Layer

The Domain layer contains product meaning, not implementation details.

Typical Domain types include the Phase 1 target state model:

```swift
struct MemberID: Hashable {
    let rawValue: String
}
```

```swift
struct Member: Equatable {
    let id: MemberID
    let displayName: String
}
```

```swift
struct ExerciseSummary: Equatable {
    let visitsThisWeek: Int
    let activityMETMinutes: Double?
    let lastWorkoutAt: Date?
    let todayCompleted: Bool
}
```

```swift
enum VisitorIdentity: Equatable {
    case known(MemberID)
    case unknown
}
```

```swift
enum AssistantState: Equatable {
    case idle
    case detected(Direction)
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

Phase 1.1 adds `.rotating` together with the deterministic State Reducer, mock
hardware port, tests, and an explicit Avatar mapping. `ending` and `returnHome`
are Application actions, not Domain state cases.

## 5.1 Domain Policies

Examples:

```text
PresenceConfirmationPolicy
RecognitionConfidencePolicy
ConversationPrivacyPolicy
GreetingPolicy
RotationSafetyPolicy
SessionTimeoutPolicy
```

Domain policies should be deterministic and independently unit-testable.

---

# 6. Application Layer

The Application layer orchestrates product behavior.

It defines:

- Use Cases
- outbound Ports
- application-level coordinators
- state transition orchestration
- error translation
- tool routing

## 6.1 Core Use Cases

Initial use cases include:

```text
HandlePresenceDetectedUseCase
AlignDeviceToVisitorUseCase
RecognizeVisitorUseCase
LoadMemberContextUseCase
GenerateGreetingContextUseCase
StartVoiceSessionUseCase
HandleMemberQuestionUseCase
EndVoiceSessionUseCase
ReturnDeviceHomeUseCase
HandleConversationTimeoutUseCase
```

Each use case must have tests.

## 6.2 Ports

Application defines abstractions for side effects.

### Member data

```swift
protocol MemberRepository {
    func profile(for id: MemberID) async throws -> Member
    func weeklySummary(for id: MemberID) async throws -> ExerciseSummary
}
```

### Identity

```swift
protocol IdentityRecognitionPort: Sendable {
    func recognizeCurrentVisitor() async throws -> RecognitionResult
}
```

`MemberID` preserves an exact non-empty string. `RecognitionConfidence`
rejects non-finite values and values outside inclusive `0...1` rather than
clamping them. The public result is known identity plus confidence, or unknown
without a policy reason; adapter-specific and confidence-policy details do not
cross this port.

### Voice

```swift
protocol VoiceSessionPort: Sendable {
    func start(context: VoiceContext) async throws
    func eventUpdates() async -> AsyncStream<VoiceSessionEvent>
    func stop() async
}
```

In Phase 1, `start(context:)` completes only when the voice session is ready.
The coordinator is the sole consumer of typed `userSpeechStarted`,
`userSpeechEnded`, `responseReady`, and payload-free `failure` events. A
failure leaves the semantic state unchanged so its legal action can be retried.
`VoiceContext` distinguishes only a returning member from a generic visitor;
it carries no member identity, confidence, or private profile data. `ToolResult`
and `sendToolResult(_:)` are introduced with Phase 3 tool calling, not ordinary
conversation.

### Hardware

```swift
protocol HardwareControlPort: Sendable {
    func rotate(to angle: RotationAngle) async throws
    func returnHome() async throws
    func stop() async
}
```

`RotationAngle` is a Domain value that rejects non-finite values and degrees
outside the inclusive `-90...90` safety range. The async `rotate(to:)` and
`returnHome()` operations return only after the adapter confirms arrival at the
requested target; command acceptance alone is not completion. Phase 1's mock
provides explicit arrival and failure controls for deterministic tests.

### Presence events

```swift
protocol PresenceEventPort {
    var events: AsyncStream<PresenceEvent> { get }
}
```

### Telemetry

```swift
protocol TelemetryPort {
    func record(_ event: TelemetryEvent)
}
```

Application must know only these abstractions.

---

# 7. Session State Ownership

Lumi must have a **single source of truth** for active interaction state.

Recommended owner:

```text
AssistantSessionCoordinator
```

The Coordinator receives Domain/Application events and drives deterministic transitions.

```text
Hardware Event
↓
Application Event
↓
AssistantSessionCoordinator
↓
State Reducer
↓
AssistantState
↓
Presentation
```

Examples:

```text
idle
+ PersonConfirmed
→ detected
```

```text
detected
+ BeginOrientation
→ rotating
```

```text
rotating
+ RotationCompleted
→ recognizing
```

```text
rotating
+ OrientationFailed(originalDirection)
→ detected(originalDirection)
```

Phase 1.2 keeps the public interaction staged: presence confirmation first,
orientation start second, and explicit mock arrival third. Left, center, and
right map to absolute `-90°`, `0°`, and `+90°` targets. All three commands cross
`HardwareControlPort` and complete only on confirmed arrival.

The coordinator is an actor and the sole owner of `AssistantState`. It exposes
read-only state updates for Presentation/App observers. A hardware failure or
caller cancellation causes `stop()` before the reducer restores the original
`detected(direction:)`; stale completions must not advance to `recognizing`.

```text
recognizing
+ KnownMember
→ greeting
```

```text
recognizing
+ Unknown
→ greeting
```

Known and unknown results both enter `greeting`. The Application session
context may retain a known `MemberID`, but Phase 1 does not query member data;
unknown never carries an internal policy reason across the port.

```text
greeting
+ VoiceSessionReady
→ speaking
```

```text
speaking
+ UserSpeechStarted
→ listening
```

```text
listening
+ UserSpeechEnded
→ thinking
```

```text
thinking
+ ResponseReady
→ speaking
```

```text
any active state
+ PersonLeft
→ EndSession action
→ VoiceSessionPort.stop() action
→ HardwareControlPort.stop() when rotating
→ HardwareControlPort.returnHome() action
→ idle
```

Timeout uses the same end-session action. Idle is published only after the
return-home operation succeeds; failures preserve the current semantic state
and allow retry. Operation ownership must prevent stale asynchronous
completions from advancing state after shutdown.

Illegal transitions must be rejected or safely ignored and logged.

No subsystem may maintain a competing product state.

---

# 8. Presentation Layer

Presentation converts product state into renderable state.

Example:

```text
AssistantState
↓
AvatarStateMapper
↓
AvatarVisualState
↓
SwiftUI
```

Presentation is also responsible for:

- screen-level UI state
- message text presentation
- visual error state
- Avatar expression mapping
- waveform presentation state

Example:

```swift
struct AssistantUIState: Equatable {
    let avatar: AvatarVisualState
    let message: String?
    let waveformVisible: Bool
    let interactionEnabled: Bool
}
```

`AssistantUIState` must contain Presentation-owned values only. Domain state is
an input to the Presentation mapper, not part of the public `LumiUI` contract.

UI must not derive complex business state using many Boolean flags.

---

# 9. Lumi Avatar Architecture

The Avatar is a Presentation/UI concern.

Core rule:

> Domain defines what Lumi is doing. Presentation defines how Lumi looks.

Flow:

```text
AssistantState → AvatarStateMapper → Base AvatarVisualState
AssistantEvent → AvatarEventCommandMapper → AvatarEventCommand

Base AvatarVisualState + Continuous modifiers + AvatarEventCommand
↓
Event Animation Layer
↓
Accessibility Layer
↓
LumiAvatarView
```

Animation layers:

1. State animation
2. Continuous animation
3. Event animation
4. Accessibility overrides

`encouraging` and `confused` remain semantic States. Short sparkle, question,
retry, recognition, and celebration feedback belongs to the Event layer and
must not create duplicate Domain event cases.

Reduced Motion preserves Event meaning with a static symbol or short opacity
transition while removing large translation, bounce, rotation, and looping
particle motion.

`AvatarEventCommand` is the Presentation-owned, exhaustive one-to-one mapping
of the current Domain `AssistantEvent` cases. `LumiUI` consumes the command and
must not expose `AssistantEvent` in a public initializer, property, or binding.
Presentation owns Event replacement, cancellation, and expiry through the
`AvatarEventPlayback` value. It stores at most one active Event: newest replaces
current, no queue or stack is created, cancel clears it, and expiry reveals the
latest base State. The Event envelope is carried by the clamped
`AvatarVisualState.effectIntensity`; UI applies it only to the Event/state effect
decoration, independently from ambient `sparkleIntensity`.

State changes consume the destination `AvatarTransition` only at
`AnimatedLumiAvatarView`; child views do not choose their own transition. Raw
mock audio amplitude is smoothed with the Presentation-owned
`AmplitudeProcessor`, reduced to one output per batch, and clamped before the
compositor routes that single value to the waveform and, for speaking only, the
mouth opening. Reduced Motion keeps the waveform mode but suppresses its
amplitude-driven motion.

Avatar logic must not know:
- member API
- OpenAI
- Vision
- GPIO
- WebSocket

---

# 10. Identity Recognition Architecture

Identity recognition is an Infrastructure capability behind `IdentityRecognitionPort`.

Full flow:

```text
AVFoundation Camera
↓
Vision Face Detection
↓
Active Face Target Selection
↓
Face Normalization
↓
Core ML Face Embedding
↓
Member Matcher
↓
RecognitionConfidencePolicy
↓
RecognitionResult
```

Only the semantic result crosses inward:

```text
known(MemberID)
unknown
```

The confidence policy may use an internal `RecognitionDecision` with
`unknown(reason:)`. Application maps that decision to the public
`RecognitionResult` before returning through `IdentityRecognitionPort`; UI does
not receive the low-level reason.

Vision/Core ML types stay inside Infrastructure.

Refer to:

```text
docs/identity-recognition.md
docs/decisions/ADR-0004-face-match-confidence-policy.md
```

---

# 11. Voice Architecture

Voice is provided through a provider-independent Application port.

```text
Application
↓
VoiceSessionPort
↑
OpenAIRealtimeAdapter
```

Responsibilities of `OpenAIRealtimeAdapter`:

- establish Realtime session
- audio input/output
- session events
- tool call transport
- interruption handling
- reconnect/error mapping

Responsibilities it must not own:

- member business logic
- hardware control
- recognition policy
- application state ownership

## 11.1 Realtime Session Activation

Voice sessions are event-triggered.

```text
No person
→ no active Realtime session

Person confirmed
→ identity/greeting flow
→ open Realtime session

Person leaves / idle timeout
→ close session
```

Do not keep the Realtime session open for all store operating hours.

---

# 12. Tool Calling Architecture

LLM tool calls must enter Application through controlled Use Cases.

Incorrect:

```text
LLM
→ direct REST call
```

Incorrect:

```text
LLM
→ motor command
```

Correct:

```text
OpenAIRealtimeAdapter
↓
ToolCall
↓
ToolRouter
↓
Application Use Case
↓
Port
↓
Infrastructure Adapter
```

Example:

```text
get_member_weekly_summary
↓
HandleMemberQuestionUseCase
↓
MemberRepository
↓
CurvesMemberAPIRepository
```

This ensures:

- authorization checks
- privacy policy
- deterministic logging
- testability
- no uncontrolled side effects

---

# 13. Member Data Architecture

Member data is accessed through `MemberRepository`.

Phase 1:

```text
MockMemberRepository
```

Production:

```text
CurvesMemberAPIRepository
```

Flow:

```text
Application
↓
MemberRepository
↑
Curves API Adapter
```

Member API DTOs must be mapped before entering Domain.

Do not expose API response structs to Domain.

---

# 14. Hardware Architecture

The physical dock is treated as an external device.

iPad communicates through a versioned protocol.

```text
iPad App
↕
WebSocket / LAN
↕
Rotation Controller
```

Prototype:

```text
Raspberry Pi
```

Productization target:

```text
ESP32
```

The iPad Application should not change when the controller implementation changes.

## 14.1 Hardware Responsibilities

Edge controller owns:

- ultrasonic sampling
- debounce
- coarse direction
- stepper control
- homing
- angle limits
- local motor safety
- watchdog
- connection status

iPad owns:

- product session state
- active target intent
- recognition
- member interaction
- voice
- UI

---

# 15. Edge Controller Architecture

The edge code should also follow Clean Architecture.

```text
edge/
├── domain/
│   ├── models/
│   ├── policies/
│   └── state_machine/
├── application/
│   ├── use_cases/
│   └── ports/
├── adapters/
│   ├── ultrasonic/
│   ├── stepper/
│   ├── home_sensor/
│   └── websocket/
├── infrastructure/
│   └── gpio/
└── main
```

Example ports:

```python
class DistanceSensorPort(Protocol):
    def read_cm(self, position: SensorPosition) -> float: ...
```

```python
class MotorPort(Protocol):
    def goto_angle(self, angle: float) -> None: ...
```

Domain/Application must not directly import GPIO libraries.

---

# 16. iPad ↔ Edge Protocol

Cross-process contracts are versioned.

Do not share internal class models.

Use:

```text
protocol/v1/messages.schema.json
```

Every message should include:

```json
{
  "protocol_version": 1,
  "message_id": "uuid",
  "type": "presence.detected",
  "timestamp": "2026-08-09T11:30:00+08:00",
  "payload": {}
}
```

Example Edge → iPad:

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

Example iPad → Edge:

```json
{
  "protocol_version": 1,
  "message_id": "uuid",
  "type": "rotation.goto",
  "timestamp": "2026-08-09T11:30:01+08:00",
  "payload": {
    "angle_deg": -45
  }
}
```

Breaking protocol changes require a protocol version change.

---

# 17. Composition Root

Only the App Composition Root creates concrete dependencies.

Conceptually:

```text
LumiApp
├─ Mock / Real MemberRepository
├─ Mock / Vision IdentityRecognitionPort
├─ Mock / OpenAI VoiceSessionPort
├─ Mock / Edge HardwareControlPort
├─ Telemetry Adapter
├─ Use Cases
├─ AssistantSessionCoordinator
└─ ViewModels
```

Avoid:

```swift
OpenAIRealtimeAdapter.shared
MemberAPI.shared
HardwareManager.shared
VisionManager.shared
```

Global singletons are prohibited as the default dependency management pattern.

---

# 18. Configuration Architecture

Product behavior values should not be scattered as magic numbers.

Examples:

```yaml
assistant:
  language: zh-TW
  personality: lively_caring

voice:
  provider: openai
  model: ${OPENAI_REALTIME_MODEL}
  idle_timeout_sec: 20

hardware:
  rotation_min_deg: -90
  rotation_max_deg: 90
  return_home_timeout_sec: 30

identity:
  confidence_policy_version: 1
  accept_threshold: TBD
  minimum_margin: TBD

privacy:
  speak_member_metrics_when_multiple_people_detected: false
```

Final product thresholds must come from approved decisions or validation, not developer guesses.

---

# 19. Error Architecture

Errors must not leak framework types across architectural boundaries.

Categories:

```text
DomainError
ApplicationError
InfrastructureError
PresentationError
```

Incorrect:

```text
URLError
→ Domain
```

Correct:

```text
URLSession Error
↓
CurvesMemberAPIRepository
↓ map
MemberRepositoryError
↓
Application
```

User-facing messages are decided by Presentation/Application policy, not SDK error strings.

---

# 20. Privacy Architecture

Privacy decisions are separate from identity confidence.

Example:

```text
RecognitionResult
↓
known(MemberID)

AND

ConversationPrivacyPolicy
↓
private data allowed?
```

Rules:

- do not send face embeddings to LLM
- do not log raw face embeddings
- minimize member data sent to voice provider
- avoid speaking private exercise metrics in ambiguous multi-person scenarios
- unknown identity must not load private member context
- member identity and exercise data access must remain separable

---

# 21. Telemetry Architecture

Telemetry enters through a port:

```swift
protocol TelemetryPort {
    func record(_ event: TelemetryEvent)
}
```

Suggested events:

```text
presence_detected
rotation_started
rotation_completed
identity_known
identity_unknown
voice_session_started
voice_session_ended
tool_called
member_api_error
hardware_error
recognition_timeout
```

Do not log:

- raw audio by default
- raw face images by default
- embeddings
- secrets
- full member profiles

---

# 22. TDD Architecture Rules

All architecture-critical behavior must be test-first.

## Domain Tests

Must run without:
- Simulator
- Network
- Vision
- Core ML
- OpenAI
- hardware

Test:
- state reducer
- policies
- value objects
- confidence logic
- privacy logic

## Application Tests

Use mock ports.

Test:
- Use Case orchestration
- session coordinator
- timeout behavior
- tool routing
- failure handling

## Infrastructure Tests

Test:
- DTO mapping
- protocol decoding
- Vision mapping
- Core ML adapter input/output
- WebSocket contract
- API translation

## Presentation Tests

Test:
- state mapping
- AvatarVisualState
- ViewModel outputs
- error presentation

## UI Tests

Only high-value end-to-end screen behavior.

---

# 23. Architecture Guardrails for Codex

Codex must obey:

- Domain has zero external framework dependencies.
- Application has zero concrete SDK dependencies.
- UI cannot call network/hardware/AI directly.
- Every side effect crosses a Port.
- Every external system is behind an Adapter.
- Composition Root creates concrete dependencies.
- No global service singleton by default.
- LLM tools cannot directly control hardware.
- OpenAI response types cannot enter Domain.
- Vision/Core ML types cannot enter Domain/Application.
- GPIO types cannot enter Application.
- API DTOs cannot become Domain models.
- AssistantSessionCoordinator is the single active session state owner.
- State transitions must be tested.
- New Use Cases must be TDD.
- If product behavior is unclear, stop and ask.

---

# 24. Architecture Acceptance Checklist

A feature is architecturally acceptable only if the following answers are **Yes**:

1. Can OpenAI be replaced by a mock without changing Domain/Application?
2. Can Raspberry Pi be removed and replaced with MockHardware?
3. Can Curves API be unavailable while MockMemberRepository runs?
4. Can identity recognition be mocked without Vision?
5. Do Domain tests run without iOS Simulator?
6. Does UI avoid direct URLSession/WebSocket/OpenAI usage?
7. Is Vision/Core ML isolated in Infrastructure?
8. Is GPIO isolated in Edge Infrastructure?
9. Is there one session-state owner?
10. Do tool calls enter through Application Use Cases?
11. Can Raspberry Pi become ESP32 without Domain changes?
12. Are thresholds configurable and decision-backed?
13. Are errors translated at boundaries?
14. Are new behaviors covered by tests?

Any `No` requires architectural review.

---

# 25. System Data Flow

End-to-end target:

```text
Ultrasonic Sensor
↓
Edge Presence Event
↓
PresenceEventPort
↓
HandlePresenceDetectedUseCase
↓
AssistantSessionCoordinator
↓
detected
↓
HardwareControlPort.rotate()
↓
rotation completed
↓
recognizing
↓
IdentityRecognitionPort
↓
known(MemberID) / unknown
↓
LoadMemberContextUseCase
↓
MemberRepository
↓
Greeting Context
↓
VoiceSessionPort
↓
Realtime Conversation
↓
Tool Call
↓
Application Use Case
↓
MemberRepository
↓
Tool Result
↓
Voice Response
↓
Person leaves / timeout
↓
EndVoiceSessionUseCase
↓
HardwareControlPort.returnHome()
↓
idle
```

---

# 26. Evolution Strategy

## Prototype

```text
iPad:
UI + Avatar + Realtime

Raspberry Pi:
Sensors + Motor + optional face prototype
```

## MVP

```text
iPad:
UI + Voice + Member Data + Application

Raspberry Pi:
Sensors + Motor
```

## V2

```text
iPad:
UI + Voice + Vision/Core ML Identity + Member Data

Raspberry Pi:
Sensors + Motor
```

## Product

```text
Curves Cloud
↓
Curves Lumi iPad App
↓
ESP32 Smart Rotation Dock
```

The architecture is considered successful if this evolution can occur without rewriting the Domain/Application core.

---

# 27. Related Documents

Read together with:

```text
SYSTEM_SPEC.md
docs/roadmap.md
docs/identity-recognition.md
docs/decisions/ADR-0004-face-match-confidence-policy.md
docs/decisions/ADR-0005-development-scope-and-boundaries.md
docs/decisions/ADR-0006-phase-1-session-flow-contract.md
Curves_Lumi_Avatar_Visual_Spec.md
```

Future architecture-changing decisions must be recorded under:

```text
docs/decisions/
```

---

# 28. Final Architecture Principle

The Lumi architecture should optimize for long-term replaceability of external technology while preserving stable product behavior.

In practical terms:

> **SwiftUI can change. Vision can change. OpenAI can change. Raspberry Pi can become ESP32. Curves APIs can evolve. The Domain and Application rules should remain stable.**
