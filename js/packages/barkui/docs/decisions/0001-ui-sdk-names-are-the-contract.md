<!-- doc-tier: human | canonical-for: barkui-decision-contract | budget: 700tok -->
# 0001 UI SDK's own names are the contract

Date: 2026-11-18 · Status: accepted

```
<button data-slot="button" data-variant="solid" data-pending>     UI SDK's slot name and state attributes
background: var(--ui-primary)                                     UI SDK's variable, BarkUI's value
[data-skin] [data-color-scheme] [data-surface] [data-depth]       BarkUI's axes
```

## Context

UI SDK ships behaviour with a plain default look. It already names every part (`data-slot`), its states (`data-disabled`, `data-pending` and the like) and every colour its default look reads (`--ui-*`). Barkpark's own pages name their colours under many prefixes today. Two contests compared ways to build BarkUI; the plan Paper `/papers/barkui-plan` has them and their results. The contract built on UI SDK's own names was picked, and the plan lists what behaviour still needs added to it.

## Decision

- A part's look keys on UI SDK's slot names and state attributes, not on class names of our own.
- Colours are UI SDK's `--ui-*` names where UI SDK has one, and `--bark-*` for what BarkUI adds: tones, a selected fill, surfaces, depth.
- BarkUI adds four axes as attributes that work on any element and nest: skin, scheme, surface and depth.
- Anything that prints this markup gets the look: a UI SDK element, a server template, a PortableDoc renderer.

## What would change it

UI SDK renaming its slots, states or variables in a way BarkUI cannot follow behind its pinned version ([0005](0005-ui-sdk-behind-a-seam.md)).

## Considered

- **A contract of our own names.** Rejected: every part would need a translation layer to UI SDK's markup, and UI SDK's own docs would stop applying.
