# Curves Lumi — Phase 2.3 Live Voice Specification

> Status: Approved
> Date: 2026-08-12
> Decision owner: Curves Lumi Product Owner
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`, `docs/roadmap.md`,
> `docs/phase-2.3-live-voice-implementation-plan.md`,
> `docs/phase-2.3-live-voice-task-list.md`,
> `docs/phase-2.2-webrtc-transport.md`,
> `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`,
> `docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md`, and
> `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`

Product-owner approval was recorded on 2026-08-12. The technical plan is also
approved; production implementation remains gated on approval of the Phase 2.3
task list.

## 1. Objective

Phase 2.3 makes the Phase 2.2 WebRTC transport usable from a dedicated Live
iPad app configuration without placing a standard OpenAI API key in the app.

The approved runtime path is:

```text
LumiApp-Live
↓
OpenAIRealtimeAdapter
↓
Vercel client-secret broker
↓
short-lived OpenAI client secret
↓
OpenAIWebRTCTransport
↓
OpenAI Realtime API
```

The broker is deliberately narrow. It authenticates a provisioned iPad, rate
limits that device, and mints a short-lived Realtime client secret. It does not
store member data, perform identity recognition, proxy the conversation, or
become a general Curves backend.

## 2. Scope

Phase 2.3 includes:

- a separate `LumiApp-Live` shared Xcode scheme
- `Debug-Live` and `Release-Live` build configurations
- a separate Live bundle identifier, `com.curves.lumi.live`
- a first-run Live setup screen with native one-tap device-token paste
- device-token storage in the iOS Keychain
- a concrete HTTP implementation of `OpenAIRealtimeClientSecretSource`
- Live composition of the completed Phase 2.1 adapter and Phase 2.2 transport
- a minimal Vercel Function that mints OpenAI Realtime client secrets
- independent Preview and Production secrets and device allowlists
- per-device credential-mint rate limiting
- Preview deployment, review gate, Production promotion, and smoke checks
- physical-iPad validation of the real voice path

The existing `LumiApp` scheme remains the deterministic Mock app.

## 3. App Modes and Build Configuration

### 3.1 Mock app

The existing `LumiApp` scheme continues to use the existing `Debug` and
`Release` configurations and `com.curves.lumi`. It keeps mock hardware, mock
identity, and mock voice behavior. Phase 2.3 must not make the Mock app depend
on network access, a microphone, Vercel, or OpenAI credentials.

### 3.2 Live app

The new `LumiApp-Live` scheme uses:

| Action | Build configuration | Broker environment |
| --- | --- | --- |
| Run / Test / Analyze | `Debug-Live` | Preview stable branch URL |
| Profile / Archive | `Release-Live` | Production URL |

The broker URL and environment identifier are non-secret build settings. No
device token, OpenAI key, short-lived client secret, or protection-bypass value
may appear in the Xcode project, scheme, generated plist, source, or bundle.

The Live app uses `com.curves.lumi.live`, allowing Mock and Live to be installed
on one iPad at the same time. There is no user-facing Mock/Live switch and no
automatic fallback from Live to Mock.

### 3.3 Hybrid Phase 2.3 simulation boundary

At the original Phase 2.3 acceptance boundary, the following was true:

In `LumiApp-Live`:

- hardware remains driven by the existing deterministic mock controls
- identity remains driven by the existing known/unknown mock controls
- voice uses the real `OpenAIRealtimeAdapter` and WebRTC transport
- the action that asks the coordinator to start voice remains available
- controls that complete mock voice startup or inject artificial voice events,
  responses, and failures are absent or disabled
- real provider events drive speaking, listening, thinking, interruption, and
  retry behavior through the existing Application boundary

Subsequent Milestone 3 work supersedes only the Debug-Live identity bullet:
the owner-approved 44B pilot now uses the bundled camera/Vision/Core ML/local
SQLite path when the operator requests recognition. Mock Debug and
Release-Live keep their anonymous/mock identity composition. Hardware remains
mocked, and the broker contract is unchanged.

### 3.4 Debug-Live continuous visitor experience diagnostics

Owner amendment (2026-08-24): the Debug-Live continuous visitor loop owns an
explicit asynchronous restart boundary. A retry first cancels the prior
generation, waits for the presence monitor's teardown and the prior loop task
to finish, and only then begins the next visitor wait. This prevents a new
arrival wait from overlapping the monitor operation that is still stopping.

The loop writes privacy-safe local Console diagnostics through an injectable
App-local callback whose default sink is OSLog/Console. Lifecycle stage slugs
remain `wait-for-arrival`, `welcome-identity-and-voice`,
`wait-for-departure`, and `finish-session`.

Owner amendment (2026-08-25): each stage also reports fixed operation slugs
with `started`, `succeeded`, `cancelled`, or `failed` status. The operation
slugs are `wait-for-arrival`, `confirm-presence`, `orient-to-visitor`,
`recognize-visitor`, `start-voice-session`, `wait-for-departure`, and
`finish-session`. Infrastructure writes a second fixed diagnostic chain for
model loading, camera permission/configuration, AVFoundation interruption and
runtime-error categories, presence camera-start versus face-capture failure,
and Vision/YuNet/alignment/SFace pipeline stages.

The UI continues to show only `自動辨識暫時無法使用，請再試一次。` Diagnostics
are closed, payload-free categories: they never include a member name or ID,
spoken label, image, embedding, transcript, model input, framework error text,
or raw provider error. Cancellation and an explicit stop are not reported as
stage failures.

Owner amendment (2026-08-25): a frame-pipeline failure during presence-only
observation is a transient unusable frame, not a terminal continuous-stage
failure. The presence monitor keeps its camera lease and waits for a newer
frame. Camera startup and stream failures still use the generic retry UI, while
calibration, enrollment, and identity decisions retain fail-closed behavior.

## 4. Device Provisioning and Keychain Contract

### 4.1 Token properties

Each authorized iPad receives a revocable, high-entropy device token. The
token-generation tool must use at least 256 bits of cryptographically secure
randomness and produce a paste-safe base64url value. It outputs the raw token
once for delivery to the iPad and its SHA-256 digest for Vercel configuration.

The raw token:

- is delivered through the native SwiftUI paste control after an explicit user tap
- is never displayed in a text field, accessibility value, or confirmation UI
- is never committed, bundled, logged, or sent to OpenAI
- is stored only in a this-device-only Keychain item for the selected broker
  environment

Preview and Production use different raw tokens, different SHA-256 allowlists,
different Keychain service namespaces, and different OpenAI API keys. QR setup
is explicitly deferred.

### 4.2 Setup behavior

When the current environment has no stored token, `LumiApp-Live` opens the
setup screen instead of the session UI. The operator copies the one-time raw
token and taps the system `PasteButton`; there is no manual token field or
separate save action. Empty or syntactically invalid pasted content is not
saved and displays `請輸入有效的裝置授權`. A save/reset cancellation or storage
failure displays the retryable generic message
`裝置設定失敗，請再試一次`. A saved token is authorized on the first
credential request.

**32A — Live configuration failure:** If the Live endpoint or environment is
missing or malformed at composition time, the app shows only
`語音服務尚未完成設定，請聯絡管理員。` It must not present setup/token UI,
perform any Keychain store operation, or fall back to Mock.

If the broker responds with `401` (or the client receives a future-compatible
`403`), the app:

- stops voice startup
- keeps Live mode active
- never falls back to a voice mock
- presents `裝置授權已失效`
- offers a `重新設定` action that returns to setup

The development controls expose `解除裝置設定`. It requires confirmation,
deletes only the token for the active Preview or Production namespace, and
returns to setup. A rate limit or transient service failure must not erase the
stored token.

## 5. Broker API Contract

### 5.1 Endpoint

```http
POST /api/realtime/client-secret
Authorization: Bearer <device-token>
Accept: application/json
```

The request has no body. The App does not send a model, voice, instructions,
member ID, member name, recognition confidence, embedding, image, transcript,
or other member data to the broker.

### 5.2 Success response

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{
  "value": "<short-lived-client-secret>",
  "expiresAt": 1786500000
}
```

