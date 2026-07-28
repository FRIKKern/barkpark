# PDS wave 22 — harness-freeze family + crown-blocked rows, adjudicated by content (2026-07-27)

Slice `pds-w22-triage-harness-and-crown-family`. LEDGER-ONLY: the dispositions below live on the Barkpark
task ledger; this file is the re-derivation record. Baseline `origin/main` @ `9110a0ebeeb9f9cd76d62cf14596b3334a5082ad`.
Every `git log -S` used `--full-history` (PDS-D299: origin/main has two root commits and `b5299fcb6`
re-adds `scripts/pds-pull-proof.sh` wholesale, so the un-flagged form hides `58d1bd3a5`).

## Lens and scope (my instant, not diffed against a differently-sampled before)

Scope = transitive `parent_id` closure of `task-2ac1f95237c4a8e5` UNION the orphan subtree rooted at
`pds-w10-climb-in-the-post-deploy-window` (root included), INTERSECT the ready pool = **145 ready rows**
(138 closure + 7 orphan) at 2026-07-27T19:1x-19:2xZ over a 3,353-task ledger. It is 145 rather than
PDS-D297's 136 because wave 22 filed its own 8 slices as children after D297's named instant.

TEXT lens (PDS-D296): path tokens = `content.files` UNION
`(?<![\w/.-])((?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,8}|scripts/[A-Za-z0-9_.-]+)`
mined from description + title + gate + every acceptance criterion and its evidence + `json.dumps(brief)`.
A row is harness-only when it has at least one token and **every** token starts with `scripts/`.
Result **52** (D296 said 47 — same lens, later instant, slightly wider token regex). A `files`-only lens
still sees only **22**, confirming D296: most blocking rows carry no `files` field at all.

MY SET = 52 harness-only + 3 charter-named crown-blocked rows the lens does not reach
(`pds-bl-w13-export-duration-unmeasured`, `pds-bl-w13-spill-dir-full-export-unobserved`,
`pds-w20-crown-collect-and-seal`) + `pds-bl-templates-deploy-noop` (assigned by name) = **56 rows**,
partitioned 46 OPEN / 8 PARKED / 2 CLOSED with zero missing and zero extra. The partner slice
`pds-w22-triage-remaining-rows` takes the complement of exactly these 56 (`pds-w22-deploy-readback` is
in scope but is a live wave-22 slice, not a triage subject).

## CLOSED by content (2)

