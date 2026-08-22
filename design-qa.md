# Design QA — DEBUG Identity Calibration Console

## 2026-08-22 — Scheme A identity-first flow

Reference: existing signed-device field-console screenshot
`/Users/tunghunglu/Downloads/截圖 2026-08-22 上午8.06.10.png`

Implementation screenshot:
`/tmp/lumi-scheme-a-setup-final.png`

Comparison inputs:

- `.build/design-qa/scheme-a-old-vs-setup-final.png`
- `.build/design-qa/scheme-a-focused-old-vs-setup-final.png`

Viewport: 1290×2796 pixels at 3× (430×932 points), portrait, iPhone 16 Plus
Simulator on iOS 18.4.

Compared state: initial DEBUG calibration entry, camera stopped, before member
confirmation.

### Decision and result

Scheme A is implemented as a two-stage flow:

1. Enter and confirm `會員 ID／暫時 ID`.
2. Load the existing sample count and start the camera before entering capture.

The first stage contains no camera preview, shutter, enrollment/return selector,
or Photos control. The capture stage contains no duplicate ID editor. `更換會員`
stops the camera and returns to the first stage without deleting samples;
`清除目前會員樣本` remains a separate confirmed destructive action.

The old screen mixed identity selection, camera control, sample progress, and
capture actions in one surface. It also showed duplicate camera controls and a
misleading capped ratio such as `6/5`. The new screen removes those repetitions
and presents sample count as soft `建議 3–5 個樣本` guidance rather than a cap.

Visual QA found one P1 during comparison: `DEBUG 身份校準` appeared in both the
navigation bar and content header. A regression test was added first, then the
duplicate content title was removed. The final comparison has no remaining P0,
P1, or P2 issue in the member-setup state.

The capture-stage hierarchy is covered structurally by App tests, but live
camera framing still requires direct inspection on `TonyLu`; Simulator visual
QA does not claim physical camera or recognition quality.

## 2026-08-21 — Camera-first console baseline

Reference: Google Stitch option A, “Lumi Field Identity Console”
Project: https://stitch.withgoogle.com/projects/10735205260712716081

Implementation viewport: iPhone 16 Plus Simulator, iOS 18.4, portrait.
Compared state: camera stopped, no temporary member selected.

The original field-console implementation passed after moving the manual
capture controls into a fixed bottom safe-area deck. That baseline established
the dark charcoal/navy console, green primary action, live preview, static face
guide, manual shutter, mode switch, and Photos action. It did not add automatic
capture, recognition thresholds, or known/unknown decisions. The 2026-08-22
Scheme A flow supersedes its camera-first entry while preserving its capture
surface after member confirmation.

final result: passed