`expiresAt` is a Unix timestamp in seconds. The broker validates the OpenAI
response before mapping it to this provider-minimal contract. It never returns
the standard OpenAI API key or an unvalidated upstream payload.

### 5.3 Error response

Errors use a stable, privacy-safe envelope:

```json
{
  "error": {
    "code": "unauthorized"
  }
}
```

| Status | Code | Meaning |
| --- | --- | --- |
| `401` | `unauthorized` | Bearer token is missing, malformed, unknown, or no longer allowlisted, including a revoked device |
| `405` | `method_not_allowed` | request method is not `POST` |
| `429` | `rate_limited` | device exceeded the configured mint limit |
| `502` | `upstream_failure` | OpenAI rejected or returned an invalid response |
| `503` | `service_unavailable` | required broker configuration or the WAF rate-limit service is unavailable |

Responses include `Cache-Control: no-store`. Provider response bodies,
credentials, token hashes, authorization headers, and stack traces are never
returned to the App.

The Phase 2.3 broker does not emit `403`. Its allowlist-only design cannot and
must not distinguish a token that was never authorized from one removed during
revocation. The App nevertheless maps a future-compatible `403` response to the
same device-reconfiguration behavior as `401`.

## 6. Broker Security and OpenAI Contract

### 6.1 Authorization

