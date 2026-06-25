#!/usr/bin/env bash
# docs-anchors-check.sh — CI link/anchor/header gate for the doc spine
# (strategy §5 + amendment A6).
#
# Blocking checks:
#   1. Every routing-table target in root CLAUDE.md resolves to a file.
#   2. Every docs/INDEX.md entry resolves to a file.
#   3. Every "Code anchors" line in docs/cards/*.md points at an existing
#      path; declared symbols (func/def/defmodule) grep to a real definition
#      with pattern 'func |def |defmodule |^#' (Go + Elixir + headings, A6).
#   4. G1 doc-tier header on every non-attic .md under docs/ and on surface
#      CLAUDE/AGENTS files. Exempt: web/CLAUDE.md (@AGENTS.md import stub),
#      _attic/, docs/cli/fixtures/. YAML-frontmatter files carry the header
#      on the first line after the closing '---'.
#   5. canonical-for values are unique repo-wide (one owner per fact-topic).
#   6. Every .md under _attic/docs-2026-06/ starts with "ARCHIVED" (G3;
#      scoped to docs-2026-06 only — legacy attic predates the convention;
#      .md only — log/xml/json residue would be corrupted by a banner).
#
# WARN-only (never fails the gate):
#   7. Duplication tripwires — prod IP literal, webhook signature literal,
#      dev-token literal outside their canonical owners.
#
# bash 3.2 compatible: no associative arrays, no mapfile.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
WARN=0

fail() { echo "FAIL: $*"; FAIL=1; }
warn() { echo "WARN: $*"; WARN=$((WARN + 1)); }

HEADER_RE='^<!-- doc-tier: (agent|human|cold) \| canonical-for: [A-Za-z0-9._-]+ \| budget: [0-9]+tok -->'

# Return the G1 header line of a file (first line, or first line after a
# leading YAML frontmatter block), or nothing.
header_line() {
  local f="$1" first
  first=$(head -n 1 "$f")
  if printf '%s\n' "$first" | grep -Eq "$HEADER_RE"; then
    printf '%s\n' "$first"
    return 0
  fi
  if [ "$first" = "---" ]; then
    awk 'NR==1{next} /^---$/{getline; while ($0 == "") getline; print; exit}' "$f"
  fi
}

# --- 1. routing-table targets in root CLAUDE.md ----------------------------
echo "== routing-table targets (CLAUDE.md) =="
ROUTE_TARGETS=$(grep -E '^\|' CLAUDE.md | grep -oE '`[A-Za-z0-9._/-]+\.md`' | tr -d '`' | sort -u)
if [ -z "$ROUTE_TARGETS" ]; then
  fail "no routing-table targets found in CLAUDE.md — table missing or reformatted"
fi
for t in $ROUTE_TARGETS; do
  if [ -f "$t" ]; then
    echo "ok:   route -> $t"
  else
    fail "routing-table target does not resolve: $t"
  fi
done

# --- 2. docs/INDEX.md entries ----------------------------------------------
echo "== INDEX entries (docs/INDEX.md) =="
INDEX_ENTRIES=$(grep -oE '[A-Za-z0-9._/-]+\.md' docs/INDEX.md | grep -v '^INDEX\.md$' | sort -u)
for e in $INDEX_ENTRIES; do
  # entries are relative to docs/ (../_attic/... resolves out of docs/)
  if [ -f "docs/$e" ]; then
    echo "ok:   index -> docs/$e"
  else
    fail "INDEX.md entry does not resolve: docs/$e"
  fi
done

