# `deploy.sh` second-VPS validation report

**Status:** Planning artifact. Slice 8.0 track C (deploy.sh repeatability drill).
**Owner:** Worker 7.4 (Sonnet, product-brain hat) — report only; no source changes.
**Artifact under test:** `/home/doey/GitHub/barkpark/deploy.sh` (213 lines).
**Goal:** can a fresh Ubuntu 22.04 ARM64 box (Hetzner cax11-class) be provisioned end-to-end by `ssh root@NEW_IP 'bash -s' < deploy.sh` with zero manual intervention?
**TL;DR recommendation:** **CONDITIONAL GO** — script is close, but has 4 blockers and ~6 sharp edges that will hurt a first-time deployer. Fix list in §4 is ~2 hours of work.

---

## 1. Inputs reviewed

Three files plus Phase 7D acceptance context.

### 1.1 `deploy.sh` (line-by-line summary)

| Lines | Step | What it does |
|---|---|---|
| 1–33 | Header / vars | `set -euo pipefail`; defines `APP_DIR=/opt/barkpark`, `REPO=https://github.com/FRIKKern/barkpark.git`, generates `DB_PASS` via `openssl rand -hex 16` on each run, detects `ARCH` via `uname -m`. `DEBIAN_FRONTEND=noninteractive` to suppress apt prompts. |
| 34–41 | System packages | `apt-get update -qq && apt-get install -y -qq build-essential git curl wget unzip libssl-dev automake autoconf libncurses5-dev inotify-tools ufw`. |
| 42–52 | PostgreSQL | Installs `postgresql` + `postgresql-contrib`, enables + starts service, conditionally creates role `barkpark` (password = freshly-generated `DB_PASS`) and DB `barkpark_prod`. |
| 53–79 | ASDF + Erlang + Elixir | Clones ASDF v0.14.0 to `/root/.asdf` if missing. Sources it. Installs plugins `erlang` and `elixir`. Installs Erlang `27.3.4` + Elixir `1.18.4-otp-27` if not present. Runs `mix local.hex --force` and `mix local.rebar --force`. |
| 80–97 | Go | Downloads official Go `1.24.2` tarball for detected arch (`arm64` or `amd64`), extracts to `/usr/local/go`, writes `/etc/profile.d/go.sh` with `PATH` extension. Skips if `go` already on `PATH`. |
| 98–109 | Clone | `git clone` or `git pull` into `$APP_DIR`. Sets `git config core.hooksPath .githooks` so the `post-merge` hook (auto-rebuild on pull) is active. |
| 110–129 | Env file | If `.env` missing: generates `SECRET_KEY_BASE` (tries `mix phx.gen.secret`; falls back to `openssl rand -base64 48`), picks first hostname-IP as `PHX_HOST`, writes `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT=4000`, `MIX_ENV=prod`. If `.env` already exists: **re-aligns the DB password** in Postgres AND in the `DATABASE_URL` line (via `sed`), preserving `SECRET_KEY_BASE`. Sources the resulting env. |
| 130–140 | Build Phoenix | `cd api && MIX_ENV=prod mix deps.get && mix deps.compile && mix compile && mix ecto.migrate && mix run priv/repo/seeds.exs`. |
| 141–147 | Build Go TUI | `cd $APP_DIR && go mod tidy && go build -o bin/barkpark .`. |
| 148–170 | Systemd service | Writes `/etc/systemd/system/barkpark.service` targeting `api/start.sh`, `Type=simple`, `User=root`, `Restart=on-failure`, `Requires=postgresql.service`. `systemctl daemon-reload && enable && restart`. |
| 171–178 | Firewall | `ufw allow 22/80/443/4000` then `ufw --force enable`. |
| 179–188 | Health-wait | 30-iteration loop polling `curl -s http://localhost:4000/api/schemas > /dev/null` with 2s sleep. No failure path — loop just ends. |
| 189–213 | Summary print | Studio URL, API URL, SSH workflow, update workflow. |

