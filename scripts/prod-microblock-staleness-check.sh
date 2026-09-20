#!/usr/bin/env bash
# Does the prod micro-block 89.167.28.206 run what origin/main holds?
#
# THE DEFECT THIS GUARDS. On 2026-09-20 that box served HTTP 200 on every health
# surface this repo offers while running code from 2026-08-31 — 2891 commits and
# 24 migrations behind origin/main. It is not a deploy.yml target (that
# workflow's only SSH hosts are CP_HOST and GUERRILLA_HOST); its deploy is a
# human running `git pull` on the box. Nothing compared its commit to
# origin/main, so twenty days of drift were invisible by construction.
#
# NO CREDENTIAL IS NEEDED. The box publishes its commit over plain HTTP at
# /status.json. This is an HTTP read plus local git — no ssh, no secret. It
# WRITES NOTHING, anywhere.
#
# THE PROPERTY THAT MATTERS MOST. A failed read must never be byte-identical to
# "zero commits behind". The bug being guarded IS a green surface over an
# unknown state, so a guard that answers 0 when it could not fetch reproduces
# the bug rather than catching it. CANNOT-READ therefore has its own exit code,
# its own banner word, and covers five arms: unreachable host, no `commit` key,
# empty `commit`, a sha git has never seen, and malformed JSON.
#
# FORKED IS AN ANSWER, NOT AN ERROR. A sha that is not an ancestor of the
# comparison ref (a branch build, a revert, a rewritten history) is a decided
# verdict with its own exit code — "behind by 0" would be a lie about it.
#
#   exit 0  OK          the box is at the ref, or within PROD_MICROBLOCK_MAX_BEHIND
#                       with no pending migrations
#   exit 3  BEHIND      past the threshold, or any migration pending
#   exit 4  CANNOT-READ the state is UNKNOWN. Never confuse this with 0.
#   exit 5  FORKED      the served sha is not an ancestor of the ref
#
# Selftest: scripts/prod-microblock-staleness-check.test.sh
set -uo pipefail

EXIT_OK=0
EXIT_BEHIND=3
EXIT_CANNOT_READ=4
EXIT_FORKED=5

STATUS_URL="${PROD_MICROBLOCK_STATUS_URL:-http://89.167.28.206/status.json}"
REF="${PROD_MICROBLOCK_REF:-origin/main}"
MAX_BEHIND="${PROD_MICROBLOCK_MAX_BEHIND:-0}"
MIGRATION_PATH="${PROD_MICROBLOCK_MIGRATION_PATH:-api/priv/repo/migrations/}"
# The fetcher is an injection point ONLY so the selftest can stub the network
# with a fake that emits the RAW status.json body. It must never be stubbed with
# something that returns the verdict — that would skip the code under test.
CURL_BIN="${PROD_MICROBLOCK_CURL:-curl}"

if [ "${1:-}" = "--exit-codes" ]; then
  printf 'OK=%d\nBEHIND=%d\nCANNOT_READ=%d\nFORKED=%d\n' \
    "$EXIT_OK" "$EXIT_BEHIND" "$EXIT_CANNOT_READ" "$EXIT_FORKED"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cannot_read() {
  # One exit door for every unknown. The word CANNOT-READ appears on no other
  # path, so `grep -q CANNOT-READ` is a sound test for "the state is unknown".
  echo "CANNOT-READ: $1" >&2
  echo "  url: $STATUS_URL" >&2
  echo "  This is NOT 'zero commits behind'. The box's state is UNKNOWN and this" >&2
  echo "  check has proven nothing about it. Fix the read before trusting a green." >&2
  exit "$EXIT_CANNOT_READ"
}

command -v jq >/dev/null 2>&1 || cannot_read "jq is not installed; the status.json body cannot be parsed"

fetch_err="$(mktemp "${TMPDIR:-/tmp}/prod-staleness.XXXXXX")"
trap 'rm -f "$fetch_err"' EXIT

