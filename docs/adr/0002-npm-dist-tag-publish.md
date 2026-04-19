# ADR 0002 — npm dist-tag publish wiring

**Status:** Accepted
**Date:** 2026-04-19
**Deciders:** Barkpark core team
**Related:** P0 incident — release.yml run 24627335562; defects #16, #18; ADR 0001

## Context

On 2026-04-19, release.yml run **24627335562** published two pre-release artifacts
to the wrong npm dist-tag:

| Package            | preview         | latest                                 |
|--------------------|-----------------|----------------------------------------|
| `@barkpark/core`   | 1.0.0-preview.0 | **1.0.0-preview.1**  (should be preview) |
| `@barkpark/nextjs` | 1.0.0-preview.0 | **1.0.0-preview.1**  (should be preview) |

A pre-release version landed on `latest`, the channel that `npm install` resolves
by default. Local `npm dist-tag` retag attempts return HTTP 403 — only the CI
NPM_TOKEN holds publish/dist-tag scope on `@barkpark/*`. Any fix must therefore
run inside a GitHub Actions workflow.

### What the wiring actually does

`.github/workflows/release.yml` exposes a `dist_tag` `workflow_dispatch` input
(values: `preview | next | latest`, default `preview`) and computes
`steps.mode.outputs.dist_tag` from it. That value is then used **only** for log
lines (`::warning::` notice and `$GITHUB_STEP_SUMMARY`). It is **not** passed to
the publish CLI.

The "Publish (REAL — emits to npm)" step runs:

```
pnpm changeset publish
```

with no `--tag` flag. The inline comment is explicit about why:

> NOTE: no --tag here. Pre-mode (`.changeset/pre.json` `tag="preview"`)
> auto-applies the dist-tag; passing --tag explicitly fails with
> "Releasing under custom tag is not allowed in pre mode".

So the published dist-tag is governed entirely by `js/.changeset/pre.json` —
specifically its `"tag": "preview"` field — *whenever pre-mode is active on
the publishing commit*. If pre-mode is **not** active at publish time
(`pre.json` absent, or `changeset pre exit` already run, or the package not
covered by the active pre-mode set), `changeset publish` falls back to its
default behavior, which is to publish under `latest`. The `dist_tag` workflow
input has no path to override that fallback; it is purely informational.

This is the wiring gap that produced the incident: the operator selected
`dist_tag=preview` on the dispatch form and reasonably assumed that selection
governed the publish. It did not. The publish landed on whatever pre-mode (or
its absence) implied — `latest` in this case.

## Decision

1. **Immediate fix (this PR):** ship `.github/workflows/retag.yml` — a
   `workflow_dispatch`-only workflow that performs `npm dist-tag add` and a
   guarded `npm dist-tag rm` from CI, where NPM_TOKEN has the required scope
   rights. The remove step is hard-guarded against the protected channels
   `preview` and `next`: if either is supplied, the step is **skipped with a
   warning, not failed** — protected channels are how downstream installs
   subscribe to the pre-release stream, and silently yanking them would break
   every consumer tracking them.

2. **Do not modify `release.yml` in this PR.** The retag workflow is the
   surgical remediation; the release-wiring fix belongs in a separately
   reviewed change so the rollback story for this incident stays narrow.

## Consequences

- The inverted dist-tag state can be corrected by a single operator running
  `retag.yml` once per affected package: `add_tag=preview`,
  `version=1.0.0-preview.1`, `remove_tag=` (empty — `latest` will be moved by
  the `add` of the correct version when the next real release lands; we do
  not strip `latest` mid-incident because that would break `npm install`
  resolution for users who already pinned to it).
- The `dist_tag` input on `release.yml` continues to be a footgun until
  follow-up work lands. Until then, operators must understand that the
  effective publish tag is determined by `js/.changeset/pre.json`, not the
  workflow input.
- `retag.yml` is a general-purpose remediation tool and will outlive this
  incident — it is the right escape hatch any time npm dist-tag state and
  intent diverge.

## Recommended follow-up (separate PR — NOT in scope here)

Wire the `dist_tag` input through to the publish CLI so the dispatch form
selection actually matters:

- **When pre-mode is active** (`js/.changeset/pre.json` exists): keep the
  current behavior — pre.json's `tag` is canonical, refuse to override, and
  fail loudly if `dist_tag` disagrees with `pre.json.tag` so the mismatch is
  caught at dispatch time rather than after publish.
- **When pre-mode is not active**: pass `--tag "${dist_tag}"` to
  `pnpm changeset publish` (or, equivalently, `pnpm publish -r --tag ...`
  for the workspace), and validate the input is one of the documented
  channels.
- Add an explicit assertion step that reads `pre.json` and reconciles it
  against the input *before* the publish step runs — so the operator gets a
  clear error in the workflow log, not a wrong-channel publish in npm.
- Consider exiting pre-mode (`changeset pre exit`) before publishing the GA
  `1.0.0` so the post-pre-exit publish path is exercised before it becomes
  load-bearing.
