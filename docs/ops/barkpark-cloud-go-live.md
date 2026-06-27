<!-- doc-tier: human | canonical-for: barkpark-cloud-go-live | budget: 1900tok -->
# Barkpark Cloud — go-live runbook (the 5 human gates)

The Barkpark Cloud machine is **built and proven at zero spend** (PRs #251–264, all 13 AUTO
roadmap tasks). Every external dependency runs against a fake; the full `local → live` flow is
green offline (`go test ./internal/cli/cloud/ -run Rehearsal`). What remains is **swapping each
fake for its real credential** — five steps, each needing a real account/domain/key/decision no
mock can substitute for. Do them in order.

## Architecture (what you're wiring up)

```
Barkpark Cloud control plane (cloud/ — Elixir/Plug+Bandit)   Managed Barkpark server (a Hetzner CAX box)
  ├── identity (users/teams, bcrypt)                           ├── Ubuntu + Postgres + Caddy/TLS + systemd
  ├── registry (barkparks/providers/agent_events)              ├── Barkpark source + bp CLI
  ├── billing (Stripe gateway)                                 └── barkpark-agent → reports to the control plane
  ├── HTTP API (/v1/auth, /v1/agent, /v1/barkparks, /v1/go-live)
  └── warm pool (pre-baked servers, assigned on go-live)
```

The control plane stores **metadata, not customer content**. Each managed server is a real,
SSH-able, source-editable Barkpark. `bp login → bp launch → bp go-live` drives it; `bp doctor`
verifies a server is genuinely ready (incl. the websocket-403 LiveView check).

## Gate 1 (cloud-14) — Fund Hetzner + provision token

Hetzner bills on create (hourly, no sandbox), so a real funded account is unavoidable.
1. Create a Hetzner Cloud project; mint an **API token** (read+write).
2. Export `HCLOUD_TOKEN` where the control plane / provisioner runs. The provisioner
   (`internal/cli/cloud/provider.go`, `HcloudProvider`) already builds the exact `hcloud server
   create … --type cax11 --location nbg1 --image <BARKPARK_SERVER_IMAGE>` argv — it just needs the
   token plus the baked snapshot id (`BARKPARK_SERVER_IMAGE`, required at Gate 3 + Gate 5; the
   worker refuses to start without it).
3. Verify with ONE paid round-trip: create a CAX11, read its IP, delete it. Confirm the
   `FakeProvider`→`HcloudProvider` swap by pointing the provider at the real token and re-running
   the provider contract test. **Also confirm live ARM (CAX) stock** via the API before relying
   on the warm pool — fall back to CPX/CCX (x86) per `docs/ops/PROD_OPS.md` server table.

## Gate 2 (cloud-15) — Acquire `barkpark.cloud` + delegate wildcard DNS

1. Register `barkpark.cloud`; create a Hetzner **Cloud DNS** zone for it.
2. Delegate `*.barkpark.cloud` so each instance gets `<name>.barkpark.cloud` + wildcard TLS.
3. **No separate DNS token.** The default DNS provider is `cloud.CloudDNS`, which shells out to
   `hcloud zone rrset` (Hetzner's integrated Cloud DNS) and authenticates with the SAME
   `HCLOUD_TOKEN` as the server provider — `HETZNER_DNS_TOKEN` is **dead** (the legacy
   `cloud.HetznerDNS` REST client remains in the tree but is not wired into the worker). One
   credential covers both provisioning and DNS.
4. Caddy's automatic ACME issues the cert the moment DNS points a subdomain at a box
   (`internal/cli/setup/caddy.go` renders the Caddyfile — no manual cert step).

## Gate 3 (cloud-16) — Bake the warm-pool image + production secrets

1. Bake a warm-server image (Ubuntu + Erlang/Elixir + Go + Postgres + Caddy + Barkpark source +
   `bp` + `barkpark-agent` + health/backup scripts, **no customer secrets**) into the Hetzner
   account. Seed a small pool — `warm_pool_size = max(2, ceil(active_customers × 0.25))`.
2. Provision the control plane's own secrets (it **won't boot without them** — `runtime.exs`
   `raise`s): `DATABASE_URL`, `REGISTRY_ENCRYPTION_KEY` (32-byte base64 — `:crypto.strong_rand_bytes(32) |> Base.encode64`), and `WORKER_TOKEN` (the shared secret the provisioner worker authenticates with — generate it the same way).
