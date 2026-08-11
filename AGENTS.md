# Curves Lumi Development Instructions

Before implementing any feature:

1. Read SYSTEM_SPEC.md.
2. Read docs/architecture.md.
3. Read the relevant feature spec under docs/.
4. Read applicable ADRs under docs/decisions/.

## Commands

Run the Swift package tests:

```sh
swift test
```

Build the iOS app for the Simulator without code signing:

```sh
xcodebuild -project App/LumiApp.xcodeproj \
  -scheme LumiApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Before handing off a change, run both commands and report their results.

## Architecture

This project MUST follow Clean Architecture.

Dependency direction:

UI
→ Presentation
→ Application
→ Domain

Infrastructure implements Application ports.

Forbidden:
- Domain importing SwiftUI, Vision, CoreML, AVFoundation, OpenAI SDK or URLSession.
- LumiUI importing LumiDomain; Domain state and events must be mapped by LumiPresentation to Presentation-owned values such as `AvatarVisualState` and `AvatarEventCommand`.
- UI directly calling network, hardware, Vision or OpenAI.
- Global singleton services.
- LLM directly controlling motor hardware.

## TDD

All production behavior must be developed using RED → GREEN → REFACTOR.

Before production code:
1. Write a failing test.
2. Confirm the test fails for the expected reason.
3. Implement the minimum behavior.
4. Run the test suite.
5. Refactor only while tests remain green.

Bug fixes require a failing regression test first.

## Specification clarification

Never silently invent product behavior.

If a requirement is unclear and different interpretations would affect:
- UX
- state transitions
- API contracts
- privacy
- member data
- hardware behavior
- Vision behavior
- thresholds
- acceptance criteria

STOP the affected implementation and ask the user.

Give:
- the unresolved question
- 2–4 concrete options where possible
- the impact of each option
- a recommendation, clearly marked as not yet decided

Do not proceed until the user confirms.

## Identity Recognition

Identity recognition belongs to the Identity milestone.

Architecture:

Camera
→ AVFoundation Adapter
→ Vision face detection
→ normalized face crop
→ Core ML embedding
→ MemberMatcher
→ RecognitionConfidencePolicy
→ known(MemberID) / unknown

Vision/CoreML code must stay in Infrastructure.

Application only depends on:

IdentityRecognitionPort

Domain owns the internal policy types:

RecognitionDecision
UnknownReason
RecognitionResult
MemberID
Confidence

Application maps `RecognitionDecision.unknown(reason:)` to the public
`RecognitionResult.unknown` returned through `IdentityRecognitionPort`.
Presentation and UI must not receive or branch on `UnknownReason`.

Unknown is preferred over guessing the wrong member.

## Testing

Run all relevant tests before completing a task.

Domain tests must not require:
- iOS Simulator
- network
- Vision
- OpenAI
- Raspberry Pi

Every Use Case must have unit tests.
Every state transition must have tests.
