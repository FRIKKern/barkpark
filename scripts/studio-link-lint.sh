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
# Self-test: `studio-link-lint.sh --selftest` proves the gate BITES — it builds a
# throwaway fixture TREE under mktemp and re-invokes THIS SCRIPT against it
# (`STUDIO_LINK_LINT_ROOT=<fixture> bash "$0"`), asserting both the exit code and
# the real gate's own output. It drives main() and whitelisted() for real; it
# does NOT reimplement the scan. Plants nothing in the tree.
#
# The old selftest ran its own inline grep over two temp FILES: it shared only
# $PATTERN with the gate, so stubbing main() to `return 0` — or disarming
# whitelisted() so every file is exempt — left `--selftest` at exit 0. A selftest
# that survives its guard being fully disarmed certifies nothing (wave
# ci-gate-script-integrity, slice cgsi-s3). It is now proven able to fail under
# five independent guard-disarm mutations (whitelisted, main, PATTERN, the
# --include set, the scan-root guard).
#
# RESIDUAL RISK (shipped knowingly): STUDIO_LINK_LINT_ROOT is a NEW silencing
# surface. Pointing it at a tree whose api/lib/barkpark_web EXISTS but is empty
# still greens — the guard reds only on an ABSENT scan root, not a thin one.
# That is the same residual the repo already accepts for TENANT_SCOPE_LIB and
# CONSOLE_RUNTIME_PIN_ROOT; no workflow sets the var, CI runs the gate with it
# unset. A minimum-file-count assertion was NOT shipped: the fixture trees this
# selftest builds are deliberately tiny (2-3 files), so any floor high enough to
# catch a hollowed real tree would red the selftest's own fixtures.

set -euo pipefail

REPO_ROOT="${STUDIO_LINK_LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
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

