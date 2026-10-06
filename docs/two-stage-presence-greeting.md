# Two-stage presence and personal greeting

> Updated: 2026-09-30
> Product interaction choices accepted by owner on 2026-09-30; numerical Vision gates and the deliberate blink rule still require confirmation/calibration.
> Related: [ADR-0020](decisions/ADR-0020-two-stage-presence-greeting.md), [identity profile](identity-performance-profile.md), [roadmap](roadmap.md).

## Goal

Lumi may notice a single face before the face is suitable for identity recognition. It only uses a member's name and gives member-specific reminders after the person is close enough **and** the existing identity policy returns a reliable `known(MemberID)` result. A distant or uncertain face must never receive a guessed name or personal reminder. Lumi remains a greeting/reminder assistant, not a chat initiator.

This is an accepted interaction direction, **not an enabled trigger rule**. The current Live loop still waits for one fully usable face, then starts orientation, recognition and voice. No distance cutoff, new greeting, deliberate camera-triggered blink or timeout is enabled yet.

## Confirmed interaction rules

- At the distant notice, say one generic 「你好」 without a name or personal facts. This is one greeting attempt for the accepted visit, not a greeting on every frame.
- Use the detected face's size in the camera frame to decide whether the person has approached. A recognized identity alone is insufficient to claim the person is near. The numeric face-size cutoff and jitter/hysteresis rule require Live measurement before activation.
- If the person never approaches, do not add further speech or a goodbye. The first 「你好」 is the only speech in that case; the existing absence/rearm behavior remains the starting point for reset design.
- If the person's face is directed toward the camera, Lumi may blink in response. The Avatar already has a timed natural two-eye blink independent of camera input. A deliberate response would require a separate face-facing signal and event; it is not yet implemented or defined as a wink.
- Name and personal reminders remain gated by both approved approach evidence and the existing reliable `known(MemberID)` recognition decision.
- When a known member approaches, the near-stage interaction may say the confirmed name and one authorized, available reminder without repeating the distant 「你好」. Unknown visitors retain the necessary existing introduction/consent path; it must avoid repeating the distant greeting or implying they were recognized.

## Existing behavior and implementation seam

- `PilotVisitorPresenceMonitor.waitForVisitor()` returns after `captureUsableFace()` succeeds. That probe currently runs the Vision → YuNet → alignment → SFace embedding pipeline. It yields only a Boolean, not face geometry.
- `SessionSimulationModel` then records arrival vitality, confirms presence, orients, obtains three fresh recognition observations and starts voice. Existing `RecognitionConfidencePolicy` decides known/unknown; unknown is safer than an incorrect identity.
- The presence boundary carries no identity, frame, image or confidence. The new geometric observation, if approved, must be measured in Infrastructure and exposed through a minimal provider-neutral Application contract. Domain can own a pure near/stable policy; Presentation maps any noticed visual state to UI-owned values. UI cannot handle Vision or decide identity.
- The current three-observation identity policy, confidence thresholds, single-face fail-closed behavior, departure latch and three-second continuous absence remain in force until independently changed and tested.

## Candidate staged flow (pending trigger choices)

1. **Notice:** detector sees exactly one face and Lumi says 「你好」 once without personal content. If reliable face-facing evidence is available, it may also perform the separately specified blink. This stage must not load the gallery, bind a member, start a personal reminder, or claim recognition.
2. **Approach:** use calibrated camera-frame face size. A face disappearing, multiple faces or an unusable observation must not silently become a known member. The exact size, observation count, hysteresis and reset behavior need a recorded decision after Live measurement.
3. **Identify:** invoke existing `IdentityRecognitionPort` only at the approved approach gate. `known` may then enable the confirmed name and authorized personal reminders. `unknown` leads only to an approved generic interaction. Do not translate unknown into “too far away.”
4. **Leave/reset:** keep one distant 「你好」 per accepted visit. A visitor who never approaches receives no more speech. Retain the existing continuous-absence departure contract unless explicitly revised. The first greeting must not cause repeated welcoming while the same face remains present.

## Field measurements before setting a threshold

