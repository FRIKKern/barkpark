#!/usr/bin/env bash
#
# local-update.sh — bring a LOCAL checkout fully up to date, then explain it.
# The local twin of the server's .githooks/post-merge deploy hook:
#
#   pull → diff-driven refresh → digest of what changed
#
#   make update              pull + refresh + digest
#   SINCE=<rev> make update  skip the pull; refresh + digest for <rev>..HEAD
#                            (use when you already pulled and want the rest)
#
# Every refresh step is DIFF-DRIVEN — it runs only when the pull touched its
# inputs — and NON-FATAL: a failed step becomes a WARN with the command to run
# by hand, and the digest still prints. Safe to re-run any time.
set -euo pipefail
cd "$(cd -P -- "$(dirname -- "$0")/.." && pwd)"

BOLD=$'\033[1m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
section() { printf '\n%s── %s ──%s\n' "$BOLD" "$*" "$RESET"; }
did()     { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
skipped() { printf '  – %s\n' "$*"; }
WARNINGS=0
warn()    { printf '%s  ! WARN:%s %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS=$((WARNINGS+1)); }

# ── 1. Pull ──────────────────────────────────────────────────────────────────
if [ -n "${SINCE:-}" ]; then
  OLD="$(git rev-parse "$SINCE")"
  echo ">> Skipping pull (SINCE=$SINCE) — refreshing for $SINCE..HEAD"
else
  OLD="$(git rev-parse HEAD)"
  echo ">> Pulling..."
  git pull --rebase --autostash
fi
NEW="$(git rev-parse HEAD)"

if [ "$OLD" = "$NEW" ]; then
  echo ">> Already up to date — nothing to refresh."
  exit 0
fi
RANGE="$OLD..$NEW"
SHORT_RANGE="$(git rev-parse --short "$OLD")..$(git rev-parse --short "$NEW")"
COUNT="$(git rev-list --count "$RANGE")"

# True when the pull touched any of the given pathspecs.
changed() { [ -n "$(git diff --name-only "$RANGE" -- "$@" | head -1)" ]; }

# ── 2. Diff-driven refresh ───────────────────────────────────────────────────
section "Refreshing local artifacts ($COUNT new commits)"

# bp CLI — the Go binary embeds internal/ assets, so any Go-side change
# (including vendored asset syncs) means the installed bp is stale.
if changed '*.go' go.mod go.sum internal cmd; then
  if make cli-build >/dev/null 2>&1; then
    BP_TARGET=""
    if [ -n "${BP_INSTALL:-}" ]; then
      BP_TARGET="$BP_INSTALL"
    elif command -v bp >/dev/null 2>&1 && [ -w "$(command -v bp)" ]; then
      BP_TARGET="$(command -v bp)"
    fi
    if [ -n "$BP_TARGET" ]; then
      cp dist/bp "$BP_TARGET"
      did "bp CLI rebuilt at $(git rev-parse --short HEAD) and installed to $BP_TARGET"
    else
      did "bp CLI rebuilt -> dist/bp (no writable bp on PATH; set BP_INSTALL=<path> to auto-install)"
    fi
  else
    warn "bp CLI build failed — run by hand: make cli-build"
  fi
else
  skipped "bp CLI (no Go changes)"
fi

# Elixir deps
if changed api/mix.exs api/mix.lock; then
  if (cd api && mix deps.get >/dev/null 2>&1); then
    did "Elixir deps fetched (mix deps.get)"
  else
    warn "mix deps.get failed — run by hand: cd api && mix deps.get"
  fi
else
  skipped "Elixir deps (mix.exs/mix.lock unchanged)"
fi

# DB migrations (local dev DB)
if changed api/priv/repo/migrations; then
  MIGS="$(git diff --name-only "$RANGE" -- api/priv/repo/migrations | sed 's|.*/||')"
  if (cd api && mix ecto.migrate >/dev/null 2>&1); then
    did "migrations applied: $(echo "$MIGS" | tr '\n' ' ')"
  else
    warn "mix ecto.migrate failed (DB not running?) — run by hand: cd api && mix ecto.migrate"
  fi
else
  skipped "migrations (none new)"
fi

# web/ (Next.js demo)
if changed web/package.json web/pnpm-lock.yaml; then
  if (cd web && pnpm install >/dev/null 2>&1); then
    did "web/ deps installed (pnpm)"
  else
    warn "web pnpm install failed — run by hand: cd web && pnpm install"
  fi
else
  skipped "web/ deps (unchanged)"
fi

# js/ (SDK monorepo)
if changed js/pnpm-lock.yaml 'js/*/package.json' 'js/packages/*/package.json'; then
  if (cd js && pnpm install >/dev/null 2>&1); then
    did "js/ SDK deps installed (pnpm)"
  else
    warn "js pnpm install failed — run by hand: cd js && pnpm install"
  fi
else
  skipped "js/ SDK deps (unchanged)"
fi

# ── 3. Heads-up: things a human/agent should RE-READ, not rebuild ────────────
section "Heads-up"
HEADSUP=0
note() { printf '  • %s\n' "$*"; HEADSUP=1; }

if changed CLAUDE.md api/CLAUDE.md js/CLAUDE.md; then
  note "agent instructions changed: $(git diff --name-only "$RANGE" -- CLAUDE.md api/CLAUDE.md js/CLAUDE.md | tr '\n' ' ')— re-read before the next session"
fi
if changed docs; then
  note "docs changed ($(git diff --name-only "$RANGE" -- docs | wc -l | tr -d ' ') files): git diff --stat $SHORT_RANGE -- docs"
fi
if changed api/config; then
  note "api/config/*.exs changed — check for new/renamed env vars before booting"
fi
if changed Makefile .githooks deploy.sh deploy scripts; then
  note "build/deploy tooling changed: $(git diff --name-only "$RANGE" -- Makefile .githooks deploy.sh deploy scripts | tr '\n' ' ')"
fi
BREAKING="$(git log --format='%h %s' "$RANGE" | grep -Ei 'BREAKING|!:' || true)"
if [ -n "$BREAKING" ]; then
  note "commits flagged breaking:"
  printf '%s\n' "$BREAKING" | sed 's/^/      /'
fi
[ "$HEADSUP" = 0 ] && skipped "nothing needs re-reading"

# ── 4. Digest of what came in ────────────────────────────────────────────────
section "What came in ($COUNT commits, $SHORT_RANGE)"
# Count by conventional-commit type so the shape of the batch is readable.
# (-e-separated sed exprs: bare `t` = branch-to-end, portable on BSD sed.)
git log --format='%s' "$RANGE" \
  | sed -E -e 's/^([a-z]+)(\(.*\))?!?:.*/\1/' -e 't' -e 's/.*/other/' \
  | sort | uniq -c | sort -rn \
  | awk '{printf "  %s %s\n", $1, $2}'
echo
# git's own -20 (not `| head`) — a closed pipe under pipefail would SIGPIPE(141) the script
git log -20 --format='  %h %s' "$RANGE"
if [ "$COUNT" -gt 20 ]; then
  echo "  … and $((COUNT - 20)) more: git log --oneline $SHORT_RANGE"
fi

echo
if [ "$WARNINGS" -gt 0 ]; then
  printf '%s>> Done with %d warning(s) — see WARN lines above for the manual commands.%s\n' "$YELLOW" "$WARNINGS" "$RESET"
  exit 1
fi
printf '%s>> Done. Local checkout, bp CLI, deps, and DB are current.%s\n' "$GREEN" "$RESET"
