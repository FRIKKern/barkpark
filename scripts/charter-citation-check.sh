#!/usr/bin/env bash
#
# CHARTER CITATION CHECK — a cited decision must EXIST in the charter it cites.
#
# D135 of the Studio Space-Priority Desk charter rules that a wave citing a
# D-number must land that number in the charter FILE in the same wave. It is
# prose, and prose does not fail a build. It has failed three recorded times:
#
#   wave 8  — the Paper claimed D117-D134 were committed; the charter ended at
#             D116; merged code cited D121/D130/D131, which resolved to nothing.
#   wave 9  — Review transcribed D117-D135 by hand to repair it.
#   wave 10 — the Paper claimed D148-D160 were committed; the charter ended at
#             D147; three of four slices shipped comments citing
#             D148/D149/D151/D152/D155 — plus a `D156b` that is not a decision
#             at all. Repaired by hand at Review, again.
#
# Twice repaired by hand is not a process. This script is the mechanical form of
# D135: it enumerates every charter D-number citation in a declared scope and
# asserts each one resolves to a decision heading in the charter, exiting
# non-zero and NAMING every unresolved citation with its file and line.
#
# It is ADVISORY by construction (D138: a flaky gate everyone learns to ignore
# is worse than an honest script). Run it at Review, or before a wave's PRs.
#
# ── THE CITATION GRAMMAR, DERIVED FROM THE REAL CORPUS ────────────────────────
#
# Read from 380 `charter D<n>` occurrences across the Studio desk surfaces on
# origin/main, not invented:
#
#   ANCHOR      The word `charter` / `charters`, case-insensitive, immediately
#               followed by a D-token. 356 of the 380 occurrences carry NO word
#               before `charter`.
#
#   D-TOKEN     `D<digits>` with an OPTIONAL single lowercase letter suffix.
#               The suffix is part of the identity, never stripped — that is the
#               whole `D156b` class: well-formed, refers to nothing. Real
#               suffixed decisions exist in sibling charters (D36a-d, D41h), so
#               a suffix can never be assumed to be a typo for its stem.
#
#   RUN         After the anchor, further D-tokens joined by `/ , ; & -` an en
#               or em dash, or the word `and`, continue ONE citation run:
#                 `charter D148/D151`   `charter D152–D156`   `charter D113/D114`
#               A DASH RUN IS NOT EXPANDED. `D152–D156` cites its two ENDPOINTS;
#               D153/D154/D155 are not literally written and are not checked
#               here. Stated so nobody reads a green as covering them.
#
#   QUALIFIER   A word immediately before `charter` that is NOT in the neutral
#               stoplist below makes the run FOREIGN — it names another epic's
#               charter and is skipped, counted, and listed under --list:
#                 `Herd charter D275`  `chat-task-hands charter D48`
#                 `TLV charter D22`    `wsc charter D9`
#               Prefixed forms (`PDS-D155`, `connectors D139`) never carry the
#               `charter` anchor and are outside the grammar entirely.
#
#               The stoplist is the FALSE-RED direction on purpose: an
#               unrecognised neutral word yields a loud, named, one-line fix,
#               never a silent pass.
#
# ── WHY SCOPE IS A DECLARED LIST AND NOT A DERIVED RULE ───────────────────────
#
# `charter D<n>` is written unqualified by at least five different epics in the
# same directories. Measured on origin/main: `api/lib/barkpark_web/live/studio/`
# alone carries citations resolving in bp-studio-space-priority (D1-D271),
# bp-studio-chat-excellence (D36a, D48b), bp-chat-tui (D41h, D43h),
# bp-authoring-excellence (D83a) and bp-pds (D605). No property of a path, a
# module or a comment distinguishes them — the file does not name its charter.
#
# So a tree-wide run against one charter is meaningless, and a run against the
# UNION of all charters is worse than meaningless: the wave-10 phantoms
# D148-D160 all resolve in bp-herd-layer-charter.md (which reaches D745), so the
# union would have printed GREEN on the exact defect this script exists to
# catch. Scope is therefore an explicit declaration, and every exclusion below
# names the charter that owns it.
#
# When an unresolved citation IS defined in some other charter, this script says
# which one — so a false red reads as "the scope list needs an entry", not as a
# phantom decision.
#
# ── TASK BODIES ───────────────────────────────────────────────────────────────
#
# The row that commissioned this asks for code comments AND task bodies. The
# committed guard's default corpus is THE TREE ONLY: CI has no Barkpark
# credentials, and a check that silently skips half its corpus when a token is
# absent is the vacuous green this script exists to refuse. Task bodies are
# reachable explicitly, the way scripts/pds-record-parity.sh takes --commits-file:
#
#   env -u BARKPARK_TOKEN bp task list --parent studio-space-priority-desk -o json \
#     > /tmp/bodies.json
#   bash scripts/charter-citation-check.sh --bodies-file /tmp/bodies.json
#
# ── EXIT CODES ────────────────────────────────────────────────────────────────
#
#   0  every in-scope citation resolves
#   1  at least one citation does not resolve (each named with file:line)
#   2  UNCHECKED — the charter is missing, the scope matched no file, or the
#      corpus held zero citations. A verdict over a corpus that was never read
#      is not a pass.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#
#   bash scripts/charter-citation-check.sh                      # default profile
#   bash scripts/charter-citation-check.sh --list               # every citation
#   bash scripts/charter-citation-check.sh --charter P --scope S [--scope S]...
#   bash scripts/charter-citation-check.sh --bodies-file F      # + task bodies
#   bash scripts/charter-citation-check.sh --selftest           # planted-defect proof
#
set -u

