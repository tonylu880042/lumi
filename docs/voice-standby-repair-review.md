# Voice standby repair review

Status: Implementation and independent review in progress.

## Review matrix

| Defect | Required evidence |
| --- | --- |
| Failed prewarm leaves start waiting | Controlled credential/connect failure, retry and start-during-prewarm coverage |
| Standby transmits audio / responds | Disabled track before attachment; ignored speech/commit/tool/output events; explicit activation |
| Promoted connection loses recovery | One reconnect with active context/tools; no greeting replay; one terminal failure |
| Lifecycle regressions | Stop during preparation/activation, stale callbacks, idempotent close, existing startup paths |

## Verification boundaries

Deterministic package tests and an unsigned Simulator build are required.
They do not prove physical microphone capture, speaker routing, or real-provider
behavior. No physical-device deployment is part of this repair.

Final commands, outcomes, RED evidence, and review disposition will be recorded
after implementation and independent verification.

## Implementation evidence received

- A: `swift test --filter failedStandbyPrewarmIsRetryable` failed at `retried`
  before cleanup repair and passed afterward.
- B: `swift test --filter standbyDoesNotRequestMicrophoneOrAnswerInputBeforeActivation`
  failed on microphone permission/audio activation counts before media repair
  and passed afterward. Deterministic event-drain coverage remains a review gate.
- C: `swift test --filter promotedStandbyReconnectsWithActiveConfiguration`
  failed at `reconnected` before retry repair and passed afterward.

## Review follow-ups sent to implementer

- Settle start joining a failing in-flight standby operation.
- Enforce media controls on every conformer, without no-op protocol defaults.
- Use WebRTC manual audio mode before standby peer creation.
- Preserve generation ownership through promotion and stop races.
- Reject duplicate starts during promotion.
- Preserve greeting output lifecycle events emitted before activation returns.
- Balance successful system audio activation when cancellation follows it.
