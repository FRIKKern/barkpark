<!-- doc-tier: human | canonical-for: teams-azure-bot-gate | budget: 2600tok -->
# Microsoft Teams — Azure Bot registration runbook (Connectors, the long-lead human gate)

Teams is one of the six first-focus Connectors channels, and the **heaviest onboarding pole** of the
group — an Azure AD app + a Bot Framework registration, none of which a script can create for you.
**The code shipped in P3b** (`connectors/src/connectors/teams.ts`: adapter, tenant routing, registry
entry, smoke harness). What is left is exactly this runbook: the Azure registration, and — once per
customer org, irreducibly — that org's own Teams admin consenting inside their tenant. The cost of
Teams was never the code; it is the onboarding. Design: `.claude/workflows/bp-connectors-charter.md`
(D3 heavy-pair onboarding, D42 one-operator-app), paper `/papers/personal-agent-provider-bridge`.

Product shape, for reference: Teams is an inbound **Channel connector** (you talk to the agent from
Teams; the agent runs sandboxed per workspace and streams back via `/v1/chat` SSE). Barkpark exposes
**one** shared multi-tenant Azure Bot; each customer org's Teams admin consents/installs it into their
own tenant; inbound activities carry the org's Teams tenant id, which maps to a Barkpark workspace —
the same `provider_team_id → workspace` shape Slack uses (charter D29). The Bot Framework adapter
itself lives in the Vercel Chat SDK bridge (charter D4), not in the BEAM.

## The irreducible human/browser gates

Like the GitHub bridge's "two browser clicks," Teams has moments **no CLI can do for you** — they are
Azure-portal and Teams-admin browser actions, and they are the whole reason this task is long-lead:

1. **Create the AAD app registration + client secret** (Azure Portal, browser — steps 1).
2. **Create the Azure Bot resource, type Multi Tenant** (Azure Portal, browser — step 2).
3. **Each customer org's Teams admin approves the app** — org-catalog upload or sideload — inside
   *their* tenant (step 7). Barkpark cannot do this on a customer's behalf; consent is per-org, by
   design of Azure multi-tenant + Teams admin policy.

Steps 3–6 (endpoint, channel, manifest, packaging) are mechanical once 1–2 exist.

## 0. Prerequisites

- An Azure subscription with rights to create App registrations and an Azure Bot resource.
- A Microsoft 365 tenant with Teams, and **Teams admin** (to sideload/publish to the org catalog for
  dev, and later for each customer org's own admin).
- A public HTTPS host for the bridge's messaging endpoint (the Bot Framework requires HTTPS; Teams
  will not deliver to plain HTTP or to a bare IP).

## 1. Register the Azure AD / Entra ID app → MicrosoftAppId + secret

Azure Portal → **Microsoft Entra ID → App registrations → New registration**.

- **Supported account types**: *Accounts in any organizational directory (Multitenant)* — required so
  any customer org can consent. Do **not** pick single-tenant.
- After creation note the **Application (client) ID** — this is the **MicrosoftAppId** (`teams.app_id`).
- **Certificates & secrets → New client secret** → copy the secret **value** immediately (shown once).
  This is the **MicrosoftAppPassword** (`teams.app_password`, masked).

## 2. Create the Azure Bot resource — **type Multi Tenant**

Azure Portal → **Create a resource → Azure Bot**.

- **Type of App**: **Multi Tenant** — the correct choice for a Cloud multi-tenant SaaS bot (one bot,
  many customer orgs). Single-tenant and user-assigned-managed-identity are both wrong here.
- **Microsoft App ID**: reuse the app from step 1 (choose "Use existing app registration" and paste
  the App ID + secret). One identity, one bot.

## 3. Messaging endpoint

Azure Bot → **Configuration → Messaging endpoint** — the REAL one, as of P3b:

```
https://guerrilla.barkpark.cloud/connectors/webhooks/teams
```

This is where Bot Framework POSTs inbound Teams activities. The adapter validates the JWT (issued for
the App ID) and hands the turn to the agent; **an activity with no valid Bot Framework JWT is rejected
401 in ~2 ms, before any handler runs** — that is the shipped fail-closed behaviour, not a fault.

For a laptop smoke, run `cd connectors && npm run smoke:teams` (it prints exactly what is missing) and
point the endpoint at an HTTPS tunnel that forwards to it. Bot Framework will not deliver to plain
HTTP or to a bare IP.

## 4. Enable the Microsoft Teams channel

Azure Bot → **Channels → Microsoft Teams** → agree to terms → **Apply**. Without this, Teams will not
route to the bot even if the endpoint is set.

## 5. Teams app package — `manifest.json` + icons, zipped

A Teams app is a **zip**: `manifest.json` + a 192×192 color icon + a 32×32 outline icon. Skeleton:

