<!-- doc-tier: human | canonical-for: barkui-decision-seam | budget: 600tok -->
# 0005 UI SDK sits behind a seam, at a pinned version

Date: 2026-11-18 · Status: accepted

```
app ──► @barkpark/barkui ──► @ui-sdk/web, @ui-sdk/core (one exact version)
        the only importer
```

## Context

When this was decided, UI SDK was a beta: the version pinned then was `0.1.0-beta.10`. A beta can change its names and behaviour between versions, and a change that lands in every app at once would break them all at once.

## Decision

- `package.json` pins `@ui-sdk/core` and `@ui-sdk/web` to one exact version, never a range.
- This package is the only place in Barkpark that imports UI SDK. Apps will import BarkUI, never UI SDK.
- A new UI SDK version is a change of its own: the check runs on it, and the showroom's lights go stale until it passes, because the UI SDK version is part of what every light rests on.

Planned, not built: a test that fails when an app file imports UI SDK directly.

## What would change it

UI SDK reaching a stable release with a promise of compatible minor versions; then a range may replace the exact pin.

## Considered

- **Apps use UI SDK directly.** Rejected: every upgrade would touch every app.