Vercel environment variables hold only SHA-256 device-token digests. The
broker hashes the presented token and performs a timing-safe comparison against
the allowlist. Adding or revoking an iPad requires an environment-variable
update and a new deployment; Phase 2.3 has no database or administration UI.

The matched digest is a device pseudonym used only as:

- the Vercel rate-limit key
- the `OpenAI-Safety-Identifier`

It is not a member identifier and must not be logged.

### 6.2 Rate limiting

The initial configurable limit is 10 successful or attempted client-secret
mints per 60 seconds per authorized device. The broker uses
`@vercel/firewall` with the matched device digest as `rateLimitKey` and a
published Vercel WAF rate-limit rule. The threshold remains operational
configuration and may be adjusted after measured usage.

The Function runs in one configured region because Vercel rate-limit counters
are region-local. A rate-limited request returns `429` without calling OpenAI.
If the WAF SDK check itself fails, the broker fails closed with the approved
`503 service_unavailable` envelope, does not call OpenAI, and the App retains
the stored device token for retry.

### 6.3 OpenAI request

The standard OpenAI API key exists only as a sensitive Vercel environment
variable. For an authorized, non-rate-limited request, the broker calls:

```http
POST https://api.openai.com/v1/realtime/client_secrets
Authorization: Bearer <standard-openai-api-key>
Content-Type: application/json
OpenAI-Safety-Identifier: <matched-device-digest>
```

The broker owns the client-secret session request and fixes:

- session type: `realtime`
- model: `gpt-realtime-2.1-mini`
- output voice: `marin`

The App cannot select a model through the broker API. The allowlist contains
only this approved model.

After WebRTC connection, the App sends the canonical Taiwan Traditional
Chinese persona, `marin`, Server VAD, and only the privacy-safe
`returningMember` or `visitor` greeting context directly to OpenAI. It never
sends a member ID, name, confidence, embedding, or image.

Owner amendment (2026-08-25): editable Realtime response wording is centralized
in `Sources/LumiInfrastructure/Voice/OpenAIConversationPrompts.swift`. The
catalog owns the base persona, returning-member and visitor wording,
enrollment-consent conversation, direction prompts, and Debug fixture
disclosure. Moving the copy does not make prompts runtime-selectable and does
not move tool schemas, authorization rules, model, voice, or broker behavior.

Owner amendment (2026-08-24, controlled barge-in): Server VAD remains the
provider speech-candidate signal, but `create_response` and
`interrupt_response` are both disabled. Infrastructure samples normalized
WebRTC microphone level while output is playing, learns three baseline samples
at 80 ms intervals, and requires three candidate samples at the same interval
whose median is at least `max(1.8 × baseline, baseline + 0.02)`. Missing or
invalid statistics fail closed. Confirmed near-end speech cancels a response
only while generation is active, always clears buffered playout, and creates
the next response only after accepted input is stopped and committed. Rejected
echo input is deleted from the provider conversation. Speech before playout
begins has no output echo, so it is accepted directly, cancels an active
generation, clears any old playout that arrives during the cancellation race,
and waits for cancellation completion before response creation.
This policy persists no
audio, transcript, or level history and remains Infrastructure-only pilot
tuning subject to physical-device validation.

Owner amendment (2026-08-22): Debug-Live may additionally send one
Application-validated `VoiceMemberAddress.spokenLabel` directly to OpenAI for
an already-confirmed 44B returning member. This temporary enrollment label is
restricted to 1–32 Unicode letters/numbers only; invalid labels, Release,
unknown visitors, and unmapped members remain anonymous. It carries no member
profile, confidence, biometric, visit, or exercise values. The broker contract
and its bodyless request are unchanged and still receive no member identity.
Debug-Live may also show the same validated label locally as
`<spokenLabel>，歡迎回來～` after recognition and before voice startup; unknown,
invalid-label, and Release paths stay anonymous.

