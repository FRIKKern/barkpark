# ttw22 — charter union splice recipe (wave-22 settlement dry-run) — 2026-08-17

Verifier vf-charter-union-dryrun. Proves the wave-22 SETTLEMENT slice (union the two
open charter PRs #11867 + #11924) assembles clean, byte-deterministically, off FRESH
origin. Line numbers here are anchored to the fetched branch heads below; the settlement
builder MUST re-fetch and re-grep the wave headers before splicing (line numbers drift —
#11875 FetchSnapshotFull precedent). This is the mechanical recipe, not a substitute for
re-derivation.

## Branch heads (re-fetch first)

- #11867 ref `epic-charter/task-tui-20260817T145123Z` — charter 2703 lines, ends at Wave 20 REVIEWED. Carries the 3 ttw20 verify ledgers.
- #11924 ref `epic-charter/task-tui-20260817T173402Z` — charter 2793 lines, has Wave 21 DECIDED+REVIEWED but SKIPS Wave 20 REVIEWED. Carries the 2 ttw21 verify ledgers.

## The gap (why a union, not a supersede)

`git show origin/epic-charter/task-tui-20260817T173402Z:.claude/workflows/bp-task-tui-epic-charter.md`
jumps DECIDED-20 (line 2527) straight to DECIDED-21 (line 2641): it lacks BOTH #11867's
Wave-20 REVIEWED block (c67 lines 2643-2703) AND the stale `Next D-number: D120` line
(c67 line 2641, correctly dropped). And #11924's branch is ABSENT all 3 ttw20-* ledgers —
so closing #11867 as "superseded" WITHOUT unioning silently loses the entire W20 verify
ledger. The union must carry all 5 ledger files.

## The splice (spine = #11924 tail)

    git fetch origin
    git show origin/epic-charter/task-tui-20260817T173402Z:.claude/workflows/bp-task-tui-epic-charter.md > c24.md
    git show origin/epic-charter/task-tui-20260817T145123Z:.claude/workflows/bp-task-tui-epic-charter.md > c67.md
    # re-derive the two boundaries by grep, do NOT trust these constants blind:
    #   A = last line of c24 DECIDED-20 block (blank line before Wave-21 DECIDED header) = 2640 at this head
    #   REVIEWED-20 body in c67 = lines 2643..2703 (header through EOF), dropping c67:2641 "Next D-number: D120"
    sed -n '1,2640p'    c24.md  > union.md
    sed -n '2643,2703p' c67.md >> union.md
    echo ""                     >> union.md
    sed -n '2641,2793p' c24.md >> union.md

## Assembly asserts (all passed in dry-run)

- Final line count: 2855.
- Section order: DECIDED-20 (2527) → REVIEWED-20 (2641) → DECIDED-21 (2703) → REVIEWED-21 (2798) → `Next D-number: D124` (2855).
- Exactly one `Next D-number` per wave-cadence = 3 total (D104, D114, D124); ZERO `D120`.
- One REVIEWED-20 header, one DECIDED-21 header (no duplicated section); both seams single-blank-line clean.

## Gate proof (union PR cannot red on docs)

- `bash scripts/check-doc-budgets.sh` → `check-doc-budgets: PASS` exit 0. Its allowlist is a hardcoded file list; `.claude/workflows/` charter is NOT in it.
- `grep -n 'claude/workflows' scripts/docs-anchors-check.sh scripts/check-doc-budgets.sh` → no hits. Neither gate scopes the charter path.

## Ledger carry manifest (all 5 must land in the union PR)

- from #11867: ttw20-anchor-currency-rederive, ttw20-drafts-claim-lifecycle, ttw20-fetch-path-map-and-now-denominator-drift (all `-2026-08-17.md`)
- from #11924: ttw21-d115-union-seam-contract, ttw21-vf-prime-route-and-failure-modes (all `-2026-08-17.md`)