3. Deploy the control plane (`cloud/`) — separate app from `api/`; give it its own Postgres. The
   turnkey path is the container set in `cloud/` (release + Dockerfile + compose, AUTO, no secrets
   baked):
   ```bash
   cp cloud/.env.example cloud/.env   # fill DATABASE_URL, REGISTRY_ENCRYPTION_KEY, STRIPE_SECRET_KEY
   docker compose -f cloud/docker-compose.yml --env-file cloud/.env up -d --build
   ```
   The `control_plane` container migrates on boot (`eval "BarkparkCloud.Release.migrate()"`) then
   serves the JSON API on **:4100**; the bundled `db` service is its Postgres. Front with Caddy for
   `api.barkpark.cloud` TLS (reverse_proxy to `:4100`). No Docker? Build the release directly:
   `cd cloud && MIX_ENV=prod mix release`, export the same env, then run the release's
   `eval "BarkparkCloud.Release.migrate()"` and `start`.

## Gate 4 (cloud-17) — Live Stripe keys + the pricing/legal call

1. Create a Stripe account; create the products/prices for the tiers
   (Free €0 / Starter €69 / Pro €149 / Business €399 / Dedicated €999+ — your call to finalize).
2. Create one **recurring price per tier** in Stripe; export each id as `STRIPE_PRICE_STARTER` /
   `_PRO` / `_BUSINESS` / `_DEDICATED` (Free has no price). Export `STRIPE_SECRET_KEY` — `runtime.exs`
   selects `StripeGateway` over `StubGateway` when it's present (prod raises if missing).
3. Add a Stripe **webhook endpoint** → `https://api.barkpark.cloud/v1/billing/webhook`, subscribed to
   `checkout.session.completed` + `customer.subscription.*`; export its signing secret as
   `STRIPE_WEBHOOK_SECRET` (the real v1 signature verification is already built — supply only the secret).
4. The pricing numbers, ToS, and refund policy are **business decisions**, not code.

## Gate 5 (cloud-18) — Flip the warm pool on + first paid go-live

1. Start the **provisioner worker** on the control-plane box — it drains the provision queue, so
   without it `bp launch` enqueues a job but nothing provisions: `barkpark-provisioner --control-url
   https://api.barkpark.cloud --token $WORKER_TOKEN`. Run it under systemd alongside the control
   plane. Its environment MUST set:
   - `HCLOUD_TOKEN` — the Hetzner Cloud token; powers BOTH the server provider AND Cloud DNS
     (`hcloud zone rrset`). **Do NOT set `HETZNER_DNS_TOKEN`** — it is dead (see Gate 2).
   - `BARKPARK_SERVER_IMAGE` — the baked warm-pool snapshot id (REQUIRED; the worker refuses to
     start without it — bare ubuntu has no Barkpark and would fail the health gate on every job).
   - `BARKPARK_SSH_KEY` — the hcloud ssh-key NAME injected into each created server (or omit it iff
     the account has exactly one ssh key, which auto-selects).
   - `BARKPARK_SSH_KEY_FILE` — the path to the PRIVATE key matching `BARKPARK_SSH_KEY`; the per-host
     SSH step runner uses it to run Caddy/TLS + migrate ON the new box.
2. Create your owner account: `bp signup --email you@you.com` (the first signup is your account; or
   `mix barkpark_cloud.create_admin <email> <password> <team>` on a mix checkout for a no-HTTP bootstrap).
   Customers self-serve the same `bp signup`.
3. Run the real flow end to end: `bp login` → `bp subscribe --plan pro` → open the returned Stripe
   Checkout URL + enter a card → Stripe's signed webhook activates the subscription → `bp launch hetzner
   --name <acme>` → the subscription gate passes → `/launch` enqueues a provision job → the worker claims
   it → warm-pool assign → DNS + Caddy + migrate + the 7-point health-gate → register → the barkpark flips
   `provisioning → up` → `bp barkparks` healthy.
4. **Do not show "ready" until `bp doctor <name>` is all-green** — capabilities, /studio,
   `/live/websocket` NOT 403 (the `PHX_HOST`/`check_origin` footgun), TLS, Postgres, agent
   connected, backup scheduled. The provisioner already fails closed on a red gate.
5. Monitor the first real customer server; confirm the replacement warm host was created.

## Rollback / safety

- The provisioner is **fail-closed**: a failed health-gate errors before the server is registered
  or marked ready — a broken box never reaches a customer.
- Each managed server is standard (Ubuntu/Postgres/Caddy/systemd) — `bp ssh`, `bp logs`,
  `bp rebuild`, `bp backup` operate it; the agent is removable (`bp agent disable/uninstall`).
- Roll back a bad control-plane deploy the same way as `api/` — see `docs/ops/PROD_OPS.md`.

> Open-source stance: Barkpark stays self-hostable everywhere; Barkpark Cloud is the official,
> fastest path — not the only one. "We recommend ownership. We sell convenience."
