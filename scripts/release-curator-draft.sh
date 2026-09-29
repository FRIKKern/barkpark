#!/usr/bin/env bash
# release-curator-draft.sh — the DRAFTING half of the release curator, as a
# script CI can run unattended.
#
# THE RULING THIS IMPLEMENTS (orchestrator, 2026-09-13T08:10Z, recorded verbatim):
#
#   > OPTION A — a scheduled release-curator run that DRAFTS only; a human
#   > blesses and tags. Never an autonomous tag on green main.
#
# So: this script reads `scripts/release-scan.sh`, decides whether there is a
# candidate worth proposing, and opens (or refreshes) ONE **draft** GitHub
# Release for it. It NEVER creates a git tag, NEVER publishes a release, and
# NEVER writes to main. The bless — clicking Publish, or cutting the annotated
# tag by hand — stays a human act. `.claude/workflows/release-curator.md`
# describes the agent-driven version of the same loop and its `autonomous`
# mode; THIS script implements propose mode ONLY and has no other mode.
#
# WHY A SCRIPT AND NOT A WORKFLOW STEP BODY. The workflow
# (.github/workflows/release-curator-draft.yml) calls this file and nothing
# else, so `scripts/release-curator-draft.test.sh` drives the SAME code CI
# runs. A `run:` block inlined in YAML is untestable by construction, and a
# stub that returns the finished string would prove nothing about the argv the
# real run builds.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT A DRAFT RELEASE DOES TO REFS — the invariant, and why it is ASSERTED
# rather than assumed.
#
# `gh release create --help` says, of the TAG argument: "If a matching git tag
# does not yet exist, one will automatically get created from the latest state
# of the default branch." That sentence describes a PUBLISHED release. GitHub's
# REST contract for `POST /repos/{owner}/{repo}/releases` creates the tag when
# the release is published, and a `draft: true` release is by definition not
# published — gh's own help says as much two paragraphs later, under
# immutability: "Draft releases can be modified or deleted, and the associated
# git tags can be modified or deleted as well."
#
# That is DOCUMENTATION, not a measurement, and this script does not run on
# documentation. After every create/edit it asks the remote directly:
#
#     git ls-remote --tags origin "refs/tags/<tag>"
#
# Empty output = no tag exists = the invariant held. NON-EMPTY output is a
# FATAL (exit 4): a tag appeared, which is the one thing the ruling forbids,
# and the run says so loudly instead of reporting a successful draft. If a
# future gh/GitHub ever did create the tag on a draft, this line is what finds
# out — on the first run, not after a surprise release ships to the fleet.
# ─────────────────────────────────────────────────────────────────────────────
#
# EXIT VOCABULARY. A JUDGMENT never reds the job; only a fact about the
# machine does (the same rule .github/workflows/seal-reading.yml states).
#
#   0  a draft was created, a draft was refreshed, or there is honestly
#      NOTHING TO DRAFT (no commits, red/pending CI, no prior tag, already
#      published). Every one of these prints a HOLDING: or DRAFTED: line.
#   2  CANNOT READ — release-scan.sh is missing, refused, emitted something
#      that is not a JSON object, or reported a truncated walk.
#   3  CANNOT WRITE — a `gh` call failed. Nothing was drafted.
#   4  INVARIANT VIOLATED — a git tag exists for the candidate after a
#      draft-only operation. Never expected; loudest possible failure.
#
# Env:
#   RELEASE_CURATOR_REPO   owner/name        (default FRIKKern/barkpark)
#   RELEASE_CURATOR_REF    ref to scan       (default origin/main)
#   RELEASE_CURATOR_SCAN   path to release-scan.sh (default: beside this file)
#   RELEASE_CURATOR_OUTDIR where the scan JSON + notes are written (default: mktemp)
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="${RELEASE_CURATOR_REPO:-FRIKKern/barkpark}"
REF="${RELEASE_CURATOR_REF:-origin/main}"
SCAN="${RELEASE_CURATOR_SCAN:-$HERE/release-scan.sh}"

OUTDIR="${RELEASE_CURATOR_OUTDIR:-}"
if [ -z "$OUTDIR" ]; then
  OUTDIR="$(mktemp -d)" || { echo "CANNOT READ: mktemp -d failed" >&2; exit 2; }
  trap 'rm -rf "$OUTDIR"' EXIT
fi
mkdir -p "$OUTDIR"
SCAN_JSON="$OUTDIR/release-scan.json"
NOTES="$OUTDIR/notes.md"

