<!-- doc-tier: agent | canonical-for: canonical-impl-markers | budget: 900tok -->
# Canonical-impl markers (code-side `canonical-for`)

This file owns the marker contract; the router keeps a pointer.

## When to stamp one

When a CAPABILITY has one true implementation a cold agent would otherwise have to
find among forks or decoys — similarly-named resolvers, or a jargon-named function
`grep` misses — stamp ONE machine-parsed comment above its **public** entry point, in
the host language's comment syntax:

```
@canonical capability:<kebab-slug> [aka:<grep,words>] [doc:<path>.md]
```
- `capability:` — a kebab-slug, unique repo-wide.
- `aka:` — the search vocabulary an agent actually types, so `grep backlink` lands on
  `reverse_referencers`. Carry the DELETED name here after a rename; that is the
  point of the field.
- `doc:` — optional backlink to the owning card or contract.
`grep -rn '@canonical capability:'` IS the index. No new card, deliberately — it
dodges the 7-card cap by design.

## Demand-driven, NOT universal

Tag only genuinely-forked or jargon-named capabilities. A well-named, unforked
function — `publish_document`, which self-points — earns no marker, and a marker
should be REMOVED once dedup eliminates its decoys. A zero-marker corpus is
legitimate: the gate reports the count, not a floor.

A marker certifies "one owner," **not** "bug-free."
## What the gate enforces

`scripts/docs-anchors-check.sh` §8 gates both invariants:

1. **Slug uniqueness** — a copy-paste that keeps the marker fails, turning dedup into
   a tripwire.
2. **Pairing** — a public `def` / `func` / `export` must follow within 6 lines, never
   a private `defp`.

§8b also pins each marker to the SYMBOL it names (`slug<TAB>symbol`, sorted,
no line numbers). A public function inserted between a marker and the function it was
written for STEALS it: the slug is still unique and a public def still follows, so §8
alone stays green. Regenerate with `REGEN_CANON_PIN=1` and READ THE DIFF: a changed
symbol means the canonical pointer now names different code.

`doc-gates.yml` triggers on `.ex` / `.go` / `.exs` / `.ts`, so a code rename re-checks.
That job is advisory: it reds its own check run, and cannot block a merge.

## What it does NOT enforce — ADVISORY BY DECISION, 2026-09-12

§8 has **no arm for the property a reader acts on**: that a slug has ONE impl. A
rival impl carrying no marker passes, and `aka:` selectivity is unchecked — a
CHOSEN posture, so read the no-fork claim as convention, never as a gate. A
tripwire that MUST block cannot live in paths-filtered `doc-gates.yml` (`Doc
budgets + anchors`, **S4** in `.github/required-checks.json`); giving one merge
authority means adopting the venue rule in
[merge-gates.md](../ops/merge-gates.md#where-a-guard-that-must-block-lives).


## Why this lever

It complements dedup: the AI-Score's one measured-positive navigation finding was
naming and pointer governance, **not** tree-tidiness.
