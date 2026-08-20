# cch wave 69 — union-reconcile proof pack: re-derivation recipes

Verifier lane `union-reconcile-proof-pack`, 2026-08-17. Every number below is re-derivable by the
command printed beside it. `origin/main` at derivation time: `05a98dd2cadd10b649c3bc17cf75145a7571f80f`
(2026-08-17 12:00:26 +0200 — PR #11706, i.e. #11706 IS MERGED and IS the tip).

## 0. Fetch the five strands as local refs (every recipe below assumes this)

```sh
for n in 10054 10256 10404 10523 10766; do
  git fetch -q origin pull/$n/head:refs/tmp/pr$n
done
C=.claude/workflows/bp-cloud-console-hardening-charter.md
```

## 1. The four charter deletion lines (the MUST-RUN grep undercounts)

The briefed command `grep -E '^-\|'` finds only #10404's two rows. Two of the four deletions are
prose lines that do not start with a pipe, so use `^-[^-]`:

```sh
for n in 10054 10256 10404 10523 10766; do
  MB=$(git merge-base refs/tmp/pr$n origin/main)
  echo "== PR $n"; git diff -U0 $MB refs/tmp/pr$n -- $C | grep -nE '^-[^-]' | cut -c1-200
done
```

Result: `10054` = 0, `10256` = 1, `10404` = 2, `10523` = 0, `10766` = 1.

| PR | deleted line | what replaces it | ruling |
|---|---|---|---|
| 10256 | `### 2026-08-07 — wave 43 REVIEW (3/3 …)` | `### 2026-08-07 — wave 45 REVIEW (4/4 …)` | **MAIN's line wins.** Spurious — a diff-alignment artifact of inserting the wave-45 block over wave 43's heading (the known decapitation). Main's wave-43 heading is present at `charter:5111`; keep it and insert wave 45 as its own section immediately above **wave 44** (`:5043`). |
| 10404 | `\| D524 \| **LAUNCH GETS THE D-ROW…` | same row, `app.js:20279`→`index.html:296`, `:20281`→`index.html:312` | **BRANCH's line wins, and its correction is STILL TRUE TODAY.** |
| 10404 | `\| D532 \| **THE "SIXTEEN ENABLED MEMBER BUTTONS" ALARM IS REFUTED…` | same row, three bare cites gain function names + `stale by +N, actual app.js:NNNN at wave 48` | **BRANCH's line wins** (adds names + an explicit as-of stamp). Do NOT re-derive to wave-69 numbers — all three wave-48 cites are wrong today, but the stamp makes them honest history. |
| 10766 | `### Wave 53 — THE CUSTODY REGISTER … (build in flight)` | `… (MERGED 2026-08-08 — #10725/#10726/#10727/#10728, review log #10729; round 2 dispatches in wave 54)` | **BRANCH's line wins.** Main still says `(build in flight)` at `charter:1777` — a stale status main never received. |

Re-derive the D524/D532 rulings:

```sh
git show origin/main:$C > /tmp/main.charter
git show refs/tmp/pr10404:$C > /tmp/pr10404.charter
grep -E '^\| D524 \|' /tmp/main.charter | head -c 400; echo
grep -E '^\| D524 \|' /tmp/pr10404.charter | head -c 400
# D524's corrected cites, verified live on today's main:
git show origin/main:cloud/priv/static/index.html | sed -n '296p;312p'
git show origin/main:cloud/priv/static/app.js | sed -n '20279p'   # sparkline expr — the phantom
# D532's wave-48 cites vs today:
git grep -nE 'function (instanceHeaderHtml|updatePanelHtml|adminWriteControlHtml)' origin/main -- cloud/priv/static/app.js
```

## 2. Prose-level dedupe: #10054's charter hunk is 100 % already on main

```sh
git show origin/main:$C > /tmp/main.charter
MB=$(git merge-base refs/tmp/pr10054 origin/main)
git diff $MB refs/tmp/pr10054 -- $C | grep '^+' | grep -v '^+++' | sed 's/^+//' | grep -v '^$' > /tmp/p10054.add
tot=$(wc -l < /tmp/p10054.add); pres=0
while IFS= read -r l; do grep -qxF -- "$l" /tmp/main.charter && pres=$((pres+1)); done < /tmp/p10054.add
echo "nonblank_added=$tot already_on_main=$pres"     # → 124 / 124
git show origin/main:$C | grep -nE '^### Wave 40 —'  # → 2170, byte-present
```

Same loop over the others: `10256` 61/3, `10404` 27/0, `10523` 102/3, `10766` 114/3. The "3" is
boilerplate in every case (`|---|---|---|---|---|` ×2 and `**What the next wave must know.**`) — safe
duplicates in distinct tables/sections, no dedupe needed.

**Consequence:** #10054 contributes ZERO charter bytes. Drop its charter hunk entirely (exactly the
`#10173` disposition proven by `dr-w35-s1-union-charter-reconcile` criterion 1) and carry only its
six ledger sidecars. Neither wave-45/48/50/54 **section** nor **review-log** heading is on main:

```sh
git show origin/main:$C | grep -nE '^### Wave (40|45|48|50|54) —'          # → only Wave 40
git show origin/main:$C | grep -nE '^### 2026-08-0[78] — wave [0-9]+ REVIEW' # → 56 55 53 52 51 49 47 46 44 43
```

## 3. D-census on today's main, and post-union

```sh
git show origin/main:$C | grep -oE '^\| D[0-9]+ \|' | grep -oE '[0-9]+' | sort -n | python3 -c \
 "import sys;ds=sorted({int(x) for x in sys.stdin});print(len(ds),ds[-1],[(a+1,b-1) for a,b in zip(ds,ds[1:]) if b-a>1])"
```

