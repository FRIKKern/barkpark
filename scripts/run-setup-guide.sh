#!/usr/bin/env bash
# run-setup-guide.sh: run the marked code blocks of a setup guide, in order.
#
# A wrong step in the guide fails when this runs. Usage:
#
#   scripts/run-setup-guide.sh --vars <file> [--doc docs/setup/SELF-HOST.md]
#                              [--path a|b] [--from N] [--list] [--run-dir DIR]
#
# Marker. An HTML comment, which GitHub does not render:
#
#   <!-- run -->            the next fenced block runs on this machine
#   <!-- run vm -->         the next fenced block runs on the VM over ssh
#   <!-- run hook=dns -->   a prose step with no command; the runner runs
#                           <vars dir>/hooks/dns.sh on this machine
#
# --path a runs the markers under a "## Path A" heading and skips those under
# any other "## Path" heading; --path b does the same for Path B. The vars
# templates are scripts/setup-guide/vars.example (A) and vars-b.example (B),
# and scripts/setup-guide/hooks holds the hooks. Markers in other sections run on every path.
# An attribute path=a,b overrides the heading. When text
# follows the marker on the same line and holds an inline code span, the first
# span is the command, for a step whose command sits in a sentence.
#
# Placeholders. <host>, <ip>, <Studio origin> and the like are replaced from the
# vars file before a block runs. The key is the placeholder in lower case with
# spaces as underscores. A value that starts with $( is a command, run once on
# first use, for values such as the VM's IP that exist only after a step.
# Every vars entry is also exported to the blocks. A block with a placeholder
# the vars file does not set fails before it runs.
#
# Secrets. Vars whose key holds SECRET, TOKEN, PASSWORD or KEY are masked in
# every line this prints and every log, as are bp_* tokens, KEY=value lines for
# secret-looking names, --token arguments and passwords in URLs.
#
# Isolation. Blocks run in <run dir>/work with XDG_CONFIG_HOME, the bp install
# directory and ZDOTDIR inside the run dir, so the run never touches your bp
# config or shell files. BARKPARK_TOKEN and BARKPARK_SERVER are unset. ssh and
# scp use a known_hosts file in the run dir and accept a new host key.
#
# The run dir defaults to $TMPDIR/guide-run-<time>, outside the repository,
# because work/ holds the generated settings file with its keys.
# It stops on the first failure and prints the step, the doc line, the exit
# code and the end of the masked log. <run dir>/steps.tsv holds seconds per step.
set -uo pipefail

# The regex below holds a "<(" token. Refuse sh and POSIX mode so the census
# in scripts/posix-vacuous-green-census.sh can see this file needs bash.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "run-setup-guide.sh: needs bash" >&2; exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "run-setup-guide.sh: refuses to run in POSIX mode" >&2; exit 2;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/setup/SELF-HOST.md"
VARS=""
GUIDE_PATH=""
FROM=1
LIST=0
RUN_DIR=""
TAIL_LINES=40

die() { printf 'run-setup-guide: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --doc) DOC="$2"; shift 2 ;;
    --vars) VARS="$2"; shift 2 ;;
    --path) GUIDE_PATH="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

[ -r "$DOC" ] || die "cannot read doc $DOC"
DOC="$(cd "$(dirname "$DOC")" && pwd)/$(basename "$DOC")"
DOC_NAME="$(basename "$DOC")"

