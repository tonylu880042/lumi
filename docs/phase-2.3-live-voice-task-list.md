# Curves Lumi — Phase 2.3 Live Voice Task List

> Status: Approved — implementation authorized through Task 17
> Date: 2026-08-12
> Decision owner: Curves Lumi Product Owner
> Related: `docs/phase-2.3-live-voice.md`,
> `docs/phase-2.3-live-voice-implementation-plan.md`, and
> `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`

## 1. Execution Rules

- No task begins until this task list is approved.
- Every production behavior follows RED → GREEN → REFACTOR. Record the focused
  failing command and expected failure before modifying production code.
- Toolchain-only scaffolding may verify an empty build without inventing a
  failing behavior test.
- A task is complete only after its focused verification and `git diff --check`
  pass.
- Checkpoints run the full relevant suites and both required unsigned App
  builds. Do not let multiple SwiftPM processes contend for the shared `.build`.
- Raw device tokens, OpenAI keys, short-lived client secrets, authorization
  headers, upstream bodies, and Vercel sensitive values must never appear in
  source, fixtures, tool output, chat, logs, screenshots, or documentation.
- No real Keychain, microphone, network, OpenAI, or Vercel access occurs in
  automated unit tests.
- `.vercel/`, `.env*` except the placeholder `.env.example`, `node_modules/`,
  coverage, build output, and Xcode-generated workspace state remain untracked.
- Staging, committing, pushing, Vercel project creation, secret entry, physical
  iPad actions, and Production promotion are explicit gates below; none is
  inferred from completing code.
- Existing Phase 2.2 changes belong to the user and must not be reverted or
  reformatted outside a task's owned lines.

## 2. Dependency Summary

| Task | Depends on | May run alongside |
| --- | --- | --- |
| 1 | none | 3 |
| 2 | 1 | 4 |
| 3 | none | 1 |
| 4 | 3 | 2 |
| 5 | 4 | 9, 10, 11 |
| 6 | 5 | 9, 10, 11 |
| 7 | 6 | 9, 10, 11 |
| 8 | 3 | 9, 10, 11 |
| 9 | 1 | 5–8, 10, 11 |
| 10 | 1, 2 | 5–9, 11 |
| 11 | 2 | 5–10 |
| 12 | 2, 11 | none on Xcode project files |
| 13 | 2, 12 | broker-only work |
| 14 | 11–13 | broker-only work |
| 15 | 9–14 | none on App files |
| 16 | 6–8 | final Swift-only checks |
| 17 | 1–16 | none; human source-control gate |
| 18 | 17 | none; external configuration gate |
| 19 | 18 | none; physical/deployment gate |
| 20 | 19 + explicit approval | none; Production gate |
| 21 | 20 | none; final reconciliation |

If the product owner requests Luna delegation, only tasks listed as parallel
may overlap. Workers must receive explicit non-overlapping file ownership and
must not stage, commit, deploy, or revert another worker's changes.

## 3. Stage A — Shared Contracts and Broker Foundation

### Task 1 — Device authorization value and store port

**Description:** Add the provider-neutral Application token value and
persistence boundary. This freezes the raw-token validation and redaction
contract before Keychain, HTTP, Presentation, or App code depends on it.

**Acceptance criteria:**

- [x] `DeviceAuthorizationToken` accepts only an unpadded base64url value that
  decodes to exactly 32 bytes and preserves the exact valid value internally.
- [x] String, debug, and reflection output contain `<redacted>` and never a
  supplied marker; the value is `Equatable` and `Sendable`.
- [x] `DeviceAuthorizationStore` exposes async load/save/remove without
  mentioning Keychain, Vercel, HTTP, OpenAI, environment names, or member data.

**Verification:**

- [x] RED then GREEN: `swift test --filter DeviceAuthorizationTokenTests`
- [x] Contract compiles in `LumiApplication` with no outer-framework import.
- [x] `git diff --check`

**Dependencies:** None.

**Files likely touched:**

- `Sources/LumiApplication/Ports/DeviceAuthorizationStore.swift`
- `Tests/LumiApplicationTests/DeviceAuthorizationTokenTests.swift`

**Estimated scope:** S — 2 files.

### Task 2 — Provisioning use case and semantic authorization error