| row | fixing commit + the content that proves it |
|---|---|
| `pds-bl-harness-pgrep-wrong-process` | 58d1bd3a5 (#4771) — live selector at scripts/pds-pull-proof.sh:1407 is `pgrep -o -x beam.smp`; the buggy `-f … \| head -1` survives only in the comment at :1384-1386 and the rejected-form banner at :1417 |
| `pds-bl-templates-deploy-noop` | b2a92e3bc (#6216) — .github/workflows/deploy.yml:87 greps `^(api\|internal\|deploy\|connectors\|templates)/`, comments at :16-19 and :82-86 match behaviour, and scripts/check-deployyml-filters.sh is the standing tripwire |

Both verified with `git merge-base --is-ancestor <sha> origin/main` exiting 0. This slice was READ-ONLY
on `scripts/pds-pull-proof.sh` and `.github/workflows/deploy.yml`.

## PARKED — blocked on a crown fire this wave forbids (8)

Each carries its own blocker plus the trigger "REACTIVATE: reopen when a crown fire is licensed", and each
states that lifting the D100 freeze does **not** unblock it: the blocker is the fire licence, not the freeze.

| row | blocker (abridged) |
|---|---|
| `pds-bl-w13-export-duration-unmeasured` | the only way to time a full export on the DEPLOYED streaming engine is to take a full export on guerrilla — a licensed fire window that this wave forbids. The 130 s figure stays a wave-7 old-in-memory-engine nu |
| `pds-bl-w13-spill-dir-full-export-unobserved` | observing peak simultaneous spill files and total spill bytes requires watching a COMPLETED FULL export (PDS-D218's numbers came from a killed-client scoped run) — a licensed fire window, not a harness edit. Th |
| `pds-w11-paired-control-measure` | the paired-control peak instrument must take a real full export with a paired idle control to give PDS-D104 the control the canonical 2235.43 MiB never had — a licensed fire window, not a harness edit. Its clai |
| `pds-w12-measure` | it is a live out-of-band peak measurement that spends a real FULL export on guerrilla against the shared attempts budget — i.e. it needs the same fire licence a crown climb needs — and it is additionally gated  |
| `pds-w20-crown-collect-and-seal` | it collects and seals the wave-20 climb that pds-w20-crown-fire would have to fire first; with the crown CLOSED there is no climb to collect, and its own text is explicit ('AFTER pds-w20-crown-fire's CLIMB COMP |
| `pds-w20-crown-fire` | this row IS a crown fire — it arms the detached climb at the 897 floor — and wave 22 is forbidden to re-fire the crown ("the crown is CLOSED — no further fire; attempt 7 is the only one left and is not needed") |
| `task-328621eadb772c81` | this row exists only to make a crown climb fire from outside a build slice (the poll outliving the agent turn). Its whole subject is the fire mechanism, and the crown is CLOSED — the launcher it argues for has  |
| `task-8db002bc83e78718` | it is the wave-20 ENGINE-FAIL finding whose own instruction is 'DO NOT re-run until explained (1 attempt left, 5/6 spent)' — closing it requires a rung-1 import re-run on guerrilla, i.e. the fire licence this w |

## OPEN with a named owner (46)

| row | owner | disposition (abridged) |
|---|---|---|
| `pds-b-proof-instrument-control-auto` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, still real. Re-derived on main: scripts/pds-pull-proof.sh:1730 still gates the instrument's own FIRING control on `if [ -n "${PDS_CONTROL_PG:-}" ]`, so the defa |
| `pds-bl-artdir-no-cleanup` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, still real. Re-derived on main: `grep -nE 'ART_DIR' scripts/pds-pull-proof.sh \| grep -cE 'rm \|trap\|clean'` returns 0 — there is still no cleanup path, so every  |
| `pds-bl-charter-line-refs-stale` | pds-charter-steward | OPEN — NOT harness work despite its scripts/ path token, and explicitly named by PDS-D297 as an ordinary defect with nothing crown-specific about it. It corrects PDS-D92/D93's cited line num |
| `pds-bl-charter-slot-durability` | pds-charter-steward | OPEN — NOT harness work despite its scripts/ path token; the subject is the shared rotating charter slot (.claude/workflows/), where five epics' charters were stranded together on unpushed l |
| `pds-bl-collect-stillrunning-hides-force` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. collect's STILL-RUNNING advisory never names `arm --force`, the escape hatch arm's own die message documents, so an obedient operator dead-ends. Buildable now t |
| `pds-bl-d220a-keyed-on-a-proxy` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and this is the wave's own defect class. scripts/pds-export-peak-measure.sh guards its windows with `[ $SAMPLES -le 0 ]` while the refusal text claims to reject |
| `pds-bl-deployed-sha-override-unimplemented` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, still real. Re-derived on main: `grep -n PDS_DEPLOYED_SHA scripts/pds-pull-proof.sh` returns exactly ONE hit, :637, and it is inside the remediation TEXT tellin |
| `pds-bl-gate-b-anticorrelated` | lead-pds | OPEN — needs a RULING, not a patch, and D296 does not supply it. Gate (b) is a single instantaneous MemAvailable read that is anti-correlated with health: the floor clears BECAUSE the BEAM h |
| `pds-bl-harness-not-relocatable` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. A bare copy of the harness dies at pds-pull-proof.sh:2546 ('SCAN_SCRIPT missing') because SCRIPT_DIR/REPO_ROOT derive from the invoked file's own location, so e |
| `pds-bl-launcher-statedir-fresh-transcript` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296 as WORK, though its payoff is fire-scoped. It is the durable class-fix for the PDS-D269 hazard: reusing PDS_RUN_ID reuses run_tag, so collect can scrape a PRIOR  |
| `pds-bl-legb-visibility-control-n3` | pds-harness-maintainer | OPEN — THE THAW IT WAS WAITING FOR IS GRANTED. The row says verbatim 'HELD UNTIL A SANCTIONED HARNESS THAW'; PDS-D296 rules PDS-D100 climb-scoped and inert with the crown closed, so the hold |
| `pds-bl-lifecycle-check-precondition` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, still real. Re-derived on main: `grep -c lifecycle_status scripts/pds-pull-proof.sh` returns 0, so nothing in the ladder asserts the target's documents_task_lif |
| `pds-bl-metric-orphan-schema-row` | pds-schema-owner | OPEN — NOT harness work despite its scripts/ path token (it cites the census markdown, not the instrument). The `metric` schema row on guerrilla is declared by no plugin and owned by nobody; |
| `pds-bl-nonint-comparison-fallthrough` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and squarely in this wave's defect class. pds-pull-proof.sh guards with `[ "$f_rows" = "ERR" ] \|\| [ "$f_rows" -eq 0 ]`; a non-integer that is not exactly 'ERR'  |
| `pds-bl-peak-budget-enforcement` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. pds-w14-peak-ledger-honesty made scripts/pds-export-peak-measure.sh WRITE the shared attempts ledger but deliberately stopped short of REFUSING on an exhausted  |
| `pds-bl-peak-lock-sequencing` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. scripts/pds-export-peak-measure.sh takes /tmp/pds-full-export/lock UNCONDITIONALLY in preflight, above the FULL_ACQ evaluation, so a SCOPED run that correctly n |
| `pds-bl-pid-live-identity-blind` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and it is a report-success-while-wrong shape: pid_live() is a bare `ps -p` existence check with no comm/lstart cross-check, so a RECYCLED pid makes a dead climb |
| `pds-bl-private-orphan-roster-probe` | pds-schema-owner | OPEN — NOT harness work: it is one psql line against guerrilla to retire the schema-row census's last unproven bound (whether a visibility='private' guerrilla-only orphan exists, invisible t |
| `pds-bl-repull-into-populated-target-500` | pds-scratch-target-maintainer | OPEN — HIGH VALUE, and closest in spirit to this wave's wish. A SECOND dev pull into an already-populated target 500s with a MASKED 25P02, so PDS-D14's 're-run is refresh' contract is unprov |
| `pds-bl-rss-ambient-caveat` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. The quoted RSS peak is WHOLE-PROCESS beam.smp RSS while the same BEAM serves live content-API traffic, and the honesty banner never says so — so every number de |
| `pds-bl-rung6-percolumn-invisible-on-green` | pds-harness-maintainer | OPEN — THE THAW IT WAS WAITING FOR IS GRANTED. Its own text says 'HELD UNTIL A SANCTIONED HARNESS THAW. Do not build this while a crown proof is in flight - PDS-D100 freezes the instrument.' |
| `pds-bl-sampler-window-default-retired-engine` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, still real. Re-derived on main: scripts/pds-idle-sampler.sh:97 still documents '--window ... default 130 — the canonical export's wall time', and that 130 s is  |
| `pds-bl-scratch-pointer-concurrency` | pds-scratch-target-maintainer | OPEN — NAMED BY THE WAVE-22 WISH and deliberately NOT taken by any wave-22 build slice; recorded here so that is visible rather than implied. Two run-proven defects in scripts/pds-scratch-ta |
| `pds-bl-scratch-pointer-explicit-default` | pds-scratch-target-maintainer | OPEN — MERGE CANDIDATE, not independent work. Its defect is the SAME global-pointer default as pds-bl-scratch-pointer-concurrency's defect (1): /tmp/pds-scratch-target.last, re-derived on ma |
| `pds-bl-scripts-md-budgets-unenforced` | docs-gates-owner | OPEN — NOT harness work: scripts/*.md declare doc-tier budgets that check-doc-budgets.sh does not enforce because its gated path list has no scripts/ entry. The defect is in the docs gate, n |
| `pds-bl-secret-scan-invisible-tables` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and a genuine report-success-while-wrong defect proven by a purpose-built low-privilege role: pds-secret-scan.sh cannot see a table the connecting role lacks SE |
| `pds-bl-stamp-silent-noop` | bp-task-ledger-maintainer | OPEN — NOT harness work: the subject is `bp task stamp` on the server, observed ONCE returning success while the criterion stayed met:false, unreproduced, filed honestly. It is the ledger tw |
| `pds-bl-stamp-trailing-newline-deadend` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. scripts/pds-crown-stamp.sh correctly REFUSES a criterion whose stored text ends in a newline (because $(cat f) strips it and the server then 409s criteria_misma |
| `pds-bl-step1-grain-no-control` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296 (filed 'under the freeze' per PDS-D118, and the freeze is now inert). Step 1's manifest-grain assertion — the PDS-D61/D62 guard against a workspace-grain bundle  |
| `pds-bl-step3-control-leg-grammar-guard` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296 (filed by wave 6 and deliberately not fixed there under PDS-D109's freeze). The asymmetry is real: the dev leg carries member-non-empty + row-count + grammar gua |
| `pds-bl-step6-tag-exclusion-stale-comment` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. The comment at pds-pull-proof.sh:2012-2013 justifying rung 6's `tag` exclusion was falsified 19 seconds before it shipped (#4770 at 08:11:43 put TagRegistry beh |
| `pds-bl-w13-cond-d-no-reservation` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296 as work, fire-scoped in value. cond_d polls `gh run list --status in_progress` ONCE immediately before spending the attempt counter and never re-polls during the |
| `pds-bl-w14-round2-standdown-risk` | lead-pds | OPEN — needs a SIZING DECISION rather than a patch, and with the crown closed there is no round 2 to size. PDS-D245 rules detach-only PAYABLE on a 76.2% payability read from a 159-of-360 PAR |
| `pds-bl-w14-standdown-token-ruling` | lead-pds | OPEN — needs a RULING, not a patch: a draw-exhausted stand-down and a mid-rung abort share the CRASHED token, so PDS-D247 needs a seventh state or an explicit ruling that the two are indisti |
| `pds-bl-w16-arm-never-records-its-own-floor` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and it is a report-success-while-wrong shape in the strict sense: PDS_LAUNCH_MEM_FLOOR_MIB is a live, legal, tighten-only knob (2199 refuses, 2200/2400 pass), b |
| `pds-bl-w16-failed-refetch-destroys-parked-bundle` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, three defects in one function (acquire_full_bundle): a failed re-fetch truncates FULL_TAR in place and so destroys the fallback AND spends the attempt; the inva |
| `pds-bl-w16-full-meta-permissive-default` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and the single most on-theme harness row in this family: full_meta_ok's `case "$p" in ""\|full) return 0` accepts an EMPTY manifest profile, so a non-tar body (a |
| `pds-bl-w16-launcher-one-shot-burns-the-window` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296 as work, fire-scoped in value (PDS-D262). On a FIRE verdict the launcher runs the harness ONCE: a marginal fire the harness immediately refuses costs zero attemp |
| `pds-bl-w16-prewarm-warms-the-wrong-build-tree` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. The launcher pre-warms with MIX_ENV=prod (pds-crown-launch.sh:258, :443) while the harness's only mix invocation is MIX_ENV=dev (pds-pull-proof.sh:741) — differ |
| `pds-bl-w16-sampler-loses-its-own-evidence` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, two measured defects in scripts/pds-idle-sampler.sh: `trap cleanup EXIT INT TERM` deletes the samples on any early kill and the script then reports 'ZERO sample |
| `pds-crown-stamp-readback-evidence-diff` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296, and it is a read-back that cannot detect the write it is meant to confirm: pds-crown-stamp.sh:408 confirms a stamp by asserting the row reads met==true, so a me |
| `pds-w10-correlation-truncation-correction` | pds-charter-steward | OPEN — NOT harness work: it amends RATIFIED MEMORY (the wave-10 Paper and the D190 digest), correcting the daily r=-0.59 and hourly r=-0.21 to -0.38 and -0.14 after the 07/12 truncation arte |
| `pds-w11-d193-leg-tension` | pds-harness-maintainer | OPEN — explicitly named by PDS-D297 as one of the orphan subtree's ORDINARY defects with nothing crown-specific about it, so it is NOT parked with the crown family. The finding stands on com |
| `pds-w13-uphint-cold-prod-aware` | pds-scratch-target-maintainer | OPEN — NOT harness-frozen work: it is the `bp`-side scratch-target verb (scripts/pds-scratch-target.sh cmd_up), named as residue by pds-w13-scratch-cost-truth, which was docs-only and could  |
| `pds-w5-citation-grep-honesty` | pds-harness-maintainer | OPEN — UNBLOCKED BY PDS-D296. Slash-compressed citations like (PDS-D69/D70/D71) under-report the harness to a naive grep for PDS-D70, so a coverage grep silently misses rulings that ARE cite |
| `pds-w9-stale-2231-in-papers` | pds-papers-sweep-owner | OPEN — NOT harness work despite its scripts/ path token: the code figure was already corrected in the tree by pds-w9-export-arithmetic (2,231 MB -> 2,235.43 MiB, 35.43 MiB incremental); what |

## The proof standard, and what it caught

PDS-D298 requires re-reading the field each write claims to have written. It earned its keep twice:

1. **24 of the 46 OPEN writes reported an error** (guerrilla manifest 500s / client timeouts under
   concurrent waves) and a re-read showed **8 of those 24 had in fact written**. Exit-code bookkeeping
   would have been wrong in both directions on one run.
2. **All 8 park notes evaporated.** Written with `bp task stage … --note`, confirmed present at t+0, then
   gone ~20 minutes later — `lifecycle_status` still `considering`, `content.engagement` `null` on 8/8.
   This is the Truth-Grip wave-10 evaporation caught in the act, so "0 of 46 considering rows had a note"
   is not necessarily proof the mechanism was never used. A 3-minute poll showed the doc rev changing with
   no write from this agent (`b6c0ed06` -> `1b4f568c`); all 8 rows carry `content.github {state: synced}`,
   making the GitHub issue-sync reconciler the prime suspect — **not proven**, filed as
   `pds-bl-park-note-evaporates` rather than asserted. Remedy: every park now writes the reason twice,
   `engagement.note` **and** `content.disposition_reason`.

Final count, after settle: **56 disposed -> 56 re-read -> 56 non-empty reason fields, 0 empty.** The same
counter printed `NON-EMPTY REASON = 48 ; EMPTY = 8` before the remedy, so it can fail and did.

## Housekeeping (PDS-D300) — closed on evidence, not work

- `pds-w21-diagnose-and-fire`: `done`, 7/7 criteria, `closed_by == claim.worker`
  (`epic-builder-diagnose-the-rung-1-abort-app-path-then-`), claimed 21:44:01.740365Z, closed 21:51:01.196759Z
  — a SELF close 6m59s later.
- `pds-w21-crown-collect-and-seal`: `done`, 6/6, `closed_by == claim.worker` (`steward-crown-seal`), closed
  3.5 s after its claim. Honest nuance: both `close_reason` strings *read* like a reconciler
  ("Historical completion reconciled from N/N met acceptance criteria"), but identity and timing refute the
  "flipped by a batch reconciler 36h later" story.
- `/Volumes/SATECHI/github/barkpark-w21-fire`: absent from disk (`ls` -> No such file or directory) and
  absent from the registry (0 hits among 1,466 registered worktrees). Nothing to prune.
  **`git worktree prune` was NOT run, at any point** (PDS-D300: forbidden forever).