# ---------------------------------------------------------------- extract
# One record per step, fields split by \x1f: n, line, where, name, code(base64).
extract() {
  awk -v want="$GUIDE_PATH" '
    function attr(s, k,   m) { if (match(s, k "=[^ ]+")) return substr(s, RSTART + length(k) + 1, RLENGTH - length(k) - 1); return "" }
    function onpath(p,   n, a, i) {
      if (p == "") p = secpath
      if (want == "" || p == "") return 1
      n = split(p, a, ","); for (i = 1; i <= n; i++) if (a[i] == want) return 1
      return 0
    }
    function emit(line, where, name, code,   cmd) {
      steps++
      gsub(/\n$/, "", code)
      printf "%d\x1f%d\x1f%s\x1f%s\x1f", steps, line, where, name
      cmd = "base64 | tr -d \"\\n\""
      printf "%s", code | cmd; close(cmd)
      printf "\n"
    }
    {
      if (infence) {
        if ($0 ~ "^[ ]*" fence "[ ]*$") {
          infence = 0
          if (pending) { emit(pline, pwhere, pname, body); pending = 0 }
          next
        }
        line = $0
        if (indent > 0) sub("^ {0," indent "}", "", line)
        body = body line "\n"
        next
      }
      if (match($0, /^[ ]*(```+|~~~+)/)) {
        fence = substr($0, RSTART, RLENGTH); sub(/^[ ]*/, "", fence)
        indent = RLENGTH - length(fence)
        infence = 1; body = ""
        next
      }
      if ($0 ~ /^## /) secpath = ($0 ~ /^## Path [A-Za-z]([^A-Za-z]|$)/) ? tolower(substr($0, 9, 1)) : ""
      if (match($0, /<!-- run( [^>]*)? -->/)) {
        m = substr($0, RSTART + 8, RLENGTH - 11)
        rest = substr($0, RSTART + RLENGTH)
        p = attr(m, "path"); name = attr(m, "hook")
        where = (name != "") ? "hook" : (m ~ /(^| )vm( |$)/) ? "vm" : "local"
        n = split(m, w, " ")
        for (i = 1; i <= n; i++) if (w[i] != "vm" && w[i] != "local" && w[i] !~ /^(path|hook)=/) {
          printf "run-setup-guide: %s:%d: unknown marker word \"%s\"\n", FILENAME, NR, w[i] > "/dev/stderr"; bad = 1
        }
        if (!onpath(p)) next
        if (where == "hook") { emit(NR, where, name, ""); next }
        if (match(rest, /`[^`]+`/)) { emit(NR, where, name, substr(rest, RSTART + 1, RLENGTH - 2)); next }
        pending = 1; pline = NR; pwhere = where; pname = name
      }
    }
    END { if (pending) { printf "run-setup-guide: %s:%d: marker with no code block after it\n", FILENAME, pline > "/dev/stderr"; bad = 1 } exit bad }
  ' "$DOC"
}

STEPS="$(extract)" || die "the markers in $DOC_NAME do not parse"
[ -n "$STEPS" ] || die "no <!-- run: ... --> markers in $DOC_NAME${GUIDE_PATH:+ for path $GUIDE_PATH}"

decode() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D; }

if [ "$LIST" = 1 ]; then
  while IFS=$'\x1f' read -r n line where name code; do
    printf '%2d  %s:%-4d %-5s %s\n' "$n" "$DOC_NAME" "$line" "$where" \
      "$( [ "$where" = hook ] && echo "hook $name" || decode "$code" | head -n 1)"
  done <<<"$STEPS"
  exit 0
fi

# ---------------------------------------------------------------- vars
[ -n "$VARS" ] || die "--vars <file> is required"
[ -r "$VARS" ] || die "cannot read vars file $VARS"
VARS="$(cd "$(dirname "$VARS")" && pwd)/$(basename "$VARS")"
HOOK_DIR="$(dirname "$VARS")/hooks"

RUN_DIR="${RUN_DIR:-${TMPDIR:-/tmp}/guide-run-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RUN_DIR"/{work,bin,config,zdot,logs}
chmod 700 "$RUN_DIR"
SECRETS="$RUN_DIR/.secrets"
: > "$SECRETS"; chmod 600 "$SECRETS"
VALS="$RUN_DIR/.vals"
: > "$VALS"; chmod 600 "$VALS"

is_secret_key() { case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in *SECRET*|*TOKEN*|*PASSWORD*|*KEY*) return 0 ;; esac; return 1; }

# Raw vars: key<TAB>value, comments and blank lines dropped.
while IFS= read -r l || [ -n "$l" ]; do
  case "$l" in ''|'#'*) continue ;; esac
  k="${l%%=*}"; v="${l#*=}"
  [ "$k" != "$l" ] || die "vars line is not KEY=VALUE: $k"
  printf '%s\t%s\n' "$k" "$v" >> "$VALS"
