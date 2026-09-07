<!-- doc-tier: human | canonical-for: cd-pipeline | budget: 1200tok -->
# Continuous deployment

A merge to `main` updates the affected **production** host automatically.
`.github/workflows/deploy.yml` runs after the merge (CI/merge-gates already
vetted the change) and is **path-filtered** so a docs-only commit never rebuilds
a server.

```
merge to main
   ├─ cloud/** | internal/** | cmd/** changed → deploy CONTROL PLANE  (barkpark.cloud / barkpark-cp)
   │    (internal/ + cmd/ because bp-provisioner is cross-built from
   │     ./cmd/barkpark-provisioner — an internal-only worker fix must roll the CP)
   └─ api/** | internal/** | connectors/** changed → deploy CONTENT INSTANCE (guerrilla)
        every deploy: build the IDLE blue/green slot (active one keeps serving)
        → health-gate it → flip Caddy's upstream (graceful reload) → stop old.
        Unhealthy new slot = it's stopped again, no swap — ZERO downtime either way.
```

The path filter diffs from the **last successful run of this workflow**, not the
previous push: the concurrency group keeps one pending run, so burst merges cancel
intermediate runs before they deploy — anchoring to the last success makes the
surviving run deploy the UNION of every push since (no cancelled range is ever
skipped), while a docs-only stretch still resolves to a no-op.

