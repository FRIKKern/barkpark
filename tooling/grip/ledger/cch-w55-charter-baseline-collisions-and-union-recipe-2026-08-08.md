# cch wave 55 — charter baseline, D-collision set, and the union-merge recipe (re-derivation)

Pinned: `origin/main` = `4b0a8a5d3d72848373d18c3aeb19efb913356351` (2026-08-08).
Charter: `.claude/workflows/bp-cloud-console-hardening-charter.md`, 6607 lines.
Every command below reads `git show origin/main:...` — never the worktree copy, which is dirty.

## 1. Baseline: 579 rows, ceiling D617, ONE hole (D95). "583" is wrong; so is "312 is a hole".

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -cE '^\| D[0-9]+'
    # 579

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -oE '^\| D[0-9]+' | sed 's/| D//' | sort -n \
      | awk 'NR>1 && $1!=p+1 {print p"->"$1} {p=$1}'
    # 94->96   498->511   534->547   561->575

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -oE '^\| D[0-9]+' | sed 's/| D//' | sort | uniq -d      # (empty: no duplicates)

Min 1, max 617. Absent: **95**, 499-510, 535-546, 562-574. The three blocks are RESERVED by open
PRs (below); **D95 is the only permanent hole — do not recycle it.**

**D312 IS NOT A HOLE.** `tooling/grip/ledger/cch-w54-charter-anchors-and-d-ceiling-2026-08-08.md`
says "Absent: 95, 312, …" and "577 rows". Both wrong. The row is **`| D312-CCH |`** — the charter's
only suffixed D-row — so a `grep -cE '^\| D312 '` (trailing space) misses it while the numeric
scan sees it:

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -nE '^\| D31[0-9]' | cut -c1-40
    # 631:| D312-CCH | **D298 IS UNREPRO...
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '^\| D[0-9]+-[A-Za-z]+' | sort -u
    # | D312-CCH

Any future D-row scanner MUST use `^\| D[0-9]+` (no trailing-space anchor) or it under-counts.

## 2. Every open PR touching this charter (exhaustive, not a hand list)

    for p in $(gh pr list --state open --limit 200 --json number -q '.[].number'); do \
      gh pr diff $p --name-only 2>/dev/null | grep -q 'bp-cloud-console-hardening-charter' && echo "PR $p"; done
    # 10766 10523 10404 10256 10054   <- exactly five, matches the direction's list

    for p in 10766 10523 10404 10256 10054; do echo "== PR $p"; \
      gh pr diff $p | grep -oE '^\+\| D[0-9]+' | sed 's/^+| D//' | sort -n | uniq | tr '\n' ' '; echo; done

| PR | added D-rows | on main already? |
|---|---|---|
| #10766 (wave 54) | 617-628 | **D617 COLLIDES** (different subject); 618-628 free |
| #10523 (wave 50) | 562-574 | none — clean reservation |
| #10404 (wave 48) | 524, 532, 535-546 | **524 + 532 already on main, STALER body** |
| #10256 (wave 45) | 499-510 | none — clean reservation |
| #10054 (wave 40) | 447-457 | **all 11 byte-identical to main — reserves nothing** |

Set arithmetic (note: `comm` needs LEXICALLY sorted input — `sort -n` silently breaks it):

    { for p in 10766 10523 10404 10256 10054; do gh pr diff $p | grep -oE '^\+\| D[0-9]+' | sed 's/^+| D//'; done; } | sort -u > /tmp/pr.s
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '^\| D[0-9]+' | sed 's/| D//' | sort -u > /tmp/main.s
    comm -23 /tmp/pr.s /tmp/main.s | sort -n | tr '\n' ' '   # RESERVED, non-citable (48 numbers)
    comm -12 /tmp/pr.s /tmp/main.s | sort -n | tr '\n' ' '   # RE-MINTS: 447..457 524 532 617

**RESERVED AND NON-CITABLE = D499-D510, D535-D546, D562-D574, D618-D628 (48 numbers).**
Not D617 — that one is already spent on main.

## 3. The #10766 D617 collision, quoted both ways

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^\| D617 ' | cut -c1-150
    # | D617 | **A FOREIGN EPIC'S TWO-SUBJECT CARVE-OUT, GRANTED AS AN ADD AND AUTHORED BY THAT EPIC'S OWN DECIDE** | See the Wave-anon-metering widening in §Surface fence...

    gh pr diff 10766 | grep -E '^\+\| D617 ' | cut -c1-150
    # +| D617 | **THE SUSPENSION CROWN IS CONFIRMED AS A MECHANISM AND LATENT AS AN EVENT — AND BOTH MUST BE SAID IN THE SAME BREATH** | Measured, not read...

**Cause, not coincidence.** #10766's base is `5b68852f4`, where the charter had 578 rows and ceiling
D616. Exactly ONE charter commit landed since:

    git log --oneline 5b68852f4..origin/main -- .claude/workflows/bp-cloud-console-hardening-charter.md
    # 5deae282d docs(anon-metering): wave-1 charter rulings D9-D16 + cch D617 carve-out + verify ledger (#10761)