done < "$VARS"

# Environment for every block.
unset BARKPARK_TOKEN BARKPARK_SERVER BP_TOKEN BP_SERVER
export XDG_CONFIG_HOME="$RUN_DIR/config" BARKPARK_BIN_DIR="$RUN_DIR/bin" ZDOTDIR="$RUN_DIR/zdot"
# Find the real ssh and scp with the run's bin dir off PATH, so a resumed run
# does not wrap its own wrapper.
SYS_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$RUN_DIR/bin" | paste -sd ':' -)"
export PATH="$RUN_DIR/bin:$SYS_PATH"
export GUIDE_RUN_DIR="$RUN_DIR" GUIDE_REPO="$ROOT"
for t in ssh scp; do
  real="$(PATH="$SYS_PATH" command -v "$t")" || die "$t not found"
  cat > "$RUN_DIR/bin/$t" <<EOF
#!/bin/sh
exec "$real" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" \\
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o BatchMode=yes "\$@"
EOF
  chmod 755 "$RUN_DIR/bin/$t"
done

# Resolve a key: literal values as written, $( values run once on first use.
# Resolved values live in a 600 cache file, because resolve runs in subshells.
CACHE="$RUN_DIR/.cache"
[ -f "$CACHE" ] || { : > "$CACHE"; chmod 600 "$CACHE"; }
lookup() { awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; f = 1; exit } END { exit !f }' "$2"; }
resolve() {
  local key="$1" raw v
  if v="$(lookup "$key" "$CACHE")"; then printf '%s' "$v"; return 0; fi
  raw="$(lookup "$key" "$VALS")" || return 1
  case "$raw" in
    '$('*) v="$(bash -c "printf '%s' \"$raw\"" </dev/null)" || return 1
           [ -n "$v" ] || return 1 ;;
    *) v="$raw" ;;
  esac
  printf '%s\t%s\n' "$key" "$v" >> "$CACHE"
  is_secret_key "$key" && printf '%s\n' "$v" >> "$SECRETS"
  printf '%s' "$v"
}

# Export resolved keys, so blocks and hooks see $RG, $host and the like.
export_cache() {
  local k v
  while IFS=$'\t' read -r k v; do
    case "$k" in [A-Za-z_]*) export "$k=$v" ;; esac
  done < "$CACHE"
}

# Literal values resolve now; $( values resolve when a block first needs them.
while IFS=$'\t' read -r k v; do
  case "$v" in '$('*) ;; *) resolve "$k" >/dev/null ;; esac
done < "$VALS"
export_cache

