# PDS wave 38 — the write-routed denominator, re-derived two independent ways

Sha pinned: `origin/main` = `db7ea8858cd626c42efd48cb3af97f13ce739946` (2026-08-02).
Every recipe below reads `origin/main`, never the working tree — the primary
checkout was **301 commits behind** origin/main when these were run, and its
copy of the charter topped out at PDS-D345 while origin/main's tops at PDS-D516.

## 0. Pin the sha and confirm the local checkout is not the truth

```
git rev-parse origin/main
git rev-list --count HEAD..origin/main
git show origin/main:.claude/workflows/bp-pds-charter.md | grep -oE "PDS-D[0-9]+" | sed 's/PDS-D//' | sort -n | uniq | tail -1
```

## 1. DERIVATION A — compiled Phoenix route table (COMPLETE BY CONSTRUCTION)

`Phoenix.Router.routes/1` IS obtainable compile-only, no app boot, no OOM.
Cold (deps compile from empty `_build/dev`): ~7 min. Warm: **13 s**.

```
cd api && mix run --no-start -e 'rs = Phoenix.Router.routes(BarkparkWeb.Router); IO.puts("TOTAL_ROUTES=#{length(rs)}"); File.write!("/tmp/phx_routes.terms", :erlang.term_to_binary(rs))'
```

Analyse the persisted term file with plain `elixir` (no mix, no recompile):

```
elixir -e 'rs=File.read!("/tmp/phx_routes.terms")|>:erlang.binary_to_term()
IO.puts("TOTAL=#{length(rs)}")
IO.puts("BY_VERB=#{inspect(Enum.group_by(rs, & &1.verb)|>Enum.map(fn {k,v}->{k,length(v)} end)|>Enum.sort())}")
w=Enum.filter(rs, & &1.verb in [:post,:put,:patch,:delete])
IO.puts("PHX_WRITE_ROUTES=#{length(w)}")
IO.puts("PHX_DISTINCT_WRITE_PAIRS=#{length(Enum.uniq(Enum.map(w,&{&1.plug,&1.plug_opts})))}")
lv=Enum.filter(rs, & &1.plug==Phoenix.LiveView.Plug)
IO.puts("LIVEVIEW_ROUTE_ENTRIES=#{length(lv)} DISTINCT_MODULES=#{length(Enum.uniq(Enum.map(lv,& &1.metadata[:phoenix_live_view]|>elem(0))))} WRITE_VERB_ENTRIES=#{length(Enum.filter(lv,& &1.verb in [:post,:put,:patch,:delete]))}")'
```

Result at db7ea8858 (Phoenix 1.8.9):

```
TOTAL=473
BY_VERB=[delete: 35, get: 257, options: 4, patch: 5, post: 162, put: 10]
PHX_WRITE_ROUTES=212
PHX_DISTINCT_WRITE_PAIRS=170
LIVEVIEW_ROUTE_ENTRIES=43 DISTINCT_MODULES=27 WRITE_VERB_ENTRIES=0
```

KNOWN LIMIT: the Phoenix 1.8.9 route map is
`[:path, :metadata, :plug, :plug_opts, :verb, :helper]` — **there is no
`pipe_through` key**. The pipeline / admin axis is NOT recoverable from the
compiled table and must come from derivation B.

## 2. DERIVATION B — AST pass over router.ex + plugin route tuples

```
git show origin/main:api/lib/barkpark_web/router.ex > /tmp/v1router.ex
elixir <ast-script> /tmp/v1router.ex
```

Script kept at `tooling/grip/ledger/` sibling? No — it was scratch. Its shape:
`Code.string_to_quoted(src, columns: true)`, walk, carry a scope-alias stack
(`Module.concat(scope_alias ++ parts)`) and a `pipe_through` stack restored at
each `__block__` boundary. Verb heads `get/post/put/patch/delete/head/options`
with arity>=3; `plugin_routes`, `live`, `forward`, `resources` counted separately.