CHARTER_DEFAULT=".claude/workflows/bp-studio-space-priority-charter.md"

# The declared scope of the Studio Space-Priority Desk charter.
SCOPE_DEFAULT=(
  "api/lib/barkpark_web/studio"
  "api/lib/barkpark_web/live/studio"
  "api/lib/barkpark_web/components/studio_components"
  "api/lib/barkpark_web/layouts/root.html.heex"
  "api/test/barkpark_web/studio"
  "api/test/barkpark_web/live/studio"
  "scripts/studio-desk-measure.mjs"
  # NOT api/assets: measured on origin/main it holds paper-editor, paper-surface,
  # sheet-grid and chat bundles ONLY — every `charter D<n>` there belongs to
  # another epic. The desk's own CSS lives in root.html.heex, already in scope.
)

# Paths inside the scope above that another charter owns outright. Each entry
# names its owner; an entry without one is a bug.
EXCLUDE_DEFAULT=(
  "claude_chat"          # bp-studio-chat-excellence-charter.md
  "chat_live"            # bp-studio-chat-excellence-charter.md
  "chat_tool_renderer"   # bp-studio-chat-excellence-charter.md
  "studio_chat"          # bp-studio-chat-excellence-charter.md
  "/sheet_grid/"         # bp-pds-charter.md (D605, the USER-CPU cost law)
)

# Words that may precede `charter` without making the run foreign. Observed in
# the corpus, plus the obvious articles and prepositions.
NEUTRAL_BEFORE="the|this|that|these|those|its|it|our|their|a|an|and|or|but|per|is|are|was|were|by|in|on|at|to|of|from|see|read|via|under|over|with|for|as|so|because|behind|since|when|where|which|while|epic|durable|canonical|own|same|full|whole|derivation|confound|note|cf|ie|eg|also|only|still|now|here"

CHARTER=""
LIST=0
BODIES_FILE=""
SELFTEST=0
ROOT=""
declare -a SCOPE=()
declare -a EXCLUDE=()

