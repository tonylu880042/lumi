# Curves Lumi — Phase 2.3 Live Voice Implementation Plan

> Status: Approved
> Date: 2026-08-12
> Decision owner: Curves Lumi Product Owner
> Related: `docs/phase-2.3-live-voice.md`,
> `docs/phase-2.3-live-voice-task-list.md`,
> `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`,
> `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`, and
> `docs/decisions/ADR-0008-phase-2.2-webrtc-transport.md`

## 1. Goal

Wire the completed Realtime adapter and WebRTC transport into a separately
installable Live app, backed by a narrowly scoped Vercel client-secret broker.
Preserve the deterministic Mock app, Clean Architecture dependency direction,
secret redaction, and the existing coordinator-owned session lifecycle.

Product-owner approval was recorded on 2026-08-12. Production code remains
gated on approval of the separate Phase 2.3 task list.

## 2. Current-State Findings

- `LumiAppApp` always constructs `MockVoiceSessionPort`.
- `SessionSimulationModel` stores a concrete `MockVoiceSessionPort`, waits for
  its pending readiness continuation, completes that continuation itself, and
  injects artificial voice events.
- `AssistantSessionCoordinator` already depends only on `VoiceSessionPort` and
  needs no provider-specific change.
- `OpenAIRealtimeAdapter`, `OpenAIWebRTCTransportFactory`, the microphone and
  audio-session implementations, SDP exchange, wire codec, and peer driver are
  ready for iOS composition.
- `OpenAIRealtimeClientSecretSource` is the missing concrete Live dependency.
- `LumiPresentation` currently depends only on Domain; the approved dependency
  direction permits adding Application so setup UI state can use an
  Application-owned provisioning boundary.
- The Xcode project has only `Debug` and `Release`; `LumiApp.xcscheme` is shared
  and should remain unchanged for Mock behavior.
- Vercel CLI `56.5.0` is authenticated for the current operator, but this
  repository is not linked to a Vercel project. Project creation and linking
  occur only after implementation approval.

## 3. Dependency Graph

```text
Approved broker HTTP contract
├── Broker handler + authorization + rate-limit seam
│   └── Preview deployment
│
└── Application device-authorization boundary
    ├── Keychain adapter
    ├── broker client-secret source
    └── setup presentation model
        └── Live composition + Live controls

Preview deployment + Live composition
└── physical-iPad Preview gate
    └── product-owner promotion approval
        └── Production promotion + smoke checks
```

The broker and Swift foundation slices can be developed independently after
their shared HTTP contract is frozen. Live App integration is sequential after
the Swift adapters exist. Production promotion is always last.

## 4. Architecture Decisions

### 4.1 Application owns authorization meaning

Add provider-neutral Application values and ports for device provisioning:

```text
DeviceAuthorizationToken
DeviceAuthorizationStore
DeviceAuthorizationController
VoiceSessionAuthorizationError.authorizationRequired
```

`DeviceAuthorizationToken` validates the approved 256-bit base64url format and
redacts all string/debug/reflection output. The store exposes load/save/remove
to inner callers without mentioning Keychain, HTTP, Vercel, or OpenAI.

`DeviceAuthorizationController` is the UI-facing use case for provisioned
status, save, and reset. Presentation depends on this controller rather than on
Security.framework. `VoiceSessionAuthorizationError.authorizationRequired` is
the one semantic error allowed to cross from a credential adapter through
`VoiceSessionPort.start` so Presentation can route to setup. HTTP status codes
and provider payloads remain in Infrastructure.

No new Domain type or state is required. Device setup is application access
configuration, not member identity or assistant conversation state.

### 4.2 Infrastructure supplies two independent adapters

`KeychainDeviceAuthorizationStore` implements the Application store with a
configured service namespace. It uses generic-password items,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and no synchronization or
shared access group. Preview and Production service names are distinct.

