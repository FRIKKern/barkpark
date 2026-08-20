<!-- doc-tier: human | canonical-for: github-sync-provisioning | budget: 2000tok -->
# GitHub Bridge — provisioning runbook (wave 7, the human gate)

The `github` plugin is **code-complete and off by default**. Everything below is the one-time
human provisioning that lights it up: create a GitHub App, drop its secrets into the instance, make
a Projects v2 board, then flip the whitelist. No code ships here — the plugin has stayed dark through
six merged waves precisely so this gate is the only thing between "built" and "live".

Plugin surface, for reference: outbound mirror (task → issue), inbound intake (outsider issue → dark
`gh-<num>` task), adoption (`bp github adopt`), conflict quarantine, Projects v2 dashboard + relations,
and a `/admin/github` console + `bp github status`. Single source of truth is the ledger; GitHub is a
one-directional projection plus a low-trust intake funnel. Design: `.claude/workflows/bp-github-bridge-epic-charter.md`.

## Fast path (scripted)

Three helpers reduce this to two browser clicks. There is no `gh app create`, so App
creation uses the **App Manifest flow** — the script pre-fills a manifest and captures the
generated App ID / private key / webhook secret automatically.

```bash
# 1. Create the App (one browser click + pick the install repo). Writes creds to a file.
python3 scripts/github-app-bootstrap.py \
  --name "Barkpark Bridge FRIKKern" \
  --webhook-url https://guerrilla.barkpark.cloud/v1/plugins/github/webhook \
  --out ~/barkpark-github-app.json
# Then install the App on FRIKKern/barkpark and note the Installation ID (in the install URL).

# 2. (Optional) Projects v2 board + Status/Priority/Worker/Goal fields → prints the project_id.
gh auth refresh -s project            # one-time scope add
scripts/github-projects-setup.sh "Barkpark Bridge" @me

# 3. Provision the creds into the instance + verify it goes active.
scripts/github-provision-guerrilla.sh \
  --creds ~/barkpark-github-app.json --install <INSTALLATION_ID> \
  --repo FRIKKern/barkpark [--project <PVT_…>]
```

The two irreducible browser moments are inside step 1: clicking **Create GitHub App** on the
manifest page, and choosing which repo to install on. Everything else is scripted. If the board
lives on your user account, note that a GitHub App installation token can't write user-owned
Projects v2 — the board is created with your own `gh` token and the plugin projects onto it
(Projects failures are isolated; the mirror/intake/adopt loop is unaffected). The manual walkthrough
below is the fallback if you'd rather not run the scripts.

## 0. Prerequisites

- Admin on the target repo (**FRIKKern/barkpark**) and on the instance the ledger runs on
  (guerrilla; the encrypted run-secret mechanism is documented in [`PROD_OPS.md`](./PROD_OPS.md)).