Owner amendment (2026-08-23): the Debug-Live visitor surface automatically
starts recognition and voice after one usable arrival, then rearms only after
ten continuous seconds without a usable face. A known session must begin its
spoken greeting with the validated `<名稱>，歡迎回來`; it may then use exactly
one of `漂亮姊姊`, `寶貝`, or `公主殿下` with a short positive sentence. An
unknown enrollment-capable session begins with
`漂亮姊姊，我好像還不認識妳` and retains the existing disclosure and explicit
consent gate. These phrases do not add member data to the broker request and do
not authorize fabricated profile or exercise facts.

The same Debug-Live surface exposes Apple's native `MPVolumeView` so the user
can change system output volume. `AVAudioSession.outputVolume` remains
read-only; the App does not set it programmatically. The existing
`.defaultToSpeaker` route preference remains unchanged.

Owner amendment (2026-08-24): the product owner approved a `2.0` gain for
decoded Realtime remote audio. Infrastructure applies this gain through the
pinned WebRTC `RTCAudioTrack.source.volume` API for both legacy stream and
Unified Plan receiver callbacks. This is a per-track media gain only; it does
not write system output volume, force a speaker route, or change the existing
external-route policy. The native `MPVolumeView` remains the user-facing
system-volume control.

Owner amendment (2026-08-24, route correction): WebRTC's public
`RTCAudioSessionConfiguration.webRTCConfiguration()` is amended before audio
unit creation through `setWebRTCConfiguration`. The App preserves the existing
WebRTC category options and adds `.defaultToSpeaker` plus `.allowBluetoothHFP`,
so an absent external route prefers the built-in speaker while Bluetooth HFP
and other existing external-route behavior remain available. This does not
write `AVAudioSession.outputVolume`, use a private API, or call
`overrideOutputAudioPort`.

## 7. App Credential Source and Failure Mapping

The concrete client-secret source is an Infrastructure adapter. It receives an
injected broker endpoint, Keychain-backed device-token source, and URL session.
It implements the existing `OpenAIRealtimeClientSecretSource` contract and
does not leak Vercel or HTTP types into Application or Domain.

The adapter must:

- issue the exact broker request without a body
- decode only the approved success envelope
- reject empty, malformed, expired, or non-finite expiry values
- preserve task cancellation
- map broker `401` and future-compatible `403` to device reconfiguration
- map `429` to a retryable rate-limit failure without deleting authorization
- map transport, `5xx`, and invalid-response failures to privacy-safe retryable
  categories
- omit raw response bodies, URLs with query data, tokens, and credentials from
  descriptions, reflections, logs, and UI

The Live composition root constructs dependencies explicitly. It must not add
a global service singleton or let SwiftUI call URLSession, Keychain, WebRTC, or
OpenAI directly.

## 8. Vercel Environments and Release Flow

The repository contains one minimal Vercel project for the credential broker.
Preview and Production are configured independently with:

- `OPENAI_API_KEY`
- device-token digest allowlist
- WAF rate-limit rule and identifier
- any required non-secret region/model configuration

Preview must be reachable by the native App without Vercel Deployment
Protection. The device Bearer token, allowlist, and rate limit form the broker
authorization boundary.

The release flow is gated:

1. deploy the selected source revision to Vercel Preview
2. verify method rejection, unauthorized rejection, rate limiting, redaction,
   successful client-secret minting, and one real iPad voice session
3. review Preview evidence with the product owner
4. receive explicit approval to promote
5. promote the same source revision to Production; Vercel rebuilds it using
   Production environment variables
6. verify Production unauthorized and authorized smoke checks
7. verify `Release-Live` uses the Production endpoint

No Production promotion occurs implicitly as part of a code build or test.

## 9. Privacy Boundary

The broker processes a device credential, not a member identity. It must not
receive or persist:

- member profiles or Member IDs
- face images or normalized face crops
- Core ML embeddings or matcher features
- recognition confidence
- audio, SDP, transcripts, or conversation content

Identity recognition remains Milestone 3. That later milestone will implement
the app-side camera → Vision face detection → normalized crop → Core ML
embedding → local `MemberMatcher` path behind `IdentityRecognitionPort`.
Multiple local embeddings per member, deletion/revocation, and storage/sync
policy will be specified there. Raw face images are not retained by default and
identity features are not sent to this broker. Except for the explicitly
approved Debug-Live spoken-label pilot above, they are not sent to the LLM.