`VercelOpenAIRealtimeClientSecretSource` implements the existing
`OpenAIRealtimeClientSecretSource`. It loads the raw device token from the
store, sends the exact bodyless broker request, validates `{ value,
expiresAt }`, and returns the existing redacted `OpenAIRealtimeClientSecret`.

Both adapters use internal injected seams so macOS package tests perform no
real Keychain or network operation. Cancellation remains native Swift task
cancellation. Infrastructure errors use fixed categories and must pass marker
redaction tests.

### 4.3 Presentation owns setup state, not secret persistence

Add a `@MainActor` Presentation model with only these user-visible phases:

```text
loading → setup(message?) → saving → ready
                         ↘ failure(generic message)
```

The transient secure-field string exists only while the user is editing. The
model hands a validated value to the Application controller and clears its
copy after success, reset, or cancellation. It never reads a stored token back
for display. Empty or invalid input stays in setup with
`請輸入有效的裝置授權`; save/reset cancellation or storage failure uses the
retryable `裝置設定失敗，請再試一次`. Authorization invalidation remains the
separate exact `裝置授權已失效` state.

The Presentation target gains an allowed dependency on `LumiApplication`.
Unit tests use an Application-port fake and cover first run, validation, save,
reset confirmation intent, environment-independent state transitions, and the
exact authorization-invalid copy.

### 4.4 App uses compile-time composition

Create `Debug-Live` and `Release-Live` by inheriting their Debug/Release project
and target settings. Both define `LUMI_LIVE`; Mock configurations do not.

Live-only non-secret settings are generated into the plist:

```text
LUMI_BROKER_ENDPOINT
LUMI_BROKER_ENVIRONMENT = preview | production
```

The App validates both values at composition time. **32A — Live configuration
failure:** A missing or malformed Live configuration shows only
`語音服務尚未完成設定，請聯絡管理員。` It must not present setup/token UI,
perform any Keychain store operation, or select Mock as a fallback.

Under `LUMI_LIVE`, the composition root constructs:

```text
KeychainDeviceAuthorizationStore
→ VercelOpenAIRealtimeClientSecretSource
→ OpenAIRealtimeAdapter
→ OpenAIWebRTCTransportFactory
→ AssistantSessionCoordinator
```

Hardware and identity remain the same mock instances. Mock builds keep the
existing voice instance and behavior.

`SessionSimulationModel` stores `any VoiceSessionPort` only through the
coordinator and receives an optional mock-voice control collaborator. When the
mock collaborator exists, current deterministic readiness completion and event
injection remain. When absent, startup simply awaits the coordinator and all
voice lifecycle events come from Realtime. A semantic authorization error
routes the shared setup presentation model back to setup.

`SimulatorControlsView` receives explicit voice-control capabilities. Live
keeps `啟動語音` but does not construct buttons for artificial speech start,
speech end, response ready, or voice failure. This is an absence in the view
tree, not merely disabled network behavior.

Add a small `LumiAppTests` Xcode unit-test target rather than moving App
composition code into an inward package. A pure App composition descriptor and
voice-control capability value let the same tests assert Mock under `Debug`
and Live under `Debug-Live`. App tests also cover authorization-required
routing and prove that Live startup does not execute the mock readiness path.
All network, Keychain, WebRTC, and microphone collaborators remain fakes.

### 4.5 Broker is a framework-free Vercel Function

Create a standalone `Broker/` Vercel project using:

- Node.js `24.x`
- TypeScript with strict checking
- Web-standard `Request` / `Response` Vercel Function signature
- Node's stable `node:test` runner
- `@vercel/firewall` for the approved per-device rate-limit bucket
- npm lockfile with exact resolved dependency versions

The route entry point performs composition only. A handler factory receives
injected hashing/allowlist, rate-limit, clock/fetch dependencies so tests do not
call Vercel or OpenAI.

Request processing order is fixed:

