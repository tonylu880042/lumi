# ADR-0009 — Phase 2.3 Live Voice Broker and Device Provisioning

> Status: Accepted
> Date: 2026-08-12
> Decision owner: Curves Lumi Product Owner
> Scope: Live app composition, device authorization, credential broker, and release environments
> Related: `docs/phase-2.3-live-voice.md`,
> `docs/phase-2.3-live-voice-implementation-plan.md`, ADR-0007, and ADR-0008

## Context

Phase 2.2 completed a concrete WebRTC transport but intentionally left the App
on `MockVoiceSessionPort`. A Live composition requires short-lived credentials,
yet placing a standard OpenAI API key in an iPad binary would violate ADR-0007
and allow extraction and unbounded use.

The first Live pilot also needs a practical way to authorize and revoke a small
number of iPads without building the general Curves backend or the later member
identity system. The design must preserve a fully offline Mock app, keep member
data out of credential infrastructure, support deterministic tests, and permit
Preview validation before Production.

The product owner accepted this decision together with the Phase 2.3 technical
plan on 2026-08-12.

## Decisions

### 1. Use a dedicated compile-time Live app configuration

Keep `LumiApp` on Mock dependencies. Add a separately installable
`LumiApp-Live` scheme, `Debug-Live` / `Release-Live` configurations, and
`com.curves.lumi.live`. Live uses real voice with mock hardware and identity.
There is no runtime mode switch and no automatic fallback to Mock.

Subsequent owner amendment (44B, 2026-08-22): Debug-Live may replace only the
mock identity dependency with the local camera/Vision/Core ML/SQLite pilot.
Release-Live keeps anonymous/mock identity composition. This does not alter the
real-voice boundary, broker request, device authorization, or fallback policy.

**32A — Live configuration failure:** If the Live endpoint or environment is
missing or malformed at composition time, the app shows only
`語音服務尚未完成設定，請聯絡管理員。` It must not present setup/token UI,
perform any Keychain store operation, or fall back to Mock.

### 2. Use a minimal ephemeral-client-secret broker

Deploy a single-purpose TypeScript Vercel Function. It authenticates a device,
rate limits it, calls OpenAI's client-secret endpoint with a server-only
standard key, validates the response, and returns only `value` and `expiresAt`.
It does not proxy SDP/audio/conversation events or implement member APIs.

### 3. Provision revocable random device tokens

Provision each environment/iPad with a random 256-bit base64url token. Store
the raw value only in a this-device-only Keychain item. Store only SHA-256
digests in the Vercel allowlist. Environment updates and redeployment add or
revoke devices; no database or administrative UI is introduced.

On 2026-08-22, the product owner simplified the single-operator setup UX. The
App now accepts the one-time raw value only through SwiftUI's native paste
control after an explicit tap and immediately runs the existing validation and
Keychain save. It has no 43-character manual input field, token display, QR
flow, bundled credential, or new server-side activation system. This changes
only provisioning interaction; the broker authorization boundary is unchanged.

Revocation removes the digest from the allowlist. The broker keeps no revoked
digest or denylist and returns the same `401 unauthorized` response for a
missing, malformed, unknown, or removed token. It does not emit `403` in Phase
2.3 because an allowlist-only broker cannot distinguish an unknown token from a
previously authorized one. The App maps a future-compatible `403` to the same
device-reconfiguration semantic as `401`.

The matched digest is used as the privacy-preserving OpenAI safety identifier
and Vercel rate-limit key. It never represents a member and is not logged.

### 4. Keep authorization semantics inward and frameworks outward

Application owns provider-neutral device authorization values, the persistence
port, provisioning use case, and the semantic authorization-required voice
error. Infrastructure implements Keychain and broker HTTP adapters.
Presentation owns setup state. SwiftUI does not call Security, URLSession,
Vercel, OpenAI, or WebRTC directly.

Setup distinguishes actionable validation from retryable infrastructure
failure: invalid input uses `請輸入有效的裝置授權`, save/reset cancellation or
storage failure uses `裝置設定失敗，請再試一次`, and broker authorization
invalidation keeps the separate `裝置授權已失效` message.

### 5. Use Vercel WAF SDK rate limiting in one region

