<!-- doc-tier: human | canonical-for: whatsapp-meta-gate | budget: 2600tok -->
# WhatsApp — Meta Business onboarding runbook (Connectors, the other long-lead human gate)

WhatsApp is the second half of the Connectors **heavy pair** (Teams is the first —
[`teams-azure-bot.md`](./teams-azure-bot.md)). Like Teams, its cost is **onboarding, not code**: the
adapter, tenant routing, registry entry and the 24-hour-window policy all shipped in P3b
(`connectors/src/connectors/whatsapp.ts`, `connectors/src/policy/whatsapp-window.ts`). What is left is
a chain of Meta approvals that no script can clear — one of which (**App Review**) is the difference
between a 5-recipient demo and a product.

Design: `.claude/workflows/bp-connectors-charter.md` (D3 heavy pair, D43 BYO-Meta-app + the 24h
window), paper `/papers/personal-agent-provider-bridge`.

## The two facts that shape everything

1. **Bring-your-own Meta app (D43).** Unlike Teams — where ONE operator Azure app serves every customer
   org — all four WhatsApp credentials are **per install**: `accessToken`, `appSecret`,
   `phoneNumberId`, `verifyToken`. So each workspace brings its own Meta app and its own number, the
   inbound path IS the tenant binding (`tenantResolution: "credential-bound"`), and every workspace
   walks this runbook itself.
2. **The 24-hour customer-service window is OUR policy.** Meta lets a business send **free-form**
   messages only within 24 h of the user's last inbound message. Outside it, only a **pre-approved
   template** is accepted. The adapter deliberately does not auto-substitute templates, so if we did
   nothing the window would be a production surprise. Instead it is a pure, unit-tested decision made
   *before* any API call: `decideWhatsappWindow()`. Outside the window a free-form send is **refused**
   — the caller either supplies an approved template explicitly, or gets a typed
   `outside-24h-window` drop. Nothing is ever silently rewritten into a template.

## The gate chain — in order, none of it scriptable

| # | Gate | Yields | Notes |
|---|---|---|---|
| 1 | **Meta Business verification** | — | Business Manager → Security Centre. Documents, days, sometimes a rejection. Everything below is blocked on it. |
| 2 | **WABA + a phone number** | `phoneNumberId` | A WhatsApp Business Account and a number that is **not** registered to the consumer WhatsApp app. The **id**, not the number, is the install key. |
| 3 | **System User token** | `accessToken` | Business Settings → Users → System users → Generate token, scopes `whatsapp_business_messaging` (+ `whatsapp_business_management`). |
| 4 | **Meta App Secret** | `appSecret` | App → Settings → Basic → App Secret. This verifies the HMAC on **every** inbound webhook. |
| 5 | **Webhook registration** | `verifyToken` | You choose the token; Meta GETs the callback with `hub.challenge` and expects it echoed **verbatim**. Callback: `https://guerrilla.barkpark.cloud/connectors/webhooks/whatsapp/<phone_number_id>` — HTTPS only. |
| 6 | **App Review → Advanced Access** | — | **The one that matters.** Without it the number can only message ~5 pre-registered *test* recipients. That is a demo, not a product. |
| 7 | **Per-template approval** | — | Every business-initiated message needs an approved template (see the 24 h window). Templates are reviewed one at a time. |

The install key is the **`phone_number_id`**, and it comes from the **URL path**, never the body:
the body's signature is verified with that install's `appSecret`, so letting the body choose which
install verifies it would let an attacker pick the secret they know. (Teams can safely do the
opposite — every Teams install verifies against the same operator JWT.)

## Store the credentials

One row per install in `chat_bridge.connector_installs`:

| Column | Value |
|---|---|
| `provider` | `whatsapp` |
| `install_key` | the `phone_number_id` (non-secret, and a PRIMARY KEY column) |
| `workspace_id` | the Barkpark workspace that owns this number |
| `credential_ref` | JSON: `{"accessToken":…,"appSecret":…,"verifyToken":…}` |
| `chat_token_ref` | the workspace-bound `chat` ApiToken (D35) |

**SEALED AT REST** (corrected 2026-07-14): both `credential_ref` and `chat_token_ref` hold
`Base64(iv‖tag‖ciphertext)` — AES-256-GCM, AAD-bound to this row's
`(provider, install_key, workspace_id)` (D35/D37, `connectors/src/crypto/credential-cipher.ts`).
Moving a sealed blob to another tenant's row makes it un-openable, so a stolen row is a dead
row, not a served one. The key is `CONNECTORS_CREDENTIAL_KEY` (missing ⇒ the bridge refuses to
boot; there is no plaintext fallback). Residual risk, stated plainly: ONE service-wide key
protects every tenant — a DB dump alone cannot impersonate a tenant's bot, but a key leak
compromises all of them. Per-workspace DEKs are backlog.

## Status — what is proven, and what is NOT

**Live WhatsApp round-trip: NOT PASSED.** It needs gates 1–6, and nobody should claim otherwise.

| | |
|---|---|
| Adapter + credential-bound tenant routing + registry entry | **shipped** — `connectors/test/whatsapp-connector.test.ts` |
| GET verification handshake | **proven**: matching `verifyToken` → `200` + the challenge echoed; wrong token → `403` |
| Inbound HMAC gate | **proven**: bad signature → `401`; no signature → `401` |
| Cross-tenant isolation | **proven**: a body signed with install A's App Secret is `401`-rejected by install B (and the same bytes are first shown to be genuinely live for A — the negative is not vacuous) |
| The 24-hour window | **proven** on fake timestamps, no live number: open at 23:59:59.999, **closed** at exactly 24:00:00.000; unknown last-inbound ⇒ closed; outside ⇒ free-form refused, template only if explicitly supplied |
| A real message from a real phone | **NOT PROVEN** — gates 1–6 |
| Runnable harness | `cd connectors && npm run smoke:whatsapp` (runs the self-checks with **no** Meta account, then prints exactly what is missing) |

## Smoke it

```bash
cd connectors && npm run smoke:whatsapp     # runs the offline self-checks + prints the gate

# with the gate cleared:
export WHATSAPP_PHONE_NUMBER_ID=… WHATSAPP_ACCESS_TOKEN=… \
       WHATSAPP_APP_SECRET=… WHATSAPP_VERIFY_TOKEN=… \
       BARKPARK_API_URL=… BARKPARK_CHAT_TOKEN=… DATABASE_URL=…
npm run smoke:whatsapp                      # serves the webhook; message the number
```

The harness prints `NOT PASSED` until a real message round-trips. It never prints a success it did not
observe.