```text
POST check
→ parse Bearer token
→ SHA-256 + timing-safe allowlist match
→ checkRateLimit(device digest)
→ POST fixed session to OpenAI
→ validate upstream response
→ return minimal no-store envelope
```

Rejected authorization and rate-limited requests never call OpenAI. The model,
voice, upstream URL, session type, and error mappings are source-owned
constants. There is no model or instruction input in the broker request.
An exception from the WAF rate-limit check fails closed as exact
`503 service_unavailable`, never calls OpenAI, and remains a transient App
failure that does not remove device authorization.

### 4.6 Broker configuration is fail-closed

Use these deployment variables:

| Variable | Classification | Purpose |
| --- | --- | --- |
| `OPENAI_API_KEY` | Vercel sensitive | standard server-only OpenAI key |
| `LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST` | Vercel sensitive | comma-separated lowercase 64-hex digests |
| `LUMI_RATE_LIMIT_ID` | non-secret | published WAF SDK rule identifier |

Missing or malformed configuration returns the approved `503` envelope before
OpenAI is called. Environment values are parsed on request without being copied
into diagnostics. `.env*`, `.vercel/`, `node_modules/`, coverage, and build
output are ignored; a placeholder-only `.env.example` may be committed.

A small local token-generation script uses Node `crypto.randomBytes(32)` and
prints one base64url token plus its lowercase SHA-256 digest. Tests validate
format and round-trip hashing with injected randomness. Real Preview and
Production tokens are generated and transferred at the human secret gate; the
agent does not echo them into logs, chat, fixtures, or command output.

### 4.7 Single-region rate limiting

`Broker/vercel.json` fixes the Function to Tokyo `hnd1`, the closest selected
Vercel region to the Taiwan pilot. The WAF SDK documents that counters are
region-local; using one region preserves the approved 10-per-60-second device
bucket. Multi-region failover is deferred because it would require a revised
global rate-limit design.

The WAF rule threshold remains Vercel operational configuration, not a source
constant. Broker tests inject the rate-limit result; deployment acceptance
inspects and exercises the published rule.

### 4.8 Preview and Production release flow

The Vercel project root is `Broker/`. Preview receives an explicit stable alias
used by `Debug-Live`; Production uses the project's stable Production domain
used by `Release-Live`. Deployment Protection remains disabled for the broker.

Preview and Production use separate OpenAI keys, allowlists, raw device tokens,
and Keychain namespaces. Promotion uses the same source revision but triggers a
Production rebuild with Production environment variables, matching Vercel's
documented behavior.

Implementation pauses twice for user-controlled external state:

1. **Secret/configuration gate:** the product owner enters Preview/Production
   OpenAI keys, token digests, and WAF rules in Vercel without placing values in
   the repository or agent output.
2. **Promotion gate:** after automated checks and the physical Preview iPad
   evidence are reviewed, the product owner explicitly approves Production
   promotion.

## 5. Implementation Stages

### Stage A — Contract and broker foundation

- Mark ADR-0009 accepted after plan approval.
- Add the Application authorization value, port, controller, and semantic
  voice-authorization error using RED → GREEN.
- Scaffold the minimal Broker project and freeze handler dependencies and
  response helpers through failing tests.

#### Checkpoint A

- Application contract tests pass without Security or network imports.
- Broker type check and initial request/error tests pass.
- Secret scanning finds only placeholders and redaction fixtures.
- No App composition or external deployment has changed.

### Stage B — Secure credential vertical slices

- Implement the Keychain store behind an injected Security seam.
- Implement the bodyless broker client-secret source behind an injected HTTP
  loader.
- Implement broker device authorization, rate-limit short circuit, exact OpenAI
  request, upstream validation, and response mapping.
- Add the deterministic token generator.

#### Checkpoint B

- Swift focused tests prove Keychain intent, namespace isolation, broker HTTP
  contract, cancellation, and redaction without external effects.