**Description:** Add the Application controller used by setup Presentation and
the single provider-neutral error used to return an invalid/revoked device to
setup without exposing a broker status code.

**Acceptance criteria:**

- [x] The controller reports missing/provisioned status, validates and saves a
  token, and removes only the injected store's token.
- [x] Cancellation propagates without a later save/remove side effect, and
  storage failures remain typed, privacy-safe Application failures.
- [x] `VoiceSessionAuthorizationError.authorizationRequired` is payload-free,
  `Equatable`, and `Sendable`; no other HTTP failure enters Application.

**Verification:**

- [x] RED then GREEN: `swift test --filter DeviceAuthorizationControllerTests`
- [x] `swift test --filter VoiceSessionPortContractTests`
- [x] `git diff --check`

**Dependencies:** Task 1.

**Files likely touched:**

- `Sources/LumiApplication/UseCases/DeviceAuthorizationController.swift`
- `Sources/LumiApplication/Ports/VoiceSessionPort.swift`
- `Tests/LumiApplicationTests/DeviceAuthorizationControllerTests.swift`
- `Tests/LumiApplicationTests/VoiceSessionPortContractTests.swift`

**Estimated scope:** M — 4 files.

### Task 3 — Broker toolchain scaffold

**Description:** Create the minimal locked Node/TypeScript project and Vercel
single-region configuration. This task adds no request behavior.

**Acceptance criteria:**

- [x] `Broker/package.json` selects Node `24.x`, ESM, strict type checking,
  Node's test runner, and the current officially verified
  `@vercel/firewall` dependency; npm produces one lockfile.
- [x] `Broker/vercel.json` fixes exactly one `hnd1` region and introduces no
  route, redirect, protection bypass, or extra framework.
- [x] Repository ignores cover `.vercel/`, all non-example `.env*`,
  `node_modules/`, coverage, and broker build output without hiding source or
  the npm lockfile.

**Verification:**

- [x] `npm --prefix Broker install`
- [x] `npm --prefix Broker run typecheck`
- [x] `npm --prefix Broker test`
- [x] `git diff --check`

**Dependencies:** None.

**Files likely touched:**

- `Broker/package.json`
- `Broker/package-lock.json`
- `Broker/tsconfig.json`
- `Broker/vercel.json`
- `.gitignore`

**Estimated scope:** M — 5 files.

### Task 4 — Fail-closed broker configuration

**Description:** Parse and validate broker environment configuration without
retaining or exposing values. Freeze the digest-list and rate-limit-ID contract
before the handler exists.

**Acceptance criteria:**

- [x] Configuration accepts a nonempty API key, a nonempty comma-separated set
  of lowercase 64-hex SHA-256 digests, and a nonempty rate-limit ID.
- [x] Missing, duplicate, uppercase, malformed, or empty digest entries fail
  closed with one non-sensitive configuration category.
- [x] `.env.example` contains names and placeholders only; diagnostics and test
  output omit supplied key/digest markers.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="configuration"`
- [x] `npm --prefix Broker run typecheck`
- [x] `git diff --check`

**Dependencies:** Task 3.

**Files likely touched:**

- `Broker/src/configuration.ts`
- `Broker/tests/configuration.test.ts`
- `Broker/.env.example`

**Estimated scope:** M — 3 files.

## Checkpoint A — Foundation Gate

- [x] Tasks 1–4 focused tests are green.
- [x] `swift test` passes with no Security, URLSession, Vercel, or OpenAI use in
  Application tests.
- [x] Broker install, tests, type check, and build scripts pass.
- [x] Secret scan finds only approved variable names/placeholders and explicit
  redaction markers.
- [x] `git diff --check` and full untracked-file review pass.
- [x] App composition and external Vercel state remain unchanged.

## 4. Stage B — Credential Vertical Slices

### Task 5 — Broker method and device authentication

**Description:** Build the injectable handler through the method and
device-authentication boundary. Do not add rate limiting or OpenAI access yet.

**Acceptance criteria:**

- [x] Non-POST returns exact `405`; missing, repeated, wrong-scheme, malformed,
  unknown, or removed/revoked Bearer values return the indistinguishable exact
  `401 unauthorized`; the broker stores no revoked-token denylist and does not
  emit `403`.
- [x] Valid tokens are SHA-256 hashed and compared against every configured
  digest through a timing-safe comparator; raw tokens/digests never enter a
  response or diagnostic.
- [x] Every response has JSON content type and `Cache-Control: no-store`; the
  authorized seam exposes only the matched digest to later dependencies.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="method|authorization"`