A foreign epic (#10761) took D617 while #10766 sat CONFLICTING. #10766's workflows have never run,
so no gate will ever report this. **Remedy on rebase: renumber #10766's crown row D617 -> D629 and
shift its band to D629-D640, OR renumber it into the tail after wave 55 mints its own.** Whichever
the lead picks, wave 55 must NOT assume D618 is the first free number.

## 4. #10404's D524/D532 are a REVERT hazard, not a subject collision

The direction says they "already exist on main with different subjects". They do not — the
**headlines are identical**; main's bodies are the wave-48-CORRECTED versions and #10404 carries the
pre-correction text. Merging #10404 as-is silently reverts those corrections.

    diff <(gh pr diff 10404 | grep -E '^\+\| D(524|532) ' | sed 's/^+//') \
         <(git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^\| D(524|532) ')
    # differs; main's D524 carries "corrected at wave 48: the original cite `app.js:20279` is a WRONG-FILE phantom"
    # main's D532 carries "cite `:6678` stale by +233, actual `app.js:6911` at wave 48"

Resolution rule for those two rows: **take MAIN's side, drop the PR's.** Union applies to the
D535-D546 block only.

## 5. #10054 reserves nothing (already filed)

    diff <(gh pr diff 10054 | grep -oE '^\+\| D4[45][0-9] .*' | sed 's/^+//') \
         <(git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^\| D4(4[7-9]|5[0-7]) ')
    # (no output) -> IDENTICAL

Owned by `cch-w53-bl-pr-10054-is-a-stale-duplicate-charter-pr` ("Close PR #10054: it reserves no
D-numbers because all eleven of its rows are already byte-identical on main"). Law 0: do not re-cut.

## 6. Insert anchors at 4b0a8a5d3 (the direction's 965/967/2583/2585 all CONFIRM)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -nE '^## |one entry per wave'
    # 7:## Vision  25:## Standing laws  123:## Surface fence  305:## The dark crown
    # 312:## Decisions  967:## Roadmap  1209:## Roadmap  1436:## Roadmap (prior waves)
    # 2583:## Wave log  2585:<!-- one entry per wave: ... -->

| Anchor | line | insert | growth |
|---|---|---|---|
| `## Decisions` heading | 312 | — | — |
| table header `\|---\|---\|---\|` | 315 | — | — |
| last D-row `\| D617 \|` | **965** | new D-rows immediately AFTER 965 | DOWN / ASCENDING |
| blank | 966 | | |
| `## Roadmap` | **967** | `### Wave 55 …` after blank 968 | UP / DESCENDING (969=W53, 1047=W52, 1107=W51, 1176=W46) |
| `## Wave log` | **2583** | | |
| `<!-- one entry per wave -->` | **2585** | new entry after blank 2586 | UP / DESCENDING (2587 = wave 53 REVIEW) |

**#10766 is stale by exactly 32 lines.** Its base at `5b68852f4` had `## Roadmap` 935 / `## Wave log`
2551 / comment 2553; main now has 967 / 2583 / 2585. Its own hunk headers read
`@@ -931,10 +931,45 @@` and `@@ -2552,6 +2587,110 @@` — the `-2552` is the +32 offset:

    git show 5b68852f4:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -nE '^## Wave log|one entry per wave'
    # 2551:## Wave log   2553:<!-- one entry per wave: ... -->

`## Roadmap` is NOT a unique heading (967 / 1209 / 1436) — anchor by LINE or by the D-row text,
never by heading search.

## 7. The one pre-existing order break — PRESERVE IT, do not re-sort

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -nE '^\| D[0-9]+' | sed 's/:| D/ /' | awk '{print $1, $2}' \
      | awk 'NR>1 && $2<p {print "line "$1": D"p" -> D"$2} {p=$2}'
    # line 399: D84 -> D72

Exactly one inversion, at line 399. A "sort the D-table ascending" resolution would move D72 and
produce a diff on a row nobody edited. **Sort only the newly concatenated block; leave lines 316-965
byte-identical apart from the append.**

## 8. Union-merge recipe (the whole thing, in order)

1. `git fetch origin main` and rebase the wave-55 branch onto `origin/main` — never `-X ours/theirs`
   (charter D533: `-X` deletes 12 or 19 rulings outright, because the reserved blocks fall
   numerically INSIDE main's range).
2. D-table conflict -> **keep BOTH sides**, then sort ONLY the concatenated new rows ascending and
   append after main's `| D617 |` (line 965). Never re-sort lines 316-965 (see §7).
3. If the other side is #10404: for D524 and D532 **take main's row and DROP the PR's** (§4).
   Union the D535-D546 block normally.
4. Roadmap conflict -> keep both, order DESCENDING by wave number, newest directly under line 967.
5. Wave-log conflict -> keep both, order DESCENDING by date, newest directly under the comment
   at 2585.
6. Re-run §1's three commands on the merged file: count must equal 579 + (rows you added),
   duplicates must be empty, and the gap scan must still show only the reserved blocks + 95.

## 9. D629 is the next free number

    for p in 10766 10523 10404 10256 10054; do gh pr diff $p | grep -cE '^\+\| D629 '; done   # 0 0 0 0 0
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -cE '^\| D629 '  # 0

Highest number claimed anywhere (main ∪ all five PRs) = **D628** (#10766). **Wave 55 starts at D629**
and must skip nothing — D629 onward is unclaimed by main and by every open PR.