```
AST_ROUTE_CALLS=350
AST_WRITE_ROUTE_CALLS=169
AST_DISTINCT_WRITE_PAIRS=136
SCOPED_TWIN_PAIRS=33
MULTILINE_WRITE_CALLS=8 lines=[1632,2135,2227,2233,2239,2251,2435,2443]
PLUGIN_ROUTES_MACRO_SITES=17 (grep 'plugin_routes(' says 23; 6 are comment prose)
LIVE_CALLS=19  FORWARD_CALLS=0  RESOURCES_CALLS=0  UNRESOLVED_MODULES=0
WRITE_CALLS_ADMIN_PIPED=57  NON_ADMIN=112
DISTINCT_PAIRS_ADMIN=42  DISTINCT_PAIRS_NONADMIN=94
```

Plugin tuples (AST, multiline-safe) over the 8 `register_routes/1` owners plus
`Barkpark.Plugins.OnixEdit.Routes` (onixedit DELEGATES — a literal-grep over
`plugins/*.ex` alone misses it):

```
PLUGIN_TUPLES_AST_TOTAL=79  PLUGIN_WRITE_TUPLES_AST=37
PLUGIN_DISTINCT_WRITE_PAIRS_AST=37  PLUGIN_LIVE_TUPLES_AST=13
```

Union: 136 router + 37 plugin, overlap 3 → **170**, identical to derivation A.

## 3. RECONCILIATION — which lens produced which integer

| integer | lens | defect |
|---|---|---|
| 161 write route CALLS | `grep -cE '^[[:space:]]*(post\|put\|patch\|delete)\(.*\)[[:space:]]*$'` (single-line-complete) | blind to the 8 multiline calls |
| 169 write route CALLS | AST, and also `grep -cE '(post\|put\|patch\|delete)\('` | correct for router.ex |
| 212 write route ENTRIES | compiled table | 172 router + 38 plugin + 2 alias-indirect |
| 131 distinct pairs | single-line lens | loses 5 pairs (4 CycleFleet, 1 MediaCollections) |
| 136 distinct pairs | AST, router only | correct, router only |
| 170 distinct pairs | AST union AND compiled table | the denominator |

Reproduce the 161/131 lens exactly:

```
grep -cE '^[[:space:]]*(post|put|patch|delete)\(.*\)[[:space:]]*$' /tmp/v1router.ex   # 161
grep -oE '^[[:space:]]*(post|put|patch|delete)\("[^"]*",[[:space:]]*([A-Za-z0-9_.]+),[[:space:]]*:([a-z_0-9]+)' /tmp/v1router.ex \
  | sed -E 's/.*,[[:space:]]*([A-Za-z0-9_.]+),[[:space:]]*:([a-z_0-9]+)/\1 \2/' | sort -u | wc -l   # 131
```

The 5 pairs only a multiline-capable lens sees:
`CycleFleetController.{create_result, admit_open_release_gate, stage_release_paper, activate_release_gate}`
and `V1.MediaCollectionsController.remove_member`.

## 4. Disposition axis

Union over 170 distinct write pairs, admin-reachable computed as
"any mount whose pipe_through contains a pipeline named `*admin*`, or whose
plugin `auth:` opt is `:admin`/`:api`/`:ops`":

```
UNION_DISTINCT_WRITE_PAIRS=170  UNION_ADMIN_REACHABLE=47  UNION_NON_ADMIN_ONLY=123
```

SCIM has **8** write routes, not the 3 the wave brief names:
`ScimUsersController.{create,update,replace,delete}` +
`ScimGroupsController.{create,replace,update,delete}`, all on `pipe_through [:scim]`.

## 5. The genuinely unkeyable shape

LiveView. 43 route entries / **27 distinct modules**, every one verb `:get`,
`plug: Phoenix.LiveView.Plug`, `metadata.mfa = {Mod, :__live__, 0}`. Their
`handle_event/3` writes carry no `{Controller, action}` key at all. The plugin
macro shape is NOT blind — it resolves cleanly in both derivations.