- [x] Tests prove forbidden downstream dependencies are not called.
- [x] `npm --prefix Broker run typecheck && git diff --check`

**Dependencies:** Task 4.

**Files likely touched:**

- `Broker/src/clientSecretHandler.ts`
- `Broker/tests/clientSecretHandler.test.ts`

**Estimated scope:** S — 2 files.

### Task 6 — Per-device rate limit and OpenAI minting

**Description:** Complete the authorized handler path with the WAF seam, exact
fixed OpenAI request, response validation, and provider-minimal output.

**Acceptance criteria:**

- [x] The matched digest is the exact rate-limit key; a limited device receives
  `429 rate_limited` and OpenAI is never called.
- [x] A WAF rate-limit check failure fails closed as exact
  `503 service_unavailable`; OpenAI is never called and no marker leaks.
- [x] The authorized request uses the exact client-secret URL, standard key,
  JSON content type, matched digest safety identifier, `realtime`,
  `gpt-realtime-2.1-mini`, and `marin`; no client request data enters the body.
- [x] Only a nonempty `value` and finite future `expires_at` become
  `{ value, expiresAt }`; upstream non-2xx/malformed data maps to the approved
  `502` without provider body or marker leakage.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="rate limit|OpenAI|upstream|success"`
- [x] `npm --prefix Broker run typecheck`
- [x] `git diff --check`

**Dependencies:** Task 5.

**Files likely touched:**

- `Broker/src/clientSecretHandler.ts`
- `Broker/tests/clientSecretHandler.test.ts`

**Estimated scope:** S — 2 files.

### Task 7 — Vercel route composition

**Description:** Add the thin production route that loads fail-closed
configuration, calls `@vercel/firewall`, injects global fetch, and delegates to
the tested handler.

**Acceptance criteria:**

- [x] The route exports the current official Web-standard Vercel function
  signature and contains composition only.
- [x] Missing/malformed environment configuration returns exact
  `503 service_unavailable`; it never calls the rate limiter or OpenAI.
- [x] The configured WAF rule ID and matched device digest reach
  `checkRateLimit`; route errors are reduced to an approved envelope without
  stack/provider details.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="route composition"`
- [x] `npm --prefix Broker run typecheck`
- [x] `npm --prefix Broker run build`
- [x] `git diff --check`

**Dependencies:** Task 6.

**Files likely touched:**

- `Broker/api/realtime/client-secret.ts`
- `Broker/src/clientSecretHandler.ts`
- `Broker/tests/routeComposition.test.ts`

**Estimated scope:** M — 3 files.

### Task 8 — Deterministic device-token generator

**Description:** Add the operator tool that produces one 256-bit base64url
token and its lowercase SHA-256 digest, with injectable randomness for tests.

**Acceptance criteria:**

- [x] Exactly 32 random bytes produce a 43-character unpadded base64url token
  and matching 64-character lowercase hex digest.
- [x] Tests inject fixed bytes and never contain a real provisioned credential;
  failure output does not repeat partially generated material.
