# Azure–Hetzner Hosting — The Live-Smoke Wave (epic charter slot)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **pd-layout-engine ledger-reconcile** at
> `bp-pd-layout-ledger-reconcile-charter.md`, **parity-page** at `bp-parity-page-charter.md`
> (plus the earlier occupants it names in its own header note). This file is now the memory
> of the **azure-hetzner-hosting live-smoke wave**.
>
> CANONICAL DEEP MEMORY for this epic: `.claude/workflows/bp-azure-hetzner-hosting-charter.md`
> (16-slice roadmap, Decisions 1–48, wave logs 2026-07-09 a–l). This slot file carries THIS
> wave's decisions; the same entry is appended to the canonical charter's wave log so the
> epic memory never forks. Read the canonical charter for anything pre-dating 2026-07-11.

Epic anchor: bp task slug **`azure-hetzner-hosting-epic`** (published, 37 children: 32 done,
5 open at wave start). Wave Paper: **`azure-hetzner-hosting-epic-wave-2026-07-11`** (guerrilla,
style=article). This is the **flight-test wave**: waves 1–7 built the whole Azure–Hetzner
stack code-green and fixture-proven; this wave makes it touch real metal honestly, then
closes the live-smoke axis to ONE named human gate.

## Vision

A fresh box born from the LIVE warm pool (CP 178.105.92.191, WARM_POOL_SIZE=2, confirmed at
target) carries a beating barkpark-agent from birth — proven not by a green provision
envelope (agent install is non-fatal step 7b; green proves nothing) but by negative-grepping
the worker journal for the three WARNING shapes, watching real vitals in the Metrics tab and
`bp cloud instance top`, then stopping the service and watching live→stale flip on both
clocks. The lifecycle machinery (archive→resurrect→decommission) runs live on the only leg
credentials actually reach — the `--fast` snapshot path, drivable on HCLOUD_TOKEN alone —
while everything the bundle path needs is parked, never faked, as ONE human-gate task
carrying exact copy-paste recipes. The one real code gap ships: translateResurrect consumes
the archived shape hints (pin > archived hint > provider default, same-provider only,
refute-tested). Every smoke box gets a birth AND a death certificate; the before/after
orphan audit brackets the whole wave. When the wave lands, the live-smoke axis of the epic
is complete except one 15-minute human errand — named, recipe'd, filed.

## Operational facts (builders read FIRST)

- **Production is sacred**: guerrilla (157.180.90.121) and the CP (178.105.92.191) are never
  smoke targets; drive them only through public verbs. Pre-existing tenants in the compute
  project — damm, gyldendal-9d71ba21, gyldendal-506f035e, jeppsi (+ a 5th `gyldendal` row,
  team 'yo', host 167.233.194.23, and a `guerrilla` self-tracking row in the CP registry) —
  are CLASSIFIED LEGITIMATE (verified: hcloud labels + CP Postgres team joins). Never touch
  them; exclude them from smoke accounting.
- **Orphan-audit baseline (captured 2026-07-11, two-token invocation)**:
  `HCLOUD_TOKEN=<compute/'barkpark' hcloud-context token> BARKPARK_DNS_HCLOUD_TOKEN=$HETZNER_API_TOKEN
  bp cloud instance audit --provider hetzner -o json` → servers:6, archives:4, 7 findings
  (2 unlabeled-server = the idle warm spares; 5 dns-unmatched = known external records
  @/api/guerrilla/mail/www). The zone lives in a SEPARATE Hetzner project — a single-token
  audit 404s "Zone not found"; that is misconfig, not a bug. Post-smoke audits must match
  this baseline.
- **Two staleness clocks** (do not misread the lag as a bug): Metrics tab `beat.status`
  flips at READ time strictly when age > 180s (exactly 180s is still live; SPA polls 4s) —
  budget ~184s after `systemctl stop barkpark-agent`. Fleet `agent_status` offline is a
  SEPARATE per-minute Oban cron with a 2-tick debounce — budget ~300s worst case.
- **CP deploys mid-smoke kill jobs**: every merge touching `cloud/**` or `deploy/**`
  hard-restarts barkpark-provisioner (observed 5×/hr under merge traffic; ordinary CD, not
  a crash loop). Time smoke windows around ambient merge activity, not just your own.
- **deploy.yml cp flag fires only on `^(cloud|deploy)/`**: an `internal/**`-only merge (w8)
  NEVER redeploys the CP provisioner. The live bundle-path proof of w8 therefore rides the
  human-gate task (manual `deploy/cp-deploy.sh` or a cloud/deploy-touching merge), not this
  wave.