Apply the initial configurable 10-mints-per-60-seconds threshold with
`@vercel/firewall`, keyed by the authorized device digest. Run the Function in
one Tokyo `hnd1` region because Vercel documents rate-limit counters as
region-local. A global or multi-region limiter is deferred.

A WAF SDK check failure fails closed as `503 service_unavailable`, does not
call OpenAI, and remains transient on the App so the stored device token is not
removed. `502 upstream_failure` remains reserved for an OpenAI rejection or
invalid OpenAI response.

### 6. Isolate Preview and Production

Use separate OpenAI keys, raw device tokens, digest allowlists, Vercel
environment variables, broker URLs, and Keychain service namespaces.
`Debug-Live` targets a stable public Preview alias; `Release-Live` targets the
Production domain. Vercel Deployment Protection is disabled because the native
App authenticates with the broker's own Bearer credential.

Preview physical-iPad evidence and explicit product-owner approval are required
before Production promotion.

### 7. Send no member data to the broker

The broker request is bodyless and carries only the device Bearer token. It
does not receive member IDs, names, recognition results, face data, embeddings,
audio, transcripts, instructions, or model selection.

Before the following owner amendment, the approved App sent only the existing
generic returning-member/visitor greeting context directly to OpenAI. Local
member feature storage remains a later Identity milestone decision.

Amendment (2026-08-22): the owner approved a Debug-Live-only 44B field-pilot
exception. For a locally confirmed returning member, App composition may send
one `VoiceMemberAddress.spokenLabel` directly to OpenAI. The label accepts only
1–32 Unicode letters/numbers; unsafe, unknown, unmapped, and Release
paths remain anonymous. This does not send recognition confidence, biometric
features, profile fields, visit history, or exercise data and does not create a
member-management binding. The broker request remains bodyless and receives
none of this label or other member data.

The same validated label may appear in Debug-Live's local recognition
confirmation as `<spokenLabel>，歡迎回來～`, so the operator can verify the
identity-to-voice handoff before starting audio. Missing/unsafe labels,
unknown visitors, and Release remain anonymous.

## Alternatives Considered

### Store a standard OpenAI key in the App

Rejected because an installed client cannot protect a reusable standard key.
It would violate ADR-0007 and remove central revocation and spend control.

### Avoid every server-side component

Rejected because OpenAI's mobile ephemeral-token flow requires a trusted
server to use the standard key and mint the short-lived client credential. The
approved Vercel Function is the minimum server-side surface, not a general
backend.

### Proxy SDP through the broker

Rejected for this phase because the completed transport already performs
ephemeral-token SDP exchange directly with OpenAI. Proxying SDP would put the
broker on the media-session initialization path and require reworking Phase 2.2.

### Use a runtime Mock/Live switch

Rejected because it risks accidental fallback, complicates credential UX, and
does not allow both diagnostic apps to coexist. Compile-time composition keeps
the shipped dependency graph inspectable.

### Use Vercel Deployment Protection

Rejected because the native app would need a second bypass secret in addition
to its device credential. The public endpoint remains protected by its own
high-entropy authorization and rate limit.

### Use a database-backed device registry now

Rejected because the initial pilot needs only a small revocable allowlist.
Environment digests plus redeployment meet the approved operations contract
without creating retention, migration, or administration scope.

### Add App Attest now

Deferred. It can strengthen device authenticity later but requires separate
attestation lifecycle, failure, and operational policy decisions. It is not a
replacement for keeping the standard key server-side.

### Share credentials between Preview and Production

Rejected because a Preview compromise would cross the Production authorization
boundary. Environment isolation is worth the extra one-time provisioning.

## Consequences

- The repository gains a small Node/TypeScript project and npm lockfile in
  addition to the Swift package and Xcode app.
- Application and Presentation gain device-setup contracts but Domain remains
  unchanged.
- The App can exercise real voice while hardware and identity remain safely
  deterministic.
- Device addition or revocation requires a Vercel configuration change and
  deployment; this is acceptable for the initial pilot but not fleet scale.
- The broker is region-dependent and has no global failover.
- Production delivery includes external Vercel configuration and a physical
  device gate that cannot be satisfied by unit tests alone.
- App Attest, QR enrollment, a database registry, real identity, and member
  feature storage remain explicit later work.
