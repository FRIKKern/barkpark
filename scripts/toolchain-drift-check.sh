#!/usr/bin/env bash
# toolchain-drift-check.sh — an Erlang or Elixir version is written in a version
# file and nowhere else.
#
# CI must run the runtime production runs. Version files in asdf format hold
# the numbers, and scripts/toolchain-owners.tsv says which file owns which
# consumer:
#
#   .tool-versions               the content server (asdf on the box reads it)
#   deploy/image.tool-versions   the release images (cloud/ and api/ Dockerfile)
#   tools/format.tool-versions   the formatter the format gate measures
#
# Everything is discovered from `git ls-files -z`, never from a watch list.
#
#   RULE 1  every tracked `.tool-versions` / `*.tool-versions`, at any depth, is
#           in the table: an owner, or a consumer whose erlang line equals its
#           owner's. Any other one fails, named.
#   RULE 2  every other file READS its version from its owner:
#           a. an erlef/setup-beam step (workflow or composite action) has
#              `version-file: <owner>` and `version-type: strict`;
#           b. every tracked workflow, action, Dockerfile, deploy file and
#              script is scanned for Erlang/Elixir version forms (setup-beam
#              keys, matrix axes, images, asdf/mise installs, *_VERSION
#              values, dotted values of any name with erlang/elixir/otp in it,
#              `Elixir 1.x` / `Erlang/OTP 2x` strings, `otp27-ex1.18` keys). A
#              literal that cannot be avoided (an image tag, an install
#              default) is compared with its file's owner row and fails on any
#              difference; a literal with no owner row fails. A `data` row
#              marks a file whose literals are test data or past check names:
#              those pass, but an install, image or *_VERSION form there fails.
#   Rows that no longer feed anything fail too, so the table cannot rot.
#
# EXIT CODES: 0 clean · 1 problems (each printed with path:line) · 2 refused
# (no git tree, no table, an unreadable version file; never a pass).
#
# bash 3.2 compatible; no YAML library, no network.
# Usage: toolchain-drift-check.sh [--root DIR]
# Its selftest is scripts/toolchain-drift-check.test.sh.

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --check) shift ;;
    *) echo "usage: $(basename "$SELF") [--root DIR]" >&2; exit 2 ;;
  esac
done

TABLE_REL="scripts/toolchain-owners.tsv"
PROBLEMS=0

refuse() { echo "REFUSAL: $*" >&2; exit 2; }
drift() { PROBLEMS=$((PROBLEMS + 1)); printf 'DRIFT  %s\n' "$*"; }
has_line() { grep -q -x -F -- "$1" <<<"$2"; }

# tv_get <file> <tool> -> the version on the `<tool> <version>` line ("" if none)
tv_get() { awk -v t="$2" '$1 == t && $2 !~ /^#/ { print $2; exit }' "$1"; }

# ── discovery ────────────────────────────────────────────────────────────────
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || refuse "$ROOT is not a git work tree; discovery reads \`git ls-files -z\`"
[ -f "$ROOT/$TABLE_REL" ] || refuse "no owner table at $TABLE_REL"

