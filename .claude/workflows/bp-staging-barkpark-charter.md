# Epic charter — staging-barkpark

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The former **studio-ui-premium** charter that lived here is preserved verbatim at
> `.claude/workflows/bp-studio-ui-premium-charter.md` (and in git history). The even earlier
> "Peak Aesthetics" charter is at `.claude/workflows/bp-cloud-peak-aesthetics-charter.md`.
> This file is now the memory of the **staging-barkpark** epic.

Epic bp task: `staging-barkpark` (published; every slice task is its child).
User wish (verbatim): "staging barkpark — a version we use to update barkpark itself — separate itself from dev / local server — make it easy to rapidly update staging server."

## Vision

staging.barkpark.cloud is a first-class fleet-style ops box — minted from the same warm image the provisioner boots, driven by the SAME blue/green `deploy/instance-deploy.sh` that deploys guerrilla — whose whole job is to be the canary for Barkpark itself. One verb, `bp cloud deploy staging [--branch <x> | --pr <n>]`, lands any ref (default: current main) on staging in low single-digit minutes, health-gated, printing the three smoke URLs when the slot flips. The box is unmistakable (Studio banner driven by `BARKPARK_ENV=staging`), unstealable (guerrilla stays the bp task server; staging is never the default target), and disposable (own DNS/TLS, own Postgres, own secrets, resettable). The canary loop becomes doctrine: branch → deploy to staging → smoke → merge → fleet auto-deploy.

## Decisions

- **D1 — One deploy system, two channels.** Generalize `deploy/instance-deploy.sh` with `DEPLOY_REF` (default `main`) + `DEPLOY_REMOTE` (default `origin`) + a marker-gated non-ff path: when `$APP/.staging` exists, `git fetch $DEPLOY_REMOTE $DEPLOY_REF && git reset --hard FETCH_HEAD` (post-merge hooks stay suppressed); when absent, today's strict `pull --ff-only origin main`, and any non-main `DEPLOY_REF` is REFUSED (exit 11). Fail CLOSED. *Why:* the script is already 80% channel-ready via env knobs (instance-deploy.sh:24-29); only the pull stanza (:53) is hard-wired — and fail-closed marker gating is the single guardrail that keeps guerrilla un-`reset --hard`-able. A second deploy script is how drift happens.
- **D2 — Birth = hand-create from the warm image, OFF the tenant fleet.** `hcloud server create --image <newest role=warm-image snapshot>`; do NOT run the provisioner go-live chain (tenant-shaped: template content bootstrap + verify-gate teardown + billing) and do NOT `bp cloud instance adopt` (clone-swap onto the billed fleet, needs --team). Staging is an ops box like guerrilla. *Why:* both product paths are the wrong shape (explorer-verified); the warm image is already a full `/opt/barkpark` source checkout that instance-deploy.sh runs on unmodified (bake-server-image.sh:130-162), and its first run self-installs the blue/green slot units.
- **D3 — The verb is `bp cloud deploy`, on-demand only, SSH-exec.** New `case "deploy"` in `runCloud` (internal/cli/hetzner_cmd.go:88 switch) — `bp deploy` is ALREADY the hosted-sites verb (sites_cmd.go:457); never overload it. Implementation rides the existing `cloud.SSHStepRunner` (freshen-proven; key `~/.ssh/barkpark_indx` / `$BARKPARK_SSH_KEY_FILE`, user root), streaming the repo's `deploy/instance-deploy.sh` to the box and running it with `DEPLOY_REF=<ref>` + `BARKPARK_HEALTH_HOST=staging.barkpark.cloud`. `.github/workflows/deploy.yml` is UNTOUCHED — staging never rides the merge train, so pre-merge branches never fight the path-filtered auto-deploy.
- **D4 — Identity: `BARKPARK_ENV=staging` → `:instance_env` → Studio banner.** New config key read in api/config/runtime.exs exactly like `BARKPARK_PUBLIC_DEMO_STUDIO` (runtime.exs:37-41, default nil in config.exs); a `studio_env_banner` layout component modeled on `studio_update_banner` (nav.ex:62 — lives in the layout, OUTSIDE the LiveView diff, reads config directly) renders an unmissable strip in studio.html.heex. Set at provision time on the box — NEVER written by instance-deploy.sh, which also runs on guerrilla. `:instance_env` is a display/identity tag, distinct from MIX_ENV.
- **D5 — bp never points at staging by accident.** Staging content ops go through ephemeral `-s` only; the deploy verb never calls `SetActiveServer`/`RememberServer`; `bp use` refuses to persist a server entry whose Kind is `staging` unless `--force`. *Why:* `bp use` persists `c.Server` (servers_cmd.go:35-38) — the one footgun that could silently repoint the task-server default off guerrilla.
- **D6 — Measure speed before building the fast path.** `log()` already stamps every phase (instance-deploy.sh:30); the first real staging deploy's captured log IS the measurement (acceptance evidence on the provision task). The staging-only incremental fast path (persist per-slot `_build`, mix.lock-hash-gated `deps.compile --force`, wasm skip when pdrender unchanged, `--clean` escape hatch, `.staging`-marker-gated fail-closed) is wave 2, justified by that measurement — the structural floor (forced cold dep compile on 2-vCPU ARM) makes it near-certain, but we don't build on a guess.
- **D7 — Reset is wave 2 and runs ON the box.** `bp cloud deploy staging --reset` SSH-execs `mix ecto.drop --force && mix ecto.setup` style reset (plain `ecto.reset` aborts under MIX_ENV=prod) against the box's own localhost DATABASE_URL, gated on the `.staging` marker + explicit confirmation. Never accepts a remote DATABASE_URL. Force-rebuild of the same SHA = `rm /opt/barkpark/.instance-deploy-last` (the verb's `--clean` does this).
- **D8 — Runbook lives in deploy/README.md.** The canary loop is documented in the existing continuous-deployment doc (routing-table owner for cloud hosts; doc-tier contract forbids a new card without retiring one).