Today: **789 rows, ceiling D840**, holes `95, 312, 499-510, 535-546, 562-574, 618-628, 645`.
Wave-68's merges did **not** move it — the charter's last touch is the wave-68 charter PR itself
(`git log -1 --format='%H %ci %s' origin/main -- $C` → `47c32698e8 … #11678`).

`D312` and `D617` are NOT what a naive read suggests:

```sh
git show origin/main:$C | grep -cE '^\| D312-CCH'   # → 1  (defined with a suffix; the strict regex misses it)
git show origin/main:$C | grep -c '^| D617 |'       # → 1  (main's anon-metering row — collides with #10766's)
grep -nE '\| D9[0-9]+ \|' /tmp/main.charter | head   # → D94 then D96: D95 is a GENUINE pre-existing hole
```

Post-union arithmetic, with #10766's D617 **moved to D645** as main's own D646 orders:

```sh
python3 - <<'EOF'
main=set(int(x) for x in open('/tmp/main.dnums'))   # from the census command above, `-u`
strands={10256:set(range(499,511)),10404:set(range(535,547)),
         10523:set(range(562,575)),10766:set(range(618,629))|{645}}
u=main.union(*strands.values())
print(len(u),max(u),[n for n in range(min(u),max(u)+1) if n not in u])
EOF
```

→ **838 rows, ceiling D840, holes `[95, 312]`** (312 = the `D312-CCH` regex artifact, 95 = genuine).
Zero collisions with main on any strand's new numbers.

**The digest's "837 rows, sole hole 95" is arithmetically reachable only by DROPPING #10766's D617
row instead of moving it** — that variant yields `837` with holes `[95, 312, 645]` and silently
deletes the suspension-crown ruling. Do not build to 837.

## 4. Sidecars: all 26 absent from main, and the local copies are untracked

```sh
for n in 10054 10256 10404 10523 10766; do
  MB=$(git merge-base refs/tmp/pr$n origin/main)
  git diff --name-only $MB refs/tmp/pr$n | grep -v 'charter\.md$' | while read f; do
    git cat-file -e origin/main:"$f" 2>/dev/null && echo "ON-MAIN $f" || echo "ABSENT  $f"
  done
done
git ls-files --others --exclude-standard tooling/grip/ledger/ | wc -l   # → 107 untracked locally
```

Every sidecar prints `ABSENT` (26 files: 6 + 9 + 6 + 2 + 3). Two of them contain `charter` in the
filename and are dropped by a `grep -v charter` filter — check them by name:
`tooling/grip/ledger/charter-citation-remedy-w48-2026-08-07.md` and
`tooling/grip/ledger/cch-w54-charter-anchors-and-d-ceiling-2026-08-08.md`. Both absent from main,
both present as untracked files in this shared checkout — **build from `refs/tmp/pr<n>:<path>` blobs,
never from the working tree** (`dr-w35-s1` criterion 3 shape: assert `git cat-file -e origin/main:<path>`
fails AND `sha1(blob) == sha1(on-disk)`).

## 5. Insertion anchors (hunk contexts, per strand)

```sh
for n in 10256 10404 10523 10766; do MB=$(git merge-base refs/tmp/pr$n origin/main)
  echo "-- PR$n"; git diff -U1 $MB refs/tmp/pr$n -- $C | grep -E '^@@' | cut -c1-140; done
```

Decision-table hunks all anchor on `fake it, or file work that depends on it being lit. Same
disposition for the QR…` (#10256 @781, #10404 @801/@809/@815, #10523 @827) or `already been wrong
three times in prose.` (#10766 @933/@936). Wave-log hunks anchor on `removes what it creates, growing
~1 entry per few minutes under load) wanting a…` (#10256 @2144, #10523 @2305, #10766 @2554).

## 6. Strand states, and the collapsed sequencing law

```sh
for p in 10054 10256 10404 10523 10766; do printf '%s\t' $p
  gh pr view $p --json state,mergeable,mergeStateStatus,commits -q '[.state,.mergeable,.mergeStateStatus,(.commits|length)]|@tsv'; done
for p in 11706 11711; do printf '%s\t' $p; gh pr view $p --json state,mergedAt -q '[.state,.mergedAt]|@tsv'; done
```

All five strands `OPEN`, `mergeable=UNKNOWN`, `mergeStateStatus=UNKNOWN` (GitHub no longer recomputes
these; the w47 row's criterion "reports MERGEABLE" is currently unobtainable by construction).
**#11711 MERGED `2026-08-17T09:56:05Z`; #11706 MERGED `2026-08-17T10:00:27Z`** — both sequencing-law
blockers are gone; nothing in this wave needs a round 2 on their account.

## 7. The rows the union pays

```sh
bp task get cch-w47-bl-rebase-10256-union-insert-with-proven-resolution -o json
bp task get cchi-w46-bl-rebase-10256-and-rescue-10054-ledger-rows -o json
bp task get cch-w46-bl-rebase-10256-and-rescue-10054-ledger-rows -o json
bp task get dr-w35-s1-union-charter-reconcile -o json      # the proven doctrine, 6/6 met
```

- `cch-w47-bl-rebase-10256-union-insert-with-proven-resolution` — OPEN, priority 0, 0/7 criteria, parent `cloud-console-hardening-epic`.
- `cchi-w46-bl-rebase-10256-and-rescue-10054-ledger-rows` — OPEN, priority 1, 0/3, parent **`cch-instruments-epic`** (a FOREIGN epic; the cch twin `cch-w46-bl-…` is `cancelled`). Law-0 credit for this one does not land on cch's denominator.
