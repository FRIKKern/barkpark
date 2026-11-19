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
#           b. in every tracked workflow, action, Dockerfile/Containerfile,
#              compose file, deploy file, script, Makefile and mise config, a
#              version-shaped token (N.N or longer) on a line that names an
#              owned tool equals that tool's number in the file's owner. The
#              tool words are the owner files' tool names plus aliases (otp,
#              kerl, node, ...), case-insensitive, also inside names and keys
#              (ERLANG_VERSION, otp-version, hexpm/elixir:). An image tag
#              `name:N.N` is checked on any line. There is no list of ways to
#              write a version: `?=`, `:=`, a space, a colon, a compose key and
#              a mise table all reach the same comparison. A token that does
#              not match passes only through a row: `data` (a test or fixture
#              file, *.test.sh, *_test.*, test/, tests/, fixtures/, with a
#              reason), `pin` (that file and token, and what it pins) or `line`
#              (one line, by the hash of its text, with a reason).
#   NOT SEEN: a version on a line that names no tool and is no image tag, such
#           as a bare `V=26.2.5; asdf install erlang "$V"`. The runtime check
#           after setup is task-1c24786728762c92.
#   Rows that no longer feed anything fail too, so the table cannot rot.
#
# EXIT CODES: 0 clean · 1 problems (each printed with path:line) · 2 refused
# (no git tree, no table, an unreadable version file; never a pass).
#
# bash 3.2 compatible; no YAML library, no network.
# Usage: toolchain-drift-check.sh [--root DIR]
# Its selftest is scripts/toolchain-drift-check.test.sh.

# A POSIX-mode shell would mis-parse this script; refuse before anything runs.
# Enforced by scripts/posix-vacuous-green-census.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "toolchain-drift-check.sh: needs bash (it uses process substitution); run: bash scripts/toolchain-drift-check.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "toolchain-drift-check.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse it; run: bash scripts/toolchain-drift-check.sh" >&2
    exit 2
    ;;