```json
{
  "manifestVersion": "1.17",
  "id": "<TEAMS_APP_ID_GUID>",
  "name": { "short": "Barkpark", "full": "Barkpark Agent" },
  "developer": { "name": "Barkpark", "websiteUrl": "https://barkpark.cloud", "privacyUrl": "…", "termsOfUseUrl": "…" },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "bots": [
    {
      "botId": "<MicrosoftAppId from step 1>",
      "scopes": ["personal", "team", "groupchat"],
      "supportsFiles": false,
      "isNotificationOnly": false
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["<public-host>"]
}
```

- `id` is the **Teams app GUID** (a fresh GUID for the app listing — distinct from the `botId`).
- `bots[].botId` is the **MicrosoftAppId** (`teams.app_id`) from step 1.
- `scopes` **`personal`, `team`, `groupchat`** = 1:1 DM, channel, and group chat — the agent should be
  reachable in all three.
- **Icons**: `color.png` 192×192, `outline.png` 32×32 (transparent). Zip manifest + both icons at the
  archive root: `zip -j barkpark-teams.zip manifest.json color.png outline.png`.

## 6. Install: sideload (dev) OR org catalog OR AppSource

Three distribution paths, pick per audience:

- **Sideload (dev/test)**: Teams → **Apps → Manage your apps → Upload a custom app** → the zip. Fast,
  local, requires the tenant to allow custom-app uploads.
- **Org Teams App Catalog**: Teams Admin Center → **Teams apps → Manage apps → Upload** → the zip.
  The app becomes available org-wide; each org publishes its own copy.
- **AppSource (public listing)**: submit through Partner Center for Microsoft validation → a public,
  discoverable listing any org can add. Highest reach, longest lead (validation review).

## 7. Multi-tenant wiring — one bot, many orgs

**One shared multi-tenant Azure Bot + one Teams app package.** Barkpark does **not** register a bot per
customer. Instead:

- Each customer org's **Teams admin** installs the shared app (sideload or org catalog) and consents to
  the multi-tenant AAD app **in their own tenant** — the irreducible per-org human gate (see gate #3).
- Every inbound activity carries the org's **Teams tenant id** (`activity.channelData.tenant.id`).
- The bridge maps `teams_tenant_id → workspace` — the **same `provider_team_id → workspace` shape**
  Slack (`team_id`) uses (charter D29). That mapping SHIPPED in P3b: `connectors/src/connectors/teams.ts`,
  `tenantResolution: "payload-team-id"`, one row per org in `chat_bridge.connector_installs`.

## Credentials — ONE operator app, NOT per workspace (charter D42)

This section **supersedes** the earlier plan to store `teams.app_id` / `teams.app_password` as
*workspace-scoped* run-secrets. That was wrong, and the correction saves a week of OAuth work:

`TeamsAdapterConfig` is `apiUrl / appId / appPassword / appTenantId / appType / federated / logger /
userName`. There is **no `installationProvider`** and **no per-tenant credential map** (contrast Slack,
whose adapter takes one), and `appTenantId` is the **bot's own** Azure home tenant — never a customer's.
So with `appType: "MultiTenant"`, **one operator Azure app serves every customer org**, and the
customer's tenancy arrives in the payload.

| Setting | Where it lives | Notes |
|---|---|---|
| `TEAMS_APP_ID` | **operator process env** (one value, all tenants) | MicrosoftAppId from step 1 |
| `TEAMS_APP_PASSWORD` | **operator process env** | client secret from step 1 — **secret** |
| `connector_installs.install_key` | one row **per installed org** | the org's Microsoft **tenant id** |
| `connector_installs.credential_ref` | **NULL** | there is no per-workspace Teams secret to store |
| `connector_installs.chat_token_ref` | **required** | the workspace-bound `chat` ApiToken (D35) — this, not a Teams credential, is what isolates tenants |

There is therefore **no Add-to-Teams OAuth flow to build**. The per-org install is an act of that org's
own Teams admin inside their tenant (step 7); it hands Barkpark no token to keep.

Tenant precedence, in exactly one place (`teamsTenantId()` in `connectors/src/connectors/teams.ts`):

```
activity.conversation?.tenantId  ??  activity.channelData?.tenant?.id
```

The same function backs both the webhook's install-key extraction and the event's workspace
resolution. Two derivations with different precedence would be a confused-deputy vector — a payload
carrying both fields with different values would verify as one tenant and open a Session as another.

## Status — what is proven, and what is NOT

**Live Teams round-trip: NOT PASSED.** It cannot be proven from CI, and nobody should claim otherwise.

| | |
|---|---|
| Adapter + tenant routing + registry entry | **shipped** (P3b) — `connectors/test/teams-connector.test.ts` |
| Fail-closed on a missing Bot Framework JWT | **proven**: 401 in ~2 ms, no handler, no Session |
| A SUCCESSFUL Teams turn | **NOT PROVEN** — the JWT is signed by Microsoft; we cannot mint one |
| Runnable harness | `cd connectors && npm run smoke:teams` |

Everything between here and a live turn is the human gate: the Azure app, the secret, the Azure Bot
resource, the messaging endpoint, the Teams channel, the manifest — and, once per customer org and
irreducibly, **that org's own Teams admin consenting inside their tenant**. Barkpark can never do that
last one on a customer's behalf.