- [x] The package exposes a documented operator command, but the agent does not
  run it for real Preview/Production provisioning.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="token generator"`
- [x] `npm --prefix Broker run typecheck`
- [x] `git diff --check`

**Dependencies:** Task 3.

**Files likely touched:**

- `Broker/scripts/generate-device-token.ts`
- `Broker/tests/generate-device-token.test.ts`
- `Broker/package.json`

**Estimated scope:** M — 3 files.

### Task 9 — Keychain device-authorization store

**Description:** Implement the Application store with exact iOS Keychain
intent behind an injected Security seam so package tests make no real Keychain
calls.

**Acceptance criteria:**

- [x] Save/load/remove use generic-password items, the injected service, one
  fixed account, `WhenUnlockedThisDeviceOnly`, non-synchronizable storage, and
  no access group.
- [x] Preview and Production service fixtures never collide; update, not-found,
  duplicate, cancellation, and OSStatus failures map to redacted typed errors.
- [x] Raw tokens and backend markers are absent from descriptions, debug output,
  reflection, and failed-operation recordings.

**Verification:**

- [x] RED then GREEN: `swift test --filter KeychainDeviceAuthorizationStoreTests`
- [x] iOS SDK type check covers the real Security implementation.
- [x] `git diff --check`

**Dependencies:** Task 1.

**Files likely touched:**

- `Sources/LumiInfrastructure/Persistence/KeychainDeviceAuthorizationStore.swift`
- `Tests/LumiInfrastructureTests/KeychainDeviceAuthorizationStoreTests.swift`

**Estimated scope:** S — 2 files.

### Task 10 — Vercel client-secret source

**Description:** Implement the bodyless Swift broker client behind an injected
data-loader seam and return the existing short-lived credential value.

**Acceptance criteria:**

- [x] The exact configured endpoint receives `POST`, Bearer device token,
  JSON accept header, no request body, and no model/instructions/member data.
- [x] `200` decodes only nonempty `value` plus finite future `expiresAt` Unix
  seconds; malformed/expired responses fail before WebRTC startup.
- [x] Broker `401` and future-compatible `403` map to the Application
  authorization-required error; `429`, transport, cancellation, `5xx`, and
  invalid data preserve approved behavior without deleting the token or leaking
  request/response markers.

**Verification:**

- [x] RED then GREEN: `swift test --filter VercelOpenAIRealtimeClientSecretSourceTests`
- [x] Cancellation test proves the injected loader observes cancellation.
- [x] `git diff --check`

**Dependencies:** Tasks 1 and 2.

**Files likely touched:**

- `Sources/LumiInfrastructure/Voice/VercelOpenAIRealtimeClientSecretSource.swift`
- `Tests/LumiInfrastructureTests/VercelOpenAIRealtimeClientSecretSourceTests.swift`

**Estimated scope:** S — 2 files.

## Checkpoint B1 — Broker Runtime Gate

- [x] Tasks 5–8 focused tests pass.
- [x] `npm --prefix Broker test`
- [x] `npm --prefix Broker run typecheck`
- [x] `npm --prefix Broker run build`
- [x] No test performs real rate-limit, Vercel, OpenAI, or secret operation.
- [x] Exact API success/error contract matches the independently approved Swift
  fixtures.

## Checkpoint B2 — Swift Credential Gate

- [x] Tasks 9–10 focused tests pass on macOS with fakes.
- [x] Real iOS Security and URLSession code type-checks in the unsigned App
  build without accessing Keychain or network.
- [x] `swift test` passes.
- [x] Marker scan and `git diff --check` pass.
- [x] No layer outside Infrastructure imports Security or URLSession.

## 5. Stage C — Setup and Dual App Composition

### Task 11 — Presentation setup model

**Description:** Add testable setup state and actions in Presentation, using
the Application provisioning controller and never reading a saved secret for
display.

**Acceptance criteria:**

- [x] First load maps missing to setup and provisioned to ready; save transitions
  setup → saving → ready and clears the transient field.
- [x] Empty/invalid input remains in setup with exact
  `請輸入有效的裝置授權` validation;
  save/reset cancellation and storage failures leave deterministic retryable
  state with exact `裝置設定失敗，請再試一次` and without secret text in errors.
- [x] Authorization invalidation displays exact `裝置授權已失效`; confirmed
  reset removes only the injected current-environment store and returns setup.

**Verification:**

- [x] RED then GREEN: `swift test --filter DeviceSetupModelTests`
- [x] `swift test --filter LumiPresentationTests`
- [x] `git diff --check`

**Dependencies:** Task 2.

**Files likely touched:**

- `Package.swift`
- `Sources/LumiPresentation/DeviceSetupModel.swift`
- `Tests/LumiPresentationTests/DeviceSetupModelTests.swift`

**Estimated scope:** M — 3 files.

### Task 12 — Live build configurations and App test harness

**Description:** Add compile-time runtime descriptors, both Live build
configurations, the shared Live scheme, and a small App unit-test target before
changing composition behavior.

**Acceptance criteria:**

- [x] `Debug-Live`/`Release-Live` inherit Debug/Release, define only
  `LUMI_LIVE`, use `com.curves.lumi.live`, and expose non-secret broker
  endpoint/environment plist keys; Mock settings remain unchanged.
- [x] `LumiApp-Live` Run/Test/Analyze uses `Debug-Live`, Profile/Archive uses
  `Release-Live`, and both schemes include `LumiAppTests`.
- [x] The pure descriptor reports Mock under Debug and Live Preview under
  Debug-Live; endpoint absence is a typed configuration failure, never Mock
  fallback. Actual external URLs remain unset until Task 18.

**Verification:**

- [x] RED then GREEN App composition tests under both build configurations.
- [x] Both schemes build unsigned for generic iOS Simulator.
- [x] `git diff --check`

**Dependencies:** Tasks 2 and 11.

**Files likely touched:**

- `App/LumiApp/Sources/AppRuntimeConfiguration.swift`
- `App/LumiApp/Info-Live.plist`
- `App/LumiAppTests/AppCompositionTests.swift`
- `App/LumiApp.xcodeproj/project.pbxproj`
- `App/LumiApp.xcodeproj/xcshareddata/xcschemes/LumiApp.xcscheme`
- `App/LumiApp.xcodeproj/xcshareddata/xcschemes/LumiApp-Live.xcscheme`

**Estimated scope:** M — 6 files.

### Task 13 — Dual-mode session wrapper

**Description:** Remove the concrete mock-voice assumption from the App model
while preserving every existing Mock simulator action and coordinator-owned
state transition.

**Acceptance criteria:**

- [x] Mock mode retains bounded pending-start detection, explicit readiness,
  injected events, cancellation, retry, and existing error copy unchanged.
- [x] Live mode simply awaits `AssistantSessionCoordinator.startVoiceSession`,
  never probes/completes a mock, and provider events remain coordinator-owned.
- [x] Authorization-required routes setup exactly once; ordinary/rate-limited
  failures keep the generic voice retry and do not invalidate authorization.

**Verification:**

- [x] RED then GREEN: focused `LumiAppTests/SessionSimulationModelTests` under
  Mock and Live build configurations.
- [x] Existing `AssistantSessionCoordinatorTests` and Mock voice tests pass.
- [x] `git diff --check`

**Dependencies:** Tasks 2 and 12.

**Files likely touched:**

- `App/LumiApp/Sources/SessionSimulationModel.swift`
- `App/LumiAppTests/SessionSimulationModelTests.swift`

**Estimated scope:** S — 2 files.

### Task 14 — Setup screen and root routing

**Description:** Implement first-run secure paste, reset confirmation, and
ready/setup routing without letting SwiftUI call Keychain or network adapters.

**Acceptance criteria:**

- [x] Missing authorization shows a light-theme Setup screen with `SecureField`
  paste/save behavior; the stored value is never rendered back or copied into
  accessibility text.
- [x] Ready shows the existing App content; authorization invalid returns setup
  with approved copy; there is no Mock fallback or QR affordance.
- [x] Development-only `解除裝置設定` requires confirmation, resets only the
  current namespace through Presentation, and does not erase on `429`/transient
  failure.

**Verification:**

- [x] RED then GREEN root-routing App tests with a fake setup model/controller.
- [x] Accessibility labels contain no token marker.
- [x] Mock and Live unsigned builds pass; `git diff --check` passes.

**Dependencies:** Tasks 11–13.

**Files likely touched:**

- `App/LumiApp/Sources/DeviceSetupView.swift`
- `App/LumiApp/Sources/AppRootView.swift`
- `App/LumiApp/Sources/ContentView.swift`
- `App/LumiAppTests/AppRootRoutingTests.swift`

**Estimated scope:** M — 4 files.

### Task 15 — Concrete Live composition and control capabilities

**Description:** Wire Keychain → broker source → Realtime adapter → WebRTC
factory in Live and preserve the complete offline Mock composition.

**Acceptance criteria:**

- [x] Live constructs fresh concrete dependencies explicitly with default
  approved Realtime configuration, mock hardware, and mock identity; no global
  service or standard key exists.
- [x] Mock constructs the existing mock voice and remains network/microphone
  independent; missing/malformed Live configuration shows unavailable/setup
  behavior and never constructs Mock voice.
- [x] Live retains `啟動語音` but omits artificial speech-start, speech-end,
  response-ready, and voice-failure controls from its view tree; Mock retains
  them.

**Verification:**

- [x] RED then GREEN App composition/control-capability tests under both
  schemes.
- [x] `swift test`
- [x] Both schemes' App tests pass against an available iOS Simulator.
- [x] Both required unsigned generic Simulator builds pass.
- [x] `git diff --check`

**Dependencies:** Tasks 9–14.

**Files likely touched:**

- `App/LumiApp/Sources/LumiAppApp.swift`
- `App/LumiApp/Sources/AppRuntimeConfiguration.swift`
- `App/LumiApp/Sources/SimulatorControlsView.swift`
- `App/LumiAppTests/AppCompositionTests.swift`
- `App/LumiAppTests/SimulatorControlCapabilitiesTests.swift`

**Estimated scope:** M — 5 files.

## Checkpoint C1 — Presentation and App Seam Gate

- [x] Tasks 11–13 tests pass.
- [x] Mock behavior remains byte-for-byte compatible at Application port
  boundaries and uses no real external service.
- [x] Live startup path contains no mock pending/readiness operation.
- [x] Package boundaries remain UI → Presentation → Application → Domain, with
  Infrastructure implementing Application ports.

## Checkpoint C2 — Dual App Gate

- [x] Tasks 14–15 App tests pass under Mock and Live configurations.
- [x] `swift test`
- [x] `npm --prefix Broker test && npm --prefix Broker run typecheck && npm --prefix Broker run build`
- [x] Unsigned `LumiApp` and `LumiApp-Live` generic Simulator builds pass.
- [x] Artificial voice controls are absent from Live and present in Mock.
- [x] Build products/plists contain only approved non-secret settings.
- [x] Xcode-generated workspace state is removed if it did not exist before the
  builds; no user-owned project file is deleted.
- [x] Full diff, status, secret scan, and `git diff --check` pass.

## 6. Stage D — Release Preparation and Preview

### Task 16 — Redacted deployment smoke tool and runbook

**Description:** Add a tested operator smoke command that validates status and
schema without printing a credential response, plus the Preview/Production
configuration, revocation, rollback, and evidence procedure.

**Acceptance criteria:**

- [x] The smoke tool accepts endpoint/device token through environment only,
  checks unauthorized/authorized/rate-limit scenarios, consumes response bodies
  in memory, and prints status/category/schema booleans only.
- [x] Tests inject fetch and prove token, Authorization, client-secret, and
  upstream markers never reach stdout/stderr or thrown diagnostics.
- [x] The runbook separates Preview and Production, documents WAF rule ID and
  10/60 setting, token generation handoff, revocation redeploy, alias, rollback,
  log redaction, and both human gates without embedding a value.

**Verification:**

- [x] RED then GREEN: `npm --prefix Broker test -- --test-name-pattern="smoke"`
- [x] `npm --prefix Broker run typecheck && npm --prefix Broker run build`
- [x] Documentation and secret hygiene review; `git diff --check`.

**Dependencies:** Tasks 6–8.

**Files likely touched:**

- `Broker/scripts/smoke-client-secret.ts`
- `Broker/tests/smoke-client-secret.test.ts`
- `Broker/package.json`
- `docs/runbooks/phase-2.3-live-voice-operations.md`

**Estimated scope:** M — 4 files.

### Task 17 — Final automated review and source-control gate

**Description:** Reconcile all code against the approved spec/ADR, run complete
automated gates, and stop for explicit source-control direction before any
external deployment.

**Acceptance criteria:**

- [x] Multi-axis review finds no Clean Architecture violation, raw secret,
  unsafe log/reflection, accidental Mock fallback, unbounded dependency, or
  user-owned change overwritten; actionable findings are fixed via regression
  tests first.
- [x] Every Task 1–16 acceptance test and Checkpoint A–C command is green from a
  clean process state, with exact results recorded without secret values.
- [x] The product owner chose the source-control action. **33A
  (2026-08-13):** staging and a local checkpoint commit are authorized; push
  is not authorized. Preview and Task 18 remain stopped; no deployment has
  occurred.

**Verification:**

- [x] Full Swift, Broker, App-test, and both App-build gates.
- [x] `git diff --check` and explicit status/untracked review.
- [x] No `.vercel`, `.env`, Node/Xcode build output, or credential-like tracked
  content.

**Dependencies:** Tasks 1–16.

**Files likely touched:** Only regression fixes within the owning task files;
otherwise none. Review evidence goes to the task list after implementation.

**Estimated scope:** S review gate; any larger fix returns to its owning task.

**Automated evidence:** Broker 43 tests passed; typecheck/build passed; audit
reported 0 high vulnerabilities. Swift recorded 317 tests and 21 suites plus
4 snapshot tests. App Debug and Debug-Live each recorded 38 tests and 4 suites.
Unsigned Mock Debug, Live Debug-Live, and Live Release-Live builds passed.
Plist, secret, status, diff, and generated-workspace checks were clean.
Automated gate collection itself performed no deployment or external action;
the 33A local stage/commit authorization and result are documented above. No
push or deployment occurred.

### Task 18 — Vercel project, secret/configuration gate, and Preview deployment

**Description:** After source-control direction, create/link the broker project,
let the product owner enter sensitive values without exposing them, publish the
WAF rule, deploy Preview, assign its stable alias, and wire tracked non-secret
App endpoints.

**Acceptance criteria:**

- [ ] The Vercel project uses `Broker/`, Node 24, `hnd1`, public Preview access,
  and separate Preview/Production environment scopes; `.vercel/` remains
  ignored and untracked.
- [ ] The product owner independently enters different OpenAI keys, device
  digest allowlists, and matching WAF rule configuration for both environments;
  the agent neither receives nor prints raw values.
- [ ] Preview deployment is READY at a stable alias; `Debug-Live` contains the
  exact public Preview endpoint, `Release-Live` the stable Production endpoint,
  and both builds contain no credential or protection bypass.

**Verification:**

- [ ] Inspect deployment/source/environment names and WAF metadata without
  reading sensitive values.
- [ ] Unauthorized Preview smoke returns exact no-store `401`.
- [ ] Both unsigned App builds pass after endpoint configuration.
- [ ] `git status` proves `.vercel/` and generated files are untracked/ignored.

**Dependencies:** Task 17 plus explicit source-control and human secret gates.

**Files likely touched:**

- `App/LumiApp.xcodeproj/project.pbxproj` for non-secret endpoints
- external Vercel project/environment/firewall state

**Estimated scope:** S repository change plus external operational work.

### Task 19 — Preview smoke and physical-iPad acceptance

**Description:** Validate the deployed contract and approved real voice matrix
without exposing response credentials. This task requires product-owner access
to the physical iPad and real environment.

**Acceptance criteria:**

- [ ] Redacted smoke verifies valid mint shape, exact `401` for unknown and
  removed/revoked devices, per-device 10/60 `429`, no-store headers, and
  redacted Vercel logs.
- [ ] `Debug-Live` verifies first-run paste/persistence, microphone permission,
  built-in/external routes, initial-only greeting, listening/response/barge-in,
  one reconnect without greeting replay, and reconfiguration after revocation.
- [ ] Known/unknown mock identity produces only generic returning/visitor
  context; observed Taiwan Mandarin quality and any accepted physical deferral
  are recorded without member or conversation data.

**Verification:**

- [ ] Product owner reviews Preview deployment ID/source checkpoint and the
  physical matrix.
- [ ] Evidence contains status/timing/category only, no raw token, client
  secret, transcript, audio, member identifier, or upstream body.
- [ ] Production remains unchanged.

**Dependencies:** Task 18.

**Files likely touched:**

- `docs/runbooks/phase-2.3-live-voice-operations.md` evidence section only
- external Preview deployment and physical iPad state

**Estimated scope:** S documentation plus manual acceptance.

## Checkpoint D — Preview Approval Gate

- [ ] Checkpoints A–C remain green after final endpoint wiring.
- [ ] Preview smoke and physical-iPad acceptance are complete or any deferral is
  explicitly approved and recorded.
- [ ] Preview exact deployment/source checkpoint and rollback target are known.
- [ ] No Production deployment or alias change has occurred.
- [ ] Ask the product owner for the exact approval: `核准 Phase 2.3 Production promotion`.

## 7. Stage E — Production and Closure

### Task 20 — Production promotion and smoke verification

**Description:** Only after the exact Checkpoint D approval, promote the
reviewed source using Production environment values and verify the stable
Production path without printing credential material.

**Acceptance criteria:**

- [ ] Promotion rebuilds the reviewed source for Production and uses Production
  environment names, WAF rule, allowlist, and key without exposing values.
- [ ] Production unauthorized and authorized redacted smoke checks pass;
  `Release-Live` targets the exact Production endpoint and builds successfully.
- [ ] Preview remains separately authorized; rollback target is verified and no
  App token or Keychain namespace is shared between environments.

**Verification:**

- [ ] Vercel promotion status/inspect/log-category checks.
- [ ] Redacted smoke command succeeds against Production.
- [ ] `Release-Live` unsigned build and App tests pass.
- [ ] Final tracked/untracked/secret review passes.

**Dependencies:** Task 19 and explicit product-owner Production approval.

**Files likely touched:** External Production deployment state and runbook
evidence only.

**Estimated scope:** S operational gate.

### Task 21 — Final reconciliation and Phase 2.3 handoff

**Description:** Record actual implementation/deployment evidence, reconcile
all documentation, and perform final quality review without silently marking
deferred acceptance complete.

**Acceptance criteria:**

- [ ] Feature spec, implementation plan, task list, ADR-0009, roadmap, and
  runbook agree on actual files, tests, deployment IDs/categories, environment
  separation, physical results, and explicit deferrals.
- [ ] Status becomes Complete only if every non-deferred exit criterion and
  Production smoke is satisfied; otherwise status names the exact remaining
  gate.
- [ ] Final review confirms no standard API key, raw device token, short-lived
  secret, transcript, member data, `.vercel/`, environment file, or build output
  is tracked.

**Verification:**

- [ ] `swift test`
- [ ] `npm --prefix Broker test && npm --prefix Broker run typecheck && npm --prefix Broker run build`
- [ ] Both schemes' App tests and unsigned Simulator builds.
- [ ] `git diff --check` and full status/secret scan.

**Dependencies:** Task 20.

**Files likely touched:**

- `docs/phase-2.3-live-voice.md`
- `docs/phase-2.3-live-voice-implementation-plan.md`
- `docs/phase-2.3-live-voice-task-list.md`
- `docs/decisions/ADR-0009-phase-2.3-live-voice-broker.md`
- `docs/roadmap.md`

**Estimated scope:** M — 5 files.

## Checkpoint E — Completion Gate

- [ ] Tasks 1–21 and every checkpoint have recorded evidence.
- [ ] Mock and Live apps coexist and use the approved compile-time dependency
  graphs.
- [ ] Preview and Production credentials, endpoints, WAF buckets, and Keychain
  namespaces are isolated.
- [ ] Real Live voice succeeds with no standard key in the App and no member
  identity data in the broker.
- [ ] Complete Swift, Broker, App-test, Simulator-build, secret, whitespace, and
  operational smoke gates pass.
- [ ] Deferred App Attest, QR, database registry, real hardware/identity,
  member-data tools, timeout/VAD/amplitude work remains clearly future scope.

## 8. Parallelization and Ownership

After Tasks 1–4 freeze shared contracts, safe independent lanes are:

```text
Broker lane:          Tasks 5 → 6 → 7, with Task 8 alongside
Swift Infrastructure: Tasks 9 and 10
Presentation lane:    Task 11
```

Tasks 12–15 are sequential because they share Xcode/App composition state.
Tasks 16–21 are sequential review or external gates. If Luna workers are later
requested, each lane receives explicit owned files and the root agent reviews
every checkpoint before releasing the next dependency.

## 9. Approval Gate

Approval of this document authorizes only the ordered implementation scope in
Tasks 1–17. Task 18 additionally requires source-control direction and human
secret/configuration participation. Task 19 requires physical-iPad cooperation.
Task 20 always requires the separate explicit Production-promotion approval
named in Checkpoint D.