- The instance can reach `api.github.com` outbound (the mirror is outbound HTTPS; the webhook is
  inbound to the instance's public URL).

## 1. Create the GitHub App

GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**.

- **Webhook URL**: `https://<instance-public-host>/v1/plugins/github/webhook`
- **Webhook secret**: generate a strong random string — you will paste it into the instance as
  `github.webhook_secret`. This is what the inbound signature plug verifies (X-Hub-Signature-256).
- **Repository permissions**: Issues **Read & write**, Pull requests **Read-only**, Contents
  Read-only, Metadata Read-only.
  For Projects v2: **Projects Read & write** (organization or user, matching where the board lives).
- **Subscribe to events**: **Issues** and **Pull requests**. Nothing else. Issues drives intake and
  the detach bookkeeping; Pull requests drives the merge-gate autostamp
  (`Plugins.Github.MergeEvents`) — without it that handler is never called and every
  `merge_gate:true` criterion waits for a human forever. `pull_request` cannot be subscribed
  without the Pull requests: Read permission above.

> **Updating an App that already exists.** `default_events` in
> `scripts/github-app-bootstrap.py` applies at CREATE time only — editing it does not touch an App
> already created from an older manifest. To add an event to a live App: App settings →
> *Permissions & events* → set the permission, tick the event, save — then the **installation must
> accept the new permission** (GitHub emails the installer a review link; until it is accepted the
> permission is pending and the event does not deliver). Verify with
> `scripts/merge-gate-autostamp-liveness.sh`, which reads the ledger for real bridge writes and is
> the only check here that can tell you the delivery path is actually alive.
- After creation: note the **App ID**; **generate a private key** (downloads a `.pem`).
- **Install the App** on FRIKKern/barkpark; note the **Installation ID** (in the install URL /
  `GET /app/installations`).

## 2. Create the Projects v2 board (optional but recommended)

The board is what turns the mirror into a dashboard. If you skip it, Projects sync no-ops cleanly
(the plugin is fully functional without it — issues still mirror).

- Create a **Projects v2** board (org or user scope matching the App's Projects permission).
- Add these **single-select / text fields** (names are matched case-insensitively by the projector):
  `Status`, `Priority`, `Worker` (single-select or text), `Goal` (text).
- Note the board's **node id** (`PVT_…`) — Settings → the GraphQL `id`, or via the API. This is
  `github.project_id`.

## 3. Provision the secrets into the instance

Six settings, under the `github` plugin settings row (Studio → plugin settings, or the settings API).
The two secrets are stored masked/password-typed.

| Setting | Value |
|---|---|
| `github.repo` | `FRIKKern/barkpark` |
| `github.app_id` | the App ID from step 1 |
| `github.installation_id` | the Installation ID from step 1 |
| `github.private_key` | the full `.pem` contents (secret, masked) |
| `github.webhook_secret` | the webhook secret from step 1 (secret, masked) |
| `github.project_id` | the Projects v2 board node id from step 2 (optional — blank = Projects off) |

Five are required (all but `project_id`); `validate_settings/1` fails closed if any required one is
missing or blank. On a cloud instance these ride the encrypted run-secret mechanism — see
`docs/ops/PROD_OPS.md`.

## 4. Flip the whitelist

Add `github` to `BARKPARK_PLUGINS` (comma-separated) and restart. Unset = all plugins; if the var is
already set, append `,github`. On boot the plugin registers its routes + supervises `Auth`
(lazy) and, when enabled, the `DrainWorker`.

## 5. Verify the round-trip

The plugin has only ever been proven against a mocked GitHub (Bypass). This is the first live contact
— watch for any unmocked-API surprise here.

1. **Health**: `bp github status` (or `/admin/github`) — `active: true`, `repo` set, cursor at head,
   zero conflicts, queue drained.
2. **Outbound**: touch a task (claim/close). Within ~30s a mirror issue appears/updates on the repo,
   authored by the App bot, carrying a `Task: <doc_id>` trailer. Re-touch → the same issue PATCHes
   (never a duplicate).
3. **Inbound**: from another account, open an issue on the repo. Within ~a minute a `gh-<num>` task
   is born labeled `src:github` + `needs-human`, and the issue gets a "tracked internally" comment.
   Re-deliver the webhook → no duplicate task (idempotent on the deterministic `gh-<num>` id).
4. **Adopt**: `bp github adopt gh-<num>` (or the Studio "Adopt from GitHub" button) → the task loses
   `needs-human`, ownership flips into Barkpark, the issue gets a backlink comment.
5. **Projects** (if step 2 done): the mirrored issue auto-adds to the board with Status/Priority/
   Worker/Goal set; an unchanged task writes zero GraphQL on the next pass.

## Loop safety (why this can't storm)

Three independent structural cuts, all live: the App's own `[bot]` webhooks are dropped on arrival;
inbound-applied writes stamp `mutation_events.source = "github"` and are excluded from the outbound
outbox; and a `synced_rev`/fingerprint check makes a no-op edit a no-op sync. No field is ever
bidirectional — GitHub values are never read back into a task. Out-of-band edits to a mirrored issue
are recorded in the `github_sync_conflicts` table (visible in the console) before the ledger reconverges;
a deleted/transferred issue is marked `detached` and never recreated.

## Turning it off

Remove `github` from `BARKPARK_PLUGINS` and restart. The mirror stops; existing issues and tasks stay
as they are (nothing is torn down). Re-enabling resumes from the cursor's current head — the pre-enable
backlog is never mass-mirrored.
