# Conversation naturalness A — independent review

Date: 2026-09-06
Status: Code review complete; final test disposition recorded below.

The owner selected option A: natural opening wording, provided forms of
address, concise replies without a rigid 35-character ceiling, and responding
to the visitor's latest utterance before encouragement. Luna implements the
change; the primary agent reviews and runs the final verification commands.

## Review gates

- Composed provider instructions use the approved tone in named returning,
  anonymous returning, ordinary visitor, and enrollment-capable visitor paths.
- No context forces an exact opening or an unsolicited intimate title.
- Necessary explanations can be complete; ordinary replies stay concise.
- User context takes priority over a scripted encouragement or repeated greeting.
- Existing consent, three-sample enrollment order, tool authorization,
  on-demand member data, fixture disclosure, and medical boundaries remain.
- Production changes stay in the Infrastructure prompt catalog. No new data
  retention, session policy, hardware behavior, or identity threshold is added.
- Existing worktree changes from the voice standby repair remain intact.

## Manual acceptance still required

Use the Live composition on a physical device. These are evaluation scenarios,
not required verbatim responses or claims of automated LLM verification.

| Scenario | Expected observation |
| --- | --- |
| Recognized visitor with a provided label | Brief natural greeting using that label; no added intimate title or opening data query. |
| Returning visitor without an authorized label | Generic welcome without a guessed name. |
| Visitor says they feel tired | Acknowledges that statement before any relevant encouragement; no diagnosis. |
| Follow-up question in the same conversation | Answers the question without restarting the welcome. |
| Visitor asks for weekly exercise data | Uses the existing authorized tool; reports only its data and preserves fixture disclosure. |
| Unknown visitor offered enrollment | Complete existing disclosure before clear consent; capture and naming retain their existing order. |
| Visitor declines or gives an ambiguous enrollment answer | Does not begin enrollment. |

Prompt contract tests prove which instructions are sent, not whether a live
model consistently follows them or whether speech feels natural.

## Review disposition

The primary reviewer requested and verified three corrections: anonymous
returning greetings express a welcome-back meaning without requiring an exact
sentence; encouragement after tool results is conditional on the latest user
context; pre/post-workout directions retain their existing after-greeting,
visitor-initiated interaction condition. No remaining blocking finding was
identified in the option A diff. The code change remains confined to the
Infrastructure prompt catalog, with prompt-contract tests and documentation.

`git apply --reverse --check /tmp/lumi-conversation-a-existing.patch` succeeded
against the final worktree, confirming the pre-existing standby repair patch
remained intact. This was a read-only patch check, not an actual reverse apply.
`git diff --check` passed.

## Verification

Luna reported the following actual RED/GREEN results (tool output, no separate
log files):

- RED: `swift test --scratch-path /tmp/lumi-luna-red-build --filter
  'OpenAIRealtimeConfigurationTests'`: exit 1, 17 expected assertion failures
  against the old prompt catalog.
- GREEN: the configuration suite in `/tmp/lumi-luna-green-build`: exit 0, 5/5;
  the adapter suite: exit 0, 35/35.
- Combined `CoreMLIdentityCalibrationServiceTests|OpenAIRealtimeConfigurationTests|OpenAIRealtimeAdapterTests`
  using the green scratch path: exit 0, 78/78.

Independent verification:

- Required `swift test`: blocked by the pre-existing SwiftPM PID 32999 holding
  the shared `.build` directory; the reviewer's own waiting invocation was
  interrupted with exit 130. Log: `/tmp/lumi-conversation-a-review-default-test.log`.
- Full suite with independent scratch path
  `/tmp/lumi-conversation-a-review-build`: built successfully, but did not
  finish. A line-buffered rerun identified the only started-but-unfinished test
  as `failedStandbyCredentialSourceIsRetryable` (the existing standby repair).
  No test failure marker was emitted; this is not a passing suite. The
  reviewer's own runs were interrupted with exit 130. Diagnostic log:
  `/tmp/lumi-conversation-a-review-tests-line.log`.
- Required `xcodebuild -project App/LumiApp.xcodeproj -scheme LumiApp
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`:
  exit 0, `BUILD SUCCEEDED`. Log: `/tmp/lumi-conversation-a-review-simulator.log`.
- Full sequential follow-up:
  `stdbuf -oL -eL swift test --scratch-path /tmp/lumi-conversation-a-review-build --no-parallel`:
  exit 0; 784 Swift Testing tests in 60 suites passed, along with the 4 XCTest
  snapshot tests. Log: `/tmp/lumi-conversation-a-review-tests-serial.log`.
  The parallel-run hang remains a separate existing standby-test concern;
  sequential success does not establish that parallel execution is reliable.

No physical deployment or live-provider conversational acceptance was performed.