esac

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
    Containerfile|*/Containerfile|Containerfile.*|*/Containerfile.*|*.containerfile) ;;
    compose.y*ml|*/compose.y*ml|compose.*.y*ml|*/compose.*.y*ml|docker-compose*.y*ml|*/docker-compose*.y*ml) ;;
    .mise.toml|*/.mise.toml|mise.toml|*/mise.toml|.mise.*.toml|*/.mise.*.toml|*/mise/config.toml) ;;
    scripts/*.py|scripts/*.mjs|scripts/*.js|scripts/*.cjs|scripts/*.ts|scripts/*.rb) ;;
    *) continue ;;
  esac
  SCAN_FILES="$SCAN_FILES$f
"
done < <(git -C "$ROOT" ls-files -z)

# The table: `<owner> <consumer>` rows; the owner is a version file or `data`.
ROWS="$(awk '!/^[[:space:]]*(#|$)/ && NF && $1 != "pin" && $1 != "line" { print $1 "\t" $2 }' "$ROOT/$TABLE_REL")"
# `pin <file> <token> <what it pins>` and `line <file> <hash> <first words> :: <reason>`
PINS="$(awk '!/^[[:space:]]*#/ && $1 == "pin" { r = $0; sub(/^[ \t]*pin[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", r); print $2 "\t" $3 "\t" r }' "$ROOT/$TABLE_REL")"
LINES="$(awk '!/^[[:space:]]*#/ && $1 == "line" { r = $0; sub(/^[ \t]*line[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", r); print $2 "\t" $3 "\t" r }' "$ROOT/$TABLE_REL")"
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
  VERS="$VERS$(awk -v o="$owner" '!/^[[:space:]]*#/ && NF >= 2 { printf "%s|%s=%s;", o, $1, $2 }' "$ROOT/$owner")"
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

# ── RULE 2b: a version-shaped token on a line that names a tool equals its owner
# A token is N.N or longer (v-prefixed, or glued to letters as in otp27.0). It
# is checked when its line names an owned tool (a word of the owner files, or
# an alias, case-insensitive, also inside names and keys: ERLANG_VERSION,
# otp-version, hexpm/elixir:), or when it is an image tag `name:N.N`. No list
# of assignment forms: `?=`, `:=`, a space, a colon, a compose key and a mise
# table all reach the same comparison. It passes when it equals the owner
# number of a tool its line names, or its file is a `data` row, or a `pin` row
# names it, or a `line` row names its line by hash.
SKIP=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  file="${spec%%$'\t'*}"; rest="${spec#*$'\t'}"; hash="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  words="${rest%% :: *}"; reason="${rest#* :: }"
  [ "$reason" != "$rest" ] && [ -n "${reason// /}" ] \
    || drift "$TABLE_REL: line row \`$file $hash\` gives no reason. End it with \` :: <why the line holds no version>\`."
  if [ ! -f "$ROOT/$file" ]; then drift "$TABLE_REL: line row \`$file $hash\`: $file does not exist. Delete the row."; continue; fi
  found=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    h="$(printf '%s' "${hit#*:}" | git hash-object --stdin)"
    if [ "${h:0:12}" = "$hash" ]; then SKIP="$SKIP$file|${hit%%:*};"; found=1; fi
  done <<<"$(grep -n -F -- "$words" "$ROOT/$file" || true)"
  [ "$found" = 1 ] || drift "$TABLE_REL: line row \`$file $hash ${words}\`: no line of $file starting that way hashes to $hash any more. Re-read the line; delete or re-hash the row."
done <<<"$LINES"
TOOLS="$(cd "$ROOT" && awk '!/^[[:space:]]*#/ && NF >= 2 { print $1 }' $OWNERS | sort -u | tr '\n' ' ')"
ROWS_V="$(awk -F'\t' '{ printf "%s=%s;", $2, $1 }' <<<"$ROWS")"
PINS_V="$(awk -F'\t' '{ printf "%s|%s;", $1, $2 }' <<<"$PINS")"
SCAN_OUT="$(cd "$ROOT" && LC_ALL=C awk -v rows="$ROWS_V" -v vers="$VERS" -v tools="$TOOLS" -v pins="$PINS_V" -v skips="$SKIP" '
  BEGIN {
    nr = split(rows, a, ";"); for (i = 1; i <= nr; i++) if (a[i] != "") { p = index(a[i], "="); row[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    nv = split(vers, a, ";"); for (i = 1; i <= nv; i++) if (a[i] != "") { p = index(a[i], "="); ver[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    np = split(pins, a, ";"); for (i = 1; i <= np; i++) if (a[i] != "") pin[a[i]] = 1
    ns = split(skips, a, ";"); for (i = 1; i <= ns; i++) if (a[i] != "") skip[a[i]] = 1
    # the usual aliases of the tools an owner file can name
    al["otp"] = "erlang"; al["kerl"] = "erlang"; al["kiex"] = "elixir"; al["node"] = "nodejs"; al["nvm"] = "nodejs"; al["go"] = "golang"
    nt = split(tools, a, " "); for (i = 1; i <= nt; i++) if (a[i] != "") word[a[i]] = a[i]
    for (w in al) if (al[w] in word) word[w] = al[w]
  }
  function ipv4(t,    c, i) { split(t, c, "."); for (i = 1; i <= 4; i++) if (c[i] + 0 > 255) return 0; return 1 }
  function base(v) { sub(/-otp-.*$/, "", v); return v }
  function where() { return file ":" n (job == "" ? "" : " (job " job ")") }
  function line(l,    low, w, named, says, s, acc, t, prev, img, o, ok, tl, i, k) {
    if (l ~ /^jobs:[ \t]*$/) injobs = 1; else if (l ~ /^[A-Za-z]/) injobs = 0
    if (injobs && l ~ /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/) { job = l; sub(/^  /, "", job); sub(/:.*/, "", job) }
    if (l ~ /^[ \t]*(#|\/\/|$)/ || ((file "|" n) in skip)) return
    low = tolower(l); named = ""
    for (w in word) if (low ~ ("(^|[^a-z])" w "([^a-z]|$)") && index(" " named " ", " " word[w] " ") == 0) named = named (named == "" ? "" : " ") word[w]
    # A YAML key with no value (`otp:`) or a TOML table header (`[tools.erlang]`)
    # names its tool for the lines under it (a workflow job id does not).
    match(l, /^[ \t]*/); k = RLENGTH
    if (ctx != "" && (cind < 0 ? l ~ /^[ \t]*\[/ : k <= cind)) ctx = ""
    if (named != "" && l ~ /^[ \t]*(-[ \t]*)?[^ \t#:]+:[ \t]*(#.*)?$/ && !(injobs && k == 2)) { ctx = named; cind = k }
    else if (named != "" && l ~ /^[ \t]*\[[^]]*\][ \t]*(#.*)?$/) { ctx = named; cind = -1 }
    else if (named == "") named = ctx
    img = (low ~ /(^|[^a-z])(image|from|docker|podman|container)([^a-z]|$)/)
    o = row[file "#" job]; if (o == "") o = row[file]
    s = l; acc = ""
    while (match(s, /[0-9]+(\.[0-9]+)+/)) {
      prev = substr(s, RSTART - 1, 1); acc = acc substr(s, 1, RSTART - 1)
      t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); acc = acc t
      if (prev ~ /[0-9.]/ || s ~ /^[A-Za-z0-9_]/) continue
      # an IPv4 address is four parts of 0-255; only Erlang has four-part versions
      if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && index(" " named " ", " erlang ") == 0 && ipv4(t)) continue
      if (named == "" && !(prev == ":" && substr(acc, 1, length(acc) - length(t)) ~ /[A-Za-z0-9][A-Za-z0-9._\/-]*:$/ && (img || substr(acc, 1, length(acc) - length(t)) ~ /\/[A-Za-z0-9._-]*:$/))) continue
      if (o == "data") { data[file] = 1; continue }
      if ((file "|" t) in pin) { pinned[file "|" t] = 1; continue }
      if (named == "") { printf "DRIFT|%s: image tag :%s is pinned by no row. Add `pin  %s  %s  <what it pins>`.\n", where(), t, file, t; continue }
      if (o == "") { printf "DRIFT|%s: %s on a line naming %s, and no row ties %s to a version file. Read the version from one, add the row, or pin it.\n", where(), t, named, file; continue }
      ok = 0; says = ""
      k = split(named, tl, " ")
      for (i = 1; i <= k; i++) { if (base(ver[o "|" tl[i]]) == t) ok = 1; says = says (says == "" ? "" : ", ") tl[i] " " (ver[o "|" tl[i]] == "" ? "(none)" : ver[o "|" tl[i]]) }
      if (ok) tied[file] = 1
      else printf "DRIFT|%s: %s on a line naming %s, but %s says %s.\n", where(), t, named, o, says
    }
  }
  NF { file = $0; n = 0; job = ""; injobs = 0; ctx = ""
       while ((getline l < file) > 0) { n++; line(l) }
       close(file) }
  END { for (f in tied) print "TIED|" f; for (f in data) print "DATA|" f; for (k in pinned) print "PINNED|" k }
' <<<"$SCAN_FILES")"
TIED="" DATA="" PINNED=""
while IFS='|' read -r kind rest; do
  case "$kind" in
    DRIFT) drift "$rest" ;;
    TIED) TIED="$TIED$rest
" ;;
    DATA) DATA="$DATA$rest
