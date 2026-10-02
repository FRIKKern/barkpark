#!/usr/bin/env bash
# doc-drift-check.sh — catch documentation drift ON THE PR THAT CAUSES IT.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS (task-b97741617bf6c860)
# ─────────────────────────────────────────────────────────────────────────────
#  The repo already had doc gates, but every one of them asks a STRUCTURAL
#  question (does a card's anchor exist, is a canonical-for slug unique, is a
#  byte budget blown). Nothing asked the three questions an ordinary code change
#  actually rots:
#
#    1. do the doc's LINKS AND ROUTES still point at something real?
#       (docs-anchors-check.sh §3c checks `.md` targets only — a link to
#       `scripts/foo.sh`, to `docs/ops/` or to an extensionless docs-site route
#       is invisible to it.)
#    2. did a PLACEHOLDER get left exposed in an active doc?
#    3. does a doc's SUPPORTED, RUNNABLE example still run?
#
#  DIFF-SCOPED, deliberately — the same shape as scripts/format-diff-scope.sh.
#  A finding is YOUR red only when your diff touches the doc that carries it (or
#  touches a file an example declares as a dependency). Inherited drift in docs
#  you did not touch is PRINTED and stays NEUTRAL, because a gate that reds
#  everyone over someone else's merge is the advisory-red problem with a merge
#  button attached. With no base (a push to main), nothing is diff-scoped: the
#  standing debt is printed, the exit code is 0 — main is where the debt is
#  VISIBLE, the PR that touches the file is where it is ENFORCED.
#
#  NOT IN SCOPE, on purpose: prose taste. This gate never judges wording.
#
# ─────────────────────────────────────────────────────────────────────────────
#  USAGE
# ─────────────────────────────────────────────────────────────────────────────
#    scripts/doc-drift-check.sh                 # scope to origin/main...HEAD
#    DOC_DRIFT_BASE=<ref> scripts/doc-drift-check.sh
#    DOC_DRIFT_BASE= scripts/doc-drift-check.sh # no base: report-only, exit 0
#    DOC_DRIFT_ROOT=<dir> ...                   # judge another tree (harness)
#    DOC_DRIFT_FILES="a.md b.md" ...            # explicit scope (harness/CI)
#
#  Exit 0 = no OWNED finding. Exit 1 = an owned finding. Exit 2 = the gate
#  could not tell (a refusal is not a verdict, and it is red).
#
# ─────────────────────────────────────────────────────────────────────────────
#  EXECUTABLE EXAMPLES ARE OPT-IN AND DISPOSABLE
# ─────────────────────────────────────────────────────────────────────────────
#  A fenced block runs ONLY when the line above it carries an explicit
#  allowlist marker:
#
#      <!-- doc-exec: allowlisted -->
#      <!-- doc-exec: allowlisted deps=scripts/foo.sh,api/mix.exs -->
#
#  Every other fenced block — the overwhelming majority, the illustrative ones
#  with `$` prompts, `<placeholders>` and destructive verbs — is NEVER run and
#  NEVER judged. The marked block is executed with `bash -e` in a FRESH mktemp
#  directory as cwd, so a side-effectful example damages nothing but its own
#  sandbox, and a non-zero exit is an owned finding. `deps=` widens the scope
#  rule: touching a listed file re-runs that doc's examples even when the doc
#  itself is untouched, which is the whole point — an example rots when its
#  DEPENDENCY changes, not when its prose does.

# INTERPRETER GUARD — this file uses process substitution, which a POSIX-mode
# bash cannot parse. `sh scripts/doc-drift-check.sh` would run everything above that line and
# then die with the status of the LAST COMPLETED command — a vacuous green from a
# gate that compared NOTHING. Refuse instead, before any check runs. The guard must
# stay POSIX-parseable and must stay FIRST: anything it sits below is code a
# POSIX-mode shell has already run. Enforced by scripts/posix-vacuous-green-census.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "doc-drift-check.sh: needs bash (this gate uses process substitution); run: bash scripts/doc-drift-check.sh${1:+ $1}" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "doc-drift-check.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this gate's process substitution; run: bash scripts/doc-drift-check.sh${1:+ $1}" >&2
    exit 2
    ;;
esac

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
ROOT="${DOC_DRIFT_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"

OWNED=0     # findings the PR's own diff owns  -> exit 1
INHERITED=0 # findings printed, neutral

owned()     { echo "FAIL: $*"; OWNED=$((OWNED + 1)); }
inherited() { echo "note: (inherited, neutral) $*"; INHERITED=$((INHERITED + 1)); }
refuse()    { echo "REFUSED: $*"; exit 2; }