| Target | Trigger paths | Script | Mechanism |
|---|---|---|---|
| Control plane | `cloud/**` | `deploy/cp-deploy.sh` | flock-serialized. Compose slots behind profiles: `blue`=:4100, `green`=:4101, one up at a time. Tag rollback image → `git pull` → headroom guard (refuses to build below a 5G floor, `BARKPARK_MIN_FREE_GB` — 2026-08-31: never-pruned images filled the box to 100% and Postgres 500'd the fleet list) → `docker compose build` → boot idle slot (auto-migrates on boot) → health-gate → flip Caddy → stop old slot (kept for instant `docker start` rollback) → prune unreferenced images + build cache (only on a PROVEN flip; the kept slot's stopped container anchors the rollback image through the prune). Provisioner cross-built by the runner (`cmd/barkpark-provisioner`, linux/amd64) and shipped (Go is not on the box). |
| Content instance | `api/**`, `internal/**`, `connectors/**` | `deploy/instance-deploy.sh` | flock-serialized (queued runs coalesce). systemd slots `barkpark-slot@blue`=:4000/`@green`=:4001, per-slot build roots (`api/_build_blue`/`_build_green` via `MIX_BUILD_ROOT`) of one checkout. Hook-suppressed `git pull` (the box's post-merge hook would rebuild+restart the live tree — the pre-blue/green outage) → backfill secret keys → clean-build idle slot's root (active slot serving its own, never rebuilt under the live BEAM) → `ecto.migrate` → boot idle slot → health-gate `/api/schemas` → flip Caddy → retire old slot + legacy `barkpark` unit. |

Both hosts overlap old+new code on the new schema for the swap window, so
migrations must be expand/contract (backward-compatible).

**Maintenance page (no raw 502 when the app is down).** Every Caddy site block
carries a `handle_errors` handler serving a branded 503 "Back in a moment" +
`Retry-After` while the upstream is unreachable — blue/green keeps deploys
seamless, this covers crashes/restarts outside deploys. Baked into the renderers
(`internal/caddyfile/caddyfile.go`, `internal/cli/setup/caddy.go`,
`internal/cli/setup/assets/deploy.sh`) so every provisioned instance gets it, and
armed on running boxes by `instance-deploy.sh` (idempotent, `caddy validate`d,
auto-reverting; port-flip-safe). Reference block + manual arming:
`deploy/caddy/barkpark-maintenance.caddy`. Offline test harness for the deploy
script (169 checks: slot selection, flip, failure semantics, channel seam,
coalesce, rollback happy flip-back + typed refusals + unhealthy fail-closed,
/mcp + /connectors route idempotence and their install guards):
`deploy/instance-deploy_test.sh`.

**Static assets survive a slot gap.** The maintenance handler above answers
*every* failing request, so during a gap `GET /assets/bp-paper-editor.css`
returned the holding-page HTML with a 503 and papers rendered unstyled (incident
2026-07-07). `instance-deploy.sh` now also arms a `BARKPARK_STATIC_ASSETS` route
— a `file_server` rooted at `api/priv/static`, matched on
`BarkparkWeb.static_paths()` and placed BEFORE the slot `reverse_proxy`, so those
bytes come off disk and never reach `handle_errors`. `pass_thru` keeps
app-served asset URLs (e.g. `/assets/paper-surface/paper-surface.css`) on the
proxy, and an explicit `Cache-Control: no-cache` restates the contract
`endpoint.ex` sets on these unversioned files. api/ has no `phx.digest` step and
no `cache_manifest.json`, so every static name is stable and there is only one
generation to serve — old and new HTML request the same URLs. Instance path
only: the per-site `file_server` blocks in `site-deploy.sh` are untouched.
Reference block: `deploy/caddy/barkpark-static-assets.caddy`.

**Remote MCP endpoint (`/mcp`).** `instance-deploy.sh` arms an idempotent
path-based Caddy route (`handle /mcp /mcp/*` → `localhost:4010`, marker
`BARKPARK_MCP_ROUTE`) on the existing public site and — GUARDED, non-fatal —
installs/enables `deploy/systemd/barkpark-mcp.service` (`bp mcp serve --http`)
only when the just-built binary advertises `--http`, so the deploy step ships
independently of the bearer transport slice. Forward-through auth: the unit and
`/etc/barkpark/mcp.env` hold NO token; the caller's own bearer is the only
credential and a bogus one fails closed downstream. Port 4010 is deliberately
outside the blue/green slot ports — the flip sed and ACTIVE_PORT greps match
slot ports exactly and pass over it.

**Connectors bridge (`/connectors`).** Same shape as `/mcp`, one port over:
`instance-deploy.sh` arms an idempotent path route (`handle /connectors
/connectors/*` → `localhost:4020`, marker `BARKPARK_CONNECTORS_ROUTE`) and —
GUARDED, non-fatal — `npm ci`s `connectors/` and installs/enables
`deploy/systemd/barkpark-connectors.service` (a persistent Node process, not the
BEAM). The unit's `ExecStart` points at `/usr/local/bin/barkpark-node`, a symlink
the deploy aims at the asdf node (`asdf where nodejs`; the box has no `node` on
`PATH`, and systemd cannot expand a variable in the executable position). Guards:
no node / no `DATABASE_URL` / failed `npm ci` / missing tsx runner / a unit that
does not stay `active` (it is disabled again rather than left crash-looping) —
each logs a WARN and leaves the bridge off, with `/connectors` on the maintenance
503. `/etc/barkpark/connectors.env` is **0600** (it holds `DATABASE_URL` + the
credential cipher key) and carries **no** chat token: one ambient operator token
would serve every tenant. Runbook, including the "bring the unit up BEFORE you
register a provider webhook URL" hazard: `docs/ops/connectors-deploy.md`.

**Rollback (W6).** Every deploy stamps `.slots/<target>.sha` so the box knows
what its idle slot holds. `instance-deploy.sh --rollback-preflight` (read-only)
answers whether a rollback is possible: exit 0 prints `TARGET_SLOT=`/
`TARGET_SHA=`; typed refusals — 21 `no_previous_slot`, 22 `not_supported`
(pre-stamp box), 23 deploy lock held. `instance-deploy.sh --rollback` flips to
the idle slot at its recorded sha: `git reset --hard <stamp>` first (a bare
port flip lies — both slots share ONE checkout, so a slot restart would
recompile NEW source into the old build root), reboot the slot, health-gate it
on its own port, flip Caddy only on green, rewrite `.instance-deploy-last`.
Unhealthy = fail closed: slot re-disabled, Caddy untouched, checkout reset
back, exit 24. Schema stays forward — rolling back code does NOT undo a
migration; write a compensating one.

**Spawned static sites (`deploy/site-deploy.sh`).** A content-bound static site
(Astro adapter × static symlink-swap target, Site-Spawner W1) builds and serves
NEXT TO Phoenix on a content box, at `https://<instance>/sites/<slug>/`. It is a
NEW state machine — deliberately not a parameterization of `instance-deploy.sh`
(that one is Phoenix-specific: mix/ecto, port-pair slots, `/api/schemas` gate,
git-reset rollback) — but it mirrors the same proven skeleton: per-slug `flock`
serialize (queue depth 1 *per site*; the fleet-wide build gate below is what keeps
N sites from compiling at once), typed exit codes, Caddy backup+`validate`+reload-or-
revert, fail-closed on any error. Deploy is one state machine over an immutable
`sites/<slug>/releases/<build_id>/` layout: **PLAN** (caller passes `BUILD_ID`;
already-live ⇒ exit 0 no-op) → **BUILD** (`npm ci && npm run build` under
`systemd-run --scope -p MemoryMax=1500M -p CPUQuota=150%` with a SCRUBBED env —
only the injected `BARKPARK_*` build vars reach Vite, because its `process.env`
precedence would let an ambient `BARKPARK_TOKEN` silently shadow the per-site
token) → **STAGE** (copy ONLY `dist/` — ~16K — into `releases/<build_id>/`;
`node_modules` stays in the ephemeral sandbox) → **HEALTH** (throwaway static
server on a loopback ephemeral port over the release dir: assert `200` AND that
the `bp-build-id` / `bp-content-rev` / `bp-doc-id` `<meta>` markers in the bytes
it **serves** carry the **values** this deploy ships — `bp-build-id ==
$BUILD_ID`, `bp-content-rev` non-empty and `== $CONTENT_REV`, `bp-doc-id`
non-empty. Presence is vacuous: the old name-only grep passed a build whose
`bp-build-id` said `TOTALLY-WRONG` and whose `bp-content-rev` was the empty
string, and it went live. Fail ⇒ no switch **and the release is purged**, so a
retry of the same `build_id` rebuilds instead of re-gating the same broken bytes
forever; if those bytes are the live/rollback target they are kept and marked
`.bp-health-failed`, which PLAN refuses) → **SWITCH** (atomic `current` symlink
`rename(2)` — via `perl` so it is portable past BSD/GNU `mv`'s symlink-to-dir
follow; no Caddy reload in the flip) → **RETIRE** (keep newest `N=5` release
dirs, never `current`/`.previous`). It also arms ONCE a marker-guarded
(`BARKPARK_SITE_ROUTE:<slug>`) Caddy `handle_path /sites/<slug>/* { root *
<root>/current; file_server }` into the live FQDN block (mirrors the `/mcp` route
arming) — never re-flipped per deploy. `--rollback` repoints `current` to the
previous release in sub-second with NO rebuild (typed `--rollback-preflight`:
exit 0 prints `TARGET_BUILD=`; refusals 21 `no_previous`, 22 `not_supported`, 23
lock held). Because rollback is a pointer flip it does **not** health-gate — so
it refuses (21) a previous release marked `.bp-health-failed`, which would
otherwise walk a build already proven broken back in front of visitors. Typed
deploy exits: 11 missing input, 12 BUILD, 13 STAGE, 14 HEALTH, 15 lock wait, 16
SWITCH. Node/npm are already on guerrilla (asdf).

**Spawned node (SSR) sites (`deploy/site-deploy-node.sh`).** The SECOND runtime
target the founding architecture named — *"ONE deploy state machine, TWO runtime
targets: static-symlink-swap OR node-slot SSR"* — for container frameworks
(`site.framework ∈ nextjs|nuxt|sveltekit`; Next.js is the flagship). It is the
**sibling** of `site-deploy.sh`, not a fork: both source the same
`deploy/lib/site-deploy-common.sh` (the `BPSTAGE` `emit()`, the `meta_value`
marker reader, the slug/build-id validators, the `BUILD_ALLOW` scrub, and the ONE
shared Caddyfile leaf lock), so the two engines can never drift on the wire
protocol or the lock. The **artifact is a running PROCESS** with a port +
lifecycle, not a directory of files. Same six stages, node-shaped: **PLAN**
(`live` = the process on the *active Caddy-upstream slot* already serves this
`build_id`) → **BUILD** (`npm ci && npm run build` under the same scrubbed, capped
sandbox; Next's `output:'standalone'` emits `.next/standalone`, a traced
`node_modules` + `server.js`, NOT a static `dist/`) → **STAGE** (three-piece copy
into an immutable `releases/<build_id>/`: the standalone dir IS the release root,
then `.next/static` → `<release>/.next/static`, then `public/` → `<release>/public`)
→ **HEALTH** (boot the REAL idle slot — `systemctl start
barkpark-site@<slug>__<slot>` — and poll ITS port to a ≥10 s deadline, because a
process needs ~1.5 s to first-200 and Next's "Ready" log lies; assert `200` AND
`bp-build-id == BUILD_ID` + `bp-content-rev`/`bp-doc-id` non-empty **by value**;
on failure stop the just-booted slot, **never touch the live slot or Caddy**, exit
14) → **SWITCH** (marker-anchored per-site `reverse_proxy localhost:<port>`
**re-flip in place** inside this site's `BARKPARK_SITE_ROUTE:<slug>` block, under
the shared lock → backup → `caddy validate` → reload → revert — deliberately NOT
`instance-deploy.sh`'s whole-file global `sed`, which was RUN-proven to corrupt a
second site sharing a port literal) → **RETIRE** (keep the current slot + **1
warm previous** slot running for `<1 s` rollback, stop the rest, keep the newest
`N` release dirs on disk, never the builds slot `a`, slot `b` or `.previous`
still point at — those three skip the prune *on top of* the newest-`N` window, so
the honest bound is `N+3`, not `N`: at `RETAIN=5` with 10 releases and all three
protected builds outside the window, **8** dirs remain). Two slots per site (`a`/`b`), blue/green: build+boot
the idle slot, health-gate it, THEN flip — a slot that won't boot or fails its
probe NEVER takes the Caddy upstream. `--rollback`: a warm previous slot = a pure
Caddy port-flip back (`<1 s`, no reboot/re-gate); a cold older release reboots the
idle slot onto it + gates + flips. The slot unit is
`deploy/systemd/barkpark-site@.service` (§below). Offline gate (fake
`systemctl`/`caddy`/`npm`, no real systemd/network): `bash
deploy/site-deploy-node.sh --self-test` — 124 checks: the six-stage protocol,
boot-in-place HEALTH with the marker-value gate, the marker-anchored port flip,
retire protecting both live slots, the warm-rollback flip, and the fleet build
admission gate (below) — including the hazard specific to THIS engine: HEALTH
boots the slot process, which outlives the run, so the gate must be released
before it. Deleting the release call is proven to leave the box's only build slot
held after a *successful* deploy, with no reaper to free it.

**The slot unit (`deploy/systemd/barkpark-site@.service`).** ONE generic template
for every node site's every slot — `%i = <slug>__<slot>`. `EnvironmentFile=/opt/
barkpark/.slots/%i.env` (regenerated each deploy, 0600 — it holds the read token)
carries `PORT`, `HOSTNAME=127.0.0.1` (loopback bind), `RELEASE_DIR`, and the
per-site `BARKPARK_*` runtime vars SSR fetches content with.
`ExecStart=/usr/local/bin/barkpark-node ${RELEASE_DIR}/server.js` — `barkpark-node`
is the stable symlink the deploy aims at the resolved asdf node (`asdf where
nodejs`), NEVER the shim (an unpinned shim exits 126 and crash-loops the unit) and
NEVER a version-pinned path. Hardened: `MemoryMax=512M`, `CPUQuota=100%`,
`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`.

**Static vs node density (charter D67).** The two targets trade differently:

| | static (`site-deploy.sh`) | node SSR (`site-deploy-node.sh`) |
|---|---|---|
| Resident cost | **0** — Caddy `file_server`, no process | **1 process/site, 65-85 MB RSS, always resident** |
| Request CPU | disk-bound (~0) | request-time SSR on the box's ~2 cores |
| On disk | ~16 KB (`dist/`) per release | ~18 MB (traced standalone) per release |
| During a deploy | one extra release dir | **warm standby doubles RSS** (current + previous slot both up for `<1 s` rollback) |
| Density | thousands per box | low tens idle; single digits under real SSR load |

So a box that hosts hundreds of static sites hosts only tens of node sites: each
node site is a permanent process (RAM) that burns the shared 2 cores per request
(CPU), and the warm-standby that buys sub-second rollback keeps a *second* process
resident until the next deploy retires it. `MemoryMax`/`CPUQuota` on the slot unit
bound the blast radius of one busy or leaking site; the operator trades density
for the SSR/container capability, not for free.

**Machine stage protocol.** A deploy prints, next to the human prose, one line
per stage boundary on **stdout**:

```
BPSTAGE name=<PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE> status=<started|ok|skipped|noop|failed> build_id=<id> [detail="…"]
```

A stage that runs emits `started` then one terminal line (`ok`/`failed`); a stage
that does not run emits one terminal line (`skipped`, or `noop` for a PLAN that
finds the build already live). A successful deploy speaks for all six stages, in
order. A `failed` line is the last stage line of the run and **carries the
reason** (`detail=`) — BUILD's own output is merged onto stdout for exactly that
purpose, so a stdout-only caller can always say *why*. The three paths that used
to be silent — a PLAN no-op, a SKIP_BUILD redeploy, a RETIRE that removes nothing
— all speak, so a stage-watching caller cannot hang. `--rollback` keeps its own
contract (`TARGET_BUILD=` + typed exits), not `BPSTAGE`.

**One Caddyfile, one lock.** `site-deploy.sh`, `site-deploy-node.sh` and
`instance-deploy.sh` all read-modify-write `/etc/caddy/Caddyfile` (static route
arming; node per-site port flip; blue/green slot flip) — the third writer
(`site-deploy-node.sh`) JOINS this lock via the shared `with_caddy_lock` in
`lib/site-deploy-common.sh`, it does not copy it. An interleave silently discards
one writer — and a lost update is *syntactically
valid*, so `caddy validate` cannot see it (reproduced: a losing write dropped the
port flip, then reloaded Caddy onto the slot the deploy was about to disable — a
hard 502). Every read-modify-write in **both** scripts therefore runs under one
shared leaf lock, `/var/lock/barkpark-caddyfile.lock` on fd 8 (`with_caddy_lock`;
`BARKPARK_CADDYFILE_LOCK` overrides, TMPDIR fallback when `/var/lock` is not
writable). Both acquire in the same order — own lock (fd 9) → Caddyfile lock (fd
8) — and the Caddyfile lock is a leaf, never held across a build, so a site
deploy never waits on the instance deploy's multi-minute run.

**One box, one build (the fleet build admission gate).** The lock above is
PER-SLUG, so "queue depth 1" is true per site and false FLEET-WIDE: N sites built
concurrently on 2 cores BY CONSTRUCTION (measured on guerrilla: 20 per-slug lock
files, four stamped in one minute; peak 8 concurrent BUILD windows in 7 days; 80%
of astro crashes / 52% of 503s / 49% of unreachable fired with a *foreign* build
mid-flight, on a MEMORY-bound box). So both engines take a SECOND, fleet-wide lock
— `/var/lock/barkpark-site-build.lock` on **fd 7** (`build_gate_acquire` /
`build_gate_release` in `lib/site-deploy-common.sh`; `BARKPARK_BUILD_GATE_LOCK` /
`BARKPARK_BUILD_GATE_WAIT` are dev+self-test knobs only — `write_env_file/4` is an
explicit allowlist, so neither can reach the engine from a control-plane deploy).
`N=1` is not a preference: `CPUQuota=150%` on 2 cores and `MemoryMax=1500M`
against 304–894M available each floor to one, so the semaphore D95 sketched
collapses to one exclusive lock (raise the caps first if you want N>1). Taken
INSIDE the build arm only — after `BUILD started` and the two cheap validations —
and released right after `BUILD ok`, before STAGE: **nothing that compiles nothing
is admission-controlled** (a rollback, a preflight, a prebuilt STAGE and an
already-staged re-gate all run with the slot pinned; those are exactly the moves
an operator makes *while* the box is busy). Budget lapse ⇒ `BUILD failed` with the
reason and a `ps` read, THEN the typed **15** — emitted before the exit, because
this refusal fires after `PLAN ok` and a bare exit would hang a stage-watching
caller. Neither engine has a script-level EXIT trap and there is no reaper, so the
fd form is mandatory: the kernel dropping fd 7 is the only release that survives
SIGKILL. Fails OPEN and loudly (no `flock(1)`, unopenable lock) — a gate that
denies every deploy is worse than the contention it prevents.

Offline gate (no npm/caddy/systemd): `bash deploy/site-deploy.sh --self-test` —
228 checks: the symlink flip, forward/back rollback and retire-N over fixture
release dirs, the marker reader, then the real script driven end-to-end against a
fake npm (the six-stage protocol, a lying build failing HEALTH with exit 14 and
being purged, the retry rebuilding, a BUILD failure carrying its 401 to stdout),
and the admission gate against a REAL `flock(1)`: two genuinely concurrent deploys
of DIFFERENT slugs whose build windows are measured DISJOINT via a shared
START/END ledger (nesting depth 1), each oracle shown non-vacuous by mutating the
engine (delete the acquire ⇒ depth 2 and interleaved; delete the refusal's `emit`
⇒ only the anti-hang check reds), a SIGKILLed build whose slot the kernel frees so
the next deploy is admitted, and both fail-open paths. That block needs a real
`flock`, so it SKIPS on stock macOS and HARD-FAILS under
`BARKPARK_SELFTEST_REQUIRE_E2E=1` (set on both harness steps in CI) — a gate
proven against the harness's exit-0 `flock` stub would prove the stub.
`bash deploy/instance-deploy_test.sh` covers the blue/green script, including the
Caddyfile-lock regression (fail-before: the flip is lost; fixed: both writers
survive) — it needs a real `caddy` and `flock(1)`, so that case skips on macOS.

A change to `deploy/**` redeploys both (the deploy logic itself changed).

The control plane's `cloud/docker-compose.yml` also ships a self-hosted mail
relay (`postfix` service) — see `cloud/postfix/README.md` for its DNS/TLS/
Hetzner-port-25 setup; nothing extra is needed in this deploy pipeline.
Its TLS cert renews on its own schedule — see below.

## Required GitHub secrets (one-time, human-only)

Add under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DEPLOY_SSH_KEY` | The private key that can `ssh root@` both hosts (the Barkpark account key — locally `~/.ssh/barkpark_indx`). Paste the full PEM, including the BEGIN/END lines. |
| `CP_HOST` | Control-plane IP — `178.105.92.191`. Doubles as the control plane's **egress** address: the instance job passes it as `BARKPARK_CLOUD_EGRESS_IPS` so each box trusts the caller address the control plane relays (see §Control-plane egress below). |
| `GUERRILLA_HOST` | Content-instance IP — `157.180.90.121` |
| `HETZNER_DNS_TOKEN` | Hetzner Cloud DNS-capable API token (the `barkpark.cloud`-zone project's token, NOT `CP_HOST`'s own server token — see `cloud/postfix/README.md` §1). Only used by `renew-mail-cert.yml`. |

The workflow uses an `environment: production` — to require a click-to-approve
before every prod deploy, add **required reviewers** to that environment in
GitHub (Settings → Environments → production). Leaving it without reviewers keeps
deploys fully automatic.

## Adding another host

1. Put its IP in a new secret (e.g. `PROD_HOST`).
2. If it's a content instance, reuse `instance-deploy.sh`; if a control plane,
   `cp-deploy.sh`. Add a job mirroring the matching one in `deploy.yml`.
   (The CLAUDE.md prod box `89.167.28.206` is a candidate once the deploy key is
   added to its `authorized_keys`.)

## Staging channel — prove a Barkpark build before the fleet gets it

`staging.barkpark.cloud` is one disposable box that runs Barkpark **itself**, so a
new build is smoke-tested BEFORE the merge train auto-deploys it everywhere. It is
NOT local dev, NOT guerrilla (the content + `bp`-task server, role untouched), NOT
old prod, NOT the control plane — it owns its DNS/TLS, Postgres, `.env`, and a
throwaway dataset, and is resettable without touching any prod data.

**One script, two channels.** `instance-deploy.sh` picks its behaviour from a
marker file — the **fail-closed safety boundary**:

| Channel | `/opt/barkpark/.staging` | Trigger | Ref it deploys |
|---|---|---|---|
| guerrilla / prod | **absent** | merge → `deploy.yml` | strict **fast-forward `origin/main`** only |
| staging | **present** | on-demand only — never a merge job | `DEPLOY_REF` (any branch, or a PR as `pull/<n>/head`) from `DEPLOY_REMOTE` (default `origin`), hard reset |

Marker absent, the script refuses any non-ff move — every fleet box can only ever
advance along `main`, so a random branch can never be pushed to it. Present, it
opts that ONE box into arbitrary-ref, hard-reset deploys. The boundary is the file,
not a flag: no marker, no non-`main` deploy, ever.

**The verb.** `bp cloud deploy staging [--branch <x> | --pr <n>] [--clean]` sshes
the staging host and runs `instance-deploy.sh` with `DEPLOY_REF` set (default: the
current `main`). It writes **zero** `bp` config — your active server
(`~/.config/barkpark/`, = guerrilla) is untouched and `bp` never defaults to
staging; staging content ops use an **ephemeral** target instead
(`bp -s https://staging.barkpark.cloud …`, never a remembered server).

- `--branch <x>` / `--pr <n>` — deploy that ref instead of `main`. This is the
  whole point of staging: try a build **before** the auto-deploy-on-merge train.
- `--clean` — `rm /opt/barkpark/.instance-deploy-last` first, forcing a full
  rebuild even when the ref looks unchanged (skips the coalesce no-op check).

**The canary loop** — how a Barkpark change reaches the fleet safely:

```
1. worktree branch     git worktree add ../wt -b fix/x
2. deploy to staging   bp cloud deploy staging --branch fix/x
3. smoke the box       curl -s  https://staging.barkpark.cloud/api/schemas | head
                       curl -sL https://staging.barkpark.cloud/studio | grep -E 'pane-layout|Sign in'
                       curl -s  https://staging.barkpark.cloud/v1/data/query/production/post | grep count
4. merge the PR        green smokes → merge to main
5. fleet auto-deploys  deploy.yml ships main to guerrilla/prod (pipeline at top)
```

**Identity + data.** The staging build serves a `BARKPARK_ENV=staging` banner in
Studio so a human can never mistake it for prod. Its Postgres is its own and
**disposable** — reset it freely (a `bp cloud deploy staging --reset` verb lands in
wave 2; today reset is manual on the box).

**Adding the staging host** (mirrors *Adding another host*):

1. Trust the operator key: the verb sshes as `root` with `~/.ssh/barkpark_indx`
   (override: `BARKPARK_SSH_KEY_FILE`) — add its public half to the staging box's
   `authorized_keys`. (CI's `DEPLOY_SSH_KEY` is NOT involved — staging never
   deploys from a merge job.)
2. Point the verb at it — host resolution, first match wins: `--host <ip>`; the
   control-plane fleet row by name (needs `bp login`); `BARKPARK_STAGING_HOST`.
   No default — with none of the three it errors, naming all three paths.
3. Arm the channel ON THE BOX: `touch /opt/barkpark/.staging`. Without it the box
   stays strict-`main` and every staging deploy is refused — fail-closed by design.

## Instance mail (provisioner-injected)

Every provisioned instance must relay transactional mail (magic-link /
password-reset / verify-email) through the control-plane Postfix relay, or
`Barkpark.Mailer` falls back to the never-delivering Local adapter and identity
emails silently drop. The **provisioner** does this automatically: set these on
`barkpark-cp:/etc/barkpark-provisioner.env` (the worker's `EnvironmentFile`) and
each go-live writes them into the new box's `/opt/barkpark/.env`:

```
SMTP_RELAY_HOST=mail.barkpark.cloud
SMTP_RELAY_PORT=587
SMTP_RELAY_USERNAME=barkpark-cloud        # same SASL user as the CP's own postfix
SMTP_RELAY_PASSWORD=…                      # = cloud/.env SMTP_PASSWORD
```

Unset → instances provision without SMTP (no mail), same as before. A
partial/malformed relay is logged at worker startup (`mail relay DISABLED — …`)
and skipped rather than shipping a broken `.env`; a good one logs `mail relay
ENABLED`. The relay submission port (587) is published for instances by
`cloud/docker-compose.yml`; it is SASL-gated (not an open relay).

## Control-plane egress → instance `BARKPARK_TRUSTED_PROXIES`

An instance believes `x-forwarded-for` **only** from loopback or a peer listed in
`BARKPARK_TRUSTED_PROXIES` (`Barkpark.RateLimiter.client_ip`, individual addresses
only — a CIDR range is refused at boot, because trusting a range lets any host in
it forge every client's bucket key). The control plane relays the phone's address
on a proxied revoke and the instance's own Caddy appends the **control plane's
egress address** to the right of it, so until that egress address is listed the
rightmost non-listed hop *is* the control plane and every proxied request keys on
**one bucket per team** instead of one per caller. Not a forgery, not a 5xx — a
silent loss of per-caller bucketing.

The address is authored **once**, as the `CP_HOST` secret above (the control
plane's own IP), and read by both deployers under one name,
`BARKPARK_CLOUD_EGRESS_IPS`:

| Box | Reader | Where the value comes from |
|---|---|---|
| freshly provisioned | `barkpark-provisioner` → the go-live step right before secrets-install (its restart loads it) | `barkpark-cp:/etc/barkpark-provisioner.env` (`deploy/barkpark-provisioner.env.example`) |
| resurrected from a bundle | same worker → the resurrect chain's identity merge (a resurrect never runs the go-live's configure) | same worker env — the trust list belongs to the CURRENT control plane, never to the archive |
| already-running (guerrilla/prod) | `instance-deploy.sh` `.env` backfill | `deploy.yml`'s instance job passes `secrets.CP_HOST` over the SSH command |

`instance-deploy.sh` **never overwrites** an existing `BARKPARK_TRUSTED_PROXIES`
line — provisioning already wrote the right value on a managed box, and a
self-hosted operator may trust a different front. Both readers **validate the
shape before writing** (bare IPs, no ranges): the Elixir side raises on a
malformed entry, so an unvalidated write would not degrade a bucket key, it would
refuse to boot the box. Value absent on both paths → the script appends a
commented placeholder and logs the gap (`WARN: no BARKPARK_CLOUD_EGRESS_IPS …`),
the worker logs it at startup, and the deploy still succeeds.

Check a box: `grep BARKPARK_TRUSTED_PROXIES /opt/barkpark/.env`.

## Mail relay TLS renewal

`.github/workflows/renew-mail-cert.yml` runs `deploy/renew-mail-cert.sh` on
its own monthly schedule (unrelated to the push-triggered deploy above) —
re-issues the mail relay's Let's Encrypt cert via DNS-01, ships it to
`barkpark-cp`, reseeds the volume, reloads postfix. Manual re-run: **Actions
→ Renew mail relay TLS cert → Run workflow**.

## Manual / emergency

- Re-run from the **Actions** tab → the failed run → *Re-run jobs*.
- Run a deploy script directly on a box: `ssh root@<host>` then
  `bash /opt/barkpark/deploy/<script>.sh` (control plane also takes a prebuilt
  provisioner path arg).
- Rollback is automatic on an unhealthy boot (the new slot is stopped; the
  active one was never touched); scripts also leave the prior commit reachable
  (`git reset --hard <old>`) and, for the control plane, a
  `cloud-control_plane:rollback` image tag.
- Instant manual rollback after a bad-but-healthy swap: flip the port in
  `/etc/caddy/Caddyfile` back (4100↔4101 / 4000↔4001), `systemctl reload
  caddy`, start the old slot (`docker start …` / `systemctl start
  barkpark-slot@<slot>`).

## Connectors `:cloud` runner (host prereqs)

`instance-deploy.sh` installs the Cloud sandbox runner every deploy — the
`.mjs` plus a 2-line `/usr/local/bin/cloud-sandbox-runner` wrapper that execs
`barkpark-node` (never the `env node` shebang; the BEAM PATH has no `node`). Before
attempting a live turn, run the non-creating preflight
`scripts/connectors/preflight-vercel.sh` (vercel present + authed + sandbox
entitlement under `--scope guerrilla` + `ANTHROPIC_API_KEY`). Full contract:
`scripts/connectors/README.md` → *Wave 34 — host prerequisites*.

## Spawning a site (`bp cloud site`) — and proving it

A **site** is not an instance. `bp cloud deploy` flips a whole Barkpark box
blue/green; `bp cloud site deploy` builds ONE content-bound static site that
lives *next to* Phoenix on that box and serves at
`https://<instance>.barkpark.cloud/sites/<slug>/`. Its engine is
`deploy/site-deploy.sh` — six stages, PLAN → BUILD → STAGE → HEALTH → SWITCH →
RETIRE, an atomic `current` symlink swap, and rollback as a symlink repoint
(~25ms measured, no rebuild).

The command sequence:

```bash
bp cloud site create my-blog --dataset default/default/production \
    --framework astro --kind static --instance guerrilla
bp cloud site deploy   my-blog     # streams the six stages
bp cloud site open     my-blog     # https://guerrilla.barkpark.cloud/sites/my-blog/
bp cloud site rollback my-blog     # sub-second flip to the previous build
```

### Shipping a build made somewhere else (`--prebuilt ./dist`)

The default lane builds ON the serving box: `npm ci && npm run build` runs on the
same two cores that answer the API. `--prebuilt` is the opt-in lane where that
build happens anywhere else — your laptop, CI, a PDS box — and only the OUTPUT
travels:

```bash
bp cloud site deploy my-blog --prebuilt ./dist
```

It is **two calls**, and the order is forced by build identity:

1. **mint** — `POST /v1/sites/:id/deploy {"source":"prebuilt"}` creates the
   deployment without starting a build and answers with the `build_id` (and the
   `content_rev`, which only the box can compute). `bp` prints them as
   `BARKPARK_BUILD_ID` / `BARKPARK_CONTENT_REV` / `BARKPARK_SITE_BASE` exports.
2. **upload** — the packed `dist/` goes to the deployment-scoped artifact route
   with a real `Content-Length` and the sha256 the client computed over exactly
   those wire bytes. The box re-verifies that digest, extracts, and runs
   STAGE → HEALTH → SWITCH → RETIRE with **BUILD reported `skipped`** — no npm
   runs there.

What it refuses, all before the upload: a directory that is empty, one with no
root `index.html` (that is the project dir, not the output dir), and — after the
mint — bytes whose `<meta name="bp-build-id">` is not the id this deployment
minted, because HEALTH asserts that marker **by value** and such an upload is a
guaranteed red one round trip later. Build with the printed exports and then ship
to **that** deployment:

```bash
bp cloud site deploy my-blog --prebuilt ./dist --deployment <id>   # the refusal prints this line
```

`--deployment` is not a convenience — it is what makes the loop terminate. A
prebuilt mint is deliberately **nonced** on the control plane (so two different
`dist/` builds of the same content can never collide on one `build_id`), which
means a plain re-run mints a *new* id and refuses again. The second run mints
nothing, reads the named row, and uploads.

What it packs: the directory's contents at the archive ROOT (no `dist/` prefix).
The dotenv family, `.git` and `.DS_Store` are excluded; the ignore list is
explicit precisely because the *default* project ignores (`dist`, `build`, `out`,
`.next`, `.astro`) would delete this payload.

What the digest certifies and what it does not: it closes tampering **in
transit** — the box serves the bytes you packed. It says nothing about who built
them or from what content. HEALTH is unchanged and still certifies integrity and
identity only; provenance (`source=prebuilt`, the digest, the uploading
principal) lives on the deployment record.

### The proof script

`deploy/site-spawner-live-proof.sh` drives that whole journey against the live
fleet and **exits non-zero with a NAMED failure at any step it cannot prove**.
It is the gate for "the spawner works", and it is deliberately hostile to a
vacuous green — a 200 is never accepted as evidence on its own.

```bash
bash deploy/site-spawner-live-proof.sh --self-check  # offline; no creds, no network
bash deploy/site-spawner-live-proof.sh --preflight   # read-only; creates NOTHING
bash deploy/site-spawner-live-proof.sh               # the full live proof
```

- **`--self-check`** feeds every assertion synthetic good *and* bad input and
  asserts the exact typed red comes back (22 cases). It exists because a proof
  script whose failure paths never ran is itself a vacuous green.
- **`--preflight`** checks *every* wall and reports all of them before exiting on
  the first — so the walls can't rot as untested paths, and an operator fixes
  them in one pass.
- The full run asserts **by value**: the served `bp-build-id` must EQUAL the
  deployment's `build_id` (a build with `bp-build-id=TOTALLY-WRONG` once went
  live on this box and a reachability check called it green), `bp-content-rev`
  and `bp-doc-id` must be non-empty (a page that fetched no content still
  returns a cheerful 200), rollback must land under 1000ms **and** actually flip
  the live page, and a deliberately broken build must die at its named stage
  **without changing what a visitor sees**.

### The three walls that will stop you first

All three are real, and the script names them rather than letting you discover
them as a confusing 404 an hour in. **Wall 1 is down on guerrilla as of
2026-09-01** (the configured session's team now owns the box); wall 3 is the one
that stops the run today.

1. **`PREFLIGHT_NO_BARKPARK` (exit 32) — the credential.** A site is created
   under a *Barkpark*, and the Barkpark belongs to a *team*. A cross-team create
   returns **404 `barkpark_not_found`** — not a permission error — because the
   control plane refuses to leak existence across a team boundary. The default
   dev session's team (`azh-w6-smoke-*`) owns **zero** barkparks; guerrilla's row
   belongs to team `guerrilla`. Use a session in the owning team, or adopt the
   box via the worker-token-gated `POST /v1/internal/barkparks`. **Adoption is a
   human gate** — it re-parents a live production box, so it is not something a
   build script should do on its own.

2. **`PREFLIGHT_NO_CONTENT` (exit 33) — the empty page.** An **undefined document
   type answers 200 with `count:0`, not 404.** The Astro starter's default is
   `BARKPARK_DOC_TYPE=post`, and there is no `post` type on guerrilla — so the
   default build succeeds and ships a **silently empty page**. Use
   `BARKPARK_DOC_TYPE=paper` (public + published), and **pin `BARKPARK_DOC_ID`**:
   "newest published" is a moving target when other sessions are writing the
   corpus, so an unpinned build races and bakes a different `bp-doc-id` than the
   one you verified.

3. **`CREATE_MINT_REFUSED` (exit 39) — the control plane's OWN box credential.**
   The one wall preflight cannot reach, and the one stopping the proof today. A
   static site is content-bound at create, which means the control plane mints a
   `public-read` token **on the box** — with *its own* stored admin credential
   for that instance, not with your session:

   ```
   Registry.mint_public_read_token/5
     → relay_admin(bp, :post, "/w/<ws>/p/<proj>/v1/tokens", …)
       → 403 {"code":"forbidden","reason":"not_a_member"}
         → 502 read_token_mint_failed
   ```

   When the box's `ResolveWorkspace` answers `:forbidden_membership`, the create
   fails **even though your own session is perfectly valid** — preflight has just
   proved your team owns the box. Nothing you do to your own login fixes it, so
   it gets its own name: reading this as `CREATE_FAILED` sends an operator to
   `bp login`, which is the one thing that cannot help.

   **Confirm the split in one command** — your token on the very same route:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $(jq -r .token ~/.config/barkpark/config.json)" \
     https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens
   ```

   `200` from your token while the create still 403s proves the refused
   credential is the **control plane's**, not yours. Cross-check the box's
   membership roll with `bp workspace member-ls`: a `revoked: true` admin row
   beside a freshly rotated one is the signature — the box's admin token was
   rotated and the control plane still holds the old one.

   **The remedy is to re-seat the control plane's stored admin token for the
   instance, and it is a human gate**: it rewrites a live production box's
   credential, so it is not something a proof script should do on its own.
   Preflight deliberately does **not** claim this wall is down — exercising the
   mint is a *write*, so no read-only check can reach it. It is proven inline at
   CREATE instead.

### Status (2026-09-01)

Measured live against guerrilla (`git_commit 8087211689` = `origin/main`,
`running_release 0.2.26`) with a `bp` built from that same commit.

**The server-side spine is in.** The three W3 slices merged, and the routes the
2026-07-14 status called missing all exist today: `delete "/v1/sites/:id"`,
`GET /v1/sites/:id/deployments/:dep_id`, and `POST /v1/sites/:id/rollback` are
all in the control-plane router. Do not re-file those as gaps.

**What the proof now reports:**

- `--self-check` → **49/49 green**, offline. Every named red fires on input that
  must trigger it.
- `--preflight` → **PASSES**. `bp` speaks `cloud site`; the session's team
  (`506f035e-…`) **owns guerrilla** (`b2b81e69-…`); type `paper` has published
  content. Wall 1 (`PREFLIGHT_NO_BARKPARK`) is **down** — the old note that the
  dev session's team owns zero barkparks no longer describes this machine.
- the full run → **exits 39 `CREATE_MINT_REFUSED`** at step 1/5, with the box's
  own words: *"guerrilla refused to mint the site's read token (HTTP 403):
  forbidden — caller is not a member of this workspace"*.

So the end-to-end spawn is **still unproven**, but the reason has moved: it is no
longer a missing spine or a cross-team session, it is the **credential the
control plane presents to the box** (wall 3 above). Deploy, live-content,
rollback and broken-build containment have never been exercised on this box —
their assertions are written, and their reds are proven to fire offline, but they
have had no live run to judge.

**Residue: none.** The mint happens *before* `Registry.create_site`, so a run
that dies here creates no site row, no releases dir, no Caddy block and no orphan
token. Two full attempts on 2026-09-01 left `GET /v1/sites` with zero `lp-` rows.

### Superseded status (2026-07-14)

The four statements below are **now false** — the slices merged and the routes
landed. Kept only so a stale citation can be traced.

The proof script is **live and reports an honest red**: `--self-check` is 22/22
green, and the live run exits **32 `PREFLIGHT_NO_BARKPARK`**. The end-to-end
spawn has **not** been proven yet, because the server-side spine is still
unwired on `main`:

- `POST /v1/sites/:id/deploy` refuses a content-bound static site with **422
  `no_build_source`** (it still demands an `artifact_url` or a `github_repo`).
- `GET /v1/sites/:id/deployments/:dep_id` (the CLI's stage poll) and
  `POST /v1/sites/:id/rollback` **do not exist** in the control-plane router.

Those are the three in-flight W3 slices (`site-spawner-w3-engine-protocol`,
`site-spawner-w3-admin-site-deploy-seam`,
`site-spawner-backlog-server-orchestration`). When they merge, the control plane
and guerrilla auto-deploy (`cloud/**`, `api/**`, `deploy/**` are all on the CD
trigger paths above) and this script is the thing that says whether the spawner
actually works. Run it; don't trust a dashboard.
