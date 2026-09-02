<!-- doc-tier: agent | canonical-for: canonical-impl-markers | budget: 900tok -->
# Canonical-impl markers (code-side `canonical-for`)

Split out of root `CLAUDE.md` to restore byte headroom there; this file is the owner
of the marker contract. The router keeps a one-line pointer, nothing more.

## When to stamp one

When a CAPABILITY has one true implementation that a cold agent would otherwise have
to find among forks or decoys — similarly-named resolvers, or a jargon-named function
that `grep` misses — stamp ONE machine-parsed comment above its **public** entry point,
in the host language's comment syntax:

```
@canonical capability:<kebab-slug> [aka:<grep,words>] [doc:<path>.md]
```

- `capability:` — a kebab-slug, unique repo-wide.
- `aka:` — the search vocabulary an agent actually types, so `grep backlink` lands on
  `reverse_referencers`. Carry the DELETED name here after a rename; that is the whole
  point of the field.
- `doc:` — optional backlink to the owning card or contract.

`grep -rn '@canonical capability:'` IS the index. There is no new card, and that is
deliberate — it dodges the 7-card cap by design.

## Demand-driven, NOT universal

Tag only genuinely-forked or jargon-named capabilities. A well-named, unforked function
— `publish_document`, which self-points — earns no marker, and a marker should be
REMOVED once dedup eliminates its decoys. A corpus of zero markers is a legitimate
tree, and the gate reports the count rather than asserting a floor.

A marker certifies "one owner," **not** "bug-free."

## What the gate enforces

`scripts/docs-anchors-check.sh` §8 gates both invariants:

1. **Slug uniqueness** — a copy-paste that keeps the marker fails, which turns dedup
   into a tripwire.
2. **Pairing** — a public `def` / `func` / `export` must follow within 6 lines, never a
   private `defp`.

§8b additionally pins each marker to the SYMBOL it names (`slug<TAB>symbol`, sorted, no
line numbers). A public function inserted between a marker and the function it was
written for STEALS the marker: the slug is still unique and a public def still follows,
so §8 alone stays green. Regenerate the pin deliberately with `REGEN_CANON_PIN=1` and
READ THE DIFF — a changed symbol means the canonical pointer now names different code.

`doc-gates.yml` triggers on `.ex` / `.go` / `.exs` / `.ts`, so a code rename re-checks.
That job is advisory: it reds its own check run, and cannot block a merge. See
`docs/ops/merge-gates.md` for what that distinction buys.

## Why this lever

This complements the dedup lever. The AI-Score's one measured-positive navigation
finding was naming and pointer governance — **not** tree-tidiness.