# --- 3. card Code anchors ---------------------------------------------------
echo "== card Code anchors =="
for card in docs/cards/*.md; do
  if ! grep -q '^## Code anchors' "$card"; then
    fail "$card has no '## Code anchors' section"
    continue
  fi
  # anchor lines: "- <path> — <description with optional func/def/defmodule symbols>"
  awk '/^## Code anchors/{on=1; next} /^## /{on=0} on && /^- /' "$card" |
  while IFS= read -r line; do
    apath=$(printf '%s\n' "$line" | sed -E 's/^- ([^ ]+) —.*/\1/')
    if [ -z "$apath" ] || [ "$apath" = "$line" ]; then
      echo "FAIL: $card anchor line not parseable: $line"
      continue
    fi
    if [ ! -e "$apath" ]; then
      echo "FAIL: $card anchors missing path: $apath"
      continue
    fi
    # extract symbols declared after func/def/defmodule keywords
    symbols=$(printf '%s\n' "$line" |
      grep -oE '(func|def|defmodule) [A-Za-z_][A-Za-z0-9_.]*[?!]?' |
      awk '{print $2}' || true)
    if [ -z "$symbols" ]; then
      echo "ok:   $card -> $apath (path only)"
      continue
    fi
    for sym in $symbols; do
      if grep -Eq "(func |def |defmodule |^#).*$sym" "$apath"; then
        echo "ok:   $card -> $apath :: $sym"
      else
        echo "FAIL: $card anchor symbol '$sym' not found in $apath (pattern: func |def |defmodule |^#)"
      fi
    done
  done > /tmp/anchors-out.$$ || true
  cat /tmp/anchors-out.$$
  if grep -q '^FAIL:' /tmp/anchors-out.$$; then FAIL=1; fi
  rm -f /tmp/anchors-out.$$
done

# --- 3b. Code anchors in NON-card agent docs (path existence) ---------------
# Cards (3 above) are fully validated, but other docs carrying a '## Code
# anchors' section were UNCHECKED — a stale ref in docs/media/DISCOVERY.md
# (api/lib/barkpark/media/search.ex, a file that moved) sailed past CI. A live
# doc pointing at a deleted path is worse than dead: it misdirects every reader
# (human and AI). Validate that every non-card anchor PATH still exists.
# Handles both formats: bare "- path —" and backticked "- `path` —"; requires
# the " —" separator so prose bullets are skipped, not false-failed.
echo "== Code anchors in non-card docs (path existence) =="
NONCARD_ANCHOR_DOCS=$(grep -rl '^## Code anchors' docs --include='*.md' | grep -v '^docs/cards/' | sort -u)
for doc in $NONCARD_ANCHOR_DOCS; do
  awk '/^## Code anchors/{on=1; next} /^## /{on=0} on && /^- /' "$doc" |
  while IFS= read -r line; do
    apath=$(printf '%s\n' "$line" | sed -E 's/^- *`?([A-Za-z0-9_./-]+)`? *—.*/\1/' | sed 's#/$##')
    case "$apath" in ""|"-"|*" "*) continue ;; esac   # no " —" anchor → prose bullet, skip
    if [ -e "$apath" ]; then
      echo "ok:   $doc -> $apath"
    else
      echo "FAIL: $doc Code-anchor path does not exist: $apath (stale reference — repoint or remove)"
    fi
  done > /tmp/nc-anchors.$$ || true
  cat /tmp/nc-anchors.$$
  if grep -q '^FAIL:' /tmp/nc-anchors.$$; then FAIL=1; fi
  rm -f /tmp/nc-anchors.$$
done

# --- 4. G1 doc-tier header --------------------------------------------------
echo "== G1 doc-tier headers =="
HEADER_FILES=$(
  {
    find docs -name '*.md' -not -path 'docs/cli/fixtures/*'
    find . -maxdepth 2 \( -name 'CLAUDE.md' -o -name 'AGENTS.md' \) \
      -not -path './_attic/*' -not -path './node_modules/*' \
      -not -path './web/CLAUDE.md'
  } | sed 's|^\./||' | sort -u
)
for f in $HEADER_FILES; do
  h=$(header_line "$f")
  if printf '%s\n' "$h" | grep -Eq "$HEADER_RE"; then
    echo "ok:   header $f"
  else
    fail "$f missing G1 doc-tier header (<!-- doc-tier: agent|human|cold | canonical-for: <topic> | budget: <N>tok -->)"
  fi
done

