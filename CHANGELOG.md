<!-- doc-tier: human | canonical-for: weekly-changelog | budget: 500tok -->
# Changelog

Barkpark publishes a project-wide changelog every Monday for the preceding ISO
week. [Read the weekly changelog](https://github.com/FRIKKern/barkpark/issues?q=is%3Aissue+label%3Aweekly-changelog).

Each entry covers user-facing `feat`, `fix`, `perf`, and `revert` commits merged
to `main` from Monday through Sunday, in UTC. Documentation, test, CI, refactor,
build, and maintenance commits are counted separately so the useful changes do
not disappear inside repository housekeeping.

The scheduled workflow is idempotent: rerunning a week edits the same closed,
`weekly-changelog`-labelled entry instead of creating a duplicate or adding
noise to the project's open work queue.

Package-specific histories remain beside their packages under
[`js/packages/`](js/packages/).