mask() {
  SECRETS_FILE="$SECRETS" perl -pe '
    BEGIN {
      $| = 1;
      @s = ();
      if (open(my $f, "<", $ENV{SECRETS_FILE})) { while (<$f>) { chomp; push @s, $_ if length($_) >= 4 } }
      @s = sort { length($b) <=> length($a) } @s;
    }
    for my $s (@s) { s/\Q$s\E/<masked>/g }
    s/\bbp_[a-z]+_[A-Za-z0-9_-]{12,}/bp_<masked>/g;
    s/^(\s*(?:export\s+)?[A-Z0-9_]*(?:SECRET|_KEY|KEY_|TOKEN|PASSWORD|_KEK|CLOAK)[A-Z0-9_]*=).+/$1<masked>/;
    s/(--token[= ]+)("[^"]*"|\S+)/$1<masked>/g;
    s/(Bearer\s+)\S+/$1<masked>/g;
    s{(://[^:/\s@]+:)[^@\s]+@}{$1<masked>@}g;
  '
}

# Replace <placeholder> with its vars value; print unresolved names on fd 3.
substitute() {
  local code="$1" ph key val out="" missing=""
  while [[ "$code" =~ \<([A-Za-z][A-Za-z0-9\ ._-]*)\> ]]; do
    ph="${BASH_REMATCH[0]}"
    key="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:] ' '[:lower:]_')"
    if val="$(resolve "$key")"; then
      out="$out${code%%"$ph"*}$val"
    else
      out="$out${code%%"$ph"*}$ph"; missing="$missing $ph"
    fi
    code="${code#*"$ph"}"
  done
  printf '%s' "$out$code"
  [ -z "$missing" ] || { printf '%s' "$missing" >&3; return 1; }
}

# ---------------------------------------------------------------- run
TSV="$RUN_DIR/steps.tsv"
[ -s "$TSV" ] || printf 'step\tline\twhere\tseconds\tresult\n' > "$TSV"
printf 'run-setup-guide: %s, run dir %s\n' "$DOC_NAME" "$RUN_DIR"
TOTAL_START=$(date +%s)

while IFS=$'\x1f' read -r n line where name code64; do
  [ "$n" -ge "$FROM" ] || continue
  log="$RUN_DIR/logs/step$(printf '%02d' "$n").log"
  code="$(decode "$code64")"
  if [ "$where" = hook ]; then
    hook="$HOOK_DIR/$name.sh"
    label="hook $name"
  else
    label="$(printf '%s' "$code" | head -n 1)"
  fi
  printf '\n[%d] %s:%d %s: %s\n' "$n" "$DOC_NAME" "$line" "$where" "$label" | mask

  missing=""
  if [ "$where" != hook ]; then
    code="$(substitute "$code" 3>"$RUN_DIR/.missing")" ; rc=$?
    missing="$(cat "$RUN_DIR/.missing")"
    if [ $rc -ne 0 ]; then
      printf 'FAIL step %d at %s:%d: placeholders the vars file does not set:%s\n' "$n" "$DOC_NAME" "$line" "$missing" | mask
      printf '%d\t%d\t%s\t0\tunresolved\n' "$n" "$line" "$where" >> "$TSV"
      exit 1
    fi
  fi

  export_cache
  start=$(date +%s)
  case "$where" in
    local)
      ( cd "$RUN_DIR/work" && bash -eo pipefail -c "$code" ) </dev/null 2>&1 | mask > "$log"; rc=${PIPESTATUS[0]} ;;
    vm)
      target="$(resolve vm_ssh)" || { echo "FAIL step $n: vm step needs vm_ssh in the vars file"; exit 1; }
      printf '%s\n' "$code" | ssh "$target" 'bash -eo pipefail -s' 2>&1 | mask > "$log"; rc=${PIPESTATUS[1]} ;;
    hook)
      if [ ! -r "$hook" ]; then
        printf 'FAIL step %d at %s:%d: prose step with no command, and no hook file %s\n' "$n" "$DOC_NAME" "$line" "$hook"
        printf '%d\t%d\t%s\t0\tno-hook\n' "$n" "$line" "$where" >> "$TSV"
        exit 1
      fi
      ( cd "$RUN_DIR/work" && bash -eo pipefail "$hook" ) </dev/null 2>&1 | mask > "$log"; rc=${PIPESTATUS[0]} ;;
  esac
  secs=$(( $(date +%s) - start ))
  if [ "$rc" -ne 0 ]; then
    printf '%d\t%d\t%s\t%d\tfail(%d)\n' "$n" "$line" "$where" "$secs" "$rc" >> "$TSV"
    printf 'FAIL step %d at %s:%d (%s) exit %d after %ds. Last %d lines of %s:\n' \
      "$n" "$DOC_NAME" "$line" "$where" "$rc" "$secs" "$TAIL_LINES" "$log"
    tail -n "$TAIL_LINES" "$log" | sed 's/^/  | /'
    printf 'Resume after a fix with --from %d --run-dir %s\n' "$n" "$RUN_DIR"
    exit 1
  fi
  printf '%d\t%d\t%s\t%d\tok\n' "$n" "$line" "$where" "$secs" >> "$TSV"
  printf '    ok in %ds\n' "$secs"
done <<<"$STEPS"

printf '\nAll steps passed in %ds. Times per step: %s\n' "$(( $(date +%s) - TOTAL_START ))" "$TSV"
