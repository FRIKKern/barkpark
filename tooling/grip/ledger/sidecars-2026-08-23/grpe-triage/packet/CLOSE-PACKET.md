# CLOSE PACKET — gr-*/pe-* open 0-met triage (2026-08-23)

Source of truth: paginated offset-walk of /v1/tasks (guerrilla), 7410 rows, 76 targets (44 gr + 32 pe).
Tree: origin/main @ afe7f98c73 (fetched this session). Grep self-test: known-positive 1 hit, impossible-string 0.
Criterion texts: exact stored `acceptance_criteria[N].criterion` bytes, one file per criterion (`<row>__crit<N>.txt`,
sha256 manifest printed at write time — all rows are 0-met, so EVERY zero-based index listed is unmet).

## Ordered by leverage

### 1. gr-bl-stale-bulldocs-branch-5730-revert — REFUTED (unmet: 0,1,2)
The feared merge ALREADY HAPPENED and could not carry the revert: PR #5720 (head loop-epic/s1-bp-bulldocs-patch-if-rev-enters-the-j-0-r)
MERGED 2026-07-22T15:11:58Z as 42425995fa with exactly two files — internal/cli/run.go + internal/cli/run_test.go —
never .claude/workflows/bp-epic-cycle.workflow.js. Proof: `gh pr view 5720 --json files` (2 paths) and
`git merge-base --is-ancestor 7a7a542ee origin/main` exits 0 (the #5730 charter-push fix stands today).
The stale remote branch still exists but is merged history; deleting it is hygiene, not this row.

### 2. gr-bl-reset-primary-main-divergence — REFUTED (unmet: 0,1,2,3)
The divergence no longer exists. Measured on the primary checkout 2026-08-23:
`git rev-list --count origin/main..HEAD` = 0 (was "ahead 13"), `git rev-list --count HEAD..origin/main` = 7 (was "behind 209"),
`git status --porcelain | grep -cv '^??'` = 0 tracked-dirty (the board_live.ex/schema.ex dirt is gone).
Host-state row: no landing commit exists or is needed — the premise is positively contradicted by measurement.

### 3. pe-w5-shared-checkout-unblock — ALREADY-DONE by events (unmet: 0) [claim held — read claim before touching]
Same checkout, same measurement as #2: ahead 0 / behind 7 / tracked-clean vs the row's "46+ commits behind,
fast-forward blocked by untracked ledger collisions". The checkout has advanced hundreds of commits past the
blockage (HEAD 228090798b is a 2026-08-22 commit). Residual 7-behind is ordinary drift, not the filed blockage.
NOTE: row carries a live claim in the walk snapshot — verify the claim before any close.

### 4. gr-backlog-compose-env-passthrough-audit — ALREADY-DONE (unmet: 0,1,2,3)
Landing commit: 2c25288479 "feat(env): grep-proof env census script + widen cloud compose passthrough (shb-w1-s1b)" (#10951, 2026-08-08 — after the row, filed 2026-07-19).
Measurement: parse origin/main cloud/config/runtime.exs → 53 distinct System.get_env names; 0 of them absent
from origin/main cloud/docker-compose.yml (the row's premise counted 22 missing). The census script is the crit-2 tripwire.

### 5. gr-backlog-e10-fixture — ALREADY-DONE (unmet: 0,1,2)
Landing commit: 9b78c20b2c "test(cloud): make the E9/E10 CSS fixture proofs runnable and RUN, and let E9 name the file it read" (#8127, 2026-07-30 — row filed 2026-07-20); widened by 367e19810b (#8946).
Symbols: committed fixture cloud/priv/static/__css_check.orphan.fixture.css (blob f41424de88), fixture mode
`node __css_check.mjs --orphan-check <file>` at __css_check.mjs:895-904, orphanCommentErrors at :650, usage doc at :75.

### 6. gr-p5-session-preview-delete-routes — REFUTED (unmet: 0,1,2)
The matchers existed BEFORE the row was filed. Both DELETE matchers live at
cloud/priv/static/__preview__/scenarios.mjs:4517-4541 (`DELETE /v1/account/sessions/:id` revoke-one at :4520-4532
with the 404 not_found failure arm, `DELETE /v1/account/sessions` sign-out-everywhere at :4533-4541).
Sole landing commit for that string: 8c9c116c55 (#5379), merged 2026-07-21 — the row was inserted 2026-07-28
claiming "NO matcher". `git log -S 'account/sessions" && method === "DELETE'` names exactly that one commit.

### 7. pe-w2-bl-tripwire-nested-checkouts — ALREADY-DONE (unmet: 0,1,2)
Landing commit: 1aaaecd15f "fix(pdrender): scope the divide-formula tripwire to tracked sources so it stops matching
228 copies of itself (#12885)" (2026-08-20 — row filed 2026-08-17). Symbol: trackedGoFiles (git ls-files scoping,
in-process regexp) in internal/pdrender/joincols_test.go (~:158-230); the in-file comment names the fix verbatim
("THIS IS THE SCOPING INSTRUMENT, and it is the whole fix"); owner-liveness arm at :221-230 (ownerSeen).
CROSS-FAMILY DUPLICATE of pbw-backlog-pdrender-grep-hang (open 0/3) — same tripwire, same landed fix. FLAG ONLY, never cancel.

### 8. pe-w1-bundle-table-scroll-chrome-gap — ALREADY-DONE (unmet: 0,1,2)
Landing commit: d2c8457413 "feat(papers): the parity gate covers every evidence-band breakout class — mirrors first,
table allowlist retired (#11759)" (2026-08-17 — row filed 2026-08-12; subject names crit-1's allowlist retirement).
Symbol: api/assets/paper-editor/src/styles.css:554 `.bp-paper-editor-body .bp-table { … display: block; overflow-x: auto; max-width: …}`
with the byte-identical-mirror comment at :549-553 naming view_edit_parity_test as the guard.

### 9. gr-bl-reap-orphaned-preview-port-squatters — DUPLICATE (flag only — never cancel) (unmet: 0,1,2)
crit0's host-state premise is already measured clear: the cch-w7 sweep (tooling/grip/ledger/cch-w7-movement0-sweep-gr-2026-07-28.md)
recorded `lsof -nP -iTCP:4199 -sTCP:LISTEN` → empty (exit 1), "squatter gone". crits 1-2 (ephemeral/distinct-exit-code
port behavior on overflow-guard.mjs) are the SAME work as gr-bl-seal-guard-port-and-stderr crit0+crit2
(overflow-guard.mjs:188 still hardcodes 4199 — the work itself is live and stays with the seal-guard row).
One ruling should dispose of the pair together; this packet recommends closing NEITHER unilaterally.

## Chains (one ruling each)

- PE SEAL CHAIN (3 rows, one ruling): pe-w7-hg-anthropic-key (BLOCKED-HUMAN: no valid ANTHROPIC_API_KEY on host)
  → pe-bl-cold-agent-run (all three AFTER-gates now done: pe-w8-door-unblock 4/4, pe-w8-harness-effort-pin 5/5,
  pe-w8-leakage-audit-hardening 4/4; RUBRIC.md + harness committed at 4f59e81e7b/11d61077e2) → pe-w7-epic-seal
  (epic task-4792223ca9eb5a7d open 2/3). The ENTIRE chain waits on one human credential.
- PE DEVICE CHAIN (2 rows): pe-w2-bl-device3-display-scale → pe-bl-framed-finale-authoring
  (shared blocker task-421937b559e1c570 is done 5/5, so device3 is dispatchable and finale waits only on device3).
- GR RESEARCH ORPHANS (7 rows under DONE parent task-09f4775e7ccc2cca — the open-under-done-parent shape):
  2 resolved here (#1, #2 above); gr-bl-e3-arm-run, gr-bl-fill-c-and-synthesis, gr-bl-graduation-dryrun-test
  (now unblocked: gr-grad-encode-blocks done 5/5), gr-bl-sweep-stranded-workflow-branches (all 4 branches still
  exist locally), gr-bl-standing-smoke-verifier-slot (trigger-gated) remain REAL WORK needing a re-home decision.

## Duplicate flags in the REAL-WORK set (flag only)
- gr-blk-shootsh-scen-suggester (claimed) ↔ gr-bl-shootsh-scen-suggester-false-done — SAME fix; defect verified
  live at origin/main shoot.sh:150-153 (`${want%%-*}` prefix grep, empty-list arm intact).
- gr-blk-accent-scenario-sweep ↔ gr-backlog-accent-matrix-rereview — both order the 86×5-accent×2-theme matrix;
  gr-p5r3-shoot-accent-fix is done 5/5 so both are dispatchable; rereview adds the human review half.

## BLOCKED-HUMAN (named boxes/credentials)
- gr-ops-platform-admin-emails — PLATFORM_ADMIN_EMAILS into /opt/barkpark/cloud/.env on the control plane
  (178.105.92.191) + restart.
- gr-backlog-qr-live-scan-proof — physical phone scan with ≥2 real authenticator apps.
- pe-w7-hg-anthropic-key — a valid sk-ant API key (or apiKeyHelper) for the cold harness.
- pe-bl-bp-token-rotation — mint+revoke the guerrilla admin bp token (prefix committed in 3 files on public main).
- (context, not in family: cloud-console-billing-live-gate — verified present, open 0/3, parented to the DONE
  cloud-console-goal by design; NOT lost.)

## Kept-open guard
gr-bl-close-time-audit-vacuous-green — REAL WORK, and the retirement trigger for cch-finding-roster-tooling-contract;
do not close casually. gr-backlog-tablet-width-audit was re-worded by the lead TODAY (cch-w14-bl-tablet-width-audit-rescope) — actively curated, hands off.