cannot_read() { echo "CANNOT READ: $*" >&2; echo "::error::release-curator-draft CANNOT READ: $*"; exit 2; }
cannot_write() { echo "CANNOT WRITE: $*" >&2; echo "::error::release-curator-draft CANNOT WRITE: $*"; exit 3; }
violated() { echo "INVARIANT VIOLATED: $*" >&2; echo "::error::release-curator-draft INVARIANT VIOLATED: $*"; exit 4; }
holding() { echo "HOLDING: $*"; exit 0; }

command -v jq >/dev/null 2>&1 || cannot_read "jq is not on PATH — the scan output cannot be parsed"
command -v gh >/dev/null 2>&1 || cannot_read "gh is not on PATH — a draft cannot be opened or inspected"
[ -f "$SCAN" ] || cannot_read "no release-scan.sh at $SCAN"

# ── 1. SCAN ──────────────────────────────────────────────────────────────────
# release-scan.sh FATALs at exit 3 on a truncated walk. That is a CANNOT-READ,
# not a "nothing to release": the workflow checks out with fetch-depth: 0 for
# exactly this reason, and if the walk is still truncated the checkout is
# broken and the scan's commits[] would under-report the range.
# `rc=$?` INSIDE an `if ! cmd; then` branch reads the status of the NEGATION —
# always 0 — not the command's. The first cut of this file did exactly that and
# reported "release-scan.sh exited 0" on a refusal, a number that is reassuring
# and wrong; case G2 of the harness is what found it. Capture first, test after.
bash "$SCAN" "$REF" >"$SCAN_JSON" 2>"$OUTDIR/scan.err"
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
  cannot_read "release-scan.sh exited $scan_rc for $REF — $(head -2 "$OUTDIR/scan.err" | tr '\n' ' ' | cut -c1-400)"
fi
jq -e 'type == "object"' "$SCAN_JSON" >/dev/null 2>&1 \
  || cannot_read "release-scan.sh emitted something that is not a JSON object"

shallow="$(jq -r '.shallow // false' "$SCAN_JSON")"
[ "$shallow" = "true" ] && cannot_read "the scan reports shallow:true — this checkout cannot see the release range (CI must use fetch-depth: 0)"

last_tag="$(jq -r '.last_tag // ""' "$SCAN_JSON")"
head_sha="$(jq -r '.head_sha // ""' "$SCAN_JSON")"
commit_count="$(jq -r '.commit_count // 0' "$SCAN_JSON")"
version="$(jq -r '.suggested_version // ""' "$SCAN_JSON")"
bump="$(jq -r '.suggested_bump // ""' "$SCAN_JSON")"
ci_status="$(jq -r '.ci.status // "unknown"' "$SCAN_JSON")"
ci_reason="$(jq -r '.ci.status_reason // ""' "$SCAN_JSON")"
certainty="$(jq -r '.ci.advisory_certainty // "cannot_tell"' "$SCAN_JSON")"

[ -n "$head_sha" ] || cannot_read "the scan named no head_sha"
echo "SCAN: repo=$SLUG ref=$REF head=$head_sha last_tag=${last_tag:-<none>} commits=$commit_count ci=$ci_status ($ci_reason) advisory_certainty=$certainty"

# ── 2. GATE — the judgments, every one of them exit 0 ─────────────────────────
[ "$commit_count" -gt 0 ] 2>/dev/null || holding "no commits since ${last_tag:-the beginning} — nothing to draft"
[ -n "$version" ] || holding "the scan suggested no version (no vA.B.C tag is reachable from $REF) — a first release is a human decision, not a draft this job may invent"

case "$ci_status" in
  success) : ;;
  failure) holding "main is RED on $head_sha — $ci_reason. Failing checks: $(jq -r '[.ci.failures[] | select(.advisory != "advisory") | "\(.name) [\(.advisory)]"] | join(", ")' "$SCAN_JSON")" ;;
  pending) holding "checks are still running on $head_sha — $ci_reason. The next tick re-reads it" ;;
  *)       holding "the CI verdict for $head_sha is '$ci_status' — $ci_reason. Cancelled is NOT failure; this job declines to draft on a verdict it cannot read, and never calls main jammed on one" ;;
esac

TAG="v$version"
TITLE="Barkpark $version (candidate)"

