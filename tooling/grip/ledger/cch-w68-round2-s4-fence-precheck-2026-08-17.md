# cch-w68 round-2 S4 (cch-w65-bl action labels) — fence precheck re-derivation

Tip measured: `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2` (== `origin/main`, clean of tracked edits).

## 1 — does `__app.test.mjs` pin `ACTION_LABELS` / `humanAction`?

```bash
grep -n 'ACTION_LABELS\|humanAction' cloud/priv/static/__app.test.mjs
# 16264 only — a COMMENT ("The decoy is the REAL ACTION_LABELS vocabulary, pre-reversed")
```

Neither identifier is pinned. But three label **VALUES** are asserted through hooks:

```bash
grep -n 'created a site\|deleted a site\|minted an API token' cloud/priv/static/__app.test.mjs
# 6067   assert.equal(byKey["a:a1"], "ada@acme.com minted an API token");
# 13674  assert.equal(hooks.tlvGroupTitle(same), "ada@acme.com minted an API token");
# 13679  assert.equal(hooks.tlvGroupTitle(mixed), "minted an API token");
# 16273  assert.match(row, /…ops@acme\.com…detaerc deleted a site/);
# 16262  (comment only)
```

So renaming `token.minted` or `site.deleted`'s label reds the harness; the other 18 labels are unpinned.
D765's citation of `:15981` for the single mention is STALE — it is `:16264` today.

## 2 — `design/check.mjs` on today's tip

```bash
node design/check.mjs > /tmp/dc.out 2>&1; echo "RC=$?"; tail -3 /tmp/dc.out
# RC=0
# design/check.mjs: PASS — 18 surfaces in lockstep + §6 lifecycle parity holds,
#   every generated region attributed to design/emit.mjs.
```

## 3 — `ARTIFACTS` app.js premise, and the build-breaker PROVEN

```bash
node -e 'import("./design/emit.mjs").then(m=>{const p=m.ARTIFACTS.map(a=>a.path);
  console.log(p.length, p.filter(x=>x.endsWith("app.js")), p.filter((x,i)=>p.indexOf(x)!==i))})'
# 18 [ 'cloud/priv/static/app.js' ] []
```

Exactly one entry (`{name:"cloud SPA theme ids", kind:"css", markerBegin/markerEnd}`, `emit.mjs:2176-2177`
— the row's cited `emit.mjs:1981` is STALE). `emit-manifest.json` has 19 `regions` keys, incl. app.js.

The collision is **path-keyed, last-writer-wins**, at three sites:

- `emit.mjs:2427` — `nextRegions[r.path] = regionDigest(r.expectedRegion)` (`--write`)
- `emit.mjs:2373` — `next[u.path] = d` (`--adopt`)
- `emit.mjs:2310` — `const recorded = regions?.[r.path]` (`attribute`)

Reproduce the failure (no repo edit needed):

```bash
node -e 'import("./design/emit.mjs").then(m=>{const P="cloud/priv/static/app.js";const next={};
 const A="\n \"evergreen\"\n", B="\n \"site.created\": \"created a site\"\n";
 next[P]=m.regionDigest(A); const first=next[P]; next[P]=m.regionDigest(B);
 console.log(Object.keys(next).length, next[P]===first,
   m.attribute({path:P,name:"theme ids",currentRegion:A,error:null},next))})'
# 1 false unattributed
```

=> a second `ARTIFACTS` entry for `cloud/priv/static/app.js` leaves ONE of the two regions
permanently `unattributed`, i.e. `design/check.mjs` red forever. The comment at `emit.mjs:2170-2172`
*invites* a second marker per file, so this is a latent defect the slice is the first to hit.
Prerequisite: key the manifest by `path + marker` (or artifact `name`) and re-bless via `--adopt`,
committing the reshaped `emit-manifest.json`.

## 4 — Jason for `@external_resource` compile-time decode in `cloud/`

```bash
grep -n 'jason' cloud/mix.exs      # 58:      {:jason, "~> 1.2"},
```

Direct precedent, same app, same pattern (`cloud/lib/barkpark_cloud/web/router.ex:10304-10310`):

```elixir
@providers_capabilities_fixture Path.expand("../../../priv/static/__fixtures__/providers_capabilities.json", __DIR__)
@external_resource @providers_capabilities_fixture
@providers_capabilities @providers_capabilities_fixture |> File.read!() |> Jason.decode!()
```

## 5 — live counts (re-derived, criterion 1)

```bash
node -e 'const fs=require("fs");
 const d=fs.readFileSync("cloud/lib/barkpark_cloud/accounts/audit_event.ex","utf8")
   .match(/@actions ~w\(([\s\S]*?)\)/)[1].split(/\s+/).filter(Boolean);
 const l=[...fs.readFileSync("cloud/priv/static/app.js","utf8")
   .match(/var ACTION_LABELS = \{([\s\S]*?)\n  \};/)[1].matchAll(/"([a-z_.]+)":\s*"/g)].map(x=>x[1]);
 const ds=new Set(d), ls=new Set(l);
 console.log(d.length, l.length, d.filter(x=>!ls.has(x)).length, l.filter(x=>!ds.has(x)))'
# 56 20 36 []
```

`@actions` anchors the row cites (`audit_event.ex:64-90`, `validate_inclusion` at `:119`) are EXACT.
`ACTION_LABELS` is `app.js:16410-16435` / `humanAction` `:16437` — the row's `16041-16066` is STALE.

## 6 — doc-gates fence

`design/check.mjs` is run by **`doc-gates.yml` only**. There is NO `**/*.json` and NO `**/*.js|.mjs`
glob (see its own comment at `:131` — *"a seeded/removed fixture is a .json, covered by no glob above"*,
and `:137` — *"there is no `**/*.js` / `**/*.mjs` trigger"*). It DOES list
`cloud/priv/static/app.js` (`:143`, `:278`) and `cloud/priv/static/__app.test.mjs`, so the slice's own
PR triggers it. A new `design/audit-actions.json` still needs an explicit path line, or a
**json-only** future edit (a verb added to the manifest alone) never re-runs `design/check.mjs`.
`design/emit-manifest.json` is likewise absent from the fence (`grep -n emit-manifest .github/workflows/doc-gates.yml` → empty).

## 7 — harness baseline

```bash
node --check cloud/priv/static/app.js && echo OK
node --test cloud/priv/static/__app.test.mjs   # RC=0 — # tests 1058 / # pass 1058 / # fail 0
```
