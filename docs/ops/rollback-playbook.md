# Rollback playbook — npm + git

**Status:** Runbook. On-call-executed during post-GA incident window.
**Owner:** Subtaskmaster (primary), Boss (approver for unpublish).
**Scope covered:** npm registry rollbacks, git revert flow for the `@barkpark/*` scope + unscoped `create-barkpark-app`. Ties into §8.11 on-call from `.doey/plans/masterplan-phase8-20260418-190403-refined.v2.md`.

**Scope NOT covered here:** Phoenix / Caddy / Vercel DNS rollback (see `caddy-api-tls.md` and `vercel-dns-connect.md`). Infra and SDK rollbacks are deliberately separate runbooks — they have different blast radii and different approvers.

---

## Decision tree — which mechanism for which failure

This is the single most important section. Read it first, act only after.

| Symptom | Window since publish | Severity | Mechanism | Time-to-fix |
|---|---|---|---|---|
| Type-only regression (`.d.mts` breaks `tsc` but runtime works) | any | Medium | **`npm deprecate` + patch** | ~30 min (land patch, CI publishes `.N+1`) |
| Runtime regression — install succeeds, app breaks | any | High | **`npm deprecate` + patch** (if fixable same-day) OR **`npm unpublish`** (if patch > 4h away AND within 72h window) | 30 min – 4h |
| Install-time failure (`pnpm install` errors on the bad version) | <72h | High | **`npm unpublish` + patch** | 1–2h |
| Install-time failure | ≥72h | High | **Deprecate + patch** (unpublish blocked by npm policy) | 30 min – 4h |
| Security issue (credential leak, RCE, auth bypass) | any | **Critical** | **`npm unpublish` immediately** (within 72h if allowed) + patched major + public CVE | 2–6h |
| Accidentally published a debug/scratch version | <72h | Low | **`npm unpublish`** | 5 min |
| Wrong dist-tag moved (`@latest` pointing at a broken build) | any | High | **`npm dist-tag rm` + `npm dist-tag add`** (no unpublish needed) | 2 min |
| Wrong package published entirely (tarball contents wrong) | <72h | High | **`npm unpublish`** and re-publish with same version *after* the re-publish-blocker window | see §Re-publish blocker below |

**Default to `npm deprecate`. Reach for `npm unpublish` only when install is broken for users who would otherwise get the bad version.**

### Why "deprecate first, unpublish last"

`npm deprecate` is:
- Reversible (deprecate with empty string to un-deprecate).
- Non-destructive (the version stays installable; users just see a warning).
- Zero-impact on anyone already pinned to that version — their installs still work.
- Visible at install time — enough friction that most users upgrade.

