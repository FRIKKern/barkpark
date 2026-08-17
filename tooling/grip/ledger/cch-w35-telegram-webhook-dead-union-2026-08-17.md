<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# Telegram mode:"webhook" is a dead union member — re-derivation recipe (wave 35)

VERDICT: REMOVE is safe. No named consumer forces the wire-it path. In webhook
mode Telegram is a total silent no-op (no poll, no HTTP route, no setWebhook).

Re-derive the three pillars:

1. The connector object never sets `webhook` (so index.ts:715 never mounts a route):
   `git show origin/main:connectors/src/connectors/telegram.ts | sed -n '410,466p' | grep -c 'webhook:'`  → 0

2. listen() early-returns in webhook mode (no polling either):
   `git show origin/main:connectors/src/connectors/telegram.ts | sed -n '482,484p'`  → `if (mode === "webhook") return;`

3. No setWebhook/route registration for telegram anywhere:
   `grep -rn 'setWebhook' connectors/src scripts/connectors`  → 0 (only vendor resetWebhook mentions in doc comments)

Consumers of the "webhook" token (all cosmetic/aspirational, none functional):
- telegram.ts:276  union member `"polling" | "webhook" | "auto"`
- telegram.ts:454  `mode` passed to vendor `createTelegramAdapter` (from @chat-adapter/telegram) — inert without a route feeding it
- telegram.ts:33/467/500  doc comments framing webhook as "a config value, not a code path"
- connectors/test/telegram-connector.test.ts:390-392  test PINS the no-op (asserts startCalls.length===0), does not prove webhook works
- connectors/docs/telegram-smoke.md:209  OVERSTATED: "the connector supports it; only polling is smoked" — false, it drops all traffic

Charter: no D-decision mandates telegram webhook mode. Telegram is polling-by-design
(D84 poll watchdog, D93/D94 single-owner lease). The generic webhook seam (D39
Connector.webhook?) exists for Discord/WhatsApp/Slack; Telegram never opts in.

Removal scope: delete union member + early-return + `mode` plumbing to adapter,
delete test 390-392, correct telegram-smoke.md:209. Wire-it path (setWebhook +
install-keyed route + lease) is a LARGER slice nothing currently forces.