- **Billing firewall**: `bp go-live` on a not-entitled team AUTO-STARTS the one-ever free
  trial (durable `trial_started_at` stamp; NO teardown verb unwinds it — this is the real
  billing orphan). Always `mix barkpark_cloud.grant_forever <TEAM>` on the CP BEFORE the
  smoke go-live. The trial path creates no Stripe state; `--plan` is cosmetic.
- **Cloud CP login is self-serve, not a human gate**: `bp signup --email … --password …`
  (headless, no verification) mints user+team+session in one shot. `bp login` without
  `--device` does NOT fall back to the device flow in a non-TTY shell. The browser console
  at barkpark.cloud is the same SPA/account system (/new, /activate, dashboard).
- **Teardown paths (neither touches billing)**: product path `DELETE /v1/barkparks/:id`
  (team session; real deprovision worker; no archive residue) — preferred. Operator path
  `bp cloud instance decommission <fqdn> --no-archive --yes` needs THREE creds
  (HCLOUD_TOKEN + BARKPARK_DNS_HCLOUD_TOKEN + WORKER_TOKEN); without WORKER_TOKEN it
  orphans the CP registry row; without `--no-archive` it leaves a paid snapshot.
- **Gate quirk**: bare `go vet` fails on this host (cc alias shadows clang) — always
  `CC=clang`.

## Decisions (this wave; D49+ continue the canonical charter's numbering)

- **D49 — w8 is same-provider hint consumption, entirely in `internal/provisioner/`.**
  Three edits: provisioner.BundleManifest gains a Spec carrier; translateResurrect copies
  m.Spec instead of dropping it; CloudRestoreDriver.CreateHost applies pin > archived hint >
  provider default, gated `job.Kind == manifest.SourceProvider`. Why: verified at HEAD the
  hint is captured at archive time and discarded at the translate boundary; the precedence
  decision belongs in the provisioner adapter where both pin and manifest are visible.
- **D50 — Cross-provider size mapping: DEFERRED, ratified.** Cross-provider resurrects
  require an explicit operator pin until real demand. Why: no heuristic exists anywhere, the
  catalogs live at the wrong process boundary (Elixir CP vs Go worker), and guessing a table
  silently is the exact failure the canonical charter forbids ("do not guess it").
- **D51 — "archived sha" is loose wording.** No sha field exists in the bundle pipeline;
  the hint is BundleSpec{Region,ServerType} shape only. Why: verified by type-level read;
  builders must not chase a nonexistent field.
- **D52 — w8 is proven by refute-tests at merge, not by a live run this wave.** Why: the
  bundle path (archive AND resurrect, any provider) is gated on the 4 Console-minted S3 vars
  (provisioner logs "resurrect drain DEGRADED" naming them; /etc/barkpark-provisioner.env
  grep confirms all absent) — the SAME creds as the go-live human gate. The local `--once`
  drain escapes the CP redeploy but not the creds, and races the degraded live worker for
  the atomic claim. Park, don't fake.
- **D53 — w7's agent-drivable leg is the `--fast` snapshot lifecycle round-trip.** Archive→
  resurrect→decommission on a disposable smoke box, HCLOUD_TOKEN only (proven credential-
  disjoint from the bundle store at the auth-gate level). Why: it proves the lifecycle
  machinery live TODAY. Honesty clause: `--fast` bypasses bundles entirely, so it proves
  NOTHING about w8's hint tier — evidence must say so explicitly.
- **D54 — Both bundle legs + the Azure leg are parked on ONE human-gate task
  (`azh-go-live-human-gate`) with copy-paste recipes.** Why: S3 4-tuple (Hetzner Console,
  no API exists) and the Azure service-principal 4-tuple (the live az-CLI session is
  structurally unusable — code requires ClientSecretCredential env) are genuinely human;
  the wish's law is park-with-recipe, never fake.
- **D55 — w6 smoke recipe**: disposable team via `bp signup` → `grant_forever` on the CP →
  `bp go-live` → beat proven by worker-journal negative-grep (3 WARNING shapes) → Metrics
  tab + `bp cloud instance top` on real vitals → stop agent, prove BOTH clock flips → browser
  DOM pass (6-zone checklist, chrome-devtools, self-serve console login) → product-path
  teardown → post-audit matches baseline. Why: every step verified drivable with zero human
  involvement; grant_forever is the trial-burn firewall.
