# Phase 2.3 Live Voice Broker Operations

> Status: operator procedure; deployment evidence is intentionally blank until
> the Preview and Production human gates are completed.
>
> This runbook handles the narrow Vercel Function that mints short-lived
> OpenAI Realtime client secrets. It does not handle member data, identity
> recognition, audio, SDP, transcripts, or conversation logs.

## Safety boundary

The broker accepts only a bodyless `POST` with a device Bearer token. It
returns either the provider-minimal `{ "value", "expiresAt" }` envelope or a
fixed error envelope. The raw device token, its digest, the standard OpenAI
key, and every short-lived client secret are sensitive values.

Do not place a value in this file, source control, chat, tickets, screenshots,
shell history, Vercel logs, or smoke output. Do not create a local `.env` file
for this procedure. The smoke command reads its endpoint and token only from
the two environment variables below and prints static scenario labels and
booleans; it never prints a response body, status number, category, token, or
credential.

## Fixed deployment contract

| Item | Preview placeholder | Production placeholder |
| --- | --- | --- |
| Public broker endpoint | `<PREVIEW_ALIAS>/api/realtime/client-secret` | `<PRODUCTION_DOMAIN>/api/realtime/client-secret` |
| Vercel environment | `Preview` | `Production` |
| Function region | `hnd1` | `hnd1` |
| OpenAI model | `gpt-realtime-2.1-mini` | `gpt-realtime-2.1-mini` |
| Output voice | `marin` | `marin` |
| WAF rule identifier | `<PREVIEW_WAF_RULE_ID>` | `<PRODUCTION_WAF_RULE_ID>` |
| WAF threshold | 10 attempts per 60 seconds per matched device digest | 10 attempts per 60 seconds per matched device digest |
| Live app endpoint setting | `<PREVIEW_ALIAS>` | `<PRODUCTION_DOMAIN>` |
| Keychain service namespace | `<PREVIEW_KEYCHAIN_SERVICE>` | `<PRODUCTION_KEYCHAIN_SERVICE>` |

Preview and Production are separate authorization boundaries. Each has its own
OpenAI key, raw device tokens, SHA-256 digest allowlist, WAF rule, broker URL,
and Keychain service namespace. Deployment Protection is disabled for this
public native-app endpoint; the device Bearer credential and WAF rule are the
authorization boundary.

The WAF rule is configured outside this repository. The source configuration
contains only `LUMI_RATE_LIMIT_ID`, not the threshold or a device identity.
Counters are region-local, so keep the Function in the single approved
`hnd1` region.

## Human gate 1: secret and configuration handoff

An operator with access to the approved Vercel project performs this gate. The
agent and repository must not receive the sensitive values.

1. Generate one token per iPad and per environment using the documented
   command. Run it only in a controlled terminal where output can be handed off
   securely:

   ```sh
   npm --prefix Broker run generate-device-token
   ```

   The command emits one raw base64url token and its lowercase SHA-256 digest.
   Deliver the raw token directly to the selected iPad's Live setup screen and
   enter only the digest in that environment's
   `LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST`. Never copy either line into this
   repository or an issue/comment. Generate unrelated values for Preview and
   Production.

2. In Vercel, configure each environment independently:

   - `OPENAI_API_KEY` — sensitive standard OpenAI key for that environment.
   - `LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST` — comma-separated lowercase
     SHA-256 digests only.
   - `LUMI_RATE_LIMIT_ID` — the published WAF rule identifier placeholder from
     the table above.

   Verify the environment scope and variable names without reading values back
   into logs or evidence. Publish the WAF rule at 10 attempts per 60 seconds
   keyed by the matched device digest.

3. Deploy the selected source revision to the intended Vercel environment,
   keeping the Preview alias stable. Do not promote to Production during this
   gate. Confirm the endpoint is reachable without Deployment Protection and
   that the Function remains pinned to `hnd1`.

## Redacted smoke procedure

Run only after the corresponding environment has passed Human gate 1. Use a
fresh or deliberately known WAF window; the rate-limit portion may consume up
to ten successful short-lived mints and one additional attempt that should be
`429`. Do not run this command against Production until Human gate 2 has been
approved.

The command accepts no positional endpoint or token arguments. Set both values
in the operator's process environment, run it, then remove them from the
environment. The angle-bracket values are placeholders, not valid credentials.

```sh
export LUMI_SMOKE_ENDPOINT="<PREVIEW_ALIAS>/api/realtime/client-secret"
export LUMI_SMOKE_DEVICE_TOKEN="<PROVISIONED_PREVIEW_RAW_TOKEN>"
npm --prefix Broker run smoke-client-secret
unset LUMI_SMOKE_ENDPOINT LUMI_SMOKE_DEVICE_TOKEN
```

The Production form uses `<PRODUCTION_DOMAIN>` and a separately provisioned
Production token. Never reuse the Preview token or namespace.

The smoke tool performs these checks in order and stops after the first failed
boundary:

1. Missing authorization must produce the fixed unauthorized envelope.
2. The provisioned token must produce a `200` JSON response with nonempty
   `value` and a finite future `expiresAt` (camelCase only), plus `no-store`.
3. Additional authorized requests continue from that first successful mint,
   with an absolute maximum of 11 authorized requests total. The tenth
   successful mint should be followed by a `429` rate-limit envelope. The
   response bodies are consumed in memory and discarded.

