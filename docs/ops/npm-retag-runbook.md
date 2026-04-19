# npm dist-tag Retag Runbook

> Operator runbook for the `retag.yml` workflow. Use this AFTER the PR introducing
> `.github/workflows/retag.yml` has been merged to `main`.

## Validation

Syntactic smoke test of `.github/workflows/retag.yml` performed on 2026-04-19:

| Tool       | Available? | Result |
|------------|------------|--------|
| `actionlint` | no       | not installed on worker host |
| `yamllint`   | no       | not installed on worker host |
| `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/retag.yml'))"` | yes | **PASS** — file parses as valid YAML |

Command used:

```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/retag.yml')); print('YAML PARSE: OK')"
# → YAML PARSE: OK
```

A deeper Actions-schema lint (`actionlint`) should be run in CI on the PR before
merge to catch expression-syntax issues that pure YAML parsing cannot detect.

## 1. Purpose

Use this runbook when an `@barkpark/*` npm package is on the wrong dist-tag and
local `npm dist-tag` commands return **HTTP 403** (only the CI `NPM_TOKEN` holds
publish/dist-tag scope on the `@barkpark` org). The triggering scenario is
**inverted dist-tag recovery** — a pre-release version landed on `latest`
instead of `preview`, or the equivalent for any other channel.

Reference incident: `release.yml` run **24627335562** (2026-04-19) published
`@barkpark/core@1.0.0-preview.1` and `@barkpark/nextjs@1.0.0-preview.1` to
`latest` instead of `preview`. See `docs/adr/0002-npm-dist-tag-publish.md` for
the wiring-gap analysis.

## 2. Prerequisites

- The PR introducing `.github/workflows/retag.yml` is merged to `main` (the
  workflow is only discoverable on the default branch for `workflow_dispatch`).
- The actor invoking the workflow has `Actions: write` (`workflow_dispatch`)
  permission on the repository.
- Repository secret **`NPM_TOKEN`** exists and has publish + dist-tag scope on
  the `@barkpark` npm org. The workflow fails fast with
  `::error title=Missing NPM_TOKEN::` if it is unset.
- Boss approval has been obtained for **each** dispatch run separately
  (see Approval Gate, §7).

## 3. Pre-flight verification

Before dispatching anything, capture the current dist-tag state from any
machine with public npm access (no auth required for `npm view`):

```
npm view @barkpark/core dist-tags
npm view @barkpark/nextjs dist-tags
```

**Expected inverted state at the time of this incident** (must match before
proceeding — if it does not, STOP and reassess):

```
@barkpark/core:   { latest: '1.0.0-preview.1', preview: '1.0.0-preview.0' }
@barkpark/nextjs: { latest: '1.0.0-preview.1', preview: '1.0.0-preview.0' }
```

If the state has already been remediated by another operator, do **not** run
this workflow — exit the runbook.

## 4. Run plan (exact sequence)

Two dispatches, **strictly sequential**. Wait for run 1 to finish green before
starting run 2. Each run requires a fresh Boss approval.

### Run 1 — `@barkpark/core`

GitHub UI path:

> **Actions → retag → Run workflow** → fill the form:
> - `package_name` = `@barkpark/core`
> - `version` = `1.0.0-preview.1`
> - `add_tag` = `preview`
> - `remove_tag` = `latest`

CLI equivalent:

```
gh workflow run retag.yml \
  -f package_name=@barkpark/core \
  -f version=1.0.0-preview.1 \
  -f add_tag=preview \
  -f remove_tag=latest
```

Watch the run: `gh run watch` (or Actions tab). Expected step outcomes:

- `Configure npm auth` — succeeds (NPM_TOKEN present).
- `Add dist-tag` — `::notice` line, `npm dist-tag add` succeeds.
- `Remove dist-tag (guarded)` — `remove_tag=latest` is **not** in the
  protected set (`preview`, `next`), so the step **executes** and removes
  `latest` from `@barkpark/core`.
- `Verify post-state` — prints the post-state for the package.

### Run 2 — `@barkpark/nextjs`