`npm unpublish` is:
- **Irreversible** past the first re-publish attempt (see §Re-publish blocker).
- Breaks every `package-lock.json` / `pnpm-lock.yaml` pinned to that version.
- Allowed only within **72h** of publish, per npm [unpublish policy](https://docs.npmjs.com/policies/unpublish). Beyond 72h you must open a registry support ticket and argue your case.
- Scoped packages (`@barkpark/*`) and unscoped (`create-barkpark-app`) follow the same rule.

---

## Mechanism A — `npm deprecate` (soft recall)

### When to use

- Buggy but installable version.
- You will ship a patch within the hour.
- You want `npm WARN deprecated` printed on every `npm install` / `pnpm install` referencing the bad version.

### Usage

```sh
# Mandatory: use a production-scoped token. 2FA on owner account must be automation-compatible.
export NPM_TOKEN=<...>

npm deprecate @barkpark/core@1.0.0 "broken TypeScript types — upgrade to 1.0.1 (see https://github.com/frikk/barkpark/releases/tag/v1.0.1)"

# Un-deprecate (rollback of the deprecation itself — rare, used if the replacement turned out worse):
npm deprecate @barkpark/core@1.0.0 ""

# Deprecate a range:
npm deprecate "@barkpark/core@<1.0.1" "upgrade to 1.0.1 — see release notes"
```

### Verification

```sh
npm view @barkpark/core@1.0.0 deprecated
# Expected: prints the deprecation message string

npm view @barkpark/core versions --json | tail -5
# Expected: 1.0.0 still present in the list (not removed)

# Simulated end-user experience:
mkdir /tmp/rollback-check && cd /tmp/rollback-check && npm init -y >/dev/null
npm install @barkpark/core@1.0.0 2>&1 | grep -i deprecated
# Expected: WARN about the deprecated version
```

### When it's insufficient

- When the version is completely uninstallable (e.g. `postinstall` script crashes, malformed tarball). Users cannot even see the deprecation warning because the install fails first. Escalate to Mechanism B.

---

## Mechanism B — `npm unpublish` (hard recall)

### When to use

Only these cases:
1. Install is completely broken for new installs.
2. Security issue where leaving the artifact published is itself the hazard (leaked credential, backdoor).
3. Accidental publish of wrong-content or debug version, caught within 72h.

### Policy constraints

- **72h window from publish.** `npm unpublish @barkpark/core@1.0.0 --force` after 72h returns `E403`. Support ticket required.
- **Unpublishing a version that is depended on by another public package in the last 72h is blocked.** If any consumer on the public registry has already added us to their `package.json`, the unpublish may fail even within the window.
- **2FA + token permissions.** Your token must have publish + unpublish scope; automation tokens created after npm's 2024 policy change default to publish-only.

### Usage

```sh
# Single version unpublish:
npm unpublish @barkpark/core@1.0.0 --force
# --force is required. Without it npm refuses for scoped packages.

# Unpublish the entire package (DO NOT do this post-GA — only for scratch publishes):
# npm unpublish @barkpark/core --force

# Unscoped package (e.g. create-barkpark-app) — same syntax:
npm unpublish create-barkpark-app@1.0.0 --force
```

### Verification

```sh
npm view @barkpark/core@1.0.0 version
# Expected: HTTP 404 — "no such package available"

npm view @barkpark/core versions --json
# Expected: the unpublished version is GONE from the array

# Confirm dist-tags do not still point at the dead version:
npm view @barkpark/core dist-tags --json
# If any tag points at 1.0.0, reassign it BEFORE or IMMEDIATELY AFTER unpublish:
npm dist-tag rm @barkpark/core latest
npm dist-tag add @barkpark/core@0.9.5 latest  # or the last known good
```

### Re-publish blocker (critical)

After `npm unpublish @barkpark/core@1.0.0`, **you cannot publish a new artifact at `1.0.0` for 24h**. The registry reserves the name to prevent supply-chain attacks via version replay.

Practical consequence: if you unpublish 1.0.0, publish 1.0.1 as the patched version — **never** try to re-use 1.0.0. This is why `npm deprecate` is the default; it doesn't consume a version number.

### Downstream impact

- Every user with `@barkpark/core@1.0.0` in their lockfile will get an install failure next `npm ci`.
- This will show up on GitHub Issues across downstream projects within hours. Pre-write a pinned issue comment: "Yes we unpublished; upgrade to 1.0.1 with `npm install @barkpark/core@latest`."
- CI systems that cache npm metadata may keep serving the old manifest for up to 1h. Expect a long tail.

---

## Mechanism C — `npm dist-tag` rollback (reassign `@latest`)

### When to use

The artifact at version N is fine for people pinned to `@N`, but `@latest` should not point to it. Common cause: wrong version promoted to `@latest` via `promote-latest.yml` or `npm dist-tag add`.

### Usage

```sh
# Show current tags:
npm view @barkpark/core dist-tags --json
# { "latest": "1.0.0", "next": "1.0.0-rc.1", "preview": "1.0.0-preview.12" }

# Move @latest back to the last good version:
npm dist-tag add @barkpark/core@0.9.5 latest

# Verify:
npm view @barkpark/core dist-tags --json
# { "latest": "0.9.5", ... }

# Users installing with no tag (`npm install @barkpark/core`) will now resolve to 0.9.5.
# The bad 1.0.0 is still installable for anyone who explicitly asks for it.
```

Dist-tag rollback is instant, non-destructive, and does not burn the version number. Prefer this over unpublish when the bug is "wrong version got promoted."

---

## Mechanism D — git revert (fix the source)

Every npm rollback is a stopgap. The permanent fix is a git revert that ships as a new patch version.

### Usage

```sh
cd /path/to/barkpark
git checkout main && git pull

# Identify the bad commit:
git log --oneline | head -20

# Revert:
git revert <sha-of-bad-commit>
# Editor opens with a default revert message. Edit if needed:
#   revert: @barkpark/core broken types in 1.0.0 (#1234)
#
#   Breaks `tsc --noEmit` for consumers. Shipping 1.0.1 to restore types.
#
#   This reverts commit <sha>.
# Save and exit.

# Add a changeset:
pnpm changeset
# Select @barkpark/core → patch → write a user-facing line.

git push origin main
# CI runs release.yml, publishes 1.0.1 to @latest (or the appropriate dist-tag
# for the current release phase).
```

### If revert creates merge conflicts

- Conflicts mean subsequent commits built on the bad one.
- Abort (`git revert --abort`), assess what downstream work depends on the reverted piece, and either:
  - Revert the follow-ups too (clean history), or
  - Forward-fix in a new commit (faster if follow-ups are independent).
- **Never** force-push to main to paper over a revert. This breaks lockfiles and confuses consumers.

### When to NOT revert

- The bad commit is part of a merged PR touching unrelated files. Don't revert the whole PR; cherry-pick or manually undo just the broken piece in a new commit.
- The commit is already past the GA cutoff (npm already has the bad version). Revert is still correct — you ship 1.0.1 — but the npm-side rollback (deprecate or unpublish) happens in parallel, not after.

---

## Incident checklist (on-call playbook)

Tied to §8.11 on-call in the v2 masterplan. Follow in order; don't skip.

### 1. Detect (target: <30 min from publish)

- Signals: GitHub Issues spike on `frikk/barkpark`, Twitter mentions tagged `@barkpark`, HN comments on the launch thread, Uptime Kuma alert, beta-channel Slack/Discord message, CI failure on a downstream staging project.
- First on-call action: acknowledge in `#incidents` (or Boss DM if pre-launch).

### 2. Assess (target: <15 min)

- Reproduce. Scratch dir, `npm init -y`, `npm install @barkpark/<pkg>@<bad-version>`, exercise the broken path.
- Classify: type-only / runtime / install-time / security / dist-tag misroute.
- Estimate blast radius: how many users have installed since publish (`npm view @barkpark/<pkg> downloads` is slow to update; use the launch thread velocity as a proxy).
- Consult the decision tree at top. **Write the decision down** in the incident ticket before acting — it forces you to justify.

### 3. Decide mechanism

Use the decision-tree table. If severity is Critical, Boss is the approver (DM / phone). Otherwise Subtaskmaster can proceed.

### 4. Execute

- Follow the relevant mechanism (A, B, C, or D). Most incidents combine two: (A deprecate + D revert) OR (C dist-tag + D revert) OR (B unpublish + D revert). Only security incidents usually require B.
- Every executed command goes into the incident ticket verbatim with timestamps.

### 5. Verify

- Run the verification snippet for whichever mechanism was used (see each section above).
- Additional smoke-test: `npx create-barkpark-app@latest blog /tmp/rollback-smoke-$(date +%s)` — confirm the scaffold still works. This is the fresh-install invariant.
- Verify from a **clean** npm cache: `npm cache clean --force` before re-testing. Registry metadata is cached aggressively.

### 6. Communicate

- Update the GitHub Release notes for the bad version with a "⚠️ rolled back" banner and a link to the patch.
- Reply on the HN launch thread if the incident is during launch week.
- Send a beta-channel note even if beta users weren't affected — transparency builds trust.

### 7. Postmortem (within 48h)

- Write `.doey/plans/postmortem-<incident>-<date>.md` with: timeline, detection gap, decision rationale, fix, prevention (test we should have had, CI gate we should add).
- File preventive tickets in the 1.0.1 backlog.
- If the same class of bug has caused two incidents, the prevention task is upgraded to P0 for 1.0.1.

---

## Sample timeline — hypothetical `@barkpark/core@1.0.0` broken TypeScript types

Timestamps are fictional but proportions are realistic for a well-drilled response.

| Time | Event | Who |
|---|---|---|
| 00:00 | `promote-latest.yml` publishes `@barkpark/core@1.0.0` to `@latest` | CI |
| 00:05 | HN "Show HN" thread goes live | Boss |
| 00:47 | GitHub issue opened: "1.0.0 breaks `tsc` for consumers — exports missing `PortableTextProps` type" | External user |
| 00:49 | On-call (Subtaskmaster) sees issue, starts clock | SM |
| 00:52 | Reproduces locally: `pnpm install @barkpark/core@1.0.0 && tsc --noEmit` errors | SM |
| 00:55 | Classification: type-only regression. Decision: Mechanism A (deprecate) + D (revert + patch). **No unpublish** — 1.0.0 still installs and runs. | SM |
| 00:58 | `npm deprecate @barkpark/core@1.0.0 "broken TypeScript types — upgrade to 1.0.1 when available (ETA ~30min)"` | SM |
| 01:02 | Replies to GitHub issue with ETA; pins the issue | SM |
| 01:05 | Replies on HN thread: acknowledging, patch in ~30 min | Boss |
| 01:12 | `git revert <sha>` on main, changeset added | SM |
| 01:15 | PR opened, auto-merges (green CI) | SM |
| 01:28 | CI publishes `@barkpark/core@1.0.1` to `@latest` | CI |
| 01:30 | Verifies: `npm view @barkpark/core@latest version` → `1.0.1`. Fresh install + `tsc` works. | SM |
| 01:32 | Updates GitHub issue: closed with link to 1.0.1 | SM |
| 01:33 | Replies on HN thread: "patched — `npm install @barkpark/core@latest`" | Boss |
| 01:35 | Updates `npm deprecate` message on 1.0.0 to point to the now-released 1.0.1: `npm deprecate @barkpark/core@1.0.0 "broken types — upgrade to 1.0.1"` | SM |
| 02:00 | Next HN check-in: no new complaints. Incident closes. | SM |
| 24:00 | 48h later: postmortem written. Prevention: add `tsc --noEmit` on a downstream scratch project to `release.yml` pre-publish gate. | SM |

Total blast radius: ~45 min from publish to patch availability. Most users installing between 00:00 and 01:28 hit the issue once, got a deprecation warning, upgraded on their next `npm install`.

---

## Sample timeline — hypothetical security issue (leaked HMAC secret in `@barkpark/nextjs@1.0.2`)

| Time | Event | Who |
|---|---|---|
| T+0 | Dependabot alert fires: a committed secret was bundled into `@barkpark/nextjs@1.0.2`'s tarball | Automation |
| T+5m | On-call wakes Boss — this is Critical and requires Boss sign-off on unpublish | SM → Boss |
| T+15m | Confirmed: `npm pack @barkpark/nextjs@1.0.2` tarball contains `.env` with live `BARKPARK_WEBHOOK_SECRET` | SM |
| T+20m | **`npm unpublish @barkpark/nextjs@1.0.2 --force`** (within 72h window, approved by Boss) | SM |
| T+22m | Rotate the leaked secret: Boss regenerates webhook secret on production Phoenix; updates `BARKPARK_WEBHOOK_SECRET` on Vercel; sets old value as `BARKPARK_WEBHOOK_PREVIOUS_SECRET` for dual-verify window | Boss |
| T+30m | `git revert` the bad commit; changeset adds `@barkpark/nextjs` patch bump → 1.0.3; extra changeset note documents CVE ID placeholder | SM |
| T+45m | CI publishes `@barkpark/nextjs@1.0.3`. Pre-publish gate (added post-Incident-1) scans tarball for common secret patterns before uploading — greenlit. | CI |
| T+1h | Public GitHub Security Advisory drafted + published; CVE requested via GitHub's CNA | Boss |
| T+2h | HN / Twitter / beta-channel comms: rolled back, rotated, upgrade path, no confirmed exploitation | Boss |
| T+24h | Postmortem draft. Preventions: (i) tarball secret-scan on publish, (ii) `.npmignore` audit, (iii) require secrets-dry-run on every release PR. | SM |

The unpublish here is non-negotiable. Even if downstream users get install failures, leaving a live-secret tarball on the registry is a larger harm.

---

## Known pitfalls

- **Dist-tag leftovers after unpublish.** If you unpublish the version `@latest` pointed at, `npm view` still lists `latest` as the dead version until you move the tag. Always reassign dist-tags BEFORE or immediately after unpublish.
- **Re-publish-blocker catches people by surprise.** If you unpublish `1.0.0` at 09:00 and try to publish a "fixed" `1.0.0` at 09:10, npm returns E403. Solution is always: publish `1.0.1`, not a "re-run" of `1.0.0`.
- **`npm deprecate` does NOT update lockfiles.** Users with `1.0.0` in their lockfile keep getting `1.0.0` until they explicitly `npm update` or regenerate the lockfile. Communicate via release notes + the deprecation warning.
- **Scoped vs unscoped unpublish error messages differ.** Scoped (`@barkpark/*`) works with `--force`. Unscoped (`create-barkpark-app`) sometimes requires the package author account to confirm; 2FA device must be handy.
- **CI cached node_modules can re-publish a ghost version.** If your release workflow caches `.pnpm-store` and the cache somehow retains an unpublished tarball, it can't push it back — but some setups checksum-mismatch and fail the next publish. Clear CI cache after any unpublish.
- **GitHub Packages mirror.** If we ever mirror to GHP, unpublishing on npm doesn't propagate. Handle separately. (Currently we do not mirror — 1.0 publishes only to npmjs.)
- **Signed tags don't auto-revert.** If you `git revert` a commit, the `v1.0.0` signed tag still points at the bad SHA. Delete and re-create the tag if necessary: `git tag -d v1.0.0 && git push origin :refs/tags/v1.0.0`, then re-tag after the revert lands. Rare; mostly only matters if the tag is load-bearing (GitHub Release artifact).
- **Concurrent publishes.** If two workers both `changeset publish` simultaneously, npm rejects the second with E409. Not a rollback scenario per se, but if it happens during an incident, wait 30s and retry — don't try to unpublish the half-failed one.

## Drill cadence

Per slice 8.0 preflight: this playbook must be **drilled at least once** before GA. The drill scenario is:

1. Publish `@barkpark/core@0.0.0-rollback-drill-<timestamp>` to `@preview` dist-tag.
2. Deprecate it within 5 minutes.
3. Unpublish it within 60 minutes (inside 72h window).
4. Record timestamps and observed behavior in `.doey/plans/rollback-drill-<date>.md`.

After GA, annual re-drill. Sooner if on-call personnel change.
