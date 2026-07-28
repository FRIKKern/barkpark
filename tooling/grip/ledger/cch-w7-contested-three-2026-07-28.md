# cch-w7 · wave-6-contested-three — re-derivation recipes

Tree: `origin/main @ f38c01920985f6fc1581229dacb713345e4783a5`, fetched 2026-07-28.
Host load: quiet (no wave builders running; `node --test` wall 425ms).

## 1. gr-blk-console-refetch-storm — CLOSES. The cited SHA is a SQUASH.

The subject line of `481d6f231` names only the LAST commit of PR #5308. Reading `%s`
alone is what makes this row look unfixed; read `%b` and the parent count.

```
git log -1 --format='%s%n--PARENTS: %P' 481d6f231
git log -1 --format='%b' 481d6f231 | head -20
git log --oneline -S 'OVERVIEW_FULL' origin/main -- cloud/priv/static/app.js
git show origin/main:cloud/priv/static/app.js | grep -n 'OVERVIEW_FLEET\|paintOverviewData'
node --test cloud/priv/static/__app.test.mjs 2>&1 | grep '12 requests'
```

Expect: one parent (squash), `-S` names 481d6f231 as the SOLE introducer of
`OVERVIEW_FULL`, `OVERVIEW_FLEET` at `app.js:4986`, test `ok 7` green.
`82eb84a37` (the branch-side perf commit wave 6 also cited) is NOT an ancestor —
it was squashed away. Cite 481d6f231 alone.

Criterion-2 wording caveat, already anticipated by wave 6: the tally is
`[8,1,1,1,1]`, not five ones. `/v1/barkparks` repeating once per fleet event IS
the freshness contract. Close text must say 40→12, never "each once".

## 2. gr-blk-cssom-parity-harden — REPRODUCES. Do NOT close.

```
git show origin/main:cloud/priv/static/__preview__/cssom-parity.mjs | sed -n '649,663p;700,713p'
git ls-tree -r --name-only origin/main cloud/priv/static/__preview__/fixtures/
git show origin/main:cloud/priv/static/styleguide.html | grep -n '<style\|</style'
grep -n 'styleguide' cloud/lib/barkpark_cloud/web/router.ex
```

Expect: COUNT SKEW block prints but never touches the exit code (exit 0 at :705
is gated on `misses.length === 0 && !baselineMismatch` only) — criterion 1 unmet.
Fixtures dir holds `cssom-floor/` and `seal-predicate/` only — no CSS-nesting
fixture. `styleguide.html` carries an inline `<style>` spanning lines 9–203 and
is in the `Plug.Static` `only:` allowlist at `router.ex:350`, so ~194 lines of
SERVED CSS are uncovered — criterion 2 is a LIVE gap, not hypothetical.

Criterion 3's anchors have DRIFTED and must be re-located before re-running the
mutation proof: `.modal-root` is now `app.css:1071` (row cites 1029) under the
`REVIEW ADDENDUM` opener at `:1066`; `.wh-secret` is now `app.css:3150` (row
cites 3076) under `/* Shown-once rotated-secret block. */` at `:3149`.

## 3. cch-bl-get-census-rederive — CLOSES, but NOT on D82's ground.

D82 rejected the "#5434" close after scanning `scripts/` + `tooling/` only. The
classifier exists — outside both directories.

```
git log -1 --format='%h %ad %s' --date=short origin/main -- cloud/test/barkpark_cloud/web/router_head_fence_census_test.exs
cd cloud && mix test test/barkpark_cloud/web/router_head_fence_census_test.exs
```

Expect: landed by `a7b5284c4` (#5434, 2026-07-21); 4 tests, 0 failures.
It re-derives from `router.ex` source on every run and pins 62/45/5/12.

Independent re-derivation (mirrors the test's wrapper lists, no ExUnit):
see `scratchpad/census.mjs` shape — route regex `^\s*get[\s(]+"([^"]+)"`, block
end `^  end\s*$`, machine wrappers checked before session wrappers. On
f38c01920 it prints `total=62 session=45 machine=5 public=12`, matching the pins.

Criterion 3 ("did the 45-writer class GROW?") is answered: NO — 45 on 2026-07-21
and 45 today. Close ground = #5434 shipped the classifier; D46 supplies the
56-vs-62 reconciliation. D82's load-bearing "it shipped no classifier" is false.
