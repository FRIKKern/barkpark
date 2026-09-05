# CLOSE PACKET — tgw-* / pdf-* open 0-met rows (2026-08-23, origin/main afe7f98c73)

Set: 59 rows (35 tgw, 24 pdf), derived from a full 7,003-doc offset walk of
guerrilla /v1/data/query/production/task (15 pages x 500, unique==7003; bp CLI was 429
rate-limited all session — walk used the query endpoint the tgw12 recipe pins).
Criterion texts: byte-exact in <row>__crit<N>.txt beside this file; bytes+sha256 in MANIFEST.txt.
Indices are ZERO-BASED. Do not stamp/close from this packet without re-running the named measurement.

## CHAIN 1 — the wave-15 merge wake (already landed, rows read 0/N forever)

1. tgw2-verify-writes-back — STRANDED-PREDECESSOR (0/7, claim held by dead worker).
   Work landed under the tgw3 wave's PR: e43a2e82d7 "feat(grip): verify writes ledger rows,
   Decide commits them (tgw3) (#5185)" (git log -S "you may WRITE re-derivation recipe rows"),
   refined by 5c807ccf66 (#6688) (git log -S "THE SAME PR CARRIES THIS RUN'S LEDGER ROWS").
   Measurement: origin/main bp-epic-cycle.workflow.js:778 carries the verifier carve-out verbatim
   (one new file under tooling/grip/ledger/, never commit, worktree assignments DENIED);
   :866 carries Decide's explicit-path ledger commit with the git add -A ban; :321/:728 rule the
   stranded-file case. Unmet: 0,1,2,3,4,5,6 — content for 0-5 is on main; 6 (merge) satisfied by #5185.

2. tgw10-bl-record-mjs-untested — ALREADY-DONE.
   tooling/grip/test/record.test.mjs EXISTS on origin/main; landing commit (diff-filter=A)
   41b16d78db "test(grip): fail-before-plant coverage for the BAD-DEPS admitFact class (#12183)"
   2026-08-18. Unmet 0-4. Residue: crit3's CI-floor bump is moot until grip CI exists (tgw6).

3. tgw4-screen-git-global-option-audit — ALREADY-DONE.
   Landing: 870fcbb7bb "fix(grip): close screenCommand value-taking-global collision on
   git/go/npm (#12180)"; test pin d3f542357c (#12272, read/write halves, mutation-proven in
   wave-15 review). Live probe THIS session (code == origin/main, only ledger docs differ):
   screenCommand refuses "git -C /tmp/repo push origin main" / "git -C /tmp/repo commit -m x" /
   "git --no-pager reset --hard origin/main" (sub-verb not on read-only allowlist) and ADMITS
   "git -C /tmp/repo log -1" — both directions of crit0/2. Unmet 0-3.
   NOT a duplicate of tgw11-bl-screen-classifysafety-global-option-launder — that row's
   classifySafety half is measured STILL LIVE (see REAL WORK) and survives this close.

4. tgw12-bl-seal-infra-fault-ready-pool-ghost — SUPERSEDED.
   Successor: 019f728bcc "fix(grip): the seal reconciles the pool ON THE SET, so it can render
   a verdict again (#12954)" 2026-08-22 — seal.mjs:65-66 now dedupes by id and reconciles the
   walk against --all on the SET; the akbr ghost no longer INFRA-FAULTs the instrument.
   Unmet 0-1. Residue (server-side ready-pool dedup in api/) is the surviving half —
   fold it into tgw10-bl-drafts-in-ready-pool (same queue.ex seam) rather than keeping two rows.

## CHAIN 2 — live-refuted defects (the asserted behaviour no longer reproduces)

5. tgw11-bl-cli-selftest-pipe-truncation — REFUTED (positive contradiction, not a zero-grep).
   Measurement THIS session: diff <(node tooling/grip/cli.mjs --selftest 2>&1) /tmp/grip-st-file.txt
   -> IDENTICAL; both forms 25 lines, verdict line "all 16 controls fired as designed.", rc 0.
   The piped form carries the verdict byte-for-byte. Candidate landing: d6b26f002d (#6508,
   2026-07-28, cli.mjs entry-guard rework — after the row's a9638ecef measurement); cause was
   never named at file:line, so crit0 is technically unsatisfied-and-moot. Unmet 0-4.

6. tgw10-bl-bp-task-list-500 — REFUTED (lead live-refuted it today: the alias runs and returns
   docs). Corroborated this session: `bp task list --all -o json` emits the alias note then a
   WELL-FORMED request — today's failure is server 429 rate_limited, not the alias 500.
   Alias rework landing: 69ad10474c "feat(cli): task show/list aliases + did-you-mean hint
   (ctx-s4-did-you-mean) (#6054)". Unmet 0-2 (crit1 regression test never written — note it).

7. tgw6-bl-primary-checkout-staged-grip-fork — ALREADY-DONE with one live residue.
   Measurement: git diff --cached --name-only | wc -l == 0 in the primary checkout (the 18-file
   staged fork is GONE; tgw12 ledger measured the same on 2026-08-18) and HEAD is 0 ahead / 7
   behind origin/main (git rev-list --left-right --count HEAD...origin/main -> "0 7").
   Unmet 0-3. RESIDUE (crit2): the two untracked mint-run files grip-20260721T054733Z-*.json /
   grip-20260721T054846Z-*.json are STILL in tooling/grip/ledger/ — plus new pollution
   (_probe_*.exs files). One small hygiene slice remains; the fork premise is dead.

8. pdf-bl-checkout-steward — ALREADY-DONE by later events, one residue.
   Measurement: .claude/workflows/bp-personal-dev-fleet-charter.md PRESENT on origin/main
   (crit1, landed via pdf-wa-charter-recovery-pr); primary checkout 0 ahead / 7 behind (crit2).
   Unmet 0-3. RESIDUE (crit3): refs/heads/worktree-fleet-provider-neutral STILL on origin
   (git ls-remote) — annotate/delete it; crit0 is moot (the ahead commits landed via PRs).

## DUPLICATE FLAGS (flag only — never cancel; both halves verified live)
- tgw11-bl-root-criteria-stamp-needs-close-window (0/3) <-> tgw9-s3-criteria-adjudicated crit[10]
  (11/12, sole unmet): the SAME close-window stamp act. tgw12 ledger names the tgw11 row the
  owner. Keep both; close tgw9-s3 via its crit10 the moment the tgw11 act runs at the seal.
- tgw12-bl residue <-> tgw10-bl-drafts-in-ready-pool: same queue.ex ghost/draft family.

## BLOCKED-HUMAN (6, all pdf)
- pdf-bl-console-key-custody (1/3, outside the 0-met set): the D88 sign-off gate CLEARED
  2026-07-28 (charter :637) — crits 1,2 are now BUILDABLE, no longer human-gated. Reclassify.
- pdf-w1-secure-stall-diagnosis — CP-host journal; barkpark_indx SSH key exists ONLY as a
  GitHub Actions secret.
- pdf-bl-fleet-ssh-key-singleton-tripwire — crit0 requires an on-CP read (owner-gated box);
  the env one-liner wants the next owner CP session.
- pdf-bl-guerrilla-500-flap — on-box journalctl + resize decision (root cause already
  evidenced: 2-vCPU saturation; today's 429s are the same box under load).
- pdf-bl-gui-workstation-spike — owner thesis ruling (Computer Use absent on Linux) + live spend.
- pdf-bl-support-arm-lane — external Hetzner ARM stock + a live create/delete cycle.
- pdf-bl-adapter-rate-card — remaining scope is ONLY the remote leg on a real listener box
  (its scheduled vehicle pdf-wc-support-proof was cancelled) — owner live-fire.

## REAL WORK (one line each; ordered by leverage)
- tgw11-bl-screen-classifysafety-global-option-launder (P1 SECURITY): measured live TODAY —
  classifySafety("git --git-dir log push") and ("git --work-tree /x push origin main") both
  return safe:true "no write shape detected" while runRerun gates on classifySafety alone
  (rerun.mjs:676): the executing veto is DECORATIVE on 7 separated-value globals. The
  guard-that-cannot-lose specimen of this family. SR-1 independent reviewer required.
- tgw6-bl-grip-suite-has-no-ci (0/11): zero grip workflows (git grep grep-controlled:
  positive control hits, "grip" zero) — and it is NOW UNBLOCKED: suite green on main after
  #12272+#12273 (712/711/1-skip, wave-15 review) and dep tgw9-s1 is done. Highest-leverage build.
- tgw10-bl-screencommand-bypass-census: runRerun still classifySafety-only — the caller-boundary
  census/structural screen never done; pairs with the launder row above.
- tgw10-bl-d92-exit-race-unfixed: backfill.mjs:406 `.then((code) => process.exit(code))` and
  acceptance.mjs:511 `process.exit(outcome.ok ? 0 : 1)` still on origin/main (ledger.mjs:1504 fixed).
- tgw11-bl-mint-path-root-relativity: REPRODUCED live — mintRecipe on
  "cd <root>/api && mix test test/.../keys_test.exs" derives subject "test/..." not "api/test/...".
- tgw10-bl-default-share-guard-one-sided: binding.test.mjs:528 asserts CEILING only
  (defaultShare < 0.2, comment says so); no floor, rename-gaming un-reproduced-and-unpinned.
- tgw4-absence-veto-stops-at-the-rerun-seam: adjudicate.mjs ruling() still exposes no `admits`
  field (grep: comments only) — D109 says the seal structurally NEEDS it. Feed the seal wave.
- tgw4-r3-has-no-adjudicator-check: DECLARED_DIVERGENCES specimen-5 entry still at
  acceptance.mjs:188-193.
- tgw9-bl-census-tool-availability-header: census.mjs:300 PATH_GONE still in DECAYED,
  :422 rc127->PATH_GONE; no availability header.
- tgw9-bl-stale-62-row-denominators: binding.mjs:13/72/89/112/113 still say "the 62 stored rows".
- tgw9-bl-class-coverage-hyphen-blind-spot: INVISIBLE_BY_CONSTRUCTION list still at
  class-coverage.test.mjs:176.
- tgw9-bl-ledger-fold-reading-path-split: still split; leads run today warns
  "505 run file(s)/row(s) could not be read".
- tgw6-leads-declares-binding: leads --json today has NO provenance key (measured); binding
  import (crit1) already landed — remaining scope is render+provenance halves.
- tgw13-s2-inloop-gate-wording-tolerant: premise-red CLEARED by #12179 (28/28 green, D149);
  survives as small anti-drift test rewrite only.
- tgw11-bl-root-criteria-stamp-needs-close-window: the seal-window stamp choreography (see dup flag).
- tgw9-bl-d28-verify-floor-has-fired: charter D28 (:220) still says "NEVER fired" — one-paragraph
  amendment + rerun command.
- tgw10-bl-stranded-unique-commons-row: HAZARD FIRED — e2-review-w17 worktree and
  w34-chatlive-belt-semantics.recipe.md are GONE (find: zero hits; absent from origin/main,
  control file PRESENT). Rescue impossible; remaining act = crit1 arm 2 (record supersession
  with the owning e2/w34 epic, and record the loss).
- tgw10-bl-drafts-in-ready-pool: queue.ex twin-collapse (#1382) predates the row; bare-draft +
  UUID-ghost class still live server-side (the tgw12 ghost is the same family) — absorb residue.
- tgw10-bl-server-side-type-fact-hook: no type:fact hook anywhere in api/lib/barkpark/plugins/.
- tgw10-bl-park-reasons-not-durable: unmeasurable via the anonymous query view (engagement is
  stripped); bp 429-limited — re-adjudication of ~45 parks stands as filed.
- tgw10-bl-hardening-tail-unenumerated: inputs now exist (tgw12 partition ledger, D110 closure
  numbers 137/135) but the per-row P2-4 CONTENT table was never produced.
- tgw11-bl-unwrapped-recipe-rows-unread: both unwrapped premise-smoke .json files still in
  tooling/grip/ledger/, no superseding wrapped rows.
- tgw6-bl-fence-branch-sweep: truth-grip/wave5-review, review/union-final, review/union-probe,
  integration-check, wave4-integration, tgw4-v3/v9, tgw2-charter-amendment all still exist locally.
- tgw2-bl-fill-rate-experiment: the scriptPath-launched fill-rate wave has still never run.
- tgw5-bl-join-prompt-closure: workflow still names the WHERE and not the HOW —
  grep -c ledger.mjs and facts.json on origin/main workflow both return 0 (positive control:
  "tooling/grip/ledger" hits 5 lines).
- tgw-bl-agent-tier-prose-published-durably / tgw-bl-coverage-ledger-unreproducible /
  tgw-bl-coverage-write-path-unsafe: out-of-fence trio (barkpark-sync + tooling/research-coverage),
  unchanged; candidate reparents per the tgw12 partition ledger.
- pdf REAL WORK (all verified unbuilt on origin/main today): cp-version-endpoint (no version
  route in cloud/), fleet-run-refresh (no refresh verb), orchestrator-spend-producer (grep:
  reader+prose+proof only, NO writer of orchestrator/spend.jsonl), support-remove-serverside
  (zero deprovision_support hits), fleet-orphan-box-janitor (SweepOrphans still
  barkpark-orphaned-only; support.go never labels), hcloud-context-darwin (HCLOUD_CONFIG rung
  landed; ~/.config fallback still absent — hcloudConfigPath = env else UserConfigDir only),
  hetzner-stock-surface (no Locations/Available in row builders), hetzner-token-project-split,
  worker-first-columns (pickColumns lead list still without worker), nonadmin-task-tests
  (zero nonadmin lifecycle hits; NOTE the cited tasks_controller_test.exs was SPLIT into
  api/test/barkpark_web/controllers/tasks_controller/ — brief path is stale),
  cp-no-team-status-mismatch (422 no_team at router.ex:2060/:2334 vs DELETE 404 unchanged),
  roster-enrichment, fleet-group-view, catalog-generalization, scratch-orphan-postgres-janitor,
  wavec-r1-branch-sweep (worktrees GONE, but 3 loop-epic branches still on origin — small),
  pdf-w1-tokenid-orphan-reconcile (supportParseMint bare-id fallback unchanged at
  support.go:1144; revoke half needs owner confirm).