# --- 5. canonical-for uniqueness (repo-wide, non-attic) ----------------------
echo "== canonical-for uniqueness =="
DUPES=$(
  find . -name '*.md' \
    -not -path './_attic/*' -not -path './node_modules/*' \
    -not -path '*/node_modules/*' -not -path './.artifacts/*' \
    -not -path '*/_build/*' -not -path '*/deps/*' |
  while IFS= read -r f; do
    h=$(header_line "$f")
    # `grep` returns 1 for a header-less file (README etc.); `|| true` keeps that
    # benign miss from aborting the substitution when the gate runs under
    # `set -o pipefail` (GitHub Actions' default shell) — a non-match is not an error.
    printf '%s\n' "$h" | { grep -E "$HEADER_RE" || true; } |
      sed -E 's/.*canonical-for: ([A-Za-z0-9._-]+) \|.*/\1/'
  done | sort | uniq -d || true
)
if [ -n "$DUPES" ]; then
  for d in $DUPES; do
    fail "canonical-for '$d' has more than one owner: $(grep -rl "canonical-for: $d " --include='*.md' . | grep -v _attic | grep -v node_modules | tr '\n' ' ')"
  done
else
  echo "ok:   all canonical-for values unique"
fi

# --- 6. ARCHIVED banner (scoped to _attic/docs-2026-06/, .md only — A6) ------
echo "== ARCHIVED banners (_attic/docs-2026-06/) =="
if [ -d "_attic/docs-2026-06" ]; then
  find _attic/docs-2026-06 -name '*.md' | while IFS= read -r f; do
    if head -n 1 "$f" | grep -q '^ARCHIVED'; then
      echo "ok:   banner $f"
    else
      echo "FAIL: $f first line must start with 'ARCHIVED — do not load' (G3)"
    fi
  done > /tmp/banners-out.$$
  cat /tmp/banners-out.$$
  if grep -q '^FAIL:' /tmp/banners-out.$$; then FAIL=1; fi
  rm -f /tmp/banners-out.$$
fi

# --- 7. duplication tripwires (WARN only) ------------------------------------
echo "== duplication tripwires (WARN) =="
tripwire() {
  # $1 = literal, $2 = space-separated allowlist
  local literal="$1" allow="$2" hits f allowed a
  hits=$(grep -rlF "$literal" --include='*.md' . 2>/dev/null |
    sed 's|^\./||' | grep -v '^_attic/' | grep -v node_modules | grep -v '^\.artifacts/' \
    | grep -v '/_build/' | grep -v '/deps/' || true)
  for f in $hits; do
    allowed=0
    for a in $allow; do
      [ "$f" = "$a" ] && allowed=1
    done
    if [ "$allowed" -eq 0 ]; then
      warn "'$literal' appears in $f — canonical owner is elsewhere; prefer a pointer"
    fi
  done
}

# Allowlist rationale: copy-paste-ready examples beat pointers in user-facing
# setup guides and starter templates — those files legitimately repeat the dev
# token / signature shape. README carries the live-demo IP; studio-nav-bug is
# path-frozen history. The tripwire still catches NEW files repeating these.
tripwire '89.167.28.206' \
  "docs/ops/PROD_OPS.md CLAUDE.md docs/ops/bokbasen-go-live.md docs/ops/adding-a-domain.md docs/ops/vercel-dns-connect.md deploy/uptime-kuma/README.md deploy/systemd/README.md README.md docs/studio/user-guide.md docs/ops/studio-nav-bug-2026-04-19.md"
tripwire 'v1=<hex>' \
  "docs/contracts/webhook-realtime.md js/packages/create-barkpark-app/templates/blog-starter/README.md js/packages/create-barkpark-app/templates/website-starter/README.md"
tripwire 'barkpark-dev-token' \
  "docs/auth.md docs/api-v1.md CLAUDE.md api/CLAUDE.md js/CLAUDE.md docs/setup/SETUP.md docs/setup/WINDOWS.md docs/setup/TASK-SYSTEM.md docs/ops/merge-gates.md js/packages/create-barkpark-app/templates/blog-starter/README.md js/packages/create-barkpark-app/templates/website-starter/README.md"

# --- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "docs-anchors-check: FAILED"
  exit 1
fi
echo "docs-anchors-check: PASS (${WARN} warning(s))"
