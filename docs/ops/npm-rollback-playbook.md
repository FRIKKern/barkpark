<!-- doc-tier: agent | canonical-for: npm-rollback | budget: 2200tok -->
# Rollback playbook — npm + git

**Scope:** npm rollbacks + git revert for `@barkpark/*` and unscoped
`create-barkpark-app`. **NOT covered:** Phoenix/Caddy/DNS rollback
(`PROD_OPS.md`, `vercel-dns-connect.md`) — deliberately separate runbooks
(different blast radii + approvers). Owner: Subtaskmaster; Boss approves
unpublish + dist-tag runs.

## Decision tree

| Symptom | Window | Severity | Mechanism |
|---|---|---|---|
| Type-only regression (`.d.mts` breaks `tsc`, runtime works) | any | Medium | **deprecate + patch** |
| Runtime regression — install works, app breaks | any | High | **deprecate + patch**; **unpublish** only if patch > 4h away AND <72h |
| Install-time failure | <72h | High | **unpublish + patch** |
| Install-time failure | ≥72h | High | **deprecate + patch** (unpublish blocked by policy) |
| Security (credential leak, RCE, auth bypass) | any | **Critical** | **unpublish immediately** (within 72h) + patched release + public CVE |
| Accidental debug/scratch publish | <72h | Low | **unpublish** |
| Wrong dist-tag (`@latest` at a broken build) | any | High | **dist-tag reassign** (no unpublish) |
| Wrong tarball contents entirely | <72h | High | **unpublish**, re-publish at the NEXT version |

