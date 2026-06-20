<!-- doc-tier: human -->
# Blast-radius monitor (programmatic core)

Answers "what does this change affect?" across Barkpark's three stacks (Go,
Elixir, JS/TS) **without burning tokens on what static analysis already knows.**
This is the deterministic half. An agentic layer (not built yet) will later
consume `last-impact.json` to reason about the parts machines can't see.

## The split

```
build-index.mjs   SLOW · out-of-band (CI / manual) · invokes go list + mix xref
        │           writes index.json — the cached reverse-dependency graph
        ▼
index.json
        │
check.mjs         FAST · the pre-push hook · pure JSON traversal, ~70ms
        │           NEVER invokes a compiler
        ▼
last-impact.json  the structured impact-set (records the exact diff range)
        │
dossier.mjs       FAST · per touched edge, assembles a SELF-CONTAINED payload:
        │           symbol delta + consumer code slice + guard contents.
        │           Content-hash cache → unchanged edges are never re-judged.
        ▼
dossiers/*.json   what an agent judges with ZERO exploration tool calls
```

## What each layer answers

| Question | Layer | How |
|---|---|---|
| Who depends on this Go package / JS workspace pkg? | **programmatic** | `index.json` reverse closure |
| What recompiles if I touch this Elixir file? | **programmatic** | `mix xref` reverse map (best-effort) |
| Did I touch the cross-language wire contract? | **programmatic** | `config.json` seam globs (no index needed) |
| Is a seam change *actually breaking* a consumer? | **agent (later)** | seeded from `last-impact.json` |
| Does a string-keyed / behaviour-dispatched edge matter? | **agent (later)** | promoted into `config.json` `dynamicEdges` |

The seam check is the highest-value, zero-cost output: it flags when a change to
`capabilities.ex`, `/v1` controllers, schema-v2 validators, or webhooks can break
the Go CLI or JS SDK — relationships **no single-language graph can see.**

## Use

```sh
node tooling/blast-radius/build-index.mjs          # build graph (add --skip-elixir to skip)
node tooling/blast-radius/check.mjs                # analyze @{u}..HEAD
node tooling/blast-radius/check.mjs --staged       # staged files
node tooling/blast-radius/check.mjs --range A..B   # arbitrary range
node tooling/blast-radius/check.mjs --json         # impact-set to stdout
node tooling/blast-radius/check.mjs --strict       # exit 1 when seam touched
sh   tooling/blast-radius/install-hook.sh          # wire the pre-push hook
```

`check.mjs` works with no index — it degrades to seam + file-level. Run
`build-index.mjs` (after a pull, or in CI) to get cross-package reachability.
`index.json` / `last-impact.json` / `dossiers/` are gitignored caches.

## Dossiers + verdict cache

```sh
node tooling/blast-radius/dossier.mjs                 # build a dossier per touched edge
node tooling/blast-radius/dossier.mjs --edge seam:http-api-v1
node tooling/blast-radius/dossier.mjs --json          # manifest to stdout
node tooling/blast-radius/dossier.mjs cache           # show cached verdicts
node tooling/blast-radius/dossier.mjs record <edgeId> <contentHash> '<verdict-json>'
```

Each `dossiers/<edge>.json` is self-contained: `changedSlices` (the diff hunks),
`consumerSlices` (anchored code windows on the far side of the seam),
`guardSlices` (current snapshot/contract-test contents), a `contentHash`, and the
`verdictSchema` the agent must emit. The agent reads nothing else.

**Cache:** verdicts are keyed by `edgeId@contentHash`. If the slices haven't
changed since the last verdict, the dossier is marked `skip` and excluded from
the token spend. `verdict-cache.json` is committed so verdicts are shared.

**Right-sizing:** a consumer glob is capped at 6 files; over-matches are logged
(`tighten its glob`) — never silently truncated.

## The flywheel

When the agent layer finds a real edge the graph missed, codify it under
`config.json` → `dynamicEdges`. The hook then catches it for free forever — you
pay tokens to discover each blind-spot edge once, not on every push.
