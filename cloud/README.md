<!-- doc-tier: human | canonical-for: barkpark-cloud-control-plane | budget: 700tok -->

# Barkpark Cloud — control plane

The **control plane** for Barkpark Cloud: a standalone Elixir + Ecto app (separate from `api/`) that stores *metadata* about many independent managed Barkpark instances — who owns which, where it lives, its lifecycle and billing state. It deliberately holds **no customer content**, only metadata, so it outlives any single instance. Not Phoenix/LiveView — a minimal JSON `Plug.Router` over Bandit, in front of a handful of contexts.

## What it does

| Context | Responsibility |
|---|---|
| **Accounts** | Cloud identity — Users, Teams, memberships, email+password auth. One login fans out across all your Barkparks. |
| **Registry** | Team-scoped store of every Barkpark instance, its providers, agent events, sites, and deployments. Sites (`create_site/2`, `list_sites_for_team/1`) and Deployments (`create_deployment/2`, `transition_deployment_fenced/4`) are sub-concerns of this single context — there is no separate `BarkparkCloud.Sites` module. The warm-pool registers a newly-live server here. |
| **Billing** | The pay-once go-live path + subscriptions, through a config-selected gateway: `StubGateway` in dev/test (in-memory, no network), the real Stripe HTTP gateway in prod (live keys + price ids are the operator's to wire). Tiers (`@plans`): `free`, `trial` (14-day), `supporter`, `support_plus`, `forever` (lifetime). |
| **Events** | Team-scoped pub/sub over OTP `:pg` powering the live dashboard's Server-Sent-Events stream (`GET /v1/events`) — no extra dependency. |
| **Health** | Control-plane liveness (`SELECT 1` round-trip to its own Postgres). |

A `barkpark-agent` on each managed box reports health and claims an allow-listed command set via `/v1/agent/*`; a Go provisioner worker claims provision jobs and brings up real Hetzner servers. The live dashboard (fleet · billing · lifecycle, SSE-pushed) is served by this control plane. It also serves the **deploy-button flow** (dwb-6): a public template catalog (`GET /v1/templates`) rendered at `/new?template=<slug>` — the "Deploy with Barkpark" landing that provisions a starter template into a live site. Manifest spec: [`templates/MANIFEST.md`](../templates/MANIFEST.md). For a connected GitHub repo it also runs **push-to-deploy** (Vercel-parity, gh-2…6): create or connect a repo, auto-register the push webhook, build with a live log console, deploy, and branch previews — the user-facing hosted-Sites API (`POST /v1/sites`, `POST /v1/sites/:id/deploy`). With a `VERCEL_PLATFORM_TOKEN` wired it also offers the **zero-paste Vercel handoff** (`POST /v1/barkparks/:id/vercel-deploy`): the plane deploys the template to Vercel with every env value pre-installed and hands the user a claim-deployment link — no env form, no pasting; unwired, the endpoint 503s and the classic clone-URL flow remains.

A Coolify-derived **beta foundation** (#352) extends the plane — RBAC roles, account sessions, personal-access-tokens, email notifications, team invitations, and an Oban job substrate — each documented in [`docs/swarm/`](../docs/swarm/). Its **beta-exit batch** (#680) layers OAuth/SSO login, two-factor auth, email verification, onboarding, team-shared secrets, and usage limits on top.

## Archive bundles — what a decommission leaves, and for how long

A **decommission** writes a portable archive bundle — a `pg_dump` plus a media
tar, a full copy of that instance's content — to `archives/<team_id>/<slug>/` in
the bundle bucket, then DELETES the `barkparks` row. There is no `archives`
table (the manifest IS the index), so no row's delete could cascade to it.

**A bundle is kept 30 days after the instance is torn down, then purged by a
daily sweep**: `BarkparkCloud.Workers.ArchiveRetentionWorker` (`45 3 * * *`, the
`:maintenance` queue) driving `ArchiveStore.delete_bundle/2` — the erasure route
the plane did not have before cch-w54-bl. Two carve-outs:

- **A still-live team never loses its most recent bundle.** "Live" means the team
  still has at least one `barkparks` row; that bundle is what a `resurrect`
  restores from. Its OLDER bundles still expire on the 30-day clock.
- **A bundle with no readable `created_at` is never purged.** An age the sweep
  cannot compute is not an age of zero.

An unconfigured bundle store makes the sweep a no-op, not a failure. The window
is ONE constant (`@retention_days` in that worker) and is quoted in exactly two
other places — this section and the console's Decommission sheet
(`priv/static/app.js`, `confirmDecommission`). Move all three together, or the
copy starts promising a window the sweep does not apply.

## Erasure — the decision, and what each route does

**THE DECISION: Barkpark Cloud ships self-serve erasure at BOTH levels, as
routes.** Ruled by team-lead on 2026-09-02, recorded on `task-c161ba42b88805c0`
(filed out of `cch-w54-bl`'s criterion 2). The alternative on the table was to
record the absence as consented, and it was declined for a stated reason: the
2026-09-02 ruling that authorised the bundle retention above covered bundles
only, so nobody had consented to the absence of account- and team-level erasure,
and documenting an absence is not disposing of it. Before this, the only erasable
object on the plane was a single archive bundle — a person who asked to be
removed could have one archive object purged and nothing else.

| Route | Who | Deletes | Refuses when |
|---|---|---|---|
| `DELETE /v1/teams/:id` | team **owner** | the team row + memberships, invitations, providers, subscription, notification settings + deliveries, GitHub installation, deploy-rate alert state, the team's audit trail, and every team-scoped PAT | the team still owns ANY instance or site — `409 {"error":"instances_present","barkparks":N,"sites":M}` |
| `DELETE /v1/account` | the account holder, **reauthenticated with their password** | the user row + memberships, every session and PAT, external identities, device push tokens, device auth requests, their personal security trail | they are the SOLE owner of a team that still exists — `409 {"error":"sole_owner","teams":[slug]}` |

**The team refusal is the safety argument, not an edge case.** `barkparks.team_id`
is `ON DELETE CASCADE`, so an unrefused team delete would drop every instance ROW
while the billed Hetzner/Azure server it names kept running — and that row is the
only thing that still says what to tear down. Decommission the fleet first.

**The account refusal has a route out.** Promote another owner
(`PATCH /v1/teams/:id/members/:user_id`) or erase the team first. Being one of
several owners never blocks.

**What is ANONYMISED rather than deleted.** `audit_events.actor_user_id` is
`ON DELETE SET NULL` and stays that way: a team's audit trail is the TEAM's
record of what happened to the team, so erasing a user removes the person from it
and leaves the team an honest history. Audit `metadata` may still carry an email
a producing route put there; scrubbing those is a separate sweep this route does
not claim to have done.

**What still needs a human.** An OAuth-only account has no password to present,
so it cannot pass the reauthentication on `DELETE /v1/account`. Set a password
first, or ask an operator.

Both tables are append-only at the DB (a `BEFORE UPDATE OR DELETE` trigger), and
a row-level BEFORE DELETE trigger fires on an FK cascade too — so both erasures
would abort without a bypass. Migration `20260917100000` narrows both trigger
functions to fall through **only** under the transaction-local GUC
`barkpark.erasure`, and even then only for a `DELETE` or for the exact
`actor_user_id` nilify the FK performs. Rewriting an `action` or a `metadata`
still raises, flag or no flag. `BarkparkCloud.Accounts.Erasure.arm_erasure/0` is
the sole caller of that `SET LOCAL`.

The console surfaces both as Danger-zone sections — the team one on
`#settings/members` (owner-only), the account one at the bottom of the account
sheet — each on the destroy-tier confirm that makes you type the name back.

## Run it (local dev)

```bash
cd cloud
mix deps.get && mix ecto.setup && mix run --no-halt
```

`mix ecto.setup` creates `barkpark_cloud_dev` and runs migrations. In production `runtime.exs` **raises** without `DATABASE_URL`, `REGISTRY_ENCRYPTION_KEY`, and `STRIPE_SECRET_KEY`. `WORKER_TOKEN` is optional at boot — when absent the app starts but all `/v1/internal/*` provisioner routes return 401 until it is set. Full go-live procedure: [`../docs/ops/barkpark-cloud-go-live.md`](../docs/ops/barkpark-cloud-go-live.md).

## Using it as a customer

You don't run this app — you talk to it with `bp` (all require `bp login` first):

```bash
bp signup --email you@example.com   # create a Cloud account + team
bp login                            # authenticate this machine
bp barkparks                        # list every Barkpark in your fleet
bp launch hetzner --name acme       # provision into a connected provider
bp go-live --name acme              # provision a fully-managed Barkpark
bp doctor --name acme               # verify an instance is healthy
```

A subscription gates `go-live` — see the [go-live runbook](../docs/ops/barkpark-cloud-go-live.md) for the billing step.
