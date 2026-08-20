# PDS w38 — register↔route join: re-derivation recipe

Derived at `origin/main` = `db7ea8858cd626c42efd48cb3af97f13ce739946`, in a clean
`git archive` tree (never the working tree).

## Setup

```sh
cd /Volumes/SATECHI/github/barkpark
rm -rf /tmp/v2 && mkdir -p /tmp/v2 && git archive origin/main | tar -x -C /tmp/v2
```

## The three derivations

The join scripts live at `/tmp/v2/j/{join,plug,reg,all,pipe}.exs` in the derivation
run; they are AST walkers, not greps. The load-bearing property is that
`scope "/p", Alias do … end` nesting is resolved by accumulating the alias argument
through the walk (`Module.concat/2`), NOT by assuming a `BarkparkWeb.` prefix.
Verification that resolution is total: `writes with UNRESOLVED module: 0`.

| Command | Prints |
|---|---|
| `cd /tmp/v2 && elixir j/all.exs` | population, join, disposition strata, twin key |
| `cd /tmp/v2 && elixir j/pipe.exs` | pipe_through per write route; twin pipeline sets |
| `cd /tmp/v2 && elixir j/reg.exs` | @register parsed from census AST; verdict + basis histograms |

## Numbers this recipe re-derives

| Quantity | Value |
|---|---|
| router write route calls (AST) | 169 |
| `plugin_routes(` real macro sites (AST, not grep) | 17 |
| plugin write route tuples | 35 |
| distinct `{module,action}` — router only | 136 |
| distinct `{module,action}` — union with plugin tuples | 168 |
| distinct `{method,path,module,action}` — union | 204 |
| @register rows | 91 |
| @register distinct `{path,mfa}` | 75 |
| @register distinct `{module,action}` | 75 |
| register pairs that JOIN to a write route | 48 |
| register pairs NOT write-routed | 27 |
| PROVEN rows | 15 |
| basis `:unexamined` rows | 33 |
| JUDGED by row-presence | 48 |
| JUDGED by verdict (basis ≠ `:unexamined`) | 30 |
| JUDGED by verdict (PROVEN only) | 12 |
| DARK (no register row) | 120 |
| DARK incl. row-but-all-`:unexamined` | 138 |
| `{module,action}` twins riding >1 path (router only) | 33 |
| twins crossing an admin/non-admin boundary | 0 |
| SCIM write routes (pipeline `[:scim]`) | 8 |
| SCIM register rows | 0 |

## The mutation proof (the key decision)

Plant one synthetic write route onto an ALREADY-PRESENT `{module,action}`:

```sh
cd /tmp/v2 && python3 - <<'PY'
p='api/lib/barkpark_web/router.ex'
L=open(p).read().split('\n')
assert L[1998]=='    post("/:dataset", WebhookController, :create)'
L.insert(1999, '    post("/:dataset/SYNTHETIC-ARRIVAL", WebhookController, :create)')
open(p,'w').write('\n'.join(L))
PY
elixir j/all.exs | grep POPULATION
```

Result: `{module,action}` stays **168 → 168** (arrival INVISIBLE; JUDGED 48 and
DARK 120 both unchanged). `{method,path,module,action}` goes **204 → 205**
(arrival ARRIVES). This is the decisive evidence for L4b's key.

## Vocabulary collision (do not re-discover)

`scripts/pds-elixir-receipt-census.exs` already owns the words *write-routed /
read-routed / unrouted* at `:2071-2073`, meaning **Repo-verb reachability**, not
HTTP-router reachability. L4 must NOT reuse them.