die() { printf '%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --charter)     CHARTER="${2:-}"; shift 2 || die "--charter needs a path" ;;
    --scope)       SCOPE+=("${2:-}"); shift 2 || die "--scope needs a path" ;;
    --exclude)     EXCLUDE+=("${2:-}"); shift 2 || die "--exclude needs a substring" ;;
    --bodies-file) BODIES_FILE="${2:-}"; shift 2 || die "--bodies-file needs a path" ;;
    --root)        ROOT="${2:-}"; shift 2 || die "--root needs a path" ;;
    --list)        LIST=1; shift ;;
    --selftest)    SELFTEST=1; shift ;;
    -h|--help)     sed -n '2,110p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
  [ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
cd "$ROOT" || die "cannot enter root: $ROOT"

[ -n "$CHARTER" ] || CHARTER="$CHARTER_DEFAULT"
[ ${#SCOPE[@]} -gt 0 ] || SCOPE=("${SCOPE_DEFAULT[@]}")
if [ ${#EXCLUDE[@]} -eq 0 ]; then EXCLUDE=("${EXCLUDE_DEFAULT[@]}"); fi

# ── the decision set the charter DEFINES ─────────────────────────────────────
# Two forms, per the lens ruling in scripts/pds-record-parity.sh: a bold lead at
# the start of a line (optionally bulleted) and a heading whose text OPENS with
# the number. A number merely MENTIONED inside a decision's prose is a reference
# and must not count as a definition.
charter_defs() {
  local f="$1"
  {
    grep -oE '^[[:space:]]*([-*][[:space:]]+)?\*\*D[0-9]+[a-z]?([.,:*]|[[:space:]]|—|-)' "$f"
    grep -oE '^#+[[:space:]]+D[0-9]+[a-z]?([[:space:]]|$)' "$f"
  } 2>/dev/null | grep -oE 'D[0-9]+[a-z]?' | sort -u
}

# ── the citations a corpus MAKES ─────────────────────────────────────────────
# stdin: `path:line:text`. stdout: `path<TAB>line<TAB>Dnnn<TAB>OURS|FOREIGN<TAB>text`
extract_citations() {
  awk -v neutral="$NEUTRAL_BEFORE" '
    {
      # split off path:line, keep the rest verbatim (text may contain colons)
      i = index($0, ":"); if (i == 0) next
      path = substr($0, 1, i-1); rest = substr($0, i+1)
      j = index(rest, ":"); if (j == 0) next
      line = substr(rest, 1, j-1); text = substr(rest, j+1)
      if (line !~ /^[0-9]+$/) next

      s = text
      while (match(s, /[Cc][Hh][Aa][Rr][Tt][Ee][Rr][Ss]?[[:space:]]+[Dd][0-9]+[a-z]?/)) {
        pre = substr(s, 1, RSTART-1)
        r   = substr(s, RSTART)

        # QUALIFIER = the word immediately before the anchor, and ONLY when
        # whitespace alone separates them. `(charter D1)` and `-- charter D1`
        # have NO qualifier: a bracket or a dash ends the phrase, so the word
        # on the far side of it is prose, not an epic name.
        q = pre
        sub(/[[:space:]]+$/, "", q)
        qual = ""
        if (length(q) < length(pre) || pre == "") {
          if (match(q, /[A-Za-z0-9_-]+$/) && RSTART + RLENGTH - 1 == length(q)) \
            qual = substr(q, RSTART, RLENGTH)
        }
        kind = "OURS"
        if (qual != "") {
          lq = tolower(qual)
          if (lq !~ ("^(" neutral ")$")) kind = "FOREIGN"
        }

        # consume the anchored D-token, then every run continuation
        match(r, /^[Cc][Hh][Aa][Rr][Tt][Ee][Rr][Ss]?[[:space:]]+[Dd][0-9]+[a-z]?/)
        tok = substr(r, RSTART, RLENGTH)
        r   = substr(r, RSTART + RLENGTH)
        emit(path, line, tok, kind, text)
        while (match(r, /^[[:space:]]*(\/|,|;|&|-|and)[[:space:]]*[Dd][0-9]+[a-z]?/)) {
          tok = substr(r, RSTART, RLENGTH)
          r   = substr(r, RSTART + RLENGTH)
          emit(path, line, tok, kind, text)
        }
        s = r
      }
    }
    function emit(path, line, tok, kind, text,   d) {
      if (match(tok, /[Dd][0-9]+[a-z]?$/)) {
        d = substr(tok, RSTART, RLENGTH)
        sub(/^d/, "D", d)
        printf "%s\t%s\t%s\t%s\t%s\n", path, line, d, kind, text
      }
    }'
}

run_check() {
  local charter="$1"; shift
  local -a scope=("$@")

  [ -f "$charter" ] || { echo "UNCHECKED: charter not found at $charter" >&2; return 2; }

  local defs cites work
  work="$(mktemp -d)" || return 2
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  defs="$work/defs"; cites="$work/cites"
  charter_defs "$charter" > "$defs"
  if [ ! -s "$defs" ]; then
    echo "UNCHECKED: $charter defines zero decisions under the two definition forms" >&2
    return 2
  fi

  local -a present=()
  local p
  for p in "${scope[@]}"; do [ -e "$p" ] && present+=("$p"); done
  if [ ${#present[@]} -eq 0 ] && [ -z "$BODIES_FILE" ]; then
    echo "UNCHECKED: no scope path exists under $ROOT" >&2
    return 2
  fi

  local -a excl_args=()
  for p in "${EXCLUDE[@]}"; do excl_args+=(-e "$p"); done

  {
    if [ ${#present[@]} -gt 0 ]; then
      if [ ${#excl_args[@]} -gt 0 ]; then
        grep -rnIE '[Cc]harters?[[:space:]]+[Dd][0-9]' "${present[@]}" 2>/dev/null | grep -vF "${excl_args[@]}"
      else
        grep -rnIE '[Cc]harters?[[:space:]]+[Dd][0-9]' "${present[@]}" 2>/dev/null
      fi
    fi
    if [ -n "$BODIES_FILE" ]; then
      [ -f "$BODIES_FILE" ] || { echo "UNCHECKED: --bodies-file $BODIES_FILE not found" >&2; return 2; }
      # one record per line; the file name stands in for the path
      awk -v f="$BODIES_FILE" '{printf "%s:%d:%s\n", f, NR, $0}' "$BODIES_FILE"
    fi
  } | sed $'s/\xe2\x80\x93/-/g; s/\xe2\x80\x94/-/g' | extract_citations | sort -u > "$cites"

  if [ ! -s "$cites" ]; then
    echo "UNCHECKED: zero citations found in scope — a verdict over an unread corpus is not a pass" >&2
    return 2
  fi

  local total ours foreign
  total="$(wc -l < "$cites" | tr -d ' ')"
  ours="$(awk -F'\t' '$4=="OURS"' "$cites" | wc -l | tr -d ' ')"
  foreign="$(awk -F'\t' '$4=="FOREIGN"' "$cites" | wc -l | tr -d ' ')"

  echo "CHARTER CITATION CHECK"
  echo "  charter    : $charter ($(wc -l < "$defs" | tr -d ' ') decisions defined)"
  echo "  scope      : ${present[*]:-(none)}${BODIES_FILE:+ + $BODIES_FILE}"
  echo "  excluded   : ${EXCLUDE[*]}"
  echo "  citations  : $total  ($ours attributed here, $foreign foreign-qualified and skipped)"

  if [ "$ours" -eq 0 ]; then
    echo "UNCHECKED: $total citation(s) found but NONE attributed to this charter —" >&2
    echo "           every one carried a foreign qualifier. A pass over zero attributed" >&2
    echo "           citations is the vacuous green this script exists to refuse." >&2
    return 2
  fi

  if [ "$LIST" -eq 1 ]; then
    echo
    echo "  --- every citation ---"
    awk -F'\t' -v d="$defs" '
      BEGIN { while ((getline l < d) > 0) def[l]=1 }
      { st = ($4=="FOREIGN") ? "skip" : (($3 in def) ? "ok  " : "MISS")
        printf "  %s  %-7s %s:%s\n", st, $3, $1, $2 }' "$cites"
  fi

  local miss="$work/miss"
  awk -F'\t' -v d="$defs" '
    BEGIN { while ((getline l < d) > 0) def[l]=1 }
    $4=="OURS" && !($3 in def)' "$cites" > "$miss"

  if [ ! -s "$miss" ]; then
    echo
    echo "PASS — every one of the $ours attributed citations resolves to a decision in the charter."
    return 0
  fi

  echo
  echo "FAIL — $(wc -l < "$miss" | tr -d ' ') citation(s) resolve to NOTHING in $charter:"
  echo
  local path line d text owner
  while IFS=$'\t' read -r path line d _kind text; do
    owner=""
    if [ -d ".claude/workflows" ]; then
      # The owner probe uses the DEFINITION forms, not a loose mention: a charter
      # that merely writes "D34" in prose does not own D34.
      owner="$(grep -lE "^[[:space:]]*([-*][[:space:]]+)?\*\*${d}([.,:*]|[[:space:]]|-)|^#+[[:space:]]+${d}([[:space:]]|$)" \
                 .claude/workflows/*.md 2>/dev/null \
               | grep -v "$(basename "$charter")" | sed 's|.*/||' | head -4 | tr '\n' ' ')"
    fi
    printf '  %s  %s:%s\n' "$d" "$path" "$line"
    printf '      %s\n' "$(echo "$text" | sed 's/^[[:space:]]*//' | cut -c1-140)"
    if [ -n "$owner" ]; then
      printf '      NOTE: %s is written in another charter (%s) — if that charter owns this\n' "$d" "${owner% }"
      printf '            file, the scope list needs an --exclude entry, not a new decision.\n'
    else
      printf '      %s is written in NO charter. This is the D156b class: well-formed, refers\n' "$d"
      printf '      to nothing. Land the decision, or fix the citation.\n'
    fi
    echo
  done < "$miss"
  return 1
}

# ── selftest: plant the two defect shapes, prove the red, prove the green ─────
selftest() {
  local t rc fails=0
  t="$(mktemp -d)" || return 2
  mkdir -p "$t/.claude/workflows" "$t/api/lib/barkpark_web/studio"
  cat > "$t/.claude/workflows/fixture-charter.md" <<'EOF'
# Fixture charter
## Decisions
- **D1 — first.** body
- **D155 — real.** body
### D200 — heading form
body
EOF
  cat > "$t/api/lib/barkpark_web/studio/clean.ex" <<'EOF'
# resolves (charter D1), a run (charter D155/D200), and a foreign one
# (herd charter D998) that resolves NOWHERE and must still be SKIPPED,
# because its qualifier hands it to another epic.
EOF

  echo "  selftest 1/4  clean corpus -> expect PASS (exit 0)"
  "$0" --root "$t" --charter ".claude/workflows/fixture-charter.md" \
       --scope "api" --exclude "__none__" >"$t/o1" 2>&1; rc=$?
  [ $rc -eq 0 ] || { echo "    FAILED: exit $rc"; sed 's/^/    /' "$t/o1"; fails=1; }

  echo "  selftest 2/4  planted D999 -> expect FAIL (exit 1), named"
  echo '# planted (charter D999) phantom' >> "$t/api/lib/barkpark_web/studio/clean.ex"
  "$0" --root "$t" --charter ".claude/workflows/fixture-charter.md" \
       --scope "api" --exclude "__none__" >"$t/o2" 2>&1; rc=$?
  if [ $rc -ne 1 ] || ! grep -q 'D999' "$t/o2"; then
    echo "    FAILED: exit $rc / D999 not named"; sed 's/^/    /' "$t/o2"; fails=1
  fi

  echo "  selftest 3/4  planted D155b (suffix class) -> expect FAIL (exit 1), named"
  sed -i.bak '/D999/d' "$t/api/lib/barkpark_web/studio/clean.ex"; rm -f "$t"/api/lib/barkpark_web/studio/*.bak
  echo '# planted (charter D155b) suffix phantom' >> "$t/api/lib/barkpark_web/studio/clean.ex"
  "$0" --root "$t" --charter ".claude/workflows/fixture-charter.md" \
       --scope "api" --exclude "__none__" >"$t/o3" 2>&1; rc=$?
  if [ $rc -ne 1 ] || ! grep -q 'D155b' "$t/o3"; then
    echo "    FAILED: exit $rc / D155b not named"; sed 's/^/    /' "$t/o3"; fails=1
  fi

  echo "  selftest 4/4  plants removed -> expect PASS (exit 0)"
  sed -i.bak '/D155b/d' "$t/api/lib/barkpark_web/studio/clean.ex"; rm -f "$t"/api/lib/barkpark_web/studio/*.bak
  "$0" --root "$t" --charter ".claude/workflows/fixture-charter.md" \
       --scope "api" --exclude "__none__" >"$t/o4" 2>&1; rc=$?
  [ $rc -eq 0 ] || { echo "    FAILED: exit $rc"; sed 's/^/    /' "$t/o4"; fails=1; }

  rm -rf "$t"
  if [ $fails -eq 0 ]; then echo "SELFTEST PASS — 4/4"; return 0; fi
  echo "SELFTEST FAIL"; return 1
}

if [ "$SELFTEST" -eq 1 ]; then
  echo "CHARTER CITATION CHECK — selftest"
  selftest
  exit $?
fi

run_check "$CHARTER" "${SCOPE[@]}"
exit $?