### 1.2 `api/start.sh` (systemd wrapper)

30 lines. Sources `/root/.asdf/asdf.sh`, exports `PATH` to include ASDF shims and `/usr/local/go/bin`, `cd`s to the script dir, sources `../.env` if present, `export MIX_ENV=prod`, then either runs `mix barkpark.rotate_public_read` (if arg `rotate-public-read` is given) or `exec mix phx.server` with `PHX_SERVER=true`.

### 1.3 CLAUDE.md "Production Server" invariants

Relevant non-negotiables to preserve across VPS reproductions:

- **Arch ARM64** on cax11 — ASDF required; Erlang Solutions has no ARM packages (past mistake #6).
- Phoenix listens on `localhost:4000`; Caddy is the public-facing reverse proxy (installed separately; not covered by `deploy.sh`).
- `force_ssl` MUST stay disabled in `api/config/prod.exs` until Caddy terminates HTTPS (Golden Rule #5) — `docs/ops/caddy-api-tls.md` owns the TLS cutover.
- `api/start.sh` is the systemd entry point; historic bug #4 was a service pointing at a non-existent `/opt/barkpark/start.sh`. Script now points to `$APP_DIR/api/start.sh` — correct.
- Rebuild hygiene (Golden Rules #1–#3): `_build/prod` must be nuked before recompile. `make rebuild` enforces this; first-boot via `deploy.sh` does NOT nuke (it's a green field, so unnecessary) — acceptable on fresh VPS, but a concern on re-run (§3.4).
- Domain: launch references `barkpark.cloud` (not `barkpark.dev` — v2 plan global replacement). `deploy.sh` does not reference either domain — it only prints IP-based URLs. Domain attachment is Caddy + registrar work, separate track.

---

## 2. Local validation attempt

**Docker availability:** `which docker` → not found on this worker box. Full containerized simulation not possible from this pane.

**What this means:** no executable validation in-band. The remainder of the report is a **walkthrough** of expected behavior on a fresh Hetzner cax11 with Ubuntu 22.04 ARM64, grounded in the script text + known-good single prior execution (prod at `89.167.28.206`). Empirical second-box execution is deferred to a Boss-supervised drill on a throwaway Hetzner instance, per v2 §5.4 mitigation.

**If docker becomes available in a follow-up worker:** the drill should be:

```sh
docker run --rm -it --platform linux/arm64 ubuntu:22.04 bash -c "
  apt-get update && apt-get install -y sudo systemd
  # Note: systemd in a container requires --privileged + cgroups work
  # Realistically: stub out systemctl calls, run the rest
"
```

A container will **not** fully validate `deploy.sh` because:
1. `systemctl` requires PID 1 systemd (containers typically don't have it).
2. `ufw` needs kernel netfilter modules; may not be present.
3. `sudo -u postgres psql` needs Postgres running as a system service.

The closest analogue is a **throwaway Hetzner cax11** (~€0.005/hour = <€0.15 for a 30-min drill). Recommended as the authoritative validation step; Boss approval required to spin one up (per task constraints).

---

## 3. Documentation-only validation — step-by-step expected behavior

Row legend: 🟢 = works as written, 🟡 = works but worth flagging, 🔴 = likely breaks on a fresh box.

### 3.1 Preconditions (implicit — not checked by script)

| Item | Status | Notes |
|---|---|---|
| Running as `root` | 🟡 | Script assumes root (`/opt/barkpark` write, `systemctl`, `ufw`). No explicit `if [ "$EUID" -ne 0 ]` guard. Fails obscurely mid-run if a non-root invokes it. **Recommendation:** add root check at line ~24. |
| Ubuntu 22.04 | 🟡 | No distro check. `apt-get` + `ufw` + `postgresql` package names assume Debian/Ubuntu. Would fail on RHEL, Fedora, Alpine. **Recommendation:** `. /etc/os-release && [ "$ID" = "ubuntu" ]` sanity check. |
| Internet connectivity | 🟢 | Implicit; all package fetches will fail fast. |
| SSH access + ≥2GB RAM | 🟡 | Erlang `asdf install erlang 27.3.4` compiles from source — takes 5–10 min and peaks at ~1.5GB RAM. cax11 (2GB) is tight but sufficient. Smaller instances (cax11-0.5GB if it existed) would OOM. **Recommendation:** note minimum 2GB RAM in CLAUDE.md. |
| Fresh disk ≥10GB | 🟡 | `.asdf/plugins/erlang/kerl-home` + build artifacts + PG + source ≈ 4–6GB. Comfortable on cax11 (40GB SSD). |
| `openssl` installed | 🟢 | Present on default Ubuntu 22.04. Used pre-apt-install for `DB_PASS` generation — works because `openssl` is in `base-files`. |

### 3.2 Step 1 — System packages (lines 34–41)

🟢 Works on fresh Ubuntu 22.04. All packages are in `main`/`universe` and have ARM64 builds.

**Sharp edge:** `apt-get update -qq` does not error on a transient mirror failure — returns 0. Worth adding `|| { echo "apt update failed"; exit 1; }` for determinism.

### 3.3 Step 2 — PostgreSQL (lines 42–52)

🟡 Works but non-obviously idempotent.

- `CREATE USER ... WITH PASSWORD '$DB_PASS' CREATEDB` is guarded by `SELECT 1 FROM pg_roles`. Good.
- `createdb` is guarded by `SELECT 1 FROM pg_database`. Good.
- **Pitfall:** `DB_PASS` is regenerated on every `deploy.sh` invocation (line 23: `openssl rand -hex 16`). On first run the user is created with this password. On re-run, the `CREATE USER` is skipped (role already exists) — so Postgres retains the **old** password. Line 125 `ALTER USER` re-aligns it, but only inside the `else` branch of "does `.env` exist." **A fresh run that finds `.env` absent BUT Postgres role present will write a new `DB_PASS` to `.env`, and Postgres will still have the old password, breaking connection.** Low probability (only if you somehow lose `.env` but keep the database), but a classic footgun.
- **Recommendation:** unconditionally `ALTER USER ... WITH PASSWORD` to match whatever `DB_PASS` is in the current run, regardless of `.env` presence.

### 3.4 Step 3 — ASDF + Erlang + Elixir (lines 53–79)

🟡 Works; several sharp edges.

- ASDF `v0.14.0` is pinned — good for reproducibility. Upcoming ASDF v0.15+ ships as a Go binary with a different layout; pin protects against surprise.
- Version-presence check `asdf list erlang | grep -q 27` matches ANY 27.x. If 27.0.0 is already installed and 27.3.4 is not, the script falsely believes it is done and will NOT install 27.3.4. Unlikely on fresh box but real on re-run after Erlang upgrade.
- `asdf install erlang 27.3.4` takes 5–10 min. The script emits a hint, but the long quiet period looks like a hang over slow SSH. No progress indicator.
- `mix local.hex --force 2>/dev/null` — errors are suppressed. If network flakes here, Mix will re-prompt on first `mix deps.get` and the non-interactive session blocks. **Recommendation:** don't swallow the error.
- Build deps for Erlang (`libssl-dev`, `automake`, etc.) are installed in step 1 — good.
- **Potentially missing build deps:** historical Erlang 27 compiles have needed `libwxgtk3.0-gtk3-dev` (for wx GUI) and `libgl1-mesa-dev` for full observer support. These are cosmetic; headless prod Erlang works without them. Kerl may warn "APPLICATIONS DISABLED (NOT ALL WILL BE AVAILABLE): wx" — benign.

### 3.5 Step 4 — Go (lines 80–97)

🟢 Works on ARM64 and x86_64. Uses official `go.dev/dl/` tarball. `rm -rf /usr/local/go` before extract — correctly idempotent.

**Sharp edge:** pinned to `1.24.2`. Fine for now; keep in mind for future bumps.

### 3.6 Step 5 — Clone (lines 98–109)

🟡 `REPO=https://github.com/FRIKKern/barkpark.git` is hardcoded. This is the correct repo today (per CLAUDE.md past mistake #9, it was made public after a private-repo clone failure on the prod box). Two concerns:

- If the repo is ever transferred or renamed, every second-VPS attempt will fail until `deploy.sh` is updated. Low probability.
- `git pull` on re-run has no conflict handling. If `/opt/barkpark` has any unstaged or uncommitted changes (e.g. a hotfix Boss tried on-box), `git pull` aborts with a message but `set -e` kills the script. **Recommendation:** `git reset --hard origin/main` before `pull` OR fail loudly with actionable message.

### 3.7 Step 6 — Env file (lines 110–129)

🟡 Logic is reasonable but has 3 sharp edges:

1. **SECRET_KEY_BASE generation:** `mix phx.gen.secret 2>/dev/null || openssl rand -base64 48`. At line 113 this runs before ASDF path is exported for a non-login shell, so `mix` may not be in PATH yet (ASDF was sourced line 61 within the same shell though, so the `mix` shim should be live — actually fine). Fallback to `openssl` is correct belt-and-braces.
2. **`PHX_HOST=$IP`** uses `hostname -I | awk '{print $1}'`. On Hetzner cax11 the first IP is the public IPv4 — correct. On dual-stack or multi-NIC boxes the "first IP" is not deterministic.
3. **Secrets ABSENT from `.env` that `deploy.sh` does NOT create** and that downstream code may expect:
   - `BARKPARK_WEBHOOK_SECRET` — required by `@barkpark/nextjs/webhook` HMAC verifier (slice 8.6 R-S5b). Phoenix side currently has no HMAC secret; webhook verifier is in the JS package, not Phoenix. Second-VPS user won't have webhook capability configured. **Not script's fault; flag for operator.**
   - `BARKPARK_WEBHOOK_PREVIOUS_SECRET` — HMAC rotation dual-verify (slice 8.6). Same as above.
   - `BARKPARK_PREVIEW_TTL_SECONDS` — preview cookie cap (slice 8.6 R-S5a).
   - No API auth TOKEN override is seeded beyond `barkpark-dev-token` in `priv/repo/seeds.exs`. A fresh second-VPS will ship with the publicly-known dev token, which is **dangerous if the VPS is internet-reachable**. **High-severity gap** — see §4 below.

### 3.8 Step 7 — Build Phoenix (lines 130–140)

🟢 Standard Elixir prod build sequence. `mix ecto.migrate` is idempotent (migrations table tracks applied). `mix run priv/repo/seeds.exs` — check if seeds are idempotent:

**Re-reading context:** `priv/repo/seeds.exs` "8 schemas, 27 docs, dev token." Seeds on a second VPS is desired (gets the box into a demo-able state). But on a **re-run**, running seeds twice will either error (unique-constraint violation) or duplicate — depending on how the seeds are written.

- 🟡 **Flag:** the script calls `mix run priv/repo/seeds.exs` unconditionally every run. If re-run and seeds aren't idempotent, either the script dies here (blocks subsequent steps) or silently doubles data. **Recommendation:** guard seeds behind a "fresh DB" check, or make seeds use `upsert`.

### 3.9 Step 8 — Build Go TUI (lines 141–147)

🟢 `go mod tidy && go build` is idempotent and fast. The binary ends up at `bin/barkpark` but is not launched by systemd — it's only useful for running the TUI against a remote Barkpark from the box itself. Fine.

### 3.10 Step 9 — Systemd (lines 148–170)

🟢 Correct unit file. `ExecStart=$APP_DIR/api/start.sh` matches the actual script location (past mistake #4 fixed).

**Sharp edge:** `User=root`. Fine for prototyping, poor hygiene for a 1.0 production service. Phoenix should run as an unprivileged user with `/opt/barkpark` owned by that user. Not a blocker; 1.0.1 hardening item.

**Sharp edge:** `Requires=postgresql.service` — if Postgres ever fails to start, Barkpark stays down. `Wants=` (softer) might be preferable for a self-heal scenario. Not a blocker.

**Missing:** no `Environment=` or `EnvironmentFile=` directive. The `start.sh` sources `.env` itself — OK, but means service-side environment is opaque to `systemctl show barkpark -p Environment`.

### 3.11 Step 10 — Firewall (lines 171–178)

🟡 Opens 22, 80, 443, 4000. Port 4000 is Phoenix itself. In a Caddy-terminates-TLS future (see `docs/ops/caddy-api-tls.md`) port 4000 should NOT be externally reachable — Phoenix binds to `localhost:4000`. `ufw allow 4000/tcp` grants external access even if Phoenix binds localhost (harmless because Phoenix won't answer), but the firewall posture is permissive.

- **Recommendation:** remove `ufw allow 4000/tcp` from `deploy.sh`; leave port 4000 for loopback only. Allow 22/80/443. Post-Caddy, there is no reason for external port 4000.

### 3.12 Step 11 — Health wait (lines 179–188)

🔴 **No failure path.** The 30-iteration × 2s loop (60s total) waits for `/api/schemas` to return a non-5xx HTTP status. If Phoenix fails to start (bad migration, port conflict, systemd cranky), the loop quietly exits after 60s and prints the "Barkpark is running!" banner anyway. A first-time deployer will believe success when the box is actually dead.

- **Recommendation:** track whether the curl succeeded; if not after 30 attempts, print `journalctl -u barkpark --no-pager -n 50` and `exit 1`.

---

## 4. Gotchas and recommendations

### 4.1 Bugs found in `deploy.sh` (document only — do NOT modify in this slice)

| # | Severity | Line | Bug | Recommended fix |
|---|---|---|---|---|
| D1 | 🔴 HIGH | 179–188 | Health-wait loop prints success banner even on failure. | After the `for` loop, check if `curl` ever succeeded; `exit 1` with `journalctl` dump otherwise. |
| D2 | 🔴 HIGH | seeds | `priv/repo/seeds.exs` is run on every invocation; re-running may error or duplicate. | Guard behind `if [ "$(mix ecto.dump | ...)" = "fresh" ]`, or make seeds `upsert`-safe. |
| D3 | 🔴 HIGH | n/a | Publicly-known `barkpark-dev-token` is seeded on every fresh deploy. A second VPS is insecure by default. | Seed a freshly-generated token written to `.env` (e.g. `BARKPARK_ADMIN_TOKEN=$(openssl rand -hex 32)` passed into seeds), OR print a prominent WARNING telling Boss to rotate the dev token before exposing the box. |
| D4 | 🔴 HIGH | 23, 48–51, 125 | `DB_PASS` regenerates each run; if `.env` is absent but Postgres role exists, passwords diverge silently. | Always `ALTER USER ... WITH PASSWORD '$DB_PASS'` before writing `.env`, regardless of which branch. |
| D5 | 🟡 MED | 172–177 | `ufw allow 4000/tcp` opens Phoenix to the public even though it binds localhost. | Remove the 4000 rule. |
| D6 | 🟡 MED | 63–64 | `asdf plugin add erlang/elixir` has no version pin; plugin updates have occasionally broken install recipes. | Pin plugin refs via `asdf plugin add <name> <repo>` with a known-good commit, OR add a "last verified against asdf-plugins commit <sha>" comment. |
| D7 | 🟡 MED | 24–29 | No `$EUID` check for root. | `[ "$EUID" -eq 0 ] || { echo "must run as root"; exit 1; }`. |
| D8 | 🟡 MED | 37 | `apt-get update -qq` swallows mirror failures. | `apt-get update || exit 1`. |
| D9 | 🟡 MED | 66 | `asdf list erlang | grep -q 27` matches any 27.x (not exactly 27.3.4). | `grep -qx "  27.3.4"` (note the double-space ASDF uses). |
| D10 | 🟡 MED | 101 | Unguarded `git pull`; aborts on any dirty working tree. | `git fetch && git reset --hard origin/main` OR explicit dirty-tree detection + error. |
| D11 | 🟢 LOW | 159 | `User=root` in systemd unit. | Later hardening: dedicated `barkpark` system user. |

### 4.2 Architecture assumptions

- **ARM64 vs x86_64:** handled correctly at lines 85–88 (Go tarball) and implicitly by ASDF (Erlang compiles from source, architecture-agnostic). Validates CLAUDE.md "Erlang Solutions has no ARM packages" stance — ASDF is the right choice.
- **Ubuntu-specific:** `apt-get`, `ufw`, `postgresql` package names. Not RHEL/Alpine-portable. Fine for Hetzner cax11 + Boss's chosen stack.
- **`hostname -I | awk '{print $1}'`** — brittle on multi-NIC / dual-stack hosts. Hetzner cax11 is single-NIC; works. Flag for future non-Hetzner targets.

### 4.3 Manual steps required regardless (these are NOT `deploy.sh` bugs — they are out-of-scope-by-design)

- DNS A record `api.barkpark.cloud` → VPS public IP. Owned by `docs/ops/vercel-dns-connect.md` + `docs/ops/caddy-api-tls.md`.
- Caddy installation + TLS cutover. Owned by `docs/ops/caddy-api-tls.md` — not in `deploy.sh` scope.
- npm `BARKPARK_WEBHOOK_SECRET` generation. Owned by slice 8.6 security audit.
- Uptime Kuma probe registration. Owned by slice 8.0 separately.

### 4.4 Boss verification checklist (post-`deploy.sh`)

Run these **from the box** immediately after `deploy.sh` prints the success banner. All must pass:

```sh
# 1. Service is live
systemctl is-active barkpark
# Expected: active

systemctl status barkpark --no-pager | head -20
# Expected: "Active: active (running)", no recent crash

# 2. Phoenix responds on loopback
curl -sS -o /dev/null -w 'status=%{http_code}\n' http://localhost:4000/api/schemas
# Expected: status=200

curl -sS http://localhost:4000/v1/data/query/production/post | head -c 200
# Expected: JSON starting with {"ms":... or {"result":...

# 3. Database connectivity
sudo -u postgres psql -d barkpark_prod -c "SELECT COUNT(*) FROM documents;"
# Expected: 27 (matches seeds)

sudo -u postgres psql -d barkpark_prod -c "SELECT COUNT(*) FROM schema_definitions;"
# Expected: 8

# 4. Journal is clean
journalctl -u barkpark -n 50 --no-pager | grep -iE 'error|crash|panic|\*\*'
# Expected: no matches. Ignored strings: "(re)starting" from normal boot

# 5. Firewall posture
ufw status verbose | head -20
# Expected: active; 22/80/443 allowed. Confirm whether 4000 is reachable from outside
#           (should NOT be, post-D5 fix)

# 6. .env security
ls -l /opt/barkpark/.env
# Expected: 600 or 640 ownership; contains real SECRET_KEY_BASE and DATABASE_URL.
# NOTE: currently deploy.sh does not chmod the file — rehardening item.
grep -c 'SECRET_KEY_BASE=' /opt/barkpark/.env
# Expected: 1

# 7. Systemd will recover the service after reboot
systemctl is-enabled barkpark
# Expected: enabled

# 8. Disk usage headroom
df -h / | tail -1
# Expected: usage under 60% after fresh deploy (leaves room for logs + rebuild)

# 9. Go TUI builds and can connect (optional — from same box, skip for pure API)
/opt/barkpark/bin/barkpark --help 2>&1 | head -5
# Expected: some output, not "command not found"

# 10. Swap check (cax11 has 2GB RAM; swap is lifesaver during future rebuild)
free -m
# If swap is 0, consider enabling before first `make rebuild`:
# fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile

# 11. Confirm repo clone is on main and clean
cd /opt/barkpark && git status --porcelain
# Expected: empty output (no local changes)

git rev-parse HEAD
# Expected: matches latest GitHub main HEAD

# 12. Dev token is NOT exposed unless D3 fix applied
curl -sS -H "Authorization: Bearer barkpark-dev-token" http://localhost:4000/v1/schemas/production | head -c 100
# Currently works. THIS IS A CONCERN (D3). Rotate before exposing box publicly.
```

If all 12 pass (modulo D3 caveat), the box is production-ready for Caddy attachment and DNS cutover.

---

## 5. Summary + recommendation

**Verdict: CONDITIONAL GO.**

`deploy.sh` reflects a single working production deploy (to `89.167.28.206`) and correctly captures the ARM64 + ASDF path forced by Erlang's missing ARM packages. It is structurally sound: idempotent clone, guarded DB init, graceful systemd wiring, arch-aware Go install. For the original "deploy once, leave it alone" use case it has delivered.

For **second-VPS repeatability** — the slice 8.0 drill goal — it is not fully self-service. Four blockers and seven sharp edges stand between "Boss runs this on a fresh box" and "healthy Barkpark instance that can serve `barkpark.cloud` traffic":

**P0 (must fix for second VPS to be trustworthy):**
- D1 — health-wait loop falsely reports success on Phoenix failure.
- D2 — seeds re-run collides on repeat invocation.
- D3 — publicly-known `barkpark-dev-token` seeded by default; insecure.
- D4 — `DB_PASS` regen + `.env` logic has a divergence edge case.

**P1 (quality / hygiene):**
- D5 — `ufw` opens port 4000 unnecessarily.
- D6 — ASDF plugin refs unpinned.
- D7 — no root check.
- D8 — apt errors swallowed.
- D9 — Erlang version-presence grep is imprecise.
- D10 — `git pull` without dirty-tree handling.

### Effort estimate

- P0 fixes (D1–D4): ~90 minutes of focused editing + local review. Discrete changes, low blast radius; each is a small targeted patch to `deploy.sh` and (for D2) `priv/repo/seeds.exs`.
- P1 fixes (D5–D10): ~60 minutes. Mostly defensive guards.
- Empirical validation drill: a throwaway cax11 deploy, ~30 minutes clock time (mostly Erlang compile). Boss approval required to spin one up; cost <€0.20.

**Total:** ~2.5–3 hours of work + one Boss-approved drill box. Dispatch as a follow-up slice (slice 8.0.a or fold into slice 8.0 exit gate) before declaring `deploy.sh` reproducible.

### Path to unconditional GO

1. Land P0 fixes D1–D4 in a single PR. Review by Subtaskmaster.
2. With Boss approval, spin up a throwaway cax11. Execute `ssh root@NEW_IP 'bash -s' < deploy.sh` from a dev machine.
3. Run the §4.4 Boss verification checklist. All 12 items pass → tear down the drill box → record result in `.doey/plans/deploy-drill-<date>.md`.
4. Land P1 fixes D5–D10 in a follow-up PR (nice-to-have; not a launch blocker).
5. After steps 1–3, `deploy.sh` graduates to **unconditional GO** for `barkpark.cloud` / second-VPS use.

Until then: `deploy.sh` can be used by Boss on a fresh box with **close supervision** — specifically, Boss should watch for the health-wait loop (D1) and rotate the dev token (D3) immediately after success.

---

## Non-goals / out of scope

- Modifying `deploy.sh`, `api/start.sh`, `priv/repo/seeds.exs`, or any source file. Report is advisory; source mutations happen in a subsequent dispatch.
- Running a live drill on Hetzner. Requires Boss approval per task constraints.
- Caddy / TLS / DNS — covered by `docs/ops/caddy-api-tls.md` and `docs/ops/vercel-dns-connect.md`.
- npm / git rollback — covered by `docs/ops/rollback-playbook.md`.
- CI / `release.yml` — owned by W7.3 (in progress).

---

*End of deploy.sh validation report — slice 8.0 track C, advisory only. Recommend dispatching a follow-up slice to land P0 fixes D1–D4 before Boss-supervised second-VPS drill.*