TV_FILES="" BEAM_FILES="" SCAN_FILES=""
while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  case "/$f" in */.tool-versions|*.tool-versions) TV_FILES="$TV_FILES$f
"; continue ;; esac
  case "$f" in
    *.md|scripts/toolchain-drift-check.sh|scripts/toolchain-drift-check.test.sh) continue ;;
    .github/workflows/*.yml|.github/workflows/*.yaml|.github/actions/*.yml|.github/actions/*.yaml)
      BEAM_FILES="$BEAM_FILES$f
" ;;
    deploy/*|*.sh|*.bash|Makefile|*/Makefile|*.mk|Dockerfile|*/Dockerfile|Dockerfile.*|*/Dockerfile.*|*.Dockerfile|*.dockerfile) ;;
    scripts/*.py|scripts/*.mjs|scripts/*.js|scripts/*.cjs|scripts/*.ts|scripts/*.rb) ;;
    *) continue ;;
  esac
  SCAN_FILES="$SCAN_FILES$f
"
done < <(git -C "$ROOT" ls-files -z)

# The table: `<owner> <consumer>` rows; the owner is a version file or `data`.
ROWS="$(awk '!/^[[:space:]]*(#|$)/ && NF { print $1 "\t" $2 }' "$ROOT/$TABLE_REL")"
[ -n "$ROWS" ] || refuse "$TABLE_REL has no rows"
OWNERS="$(awk -F'\t' '$1 != "data" { print $1 }' <<<"$ROWS" | sort -u)"

echo "VERSION FILES"
VERS=""
while IFS= read -r owner; do
  case "$owner" in *.tool-versions) ;; *) refuse "$TABLE_REL names owner '$owner': an owner is a *.tool-versions file or \`data\`" ;; esac
  [ -f "$ROOT/$owner" ] || refuse "$owner is named by $TABLE_REL but does not exist"
  erl="$(tv_get "$ROOT/$owner" erlang)"; ex="$(tv_get "$ROOT/$owner" elixir)"
  [ -n "$erl" ] || refuse "$owner has no \`erlang <version>\` line"
  [ -n "$ex" ] || refuse "$owner has no \`elixir <version>\` line"
  printf '  %-28s erlang %-12s elixir %s\n' "$owner" "$erl" "$ex"
  VERS="$VERS$owner|erlang=$erl;$owner|elixir=$ex;"
done <<<"$OWNERS"
printf '  scanned: %s version file(s), %s workflow/action file(s), %s other file(s)\n\n' \
  "$(grep -c . <<<"$TV_FILES" || true)" "$(grep -c . <<<"$BEAM_FILES" || true)" "$(grep -c . <<<"$SCAN_FILES" || true)"

# ── RULE 1: every version file is in the table ──────────────────────────────
CONSUMERS="$(cut -f2 <<<"$ROWS")"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! has_line "$f" "$CONSUMERS"; then
    has_line "$f" "$OWNERS" \
      || drift "$f: a version file $TABLE_REL does not name. asdf would read it in that directory; add its row or delete it."
    continue
  fi
  owner="$(awk -F'\t' -v c="$f" '$2 == c { print $1; exit }' <<<"$ROWS")"
  want="$(tv_get "$ROOT/$owner" erlang)"; got="$(tv_get "$ROOT/$f" erlang)"
  [ "$got" = "$want" ] || drift "$f: erlang ${got:-missing}, but $owner says $want."
done <<<"$TV_FILES"

# ── RULE 2a: each setup-beam step reads its owner ───────────────────────────
owner_of() { # owner_of <file> <job> -> the job row, else the file row
  awk -F'\t' -v j="$1#$2" -v w="$1" '$2 == j { o = $1; exit } $2 == w && o == "" { o = $1 } END { print o }' <<<"$ROWS"
}
STEPS="$(cd "$ROOT" && awk '
  function ind(s) { match(s, /^ */); return RLENGTH }
  function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s)
                    gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  function emit() { printf "%s|%d|%s|%s|%s|%s|%d\n", file, start, job, vf, vt, lit, litline; instep = 0 }
  function line(l) {
    if (l ~ /^jobs:[[:space:]]*$/) injobs = 1
    else if (l ~ /^[A-Za-z]/) injobs = 0
    if (injobs && l ~ /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/) { if (instep) emit(); job = l; sub(/^  /, "", job); sub(/:.*/, "", job) }
    if (instep && l !~ /^[[:space:]]*(#.*)?$/) {
      if (ind(l) < k) emit()
      else {
        sub(/^[[:space:]]+/, "", l)
        if (l ~ /^version-file:/) vf = val(l)
        else if (l ~ /^version-type:/) vt = val(l)
        else if (l ~ /^(otp|elixir)-version:/) { key = l; sub(/:.*/, "", key); if (lit == "") litline = n; lit = lit (lit == "" ? "" : ",") key }
      }
    }
    if (!instep && l ~ /uses:[[:space:]]*["\047]?erlef\/setup-beam@/) { instep = 1; start = n; k = index(l, "uses:") - 1; vf = ""; vt = ""; lit = ""; litline = 0 }
  }
  NF { file = $0; n = 0; job = ""; injobs = 0; instep = 0
       while ((getline l < file) > 0) { n++; line(l) }
       close(file); if (instep) emit() }
' <<<"$BEAM_FILES")"
FED=""
while IFS='|' read -r wf line job vf vt lit litline; do
  [ -n "$wf" ] || continue
  want="$(owner_of "$wf" "$job")"
  if [ -z "$want" ] || [ "$want" = data ]; then
    drift "$wf:$line${job:+ (job $job)}: a setup-beam step with no version-file row in $TABLE_REL. Add the row naming the file it must read."
    continue
  fi
  if awk -F'\t' -v c="$wf#$job" '$2 == c { f = 1 } END { exit !f }' <<<"$ROWS"; then FED="$FED$wf#$job
"; else FED="$FED$wf
"; fi
  [ -z "$lit" ] || drift "$wf:$litline${job:+ (job $job)}: names a version itself ($lit). Use \`version-file: $want\` and \`version-type: strict\`."
  [ "$vt" = strict ] || drift "$wf:$line${job:+ (job $job)}: \`version-type: strict\` is missing; setup-beam refuses a version file without it."
  case "$vf" in
    "$want"|*/"$want") : ;;
    "") drift "$wf:$line${job:+ (job $job)}: no \`version-file:\`; it must read $want." ;;
    *) drift "$wf:$line${job:+ (job $job)}: reads $vf, but $TABLE_REL says $want." ;;
  esac
