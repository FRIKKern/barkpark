<!-- doc-tier: human | canonical-for: barkpark-cloud-go-live | budget: 1500tok -->
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
   create … --type cax11 --location nbg1 --image ubuntu-22.04` argv — it just needs the token.
3. Verify with ONE paid round-trip: create a CAX11, read its IP, delete it. Confirm the
   `FakeProvider`→`HcloudProvider` swap by pointing the provider at the real token and re-running
   the provider contract test. **Also confirm live ARM (CAX) stock** via the API before relying
   on the warm pool — fall back to CPX/CCX (x86) per `docs/ops/PROD_OPS.md` server table.

## Gate 2 (cloud-15) — Acquire `barkpark.cloud` + delegate wildcard DNS

1. Register `barkpark.cloud`; create a Hetzner DNS zone (or Cloudflare).
2. Delegate `*.barkpark.cloud` so each instance gets `<name>.barkpark.cloud` + wildcard TLS.
3. Export `HETZNER_DNS_TOKEN` (+ the zone id). `internal/cli/cloud/dns.go` (`HetznerDNS`) already
   builds the record-upsert requests — swap `FakeDNS` for the real provider.
4. Caddy's automatic ACME issues the cert the moment DNS points a subdomain at a box
   (`internal/cli/setup/caddy.go` renders the Caddyfile — no manual cert step).

## Gate 3 (cloud-16) — Bake the warm-pool image + production secrets

1. Bake a warm-server image (Ubuntu + Erlang/Elixir + Go + Postgres + Caddy + Barkpark source +
   `bp` + `barkpark-agent` + health/backup scripts, **no customer secrets**) into the Hetzner
   account. Seed a small pool — `warm_pool_size = max(2, ceil(active_customers × 0.25))`.
2. Provision the control plane's own secrets (it **won't boot without them** — `runtime.exs`
   `raise`s): `DATABASE_URL`, `REGISTRY_ENCRYPTION_KEY` (32-byte base64 — `:crypto.strong_rand_bytes(32) |> Base.encode64`), the session-token secret.
3. Deploy the control plane (`cloud/` — `mix ecto.migrate` then start Bandit). It's a separate app
   from `api/`; give it its own Postgres.

## Gate 4 (cloud-17) — Live Stripe keys + the pricing/legal call

1. Create a Stripe account; create the products/prices for the tiers
   (Free €0 / Starter €69 / Pro €149 / Business €399 / Dedicated €999+ — your call to finalize).
2. Export `STRIPE_SECRET_KEY` (+ the webhook signing secret). `runtime.exs` selects
   `StripeGateway` over `StubGateway` when the key is present (prod raises if missing). The
   gateway's request shapes are already built + tested — wire the key + the real price ids.
3. The pricing numbers, ToS, and refund policy are **business decisions**, not code.

## Gate 5 (cloud-18) — Flip the warm pool on + first paid go-live

1. With Gates 1–4 live, run the real flow end to end:
   `bp login` → `bp launch hetzner --name <acme>` → pay (real card) → the warm pool assigns a box →
   DNS + Caddy + migrate + the 7-point health-gate → register → `bp barkparks` shows it healthy.
2. **Do not show "ready" until `bp doctor <name>` is all-green** — capabilities, /studio,
   `/live/websocket` NOT 403 (the `PHX_HOST`/`check_origin` footgun), TLS, Postgres, agent
   connected, backup scheduled. The provisioner already fails closed on a red gate.
3. Monitor the first real customer server; confirm the replacement warm host was created.

## Rollback / safety

- The provisioner is **fail-closed**: a failed health-gate errors before the server is registered
  or marked ready — a broken box never reaches a customer.
- Each managed server is standard (Ubuntu/Postgres/Caddy/systemd) — `bp ssh`, `bp logs`,
  `bp rebuild`, `bp backup` operate it; the agent is removable (`bp agent disable/uninstall`).
- Roll back a bad control-plane deploy the same way as `api/` — see `docs/ops/PROD_OPS.md`.

> Open-source stance: Barkpark stays self-hostable everywhere; Barkpark Cloud is the official,
> fastest path — not the only one. "We recommend ownership. We sell convenience."
