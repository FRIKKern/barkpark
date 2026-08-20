# cch-w48 — the raw-slug paint proof, re-derivable

VERIFIER carve-out row. Nothing here is a fix; it is the recipe that re-derives the
finding that scopes the wave-48 refusal-copy slice. Everything runs against a full-tree
`git archive origin/main` (fc27f0d7499046c2a5d511f2334f3fe1bc5878f7), never a checkout.

## The claim, in one line

Exactly TWO paint sites in `cloud/priv/static/app.js` render a machine slug at a human:
`app.js:3143` (team GitHub disconnect) and `app.js:11486` (site theme save). The three
other cited "bypasses" (`:2301`, `:7282`, `:7436`) CLASSIFY, never paint — replacing
their raw read with `friendly()` inverts live control flow.

## Re-derivation

```sh
D=$(mktemp -d); git archive origin/main | tar -x -C "$D"
cd "$D/cloud/priv/static"
node __app.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)'      # 988 / 988 / 0
git show origin/main:cloud/priv/static/app.js | sed -n '3137,3146p;11484,11488p'
```

The RENDER proof (not a source scan) boots the shipped `app.js` verbatim inside a
`node:vm` with a smoke-style DOM shim (`readyState:"complete"` ⇒ `init()` runs), routes
`fetch` to a hand-held table, drives the control, and reads `#toast-stack`'s innerHTML
back. Harness pattern is `cloud/priv/static/__preview__/smoke.mjs` `makeDom()`/
`bootScenario()` (lines 162-474) — copy it; it is not exported.

- Seed `localStorage["bpcloud.session"]`, `location.hash = "#providers"`.
- `GET /v1/github/installation` → `{connected:true, account_login:"acme-org"}` ⇒ arm 1
  paints and `#github-disconnect` exists.
- `registry.get("github-disconnect").click()` (the shim's `$("#id")` reads the flat
  registry, so the control resolves) ⇒ `DELETE /v1/github/installation` → 403
  `{error:"forbidden",required:"admin",scope:"team"}`.
- Read `#toast-stack` innerHTML: `<div class="toast-body">forbidden</div>`.

Site theme twin: `location.hash = "#site/s1"`, drive `hooks.applyRoute()`, then
`registry.get("site-theme-select").dispatchEvent({type:"change"})` with
`PATCH /v1/sites/s1` answering the same payload. Three inputs, three rendered bodies:
`forbidden` · `update failed (403)` (empty 403 body) · a raw `Ecto.ConstraintError` on a
500 with `detail`. The site-detail markup lands in registry key **`site-body`**, not
`view-site` — reading the wrong key silently reports 0 bytes.

## The mutation that proves the three refuted seeds are load-bearing

Boot the pure-helper harness (`readyState:"loading"`, `__app.test.mjs`'s sandbox) and
substitute `friendly()`'s sentence for the raw slug at each classifier:

| helper | raw slug `"forbidden"` | `friendly()` sentence |
|---|---|---|
| `rollbackRefusalTerminal` | `true` | `false` |
| `decommissionRefusalTerminal` | `true` | `false` |
| `catalogViewState` (404 `no_provider`) | `{"state":"no_provider"}` | `{"state":"unknown"}` |

A terminal refusal flipping to `false` turns a permanent authority determination into a
"Try again" loop; `no_provider → unknown` loses the connect-first arm. Both refusal
COPIES on those paths already route through `friendly()` (`app.js:7284` directly,
`app.js:7437` via `rollbackConflictCopy`), so the edits are no-ops on copy and damaging
on control flow.

## Two collateral facts worth their own rows

1. `__preview__/smoke.mjs:627-629` (a shipped COVERAGE-BOUNDARY comment) claims the
   remaining six destructive DELETEs "toast client-side CONSTANTS … and, in fact,
   honest". For `/v1/github/installation` that is FALSE on the error arm — it
   interpolates `r.data.error` raw. Its own line cites are stale: `:2295` vs the real
   `3138` (~843 lines), `:9991` vs the real `13008` (~3017 lines).
2. The SITE-level GitHub controls (`app.js:12999` connect, `13014` disconnect) already
   use `friendly(r.data, "Please try again.")`. The bypass is not a GitHub-surface
   property; it is two specific callbacks.