done <<<"$STEPS"

# ── RULE 2b: every literal version is tied to its owner and equal to it ─────
ROWS_V="$(awk -F'\t' '{ printf "%s=%s;", $2, $1 }' <<<"$ROWS")"
SCAN_OUT="$(cd "$ROOT" && awk -v rows="$ROWS_V" -v vers="$VERS" '
  BEGIN {
    nr = split(rows, a, ";"); for (i = 1; i <= nr; i++) if (a[i] != "") { p = index(a[i], "="); row[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    nv = split(vers, a, ";"); for (i = 1; i <= nv; i++) if (a[i] != "") { p = index(a[i], "="); ver[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    Q = "[\"\047]?"
    RE_KEY  = "(otp|elixir)-version[ \t]*:[ \t]*" Q "[^ \t\"\047#]*"
    RE_AXIS = "^[ \t]*-?[ \t]*(otp|elixir|erlang)[ \t]*:[ \t]*(\\[[^]]*\\]|" Q "[0-9][^ \t\"\047#]*)"
    RE_IMG  = "(elixir|erlang):[0-9][^ \t\"\047]*"
    RE_MGR  = "(asdf|mise)[ \t]+[a-z]+([ \t]+-[-a-z]+)*[ \t]+(erlang|elixir)[ \t@]+" Q "[0-9][0-9.]*(-otp-[0-9]+)?([ \t\"\047;|&)]|$)"
    NAME    = "[A-Za-z_]*([Ee][Rr][Ll][Aa][Nn][Gg]|[Ee][Ll][Ii][Xx][Ii][Rr]|[Oo][Tt][Pp])[A-Za-z0-9_]*"
    END_V   = "(-otp-[0-9]+)?([^A-Za-z0-9.-]|$)"
    RE_VER  = "[A-Z_]*(ERLANG|ELIXIR|OTP)[A-Z_]*VERSION[ \t]*(=|:-|:)[ \t]*" Q "[0-9][0-9.]*" END_V
    RE_VAR  = NAME "[ \t]*(=|:-|:)[ \t]*" Q "[0-9]+\\.[0-9][0-9.]*" END_V
    RE_TV   = "(^|[^A-Za-z0-9_./-])(erlang|elixir)[ \t]+" Q "v?[0-9]+\\.[0-9][^ \t\"\047)]*"
    RE_CAP  = "Erlang/OTP[ \t]*[0-9]+(\\\\?\\.[0-9]+)*|(Elixir|OTP)[ \t-]+v?[0-9]+(\\\\?\\.[0-9]+)+|[0-9]-otp-[0-9]+"
    RE_CKEY = "(otp|-)2[0-9]\\.[0-9][0-9.]*-(ex)?1\\.[0-9]+(\\.[0-9x]+)?"
  }
  function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
  function num(s) { return match(s, /[0-9]+(\\?\.[0-9]+)*/) ? substr(s, RSTART, RLENGTH) : "" }
  function tok(s) { sub(/^[ \t"\047]+/, "", s); sub(/[^0-9A-Za-z.+_\\-].*$/, "", s); return s }
  function after(m, re) { return match(m, re) ? substr(m, RSTART + RLENGTH) : "" }
  function norm(t, v) { gsub(/\\/, "", v); sub(/^[vV]/, "", v); sub(/^OTP-/, "", v); if (t == "elixir") sub(/-otp-.*$/, "", v); return v }
  function bad(m) { if (!said) printf "DRIFT|%s:%d%s: %s\n", file, n, (job == "" ? "" : " (job " job ")"), m; said = 1 }
  function lit(kind, t, v,    o, a, b) {
    o = row[file "#" job]; if (o == "") o = row[file]
    if (o == "data") { if (kind == "pin") bad("installs or selects " t " " v ", but the table lists this file as data"); else data[file] = 1; return }
    if (o == "") { bad("a literal " t " version (" v ") that no row in the table ties to a version file. Read it from the file, or add the row."); return }
    a = norm(t, v); b = norm(t, ver[o "|" t])
    if (kind == "data" && t == "erlang" && a !~ /\./) sub(/\..*$/, "", b)
    if (a == "" || a != b) bad(t " " v ", but " o " says " ver[o "|" t] "."); else tied[file] = 1
  }
  function scan(s, re, form,    m) {
    while (match(s, re)) { m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); hit(form, m) }
  }
  function hit(form, m,    t, v, rest) {
    if (form == "key") { t = (m ~ /^otp/) ? "erlang" : "elixir"; v = tok(after(m, ":")); if (num(v) == "") bad("names " t " through " m " with no number to compare; read the version file."); else lit("pin", t, v) }
    else if (form == "axis") { t = (m ~ /otp|erlang/) ? "erlang" : "elixir"; rest = after(m, ":"); while (match(rest, /[0-9]+(\.[0-9x]+)*/)) { lit("data", t, substr(rest, RSTART, RLENGTH)); rest = substr(rest, RSTART + RLENGTH) } }
    else if (form == "img") { t = (m ~ /^elixir/) ? "elixir" : "erlang"; lit("pin", t, num(after(m, ":"))); if (m ~ /-erlang-[0-9]/) lit("pin", "erlang", num(after(m, "-erlang-"))) }
    else if (form == "mgr") { v = after(m, "(asdf|mise)[ \t]+[a-z]+([ \t]+-[-a-z]+)*[ \t]+"); t = (v ~ /^erlang/) ? "erlang" : "elixir"; lit("pin", t, tok(after(v, "^(erlang|elixir)[ \t@]+"))) }
    else if (form == "ver" || form == "var") { t = (tolower(m) ~ /elixir/) ? "elixir" : "erlang"; lit(form == "ver" ? "pin" : "data", t, tok(after(m, "(=|:-|:)[ \t]*"))) }
    else if (form == "tv") { t = (m ~ /erlang/) ? "erlang" : "elixir"; lit("data", t, tok(after(m, "(erlang|elixir)[ \t]+"))) }
    else if (form == "cap") { t = (m ~ /^Elixir/) ? "elixir" : "erlang"; lit("data", t, num(m ~ /-otp-/ ? after(m, "-otp-") : m)) }
    else if (form == "ckey") { lit("data", "erlang", num(m)); lit("data", "elixir", num(after(m, "[0-9]-(ex)?"))) }
  }
  function line(l) {
    if (l ~ /^jobs:[ \t]*$/) injobs = 1; else if (l ~ /^[A-Za-z]/) injobs = 0
    if (injobs && l ~ /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/) { job = l; sub(/^  /, "", job); sub(/:.*/, "", job) }
    if (l ~ /^[ \t]*(#|$)/) return
    said = 0
    if (pend) { if (ind(l) <= pind) pend = 0; else if (l ~ /^[ \t]*-[ \t]*["\047]?[0-9]/) lit("data", pendt, num(l)) }
    if (l ~ /^[ \t]*-?[ \t]*(otp|elixir|erlang)[ \t]*:[ \t]*$/) { pend = 1; pind = ind(l); pendt = (l ~ /otp|erlang/) ? "erlang" : "elixir" }
    scan(l, RE_KEY, "key"); scan(l, RE_MGR, "mgr"); scan(l, RE_VER, "ver"); scan(l, RE_VAR, "var"); scan(l, RE_IMG, "img")
    if (match(l, RE_AXIS)) hit("axis", substr(l, RSTART, RLENGTH))
    scan(l, RE_TV, "tv"); scan(l, RE_CAP, "cap"); scan(l, RE_CKEY, "ckey")
  }
  NF { file = $0; n = 0; job = ""; injobs = 0; pend = 0
       while ((getline l < file) > 0) { n++; line(l) }
       close(file) }
  END { for (f in tied) print "TIED|" f; for (f in data) print "DATA|" f }
' <<<"$SCAN_FILES")"
TIED="" DATA=""
while IFS='|' read -r kind rest; do
  case "$kind" in
    DRIFT) drift "$rest" ;;
    TIED) TIED="$TIED$rest
" ;;
    DATA) DATA="$DATA$rest
" ;;
  esac
done <<<"$SCAN_OUT"

# ── rows that feed nothing ──────────────────────────────────────────────────
while IFS="$(printf '\t')" read -r owner consumer; do
  path="${consumer%%#*}"
  if [ ! -f "$ROOT/$path" ]; then drift "$TABLE_REL: row \`$owner $consumer\`: $path does not exist. Delete the row."; continue; fi
  case "$owner|$path" in
    data\|*) has_line "$path" "$DATA" || drift "$TABLE_REL: data row \`$consumer\` carries no version literal any more. Delete the row." ;;
    *\|.github/workflows/*|*\|.github/actions/*)
      has_line "$consumer" "$FED" || drift "$TABLE_REL: row \`$owner $consumer\` feeds no setup-beam step. Delete the row." ;;
    *\|*.tool-versions) : ;;
    *)
      if ! has_line "$path" "$TIED" && ! grep -q -F -- "$owner" "$ROOT/$path"; then
        drift "$TABLE_REL: row \`$owner $consumer\`: $path neither reads $owner by path nor carries a version equal to it."
      fi ;;
  esac
done <<<"$ROWS"

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "FAIL - $PROBLEMS problem(s). Every Erlang/Elixir version belongs in a version file named by $TABLE_REL."
else
  echo "ok   - every version file is in the table, every consumer reads its owner, every literal equals it."
fi
exit $((PROBLEMS > 0))
