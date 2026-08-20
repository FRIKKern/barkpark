# headline-retire-or-restate — wave-9 verifier re-derivation recipes (2026-07-27)

Subject: which charter headline figures still re-derive on `origin/main` today.
Authority: every row below is L2 (a command re-run against the tree), never a restatement.

## 0. Reading-path caveat (NEW — a seal must name it)

`foldLedger(dir)` and the CLI's `foldLedger(dir, cliBounds())` disagree on today's
store. Any quoted row count MUST name its path.

    node -e 'import("./tooling/grip/ledger.mjs").then(G=>console.log(G.foldLedger().stats))'
    # → rows 332 / subjects 280 / unreadable 323   (library default, no screen, no clock)
    node tooling/grip/ledger.mjs fold 2>/dev/null | tail -14
    # → rows 327 / subjects 275 / unreadable 371   (CLI: + shellNow + screenCommand)

Historical stores (62/63/229/230) are path-INDEPENDENT — bounded == unbounded.

## 1. 229-vs-230 and 62-vs-63 — BOTH REAL, an hour apart. 3.71x is the only error.

    SP=$(mktemp -d); git archive 87221bfa5^ tooling/grip/ledger | tar -x -C $SP
    # 3-run store (before grip-20260721T145131Z landed) → 62 rows
    # 4-run store (after it)                            → 63 rows
    # + grip-20260721T152122Z-4f7a1c25c71ceb5e.json (167 rows) → 229 / 230

Measured: 62 → 229 (3.69x) · 63 → 230 (3.65x, 144 subjects, 135 leads-indexed).
D85 publishes "63 rows → 230 rows = 3.71x". 3.7097 = 230/62 — a CROSSED pair.
RETIRE 3.71x. RESTATE 63 → 230 as 3.65x, or 62 → 229 as 3.69x. Never mix.

## 2. Figures that RE-DERIVE EXACTLY (historical scope, past tense only)

    node tooling/grip/screen.mjs --census | head -8
    # 651 distinct / 254 ADMITTED / 397 refused / 39.0%   ← D84, D85, screen.mjs:38

    # corpus is frozen: ONE commit, blob unchanged
    git rev-list --count origin/main -- tooling/grip/fixtures/evidence-corpus.json  # 1
    git rev-parse origin/main:tooling/grip/fixtures/evidence-corpus.json            # f0d6b6cbdb50…
    #   → 254/651 is VOLUME-independent (never reads the ledger; screen.mjs:1594
    #     reads only the fixture). It is NOT CODE-independent: 194 → 240 → 254.

    # D86: internal/cli 11 → 20   ·  D87: band 15 → 25 leads-faithful, 15 → 28 with cmd:
    # (re-run selectLeads / subsystemBand against the archived 62/63/229/230 stores)

    # D85: of the 167 minted rows, 32 network-reaching {bp:20, gh:11, curl:1},
    # hermetic floor 135 — EXACT on the first-head classifier (37 if `bp` anywhere
    # in a pipeline counts). The published classifier re-derives; name it.

## 3. Figures that must be RETIRED, not restated

| Figure | Where | Today |
|---|---|---|
| 3.71x | D85 | arithmetically impossible for any single base — use 3.65x or 3.69x |
| 230 rows (present tense) | D85, S1 row | 327 (CLI) / 332 (library) and rising |
| 15 → 25 band (present tense) | D87 | 40 leads-faithful / 43 with cmd: |
| internal/cli 20 (present tense) | D86 | 21 |
| "the 62 stored rows" | binding.mjs:13,15,72,89,112,113 · ledger.mjs:472,706 · census.mjs:1034 · trial-leads-vs-grep.mjs:24,69,130,562 | 327-row universe, 5 binding classes {cwd-bound 180, shared-ref 114, per-worktree 17, foreign-tree-pinned 8, content-addressed 8} |
| 327 / 5.27x | not in the charter — a wave-9 digest figure | do NOT enter it; the store is a shared write target and rots by design |

`240` (screen.mjs:43, census.mjs:316, :701) is NOT in this table: all three sit
inside prose that already declares it historical and names 254. Closed by content.

## 4. True ledger composition on origin/main @ d505293a5

    git ls-tree -r --name-only origin/main tooling/grip/ledger/ | grep -c  '\.json$'   # 73
    git ls-tree -r --name-only origin/main tooling/grip/ledger/ | grep -vc '\.json$'   # 28

101 files = 73 `.json` + 27 `.md` recipe/proof docs (foreign epics) + 1 `README.md`.
Of the 73 `.json`, 64 fold as runs and 9 are MALFORMED-RUN (foreign schemas, no
`recipes[]`). "100 committed ledger run files" is wrong — it counts the `.md` prose.
Unreadable, CLI-bounded: MALFORMED-ROW 202, LEVEL-SKIP 60, REFUSED-COMMAND 48,
UNKNOWN-FIELD 45, MALFORMED-RUN 9, VALUE-STORED 7 = 371.
