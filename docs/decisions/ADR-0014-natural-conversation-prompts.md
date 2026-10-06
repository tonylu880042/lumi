# ADR-0014 — Natural Realtime Conversation Prompt Policy

> Status: Accepted
> Date: 2026-09-06
> Decision owner: Curves Lumi Product Owner
> Scope: Realtime prompt wording for returning-member and visitor conversations
> Related: `SYSTEM_SPEC.md`, `docs/architecture.md`,
> `docs/transient-face-and-conversation-prompts.md`,
> `docs/decisions/ADR-0007-phase-2-realtime-voice-contract.md`,
> `docs/decisions/ADR-0011-phase-3-session-bound-member-tool.md`,
> `docs/decisions/ADR-0012-phase-3-conversation-direction.md`, and
> `docs/decisions/ADR-0013-conversational-face-enrollment.md`

## Context

The existing Realtime catalog gave Lumi a fixed opening sentence, optional
intimate titles, and a 35-character ceiling. Those constraints made every
arrival sound alike and could cause Lumi to add encouragement before responding
to what the visitor actually said. The prompt needs to guide natural turn
taking while keeping the existing privacy, tool, and enrollment contracts.

## Decision

### 1. Keep replies short while allowing necessary explanations

The default is 1–2 short, natural sentences in Taiwan Traditional Chinese.
There is no rigid character ceiling. Privacy, consent, safety, and other
necessary explanations may use enough words to remain clear.

### 2. Use only a confirmed volunteered label when one exists

For a returning member, a voluntarily provided and Application-validated
`VoiceMemberAddress.spokenLabel` is available as address data. Lumi may use it
naturally and sparingly. When no validated label exists, the returning-member
context uses a generic welcome-back meaning. Visitor contexts use a generic
greeting and do not invent names or intimate titles. No title preference is
stored.

### 3. Respond to context before encouragement

Each response first acknowledges the latest visitor utterance or situation.
Encouragement or a next step follows only when useful. Lumi avoids repeating an
opening greeting or address and leaves room for the visitor to respond.

### 4. Preserve existing safety and session boundaries

Opening greetings still call no tools. Weekly-summary data remains known-member
only and on-demand. Enrollment keeps its existing disclosure, clear affirmative
consent gate, three usable samples, no-photo statement, and naming-after-capture
order. The prompt change adds no member data, tool authorization, preference
storage, enrollment timing, or deterministic conversation state.

### 5. Treat the wording as guidance

These instructions guide the provider but cannot guarantee every generated
response. Naturalness therefore requires manual Debug-Live conversation
acceptance in addition to prompt and configuration tests.

## Alternatives Considered

### Keep a fixed opening and playful titles

Rejected. Repeating the same opener and assigning intimate titles makes the
welcome feel scripted and may not fit the visitor's preference or context.

### Keep a rigid character ceiling

Rejected. A hard limit can truncate privacy, consent, safety, or enrollment
explanations. Concision remains the default through the 1–2 sentence guidance.

### Add a persisted address or title preference

Rejected. The approved slice uses only an already confirmed volunteered label
and does not add a new stored preference or cross-session setting.

## Consequences

- Prompt copy remains centralized in
  `Sources/LumiInfrastructure/Voice/OpenAIConversationPrompts.swift`.
- Returning-member instructions can address a confirmed label without forcing
  it into every turn; anonymous returning and visitor contexts remain generic.
- Configuration and adapter tests can assert privacy, no opening tools, and the
  naturalness policy without claiming deterministic provider output.
- Physical audio and conversation testing remains required before treating the
  prompt policy as accepted field behavior.

## Pending Manual Conversational Acceptance Examples

These are scenarios for physical Debug-Live validation, not fixed scripts:

1. A known member with a confirmed label says she is tired. Lumi should first
   acknowledge that context, then offer a proportionate next step or
   encouragement; the label may be omitted if it would sound repetitive.
2. A known member without a confirmed label receives a brief generic welcome
   back, with no invented name or intimate title and no repeated opening after
   she answers.
3. An unknown visitor responds to a generic greeting with a question about
   being remembered. Lumi should provide the complete existing disclosure and
   ask for clear consent before any enrollment tool call; the three samples and
   naming step remain in their existing order.
4. A member asks for weekly exercise data after the opening. Lumi should answer
   the request with the on-demand known-member tool and avoid repeating the
   opening greeting or address.

The owner still needs to judge timing, interruption behavior, Taiwan Mandarin
delivery, and whether these responses feel comfortable in a real store.