- **D56 — Azure SSH-user defect gets a code slice THIS wave.** The step runner hard-codes
  root; Azure boxes only provision the `barkpark` admin (key only in /home/barkpark; stock
  Canonical images lock root), and azure-base-install.sh requires root → the azure restore
  leg must SSH as `barkpark` and sudo-wrap. Why: proven at HEAD; left unfixed it wastes the
  human's one Azure-console shot at the gate.
- **D57 — s14d closed as superseded.** `azh-s14d-azure-base-install-live-smoke` (filed 41
  min before w7, same two criteria) is cancelled as a duplicate; its obligations live in
  w7's parked recipes + the human-gate task. Why: two open tasks for one obligation is the
  double-work hazard the canonical charter has hit twice.
- **D58 — Epic-scope honesty**: "closed to one human gate" holds for the LIVE-SMOKE axis
  only. Roadmap slices S8 (hetzner-native cutover), S11c (infra tab), S15 (styleguide),
  S16 (journey polish) remain deferred and are now FILED as a visible backlog rollup task,
  not silence. azh-w3-pricing-live-join-verify stays open as pre-existing backlog (likely
  agent-drivable: public no-auth API).
- **D59 — Audit-verb UX hint filed as backlog, not wave.** The verb works with two tokens;
  the fix is an error-message hint naming BARKPARK_DNS_HCLOUD_TOKEN on zone-404. Why: not
  blocking, cheap, worth having.

## Roadmap (this wave, integration order)

