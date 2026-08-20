# Re-derivation recipes — breakpoint-sweep's own false numerals (wave 63, v11)

The local checkout at `/Volumes/SATECHI/github/barkpark` was BEHIND origin/main
when these were taken (`HEAD 0789ab90a`, `origin/main 3af348c90`) and does not
contain `breakpoint-sweep.mjs` at all. Every command below runs against an
export of origin/main, never the worktree:

```sh
S=$(mktemp -d)
git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud/priv/static | tar -x -C "$S"
cd "$S/cloud/priv/static/__preview__"
```

## 1. The live axis (the numbers the instrument actually measures)

```sh
node -e "import('./breakpoint-sweep.mjs').then(m=>console.log('WIDTHS',m.WIDTHS.length,'CELLS',m.CELLS.length,'THEMES',m.THEMES.length,'product',m.CELLS.length*m.THEMES.length*m.WIDTHS.length,'RESIDUE',Object.keys(m.SCENARIO_RESIDUE).length))"
# WIDTHS 18 CELLS 26 THEMES 2 product 936 RESIDUE 85
```

## 2. The runner prints the truth while the file's prose lies

```sh
node breakpoint-sweep.mjs | tail -6
# >> @media     25 preludes (comment-stripped; the raw grep counts 34 …)
# >> axis       6 breakpoints … -> 18 boundary widths …
# >> scenarios  110 scenarios · 25 distinct covered by 26 cells · 85 residue over 13 families
# exit 0
```

## 3. The false prose sites

```sh
grep -c '15 widths' breakpoint-sweep.mjs        # 8   (axis is 18)
sed -n '28p;79,80p;183p;366,367p;384p;390p' breakpoint-sweep.mjs
grep -n '108/25/26/83/13\|83 pairs\|21 of them' breakpoint-sweep.test.mjs   # 625, 639, 623
```

## 4. The suite is GREEN while the file states a false census

```sh
node --test breakpoint-sweep.test.mjs 2>&1 | grep -E '^# (pass|fail)'
# # pass 54
# # fail 0
```

## 5. Dating the width drift (prose was TRUE when written, rotted one day later)

```sh
cd /Volumes/SATECHI/github/barkpark
git log origin/main -S'= 780 cells' --format='%h %ad %s' --date=short -- cloud/priv/static/__preview__/breakpoint-sweep.mjs
# 626466a0ca 2026-08-01  (the phrase is born)
# then, per commit, export the tree and evaluate WIDTHS.length:
#   626466a0ca 2026-08-01 -> 15 widths / 780   (prose TRUE)
#   c25466dacd 2026-08-02 -> 18 widths / 936   (prose FALSE, and still is)
for c in $(git log origin/main --format=%h -- cloud/priv/static/__preview__/breakpoint-sweep.mjs | head -16); do
  echo "$c $(git log -1 --format=%ad --date=short $c) x$(git show "${c}:cloud/priv/static/__preview__/breakpoint-sweep.mjs" | grep -c '15 widths')"
done
# NOTE the zsh trap: `$c:cloud/...` (unbraced) silently eats a character and
# git answers about a DIFFERENT path. Always `"${c}:path"`.
```

## 6. Why a `/swept by (\d+) cells/` arm would be VACUOUSLY GREEN

```sh
node -e "import('./breakpoint-sweep.mjs').then(m=>{const R=Object.entries(m.RESIDUE_FAMILY_REASONS);
console.log('digit',R.filter(([f,r])=>/swept by (\d+) cells/.test(r)).length,
            'word', R.filter(([f,r])=>/swept by ([A-Za-z]+) cells/.test(r)).length);})"
# digit 0 word 8      — all eight are spelled two/four/TEN
```

## 7. The cross-axis problem behind those eight clauses

```sh
node -e "import('./breakpoint-sweep.mjs').then(m=>{const cf={};for(const c of m.CELLS){const f='hash:'+String(c.hash).split('/')[0];cf[f]=(cf[f]||0)+1;}console.log(JSON.stringify(cf));})"
# {"hash:#overview":2,"hash:#fleet":2,"hash:#settings":12,"hash:#sites":1,
#  "hash:#activity":1,"hash:#operator":2,"hash:#instance":4,"hash:#site":2}
```

`RESIDUE_FAMILY_REASONS` is keyed by `familyOf(scenario.deepLink)`; cells carry
their own `hash`. `hash:#billing` and `hash:#notifications` are residue families
with ZERO cells on the `familyOf` axis, yet their prose says "swept by two
cells" (true on the `cell.hash` axis, under `#settings/…`). No single
derivation recounts these eight until that mapping is defined.
