# Transient Face Recovery and Conversation Prompt Catalog

## Objective

Improve the Debug-Live continuous visitor experience in two focused ways:

1. A frame-level Vision/YuNet/alignment/SFace processing failure during
   presence observation behaves like one temporarily unusable face frame and
   the monitor waits for a newer frame instead of showing the automatic
   recognition retry dialog.
2. OpenAI Realtime response wording is centralized in
   `OpenAIConversationPrompts.swift` so product copy can be edited without
   searching through configuration and adapter control flow.

## Commands

- Focused package tests:
  `swift test --filter 'CoreMLIdentityCalibrationServiceTests|OpenAIRealtimeConfigurationTests|OpenAIRealtimeAdapterTests'`
- Full package tests: `swift test`
- Simulator build:
  `xcodebuild -project App/LumiApp.xcodeproj -scheme LumiApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

## Project Structure

- Presence recovery stays in
  `Sources/LumiInfrastructure/Identity/Calibration/CoreMLIdentityCalibrationService.swift`.
- Conversation copy lives in
  `Sources/LumiInfrastructure/Voice/OpenAIConversationPrompts.swift`.
- Realtime configuration and adapter code select and compose prompt catalog
  values; they do not contain editable Traditional Chinese response copy.
- Tests remain in the existing Infrastructure test suites.

## Code Style

Prompt text uses named multiline Swift strings so Traditional Chinese remains
readable and compile-time checked:

```swift
static let anonymousVisitorGreeting = """
這位訪客沒有已確認的會員身分。請使用不包含私人資料的一般問候。
"""
```

## Testing Strategy

- RED first: prove a presence-only frame-pipeline failure currently escapes as
  `IdentityCalibrationError.failed`.
- GREEN: the same failure returns `false`; a later fresh frame may return
  `true` without restarting the camera.
- Preserve tests proving generic frame-source failures and cancellation remain
  errors.
- Assert configuration and all context/direction prompt paths use the catalog
  while preserving privacy and consent wording.

## Boundaries

- Always preserve `CancellationError` and payload-free diagnostics.
- Always keep camera startup and frame-stream failures visible as operation
  failures.
- Always keep enrollment, return-visit calibration, and identity recognition
  fail-closed on pipeline errors.
- Never send an image, embedding, confidence, raw member ID, or framework error
  through OpenAI instructions.
- Never move OpenAI tool schemas or authorization rules into editable copy.
- Never change recognition confidence thresholds in this feature.

## Success Criteria

- Moving out of frame or one failed frame-processing attempt does not end the
  presence loop or show the automatic-recognition error dialog.
- A subsequent usable frame can complete arrival/departure observation.
- A broken camera lease or ended stream still reaches the existing generic
  retry UI.
- OpenAI response wording is editable from one Swift file and existing session
  behavior, consent, privacy, model, and voice remain unchanged.

