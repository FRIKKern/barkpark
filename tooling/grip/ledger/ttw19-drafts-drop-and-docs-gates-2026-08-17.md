<!-- doc-tier: cold | canonical-for: ttw19-drafts-drop-and-docs-gates-rederivation | budget: 400tok -->
# Task-TUI W19 — drafts-drop + docs/CI-gate re-derivation recipes

Verifier carve-out row (no commit by me; Decide commits). Each fact + the ONE command that re-derives it from origin/main state.

## 1. There is NO drafts.* filter in the Go tree — the NOW-band drop is server-side

    grep -rn 'draftsPrefix\|bareID(' internal/taskboard/*.go | grep -v _test.go
    # → every hit is NORMALIZATION (strip "drafts." so ids/slugs JOIN), never filter/exclude.
    sed -n '355,361p' internal/taskboard/board.go
    # → NOW filter is exactly: Claim != nil && Claim.Worker != "" && Lifecycle == in_progress. No prefix gate.
    grep -n 'limit=1000\|/v1/tasks' internal/taskboard/fetch.go
    # → fetch is GET /v1/tasks?limit=1000 (published list). drafts.* claims are draft docs that
    #   the published list does not return (or the 1000-row clamp truncates) — a SERVER/api contract
    #   artifact, OUTSIDE this wave's internal/ fence. No fixture/test pins a drafts-DROP.

## 2. docs-anchors-check FAILS only from mainbase/ worktree pollution (CI passes clean)

    bash scripts/docs-anchors-check.sh; echo $?          # → FAILED / exit 1 in the primary checkout
    grep '^FAIL' <out> | grep -vc mainbase               # → 50 (all @canonical dup FAILs)
    grep -rn '@canonical capability:' --include='*.ex' --include='*.go' --include='*.exs' --include='*.ts' \
      --exclude-dir=node_modules --exclude-dir=_build --exclude-dir=deps --exclude-dir=.git \
      --exclude-dir=.omx --exclude-dir=.tmp-bp89 --exclude-dir=.claude --exclude-dir=.artifacts \
      --exclude-dir=mainbase . | sed -E 's/.*capability:([a-z0-9-]+).*/\1/' | sort | uniq -d
    # → EMPTY. Script prunes .omx/.claude/.tmp-bp89 (lines 49-60) but NOT the ad-hoc `mainbase` worktree.
    #   All 252 FAILs are (real ./x + ./mainbase/x) dup pairs. On a clean CI checkout the gate is GREEN.

## 3. CI gates on an internal/taskboard-only (.go) PR

    grep -rn 'paths' .github/workflows/*.yml
    # FIRES: go-tests.yml (**/*.go, BLOCKING) · go-format.yml (**.go, advisory) ·
    #        doc-gates.yml (**/*.go → runs docs-anchors §8 + status-manifest-check + design/check.mjs steps,
    #          which check the design/ token surface and pass trivially for a taskboard PR) ·
    #        architecture.yml (internal/**, advisory) · aesthetics-guard.yml + pr-task-gate.yml (no paths).
    # GATING GAP: go-tests.yml paths list internal/pdrender/testdata/** but NOT internal/taskboard/testdata/**.
    #   A golden-only regen editing just internal/taskboard/testdata/*.txt (no .go diff) triggers NO Go suite
    #   — same #963→#969 class the go-tests carve-out comments describe for other fixture dirs.

## 4. Two stale TUI doc surfaces, both near cap, both zero mouse words

    git show origin/main:docs/cheatsheets/tui.md | wc -c   # 2391 / cap 2400 (9B headroom); last touch 2026-06-28 (#318)
    git show origin/main:docs/cards/tui.md | wc -c         # 2396 / ~2400 (4B headroom); last touch 2026-07-26 (#6237)
    git show origin/main:docs/cheatsheets/tui.md | grep -icE 'mouse|wheel|click|drag|divider|opt-shift'  # 0
    git show origin/main:docs/cards/tui.md | grep -icE 'mouse|wheel|click|drag|divider| M |opt-shift'     # 0
    # Docs slice scope = TWO net-neutral rewrites (agent card + human cheatsheet), not one.
