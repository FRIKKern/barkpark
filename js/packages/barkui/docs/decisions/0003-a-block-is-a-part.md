<!-- doc-tier: human | canonical-for: barkui-decision-block-is-part | budget: 500tok -->
# 0003 A block is a part

Date: 2026-11-18 · Status: accepted

```
a table block in a Paper  ─┐
                           ├─►  one table part: one look, one behaviour, every format
a table in an app         ─┘
```

## Context

The same thing is often built twice: a table in a document and a grid in an app, a callout block and a notice in a screen. Each copy drifts from the other.

## Decision

A document block and the app part it resembles are one part, built once. The table block and the grid go first. Other blocks become parts only when an app needs them as one; until then they are drawn by PortableDoc's renderers through the bridge ([0002](0002-barkui-draws-portable-doc-defines.md)).

## What would change it

A block whose document form and app form need different behaviour, so that one part would carry two sets of rules.

## Considered

- **Move every block at once.** Rejected: the renderers already draw every block well; moving one with no app asking for it is work with no reward.
