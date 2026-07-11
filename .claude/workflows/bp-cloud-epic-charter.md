# Epic-Cycle Dogfood — docs/INDEX.md Note (epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and rotates per epic.
> Preserved verbatim: the outgoing **pd-layout-engine ledger-reconcile** occupant at
> `bp-pd-layout-engine-charter.md` (which itself names **parity-page** at
> `bp-parity-page-charter.md` and the earlier occupants in its own header note). This
> file is now the memory of the **epic-cycle docs-index dry-run** epic.

Epic anchor: bp task slug **`epic-cycle-docs-index`** (published). Wave Paper:
`epic-cycle-docs-index-wave-2026-07-11` (style=article, guerrilla). This is a deliberate
**dogfood / test wave**: the deliverable is intentionally tiny — one `docs/INDEX.md`
edit — so the seven-phase epic cycle can be watched end-to-end with near-zero code blast
radius. The note being added is itself the self-referential proof: it names the three
durable artifacts an epic cycle produces, and this very wave is producing all three.

## Vision

A cold agent opening `docs/INDEX.md` sees, at the foot of the existing doc catalog, one
short line naming what an epic cycle produces — a wave-strategy Paper (style=article), bp
tasks (type:task), and builder commits — and pointing at the `bp-epic-cycle` workflow to
learn the loop. The catalog stays terse and under its hard 1200-byte cap, every existing
navigable path still resolves, and both doc-gates (`check-doc-budgets.sh`,
`docs-anchors-check.sh`) stay green in a clean CI checkout. Nothing else in the repo moves.

## Operational facts (builders read FIRST)

- **The 1200-byte cap is HARD and the file is at 1187B after this wave (13B headroom).**
  `scripts/check-doc-budgets.sh` line ~44 hardcodes `docs/INDEX.md 1200` (bytes, via
  `wc -c`); the header's `budget: 300tok` is format-checked only, never numerically
  enforced. NEVER raise the cap (doc contract). Any future line added here must be funded
  by a same-file trim.
- **`docs/INDEX.md` paths are docs-relative.** `docs-anchors-check.sh` §2 greps every
  `[A-Za-z0-9._/-]+\.md` token and resolves it at `docs/<token>`. Write `setup/TASK-SYSTEM.md`,
  NEVER `docs/setup/TASK-SYSTEM.md` (double-prefixes → FAIL). Brace-group entries
  (`cards/{a,b}.md`) escape the regex; prose names with no `.md` (the `bp-epic-cycle`
  workflow) are never grabbed.
- **`bp-epic-cycle` is a WORKFLOW** (`.claude/workflows/bp-epic-cycle.workflow.js`), NOT a
  SKILL.md — name it in prose, never as a `.md` path (a fabricated link fails §2).
- **Local `docs-anchors-check.sh` shows ~32 FAILs from untracked `.claude/worktrees/`
  copies** — pure environmental noise (V2 proved a clean `git archive HEAD` checkout exits
  0). A builder's isolated worktree is branched from committed state and carries no
  `.claude/worktrees/`, so it runs clean. The gate that matters is: budgets PASS + no
  INDEX/doc-catalog FAIL line that is NOT under `worktrees/`.
- **`bp task stamp` IS live on guerrilla** (inherited note from the outgoing occupant;
  the earlier "not live" claim was stale). Stamp criteria mid-claim; the LEAD closes the
  merge-gated criterion.

## Decisions

- **D1 — The note is NOT purely additive; it lands via a same-file trim.** *Why:*
  `docs/INDEX.md` is 1197B against a hard 1200B cap (3B headroom), so an honest ~110B
  three-artifact line cannot fit as a pure append — verify PROVED every candidate overflows
  without a compensating trim. Keeps it one file / one PR.
- **D2 — Sacrifice the beta `Swarm (beta):` line, NOT the `Domain:` line.** *Why:* Swarm
  is beta and its target is the whole `swarm/` directory (still trivially discoverable by
  listing), whereas `Domain:` lists 7 scattered concrete file paths that would become hard
  to find. Minimalism = preserve every real navigable path; delete only the lowest-value pointer.
- **D3 — Collapse the ` · ` separators on the `Frozen:` and `Domain:` lines to single
  spaces.** *Why:* frees ~33B with ZERO path loss (§2 matches bare `.md` tokens regardless
  of separator), funding a readable full-sentence note with 13B of headroom instead of
  COMBO_B's fragile 1B.
- **D4 — One pointer (the `bp-epic-cycle` workflow), not two.** *Why:*
  `setup/TASK-SYSTEM.md` is ALREADY cataloged in the `Setup:` line above, so re-pointing to
  it is redundant; the net-new pointer worth spending bytes on is the workflow (a `.claude/`
  file not otherwise in the catalog).
- **D5 — Drop the `(style=article)` / `(type:task)` parentheticals from the note.** *Why:*
  the core three-artifact claim is true without them and they cost ~40B; the precision is
  learnable at the pointer. TRUTH is preserved (nothing false); bytes go to the pointer that
  orients a cold agent.
- **D6 — Note wording stays artifact-focused ("builder commits"), not process-focused.**
  *Why:* the automation itself does not merge PRs (builders make local `loop-epic/*`
  commits; the LEAD pushes+merges post-Review) — naming the durable ARTIFACT avoids implying
  the workflow merges.
- **D7 — Final file lands at 1187B; exact text frozen in Decide, builder applies verbatim.**
  *Why:* single-slice dogfood wave — Decide already proved the exact bytes against both
  gates, so the builder's only job is faithful application + gate proof (no re-sizing that
  could overflow).

## Roadmap

- **W1 (this wave) — the note lands.** One slice: edit `docs/INDEX.md` (drop Swarm line +
  collapse Frozen/Domain separators + append the epic-cycle note), land ≤1200B, both
  gates green. Size: small. Model: opus (exact text pre-proven).
- **Backlog (filed, not this wave):**
  - `docs-anchors-uniqueness-exclude-worktrees` — §8a `@canonical` uniqueness check does
    not exclude `_build/deps/node_modules/.claude/worktrees` the way §8b does, so any stray
    untracked copy of a tracked file trips ~32 false-positive local FAILs. Latent gate bug;
    low priority. Size: small.
  - `prune-stale-agent-worktrees` — several full-repo copies under `.claude/worktrees/`
    from prior sessions pollute local gate runs; a periodic prune keeps local gates honest.
    Low priority. Size: small.
  - `index-restore-swarm-pointer` — if the 1200B cap ever frees (an entry retires), restore
    a `Swarm (beta): swarm/` pointer. Very low priority; tracks the nav removed by D2.

## Wave log

<!-- Review appends "### Wave <date>" entries here; empty at Decide. -->
