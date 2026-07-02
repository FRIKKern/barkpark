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

# ── 2. Installed bp binary stale? ────────────────────────────────────────────
# bp embeds its build commit; it is stale only if Go-side inputs changed since.
if command -v bp >/dev/null 2>&1; then
  BP_COMMIT="$(bp version 2>/dev/null | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p')"
  if [ -z "$BP_COMMIT" ] || ! git cat-file -e "$BP_COMMIT^{commit}" 2>/dev/null; then
    skip "bp build commit unknown ($BP_COMMIT) — staleness check skipped"
  elif [ -n "$(git diff --name-only "$BP_COMMIT" HEAD -- '*.go' go.mod go.sum internal cmd 2>/dev/null | head -1)" ]; then
    bad "installed bp ($BP_COMMIT) predates Go changes in HEAD — run: make update"
  else
    ok "installed bp ($BP_COMMIT) is current"
  fi
else
  skip "no bp on PATH — install: make cli-build && cp dist/bp ~/.local/bin/bp"
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
