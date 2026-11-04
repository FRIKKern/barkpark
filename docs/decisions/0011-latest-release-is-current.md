<!-- doc-tier: agent | canonical-for: cloud-status-behind-rule | budget: 800tok -->
# 0011 — A Cloud box on the latest release tag is current

**Status:** Accepted 2026-11-04. Supersedes the attention rule from ledger task
`dr-w24-s2-commit-distance-reaches-the-cli` (PR #10943, 2026-08-08).
**Deciders:** Barkpark owner (approval), agent (drafting)
**Related:** ledger task `task-7cafe3817d21eda6` ·
`internal/cli/cloud_status_cmd.go` (`attentionStatus`, `onLatestRelease`) ·
`cloud/priv/static/app.js` (`classifyBp`, `onLatestRelease`) ·
`cloud/lib/barkpark_cloud/github/latest_release.ex`

## Context

A Cloud box carries two freshness readings. `update_state` is the box's own
grade against the newest release tag. `commit_ancestry` and `commit_distance`
are the control plane's compare of the commit the box serves against `main`.

dr-w24-s2 made `bp cloud status` read both. A box with `commit_ancestry:
"behind"` became `behind` and went to the attention bucket, whatever its tag
grade said. At that time no release tag had been cut since 2026-07-08, so a box
on the newest tag could be 2,493 commits old and still grade itself `current`.
The console copied the rule in dr-w25.

Releases are now cut often. On 2026-11-04 gyl ran v0.2.39 at `e2942e055`, the
newest release, and read `behind, 17 commits` in attention. The only thing
behind was `main`, which no box is meant to follow between releases.

## Decision

A box whose served commit equals the commit of the latest `vA.B.C` release tag
is current. `bp cloud status` and the console classify it `ok` in the healthy
bucket, even when `commit_ancestry` is `behind`.

- Cloud reads the tags list every 3 minutes (`ReleaseWatchWorker`) and keeps
  the newest tag's commit sha. `GET /v1/barkparks` serves it on every row as
  `latest_release_commit`.
- The CLI and the console compare it with `git_commit`. Either sha may be
  abbreviated to 7 or more characters.
- A box that serves another commit and is behind main still reads `behind`.
- A box whose own `update_state` is `behind` still reads `behind`, whatever its
  commit.
- When `latest_release_commit` or `git_commit` is empty, the dr-w24-s2 rule
  applies unchanged. That covers an older control plane and the first 3 minutes
  after a control plane boot.
- The BEHIND column still prints the distance from `main` on every row. A
  healthy row on the latest release says `on the latest release 0.2.39; main is
  17 commits ahead of it` in DETAIL.

## Not changed

The commit-distance measurement, the `diverged` rung, the attention ladder and
the weekly digest's freshness counts are unchanged. The digest still counts a
box behind `main` as behind.
