# Phone greeting diagnostic — 2026-10-06

The owner reported delayed first speech, then clarified during the test that
Lumi recognized them but sometimes returned immediately to recognition without
speaking. The owner authorized local stage diagnostics without retaining images
or conversation content.

## Captured evidence before the diagnostic update

Live composition on an iPhone 15 Plus, captured through macOS Console. Duplicate
Console copies of the same event are not separate sessions. All times below are
UTC+08:00.

| Event | Time |
| --- | --- |
| Identity recognition started | 06:36:48.873488 |
| Identity recognition succeeded | 06:36:50.333638 |
| Voice startup requested | 06:36:50.335306 |
| Later voice startup requested | 06:40:40.844873 |
| Later voice startup failed | 06:40:41.090078 |

The measured identity operation took about 1.460 seconds. One later startup
failed about 0.245 seconds after its request. These are different attempts;
neither measurement establishes total arrival-to-audible-greeting latency.
The failure supports investigating the automatic loop's existing error recovery,
which ends the failed welcome and starts another arrival wait. It does not
establish the underlying broker, transport or audio failure reason.

## Diagnostic update and validation

Debug-only Infrastructure Console category `realtime-startup` adds closed event
codes for credentials, connection, activation, readiness and output start.
Known typed failures become fixed codes; arbitrary errors are `unclassified`.
No names, member IDs, credentials, transcripts, raw errors, images or embeddings
are emitted. The update changes no greeting rules, thresholds or lifecycle.

- RED: new classification/privacy tests failed because the diagnostic type did
  not yet exist.
- GREEN: both new tests passed.
- Full `swift test`: 927 Swift Testing tests in 77 suites and 4 XCTest tests passed.
- Required unsigned Simulator build: succeeded.
- `LumiApp-Live` / `Debug-Live` phone build: succeeded.
- Built bundle identifier verified as `com.curves.lumi.live`; installation succeeded.
- Automatic launch initially failed because the phone was locked. The owner was
  asked to unlock and run the updated app for the next measurement.
- After the owner unlocked the phone and requested deployment again, the same
  verified Live build was installed and launched successfully; CoreDevice
  confirmed its process was running. The next voice measurement is still pending.

Underlying failure diagnosis and device acceptance remain pending. An adapter
output-start event is a lifecycle signal, not an acoustic measurement.
