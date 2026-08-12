# Epic-cycle distribution charter — the repo is the harness home

Epic task: task-4d7479832a947b8c · Wave 1 Paper: /papers/epic-cycle-distribution-wave-2026-08-12

## Vision

On any machine with a barkpark clone, `bp` authenticated, `gh` authenticated, and a Claude Code harness with workflows enabled, `Workflow({scriptPath: ".claude/workflows/bp-epic-cycle.workflow.js", args: {...}})` launches an epic wave that behaves exactly as it does on the original Mac. Distribution IS git: the workflow file is the whole unit (the harness derives the skill listing from each engine's `export const meta`, so committing the engine commits the invocation). The epic seals on a live wave launch from a second environment.

## Decisions

- **D1 — Direction A stands, move (1) retracted.** All four engines are TRACKED on origin/main, byte-identical to local, with merged history (#6929/#6131/#6360/#11079); a GitHub `--depth 1` clone delivers them shasum-identical. The "commit the untracked engines" premise was a level-skip — origin/main has been the L2 truth for engine doctrine since July. Wave 1 re-aims at portability, launch doctrine, a tripwire, and the runbook.
- **D2 — The engines teach the enforced paper dialect; the wall is not edited.** `api/lib/barkpark/content/papers/epic_quality.ex` (tag `epic-cycle-wave-paper`) hard-fails `:empty_paragraph_spacer` anywhere in the block tree and requires h1 + `ingress` + one orientation block (byline|stats|toc|list|steps) in the first 8 meaningful blocks; ceilings 80 blocks / 16 top-level headings / 5000 primary words (closed `expandable`s excluded). The engines' MECHANICAL SPACING bullet commands exactly the hard failure. Fix: rewrite the PAPER doctrine in all three general engines to the enforced dialect, cite open task `cchi-w67-bl-…` (owned by cch-instruments-epic) for the doctrine ruling, and teach the 422 debug loop (`invalid_epic_paper_quality` → `details.failures` names every failed gate; the CLI renders details).
- **D3 — `node --check` is replaced, with mechanism.** Any file containing an `export` statement passes `node --check` with rc=0 regardless of syntax errors (measured, node v22.22.0) — vacuous on 100% of the corpus. And the engines are valid in NO stock node mode (ESM `export` + top-level `return`). The only faithful mirror is: strip leading `export `, compile as an async function body (never invoke). Mutation-proven able to fail.
- **D4 — Tripwire venue = shell-harnesses.yml, advisory; doc-gates refused.** doc-gates carries a workflow-level paths filter with no `.js`/`.claude` glob (proven live: engine-only PR #11079 got zero doc-gates check runs; charter-md PR #11420 got one). Per required-checks `_readme` (honest-gates D18) a paths-filtered workflow is structurally disqualified from being a required context. The tripwire lands in shell-harnesses.yml (runs, doesn't block); promotion to blocking = a new job under one of the four required aggregators + governed required-checks regeneration — a separate, later, human-gated act.
- **D5 — Tripwire scope is `*.workflow.js` only.** Widening to charters inherits a 13-file absolute-path backlog of historical prose. view-edit-parity (the sole engine offender, lines 65/66/287/343) is FIXED, not allowlisted.
- **D6 — Guard lands after the fix (rounds are law).** The guard PR must be able to show fail-before via its own mutation fixture and land green on the live corpus, so the tripwire is round 2, after all four engine slices merge (wild-bulk's phases drift and deep-investigation's over-cap listing would otherwise red it at birth).
- **D7 — Runbook venue = docs/setup/CLAUDE-CODE.md (+ thin `.claude/workflows/README.md` pointer).** CLAUDE.md is at 9996/10000 bytes and docs/INDEX.md at 1197/1200 — both dead venues. CLAUDE-CODE.md is the uncapped, topical owner (`canonical-for: claude-code-onramp`); un-indexed setup docs are gate-legal precedent. The runbook states the invocation ITSELF — the skill listing cannot be delegated to (per-skill 1536-char cut; a global listing budget can drop whenToUse entirely on other accounts).
- **D8 — Launch is portable; resume is host-bound.** Run state lives under `$HOME/.claude/projects/<abs-cwd-key>/<session>/…` — not in the clone, keyed by absolute cwd + session uuid. A wave that dies on host A is RELAUNCHED on host B, never resumed. The runbook says this verbatim.
- **D9 — bp prerequisites are two steps, verified by fields.** `bp login` writes ONLY cloud_url/cloud_token/cloud_team; the server+token connect tail is TTY-gated, so headless machines also need `bp setup`/`bp use`. Verification is `bp whoami -o json` FIELDS (`.server/.reachable/.token_present/.cloud.logged_in`) — whoami exits 0 even when unreachable, so rc is a vacuous green. Host derivation for engine prompts: `bp capabilities -o json → .server.base_url`, never a hardcoded literal and never a raw config.json read (four precedence layers sit above it).
- **D10 — .gitignore gets all ELEVEN `.claude` runtime paths.** The runtime ignores live only in this Mac's `.git/info/exclude`, which git never clones (proven in a virgin clone: `?? .claude/worktrees/`). Committing only `worktrees/` leaves nine other paths dirtying a second machine's tree.
- **D11 — PR #6086 is not a blocker; the wave lands first.** Mutation-proven: wave edits at whenToUse:5, NO_FABLE:102, GATES_BLOCK:126–131, host:152 add ZERO conflict surface. The PAPER_BLOCK slice owns the one shared region (:158) and folds the PR's two wall-aligned bullets (BEAUTIFUL BY CONTRACT / CURATE, DON'T DUMP) into its rewrite; the PR's later rebase takes the wave's side of region 1. Filed as backlog.
- **D12 — bp-served workflows stays deferred.** No consumer without a clone exists (Studio chat runs inside the prod clone; cloud connector sessions have no exec tools; the engine is clone-bound via worktrees + tracked charters). Cheap later via the scaffy generic-query pattern if a thin consumer ever appears.
- **D13 — Charter file naming.** This epic's charter lives at `.claude/workflows/bp-epic-cycle-distribution-charter.md` — NOT `bp-cloud-epic-charter.md` (that is the Cloud epic's memory and the engine's default arg; overwriting it would destroy another epic's charter). Future waves pass `charter_path` explicitly.

## Roadmap

Wave 1 (this wave — 7 slices):

1. **ecd-w1-s1-view-edit-parity-delocalize** (S, opus, round 1) — drop the machine prefixes at :65/:66 (repo-relative `api/…`), report path → repo-relative `docs/specs/`, add a scriptPath INVOKE line to its meta.
2. **ecd-w1-s2-epic-cycle-engine-portability** (M, fable, round 1) — bp-epic-cycle.workflow.js: meta teaches scriptPath (deletes the name-launch trap), CC=clang annotated as host-conditional, guerrilla host replaced by derived-host instruction, PAPER_BLOCK rewritten to the wall dialect (spacer mandate deleted; tag/opening/ceilings/422-loop taught; #6086's two bullets folded in).
3. **ecd-w1-s3-wild-bulk-portability** (M, opus, round 1) — no_fable switch, xhigh→high at 4 joints, CC=clang annotation, spacer sentence → wall dialect, phases roster reconciled with the 6 actual `phase()` calls.
4. **ecd-w1-s4-deep-investigation-listing** (S, opus, round 1) — hoist the scriptPath INVOKE ahead of the interview prose; listing (description + " - " + whenToUse) ≤1536 chars; spacer sentence → wall dialect.
5. **ecd-w1-s5-gitignore-doctor-honesty** (S, opus, round 1) — commit the eleven `.claude` runtime-ignore lines to `.gitignore`; `scripts/doctor.sh` reports missing bp as a visible issue in `--hook` mode (mutation-proven).
6. **ecd-w1-s7-launch-runbook** (M, fable, round 1) — the honest launch runbook in docs/setup/CLAUDE-CODE.md + `.claude/workflows/README.md` pointer.
7. **ecd-w1-s6-workflow-portability-tripwire** (M, opus, round 2, AFTER s1+s2+s3+s4 merge) — `scripts/workflow-portability-check.sh` + `.test.sh` (async-body compile mirror, meta/registration invariants, 512KiB cap, no absolute/home paths, git-tracked scriptPath refs, phases-declared==called, listing-length warn), wired into shell-harnesses.yml with a corpus-defining glob.

Later waves / seal:
- Live second-environment wave launch (the epic's third acceptance criterion) — human-gated: second machine + credentials + harness enablement.
- Tripwire promotion to a blocking context (required-checks governance).
- view-edit-parity substantive rewrite (its audit targets the pre-unification inline-style mechanism; superseded by view_edit_parity_test.exs) — or retirement.
- Charter-corpus hygiene ruling (prod IPs + customer emails already published in the tracked charters of a public repo).
- PR #6086 resolution onto post-wave main (region-1 recipe: take the wave's PAPER_BLOCK).

## Wave log

(wave 1 in flight — story: /papers/epic-cycle-distribution-wave-2026-08-12)
