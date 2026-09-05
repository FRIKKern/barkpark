#!/usr/bin/env bash
# bp-read.sh — run bp and print its body ONLY if bp did not refuse.
#
# THE SHELL HALF of `spd-*`-class reader defect. The parsing idiom
# `d.get("docs") or []` is only two thirds of the disease. The INVOCATION
# pattern throws away the third signal before the parser ever runs:
#
#     bp task get "$1" -o json 2>/dev/null | python3 -c '...'
#     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^
#     stderr discarded ....................|.. and without `set -o pipefail`
#                                          |   the pipeline's status is
#                                          |   python3's, never bp's.
#
# So a `usage` refusal at exit 2 becomes: an empty parse, a swallowed
# traceback, and a loop that iterates zero times. NAME IT: the
# "bp-into-a-pipe" pattern. It is defeated two ways, and both are required:
#
#   1. CAPTURE, do not pipe. Run bp with its stdout redirected to a file (or
#      a variable), CHECK `$?`, and only then feed the file to the parser.
#   2. Check the envelope. Exit status alone misses `bp search`, which prints
#      a failure on stderr and still exits 0 (the sibling producer row).
#
# `set -o pipefail` alone is NOT a fix here: it rescues the exit status but
# leaves stderr in /dev/null, so the operator gets a bare non-zero with no
# `error.code` to act on.
#
# Usage:
#     . "$(dirname "$0")/../lib/bp-read.sh"   # path from scripts/foo.sh
#     body="$(bp_json task get "$id" -o json)" || exit $?
#     n="$(printf '%s' "$body" | python3 -c '...')"
#
# bp_json writes the success body to stdout, and on refusal writes a line
# naming the CODE to stderr and returns bp's own exit status (or 1).

bp_read_sh__die() { printf 'bp-read: %s\n' "$*" >&2; }

# bp_json <bp args...> -> body on stdout, or a named refusal on stderr
bp_json() {
  command -v bp >/dev/null 2>&1 || { bp_read_sh__die "bp is not on PATH"; return 127; }

  local out err rc
  out="$(mktemp)"; err="$(mktemp)"
  bp "$@" >"$out" 2>"$err"; rc=$?

  local body; body="$(cat "$out")"
  local stderr_text; stderr_text="$(cat "$err")"
  rm -f "$out" "$err"

  if [ "$rc" -ne 0 ]; then
    local code
    code="$(printf '%s' "$body" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
e=d.get("error") if isinstance(d,dict) else None
print("%s: %s" % (e.get("code"), e.get("message")) if isinstance(e,dict) else "")' 2>/dev/null)"
    bp_read_sh__die "\`bp $*\` REFUSED (exit $rc)${code:+ — $code}${stderr_text:+ | stderr: $stderr_text}"
    bp_read_sh__die "this is a refusal, NOT an empty result — do not read it as zero"
    return "$rc"
  fi

  if [ -z "$body" ]; then
    bp_read_sh__die "\`bp $*\` exited 0 but printed nothing${stderr_text:+ | stderr: $stderr_text}"
    return 1
  fi

  # Exit 0 is not enough: `bp search` prints a manifest failure on stderr and
  # still exits 0. Check the envelope too.
  if ! printf '%s' "$body" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)          # not JSON: let the caller parse and fail loudly
if not isinstance(d, dict): sys.exit(0)
sys.exit(3 if (d.get("ok", True) is False or "error" in d) else 0)' 2>/dev/null; then
    bp_read_sh__die "\`bp $*\` exited 0 but returned an ERROR envelope: $(printf '%s' "$body" | head -c 300)"
    return 1
  fi

  printf '%s\n' "$body"
}

# bp_json_or_die <bp args...> — same, but ends the script instead of returning.
bp_json_or_die() {
  local body rc
  body="$(bp_json "$@")"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  printf '%s\n' "$body"
}
