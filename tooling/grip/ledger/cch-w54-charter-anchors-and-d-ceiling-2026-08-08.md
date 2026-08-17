# cch wave 54 — charter insert anchors + D-ceiling (re-derivation recipes)

Pinned: `origin/main` = `5b68852f46b75047908c1947280af1bf3f72e529`.
Charter blob unchanged since `dcfd083dd` (both resolve to blob `b652d199…`), 6575 lines.

## 1. D-ceiling is D616; D617 is free

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '\bD6[0-9]{2}\b' | sort -u | tail -3
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'D617'

## 2. Missing D-numbers (reserved blocks + two historical holes)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -nE '^\| D[0-9]+ \|' | sed -E 's/^([0-9]+):\| D([0-9]+) \|.*/\1 \2/'

577 rows, zero duplicate D-numbers. Absent: 95, 312, 499-510, 535-546, 562-574.
The three blocks are the reserved ones on open CONFLICTING PRs (#10256, #10404, #10523).
D95 and D312 are historical holes — do NOT recycle them; number forward from D617.

## 3. The three insert anchors (line numbers at 5b68852f4)

- D-table tail: last row is line **933** (`| D616 | …`); 934 is blank; `## Roadmap` is **935**.
  Insert new D-rows immediately AFTER 933. Growth direction: **DOWN / ASCENDING**.
- Roadmap wave section: `## Roadmap` **935**, blank 936, `### Wave 53 …` **937**.
  Insert `### Wave 54 …` after 936. Growth direction: **UP / DESCENDING** (53, 52, 51, 49, 47, 46, 44 …).
- Wave log: `## Wave log` **2551**, blank 2552, `<!-- one entry per wave: … -->` **2553**,
  blank 2554, first entry `### 2026-08-08 — wave 53 REVIEW …` **2555**.
  Insert after 2554. Growth direction: **UP / DESCENDING**.

Verify:

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -nE '^## |^<!--' 
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '2551,2556p'

## 4. Heading search is NOT a safe anchor

Three `## Roadmap`-family headings: **935**, **1177**, `## Roadmap (prior waves)` **1404**.
Two wave sections are stranded INSIDE `## Decisions` (281-934): `### Wave 49` at **831** and
`### Wave 47` at **849**, splitting the D-table into segments 663-827 and 892-933 (the tail
segment has no table header row, so the table is already broken markdown).

Proof of how that happened vs. how wave 53 did it right:

    git show bf309b27d -U0 -- .claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^@@'
    #  @@ -812,0 +813,15 @@   D-rows
    #  @@ -815,0 +831,18 @@   ### Wave 49 section — landed inside ## Decisions (WRONG)
    git show 336db9b94 -U0 -- .claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^@@'
    #  @@ -919,0 +920,14 @@   D603-D616 at the D-table tail (RIGHT)
    #  @@ -922,0 +937,78 @@   ### Wave 53 immediately under ## Roadmap:935 (RIGHT)
    git show dcfd083dd -U0 -- .claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^@@'
    #  @@ -2554,0 +2555,75 @@  wave-log entry PREPENDED after the HTML comment (RIGHT)

## 5. Union-merge recipe (opposite directions in one file)

Two independent writers both touch this file; the merge is a UNION INSERT, never `-X ours/theirs`
(charter D533: `-X` deletes 12 or 19 rulings outright because reserved blocks fall numerically
INSIDE main's range).

- D-table hunk: keep BOTH sides, then sort the concatenation by D-number **ASCENDING**.
- Roadmap + Wave-log hunks: keep BOTH sides, then order **DESCENDING** by wave number / date.
  A blind union that keeps "ours then theirs" in the same order for all three hunks silently
  mis-orders one of them — D533 measured exactly this failure (`46 → 44 → 45 → 43`).
- Post-merge assertions: zero duplicate D-numbers; every new number present exactly once;
  wave headings monotonically descending; no headless log fragment (D533's decapitation).

Charter growth carries no CI risk:

    git show origin/main:scripts/check-doc-budgets.sh | grep -ci charter   # 0
    git show origin/main:scripts/docs-anchors-check.sh | grep -n '\.claude' # ./.claude excluded

## 6. Open PRs already queued on this file (all CONFLICTING)

    gh pr list --state open --limit 200 --json number,title,mergeable,headRefName,files \
      --jq '[.[]|select((.files//[])|map(.path)|index(".claude/workflows/bp-cloud-console-hardening-charter.md"))][]|"\(.number)\t\(.mergeable)\t\(.title[0:70])"'

#10523 (D562-D574), #10404 (D535-D546), #10256 (D499-D510), #10054 (wave 40, ruled a stale
duplicate by D603). Four, not six, at this sha — and none of their gates re-run while CONFLICTING.