# ── SELF-TEST ───────────────────────────────────────────────────────────────
# Eight cases, each of them a full run of THE REAL GATE against a throwaway
# fixture tree that mirrors the repo layout (api/lib/barkpark_web/...), so
# SCAN_ROOT / BUILDER / PATTERN / the whitelist loop all keep byte-identical
# semantics between the selftest and CI. Every case asserts the exit code AND a
# substring of the gate's own stdout — an exit code alone cannot tell a real
# pass from a guard that never scanned.
selftest() {
  local tmp bad=0 rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() {
    if [ "$2" -eq 0 ]; then
      echo "  ok    $1"
    else
      echo "  FAIL  $1"
      sed 's/^/          /' "$tmp/out"
      bad=$((bad + 1))
    fi
  }

  # A fixture tree with the REAL layout: the scan root, the builder, and a clean
  # file (static admin singleton + a ~p verified route — both legitimately
  # unflagged). Callers plant on top of this.
  fresh() {
    rm -rf "$tmp/tree"
    mkdir -p "$tmp/tree/$SCAN_ROOT/live/studio/studio_live" \
             "$tmp/tree/$SCAN_ROOT/controllers"
    cat >"$tmp/tree/$BUILDER" <<'EOF'
defmodule BarkparkWeb.Studio.StudioLive.Paths do
  def studio_path(ws, ds), do: "/w/#{ws}/d/#{ds}/studio"
end
EOF
    cat >"$tmp/tree/$SCAN_ROOT/clean.ex" <<'EOF'
defmodule Good do
  def a, do: "/studio/settings"
  def b(ds), do: ~p"/studio/#{ds}/_plugins"
  # a commented literal: "/w/#{ws}/d/#{ds}/studio/post"
end
EOF
  }

  # One run of the REAL gate against the fixture tree.
  probe() {
    local code=0
    STUDIO_LINK_LINT_ROOT="$tmp/tree" bash "$0" >"$tmp/out" 2>&1 || code=$?
    echo "$code"
  }

  plant() {   # plant <relative-path-under-scan-root> <literal>
    mkdir -p "$(dirname "$tmp/tree/$SCAN_ROOT/$1")"
    printf 'defmodule Bad do\n  def href(ws, ds), do: "%s"\nend\n' "$2" \
      >"$tmp/tree/$SCAN_ROOT/$1"
  }

  echo "studio-link-lint --selftest (real gate, throwaway fixture tree)"

  # 1 — a clean corpus greens, and says so.
  fresh; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "no hand-built Studio URLs outside Paths" "$tmp/out"; } \
    && say "clean corpus -> exit 0, 'no hand-built Studio URLs outside Paths'" 0 \
    || say "clean corpus -> exit 0 (got $rc)" 1

  # 2 — the scoped shape reds AND names the offending file:line.
  fresh; plant "live/studio/plant_a.ex" '/w/#{ws}/d/#{ds}/studio/post'; rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "live/studio/plant_a.ex:2:" "$tmp/out" \
      && grep -q "studio-link-lint: FAILED" "$tmp/out"; } \
    && say "planted /w/#{}/d/#{}/studio/... -> exit 1, offender named" 0 \
    || say "planted /w/#{}/d/#{}/studio/... -> exit 1, offender named (got $rc)" 1

  # 3 — removing the plant greens again (the red in case 2 was the plant, not
  #     the fixture tree).
  rm -f "$tmp/tree/$SCAN_ROOT/live/studio/plant_a.ex"; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "studio-link-lint: PASS" "$tmp/out"; } \
    && say "plant removed -> exit 0 again" 0 \
    || say "plant removed -> exit 0 again (got $rc)" 1

  # 4 — the flat interpolated shape reds too.
  fresh; plant "live/studio/plant_flat.ex" '/studio/#{ds}/post'; rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "plant_flat.ex" "$tmp/out"; } \
    && say "planted flat /studio/#{} -> exit 1, offender named" 0 \
    || say "planted flat /studio/#{} -> exit 1, offender named (got $rc)" 1

  # 5 — a .heex hit reds (pins the --include set; dropping *.heex blinds it).
  fresh
  mkdir -p "$tmp/tree/$SCAN_ROOT/live/studio"
  printf '<a href={"/w/#{@ws}/d/#{@ds}/studio/post"}>go</a>\n' \
    >"$tmp/tree/$SCAN_ROOT/live/studio/plant_tpl.html.heex"
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "plant_tpl.html.heex" "$tmp/out"; } \
    && say "planted .heex literal -> exit 1, offender named" 0 \
    || say "planted .heex literal -> exit 1, offender named (got $rc)" 1

  # 6 — a REVIEWED whitelist entry stays exempt (the registry still works).
  fresh; plant "controllers/studio_redirect_controller.ex" '/w/#{ws}/d/#{ds}/studio/post'
  rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "studio-link-lint: PASS" "$tmp/out"; } \
    && say "reviewed whitelist entry -> still exempt, exit 0" 0 \
    || say "reviewed whitelist entry -> still exempt, exit 0 (got $rc)" 1

  # 7 — a SUFFIX-SPOOFED filename does NOT inherit that entry's exemption.
  #     Byte-identical to the case-2 plant; only the filename differs.
  fresh; plant "live/studio/evil_studio_chrome.ex" '/w/#{ws}/d/#{ds}/studio/post'
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "evil_studio_chrome.ex" "$tmp/out"; } \
    && say "suffix-spoofed evil_studio_chrome.ex -> exit 1, NOT exempt" 0 \
    || say "suffix-spoofed evil_studio_chrome.ex -> exit 1, NOT exempt (got $rc)" 1

  # 8 — an ABSENT scan root reds instead of certifying an empty corpus.
  fresh; rm -rf "$tmp/tree/$SCAN_ROOT"; rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "scan root .* does not exist" "$tmp/out"; } \
    && say "absent scan root -> exit 1, 'scan root ... does not exist'" 0 \
    || say "absent scan root -> exit 1, refuses to measure (got $rc)" 1

  if [ "$bad" -ne 0 ]; then
    echo "studio-link-lint --selftest: FAILED ($bad case(s))"
    exit 1
  fi
  echo "studio-link-lint --selftest: PASS"
}

whitelisted() {
  local file="$1"
  local entry
  for entry in "${WL_PATH[@]}"; do
    # Anchored to a whole path SEGMENT tail: an entry exempts exactly the file
    # it names, never a file whose basename merely ENDS with it (a bare *"$entry"
    # let a planted evil_studio_chrome.ex inherit studio_chrome.ex's [SEAM]).
    case "$file" in
      "$entry" | */"$entry") return 0 ;;
    esac
  done
  return 1
}

main() {
  echo "== studio-link-lint: hand-built Studio URLs outside Paths =="

  # Refuse to certify an empty corpus: with no scan root there is nothing to
  # grep, and `grep -r` on a missing dir would otherwise green this gate.
  if [ ! -d "$SCAN_ROOT" ]; then
    echo "FAIL: scan root $SCAN_ROOT does not exist under $REPO_ROOT — refusing"
    echo "      to pass a gate that scanned nothing."
    echo "studio-link-lint: FAILED"
    exit 1
  fi

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
  "") main ;;
  --selftest) selftest ;;
  *)
    echo "studio-link-lint: unknown argument '$1'" >&2
    echo "usage: studio-link-lint.sh [--selftest]" >&2
    exit 2
    ;;
esac