- Broker tests prove every approved status and no forbidden OpenAI call.
- Full `swift test`, broker tests, broker type check, and broker build pass.

### Stage C — Setup and dual App composition

- Add the tested Presentation setup model and Application dependency.
- Refactor the App simulation wrapper so mock-only voice controls are optional.
- Add the setup screen, reset confirmation, and authorization-invalid routing.
- Add Live build configurations and the shared `LumiApp-Live` scheme.
- Wire concrete Live voice while preserving mock hardware and identity.

#### Checkpoint C

- Mock package and App behavior remain deterministic and offline.
- Live configuration compiles only the approved real voice composition.
- Broker `401` and future-compatible `403` return to setup;
  `429`/transient failures retain the token.
- Artificial voice-event buttons are absent from the Live view tree.
- App unit tests pass under both Mock and Live build configurations.
- `swift test` and unsigned Simulator builds for both schemes pass.

### Stage D — Preview deployment and device gate

- Link or create the Vercel project without committing `.vercel/` state.
- Complete the human secret/configuration gate for Preview and Production.
- Deploy the approved source revision to Preview and assign the stable alias.
- Verify rejection, authorization, rate limiting, response shape, no-store, and
  redacted logs.
- Build/install `Debug-Live` and perform the approved physical-iPad matrix.

#### Checkpoint D

- Preview deployment evidence and exact source revision are recorded.
- A real Preview client secret and WebRTC conversation succeed without exposing
  either standard or device credentials.
- Permission, routing, greeting, barge-in, reconnect, revocation, and Taiwan
  Mandarin observations are recorded.
- Production is unchanged pending explicit approval.

### Stage E — Production promotion and documentation

- Receive explicit product-owner promotion approval.
- Promote the reviewed source revision using Production environment values.
- Run Production unauthorized and authorized smoke checks.
- Confirm `Release-Live` targets Production and passes an unsigned build.
- Update the feature spec, this plan, ADR, architecture/roadmap, and operational
  runbook with actual evidence and any accepted deferrals.

#### Checkpoint E

- All automated and manual Phase 2.3 exit criteria are satisfied.
- Preview and Production configuration remain isolated.
- No raw secret, generated environment file, deployment metadata, or build
  output is tracked.
- Rollback target and device-revocation procedure are documented.

## 6. Verification Strategy

### Swift

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

The implementation task list will also run both schemes' `LumiAppTests`
against an available iOS Simulator destination. The exact device UUID is
resolved at execution time rather than committed to a scheme or script.

Focused Swift filters will be named in the approved task list. Real Keychain,
microphone, and network access are excluded from `swift test`.

### Broker

The final `package.json` exposes stable commands equivalent to:

```sh
npm test
npm run typecheck
npm run build
```

Tests inject OpenAI fetch and rate limiting. Deployment smoke tests use Vercel
CLI without printing response credentials. Logs are inspected for error
categories and absence of known secret markers, not raw payloads.

### Git and secret hygiene

```sh
git diff --check
git status --short --untracked-files=all
```

Before any commit or deployment, inspect the exact diff and scan tracked files
for environment files, authorization headers, OpenAI key prefixes, generated
device tokens, `.vercel/`, and build output. Staging, committing, pushing, and
Production promotion require their own explicit user authorization.

## 7. Expected File Boundaries

Likely Swift ownership:

```text
Sources/LumiApplication/Ports/DeviceAuthorizationStore.swift
Sources/LumiApplication/UseCases/DeviceAuthorizationController.swift
Sources/LumiApplication/Ports/VoiceSessionPort.swift
Sources/LumiInfrastructure/Voice/VercelOpenAIRealtimeClientSecretSource.swift
Sources/LumiInfrastructure/Persistence/KeychainDeviceAuthorizationStore.swift
Sources/LumiPresentation/DeviceSetupModel.swift
Package.swift
App/LumiApp/Sources/LumiAppApp.swift
App/LumiApp/Sources/SessionSimulationModel.swift
App/LumiApp/Sources/SimulatorControlsView.swift
App/LumiApp/Sources/DeviceSetupView.swift
App/LumiAppTests/AppCompositionTests.swift
App/LumiAppTests/SessionSimulationModelTests.swift
App/LumiApp.xcodeproj/project.pbxproj
App/LumiApp.xcodeproj/xcshareddata/xcschemes/LumiApp-Live.xcscheme
```

