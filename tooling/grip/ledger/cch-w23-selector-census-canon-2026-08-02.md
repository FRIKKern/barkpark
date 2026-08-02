# CCH wave 23 — the canonical overflow-guard selector census

Re-derivation recipe. Target: `cloud/priv/static/__preview__/overflow-guard.mjs`
on `origin/main`, blob `ed3f51f0be443083c789578726297dc9862e9c2d`, 2475 lines.

## The one canonical sentence

> On `origin/main`, `overflow-guard.mjs` (blob `ed3f51f0b`, 2475 lines) contains
> **68 `querySelector(` OCCURRENCES on 55 LINES** and **15 `querySelectorAll(`
> occurrences on 15 lines** — occurrences counted with `grep -o … | wc -l`, lines
> with `grep -c`; the two rules differ because 13 lines carry two calls. Of the 68:
> **1** is prose inside a comment (`:1809`), **24** are `nav()` readiness arguments,
> **9** are `section.view:not([hidden])` active-view reads in measurement bodies,
> **11** are correctly row-scoped inside a `forEach`/`map` callback, and the
> **remaining 23 are the sweep population**.

## Re-derive

```sh
cd /Volumes/SATECHI/github/barkpark
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs > /tmp/og.mjs
wc -l /tmp/og.mjs                                  # 2475
grep -c  'querySelector('      /tmp/og.mjs         # 55   (LINES)
grep -oF 'querySelector('      /tmp/og.mjs | wc -l # 68   (OCCURRENCES)
grep -oF 'querySelectorAll('   /tmp/og.mjs | wc -l # 15
git rev-parse origin/main:cloud/priv/static/__preview__/overflow-guard.mjs
```

## D258's integers, adjudicated

| D258 claim | Truth | Verdict |
|---|---|---|
| 65 `querySelector(` per CALL | 68 occ / 67 executable / 55 lines / 37 distinct literals | **WRONG** — no counting rule and no revision on main ever produced 65 |
| 20 `querySelectorAll(` | 15 in this file | **WRONG, and explained**: 15 (overflow-guard) + 5 (breakpoint-sweep) = 20; D258 pooled two files in the same paragraph where it discusses breakpoint-sweep's six `querySelector` calls |
| "the digest's 68/15 is also wrong" | 68/15 is the correct occurrence pair | **WRONG** |
| "55/15 is a LINE count" | 55 is; 15 is BOTH a line and an occurrence count | half right |
| 24 readiness predicates | 24 | **RIGHT** |
| 9 `:not([hidden])` singletons | 9 (measurement bodies; 10 more sit inside readiness args, 19 total) | **RIGHT** |
| 11 correctly row-scoped in a callback | 11 | **RIGHT** |
| breakpoint-sweep has SIX `querySelector` | 6 | **RIGHT** |

Never-existed proof: all 19 revisions of the file on `origin/main` read
12/0 → 26/1 → 30/1 → 36/2 → 38/3 → 43/5 → 43/7 → 48/8 → 51/9 → 54/11 → 58/13 →
61/14 → 63/14 → 68/15. 65 and 20 appear in none.

```sh
for c in $(git log --format=%h origin/main -- cloud/priv/static/__preview__/overflow-guard.mjs); do
  t=$(git show "${c}:cloud/priv/static/__preview__/overflow-guard.mjs")
  printf "%s %s\n" "$(printf '%s' "$t"|grep -oF 'querySelector('|wc -l)" \
                   "$(printf '%s' "$t"|grep -oF 'querySelectorAll('|wc -l)"
done | sort -n | uniq -c
```

## The 23-occurrence sweep population (residual after D258's three buckets)

| line(s) | occ | site |
|---|---|---|
| 791, 792, 793, 805 | 4 | GR109 `.attention-row` + `.attention-main` + `.attention-acts` |
| 925, 926, 927 | 5 | GR115 `host.querySelector` bp-console family (fixture-scoped) |
| 984 | 2 | `.instances-grid` + card 0 — the one filed vacuity |
| 1033, 1036, 1037, 1047, 1057, 1058, 1059, 1065, 1068 | 11 | `.set-matrix` family |
| 1133 | 1 | `.inst-tab[aria-current="page"]` |
| 2216 | 1 | `.token-ab` (a gesture, not a measurement) |

## Trap: the primary checkout is 327 commits behind

`/Volumes/SATECHI/github/barkpark` HEAD `a31faa52d` carries a 486-line
overflow-guard with **12** `querySelector(` and **ZERO** `querySelectorAll(`, and
has no `breakpoint-sweep.mjs` at all. Any census grepping disk instead of
`git show origin/main:` reports a fifth number. Always `git show origin/main:`.