if ! body="$("$CURL_BIN" -sS --max-time 15 "$STATUS_URL" 2>"$fetch_err")"; then
  cannot_read "the box did not answer: $(head -c 300 "$fetch_err" 2>/dev/null)"
fi
[ -n "$body" ] || cannot_read "the box answered with an EMPTY body"

# jq's own exit code separates malformed JSON from a well-formed body missing
# the key. Collapsing them would hide a broken endpoint behind "no commit".
commit="$(printf '%s' "$body" | jq -r 'if type == "object" then (.commit // "") else "" end' 2>/dev/null)"
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  cannot_read "the body is not parseable JSON (jq exit $jq_rc): $(printf '%s' "$body" | head -c 200)"
fi
if [ -z "$commit" ] || [ "$commit" = "null" ]; then
  cannot_read "the body carries no usable \"commit\" key (absent, null or empty): $(printf '%s' "$body" | head -c 200)"
fi
# Barkpark.BuildInfo degrades to the literal string "unknown" when it cannot
# derive a sha at compile time. That is an unknown state, not a commit.
case "$commit" in
  [0-9a-fA-F]*) : ;;
  *) cannot_read "commit=\"$commit\" is not hexadecimal (BuildInfo serves \"unknown\" when it has no sha)" ;;
esac
if ! printf '%s' "$commit" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
  cannot_read "commit=\"$commit\" is not a 7-40 character hex sha — too short or malformed to resolve"
fi

if ! served="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${commit}^{commit}" 2>/dev/null)"; then
  cannot_read "git does not know the served sha $commit (unfetched, from another repo, or rewritten history)"
fi
if ! ref_sha="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null)"; then
  cannot_read "the comparison ref '$REF' does not resolve in $REPO_ROOT"
fi

echo "box      $STATUS_URL"
echo "served   $served"
echo "ref      $REF  $ref_sha"

if [ "$served" = "$ref_sha" ]; then
  echo "OK: the box serves $REF exactly (0 commits behind, 0 migrations pending)."
  exit "$EXIT_OK"
fi

if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$served" "$ref_sha" 2>/dev/null; then
  ahead="$(git -C "$REPO_ROOT" rev-list --count "${ref_sha}..${served}" 2>/dev/null || echo '?')"
  echo "FORKED: the served sha is NOT an ancestor of $REF ($ahead commit(s) on the box's side alone)." >&2
  echo "  This is a decided answer, not zero and not an error: the box is running a" >&2
  echo "  branch build, a revert, or history that $REF does not contain." >&2
  exit "$EXIT_FORKED"
fi

behind="$(git -C "$REPO_ROOT" rev-list --count "${served}..${ref_sha}")"
# ONLY *.exs. `git diff --diff-filter=A` over the migrations directory also
# catches api/priv/repo/migrations/MANIFEST.sha256, which is a checksum file,
# not a migration — counting it overstates the pending set by exactly one (24
# vs the true 23 across ca4534461..origin/main on 2026-09-20).
migrations="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=A "${served}..${ref_sha}" -- "$MIGRATION_PATH" | grep -cE '\.exs$' || true)"

echo "behind   $behind commits"
echo "pending  $migrations migrations under $MIGRATION_PATH"

if [ "$behind" -gt "$MAX_BEHIND" ] || [ "$migrations" -gt 0 ]; then
  echo "BEHIND: the box is $behind commits behind $REF with $migrations pending migration(s)." >&2
  echo "  Threshold PROD_MICROBLOCK_MAX_BEHIND=$MAX_BEHIND; ANY pending migration reds regardless." >&2
  echo "  This box is not a deploy.yml target. Its deploy is a human running \`git pull\` on it." >&2
  echo "  Plan: docs/ops/prod-microblock-pull-plan.md" >&2
  exit "$EXIT_BEHIND"
fi

echo "OK: $behind commits behind (within PROD_MICROBLOCK_MAX_BEHIND=$MAX_BEHIND), 0 migrations pending."
exit "$EXIT_OK"