## Roadmap

Wave 1 (this wave — integration order as listed):
1. `staging-w1-channel-seam` — DEPLOY_REF/DEPLOY_REMOTE/marker-gated non-ff seam in instance-deploy.sh + fake-git ref semantics in the offline harness. **medium**
2. `staging-w1-deploy-verb` — `bp cloud deploy` verb over SSHStepRunner + `bp use` staging-kind guard. **medium**
3. `staging-w1-identity-banner` — `:instance_env` config key + `studio_env_banner` Studio strip. **small**
4. `staging-w1-box-provision` — HUMAN-GATED: mint the box from the warm image, staging.barkpark.cloud DNS, .env identity (PHX_HOST/PHX_SCHEME/BARKPARK_ENV), `.staging` marker, SSH key trust, first deploy with live smokes + phase-timing capture. **medium**
5. `staging-w1-canary-runbook` — deploy/README.md staging channel section + canary-loop runbook. **small**

Wave 2 (planned):
6. `staging-fast-build` — staging-only incremental build path (persist `_build`, lock-hash gate on deps.compile, wasm skip), sized against the w1 measured timings; `--clean` escape hatch. **medium**
7. `staging-reset-verb` — `bp cloud deploy staging --reset` disposable-data path (on-box, marker-gated, --force). **small**
8. Optional polish: `--pr <n>` sugar fetching `refs/pull/<n>/head` explicitly; staging row in `bp cloud status`; opt-in main auto-track for staging; workflow_dispatch CI fallback (needs STAGING_HOST secret — human gate).

## Wave log

### Wave 2026-07-10 (epic staging-barkpark, wave 1 — reviewer log)

*(Filed here because this charter is the file the staging-barkpark workflow reads; the staging epic carries no charter of its own yet — the wave-2 lead should mint one or keep logging here under the slug.)*

