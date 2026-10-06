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

## Owner-approved greeting/reminder priority (2026-09-23)

The latest owner direction prioritizes greetings and reminders rather than
member chat. One relevant point, no routine answer obligation, no invitations
to small talk or topic expansion, and no thirty-second conversation target.
Necessary consent, naming, corrections and direct service replies remain.
See [the current feature specification](greeting-reminder-first.md) and
[ADR-0019](decisions/ADR-0019-greeting-reminder-first.md).
This changes prompt policy without changing tools, authorization or lifecycle.

## Natural-response baseline retained from 2026-09-06

The Realtime prompt catalog now guides Lumi toward a natural first response:

- Use 1–2 short, natural Taiwan Mandarin sentences by default. There is no
  rigid character ceiling; privacy, consent, safety, and other necessary
  explanations must remain complete.
- Respond to the visitor's latest utterance or situation before offering
  encouragement or a next step. Leave room for the visitor to answer.
- When a returning member has a voluntarily provided and confirmed
  `VoiceMemberAddress.spokenLabel`, Lumi may use that label naturally and
  sparingly. Without a validated label, use a generic welcome-back meaning.
  Visitor contexts use a generic greeting and do not invent names or intimate
  titles.
- Avoid repeating an opening greeting or address. Opening tool calls remain
  forbidden, existing on-demand tool authorization is unchanged, and the
  enrollment disclosure, consent gate, capture count, and naming order remain
  unchanged. No title preference is stored.

This is prompt policy rather than a deterministic output guarantee. The
manual conversational acceptance examples are recorded in
`docs/decisions/ADR-0014-natural-conversation-prompts.md` and remain pending
physical Debug-Live validation.

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
  while preserving privacy, consent, and natural context-first wording.

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
- OpenAI response wording is editable from one Swift file; returning-member and
  visitor prompts use a natural generic or confirmed-label address, acknowledge
  the latest utterance before encouragement, and allow complete necessary
  explanations while existing session behavior, consent, privacy, model, and
  voice remain unchanged.