# ── corpus: which files are ACTIVE documentation ────────────────────────────
# A PREDICATE, not a list. `cold`-tier docs and the history/fixture trees below
# are retired or deliberately-frozen text; drift there is not drift.
#   - `_attic/**`, `docs/**/history*`, `*-history.md`   — historical record
#   - `tooling/**/fixtures/**`, `docs/cli/fixtures/**`  — fixtures, which EXIST
#     to carry broken shapes; a gate that reds them cannot have a test suite
#   - `tooling/grip/ledger/**`                          — dated wave evidence
doc_is_active() {
  local rel="$1"
  case "$rel" in
    *.md) ;; *) return 1 ;;
  esac
  case "$rel" in
    _attic/*|*/_attic/*) return 1 ;;
    */fixtures/*|fixtures/*) return 1 ;;
    tooling/grip/ledger/*) return 1 ;;
    *-history.md|docs/*/history/*) return 1 ;;
    node_modules/*|*/node_modules/*|deps/*|_build/*) return 1 ;;
  esac
  [ -f "$ROOT/$rel" ] || return 1
  # cold-tier docs are retired text — G1 header carries the tier.
  head -1 "$ROOT/$rel" | grep -q 'doc-tier: cold' && return 1
  return 0
}

# ── scope ────────────────────────────────────────────────────────────────────
# DOC_DRIFT_FILES (explicit) > git diff vs DOC_DRIFT_BASE > report-only.
SCOPED=""
SCOPE_MODE="report-only"
if [ -n "${DOC_DRIFT_FILES-}" ]; then
  SCOPED="$DOC_DRIFT_FILES"
  SCOPE_MODE="explicit"
elif [ -n "${DOC_DRIFT_BASE-x}" ]; then
  BASE="${DOC_DRIFT_BASE:-origin/main}"
  if git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
    # A merge-base diff: the PR's OWN changes, not everything main moved on.
    SCOPED=$(git -C "$ROOT" diff --name-only --diff-filter=ACMR "$BASE...HEAD" 2>/dev/null) || SCOPED=""
    SCOPE_MODE="diff"
  else
    echo "note: base '$BASE' does not resolve here — report-only, nothing enforced"
  fi
fi
# The touched set is a lookup, not a substring match: `docs/a.md` must not match
# `docs/ab.md`.
touched() {
  local needle="$1" f
  [ "$SCOPE_MODE" = "report-only" ] && return 1
  for f in $SCOPED; do [ "$f" = "$needle" ] && return 0; done
  return 1
}
# An owned finding in `report-only` mode is printed and neutral.
report() {
  local rel="$1"; shift
  if [ "$SCOPE_MODE" = "report-only" ]; then inherited "$rel: $*"; else owned "$rel: $*"; fi
}

# ── the docs to WALK ─────────────────────────────────────────────────────────
ALL_DOCS=$(cd "$ROOT" && git ls-files '*.md' 2>/dev/null)
if [ -z "$ALL_DOCS" ]; then
  ALL_DOCS=$(cd "$ROOT" && find . -name '*.md' -not -path './node_modules/*' -not -path './.git/*' | sed 's|^\./||')
fi
[ -n "$ALL_DOCS" ] || refuse "no markdown files found under $ROOT — the walk cannot be empty"

# ─────────────────────────────────────────────────────────────────────────────
#  CHECK 1 — links and routes resolve
# ─────────────────────────────────────────────────────────────────────────────
# Widens §3c from `.md` targets to EVERY relative target, including the
# extensionless docs-site routes §3c skipped. A route is VALID when any of
# these exists: the literal path, path.md, path/, or path/index.md — that is
# what the docs site serves, so a bare `docs/ops` next to `docs/ops/` is not a
# defect and must not be called one.
route_resolves() {
  local p="$1"
  [ -e "$ROOT/$p" ] && return 0
  [ -e "$ROOT/$p.md" ] && return 0
  [ -e "$ROOT/$p/index.md" ] && return 0
  [ -e "$ROOT/$p/README.md" ] && return 0
  return 1
}
EXTRACT="$(dirname "$SELF")/doc-drift-extract.py"
[ -f "$EXTRACT" ] || refuse "doc-drift-extract.py is missing next to $SELF — the prose/code split cannot be guessed"
SCANTMP=$(mktemp) || refuse "cannot create a temp file"
trap 'rm -f "$SCANTMP"' EXIT

# Placeholder markers are judged in doc-drift-extract.py; a fenced block or an
# inline code span is a QUOTATION and is stripped there before either check
# looks at the line.
echo "== links + routes, exposed placeholders =="
for doc in $ALL_DOCS; do
  doc_is_active "$doc" || continue
  python3 "$EXTRACT" "$ROOT/$doc" > "$SCANTMP" 2>/dev/null || refuse "$doc: extractor failed"
  dir=$(dirname "$doc")
  while IFS=$'\t' read -r kind ln payload; do
    [ -n "$kind" ] || continue
    case "$kind" in
      placeholder)
        if touched "$doc"; then report "$doc" "exposed placeholder at line $ln: $payload"
        else inherited "$doc: exposed placeholder at line $ln"; fi
        ;;
      link)
        lnk=${payload%%#*}
        case "$lnk" in
          ""|http*|mailto:*|/*|\#*|'<'*) continue ;;
          *[\{\$\*]*) continue ;;   # templated targets are not addresses
        esac
        resolved=$(python3 -c 'import posixpath,sys; print(posixpath.normpath(posixpath.join(sys.argv[1],sys.argv[2])))' "$dir" "$lnk" 2>/dev/null)
        [ -n "$resolved" ] || continue
        case "$resolved" in ..*) continue ;; esac  # escapes the repo; not ours to judge
        route_resolves "$resolved" && continue
        if touched "$doc"; then report "$doc" "link/route does not resolve: $lnk (-> $resolved) at line $ln"
        else inherited "$doc: link/route does not resolve: $lnk (-> $resolved) at line $ln"; fi
        ;;
    esac
  done < "$SCANTMP"
done

# ─────────────────────────────────────────────────────────────────────────────
#  CHECK 3 — allowlisted executable examples still run
# ─────────────────────────────────────────────────────────────────────────────
echo "== allowlisted executable examples =="
EXEC_DOCS=0
for doc in $ALL_DOCS; do
  doc_is_active "$doc" || continue
  grep -q '<!-- doc-exec: allowlisted' "$ROOT/$doc" 2>/dev/null || continue
  EXEC_DOCS=$((EXEC_DOCS + 1))
  # deps= widens ownership: a dependency change re-runs the example.
  deps=$(grep -o '<!-- doc-exec: allowlisted[^>]*deps=[^ >]*' "$ROOT/$doc" | sed 's/.*deps=//' | tr ',' '\n' | sort -u)
  owns=0
  touched "$doc" && owns=1
  for d in $deps; do touched "$d" && owns=1; done
  # Extract every marked block. python does the pairing; bash would guess.
  blocks=$(python3 - "$ROOT/$doc" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read().splitlines()
out, i = [], 0
while i < len(src):
    if "<!-- doc-exec: allowlisted" in src[i]:
        j = i + 1
        while j < len(src) and not src[j].startswith("```"):
            j += 1
        if j < len(src):
            k = j + 1
            body = []
            while k < len(src) and not src[k].startswith("```"):
                body.append(src[k]); k += 1
            out.append("\x1f".join([str(j + 2)] + body))
            i = k
    i += 1
print("\x1e".join(out))
PY
)
  [ -n "$blocks" ] || { report "$doc" "carries a doc-exec marker but no fenced block follows it"; continue; }
  idx=0
  while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    idx=$((idx + 1))
    # NOT NUL as the separator: bash cannot hold a NUL in a variable, so the
    # record collapsed to one field and the loop ran zero examples while
    # reporting a clean PASS — a vacuous green with the fence right there.
    ln=${blk%%$'\037'*}
    body=$(printf '%s' "${blk#*$'\037'}" | tr '\037' '\n')
    sandbox=$(mktemp -d) || refuse "cannot create a sandbox for $doc"
    out=$( cd "$sandbox" && DOC_DRIFT_REPO="$ROOT" bash -e -c "$body" 2>&1 ); rc=$?
    rm -rf "$sandbox"
    if [ "$rc" -ne 0 ]; then
      if [ "$owns" = 1 ]; then
        report "$doc" "allowlisted example at line $ln exited $rc"
        printf '%s\n' "$out" | sed 's/^/    | /' | head -20
      else
        inherited "$doc: allowlisted example at line $ln exited $rc"
      fi
    else
      echo "ok:   ran $doc example #$idx (line $ln)"
    fi
    # printf '%s\n', not '%s': a final line with no newline makes `read` return
    # non-zero and bash skips the body — one example silently never ran.
  done < <(printf '%s\n' "$blocks" | tr '\036' '\n')
done

# ── vacuity floor ────────────────────────────────────────────────────────────
# A checker that answers "clean" for every input passes vacuously. Prove the
# walk had a subject before the verdict is believed.
ACTIVE=0
for doc in $ALL_DOCS; do doc_is_active "$doc" && ACTIVE=$((ACTIVE + 1)); done
echo "== corpus =="
echo "ok:   $ACTIVE active docs walked, $EXEC_DOCS carrying allowlisted examples, scope=$SCOPE_MODE"
[ "$ACTIVE" -gt 0 ] || refuse "zero active docs — the corpus predicate matched nothing, so every verdict above is vacuous"

echo "== summary =="
echo "owned findings:     $OWNED"
echo "inherited (neutral): $INHERITED"
if [ "$OWNED" -gt 0 ]; then
  echo "doc-drift-check: FAIL — $OWNED finding(s) in documentation THIS diff touches"
  exit 1
fi
echo "doc-drift-check: PASS"
exit 0
