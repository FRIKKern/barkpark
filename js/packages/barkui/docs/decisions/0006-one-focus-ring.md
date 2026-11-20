<!-- doc-tier: human | canonical-for: barkui-decision-focus-ring | budget: 600tok -->
# 0006 One focus ring, in the base styles

Date: 2026-11-18 · Status: accepted

| Light | Dark |
|---|---|
| ![Primary and secondary buttons focused by Tab, light](../images/focus-light.png) | ![Primary and secondary buttons focused by Tab, dark](../images/focus-dark.png) |

## Context

When each part draws its own focus ring, rings differ from part to part and a part that forgets one is unusable by keyboard.

## Decision

`css/base.css` draws one ring for every part, in the last layer so no part's own shadow can cover it: a 2px gap in `--ui-background`, a 2px edge in `--ui-ring-border`, then the pale `--ui-ring` halo. The gap keeps the edge off a filled control; the edge reads against the ground. A transparent outline sits on the edge and shows in forced-colours mode.

A part never draws its own: the lint refuses a focus rule or an outline in `part.css`. The check holds the ring's edge at 3:1 or more on every Tab stop, in every skin and scheme.

## What would change it

A part where the ring cannot show around the box, such as a cell inside a grid; that part would get a second shape of the same ring, named in this record.

## Considered

- **UI SDK's own focus style.** Rejected: it is one 4px outline in `--ui-ring`. BarkUI's `--ui-ring` is a pale halo, so that outline alone would barely stand off the ground.