## 10. Original Phase 2.3 Out of Scope

At Phase 2.3 acceptance, this phase did not add the following. Later milestones
may supersede individual bullets; in particular, Milestone 3 now supplies the
Debug-Live 44B local identity pilot described above.

- a standard OpenAI API key to the app
- a general application backend or database
- App Attest or DeviceCheck
- QR provisioning
- remote device administration
- real camera, Vision, Core ML, or member identity storage
- real Raspberry Pi hardware control
- member repository queries or Realtime tool calling
- member names, IDs, embeddings, or images in prompts
- user-selectable model, voice, persona, or language
- a visible Mock/Live runtime switch
- automatic fallback to Mock
- new timeout values, VAD thresholds, transcript recovery, or Avatar amplitude
  behavior

## 11. TDD and Verification Requirements

All production behavior follows RED → GREEN → REFACTOR.

### 11.1 Broker tests

Deterministic tests must cover:

- method and empty-body contract
- missing, malformed, unknown, and removed/revoked device tokens all returning
  exact `401 unauthorized`
- exact SHA-256 authorization and timing-safe comparison boundary
- per-device rate-limit keys, allowed requests, and `429` short-circuiting
- exact OpenAI URL, method, headers, safety identifier, model, and voice
- success mapping to `value` and `expiresAt`
- upstream non-2xx, malformed JSON, missing values, and invalid expiry
- `no-store` headers and privacy-safe error bodies
- absence of standard keys, raw tokens, hashes, and upstream markers in errors

### 11.2 App and package tests

Deterministic tests must cover:

- environment-specific Keychain namespace selection through an injected seam
- missing-token setup routing
- paste/save behavior and empty/invalid input rejection
- explicit reset and current-environment-only deletion
- exact broker HTTP request and success decoding
- broker `401` and future-compatible `403` reconfiguration behavior, with the
  approved Taiwan Chinese copy
- `429` and transient failure behavior without token deletion
- cancellation and secret/error redaction
- Mock composition remains fully mock and offline
- Live composition selects the real voice adapter while retaining mock hardware
  and identity
- artificial voice controls are unavailable in Live mode
- no automatic Live-to-Mock fallback

### 11.3 Required commands

```sh
swift test
```

```sh
xcodebuild -project App/LumiApp.xcodeproj \
  -scheme LumiApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

```sh
xcodebuild -project App/LumiApp.xcodeproj \
  -scheme LumiApp-Live \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The broker project must also pass its unit tests, type check, and clean build.

### 11.4 Physical and deployment acceptance

Before Phase 2.3 is complete, a physical iPad using real Preview credentials
must verify:

- first-run setup and Keychain persistence across relaunch
- microphone permission presentation and denial behavior
- built-in speaker and available external-route behavior
- initial greeting exactly once
- listening, response, barge-in, and interruption recovery
- one fresh-credential reconnect without greeting replay
- generic returning-member and visitor greetings with no identity details
- authorization revocation and reconfiguration
- acceptable Taiwan Mandarin interaction quality

Simulator builds and fake-based tests do not satisfy this physical acceptance
gate.

## 12. Exit Criteria

Phase 2.3 is complete only when:

- Mock and Live apps can coexist and select their approved dependencies without
  a runtime mode switch
- the Live app obtains only short-lived credentials through the authenticated
  broker and completes a real WebRTC conversation
- no standard API key or raw provisioned token exists in source or bundle
- Preview and Production use separate keys, device tokens, allowlists, and
  Keychain namespaces
- unauthorized, revoked, and rate-limited devices follow the approved UX
- no member identity data reaches the broker
- all package, broker, Mock-scheme, and Live-scheme automated gates pass
- the Preview physical-iPad gate is recorded
- the product owner approves Preview before Production promotion
- the promoted Production deployment passes its smoke checks

## 13. Authoritative Sources

- [OpenAI Realtime API with WebRTC](https://developers.openai.com/api/docs/guides/realtime-webrtc)
- [OpenAI API authentication](https://platform.openai.com/docs/api-reference/authentication)
- [Vercel Rate Limiting SDK](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting-sdk)
- [Vercel environment variables](https://vercel.com/docs/environment-variables)
- [Vercel Preview-to-Production promotion](https://vercel.com/docs/deployments/promote-preview-to-production)
- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