" ;;
    PINNED) PINNED="$PINNED$rest
" ;;
  esac
done <<<"$SCAN_OUT"

# ── rows that feed nothing ──────────────────────────────────────────────────
while IFS= read -r consumer; do
  [ -z "$consumer" ] || drift "$TABLE_REL: data row \`$consumer\` gives no reason. Add a one-line reason after the path."
done <<<"$(awk '!/^[[:space:]]*#/ && $1 == "data" && NF < 3 { print $2 }' "$ROOT/$TABLE_REL")"
while IFS="$(printf '\t')" read -r file tok what; do
  [ -n "$file" ] || continue
  [ -n "$what" ] || drift "$TABLE_REL: pin row \`$file $tok\` does not say what it pins. Add it after the token."
  if [ ! -f "$ROOT/$file" ]; then drift "$TABLE_REL: pin row \`$file $tok\`: $file does not exist. Delete the row."; continue; fi
  has_line "$file|$tok" "$PINNED" || drift "$TABLE_REL: pin row \`$file $tok\`: $file has no checked $tok any more. Delete the row."
done <<<"$PINS"
while IFS="$(printf '\t')" read -r owner consumer; do
  path="${consumer%%#*}"
  if [ ! -f "$ROOT/$path" ]; then drift "$TABLE_REL: row \`$owner $consumer\`: $path does not exist. Delete the row."; continue; fi
  case "$owner|$path" in
    data\|*)
      case "$path" in
        *.test.sh|*_test.*|test/*|*/test/*|tests/*|*/tests/*|fixtures/*|*/fixtures/*)
          has_line "$path" "$DATA" || drift "$TABLE_REL: data row \`$consumer\` carries no version literal any more. Delete the row." ;;
        *) drift "$TABLE_REL: data row \`$consumer\`: only a test or fixture path (*.test.sh, *_test.*, test/, tests/, fixtures/) may be data. Read the version from its owner instead." ;;
      esac ;;
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
  echo "FAIL - $PROBLEMS problem(s). Every owned tool's version belongs in a version file named by $TABLE_REL."
else
  echo "ok   - every version file is in the table, every setup-beam step reads its owner, every version on a tool's line equals it."
fi
exit $((PROBLEMS > 0))
