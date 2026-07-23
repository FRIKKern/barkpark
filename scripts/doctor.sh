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
  [ "$AHEAD" -gt 0 ] && bad "$AHEAD local commit(s) not pushed — run: git push"
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

# ── 2. Installed bp binary stale? ────────────────────────────────────────────
# bp embeds its build commit; it is stale only if Go-side inputs changed since.
if command -v bp >/dev/null 2>&1; then
  # Capture the bare hex SHA even when the build was dirty: a dirty tree stamps
  # e.g. "2a8b147ee-dirty-purpose", so allow a non-quote suffix after the hex
  # (\{7,\} anchors on a real short/long SHA, never a stray hex fragment) and
  # emit only \1 — the bare hex the ancestry check below feeds to git cat-file.
  BP_COMMIT="$(bp version 2>/dev/null | sed -n 's/.*"commit": *"\([0-9a-f]\{7,\}\)[^"]*".*/\1/p')"
  if [ -z "$BP_COMMIT" ]; then
    # No commit field at all → the binary was built by a bare `go build` with no
    # -ldflags, so its provenance is unverifiable. This is the PATH/dist
    # divergence trap: the same `bp` name can mean different code across workers.
    # RED loudly (do not skip); the fix installs a commit-stamped bp.
    bad "installed bp has NO build-commit stamp (built without -ldflags) — run: make cli-install"
  elif ! git cat-file -e "$BP_COMMIT^{commit}" 2>/dev/null; then
    skip "bp build commit not in this checkout ($BP_COMMIT) — staleness check skipped"
  elif [ -n "$(git diff --name-only "$BP_COMMIT" HEAD -- '*.go' go.mod go.sum internal cmd 2>/dev/null | head -1)" ]; then
    bad "installed bp ($BP_COMMIT) predates Go changes in HEAD — run: make cli-install"
  else
    ok "installed bp ($BP_COMMIT) is current"
  fi
else
  skip "no bp on PATH — install: make cli-install"
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
    printf '%s\n' "$APPLIED" | grep -q "^$v$" || PENDING="$PENDING $(basename "$f")"
  done
  if [ -n "$PENDING" ]; then
    bad "pending migrations:$PENDING — run: cd api && mix ecto.migrate"
  else
    ok "dev DB migrations are current"
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