# ── 3. NOTES ─────────────────────────────────────────────────────────────────
# Grouped by conventional-commit type. Deliberately mechanical: a scheduled
# script has no judgment and must not pretend to. The header says so in the
# draft itself, so the human blessing it knows the prose is unreviewed.
{
  printf '> **DRAFT — not blessed.** Opened automatically by `.github/workflows/release-curator-draft.yml`\n'
  printf '> from `scripts/release-scan.sh` on `%s`. No tag exists yet: publishing this draft is what creates `%s`.\n' "$head_sha" "$TAG"
  printf '> The grouping below is mechanical (conventional-commit prefixes). Rewrite it before you publish —\n'
  printf '> `.claude/workflows/release-curator.md` step 4 says what good notes look like.\n\n'
  printf '%s commit(s) since **%s**, suggested bump **%s**.\n' "$commit_count" "${last_tag:-<no previous tag>}" "$bump"
  emit_group() { # <heading> <jq-regex over subject>
    local body
    body="$(jq -r --arg re "$2" '[.commits[] | select(.subject | test($re))
             | "- \(.subject)" + (if .pr then " (#\(.pr))" else "" end)] | join("\n")' "$SCAN_JSON")"
    [ -n "$body" ] && printf '\n### %s\n\n%s\n' "$1" "$body"
    return 0
  }
  emit_group "Features"      '^feat(\(|!|:)'
  emit_group "Fixes"         '^fix(\(|!|:)'
  emit_group "Performance"   '^perf(\(|!|:)'
  emit_group "Under the hood" '^(chore|refactor|docs|test|ci|build|style)(\(|!|:)'
  emit_group "Uncategorised" '^(?!(feat|fix|perf|chore|refactor|docs|test|ci|build|style)(\(|!|:))'
  printf '\n---\n\nFull range: `%s..%s`\n' "${last_tag:-<root>}" "$head_sha"
} >"$NOTES" || cannot_read "the notes file could not be written to $NOTES"

# ── 4. DRAFT ─────────────────────────────────────────────────────────────────
# THE ONE DOOR to `gh release create`. Every call goes through here and this
# function refuses an argv without --draft, so a future edit that drops the
# flag fails at runtime instead of publishing a release. The harness asserts
# the same property from outside, over the argv a fake `gh` records.
gh_release_create_draft() { # <tag> <args...>
  local a seen=0
  for a in "$@"; do [ "$a" = "--draft" ] && seen=1; done
  [ "$seen" = "1" ] || violated "a gh release create argv was assembled WITHOUT --draft: $*"
  gh release create "$@"
}

existing="$(gh release view "$TAG" --repo "$SLUG" --json isDraft,url 2>/dev/null || true)"
if [ -n "$existing" ] && printf '%s' "$existing" | jq -e 'type == "object"' >/dev/null 2>&1; then
  is_draft="$(printf '%s' "$existing" | jq -r '.isDraft // false')"
  url="$(printf '%s' "$existing" | jq -r '.url // ""')"
  if [ "$is_draft" != "true" ]; then
    holding "$TAG is already PUBLISHED ($url) — this job never retags, never overwrites, and never re-drafts over a blessed release. The next candidate needs a newer bump."
  fi
  # ONE draft per candidate: refresh the notes in place, never a second release.
  gh release edit "$TAG" --repo "$SLUG" --title "$TITLE" --notes-file "$NOTES" --target "$head_sha" \
    || cannot_write "gh release edit $TAG failed — the existing draft was not refreshed"
  action="REFRESHED"
else
  gh_release_create_draft "$TAG" --repo "$SLUG" --draft --target "$head_sha" --title "$TITLE" --notes-file "$NOTES" \
    || cannot_write "gh release create $TAG --draft failed — no draft was opened"
  action="DRAFTED"
fi

# ── 5. THE INVARIANT, MEASURED ───────────────────────────────────────────────
# Not "a draft does not make a tag, everyone knows that" — ask the remote.
tagline="$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null || true)"
if [ -n "$tagline" ]; then
  violated "refs/tags/$TAG EXISTS on origin after a draft-only operation ($tagline). A draft must not create a tag; the ruling forbids an autonomous tag entirely. Delete the tag and investigate before this job runs again."
fi

echo "$action: $TAG ($TITLE) targeting $head_sha — DRAFT ONLY."
echo "NO TAG: git ls-remote --tags origin refs/tags/$TAG is empty; publishing the draft is the human act that creates it."
exit 0