GitHub UI path: same as above with `package_name=@barkpark/nextjs`.

CLI equivalent:

```
gh workflow run retag.yml \
  -f package_name=@barkpark/nextjs \
  -f version=1.0.0-preview.1 \
  -f add_tag=preview \
  -f remove_tag=latest
```

## 5. Post-state verification

After both runs are green:

```
npm view @barkpark/core dist-tags
npm view @barkpark/nextjs dist-tags
```

**Expected post-state:**

```
@barkpark/core:   { preview: '1.0.0-preview.1' }
@barkpark/nextjs: { preview: '1.0.0-preview.1' }
```

### What `npm dist-tag rm` does to the `latest` tag

`npm dist-tag rm <pkg> latest` **deletes** the `latest` entry — it does NOT
reassign it to a different version. After Run 1+2:

- `latest` is **gone** from each package's dist-tag table.
- A bare `npm install @barkpark/core` (no `@version`, no `--tag`) resolves
  `latest`, finds it missing, and falls back to the highest stable semver
  that is **not** a pre-release. Because no stable `@barkpark/core` has been
  published yet (we are pre-1.0 GA), this resolution will **404**.
- This is the **intended interim state** per the incident response: it is
  better to fail-loud on `npm install @barkpark/core` than to silently serve
  a pre-release to consumers who asked for the stable channel. The 404
  persists until the first stable GA publish lands on `latest`.
- Consumers who want the pre-release continue to use
  `npm install @barkpark/core@preview` (or pin to the explicit
  `@1.0.0-preview.1` version) and are unaffected.

> **Note on ADR divergence:** ADR 0002 §Consequences (line 78) suggests
> *not* stripping `latest` mid-incident. This runbook follows the explicit
> incident-response decision to **clear** `latest` so consumers fail loud
> rather than silently install a pre-release. If the ADR posture is to be
> reasserted, run only `add_tag=preview` with `remove_tag=` (empty) — see
> §6 Rollback for the recovery path.

## 6. Rollback / abort procedure

### Run 1 succeeded, Run 2 failed (mid-incident split state)

State will be:

```
@barkpark/core:   { preview: '1.0.0-preview.1' }              ← fixed
@barkpark/nextjs: { latest: '1.0.0-preview.1', preview: '1.0.0-preview.0' }  ← still inverted
```

Recovery: re-run **only Run 2**, with the same inputs. The `Add dist-tag`
step is idempotent on npm; re-running is safe.

```
gh workflow run retag.yml \
  -f package_name=@barkpark/nextjs \
  -f version=1.0.0-preview.1 \
  -f add_tag=preview \
  -f remove_tag=latest
```

### Need to put `1.0.0-preview.1` back on `latest` (full undo)

If the decision is reversed and `1.0.0-preview.1` must be restored to
`latest` on a package, dispatch `retag.yml` with `add_tag=latest`:

```
gh workflow run retag.yml \
  -f package_name=@barkpark/core \
  -f version=1.0.0-preview.1 \
  -f add_tag=latest

gh workflow run retag.yml \
  -f package_name=@barkpark/nextjs \
  -f version=1.0.0-preview.1 \
  -f add_tag=latest
```

Leave `remove_tag` empty for the undo — we do **not** want to strip `preview`
on the way back. The workflow's protected-channel guard would skip it
anyway (`remove_tag=preview` is refused with a warning), but omitting it is
clearer.

### Workflow itself broken / dispatch fails

If the workflow run cannot start (token missing, workflow not on `main`,
permission error), do **not** improvise from a developer machine — local
`npm dist-tag` will 403. Fix the underlying gating (re-add NPM_TOKEN,
re-merge to main, grant Actions permission) and re-dispatch.

## 7. Approval gate

> **Boss must approve each `workflow_dispatch` run separately before it
> executes.** This is a P0 guardrail. Do not chain runs without re-approval.
> Two packages = two approvals. A re-run after a failure = a fresh approval.

Rationale: dist-tag changes are immediately visible to every npm consumer
of `@barkpark/*`. There is no staging tier between "dispatch" and "in
production." The approval cadence is the only human gate.
