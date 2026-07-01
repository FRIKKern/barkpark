<!-- doc-tier: human | canonical-for: barkpark-cloud-control-plane | budget: 700tok -->

# Barkpark Cloud — control plane

The **control plane** for Barkpark Cloud: a standalone Elixir + Ecto app (separate from `api/`) that stores *metadata* about many independent managed Barkpark instances — who owns which, where it lives, its lifecycle and billing state. It deliberately holds **no customer content**, only metadata, so it outlives any single instance. Not Phoenix/LiveView — a minimal JSON `Plug.Router` over Bandit, in front of a handful of contexts.

## What it does

| Context | Responsibility |
|---|---|
| **Accounts** | Cloud identity — Users, Teams, memberships, email+password auth. One login fans out across all your Barkparks. |
| **Registry** | Team-scoped store of every Barkpark instance, its providers, agent events, sites, and deployments. Sites (`create_site/2`, `list_sites_for_team/1`) and Deployments (`create_deployment/2`, `transition_deployment_fenced/4`) are sub-concerns of this single context — there is no separate `BarkparkCloud.Sites` module. The warm-pool registers a newly-live server here. |
| **Billing** | The pay-once go-live path + subscriptions, through a config-selected gateway: `StubGateway` in dev/test (in-memory, no network), the real Stripe HTTP gateway in prod (live keys + price ids are the operator's to wire). Tiers: `free`, `supporter`, `support_plus`. |
| **Events** | Team-scoped pub/sub over OTP `:pg` powering the live dashboard's Server-Sent-Events stream (`GET /v1/events`) — no extra dependency. |
| **Health** | Control-plane liveness (`SELECT 1` round-trip to its own Postgres). |

A `barkpark-agent` on each managed box reports health and claims an allow-listed command set via `/v1/agent/*`; a Go provisioner worker claims provision jobs and brings up real Hetzner servers. The live dashboard (fleet · billing · lifecycle, SSE-pushed) is served by this control plane.

A Coolify-derived **beta foundation** (#352) extends the plane — RBAC roles, account sessions, personal-access-tokens, email notifications, team invitations, and an Oban job substrate — each documented in [`docs/swarm/`](../docs/swarm/). Its **beta-exit batch** (#680) layers OAuth/SSO login, two-factor auth, email verification, onboarding, team-shared secrets, and usage limits on top.

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