**Default to `npm deprecate`. Reach for `npm unpublish` only when install is
broken for users who would otherwise get the bad version.** Deprecate is
reversible (deprecate with `""` to undo), non-destructive (version stays
installable; pinned users unaffected), visible at install time. Unpublish is
**irreversible** past the first re-publish attempt, breaks every lockfile pinned
to that version, and is allowed only within **72h** of publish
([npm unpublish policy](https://docs.npmjs.com/policies/unpublish)); beyond 72h
requires a registry support ticket. Same rule for scoped + unscoped.

## Mechanism A — `npm deprecate` (soft recall)

For buggy-but-installable versions with a patch landing soon.

```sh
npm deprecate @barkpark/core@1.0.0 "broken types — upgrade to 1.0.1"
```

Un-deprecate with message `""`; ranges work (`"@barkpark/core@<1.0.1"`).
Verify: `npm view @barkpark/core@1.0.0 deprecated` prints the message; version
still listed; a scratch install prints `npm WARN deprecated`. If the version is
completely uninstallable the warning is never seen — escalate to B.

### Deprecation via CI (`deprecate.yml`)

Local `npm deprecate` 403s for the same reason local `npm dist-tag` does — only
the CI `NPM_TOKEN` holds `@barkpark` scope rights. Dispatch
`.github/workflows/deprecate.yml` (`workflow_dispatch`: `package_name`,
`version_range`, `message`; an empty `message` un-deprecates). It fails closed on
a missing token, **measures** the token with `npm whoami` before any write
(`npm publish --dry-run` and `npm access list` both exit 0 on a bogus token —
neither is evidence), hard-fails a `version_range` matching **zero** published
versions (a silent no-op would otherwise exit green), and re-reads every matched
version afterwards to assert the message landed.

**Standing disposition — `@barkpark/react` `1.0.0-preview.0` + `1.0.0-preview.1`:**
both published previews contain the reference-error collapse repaired by #9601;
neither is free of it (byte-identical `src/Reference.tsx`), so **deprecate both**
pointing at `1.0.0-preview.2` — `preview.2` is an unused version number, and npm
never lets a used one be re-published. Execute after that version actually
publishes (cutting it is a separate row). The disposition is **conditional on
`NPM_TOKEN` still being live**: that is unproven, and this workflow's `npm whoami`
step is what proves it. Unpublish stays off the table (past the 72h window).
Public dependents are **unmeasured** — npm's `depends:` search qualifier is
silently ignored, so no "no dependents" claim is available to lean on.

## Mechanism B — `npm unpublish` (hard recall)

Only for: completely broken installs; security hazards where the artifact itself
is the harm; accidental wrong-content publishes caught <72h.

Constraints: **72h window** (`E403` after); blocked if another public package
depended on the version in the last 72h; token needs publish + unpublish scope
(post-2024 automation tokens default publish-only; 2FA device handy — unscoped
packages may require account confirmation).

```sh
npm unpublish @barkpark/core@1.0.0 --force # --force required; unscoped same syntax
```

Verify: `npm view @barkpark/core@1.0.0 version` → 404; version gone from
`versions --json`; check `dist-tags --json` and reassign any tag pointing at the
dead version BEFORE or IMMEDIATELY AFTER unpublish.

**Re-publish blocker (critical):** after unpublishing `1.0.0` you **cannot
publish a new artifact at `1.0.0` for 24h** (registry anti-replay). Always ship
the fix as `1.0.1` — never re-use the number. This is why deprecate is the
default: it doesn't burn a version.

**Downstream impact:** every lockfile pinned to the version fails next `npm ci`;
pre-write a pinned GitHub issue comment with the upgrade line; CI metadata
caches can serve the old manifest for up to 1h. Clear CI caches after any
unpublish.

## Mechanism C — `npm dist-tag` rollback (reassign `@latest`)

When the artifact is fine but `@latest` points at the wrong version.

```sh
npm dist-tag add @barkpark/core@0.9.5 latest # move back to last good
```

Instant, non-destructive, burns no version number. Prefer over unpublish when
the bug is "wrong version got promoted."

### Dist-tag changes via CI (`retag.yml`) — absorbed retag runbook

Local `npm dist-tag` returns **HTTP 403** — only the CI `NPM_TOKEN` holds
publish/dist-tag scope on the `@barkpark` org. Dispatch through
`.github/workflows/retag.yml` (`workflow_dispatch`, no branch restriction — can
be dispatched from any branch that carries the file). It fails closed **twice**:
`::error title=Missing NPM_TOKEN::` if the secret is unset, and
`::error title=NPM_TOKEN rejected by the registry::` from the `npm whoami`
preflight when the secret *is* set but the token is expired or revoked — that
second one means rotate `NPM_TOKEN`, not re-dispatch. The
protected-channel guard **skips** the removal step with a `::warning::`
annotation (exit 0 — the workflow still succeeds) when `remove_tag` is
`preview` or `next`. Reference incident: `release.yml` run **24627335562**
(2026-04-19) published two `1.0.0-preview.1` packages to `latest` instead of
`preview` — see `docs/decisions/0002-npm-dist-tag.md`.

> **Approval gate (P0 guardrail) — convention only, NOT enforced by CI:**
> **Boss must approve each `workflow_dispatch` run separately before it
> executes.** Two packages = two approvals; a re-run after a failure = a fresh
> approval. `retag.yml` carries no `environment:` protection rule, so a dispatch
> runs immediately and no approval prompt will ever appear — get the approval in
> `#incidents` *before* you press Run. Dist-tag changes are immediately live for
> every npm consumer — the approval cadence is the only human gate.

**Split-state rollback (run 1 succeeded, run 2 failed):** re-run **only run 2**
with the same inputs — the `Add dist-tag` step is idempotent on npm. Full undo
(restore the version to `latest`): dispatch with `add_tag=latest` and
`remove_tag` **empty** — never strip `preview` on the way back (the guard
skips it with a warning anyway). If the workflow refuses (secret unset, or
`npm whoami` rejected the token), fix that first — rotate the token if the
registry rejected it — then re-dispatch. Never improvise locally (403s).

**404-is-intentional:** `npm dist-tag rm <pkg> latest` **deletes** the `latest`
entry — it does not reassign. With no stable version published, a bare
`npm install @barkpark/core` then **404s**. This is the intended interim state:
fail-loud beats silently serving a pre-release on the stable channel. The 404
persists until the first stable GA publish; `@preview` installs and explicit
pins are unaffected.

> **ADR divergence note:** ADR 0002 §Consequences suggests *not* stripping
> `latest` mid-incident. The incident response deliberately **cleared** `latest`
> (fail-loud). To reassert the ADR posture: dispatch `add_tag=preview`,
> `remove_tag=` empty.

## Mechanism D — git revert (fix the source)

Every npm rollback is a stopgap; the permanent fix is a revert shipped as a new
patch: `git revert <bad-sha>` on main → `cd js && pnpm changeset` (patch) →
push → CI publishes. (`js/` is its own pnpm workspace — the `changeset` script
and `.changeset/` live only there; at the repo root the command is not defined.) If the revert conflicts, abort and either revert the follow-ups too
or forward-fix. **Never** force-push main to paper over a revert. Don't revert a
whole multi-concern PR — undo just the broken piece. npm-side rollback runs in
parallel, not after.

## Incident checklist

1. **Detect** (<30 min): GitHub Issues / Uptime Kuma / beta channel; acknowledge in `#incidents`.
2. **Assess** (<15 min): reproduce in a scratch dir; classify (type-only / runtime / install-time / security / dist-tag); estimate blast radius.
3. **Decide:** use the decision tree; **write the decision down** in the incident ticket before acting. Critical ⇒ Boss approves.
4. **Execute:** most incidents combine two mechanisms (A+D, C+D, or B+D). Every command goes in the ticket verbatim with timestamps.
5. **Verify:** mechanism checks above + fresh-install invariant: `npx create-barkpark-app@latest /tmp/rollback-smoke-$(date +%s) --template blog-starter --yes`. The CLI takes **one** positional (the target directory) — a second one is silently ignored, so the old two-argument form scaffolded into `./blog` instead; `blog` is not a template name (`website-starter` | `blog-starter`), and without `--yes` it blocks on interactive prompts. Re-test from a clean cache (`npm cache clean --force`).
6. **Communicate:** "rolled back" banner on the GitHub Release; reply where users reported it.
7. **Postmortem (48h):** record the incident as a task — file it with `bp task create` — the contract-correct front door: it injects the task schema's two required fields, `kind:"task"` and `lifecycle_status:"open"`. `create` is a CLI built-in, so it is absent from `bp task --help` and from the `task` noun of `bp capabilities` (13 read/lifecycle/progress verbs: `ls ready prime events get claim close release stamp next move stage pulse`) — `bp task create --help` is its contract. **Fallback, no `bp` on hand:** a `type:"task"` document via `POST /v1/data/mutate/production` — still the only route, since the server has no bare `POST /v1/tasks` create verb — but the payload must carry `kind` AND `lifecycle_status` itself; omitting them 422s `validation_failed`, which is exactly what the `bp` verb exists to prevent. Capture timeline, detection gap, decision rationale, fix, prevention. Long-form: attach a Bulldocs paper via `POST /v1/tasks/<task_id>/papers`. Never write to `.doey/plans/` (retired). File preventive tickets; a same-class second incident upgrades prevention to P0.

## Known pitfalls

- **`npm deprecate` does NOT update lockfiles** — pinned users keep the bad version until they update; communicate via release notes.
- **GitHub Packages mirror** — we don't mirror; if we ever do, unpublish doesn't propagate.
- **Signed tags don't auto-revert** — delete + re-create the tag after the revert lands, if the tag is load-bearing.
- **Concurrent `changeset publish`** → E409; wait 30s and retry — don't unpublish the half-failed one.

## Drill cadence

Drill **at least once before GA**; annually after, sooner on on-call change:

1. Publish `@barkpark/core@0.0.0-rollback-drill-<timestamp>` to `@preview`.
2. Deprecate within 5 min.
3. Unpublish within 60 min (inside 72h window).
4. Record the drill as a task (same task-system mechanics as the postmortem step): timestamps for published/deprecated/unpublished, observed deviations, labels `["rollback-drill", "ops"]`.
