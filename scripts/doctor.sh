#!/usr/bin/env bash
#
# doctor.sh — READ-ONLY health report for a local checkout. Never mutates
# anything (no pull, no install, no migrate); it only tells you what's stale
# and which command fixes it. `make update` is the fixer; this is the gauge.
#
#   make doctor                 full report
#   scripts/doctor.sh --hook    quiet mode for the Claude Code SessionStart
#                               hook: prints ONLY problems (silent when all
#                               is current), so a healthy checkout adds zero
#                               noise to the session context.
set -uo pipefail
cd "$(cd -P -- "$(dirname -- "$0")/.." && pwd)"

HOOK=0
[ "${1:-}" = "--hook" ] && HOOK=1

PROBLEMS=0
ok()   { [ "$HOOK" = 1 ] || printf '  ✓ %s\n' "$*"; }
skip() { [ "$HOOK" = 1 ] || printf '  – %s\n' "$*"; }
bad()  { printf '  ! %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }

[ "$HOOK" = 1 ] || printf 'barkpark doctor — read-only checks (fix: make update)\n'

# ── 1. Behind origin/main? ───────────────────────────────────────────────────
if git fetch --quiet origin main 2>/dev/null; then
  BEHIND="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  if [ "$BEHIND" -gt 0 ]; then
    bad "checkout is $BEHIND commit(s) behind origin/main — run: make update"
  else
    ok "checkout is current with origin/main"
  fi
  if [ "$AHEAD" -gt 0 ]; then
    # NEVER advise a bare `git push` toward main: branch protection refuses a
    # direct push to main for everyone, admins included, and GH006 there is
    # CORRECT — not a retry cue. Code reaches main by PR only.
    CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$CUR_BRANCH" = "main" ]; then
      bad "$AHEAD local commit(s) on main that origin/main lacks — do NOT run git push: a direct push to main is REFUSED by branch protection (GH006 is correct, not a retry cue). Move them to a branch and open a PR: git branch rescue/<name>, then git reset --hard origin/main, push the branch, and merge with scripts/bp-merge.sh"
    else
      bad "$AHEAD local commit(s) not pushed — run: git push -u origin $CUR_BRANCH (then open a PR; the merge verb is scripts/bp-merge.sh)"
    fi
  fi
else
  skip "fetch failed (offline?) — behind-check skipped"
fi

# ── 1b. Release cadence — has releases/latest drifted behind main? ───────────
# `bp upgrade` and install-cli.sh resolve published cli-v* releases from the
# GitHub API rather than trusting releases/latest or local tags. Do the same
# here: draft/unpublished, prerelease, and non-CLI releases must not make stale
# cadence look current. Advisory only (exit stays 0); the fix is to cut a fresh
# CLI release.
RELEASES_API_URL="${BARKPARK_RELEASES_API_URL:-https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=30}"
RELEASES_JSON="$( { curl -fsSL "$RELEASES_API_URL" 2>/dev/null || wget -qO- "$RELEASES_API_URL" 2>/dev/null || true; } )"
NEWEST_CLI_TAG=""
if [ -n "$RELEASES_JSON" ] && command -v jq >/dev/null 2>&1; then
  NEWEST_CLI_TAG="$(printf '%s' "$RELEASES_JSON" | jq -r '
    [.[]
      | select((.draft // false) == false)
      | select((.prerelease // false) == false)
      | .tag_name
      | select(test("^cli-v[0-9]+([.][0-9]+)*$"))
      | . as $tag
      | (ltrimstr("cli-v") | split(".") | map(try tonumber catch null)) as $version
      | select(all($version[]; type == "number"))
      | select(all($version[]; . >= 0 and . <= 4294967295 and floor == .))
      | {tag: $tag, version: $version}]
    | sort_by(.version) | last | .tag // empty
  ' 2>/dev/null)"
fi
if [ -n "$NEWEST_CLI_TAG" ] \
   && git rev-parse --verify --quiet "$NEWEST_CLI_TAG" >/dev/null 2>&1 \
   && git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  TAG_DRIFT="$(git rev-list --count "$NEWEST_CLI_TAG"..origin/main 2>/dev/null || echo 0)"
  TAG_EPOCH="$(git log -1 --format=%ct "$NEWEST_CLI_TAG" 2>/dev/null || echo 0)"
  TAG_AGE_DAYS=0
  [ "$TAG_EPOCH" -gt 0 ] 2>/dev/null && TAG_AGE_DAYS=$(( ( $(date +%s) - TAG_EPOCH ) / 86400 ))
  if [ "$TAG_DRIFT" -gt 250 ] || [ "$TAG_AGE_DAYS" -gt 14 ]; then
    bad "release $NEWEST_CLI_TAG is $TAG_DRIFT commit(s) / ${TAG_AGE_DAYS}d behind origin/main — cut a fresh cli release (unpinned installs get releases/latest)"
  else
    ok "release cadence current ($NEWEST_CLI_TAG: $TAG_DRIFT commit(s) / ${TAG_AGE_DAYS}d behind main)"
  fi
else
  skip "published stable cli release, jq, or origin/main ref unavailable — release-cadence check skipped"
fi

# ── 1c. Test database inventory and connection pressure ──────────────────────
# Abandoned lane partitions can accumulate (314 measured 2026-08-24,
# task-1a7e52b811dabc3c). This query counts all matching names, not proven orphans.
# `make test` (scripts/test-partition-cleanup.sh) now drops a lane's own
# partition on a clean exit; `make reap-test-dbs` sweeps by age for the lanes
# that never reach one. Read-only here: this counts, it never drops.
#
# DATABASE COUNT AND CONNECTION PRESSURE ARE TWO SEPARATE FACTS — do not fuse
# them. An idle orphaned database holds ZERO connections (verified live
# 2026-08-31: 182 orphans, 0 of them in pg_stat_activity); the connections in
# use belong to whatever is ACTUALLY running right now (dev `phx.server`s,
# live lanes' pools, ...). A prior version of this check printed "at the
# ceiling" unconditionally whenever the orphan count was high, regardless of
# actual connection usage — which is itself a misread-failure risk of exactly
# the kind this check exists to prevent. So the two are reported, and warned
# on, independently below.
TEST_DB_WARN="${BARKPARK_TEST_DB_WARN:-60}"
CONN_WARN_PCT="${BARKPARK_TEST_DB_CONN_WARN_PCT:-80}"
if command -v psql >/dev/null 2>&1; then
  TEST_DBS="$(psql -h "${BARKPARK_TEST_DB_HOST:-localhost}" -U "${BARKPARK_TEST_DB_USER:-postgres}" \
      -tAc "select count(*) from pg_database where datname like 'barkpark\\_test%';" 2>/dev/null)"
  CONN_USED="$(psql -h "${BARKPARK_TEST_DB_HOST:-localhost}" -U "${BARKPARK_TEST_DB_USER:-postgres}" \
      -tAc "select count(*) from pg_stat_activity;" 2>/dev/null)"
  CONN_MAX="$(psql -h "${BARKPARK_TEST_DB_HOST:-localhost}" -U "${BARKPARK_TEST_DB_USER:-postgres}" \
      -tAc "select setting from pg_settings where name='max_connections';" 2>/dev/null)"
  if [ -n "$TEST_DBS" ]; then
    if [ "$TEST_DBS" -gt "$TEST_DB_WARN" ] 2>/dev/null; then
      bad "$TEST_DBS barkpark_test* databases (orphan status not established; connections ${CONN_USED:-?}/${CONN_MAX:-?}, see below). Inspect age and active connections: make reap-test-dbs (dry run); use make test to clean up each lane's own partition"
    else
      ok "$TEST_DBS barkpark_test* databases (connections ${CONN_USED:-?}/${CONN_MAX:-?})"
    fi
    if [ -n "$CONN_USED" ] && [ -n "$CONN_MAX" ] && [ "$CONN_MAX" -gt 0 ] 2>/dev/null \
        && [ $(( CONN_USED * 100 / CONN_MAX )) -ge "$CONN_WARN_PCT" ] 2>/dev/null; then
      bad "connections ${CONN_USED}/${CONN_MAX} is near the ceiling — ecto.create dies with \"couldn't be created: killed\" and tests with \"FATAL 53300 too_many_connections\" when it's hit. NEITHER is a code fault; do not record such an abort as a red"
    fi
  else
    skip "postgres unreachable — orphaned-test-database check skipped"
  fi
else
  skip "psql not on PATH — orphaned-test-database check skipped"
fi

# ── 2. Installed bp binary stale? ────────────────────────────────────────────
# bp embeds its build commit via -ldflags; it is stale only if Go-side inputs
# changed on the MERGED tip since. The compare-target is origin/main, NOT local
# HEAD: a binary built in a diverged worktree (behind + ahead of the merged tip)
# false-greens against HEAD because both sides are stale together — the binary
# and the worktree it was built from miss the same merged CLI commits. Comparing
# against origin/main is what makes a behind binary red honestly.
#
# The ldflags `commit` field is the ONLY trustworthy provenance signal here. We
# never read `go version -m` vcs.revision/vcs.modified: Go's -buildvcs walk-up
# binds to the nearest ancestor `.git` DIRECTORY, so in a worktree nested under
# the primary checkout it stamps the ANCESTOR repo's HEAD, not the worktree's —
# unsound for freshness. Only the ldflags stamp reflects the code that was built.
if command -v bp >/dev/null 2>&1; then
  # Capture the bare hex SHA even when the build was dirty: a dirty tree stamps
  # e.g. "2a8b147ee-dirty-purpose", so allow a non-quote suffix after the hex
  # (\{7,\} anchors on a real short/long SHA, never a stray hex fragment) and
  # emit only \1 — the bare hex the ancestry check below feeds to git cat-file.
  BP_COMMIT="$(bp version 2>/dev/null | sed -n 's/.*"commit": *"\([0-9a-f]\{7,\}\)[^"]*".*/\1/p')"
  # Guard order is load-bearing (proven on the fixture verdict matrix):
  #   1. no stamp        → loud RED (unverifiable provenance; fix installs one)
  #   2. commit unknown  → loud skip (can't diff a commit we don't have)
  #   3. origin/main ref → loud skip when absent (offline/shallow — a BARE
  #                        `git diff $(git merge-base …) origin/main` FALSE-GREENS
  #                        here: merge-base errors, $base goes empty, the swallowed
  #                        error leaves an empty diff that reads ok)
  #   4. merge-base      → loud skip when empty (no common ancestry to compare)
  #   5. ancestry        → RED (DIVERGED) when origin/main does not CONTAIN the
  #                        bp commit and the bp commit does not contain
  #                        origin/main: the binary carries code main has never
  #                        seen, so "predates" is FALSE and a rebuild from this
  #                        same checkout reinstalls the same off-history binary
  #   6. diff            → RED iff Go inputs changed merge-base→origin/main
  # The merge-base collapse is why a binary AHEAD with unpushed local Go commits
  # stays GREEN: its merge-base with origin/main IS origin/main, so the diff is
  # empty — a bare `git diff BP_COMMIT origin/main` would false-RED that case.
  if [ -z "$BP_COMMIT" ]; then
    # No commit field at all → the binary was built by a bare `go build` with no
    # -ldflags, so its provenance is unverifiable. This is the PATH/dist
    # divergence trap: the same `bp` name can mean different code across workers.
    # RED loudly (do not skip); the fix installs a commit-stamped bp.
    bad "installed bp has NO build-commit stamp (built without -ldflags) — run: make cli-install"
  elif ! git cat-file -e "$BP_COMMIT^{commit}" 2>/dev/null; then
    skip "bp build commit not in this checkout ($BP_COMMIT) — staleness check skipped"
  elif ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    # origin/main is the compare-target; without it there is nothing sound to
    # diff against. LOUD skip (never a silent ok) — the bare merge-base form
    # would false-green here.
    skip "origin/main ref unavailable (offline / never fetched) — bp staleness check skipped"
  elif ! BP_MERGE_BASE="$(git merge-base "$BP_COMMIT" origin/main 2>/dev/null)" \
       || [ -z "$BP_MERGE_BASE" ]; then
    skip "no merge-base between bp commit ($BP_COMMIT) and origin/main — staleness check skipped"
  elif ! git merge-base --is-ancestor "$BP_COMMIT" origin/main 2>/dev/null \
       && ! git merge-base --is-ancestor origin/main "$BP_COMMIT" 2>/dev/null; then
    # DIVERGED — the rung, in the vocabulary of
    # cloud/lib/barkpark_cloud/github/commit_distance.ex:120 (and its local twin
    # tooling/grip/provenance.mjs). Neither commit contains the other, so the
    # binary is not "behind": it is off origin/main's history, carrying commits
    # main has never seen. The old branch below called this "predates Go
    # changes" — false — and prescribed `make cli-install`, which is a LOOP:
    # cli-build runs `go build ./cmd/barkpark` against THIS diverged checkout and
    # reinstalls the same off-history binary. Only a rebase/pull can end it.
    #
    # --is-ancestor's rc=128 ("not in this object database") cannot reach here:
    # guard 2 already proved BP_COMMIT is in this object database and guard 3
    # proved origin/main resolves, so both calls answer 0 or 1. Were 128
    # possible, `!` would read it as "not an ancestor" and turn "I could not
    # look" into a confident refusal.
    bad "installed bp ($BP_COMMIT) is DIVERGED from origin/main — it carries commits main does not have, so it does not merely predate main and rebuilding from this checkout reinstalls the same binary — run: git pull --rebase (then: make cli-install)"
  elif [ -n "$(git diff --name-only "$BP_MERGE_BASE" origin/main -- '*.go' go.mod go.sum internal cmd deploy.sh 2>/dev/null | head -1)" ]; then
    bad "installed bp ($BP_COMMIT) predates Go changes on origin/main — run: make cli-install"
  else
    ok "installed bp ($BP_COMMIT) is current with origin/main"
  fi
else
  # NOT a skip. `skip` prints nothing under --hook (line 20), and a missing bp is
  # the single most likely failure in a second environment — a fresh clone on
  # another machine has no bp at all, and the SessionStart hook staying silent
  # about it is exactly the case the hook exists to catch. `bad` prints in both
  # modes and counts toward the issue summary; the script still exits 0 below
  # (doctor is advisory, never a gate).
  bad "no bp on PATH — install: make cli-install"
fi

# ── 3. Pending migrations on the local dev DB? ──────────────────────────────
# Direct psql (no BEAM boot — fast enough for a session hook). Skips quietly
# when the dev DB isn't running; `make update` reports migrate failures anyway.
if command -v psql >/dev/null 2>&1 \
   && APPLIED="$(psql -h localhost -U postgres -d barkpark_dev -tAc \
        'select version from schema_migrations' 2>/dev/null)"; then
  PENDING=""
  for f in api/priv/repo/migrations/*.exs; do
    v="$(basename "$f" | cut -d_ -f1)"
    # No upstream writer: grep -q may close early, which makes printf fail
    # with SIGPIPE under pipefail and falsely reports an applied version.
    grep -qxF "$v" <<<"$APPLIED" || PENDING="$PENDING $(basename "$f")"
  done
  if [ -n "$PENDING" ]; then
    bad "pending migrations:$PENDING — run: cd api && mix ecto.migrate"
  else
    # VERSION rows only. A migration amended in place after it ran keeps its
    # row and its stale object forever, so "current" here is not a claim that
    # the schema OBJECTS match the files (PDS-D311).
    ok "dev DB migration versions are current (version rows, not a read of the objects)"
  fi
else
  skip "dev DB not reachable — migration check skipped"
fi

# ── 4. Vendored assets in sync? ──────────────────────────────────────────────
if cmp -s deploy.sh internal/cli/setup/assets/deploy.sh; then
  ok "vendored deploy.sh asset in sync"
else
  bad "deploy.sh and internal/cli/setup/assets/deploy.sh differ — run: make cli-assets-sync (edit the ROOT copy)"
fi

# ── 5. Working-tree hygiene ──────────────────────────────────────────────────
UNTRACKED="$(git status --porcelain | grep -c '^??' || true)"
DIRTY="$(git status --porcelain | grep -c '^ *[MADRC]' || true)"
if [ "$UNTRACKED" -gt 0 ] || [ "$DIRTY" -gt 0 ]; then
  # Informational, not a problem — but in hook mode surface it so stragglers
  # from a previous session don't get stranded silently.
  MSG="working tree: $DIRTY modified, $UNTRACKED untracked (git status)"
  if [ "$HOOK" = 1 ]; then printf '  · %s\n' "$MSG"; else skip "$MSG"; fi
else
  ok "working tree clean"
fi

if [ "$PROBLEMS" -gt 0 ]; then
  [ "$HOOK" = 1 ] && printf 'barkpark doctor: %d issue(s) above — fix-all: make update\n' "$PROBLEMS"
  [ "$HOOK" = 0 ] && printf '>> %d issue(s) found.\n' "$PROBLEMS"
  exit 0   # advisory, never blocks a session or a script chain
fi
[ "$HOOK" = 1 ] || printf '>> All current.\n'