| # | Slice | Task | Size | Model | Surface |
|---|-------|------|------|-------|---------|
| 1 | Restore consumes bundle spec hints (pin > hint > default, same-provider, refute-tested) | azh-w8-consume-spec-hints | medium | opus | internal/provisioner |
| 2 | Azure restore SSH-user fix (barkpark + sudo on azure kind; hetzner byte-identical) | azh-azure-ssh-user-fix | medium | opus | internal/cli/cloud + internal/provisioner (sequenced after #1: shared restore_driver.go) |
| 3 | Live agent smoke: fresh warm-pool box, beat proof, both stale clocks, browser DOM pass, honest teardown | azh-w6-live-agent-smoke | large | fable | live CP + smoke box (evidence task, no repo files) |
| 4 | Live lifecycle smoke: --fast archive→resurrect→decommission round-trip + drivability survey + parked recipes | azh-w7-live-resurrect-smoke | large | fable | live Hetzner compute project (evidence task, no repo files) |

Backlog filed this wave: `azh-go-live-human-gate` (p1, THE sole remainder for the live-smoke
axis), `azh-audit-dns-token-hint` (p3), `azh-cp-registry-inventory-hygiene` (p3),
`azh-roadmap-tail-s8-s11c-s15-s16` (p3). Pre-existing kept open: `azh-w3-pricing-live-join-verify` (p3).

## Wave 6 Decisions (2026-07-13) — FINISH + HONEST-LEDGER (land the two unlanded wave-5 slices)

Wave Paper: **`felix-pristine-wave-6-2026-07-13`** (guerrilla, style=article). Wave 5 shipped and
MERGED 4 of 6 slices (vix ceiling #2897→merged path, LV telemetry, bokbasen pagination, Part XI
Paper #2900). Two slices were BUILT+reviewer-A- but never LANDED/CLOSED — they are local-only
branches with no PR. Wave 6 FINISHES exactly those two; it does NOT rebuild. Twelve wave-6 scouts +
three deep verifiers (full-24 SHA sweep, post-rebase seed-varied gate, close-mechanics) converged.

- **D23 — Wave 6 is FINISH + VERIFY-BEFORE-CLOSE, scoped TIGHT to the two unlanded slices.** Why:
  survey+verify cross-confirmed both wave-5 slices are BUILT and correct; "unlanded" means
  not-merged/not-closed, not not-built. Restamp = verify-and-close; async = rebase-and-land. Every
  other open Felix child is mapped-not-built (backlog). No fresh scouts; the 12 domains stay closed.
- **D24 — Ledger restamp (`task-felix-ledger-restamp`): VERIFY-AND-CLOSE via claim→close, NEVER raw
  mutate.** Why: the restamp mutations are already LIVE (all 24 published copies carry the asserted
  met-vectors; verify RAN a full-24 sweep — every cited SHA an ancestor of origin/main, criterion-vs-
  diff fidelity on 16 of 24, zero fabrication). The task is 5/5 met but lifecycle=open with an
  EXPIRED claim (epoch 6). Close mechanics (verify-proven): there is NO bare `set lifecycle_status`
  verb — `task.close` is claim/epoch-CAS-gated by design, so re-claim (fresh epoch) → `bp task close`.
  A raw `/v1/data/mutate` on lifecycle_status would bypass the exact CAS/work-digest fence this
  honest-ledger wave exists to protect. The builder re-runs the full-24 ancestry sweep against
  CURRENT origin/main as the close evidence — audit-grade, not inherited trust.
- **D25 — d328 OTP landmine: RESTAMP, not reopen (confirmed a THIRD time, live).** Why: fc9665e4/#2403
  genuinely tiers the top-level supervision tree (4 new supervisors + `supervision_isolation_test.exs`
  152L + `application_child_specs_test.exs` 87L); verify confirmed [T,T,T] on the ancestor commit and
  read the diff. The digest's "no landing commit" fabrication-landmine is REFUTED. Do NOT reopen. Rule
  of the wave: had it been genuinely unfixed, the correct move is REOPEN — never a fabricated commit
  (surfacing a false-done is a WIN).
- **D26 — #2390 pair is NOT a double-count; `task-a9adc82f820db065` STAYS [T,F,T].** Why: task-9e21c3f2
  (issue #2299) and task-a9adc82f (issue #2297) are distinct findings sharing one commit. a9adc82f's
  criterion[1] (reopen wall-time / `:erlang.external_size` byte at N=2000) is genuinely unmet — #2390
  measures only `:reductions` — so it stays honestly met:false with a duplicate-of note. The unmet
  measurement is filed as backlog, not force-stamped.
- **D27 — Async flip (`task-5a5e2c939a33a621`): LAND the 55-file set as-is; do NOT re-litigate or
  expand.** Why: 55 is the empirical honest ceiling — the analytic 230 was EMPIRICALLY UNSAFE (non-
  deterministic breakage across 4 grep-invisible hazard classes; see D14). origin/main has since
  advanced past the verify base and touched 10 of the 55 files, but ALL 55 flip-target
  `use …DataCase, async: false` lines survive on origin/main (confirmed) — so the flip RE-APPLIES
  deterministically off origin/main. Builder re-derives the 55-file flip (avoids cherry-pick context
  conflicts) rather than growing the set; expanding repeats the failure mode. Merge-gated criterion
  closed by the lead.
- **D28 — Async payoff recorded HONESTLY as net-neutral on current base, NOT −36%.** Why: verify RAN
  both seeds (0-fail) AND a same-seed baseline on current origin/main — flip 220.7s vs baseline 221.4s
  is FLAT (the −36% was true on the old base 47b8c0ce; today the serial sync tail dominates and
  absorbs the rebalance). The merge is justified by correctness (2 seeds, 0-fail), not a payoff
  number — distrust-vacuous-green cuts both ways. The builder re-stamps criterion[2] with the honest
  net-neutral evidence after the post-rebase gate.
- **D29 — 40P01 migration-DDL deadlock is a KNOWN pre-existing flake, not a wave-6 regression.** Why:
  `task-felix-migration-ddl-audit-deadlock` tracks it (workspace-delete-cascade DDL ACCESS-EXCLUSIVE
  lock vs a leaked fire-and-forget audit-dispatch Task). The 55-flip touches no DDL file but raises
  ambient concurrency on the audit path, so a 40P01 hit during the seed-varied gate is already-known,
  self-healing on isolated rerun — NOT a red flag. The wave Paper and PR note this explicitly to
  prevent a false alarm.
- **D30 — `task-f0bdb914d63a2e84` (the wish's "25th landmine") is already CLOSED this wave.** Why:
  lifecycle=done, closed_by=lead-opus 2026-07-13, all 4 criteria met citing #2870/821fcada (verified
  MERGED, mergeCommit an ancestor of origin/main). Genuinely fixed, honestly marked done — no restamp,
  no reopen, no action.
- **D31 — Both slices branch from ORIGIN/main (local checkout diverged +107/−54); isolated worktrees;
  `CC=/usr/bin/clang`; opus-only builders (Fable exhausted).** Restamp branch f6beac23 is a zero-diff
  audit anchor — no PR, no repo files. Async is a code PR the lead merges. D11/D12 hold unchanged.

### Wave 6 roadmap (2 opus slices, parallel — disjoint files)

1. **[P1] Ledger restamp — verify-and-close** — `task-felix-ledger-restamp` — opus. No repo files
   (ledger-only). Re-run the full-24 SHA-ancestry sweep against current origin/main, confirm every
   published copy's met-vector unchanged (a9adc82f stays [T,F,T]), then claim→close (fresh epoch;
   NEVER raw mutate). Gate: ancestry sweep prints all-ANCESTOR + `bp task get task-felix-ledger-restamp`
   shows lifecycle=done post-close.
2. **[P1] async flip — land the 55-file subset** — `task-5a5e2c939a33a621` — opus. Files: the 55
   `api/test/**_test.exs` files of commit 0b9dcf8c (re-derived off origin/main). Rebase/re-apply,
   two seed-varied `CC=/usr/bin/clang mix test` green (0-fail; a 40P01 hit is the known flake per D29),
   push + open PR; builder stamps [1][2][3] with honest net-neutral payoff (D28); LEAD closes [4]
   (merge gate). Gate: two `CC=/usr/bin/clang mix test --seed N` runs, 0 failures each.

Backlog (mapped-not-built this wave): 3 open Group-A felix PRs #2897/#2898/#2899 (tasks
`task-vix-bomb-explicit-ceiling` in_progress, LV-telemetry + bokbasen DONE — merge cleanup);
`task-felix-roothtml-durable-sobelow-skip`, `task-felix-interop-resource-bound-sweep`,
`task-felix-phantom-media-atomicity`, `task-felix-migration-ddl-audit-deadlock` (all open);
NEW `task-felix-a9adc82f-reopen-wall-time-measure` (the unmet #2390 N=2000 measurement).

## Wave log

- **Wave 6 — 2026-07-13 — DECIDED (building).** Ratified D23–D31. Two opus slices under
  `task-96a908af98698118`, both linked to `felix-pristine-wave-6-2026-07-13`: ledger restamp
  (verify-and-close, claim→close not raw mutate) and async flip (land the 55-file subset off
  origin/main, honest net-neutral payoff). Full-24 SHA sweep + post-rebase seed-varied gate proved
  green pre-decision. Backlog: 3 open felix PRs, 4 open backlog children, + new a9adc82f measurement
  gap. Fable exhausted — all builders opus. Grade: pending build+review.
- **Wave 5 — 2026-07-13 — SHIPPED (A-, per `felix-pristine-wave-5-2026-07-13`).** Ratified D13–D22.
  Merged 4 of 6: vix ceiling, LV telemetry, bokbasen pagination, Part XI verdict-table Paper. Two
  slices built+A- but left unlanded (ledger restamp, async flip) → carried to Wave 6 to LAND.
  Backlog seeded: root.html.heex durable skip, interop resource-bound sweep. Phantom-media parked.
- **Wave 4 — 2026-07-13 — SHIPPED (grade recorded prior).** Magick bound #2868, bokbasen
  mount-gate #2869, sobelow durable inline skip #2870 — all merged to origin/main.

### Wave 6 landed (2026-07-13, steward) — grade A-

Both unlanded wave-5 slices are now finished. **Async-flip** (`task-5a5e2c939a33a621`): PR **#2917** merged to main as `dd0c27ce` — 54 empirically-validated cargo-cult-serial DataCase files flipped `async:false→true` (accounts_test.exs excluded per a real seed-333 TOCTOU pool-contention flake — the honest ceiling; 230→54 after hazard-class reversion). Green `CC=/usr/bin/clang mix test` at seeds 111 (10365 tests, 0 failures) + 222; payoff recorded HONESTLY as net-neutral (wall-clock bounded by the serial sync pool), justified by correctness. Criterion 4 (merge gate) closed. **Ledger-restamp** (`task-felix-ledger-restamp`): VERIFY-AND-CLOSE — the full-24 SHA-ancestry sweep re-ran against current origin/main (all 22 unique merge commits ANCESTOR, zero fabrication; d328 RESTAMP-not-reopen on fc9665e4/#2403 confirmed a 3rd time; the #2390 pair stays honest [T,F,T]); task closed done, no PR (zero-diff audit anchor). Steward note: the #2917 task-gate red was a verified stale-event false-negative (trailer + active task confirmed, linkage real). Backlog filed: `task-4bc654f703da9d4a` (the a9adc82f N=2000 wall-time/byte honest-miss). **Next wave (7):** the open named-failure children — task-felix-roothtml-durable-sobelow-skip (durable inline `# sobelow_skip` to end baseline line-shift drift), task-felix-interop-resource-bound-sweep, task-felix-phantom-media-atomicity, task-felix-migration-ddl-audit-deadlock. (Group-A PRs #2897-2900 already merged — not backlog.)
