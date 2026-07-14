<!-- doc-tier: human | canonical-for: connectors-deploy | budget: 2600tok -->
# Connectors bridge — deploying it on guerrilla (systemd + a Caddy PATH route)

The Connectors bridge (`connectors/`, charter D4/D27/D32) is a **persistent Node
service**, not a Vercel function and not part of the BEAM. On a content instance
it runs as `barkpark-connectors.service` on loopback `127.0.0.1:4020` and the
host Caddy exposes it **path-based** at `https://<host>/connectors`.

```
provider webhook ──► https://guerrilla.barkpark.cloud/connectors/<provider>
                        │  Caddy: @barkpark_connectors path /connectors /connectors/*
                        ▼
                     127.0.0.1:4020   barkpark-connectors.service (node + tsx)
                        │  per-install workspace token (NEVER a global one)
                        ▼
                     https://guerrilla.barkpark.cloud/v1/chat   (the stable public
                                                                 front — blue/green
                                                                 flips 4000/4001)
```

**Why a path, not `connectors.barkpark.cloud`.** There is no wildcard DNS on
`barkpark.cloud`; a subdomain would re-arm the separate Hetzner DNS-token human
gate for nothing. The MCP endpoint already proves the pattern
(`curl -i https://guerrilla.barkpark.cloud/mcp` → `405` via Caddy, answered by a
non-Elixir loopback process on `:4010`). `:4020`, like `:4010`, sits **outside**
the blue/green slot ports `{4000,4001}` on purpose: the deploy's port-flip `sed`
and `ACTIVE_PORT` greps match slot ports exactly and pass over both routes.

## ⚠ Ordering hazard — bring the unit UP *before* you register a webhook URL

Until `barkpark-connectors` is active, `/connectors/*` hits a dead upstream and
Caddy answers with the branded **maintenance 503**. Slack and Meta (WhatsApp)
**disable a webhook subscription after repeated non-2xx responses** — so a URL
registered against a down bridge does not merely fail, it gets *retired* at the
provider, and re-enabling it is a manual console trip.

Order every time:

1. Merge the bridge code → the deploy runs (see below) → the unit is up.
2. `curl -i https://guerrilla.barkpark.cloud/connectors/health` — the **bridge**
   must answer. A `503` with the "Back in a moment" body means Caddy is
   answering, i.e. the bridge is down. Do **not** proceed.
3. Only then paste the URL into Slack's Event Subscriptions / Meta's webhook
   config / the Azure Bot messaging endpoint.

## What the deploy does (no hand-editing on the box — ever)

`deploy/instance-deploy.sh` owns all of it; `.github/workflows/deploy.yml` fires
on `connectors/**` (as well as `api|internal|deploy`), so merging bridge code
deploys it. On each run, **after** the blue/green flip (so a bridge hiccup can
never brick a good app deploy — every step below is non-fatal):

| Step | Detail |
|---|---|
| Caddy route | `arm_caddy_connectors_route()` — marker `BARKPARK_CONNECTORS_ROUTE`, idempotent, `caddy validate`d, auto-reverting, inserted before the slot `reverse_proxy` |
| node | `resolve_node_bin()` — `asdf where nodejs` → newest asdf install → a real `node` on `PATH` (never a bare shim; the box has **no** `node` on `PATH`). Symlinked to `/usr/local/bin/barkpark-node`, which the unit's `ExecStart` names (systemd cannot expand a variable in the executable position) |
| deps | `npm ci` in `/opt/barkpark/connectors` (full install — the entrypoint is `tsx src/index.ts` and `tsx` is a devDependency; when the bridge grows a real `build`, switch to `--omit=dev` + `node dist/index.js`) |
| env | `/etc/barkpark/connectors.env`, mode **0600** (see below) |
| unit | `install -m 0644 deploy/systemd/barkpark-connectors.service`, `daemon-reload`, `enable`, `restart` |
| gate | after 5s, `systemctl is-active` must say `active`; otherwise the unit is **disabled again** (a bridge that cannot boot would `Restart=on-failure` forever) and the deploy logs a WARN. Then a **log-only** probe of `/connectors/health` |

Guards, all non-fatal and all logged honestly: no node, no `DATABASE_URL`, `npm
ci` failure, missing `tsx` runner, unit not staying active. Each leaves the
bridge **not enabled** — the route stays armed, so `/connectors` serves the
maintenance 503 rather than a raw 502.

## `/etc/barkpark/connectors.env` (0600, written by the deploy)

| Key | Value |
|---|---|
| `DATABASE_URL` | copied from `/opt/barkpark/.env` — the bridge owns the `chat_bridge` schema (D28), never an Ecto table |
| `BARKPARK_API_URL` | `https://guerrilla.barkpark.cloud` — the **stable public front**, never a raw slot port |
| `CONNECTORS_HTTP_ADDR` | `127.0.0.1:4020` |
| `CONNECTORS_PATH_PREFIX` | `/connectors` (must match the Caddy matcher) |
| `CONNECTORS_CREDENTIAL_KEY` | cipher key for each install's stored credentials |

**There is deliberately no `BARKPARK_CHAT_TOKEN`.** One ambient operator token
would serve *every* tenant — the exact multi-tenant hole this wave closes. Each
install authenticates with its **own** workspace-bound `chat` ApiToken, stored
ciphered in the bridge's `connector_installs` rows. `mcp.env` is `0644` because
it deliberately holds no secret; `connectors.env` holds two, hence `0600`.

`CONNECTORS_CREDENTIAL_KEY` is generated **once** and persisted in
`/opt/barkpark/.env` (same mechanism as `BARKPARK_KEK`), then copied into
`connectors.env` on every deploy. **Rotating it makes every stored connector
credential undecryptable** — every install must then be re-connected.

## Verify

```bash
systemctl status barkpark-connectors
journalctl -u barkpark-connectors -n 50 --no-pager
curl -sS -i http://127.0.0.1:4020/connectors/health          # on the box
curl -sS -i https://guerrilla.barkpark.cloud/connectors/health   # through Caddy
```

`via: 1.1 Caddy` + a bridge response = the path route works. A `503` +
"Back in a moment" = the unit is down; check the deploy log for the WARN that
names which guard refused.

## Roll it back

Stop at the unit, not at the app: `systemctl disable --now barkpark-connectors`.
The Caddy route stays armed (harmless — it serves the maintenance 503) and the
app's blue/green slots are untouched. A full app `instance-deploy.sh --rollback`
also leaves `:4020` alone; the flip `sed` only rewrites slot ports.

Offline proof of all of the above: `bash deploy/instance-deploy_test.sh`
(Case 1 + Case 12 cover the route, the env-file mode, the no-token invariant,
and every install guard).
