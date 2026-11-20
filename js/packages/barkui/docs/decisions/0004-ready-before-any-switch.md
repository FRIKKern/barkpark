<!-- doc-tier: human | canonical-for: barkui-decision-ready-first | budget: 600tok -->
# 0004 Ready before any switch

Date: 2026-11-18 · Status: accepted

```
build parts ─► the showroom shows them whole ─► the owner says ready ─► apps move, a screen at a time
              (every light on)
```

## Context

The owner, on what matters before any app moves: "The most important for me to see before a switch is it being ready". An app that moves to half a kit carries two looks for as long as the rest takes.

## Decision

- **The step.** The owner looks at the first six parts in the showroom and confirms their look, which the rest then copy; and no app reads BarkUI until every part in the showroom has every light on ([QUALITY.md](../../QUALITY.md)) and the owner says the whole is ready.
- The showroom is built first and is the scoreboard.
- After the step, apps move one screen at a time, each measured before it moves.

## What would change it

An app that needs one finished part now, where waiting costs more than carrying two looks for a while. That is decided for that part and that app, and written here.

## Considered

- **Move each app as parts land.** Rejected: every app would show a mix of old and new parts for as long as the set is unfinished.
