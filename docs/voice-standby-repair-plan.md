# Voice standby repair design and work order

Date: 2026-09-05
Owner: primary reviewer; implementation: Luna
Authorization: user requested repair of the three reviewed standby defects.

## Scope and governing contracts

Read SYSTEM_SPEC.md, docs/architecture.md, docs/phase-2.2-webrtc-transport.md,
ADR-0007 and ADR-0008 before implementation. Preserve Clean Architecture and
the existing one-reconnect, no-replayed-greeting contract. This repair does not
introduce product timeouts, change thresholds, prompts, credentials, or UI.

## Design rules

1. A completed standby worker must never masquerade as running work. Every
   connection outcome must settle pending start waiters and release owned
   resources. A failed idle prewarm leaves a subsequent start retryable.
2. Start racing with standby connection/failure must either activate exactly
   one usable connection or return the existing typed failure. No lost wakeup,
   duplicate greeting, or indefinite wait on an already completed worker.
3. Standby must not transmit microphone content or trigger responses/tools.
   Media must be disabled before attaching/negotiating an outgoing audio track,
   not after connect. Ignore standby speech/commit/output events before they
   mutate conversation-turn state. Do not rely on an adapter event filter alone.
4. Use an explicit Infrastructure transport activation operation if needed;
   do not infer activation from arbitrary serialized JSON. Activation applies
   session-specific configuration/capabilities, enables conversation media,
   and sends exactly one greeting. Preserve permission-denial behavior and
   prevent standby from broadening microphone permission timing: if the real
   peer cannot safely prepare without permission/audio capture, defer that
   preparation until activation rather than inventing a new privacy policy.
5. Promoted standby shares active-session outcome handling: unexpected end
   reconnects at most once with the active configuration and tool capabilities;
   reconnect does not greet again; terminal failure is published once.
6. Stop/cancellation invalidates pending work. Check generation after suspension
   points before changing state, sending greeting, enabling media, or publishing.
   Close superseded transports; stale work must not clear a newer worker.
7. Prefer one understandable lifecycle implementation over parallel standby and
   active cleanup logic. No global services or provider types outside Infrastructure.

## Ordered implementation slices (RED → GREEN → REFACTOR)

### A. Recover failed standby

Ownership: OpenAIRealtimeAdapter and its tests.
First reproduce credential/connect failure before start and while start waits.
Assert retry succeeds or returns failure promptly using controlled fakes and
bounded test observation, and stop cancels pending startup. Record actual RED.
Implement common outcome cleanup with generation ownership.

### B. Make standby media and events inert

Ownership: OpenAIRealtimeTransport, OpenAIWebRTCTransport,
OpenAIRealtimeWebRTCPeerDriver and corresponding tests/fakes.
First reproduce standby speech+commit causing response.create and active media.
Add explicit activation/media control with fail-closed semantics; update adapter.
Assert standby has no outgoing microphone content, response.create, tool event,
or accumulated input-turn state; activation applies the correct context and
greets once. Cover stop/activation race and activation send failure.

### C. Preserve reconnect after promotion

Ownership: adapter and adapter regression tests.
First reproduce promoted standby disconnect without reconnect.
Verify one reconnect, active context/tools retained, no second greeting,
retry failure emitted once, and no third transport. Keep existing initial
connection and reconnect tests passing.

## Delivery and review gates

- Use deterministic fakes, no real microphone, network or credentials.
- Report RED command/result for each defect and subsequent focused GREEN result.
- Run swift test and the AGENTS.md unsigned Simulator xcodebuild command.
- If a suite hangs, identify the pending test and bound/cancel only owned test
  processes; do not disable tests or claim success. Investigate within scope.
- Primary reviewer checks implementation, race safety, privacy boundary, diff,
  and independently runs final verification. Fix review findings before handoff.
- Physical device deployment is outside this work order; audio behavior still
  requires future authorized Live-composition physical-device acceptance.