**Landed (4/4 code slices green, reviewer-fixed in place — integrate the `-r` branches):**
- **staging-w1-channel-seam** (`loop-epic/instance-deploy-sh-gains-a-fail-closed-d-0-r`, 0b10610c): DEPLOY_REF/DEPLOY_REMOTE channel seam in `deploy/instance-deploy.sh`, fail-closed on the `/opt/barkpark/.staging` marker — prod keeps byte-identical `pull --ff-only origin main` and REFUSES non-main refs (exit 11); staging fetch+hard-resets any branch or `pull/<n>/head`. Reviewer fix: prod also REFUSES a non-origin `DEPLOY_REMOTE` (was silently ignored — safe outcome, wrong intent) + 5 new harness checks incl. staging non-origin-remote fetch. 49/49, both guards mutation-probed.
- **staging-w1-deploy-verb** (`loop-epic/bp-cloud-deploy-one-verb-pushes-any-ref--1-r`, c364bb78): `bp cloud deploy <target> [--branch|--pr|--host|--clean|--dry-run]` — streams the LOCAL instance-deploy.sh over SSH under the exact seam env contract; host precedence --host → fleet row → BARKPARK_STAGING_HOST → clear error; ZERO config writes (byte-asserted); `bp use` refuses a staging default without --force. 13 new tests. Reviewer fix: gofmt only. KNOWN GAP (accepted): RunFeed buffers CombinedOutput, so the deploy log prints after completion, not live — a streaming exec seam in cloud/sshrunner.go is wave-2 fodder.
- **staging-w1-identity-banner** (`loop-epic/studio-wears-its-environment-barkpark-en-2`, 37e4b719, no reviewer changes): `BARKPARK_ENV` → `:instance_env` (runtime.exs prod, identity tag NOT MIX_ENV) → `Nav.studio_env_banner/1` in studio.html.heex — staging strip with disposable-data copy, generic uppercase for unknown tags, nothing for nil/prod/production; warn-token colors verified present in all 8 themes; literal-check green; 51 tests. **Elixir slice — WAIT for the Elixir Test gate before merge.** app.html.heex does NOT carry the banner (Studio-only this wave, by brief).
- **staging-w1-canary-runbook** (`loop-epic/deploy-readme-md-teaches-the-staging-cha-4-r`, 99ce648a): deploy/README.md "Staging channel" section — two-channel table, the verb, the 5-step canary loop, staging-host onboarding. Reviewer fixes against the built code: real host-resolution precedence (BARKPARK_STAGING_HOST has NO default), operator key `~/.ssh/barkpark_indx` not CI's DEPLOY_SSH_KEY, branch/PR refs not raw shas. Doc gates green. Its criterion 1 ("match MERGED implementations, cite PRs") stays open until the lead merges seam+verb and cites the PRs.

**Stalled (honest):** **staging-w1-box-provision** — HUMAN-GATED, all 6 criteria open with a prepared executor runbook stamped as evidence. Hard gates: staging.barkpark.cloud NXDOMAIN (DNS zone is on the SEPARATE Hetzner token — cannot be automated with the present credentials); billable `hcloud server create` forbidden unsupervised; newest warm snapshot is x86 (use cx22/cpx11, NOT cax11 ARM). Also blocked on seam+verb merging first.

**Merge order:** seam-r → verb-r (Go gate; may merge on it) → banner (WAIT for Elixir Test) → runbook-r last (docs-only). No textual conflicts expected — disjoint files. Lead closes each task's "PR merged" criterion on merge (claim epochs: seam/verb/banner/runbook = 1; box-provision = 2 — do NOT patch briefs, the close fence digests them).

**Wave 2 should take:** (1) the human executes box-provision (runbook is in the task evidence; D6 timing measurement rides the first real `bp cloud deploy staging`); (2) `bp cloud deploy staging --reset` (disposable-data verb the runbook already promises); (3) live-stream the deploy log (exec seam in sshrunner); (4) consider the banner on app.html.heex-rendered admin surfaces; (5) a real end-to-end smoke: branch → deploy → three curls → merge, timed against the seconds-to-minutes wish.
