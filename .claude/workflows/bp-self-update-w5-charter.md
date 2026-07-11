# Self-update: from nag to product — W5 charter (product-grade update pipeline)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. The **airdrop-grants leak-seal** charter formerly here is preserved verbatim at
> `.claude/workflows/bp-airdrop-grants-leakseal-charter.md`. This file is the memory of the
> self-update epic's W5 wave onward.

Epic anchor: bp task slug **`self-update-epic`** — CLOSED done by the W7 reconcile wave
(2026-07-11): 20 children, 18 done, exactly TWO blessed open remainders
(`isu-backlog-rollback-live-smoke`, `isu-backlog-operator-principal`); the five other
backlog children were re-homed to top-level tasks (see W7 D28). Design paper:
`self-update-from-nag-to-product` (Barkpark Paper — amend it, don't fork it). W3 runbook:
`.claude/workflows/release-curator.md`. Server: guerrilla.

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
   **[SUPERSEDED by W6, 2026-07-11: the real rollback engine SHIPPED end-to-end in #2514 —
   see D11-D26. This decision was true for W5 only.]**
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
  API + console button — needs a Runner/script capability first) **[SHIPPED as W6, #2514]**;
  growing canary cohorts (v2 per worker moduledoc); maintenance-window gate for the rollout
  worker; CP-driven staging ref deploys (needs an operator SSH capability in the CP — decide
  deliberately, don't drift into it). **[W7 note: the unshipped items here were NOT filed as
  epic children — they remain deliberately unfiled; file them only when someone wants them.]**

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

---

# W6 — rollback becomes real (decided 2026-07-11)

Wave Paper: `self-update-epic-wave-2026-07-11`. Two exploration rounds + a 6-report verify
fleet ran before these decisions; every load-bearing claim below carries actually-run proof
(mix-staleness probe, live guerrilla ground truth, harness baseline, gate dry-runs).

## W6 Vision

An operator staring at a bad release clicks **Rollback** in the console or runs
`bp cloud rollback <instance>`; the instance resets its shared checkout to the idle slot's
recorded sha, reboots that slot, health-gates it on its own port, flips Caddy ONLY on
green, rewrites deploy STATE, and the CP atomically pins the instance at the rolled-back
version so the 5-minute rollout worker can never silently undo the operator. Every refusal
is typed and honest: no previous slot → says so; old slot boots dead → fail closed, Caddy
untouched, says so. One honest path, zero new capabilities — the verb is a mode of the
sanctioned deploy machinery riding the exact W5 relay seam.

## W6 Decisions (numbering continues from W5's D10)

11. **Flip+reset, never flip-only.** The mix-staleness probe REFUTED bare port-flip: a slot
    restart runs `mix phx.server` against the ONE shared checkout, and a stale build root
    recompiles NEW source (`Compiling 1 file… :V2_NEW_CODE`, beam sha flipped). The script's
    own "instant manual rollback" comment (instance-deploy.sh:264-265) is a lie for the beam.
    `git reset --hard <slot-sha>` restores OLD code byte-identically (probe: sha returned
    exactly to original, second run stable no-recompile) and is the script's own sanctioned
    failure-path idiom (:200-205,241,252,258). Why: proven restore, zero new capability.
12. **Per-slot version stamp, refuse without it.** Every deploy writes
    `.slots/<target>.sha` = $NEW when it writes the slot env files. Rollback reads
    `.slots/<other>.sha` and refuses `no_previous_slot` when the stamp OR a complete
    `_build_<other>/prod` is missing. Why: amnesia proven LIVE on guerrilla — STATE is one
    global sha, slot envs carry only port+build-root, and an auto-deploy was caught
    recycling the previous live slot ~8 minutes after retirement.
13. **Rollback lives IN instance-deploy.sh** as `--rollback` + `--rollback-preflight`
    modes sharing the SAME flock (:49-53). Preflight is synchronous and read-only: typed
    exit codes + prints `TARGET_SLOT=`/`TARGET_SHA=`. Why: one script owns slot truth; the
    lock makes rollback-vs-deploy a queue, never a race.
14. **Real health gate only.** Rollback reuses the BLOCKING pre-flip curl loop against the
    resurrected slot's own port (mirror :232-243); on unhealthy: slot disabled, Caddy
    untouched, checkout reset back to the live slot's sha, typed exit. The post-flip public
    curl (:260) is LOG-ONLY and must never be copied as a gate. Health gate proves
    boot+shallow endpoint, NOT schema compatibility — the copy says so.
15. **Instance API = POST /v1/admin/rollback** (same `require_admin` pipeline as
    self-update). Controller runs preflight synchronously → `202 {status:"started",
    target_sha}` then spawns the async Port (Runner single-flight SHARED with self-update —
    one run slot for both verbs); typed refusals: 409 `no_previous_slot`, 409
    `already_running`, 409 `not_supported` (no `.slots` box), 503 `feature_not_configured`
    (same BARKPARK_SELF_UPDATE_APPLY gate). Why: sync preflight hands the CP the pin value;
    async Port keeps the CP's 15s :httpc shape.
16. **CP relay = POST /v1/barkparks/:id/rollback, gated `require_primary_team_admin`** —
    the ONE gate reachable from a console session AND `bp login` (require_worker routes are
    operator-unreachable in prod, a pre-existing kill-switch bug filed to backlog, not
    repeated here). `Registry.trigger_rollback/2` (sibling of trigger_self_update) does NOT
    block on `pinned_release` — rollback re-pins by design; on instance 202 it atomically
    writes `pinned_release = <instance-reported target>` (never operator free-text), then
    enqueues UpdateStatusWorker `schedule_in: 60` + `push_event("fleet")` exactly like the
    update trigger. Why: an unpinned rollback is undone within one 5-min tick — a lie; a
    pinned one is immune with ZERO new worker logic.
17. **Pin-after-202 ordering, freeze-only semantics.** If the async run later fails closed,
    the pin stays at the intended target while status truth (BuildInfo via the refreshed
    UpdateStatusWorker) shows reality — a frozen box with an honest status beats an
    unpinned box that silently re-updates. pinned_release remains bookkeeping (OC10 law:
    a pin freezes, it never downgrades).
18. **Fleet halt does NOT suppress manual rollback.** The halt is the autonomous-rollout
    brake; the interactive update trigger already ignores it, rollback matches. Why: human
    override wins; two surfaces must not invent two answers.
19. **Schema stays forward.** Rollback is app-level only; its copy quotes the PROD_OPS law
    ("rolling back code does NOT undo the schema; write a compensating migration").
    Expand/contract remains a 3-place comment law scoped to the swap window — enforcement
    is backlog, not this wave.
20. **Shared-static accepted with healing.** git-reset heals the 31 git-tracked static
    files; `make wasm` re-runs at the OLD sha (non-fatal, degrades to fallback — existing
    precedent). Residual: priv is ONE shared symlinked dir (proven on guerrilla — both
    slots' priv readlink to /opt/barkpark/api/priv), so brief skew during the window and a
    functionally-equivalent (not byte-identical) wasm are documented v1 limitations. No
    per-slot priv snapshot (that's a new capability — out).
21. **STATE coherence.** `--rollback` rewrites `.instance-deploy-last` to the rolled-back
    sha. With the git reset this makes agent `git_commit`, coalesce logic, and the next
    deploy's OLD baseline all truthful; barkpark-agent's would-be lie fixes itself for free.
22. **OC10 does NOT disprove this design.** OC10 rejected PIN-DOWNGRADE via the git
    ff-only update path — a sibling dead end. Port-flip rollback flips to an already-built
    slot and moves the checkout with the sanctioned `reset --hard`, never a backward merge.
23. **Refusal vocabulary:** reuse `already_running` / `not_supported` /
    `feature_not_configured` / `no_admin_token` / `decrypt_failed` / `instance_error` /
    `instance_unreachable` verbatim; ADD `no_previous_slot` (409). Async unhealthy failure
    = script exit 24 `unhealthy_fail_closed`, surfaced through the status/log endpoint.
    CLI exit mapping: 409-family → exitConflict(6), 404 → exitNotFound(4), 502 →
    exitServer(8), auth → 3.
24. **Naming: "instance rollback".** Route lives under /v1/barkparks/:id (instances);
    console+test helpers use the `isu-w6` prefix. Explicitly distinct from the D7/D25
    SITE-deployment "Roll back to this" promote feature in app.js:5139-5175 and from
    Ecto `Repo.rollback` noise.
25. **Gate hygiene (stale figures corrected):** the offline harness has **68** checks
    today, not 49 — acceptance criteria use the real count; the harness is NOT CI-wired
    (backlog). ALL Go gate invocations carry `CC=clang` (the cc-alias landmine reds vet/
    test otherwise). cloud/ mix tests need Postgres reachable+migrated (`mix ecto.create &&
    mix ecto.migrate` on a fresh box) — there is no DB-free mix test in cloud/.
    `test/barkpark_cloud/registry/barkpark_test.exs` does not exist — never cite it.
26. **Live smoke PARKED as a recipe** (backlog task carries it): disposable box hand-minted
    from the warm image (staging-barkpark D2 recipe), Caddy `tls internal`, no real DNS
    (`curl --resolve`), TWO forward deploys to populate both slots, then rollback + deny
    cases. guerrilla is production AND the task ledger — never the first flip.

## W6 Contract pinned for parallel builders

- **Script:** `instance-deploy.sh --rollback-preflight` → exit 0 prints
  `TARGET_SLOT=<blue|green>` + `TARGET_SHA=<40-hex>`; exit 21 `no_previous_slot`;
  exit 22 `not_supported`; exit 23 lock-held (`already_running`). `--rollback` → exit 0
  success; exit 24 `unhealthy_fail_closed`; preflight codes apply. Deploy additionally
  writes `.slots/<target>.sha` on every run.
- **Instance:** `POST /v1/admin/rollback` → `202 {"status":"started","target_sha":"…"}` |
  `409 {"error":{"code":"no_previous_slot"|"already_running"|"not_supported"}}` |
  `503 {"error":{"code":"feature_not_configured"}}`.
- **CP:** `POST /v1/barkparks/:id/rollback` → `202 {"status":"started","target_sha":"…",
  "pinned_release":"…"}` | relays instance 409 codes verbatim | 404 team-scoped (no
  existence leak) | 404 `no_admin_token` | 500 `decrypt_failed` | 502
  `instance_unreachable`/`instance_error`. On 202 the CP has ALREADY pinned.
  If a builder's final names drift, the PR body says so and the lead reconciles.

## W6 Roadmap

- **W6-S1 (large, fable)** `isu-w6-rollback-script-stamp` — per-slot sha stamp +
  `--rollback`/`--rollback-preflight` in instance-deploy.sh + harness rollback cases
  (happy flip, no-previous-slot, unhealthy-fail-closed). The heart.
- **W6-S2 (medium, opus)** `isu-w6-instance-rollback-api` — instance route/controller/
  Runner rollback trigger (async Port, shared single-flight).
- **W6-S3 (medium, fable)** `isu-w6-cp-rollback-relay` — CP route + trigger_rollback +
  atomic pin write + status refresh + tests. The pin-atomicity slice.
- **W6-S4 (medium, opus)** `isu-w6-console-rollback-button` — console Rollback button in
  the isu-w5 update panel, typed conflict copy, escaping tests.
- **W6-S5 (medium, opus)** `isu-w6-cli-rollback-verb` — `bp cloud rollback <instance>` +
  cloudclient method, verify-style raw envelope, typed exit codes.

## W6 Wave log

### Wave 2026-07-11 — rollback becomes real (Review debrief; Paper self-update-epic-wave-2026-07-11)

**All 5 slices green, grade A.** The pinned contract held with zero drift across five
surfaces. Landed (final branches for the lead):

- **S1** `isu-w6-rollback-script-stamp` → `loop-epic/w6-1-rollback-becomes-real-in-instance-d-0`
  (unchanged by review). Per-slot stamp (D12), `--rollback-preflight` typed exits 21/22/23 +
  `TARGET_SLOT=`/`TARGET_SHA=`, `--rollback` flip+reset with blocking own-port health gate,
  fail-closed exit 24 (Caddy byte-identical), STATE rewrite (D21), :264-265 lie rewritten.
  Harness 68→99 checks ALL PASS (re-run at Review).
- **S2** `isu-w6-instance-rollback-api` → `loop-epic/w6-2-instance-rollback-api-post-v1-admin-1-r`
  (review: mix-format only + this wave-log entry). POST /v1/admin/rollback, sync preflight →
  typed 409s / 503, exit-0-no-sha fails CLOSED (500), async Port SHARING one run slot with
  self-update, status gains `mode`. 40/0 re-run at Review. **Waits Elixir Test CI.**
- **S3** `isu-w6-cp-rollback-relay` → `loop-epic/w6-3-cp-rollback-relay-team-admin-gated--2`
  (unchanged). CP route + `trigger_rollback` (NO pin precondition, D16), pin = instance-REPORTED
  sha written before the 202 (DB-proven), D23 relays verbatim, halt doesn't gate (D18),
  self-update trigger refactored onto shared `relay_admin_post` (sibling 7/0). 27/0 re-run at
  Review. **Waits Elixir Test CI; cloud/** merge briefly 503s the CP.**
- **S4** `isu-w6-console-rollback-button` → `loop-epic/w6-4-console-rollback-button-typed-confl-3-r`
  (review FIX: `rollbackConflictCopy` maps `not_live` — w5 update-trio parity — pinned in the
  node suite). D19 confirm copy, data-rollback button, typed toasts, escaping tests. 388/388.
- **S5** `isu-w6-cli-rollback-verb` → `loop-epic/w6-5-bp-cloud-rollback-instance-cli-twin-4`
  (unchanged). `bp cloud rollback`: Raw-verbatim `-o json`, both refusal shapes decoded, exit
  ladder by status family, honest STARTED-not-done verdict + pin + schema-forward law.

Residuals (documented in code, not debt tickets): exit 24 reused for caddy-validate/reload
failures during the rollback flip (logs disambiguate); pin write non-transactional with the
instance call (degrades to honest 202 with old pin); fail-closed wasm skew mirrors the forward
path (D20). Ledger audit clean — evidence stamped live, merge-gated criteria left open.

**Stalled:** nothing. Live smoke is scoped out (D26), not stalled.

**Next wave:** (1) THE LIVE SMOKE — staging box from the warm image, two forward deploys, then
rollback + deny cases (the D26 recipe; the one gap between proven-offline and proven);
(2) operator-principal decision (W5 carry — unblocks console halt/resume + the require_worker
reachability bug); (3) CI-wire the 99-check deploy harness (D25 backlog); (4) charter residue:
growing cohorts, maintenance windows.

**[W7 close-out annotation, 2026-07-11 — disposition of the four items above:** (1) live smoke
stays PARKED as blessed remainder `isu-backlog-rollback-live-smoke` (recipe made stranger-grade
in W7); (2) operator-principal stays the second blessed remainder
`isu-backlog-operator-principal` (W5 open-decision #1 text inlined verbatim); (3) harness CI
wiring re-homed to top-level task `isu-backlog-harness-ci-wiring` — real, still-open, NOT an
epic remainder; (4) growing cohorts + maintenance windows remain deliberately unfiled per the
W6-candidates note. The epic is CLOSED; this file is its durable memory.**]**

---

# W7 — final ledger reconcile (decided 2026-07-11; the closing wave)

Wave Paper: `self-update-epic-wave-2026-07-11-reconcile`. Two exploration rounds + a 7-report
verify fleet ran. HEAD = 703c5406 (#2514). ZERO build slices — D12 held: every gate green
(instance-deploy harness 99/99, cp-deploy 7/7, cloud Elixir 44/0 + registry 24/0, api Elixir
27/0, Go 1060 PASS / 0 FAIL across internal/cli+cloudclient, SPA 388/388, go build+vet clean).
This wave is ledger, paper, and park work ONLY — no repo code changes.

## W7 Decisions (numbering continues from W6's D26)

27. **Close the epic done with exactly two open blessed children.** Empirically proven safe on
    guerrilla: no server-side parent-with-open-children guard; close of an UNCLAIMED task
    accepts any epoch (fencing skipped when claim=null); one `task.closed` event, no cascade.
    Sequence law: patch description FIRST via /v1/data/mutate, then `bp task close
    self-update-epic <worker> 0 done "…"` — NEVER flip lifecycle_status via raw mutate (skips
    the mutation event + cascade). Why: task-system semantics allow it and re-homing the two
    blessed remainders would orphan them from the epic story they belong to.
28. **The five non-blessed open backlog children re-home to TOP-LEVEL tasks** (parent_id
    cleared, provenance note added): isu-backlog-cloud-update-trigger-verb,
    isu-backlog-fetch-prebuilt-slots-guard, isu-backlog-slot-box-branch-hygiene,
    isu-backlog-harness-ci-wiring, isu-backlog-expand-contract-enforcement. All five were
    individually proven still-open at HEAD (no update verb in runCloud dispatch; zero
    "slots" in fetch-prebuilt.sh; branch d889aa08 still on origin; no harness refs in
    .github/workflows; expand/contract prose-only in 3 files). None shipped, none foldable
    into the blessed two, none closed. Why: the closed epic must read as done + exactly two
    deliberate threads; these five are real future work that outlives the epic.
29. **dwb-6 is SHIPPED — stamp all 4 criteria and close it (PR #773, merged 2026-07-02).**
    C1 run-pinned (SSE narration/elapsed: app.js:8107/8144/8385-8392, __app.test.mjs 388/388);
    C2 code-present (newLaunch app.js:8012-8028 optimistic flip + immediate progress);
    C3 code-present (newRenderFailed app.js:8839, Retry→/retry app.js:8866, router.ex:1457);
    C4 code-present (double-submit guard app.js:8015-8017 + 409 reconcile). The owed manual
    browser pass (PR #773's own note) folds into dwb-12's framing, not a reason to hold open.
30. **The six done-with-0/N dwb children are STAMPING DEBT, not false-done — stamp, never
    reopen:** dwb-14/15 (#783), dwb-16 (#798; control-url pin cp-deploy.sh:120-140,
    cp-deploy_test.sh 7/7; console app.js:8200-8247), dwb-17 (#1080/#748), dwb-19 (#890;
    persistence provision_job.ex:92-96 + router.ex:6089,6127 + app.js:8469-8482), dwb-20
    (#914; warmpool.go:761,771-778,1207). None of PRs #783/#798/#890/#914/#1080 was reverted.
    PATH LAW: the rollout worker test lives at
    cloud/test/barkpark_cloud/autoupdate_rollout_worker_test.exs — NO workers/ segment;
    never cite the workers/ path.
31. **The NINE zero-evidence done dwb children (gh-2..6, dwb-1/3/5/8) get evidence backfill:**
    PR-hunt via git log, write code_refs.prs + close_reason. If no PR is found for one, add an
    honest `close_reason: "evidence not reconstructible — done on lifecycle only"` note; do
    NOT reopen without proof of absence of the work itself.
32. **dwb-9 stays OPEN, split-stamped:** criterion 1 (README badge) IS shipped — stamp met
    (README.md:4, cloud/priv/static/button.svg, router.ex:193, PR #795). Criterion 2 (launch
    docs page) is a genuine not_found (templates/DEPLOYING.md and cloud/README.md:17 are
    DIFFERENT admin-facing flows); note that "to live site + Studio" cannot be honestly
    documented yet — Studio one-click entry is itself missing (paper item (g), token-paste-only).
33. **Human gates park as explicit recipes:** gh-1 THICKENED (compose passes only
    GITHUB_OAUTH_* at docker-compose.yml:47-48 — the GITHUB_APP_ID / GITHUB_APP_PRIVATE_KEY /
    GITHUB_APP_WEBHOOK_SECRET / GITHUB_APP_SLUG passthrough lines must be ADDED; exact GitHub
    permission scopes named). NEW task `dwb-vercel-token-gate` authored — the Vercel gate had
    ZERO task and ZERO doc: VERCEL_PLATFORM_TOKEN (+optional VERCEL_TEAM_ID),
    cloud/config/runtime.exs:169-188, vercel.ex:52-56 configured?, compose passthrough ALREADY
    exists (docker-compose.yml:55-58), absent token → 503 + classic clone-URL fallback.
34. **Warm-pool memory conflict resolved by SUBSYSTEM SPLIT — never conflate again:**
    instance warm-pool is LIVE (WARM_POOL_SIZE=2 in /etc/barkpark-provisioner.env on CP host
    178.105.92.191, barkpark-provisioner.service active, re-confirmed 2026-07-11); the off-box
    SITE builder is merged source only, never deployed (no systemd unit, no binary anywhere on
    the box, only /opt/barkpark/cmd/barkpark-builder/main.go). Park text must state both halves.
35. **dwb-builder-cross-tenant-auth is FIXED, stays done, no security surfacing:** PR #936
    (2026-07-08) re-gated all four builder routes require_worker (router.ex:4817/4858/4935/4968);
    live CP 401s anonymous + bogus tokens. Add #936 to its code_refs.prs. The stale pre-fix
    moduledoc header (router.ex:4751-4758) is a backlog microfix, NOT a W7 code touch (D12).
36. **Papers get truth this wave:** `self-update-from-nag-to-product` is REWRITTEN as
    style=article blocks (it is legacy body_html, unrenderable by bp paper view) with the full
    W1-W6 arc (#1195/#1197/#1199/#1230/#2227/#2514) and its "Still open" list reconciled to
    the two blessed remainders. `deploy-with-barkpark` gains a "Parked remainders" block naming
    VERCEL_PLATFORM_TOKEN + the GITHUB_APP_* set with file:line seams, and the warm-pool/builder
    split (D34).
37. **Publish-collapse worklist = parent + 28 children = 29 docs** (dwb-16 AND lvd-t5-task are
    already published — the "29 children" figure double-counted lvd-t5-task). Law: every slice
    publish-collapses its OWN drafts.* touches; a final sweep slice proves zero drafts.dwb*
    remain. Draft-form reads need the authed /w/default/... path (public endpoint 404s drafts).
38. **lvd-t5-task is mis-parented Living-Values contamination** — re-home it off dwb
    (clear parent_id + provenance note); the dwb close-out narrative carves it out explicitly.
39. **The blessed remainders become stranger-grade:** isu-backlog-rollback-live-smoke's WRONG
    citation "health gate uses curl --resolve (instance-deploy.sh:259)" is corrected (line 259
    is the Caddy maintenance-page HTML; the BLOCKING gate is the plain localhost curl loop —
    D14's law; the --resolve public curl is LOG-ONLY) and the recipe gains: warm-image selector
    (`hcloud image list --type snapshot --selector role=warm-image` per bake-server-image.sh:60),
    SSH root + ~/.ssh/barkpark_indx, a pasteable `tls internal` Caddy block, `hcloud server
    delete`, and the Hetzner-token note. isu-backlog-operator-principal inlines the W5 wave-log
    open-decision #1 text VERBATIM (charter lines above) before this file goes cold. GitHub
    mirrors (#2486/#2485) get the same corrections.
40. **GitHub mirror settles with the epic:** issue 2181 (FRIKKern/barkpark) must end closed —
    verify the task-sync closed it; if not, `gh issue close 2181` with a close-out comment.

## W7 Wave plan (6 slices, ledger/paper only, zero repo code)

- **S1 (fable)** `isu-reconcile-epic-close` — epic description rewrite (full W1-W6 arc + PR
  trail), fix both blessed remainders (D39), re-home the five (D28), close the epic (D27),
  settle GH mirror (D40).
- **S2 (opus)** `isu-reconcile-nag-paper` — rewrite self-update-from-nag-to-product as
  style=article blocks with W1-W6 truth (D36).
- **S3 (opus)** `dwb-reconcile-stamp-pack` — stamp the six 0/N done children + close dwb-6 +
  split-stamp dwb-9 + add #936 to builder-auth code_refs (D29/D30/D32/D35); collapse own touches.
- **S4 (opus)** `dwb-reconcile-evidence-backfill` — PR-hunt the nine zero-evidence done
  children (D31); re-home lvd-t5-task (D38); collapse own touches.
- **S5 (fable)** `dwb-reconcile-human-gate-parks` — gh-1 thickening + NEW dwb-vercel-token-gate
  + dwb parent parked-state description (D33/D34) + deploy-with-barkpark paper block (D36);
  collapse own touches.
- **S6 (opus)** `dwb-reconcile-publish-collapse` — runs LAST: sweep-publish every remaining
  drafts.dwb* doc; prove bare-id 200 / drafts.<id> 404 for parent + all 28 (D37).

Backlog filed (published, honest): `dwb-doc-lag-microfixes` (stale router.ex:4751-4758 builder
auth header + stale example domain in cmd/barkpark-provisioner/main.go doc comment — tiny code
touches, next wave), `dwb-launch-flow-double-submit-test` (router_launch_flow_test.exs has no
explicit double-submit/409 case — C4's server half untested in Elixir).
### Wave 2026-07-11 — W7 final ledger reconcile (Review debrief; Paper self-update-epic-wave-2026-07-11-reconcile)

**EPIC CLOSED. Grade A-.** Zero build slices (D12 held — the regression probe + 7-report
verify fleet found nothing broken at 703c5406); six ledger/paper slices, all substance
verified true at Review. Landed (branches are empty ledger markers — merging optional):

- **S1 `isu-reconcile-epic-close`** → `loop-epic/epic-close-out-self-update-epic-reads-as-0`.
  self-update-epic CLOSED as the W1–W6 story (#1195 #1197 #1199 #1230 #2227 #2514), exactly
  two blessed open remainders (live-smoke recipe now stranger-grade with the :259/--resolve
  lie corrected — re-proven against instance-deploy.sh at HEAD; operator-principal inlines
  W5 open-decision #1 verbatim), five non-blessed children re-homed top-level with
  provenance, GH 2181 closed + 2485/2486 mirrored. Builder proved a real bug in its own
  literal gate: the tasks API emits `children` as a SIBLING of `doc`
  (tasks_controller.ex ~257-264) — gate authors read children from the response root.
- **S2 `isu-reconcile-nag-paper`** — paper `self-update-from-nag-to-product` now
  style=article Rev 3, renders in `bp paper view`, full W1–W6 arc, body_html cleared.
- **S3 `dwb-reconcile-stamp-pack`** → `loop-epic/dwb-stamp-pack-six-done-with-0-n-childre-2`.
  dwb-14/15/16/17/19/20 stamped from the verifier pack, dwb-6 closed shipped (#773, its
  criteria are dwb-2-independent — mutate-close sanctioned), dwb-9 split-stamped, #936 on
  the auth task. Review re-ran SPA 388/388 + cp-deploy 7/7; dwb-9 evidence byte-exact at HEAD.
- **S4 `dwb-reconcile-evidence-backfill`** — nine zero-evidence done children carry real PR
  trails (spot-verified: gh-2=#814 gh-3=#821 gh-4=#818 gh-5=#815 dwb-1=#722 dwb-8→#724);
  lvd-t5-task re-homed. **Review FIX:** the builder hit the `bp task stamp --criterion`
  0-vs-1-indexed trap — every evidence string shifted one slot down and the MERGE-GATE
  criterion was falsely met; reviewer realigned the array (4/5, merge-gate honestly open).
- **S5 `dwb-reconcile-human-gate-parks`** → `loop-epic/dwb-parks-honestly-vercel-token-gate-get-4`.
  dwb-vercel-token-gate authored (first VERCEL_PLATFORM_TOKEN recipe), gh-1 thickened
  (compose GITHUB_APP_* passthrough gap), dwb parent = six-part parked story (D34 split
  held), deploy-with-barkpark paper carries Parked-remainders. This builder's off-by-one
  warning led review straight to S4's mis-stamp.
- **S6 `dwb-reconcile-publish-collapse`** — stalled honestly (dispatched while two
  predecessors were mid-write on its worklist; builder held the sweep, recorded --miss).
  **Reviewer completed it post-settle:** 8 residual publishes, 32/32 bare-200/drafts-404,
  zero drafts.* in the parent_id==dwb raw query; criteria 0-2 stamped with reviewer
  attribution. Dispatch lesson: RUNS-LAST slices must not enter the frontier until
  predecessors report built.

Review also fixed the wave Paper itself: raw-mutate had written body.blocks with no
top-level `blocks` mirror (bp paper view refused it) and the status line still said
SURVEYING — re-upserted via bulldocs publish with a dated correction note. Paper writers:
set `blocks` top-level or use the bulldocs path.

**Lead closes on merge:** the six merge-gate criteria (S1 c5, S2 c4, S3 c6, S4 c4, S5 c5,
S6 c3); expect 409 doc_changed_since_claim where criteria were patched out-of-band — re-claim
resolves. Stamp trap for every future wave: `bp task stamp --criterion N` is 0-INDEXED.

**Next:** nothing is owed on this epic until a gate opens — the two blessed remainders
(D26 live smoke; operator-principal decision GH 2485), the dwb human gates (gh-1 App
registration + compose passthrough; dwb-vercel-token-gate), then harness CI wiring,
growing cohorts, maintenance windows.
