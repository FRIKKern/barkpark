<!-- doc-tier: human | canonical-for: teams-azure-bot-gate | budget: 2600tok -->
# Microsoft Teams — Azure Bot registration runbook (Connectors, the long-lead human gate)

Teams is one of the six first-focus Connectors channels, and the **heaviest onboarding pole** of the
group — an Azure AD app + a Bot Framework registration, none of which a script can create for you.
This runbook exists so that human cost can start **in parallel with P0** and gate nothing in the build:
the whole Teams flow is **code-dark until P3b**, so all P0 needs from Teams is the identity pair
(`teams.app_id` + `teams.app_password`) sitting in the drawer. No routing code ships here — the Teams
channel connector stays dark through the P0/P1/P2 waves precisely so this registration is the only
long-lead item between "planned" and "buildable." Design: `.claude/workflows/bp-connectors-charter.md`
(D3 heavy-pair onboarding), paper `/papers/personal-agent-provider-bridge`.

Product shape, for reference: Teams is an inbound **Channel connector** (you talk to the agent from
Teams; the agent runs sandboxed per workspace and streams back via `/v1/chat` SSE). Barkpark exposes
**one** shared multi-tenant Azure Bot; each customer org's Teams admin consents/installs it into their
own tenant; inbound activities carry the org's Teams tenant id, which maps to a Barkpark workspace —
the same `provider_team_id → workspace` shape Slack and Discord use (charter D9). The Bot Framework
adapter itself lives in the Vercel Chat SDK bridge (charter D4), not in the BEAM.

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

Azure Bot → **Configuration → Messaging endpoint**:

```
https://<public-host>/api/messages
```

`<public-host>` is the bridge's public HTTPS host. This is where Bot Framework POSTs inbound Teams
activities; the bridge validates the JWT (issued for the App ID) and hands the turn to the agent.
Until the bridge ships (P3b) this endpoint 404s — expected, code-dark.

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
  Slack (`team_id`) and Discord (`guild_id`) use (charter D9). That mapping is **code-dark until P3b**;
  this task produces the runbook + the identity pair, **not** the mapping code.

## Secrets to provision (workspace-scoped run-secrets)

Once steps 1–2 yield the identity pair, provision these under the workspace's run-secrets (the
encrypted run-secret mechanism is documented in [`PROD_OPS.md`](./PROD_OPS.md); secrets are stored
masked/password-typed). Per charter D9 these are **workspace-scoped** — each installing org's identity
and tenant map live under that workspace.

| Setting | Value | Notes |
|---|---|---|
| `teams.app_id` | MicrosoftAppId (App/client ID from step 1) | the bot identity |
| `teams.app_password` | client secret value from step 1 | **masked/secret** |
| `teams.tenant_id` | home tenant id of the AAD app | for token/authority config |
| `teams_tenant_id → workspace` | one map row **per installed org** | the org's Teams tenant id → its Barkpark workspace; added as each org onboards (step 7), not up front |

## Fakes-first: what this task delivers vs. what stays dark

This runbook and the resulting **app id / secret pair** are the deliverable. Everything downstream —
the Bot Framework adapter, the JWT validation on `/api/messages`, the `teams_tenant_id → workspace`
resolution, streaming replies back through `/v1/chat` — is **code-dark until P3b** (charter D3/D4).
Doing the Azure registration now means P3b starts with the credentials already in hand rather than
blocked on a multi-day Azure + Teams-admin loop. Blocks nothing in P0/P1/P2.
