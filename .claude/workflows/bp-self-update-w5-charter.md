# Self-update: from nag to product — W5 charter (product-grade update pipeline)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **airdrop-grants leak-seal** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-airdrop-grants-leakseal-charter.md`. This file is the memory of the
> self-update epic's W5 wave onward.

Epic anchor: bp task slug **`self-update-epic`** (published, lifecycle open, priority 1,
3 done children W2–W4). Design paper: `self-update-from-nag-to-product` (Barkpark Paper —
amend it, don't fork it). W3 runbook: `.claude/workflows/release-curator.md`. Server: guerrilla.

## Vision

A blessed release rides ONE train: the curator judges main → a GitHub Release exists → the
**staging-channel instance** picks it up first via the ordinary self-update relay → it settles
`current` (that IS the smoke) → the fleet rolls serial, health-gated, with a **fleet-wide
operator kill switch**. An operator opens the cloud console or runs `bp cloud status` and sees
honest per-instance update truth — running version, available version, channel, last check,
pin/pause state — and can pin, pause, halt, and resume without SSH. The curator's daily
judgment lands in a human inbox, not a run log. Pinning is honest: nothing (including the
manual console Update button) updates past a pin without an explicit force.

## Non-negotiable operational facts (builders read FIRST)

- guerrilla deploys ONLY via instance-deploy.sh (hook-suppressed law). cloud/** merges
  briefly 503 the control plane. api/** auto-deploys on merge. .ex changes WAIT for the
  Elixir Test CI gate. Worktrees from origin/main after `git fetch`. Claim BEFORE working.
  PR body carries `Task: <id>`.
- Elixir local gate = targeted unit tests only (`CC=clang mix test <file>`), no DB-boot,
  never prod compile. Cloud SPA gate = `node --check cloud/priv/static/app.js` +
  `node cloud/priv/static/__app.test.mjs`. Go gate = `CC=clang go build ./... && go vet
  ./internal/cli/... && go test ./internal/cli/...`.
- staging.barkpark.cloud does NOT exist yet (box-provision is human-gated on the separate
  Hetzner DNS token) — nothing in this wave may hard-depend on a live staging box.

## Decisions

1. **Ledger truth over rebuild.** W1–W4 code is MERGED (#1195/#1197/#1199/#1230); the 0/9
   unevidenced criteria are documentation lag. Attach PR evidence — do NOT reopen or
   re-implement. Why: reopening duplicates merged code (per-tenant policy, settle gate,
   per-instance pause all exist with tests — router_autoupdate_test.exs proves the policy path).
2. **Cohort-of-1 is the ratified W4 canary design.** Re-word isu-w4 crit 1 to match the
   shipped serial rollout; growing parallel cohorts stay an explicitly-deferred v2 (the
   worker's own moduledoc says so, autoupdate_rollout_worker.ex:28-31). Why: the paper's
   "cohort size" open decision was settled in code by #1230.
3. **Canary = cohort-0 over the existing self-update relay — NOT the #2074 CLI seam.** The
   control plane has no repo checkout and no operator SSH key; `bp cloud deploy` stays a
   human, local, pre-merge verb. The autonomous train gets a `channel` column ("prod"
   default, "staging") on registry barkparks: the worker advances the staging box first and
   refuses to advance any prod box until a staging box is settled-current on the latest
   release. Why: reuses the settle mechanism the worker already trusts
   (settle_in_flight, worker.ex:60-97); bridging CP→SSH is a new capability this wave
   doesn't need and must not drift into.
4. **Staging gate fails OPEN when no staging-channel box is registered, CLOSED once one
   exists.** Why: staging.barkpark.cloud is human-gated and doesn't exist yet; the wave must
   ship without it and harden automatically the day the box lands.
5. **Kill switch = persisted fleet-wide halt in the CP DB** (`autoupdate_halted`), exposed
   via operator-gated routes `GET /v1/admin/autoupdate` → `{"halted": bool}` and
   `POST /v1/admin/autoupdate/halt` / `POST /v1/admin/autoupdate/resume`, checked FIRST by
   the worker every tick. Why: per-instance pause is a tenant affordance, not an operator
   brake; "disable the Oban cron" is not a product.
6. **Pin honesty: a pinned instance refuses non-forced triggers.** The CP trigger path
   (console Update button relay + worker) rejects when `pinned_release` is set unless the
   request carries `force:true`. Why: today the manual button silently bypasses a pin
   (scripts/self-update.sh ff-merges to HEAD) — exactly the dishonesty the wish names.
7. **Rollback v1 = surfaced pinning, not a rollback engine.** Pin-to-a-release is the honest
   affordance that exists; the blue/green Caddy port-flip rollback API is a named W6
   candidate (bp-cloud-console-charter OC10), not this wave. Why: no rollback capability
   exists at any layer — surfacing a fake button would violate the epic's own thesis.
8. **Bless policy (ratifies the paper's open decision):** agent-proposes/human-publishes
   stays the default; autonomous tag-on-green is authorized ONLY on a fleet whose staging
   gate is live (a staging-channel box exists and gates the rollout). Why: closes W3 crit 3
   by written policy and resolves the "autonomous armed but unratified" governance gap — the
   canary train is the safety argument that makes autonomy defensible.
9. **Digest = plain-text Oban `DailyDigestWorker` in cloud/, recipients = platform-admin
   users** (the `create_admin` operator model; the team-scoped exfiltration guard stays
   intact). It is NOT a gui-premium "email type" — that system renders paper blocks and
   never sends. Curator and digest are joined by the GitHub Release as the shared fact, not
   a shared tick (the curator runs out-of-BEAM). Why: smallest true push-to-inbox; a rich
   rendered digest would be cross-app (cloud has no PortableDoc renderer).
10. **Contract pinned for parallel builders:** the fleet-list JSON (cloud router.ex ~5838)
    ADDITIONALLY emits `autoupdate_enabled`, `autoupdate_paused`, `pinned_release`,
    `channel`, `update_checked_at`; `PATCH /v1/barkparks/:id/autoupdate` additionally
    accepts `channel`; fleet halt reads/writes the routes in D5. S3 (console) and S4 (CLI)
    build against these names with fixtures; S2 owns the emission. If S2's final names
    drift, S2's PR description must say so and the lead reconciles before merging S3/S4.

## Roadmap

- **W5-S1 (small)** `isu-w5-ledger-paper-reconcile` — attach real PR evidence to all W1–W4
  criteria, re-word W4 crit 1 to the ratified design, fix the stale epic description, amend
  the design paper (rev 2) with settled decisions + the W5 slices + the ratified bless policy.
- **W5-S2 (large)** `isu-w5-canary-gated-fleet` — `channel` column + staging-green gate in
  AutoupdateRolloutWorker + fleet-wide kill switch + pin-honest trigger. The spine.
- **W5-S3 (medium)** `isu-w5-console-update-panel` — operator update panel in the cloud
  console SPA: per-instance truth + pin/pause/resume writes + fleet halt switch. The face.
- **W5-S4 (medium)** `isu-w5-cli-update-truth` — `bp cloud` decodes full update+policy
  truth; `bp cloud autoupdate pin|unpin|pause|resume` + `bp cloud rollout halt|resume|status`.
- **W5-S5 (medium)** `isu-w5-curator-digest-email` — daily plain-text fleet update digest
  mailed to platform admins.
- **W6 candidates (deliberately unfiled):** blue/green rollback verb (Caddy port-flip as an
  API + console button — needs a Runner/script capability first); growing canary cohorts
  (v2 per worker moduledoc); maintenance-window gate for the rollout worker; CP-driven
  staging ref deploys (needs an operator SSH capability in the CP — decide deliberately,
  don't drift into it).

## Wave log

### Wave 2026-07-10 — W5, all five slices green

**Landed (review-fixed branches, `-r` suffix = integrate these):**

- **S1 `isu-w5-ledger-paper-reconcile`** — no-code slice, all mutations server-side on
  guerrilla and VERIFIED: isu-w2/w3/w4 all criteria met+evidenced+published, epic anchor
  description current (W1–W4 PRs, five W5 slices, stale Remaining line gone), paper at
  rev 2 with settled decisions + ratified bless policy (D8). Its own task honestly
  in_progress with the lead-verify criterion open.
- **S2 `loop-epic/w5-2-canary-gated-fleet-rollout-channel--1-r`** — channel column +
  staging-green gate + fleet kill switch + pin-honest 409; 47/0 targeted + 250/0 adjacent.
  Review added: (a) the 409 pin body now NAMES the pin (`error.pinned_release`) so the
  console modal can say which release holds the box; (b) fleet JSON emits
  `autoupdate_triggered_at` — without it S3's "Updating" in-flight badge could never fire.
- **S3 `loop-epic/w5-3-console-operator-update-panel-per-i-2-r`** — operator update panel +
  pin/pause/halt affordances; 383/0. Review fixed a REAL merge-blocking bug: the
  fleet-rollout banner probe hit the worker-gated `/v1/admin/autoupdate` without
  `noBounce`, so the 401 would clearSession() and LOG THE OPERATOR OUT on every fleet
  render once S2 merges.
- **S4 `loop-epic/w5-4-bp-cloud-update-truth-full-version--3-r`** — tolerant decode +
  status columns + autoupdate/rollout verbs; full Go gate green. Review fixed vocabulary
  honesty: channel is prod/staging (not the invented stable/canary), and the rollout
  help/403 copy now says platform-operator (not team-admin — a refused operator would
  chase the wrong fix).
- **S5 `loop-epic/w5-5-curator-digest-email-daily-fleet-up-4-r`** — DailyDigestWorker +
  DigestEmail + allowlist recipient resolution; 6/0 + notifications 26/0. Review: mix
  format only.

**Open decisions the wave surfaced (lead / next wave):**

1. **The kill switch is operator-honest but operator-unreachable.** The D5 routes are gated
   by `require_worker` (the faceless WORKER token). Neither the console SPA (session token)
   nor `bp cloud rollout` (cloud session token) can pass it — both degrade honestly (hidden
   banner / clear refusal), but today halt/resume is curl-with-WORKER_TOKEN only.
   Deliberate next step: either a platform-admin principal (S5 hit the same gap — there is
   NO admin marker on User; it invented a `:platform_admin_emails` allowlist) or bless the
   worker-token-only posture and say so in ops docs. Do NOT let two more surfaces invent
   two more answers.
2. **S5 recipient deviation, needs a nod:** the brief said "find the create_admin marker";
   no such marker exists (roles are strictly per-team), so recipients = configured
   `:platform_admin_emails` ∩ registered users, empty = logged no-op. Honest and safe, but
   an unconfigured prod fleet sends NOTHING — wire `PLATFORM_ADMIN_EMAILS` into runtime.exs
   (trivial follow-up, deliberately not wired this wave) and set it on the CP.
3. **Multi-staging-box gate semantics:** `staging_gate_open?` is ANY-current-on-latest —
   with several staging boxes, one green canary opens prod past a red sibling. Exact
   single-canary behavior matches the charter; revisit only if a second staging box ever
   exists.

**Merge notes:** S2/S5 are .ex → wait for Elixir Test; both cloud/** (brief CP 503 on
merge; migration on S2 — channel column + fleet_settings). S3 static-only, S4 Go-only —
own gates. No file overlap between slices; any merge order works, but S2 first makes
S3/S4 live truth immediately. Lead closes each task's merge-gated criterion + lifecycle
on merge, and re-reads isu-w5-ledger-paper-reconcile before closing (its criteria were
patched out-of-band → close may 409 doc_changed_since_claim, expected). NOTE: this
charter file was an UNCOMMITTED working-copy file in the shared checkout and got
clobbered mid-wave — the reviewer restored it verbatim (+ this wave log) on the S2 `-r`
branch, and preserved the prior airdrop-grants slot content at
`.claude/workflows/bp-airdrop-grants-leakseal-charter.md` per this file's own header note.
Merging S2-r makes the charter durable; don't lose it again.

**Next wave (W6 candidates, from the charter + this wave's residue):** operator-principal
decision (see #1 — it unblocks console halt/resume for real), runtime.exs
PLATFORM_ADMIN_EMAILS + set it on the CP, provision the actual staging box (human-gated
DNS token) so the canary train stops failing open, then the deliberately-unfiled charter
W6 list (blue/green rollback verb, growing cohorts, maintenance windows).
