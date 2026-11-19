<!-- doc-tier: human | canonical-for: barkui-decision-home | budget: 900tok -->
# 0007 Incubated in Barkpark, and what makes it leave

Date: 2026-11-19 · Status: accepted

```
Barkpark today                                        BarkUI's own repo, when it leaves
design/themes, derive.mjs   the colour source  ─?─►   open: stays, moves, or is split
design/emit/barkui*.mjs     BarkUI's emitters  ───►   moves
api/priv/barkui/tokens.css  the sheet          ───►   moves
js/packages/barkui/         the package        ───►   moves
design/emit/*  (the rest)   Elixir, Go, web    ───    stays: Barkpark's own output
```

## Context

BarkUI is as large and as important as Barkpark's other projects, and is run as one: its own roadmap, decisions, quality bar and pictures. It lives inside Barkpark for now because two things hold it there:

- **The colour source is shared.** `design/themes/` and `design/derive.mjs` write BarkUI's sheet and also Barkpark's own Elixir, Go and web output. Moving BarkUI alone would leave one source writing into two repos.
- **The checks already run here.** Barkpark's hosted `js-tests` workflow runs the fast tests and the showroom check in a real browser on every change that touches BarkUI's files: anything under `js/`, the sheet in `api/priv/barkui/`, or the workflow itself (the workflow lists its other paths).

## Decision

BarkUI stays in Barkpark while it is young: the package in `js/packages/barkui/`, its emitters in `design/emit/`, its sheet in `api/priv/barkui/`. It keeps a front door of its own (this folder's README) and nothing in it depends on Barkpark's server code.

When it leaves, the package, the BarkUI emitters and the sheet move to their own repo, with their history. Where the colour source lives is the open question: it could stay in Barkpark and be read by BarkUI, move to BarkUI and be read by Barkpark, or be split so each owns its part. No date is set.

## What would change it

Any of these makes the move worth its cost:

- Apps in other repos install BarkUI as a package and need releases at their own pace.
- The colour source can be split, so BarkUI's skins and Barkpark's own output each have one home.
- Changes to BarkUI and to Barkpark start blocking each other in review or in checks.

## Considered

- **A repo of its own from the start.** Rejected for now: the colour source would have two homes on day one.
- **BarkUI inside the PortableDoc repo.** Rejected: PortableDoc defines documents; BarkUI draws apps too ([0002](0002-barkui-draws-portable-doc-defines.md)).
