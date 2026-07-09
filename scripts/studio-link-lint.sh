#!/usr/bin/env bash
# studio-link-lint.sh — hand-built Studio-URL tripwire (bp-studio-deep-link W1).
#
# The epic's invariant: every Studio destination has ONE canonical path, and
# every link / push_patch / push_navigate emits it through the single builder
# `BarkparkWeb.Studio.StudioLive.Paths` (lib/.../studio_live/paths.ex). A
# hand-built, INTERPOLATED, scope/dataset Studio URL string literal anywhere
# else is how the two-spellings-per-destination drift crept in — a deep vs
# shallow path that carries different breadcrumbs/back-nav/scope. This gate
# greps the Studio web tree and FAILS (exit 1, file:line) on any such literal
# outside the builder and an EXPLICIT, justified whitelist.
#
# What is flagged (the drift-prone shapes the builder owns):
#   · "/d/#{...}/studio..."          — scoped canonical dataset path
#   · "/studio/#{...}"               — flat dataset path (must 302, never emitted)
#   · "/w/#{...}...studio..."        — full scoped path
# What is NOT flagged (legitimately outside the builder's remit):
#   · `~p"..."` verified routes      — Phoenix compile-checks these against the
#                                      router; they cannot drift to a dead path.
#   · static flat admin singletons   — "/studio/settings", "/studio/chat",
#     ("/studio/…" with NO interpolation) "/studio/tmux", "/studio/styleguide":
#                                      a distinct, workspace-less route family.
#   · comment lines.
#
# The WHITELIST below is the reviewed registry of deliberate flat exceptions
# (mirrors docs-anchors-check.sh §8's canonical-marker registry). Each entry
# carries a one-line justification. Two justification classes:
#   [SEAM]    — a legitimate canonical builder / redirect target / scope
#               resolver that OWNS its literal (router, redirect controllers,
#               the socket-aware choke point, the scope-prefix resolver).
#   [PENDING] — a literal the wave-1 fix slices (sdl-w1-builder/teleport/
#               admin-canonical/return-path) move INTO Paths; whitelisted only
#               until that slice merges. The LEAD prunes the entry as each fix
#               lands — a PENDING entry that no longer matches is dead and
#               should be removed. NEVER add a new PENDING to make an edit pass;
#               route the URL through Paths instead.
#
# Self-test: `studio-link-lint.sh --selftest` proves the gate BITES — it plants
# a synthetic hand-built href in a temp file, asserts the scanner reds naming
# it, then asserts a clean file passes. Plants nothing in the tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCAN_ROOT="api/lib/barkpark_web"
BUILDER="api/lib/barkpark_web/live/studio/studio_live/paths.ex"

# The drift-prone interpolated Studio-URL shapes the builder owns.
PATTERN='(/d/#\{|/studio/#\{|/w/#\{[^"]*studio)'

# ── Whitelist: the reviewed registry of deliberate flat exceptions ──────────
# Path substring → justification. A hit whose file matches ANY entry is exempt.
# bash 3.2: parallel arrays, no assoc.
WL_PATH=(
  # ── [SEAM] canonical builders / redirect targets / scope resolvers ───────
  "controllers/studio_redirect_controller.ex"   # [SEAM] THE flat→scoped 302 funnel; owns the canonical target string.
  "controllers/admin_studio_redirect_controller.ex" # [SEAM] flat admin → scoped 302 funnel (settings/_plugins); owns its canonical targets.
  "controllers/grant_controller.ex"             # [SEAM] post-claim redirect target → scoped Studio (controller redirect).
  "controllers/legacy_redirect_controller.ex"   # [SEAM] retargets legacy /studio/:ds/book deep links (controller redirect).
  "studio_chrome.ex"                            # [SEAM] scope-prefix + canonical breadcrumb URL for the chrome (scope-resolver seam).
  "live/studio/studio_live/shared.ex"          # [SEAM] the socket-aware studio_path/4 choke point + sync_scope_prefix (delegates to Paths).
  # ── [PENDING] (none) — all wave-1 fix slices consolidated their literals ─
  # into Paths. NEVER add a new PENDING to make an edit pass; route the URL
  # through Paths instead.
)

selftest() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # A synthetic offender: a hand-built scoped Studio href, NOT via Paths.
  cat >"$tmp/offender.ex" <<'EOF'
defmodule Bad do
  def href(ws, ds), do: "/w/#{ws}/d/#{ds}/studio/post"
end
EOF
  # A clean file: static admin singleton + a ~p verified route (both allowed).
  cat >"$tmp/clean.ex" <<'EOF'
defmodule Good do
  def a, do: "/studio/settings"
  def b(ds), do: ~p"/studio/#{ds}/_plugins"
end
EOF

  local out
  if out="$(grep -rnE "$PATTERN" "$tmp/offender.ex" | grep -v '~p' | grep -vE ':[0-9]+:[[:space:]]*#')" \
     && [ -n "$out" ]; then
    echo "selftest: ok — planted offender detected:"
    echo "$out" | sed 's/^/  /'
  else
    echo "SELFTEST FAIL: the scanner did NOT flag a planted hand-built Studio href"
    exit 1
  fi

  if grep -rnE "$PATTERN" "$tmp/clean.ex" | grep -v '~p' | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then
    echo "SELFTEST FAIL: the scanner flagged a clean file (static singleton / ~p route)"
    exit 1
  else
    echo "selftest: ok — clean file (static singleton + ~p route) passes"
  fi

  echo "studio-link-lint --selftest: PASS"
}

whitelisted() {
  local file="$1"
  local entry
  for entry in "${WL_PATH[@]}"; do
    case "$file" in
      *"$entry") return 0 ;;
    esac
  done
  return 1
}

main() {
  echo "== studio-link-lint: hand-built Studio URLs outside Paths =="

  # Raw candidate hits (interpolated scope/dataset studio literals),
  # ~p-verified routes and comment lines excluded, the builder excluded.
  local hits
  hits="$(grep -rnE "$PATTERN" "$SCAN_ROOT" --include='*.ex' --include='*.heex' 2>/dev/null \
    | grep -v '~p' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -vF "$BUILDER" || true)"

  local fail=0
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    local file="${hit%%:*}"
    if whitelisted "$file"; then
      continue
    fi
    if [ "$fail" -eq 0 ]; then
      echo "FAIL: hand-built Studio URL literal(s) outside Paths + whitelist —"
      echo "      route it through BarkparkWeb.Studio.StudioLive.Paths, or (only if"
      echo "      genuinely a canonical seam) add a justified whitelist entry."
    fi
    echo "  $hit"
    fail=1
  done <<EOF
$hits
EOF

  if [ "$fail" -ne 0 ]; then
    echo ""
    echo "studio-link-lint: FAILED"
    exit 1
  fi

  echo "ok:   no hand-built Studio URLs outside Paths + the reviewed whitelist"
  echo "studio-link-lint: PASS"
}

case "${1:-}" in
  --selftest) selftest ;;
  *) main ;;
esac
