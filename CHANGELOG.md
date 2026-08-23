<!-- doc-tier: human | canonical-for: weekly-changelog | budget: 500tok -->
# Changelog

Barkpark publishes a project-wide changelog every Monday for the preceding ISO
week. [Read the weekly changelog on GitHub Releases](https://github.com/FRIKKern/barkpark/releases?q=weekly-).

Each entry covers user-facing `feat`, `fix`, `perf`, and `revert` commits merged
to `main` from Monday through Sunday, in UTC. Documentation, test, CI, refactor,
build, and maintenance commits are counted separately so the useful changes do
not disappear inside repository housekeeping.

The scheduled workflow is idempotent: rerunning a week edits the existing
`weekly-YYYY-MM-DD` release. Weekly entries are prereleases so they never replace
the stable `bp` CLI release consumed by installers and `bp upgrade`.

Package-specific histories remain beside their packages under
[`js/packages/`](js/packages/).