Likely broker ownership:

```text
Broker/api/realtime/client-secret.ts
Broker/src/clientSecretHandler.ts
Broker/src/configuration.ts
Broker/tests/clientSecretHandler.test.ts
Broker/tests/configuration.test.ts
Broker/scripts/generate-device-token.ts
Broker/tests/generate-device-token.test.ts
Broker/package.json
Broker/package-lock.json
Broker/tsconfig.json
Broker/vercel.json
Broker/.env.example
.gitignore
docs/runbooks/phase-2.3-live-voice-operations.md
```

The approved task list must split these into S/M-sized units, keep shared
contract files sequential, and assign non-overlapping ownership if the product
owner again requests Luna delegation.

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Secret appears in source, logs, tests, or tool output | Critical | Human secret gate, sensitive Vercel variables, injected marker tests, no raw deployment response output. |
| `SessionSimulationModel` mock assumptions break Live startup | High | Separate optional mock-control collaborator before composition; preserve coordinator as sole state owner. |
| Build-time Live wiring is only visually inspected | Medium | Add App tests for the compile-time descriptor, control capabilities, and live startup branch under both configurations. |
| HTTP/Vercel errors leak into UI or Application | High | One Application semantic authorization error; all other mapping and redaction inside Infrastructure. |
| Keychain token migrates or syncs | High | `WhenUnlockedThisDeviceOnly`, no synchronizable flag/access group, namespace tests. |
| Rate limit is accidentally global or multi-region | High | Match allowlist first, use device digest as `rateLimitKey`, one `hnd1` region, deployed two-device check. |
| Vercel rule and code IDs differ | High | Fail-closed config, inspect published WAF rule, smoke-test `429` before device acceptance. |
| Preview alias changes | Medium | Explicit stable alias in tracked non-secret build config; verify endpoint in built plist. |
| Promotion uses wrong secrets | High | Separate Vercel environments, promotion gate, inspect environment names without reading values, post-promotion smoke. |
| Physical iPad behavior differs from fakes | High | Preview device checkpoint before Production; record permission, routes, echo, barge-in, reconnect, and speech quality. |
| App and broker contracts drift | Medium | Freeze one response fixture shape in independent Swift and TypeScript contract tests. |
| Vercel or OpenAI API changes | Medium | Implement from current official docs, exact npm lock, typed validation, and source review before dependency upgrades. |

## 9. Deferred Work

- App Attest / DeviceCheck
- QR provisioning and remote fleet administration
- database-backed device registry or global rate limiter
- multi-region broker failover
- real hardware and identity adapters
- local identity embedding persistence/sync design
- member-data tool calling
- runtime model/voice/persona selection
- Realtime timeout, VAD tuning, transcript recovery, and Avatar amplitude

## 10. Official References

- [OpenAI Realtime API with WebRTC](https://developers.openai.com/api/docs/guides/realtime-webrtc)
- [Vercel Node.js runtime](https://vercel.com/docs/functions/runtimes/node-js)
- [Vercel Function regions](https://vercel.com/docs/functions/configuring-functions/region)
- [Vercel Rate Limiting SDK](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting-sdk)
- [Vercel environment variables](https://vercel.com/docs/environment-variables)
- [Vercel Preview-to-Production promotion](https://vercel.com/docs/deployments/promote-preview-to-production)
- [Apple keychain accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)
- [Node.js test runner](https://nodejs.org/api/test.html)
