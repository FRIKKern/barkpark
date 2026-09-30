<!-- doc-tier: agent | canonical-for: canonical-impl-markers | budget: 900tok -->
# Canonical-impl markers (code-side `canonical-for`)

This file owns the marker contract; the router keeps a pointer.

## When to stamp one

When a CAPABILITY has one true implementation a cold agent would otherwise have to
find among forks or decoys — similarly-named resolvers, or a jargon-named function
`grep` misses — stamp ONE machine-parsed comment above its **public** entry point:

```
@canonical capability:<kebab-slug> [aka:<grep,words>] [doc:<path>.md]
```
- `capability:` — a kebab-slug, unique repo-wide.
- `aka:` — the search vocabulary an agent actually types. Carry the DELETED name
  here after a rename; that is the point of the field.
- `doc:` — optional backlink to the owning card or contract.

## What counts: declarations, not citations

A marker is a DECLARATION: a comment whose text STARTS with `@canonical
capability:` (after `#` or `//`), in `.ex`/`.exs`/`.go`/`.ts`/`.tsx`/`.mjs`/`.js`.
Prose that QUOTES a slug (a moduledoc, a doc) is a citation and is not one. Test
files (`*_test.*`, `*.test.*`, `*.spec.*`) and `_build`/`deps`/`node_modules`
are excluded: a test only holds a marker as fixture data. So the INDEX is §8's scan
set, whose count `scripts/docs-anchors-check.sh` prints (`§8 scanned N`). A bare
`grep -rn '@canonical capability:'` over-counts by the citations.

## Demand-driven, NOT universal

Tag only genuinely-forked or jargon-named capabilities; remove a marker once dedup
eliminates its decoys. A zero-marker corpus is legitimate. A marker certifies "one
owner," **not** "bug-free."

## What the gate enforces

`scripts/docs-anchors-check.sh` §8: **slug uniqueness** (a copy-paste that keeps
the marker fails) and **pairing** (a public `def`/`func`/`export` within 6 lines,
never a private `defp`). §8b pins each marker to the SYMBOL it names; a public
function inserted between STEALS it, so regenerate with `REGEN_CANON_PIN=1` and
READ THE DIFF. `doc-gates.yml` triggers on `.ex`/`.go`/`.exs`/`.ts`; that job is
advisory and cannot block a merge.

## What it does NOT enforce — ADVISORY BY DECISION, 2026-09-12

No arm checks that a slug has ONE impl: a rival impl carrying no marker passes, and
`aka:` selectivity is unchecked. Read the no-fork claim as convention. A tripwire
that MUST block needs the venue rule in
[merge-gates.md](../ops/merge-gates.md#where-a-guard-that-must-block-lives).

## Why this lever

Naming and pointer governance, not tree-tidiness, was the AI-Score's one
measured-positive navigation finding. Markers dodge the 7-card cap by design.