Use consented participants and the actual Live iPhone/iPad mounting position. For several standing positions and lighting conditions, log device/camera configuration, source frame pixel dimensions, detected face-box width/height/area as fractions of frame, detection and usable-embedding rates, known/unknown/correct identity, latency from first detection to permitted greeting, and no-face/multi-face rates. Keep distributions and failure counts, not just an average. Do not save photos, embeddings, names or stable member IDs in diagnostic output. The existing profile document gives the broader stage timing protocol.

## Implementation slices and acceptance

1. Add read-only anonymous geometry/timing instrumentation with tests that verify units, missing/multi-face samples, cancellation and absence of identifying payload. Run a Live distance profile. The geometry conversion helper and optional raw Vision yaw/roll mapping are complete; camera sampling, timing instrumentation and Live data collection remain.
2. With a calibrated threshold, write failing Domain tests for distant, near/stable, boundary jitter, disappearance and multi-face cases; implement the smallest pure policy. An Application port carries only the approved observation type.
3. Write failing continuous-loop tests for a single distant 「你好」, approach, known/unknown, no-approach silence, cancellation, repeated frames and departure rearm. Implement staged orchestration without duplicate welcomes or private speech before known recognition. Test Presentation mapping independently. A camera-triggered blink needs its own face-facing and event tests before enabling.
4. Run `swift test` and the unsigned Simulator build. Field acceptance on the Live composition must confirm no premature names, at most one distant 「你好」 per accepted visit, silence after it when no approach occurs, and acceptable detection-to-greeting p50/p95. Report the measured distance conditions rather than promising a universal number of meters.

## Open product decisions

- What face-facing evidence permits a camera-triggered blink? Vision currently exposes only face rectangles; pose is not part of the detection contract. The pose cutoff and signal quality must be field-calibrated. Also confirm whether the desired action is one deliberate two-eye blink or simply the existing natural blink.
- The face-size cutoff, required consecutive observations, boundary hysteresis and behavior during detection gaps remain to be measured and confirmed. There is no approved numerical value yet.
- The distant 「你好」 needs an actual short voice asset or a constrained one-shot voice path. Existing bundled welcome clips last 2.85–4.50 seconds and are not verified to say only 「你好」; they must not be repurposed on filename alone. The voice path must not leave a Realtime session open indefinitely for a visitor who never approaches.

These choices affect UX and Vision/state transitions. Per `AGENTS.md`, affected production behavior must wait for the owner's answer; measurement and specification work can proceed.

## 2026-09-30 Luna delivery — geometry foundation only

`FaceGeometryObserver` now maps a unique Vision face rectangle to normalized and source-frame pixel geometry. It also carries optional raw yaw/roll angles in radians from Vision; unavailable angles stay absent, and non-finite values fail closed. The Vision/YuNet pairer preserves this optional pose. Zero or multiple faces return no observation; cancellation propagates. It does not sample the camera in the active loop, store diagnostics, infer face-facing direction or trigger greetings. The existing confidence policy and voice lifecycle are unchanged.

TDD evidence: the geometry focused test first failed to compile because the observer was absent, then its four tests passed after implementation. The pose focused test first failed to compile because the new contract was absent, then 16 tests / 2 suites passed. Luna reported `swift test` with 913 tests / 74 suites passing and the unsigned Simulator build succeeding. Parent review confirmed the helper contains no identity or image payload; parent verification is recorded separately at handoff. These slices do not complete the Live distance profile or enable the two-stage behavior.

## 2026-09-30 Live iPhone installation

At the owner's request, the current worktree was built as `LumiApp-Live` / `Debug-Live` for iPhone with Team `85867ARTR8`. The signed product's `CFBundleIdentifier` was verified as `com.curves.lumi.live` before installation; its embedded profile included the connected iPhone. The app installed on the paired iPhone 15 Plus and `com.curves.lumi.live` launched successfully; the device process list showed `LumiApp.app/LumiApp` running. The device initially rejected the developer disk image while locked, then accepted installation after it became available. Build log: `/tmp/lumi-live-generic-build.log`.

This was built from the existing dirty local worktree at HEAD `4759791` (version 1.0, build 1), not a clean release. The exact connected-device build could not start while the developer disk image was locked; the signed generic-iOS Live build used the same scheme and configuration. Installation and process launch do not establish recognition accuracy, audio quality or the two-stage behavior. Geometry/pose remain unconnected to production triggers, and no distance or face-facing field profile was performed.