Output is one JSON line containing only the static scenario labels
`unauthorized`, `authorized`, and `rate_limit`, and the booleans `statusOk`,
`categoryOk`, and `schemaOk`. A nonzero exit means a check failed. Copy only
that redacted line into evidence.

## Expected response categories

The broker's public error categories are fixed and contain no provider body:

| HTTP status | Category | Operator action |
| --- | --- | --- |
| `401` | `unauthorized` | Check the environment allowlist and token handoff; do not guess or retry with a different value. |
| `405` | `method_not_allowed` | Check the endpoint path and deployment revision. |
| `429` | `rate_limited` | Wait for the WAF window; retain the iPad token. |
| `502` | `upstream_failure` | Inspect only redacted Vercel category/timing logs; do not expose the OpenAI response. |
| `503` | `service_unavailable` | Check non-secret configuration and WAF availability; retain the iPad token. |

The smoke command intentionally reports only booleans, not these status or
category values. A `403` from a future-compatible broker is handled by the
Live app as device reconfiguration, but the Phase 2.3 broker itself emits
`401` for unknown and revoked tokens.

## Revocation and redeploy

Revocation is an environment configuration change followed by a deployment;
there is no denylist or administration API.

1. Identify the affected environment and iPad without copying its raw token
   into the record.
2. Remove only that device's digest from the environment's
   `LUMI_DEVICE_TOKEN_SHA256_ALLOWLIST`.
3. Deploy/redeploy the same reviewed source revision in that environment.
4. Verify the stable alias and environment name without reading sensitive
   variable values.
5. With the revoked token held only in the operator's secure process
   environment, run the redacted smoke check and confirm the unauthorized
   booleans. Do not record the token or response body.
6. The Live app should show `裝置授權已失效`; it must retain no automatic
   fallback to Mock. Provisioning a replacement requires a newly generated
   token and a new digest entry.

Preview revocation must not alter Production. Production revocation must not
alter Preview. Keep their Keychain namespaces and endpoint settings distinct.

## Rollback and alias recovery

If a deployment fails a smoke check or a physical Preview gate, stop promotion
and keep Production unchanged. Record only the source revision, deployment
identifier, alias, environment name, check booleans, and timing category.

1. Select the last reviewed READY deployment for the same environment.
2. Roll back or promote that deployment through the Vercel project controls;
   do not rebuild from an unreviewed working tree.
3. Confirm the stable Preview alias or Production domain points to the selected
   deployment and remains in `hnd1`.
4. Re-run the redacted smoke matrix with the environment's existing token. If
   the failure concerns authorization, rotate/revoke according to the section
   above rather than weakening the allowlist.
5. Do not change Live app endpoints or Keychain namespaces as a rollback
   shortcut. Production promotion remains blocked until the explicit gate.

## Log and evidence redaction

Vercel and local logs may contain only fixed error categories, HTTP timing, and
the deployment/source metadata needed for review. Before sharing evidence,
remove or redact:

- `Authorization` headers and raw device tokens;
- SHA-256 device digests and `OpenAI-Safety-Identifier` values;
- standard OpenAI keys and short-lived client-secret values;
- upstream response bodies, URLs with query data, stack traces, transcripts,
  audio, SDP, member identifiers, and identity data.

Never use `set -x`, shell history capture, request dump middleware, or a proxy
that records headers/body data for this endpoint. The broker response is
`Cache-Control: no-store`; do not paste it into tickets or chat.

## Human gate 2: Preview review and Production promotion

Production promotion requires both approvals below, in order:

1. The product owner reviews the Preview source revision, alias, redacted smoke
   line, WAF rule metadata, and physical-iPad evidence (setup persistence,
   microphone permission, greeting, listening/response, barge-in, reconnect,
   revocation, and Taiwan Mandarin quality).
2. The product owner explicitly approves the exact action:
   `核准 Phase 2.3 Production promotion`.

Only after that approval may the operator promote the same source revision to
Production. Vercel rebuilds it with Production environment values. Run the
Production unauthorized and authorized smoke checks, then confirm
`Release-Live` uses the Production endpoint. A build or smoke command alone is
not Production approval.

## Evidence template

Copy this template without adding sensitive values:

```text
Date/time: <UTC_TIMESTAMP>
Source revision: <SOURCE_REVISION>
Environment: Preview | Production
Deployment identifier: <DEPLOYMENT_IDENTIFIER>
Stable alias/domain: <ALIAS_OR_DOMAIN_NAME>
Function region: hnd1
WAF rule identifier: <WAF_RULE_ID_NAME_ONLY>
WAF setting confirmed: 10 attempts / 60 seconds / device digest
Smoke exit: 0 | 1
Unauthorized: statusOk=<true|false> categoryOk=<true|false> schemaOk=<true|false>
Authorized: statusOk=<true|false> categoryOk=<true|false> schemaOk=<true|false>
Rate limit: statusOk=<true|false> categoryOk=<true|false> schemaOk=<true|false>
Physical iPad gate: pending | passed | deferred with approval
Product-owner promotion approval: pending | received
Rollback target: <SOURCE_REVISION_OR_DEPLOYMENT_IDENTIFIER>
Sensitive values, response bodies, member data: not recorded
```

Do not mark a gate passed from a local fake. Local tests prove request shape,
bounded probing, and redaction; only the corresponding deployed environment
and approved physical iPad evidence satisfy operational acceptance.
