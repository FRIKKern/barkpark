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
gate for nothing. The MCP endpoint already proves the pattern (`GET /mcp` → `405` via Caddy, from
a non-Elixir loopback process on `:4010`). `:4020`, like `:4010`, sits **outside**
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
2. `bash deploy/mcp-reachability-smoke.sh` — its `connectors-health` leg must be
   GREEN. A `503` there is *Caddy*, i.e. the bridge is down. Do **not** proceed.
3. Only then paste the URL into Slack's Event Subscriptions / Meta's webhook
   config / the Azure Bot messaging endpoint.

`/connectors/health` is the ONE unauthenticated surface and it deliberately says
nothing else: no install count, no provider list, no version. It is a liveness
probe, not a status page — an enumerable one would tell a stranger which tenants
exist here.

**The address is one contract, written once.** `CONNECTORS_HTTP_ADDR` (`host:port`)
is the only name in play: `instance-deploy.sh` writes `127.0.0.1:4020` into
`connectors.env`, Caddy reverse-proxies `:4020`, and `src/config.ts` parses that
exact variable. It binds **loopback**, not `0.0.0.0` — the webhook seam trusts
`x-forwarded-proto`/`x-forwarded-host` when `CONNECTORS_PUBLIC_BASE_URL` is unset
(that is what makes Teams' Bot Framework JWT audience check work behind Caddy), and
those headers are only trustworthy coming from the proxy. A malformed value is a
**boot failure**, never a silent fallback to a default port: a bridge listening on
the wrong port is a bridge whose every webhook 404s, with a green deploy and an
active unit to look at. `connectors/test/config.test.ts` is the tripwire.

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
| `CONNECTORS_CONNECT_SECRET` | shared HMAC secret for Studio→bridge connect tickets (D50) — the same value the BEAM signs with. Absent ⇒ connect routes are not mounted (a supported state, logged loudly at boot). |

**There is deliberately no `BARKPARK_CHAT_TOKEN`.** One ambient operator token
would serve *every* tenant — the exact multi-tenant hole this wave closes. Each
install authenticates with its **own** workspace-bound `chat` ApiToken, stored
ciphered in the bridge's `connector_installs` rows. `mcp.env` is `0644` because
it deliberately holds no secret; `connectors.env` holds three (`DATABASE_URL`, `CONNECTORS_CREDENTIAL_KEY`,
`CONNECTORS_CONNECT_SECRET`), hence `0600`.

`CONNECTORS_CREDENTIAL_KEY` is the **KEK**: every install's secrets are sealed
under an HKDF-derived **per-workspace subkey**, never the KEK directly, so a
single leaked row-key compromises one workspace rather than the instance. It is
generated **once** and persisted in `/opt/barkpark/.env` (same mechanism as
`BARKPARK_KEK`), then copied into `connectors.env` on every deploy.

## Rotating the credential key (safe by design — but the deploy does not do it for you)

Rotating the key does **not** make stored credentials undecryptable — that old
claim was wrong. The cipher opens a row under the **current key OR**
`CONNECTORS_CREDENTIAL_KEY_PREVIOUS`, and a sweep re-seals every row under the
new one:

> **The deploy does not carry `CONNECTORS_CREDENTIAL_KEY_PREVIOUS`.** The
> `connectors.env` writer in `deploy/instance-deploy.sh` emits exactly the six
> keys in the table above, and the unit reads *only* that file
> (`EnvironmentFile=/etc/barkpark/connectors.env`). Setting `_PREVIOUS` in
> `/opt/barkpark/.env` and deploying therefore leaves the bridge with an empty
> previous-key list — a flag day, not a rotation, and every already-sealed
> install blob becomes unopenable. Until the writer emits the key, step 1 below
> must be done by hand on the box. Filed as a follow-up; fixing the writer is
> the durable repair.

1. Set a fresh `CONNECTORS_CREDENTIAL_KEY=<new>` in `/opt/barkpark/.env` and
   deploy. **Then, before touching any install,** append the old value to
   `/etc/barkpark/connectors.env` by hand as
   `CONNECTORS_CREDENTIAL_KEY_PREVIOUS=<old>` and
   `systemctl restart barkpark-connectors`. Installs keep working through the
   window — rows still open under the previous key.
2. Run the sweep with the bridge's own environment (a bare
   `npm run rewrap` fails closed: `loadConfig` reads `DATABASE_URL`,
   `BARKPARK_API_URL` and `CONNECTORS_CREDENTIAL_KEY` from `process.env`, and
   nothing puts them in an operator's login shell):

   ```bash
   cd /opt/barkpark/connectors
   set -a; . /etc/barkpark/connectors.env; set +a
   npm run rewrap
   ```

   It re-seals
   **both** sealed columns of **every** install (all providers) under the new
   per-workspace key. It is idempotent and safe against a live bridge (it pins
   each row's old bytes, so a connect landing mid-sweep is kept, never rolled
   back — re-run to finish any `raced` row).
3. When it reports `raced=0` and no `unopenable` rows, delete the
   `CONNECTORS_CREDENTIAL_KEY_PREVIOUS` line from `/etc/barkpark/connectors.env`
   and `systemctl restart barkpark-connectors`. The old key is now retired.

**Custody.** The key is backed up only in `/opt/barkpark/.env` (`0600`) — the
box owns it. For disaster recovery, copy that line to a secret manager off-box;
this deploy does not escrow it. **If the key is lost** with no `_PREVIOUS` and no
backup, stored blobs can no longer be opened and every install must be
**re-connected** (re-paste the provider token). That is the only thing a lost key
breaks — the routing rows survive, the secrets they point at do not.

## Verify

```bash
systemctl status barkpark-connectors
journalctl -u barkpark-connectors -n 50 --no-pager
curl -sS -i http://127.0.0.1:4020/connectors/health   # the bridge, on the box
bash deploy/mcp-reachability-smoke.sh guerrilla.barkpark.cloud   # 4 public legs
```

The smoke is the deploy's own last step, advisory there: one verdict line per
leg with the code it saw, a RED leg logging a WARN rather than failing a live
app. A `503` = that unit is down; the WARN names which guard refused.

## Roll it back

Stop at the unit, not at the app: `systemctl disable --now barkpark-connectors`.
The Caddy route stays armed (harmless — it serves the maintenance 503) and the
app's blue/green slots are untouched. A full app `instance-deploy.sh --rollback`
also leaves `:4020` alone; the flip `sed` only rewrites slot ports.

Offline proof: `bash deploy/instance-deploy_test.sh` (Cases 1 + 12: the route,
the env-file mode, the no-token invariant, every install guard) and `bash
deploy/mcp-reachability-smoke_test.sh` (all four public legs).
