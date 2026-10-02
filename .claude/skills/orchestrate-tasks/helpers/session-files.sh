#!/usr/bin/env bash
#
# session-files.sh — a lane's session-owned files are per SESSION, not per lane.
#
# WHY (task-50d7d1a599dd14dd, measured 2026-09-07 in the gates lane). Two
# sessions of ONE lane ran concurrently under one worker id and one set of
# filenames. Nothing errored, because every write was legitimate:
#
#   held.txt   00:35:35Z  a row REMOVED that the other session still held, and
#                         a row ADDED that it had never claimed. A row silently
#                         dropped from a pulse list lapses 30-45 min later
#                         exactly like a row nobody claimed.
#   status.md  ~00:5xZ    WHOLESALE REWRITE, 149 lines -> 94, by a session that
#                         believed it had inherited the lane from a predecessor
#                         it declared dead. The predecessor was alive.
#
# All three collisions that night were detected, and ALL THREE DETECTIONS WERE
# ACCIDENTAL — an mtime that had moved, a line count that SHRANK after an
# append, a file read back at 9,549 bytes where ~20,691 was expected. Zero
# designed checks fired, because none existed. THE ONLY THING THAT HAS EVER
# CAUGHT THIS IS A SIZE THAT MOVED; `verify` below makes that a check instead
# of a coincidence.
#
# THE TWO HALVES, and neither works alone:
#
#   1. PER-SESSION FILENAMES. status.<session>.md, held.<session>.txt,
#      pulse.<session>.log/.pid. Two sessions of one lane cannot name the same
#      file, so a removal from a peer's pulse list is IMPOSSIBLE BY
#      CONSTRUCTION rather than merely reported (task criterion 3: this
#      implementation chose impossibility over an audit log, because an audit
#      log of a silent removal is read only by someone who already suspects the
#      removal happened).
#
#   2. AN INHERITED LANE APPENDS. A filename prevents a NAME collision; it does
#      not prevent a successor that correctly believes itself the sole owner
#      from rewriting its predecessor's file, which is what actually destroyed
#      status.md. `open` therefore refuses to hand out a path whose header
#      names a DIFFERENT session, records every predecessor file's size+digest,
#      and `verify` reds when one of those moved. Quiet is not dead: on the
#      night this was filed the death inference was wrong THREE TIMES OUT OF
#      THREE, every relaunch resting on an inference from SILENCE.
#
# BACKWARD COMPATIBILITY (task criterion 4). Legacy un-suffixed files
# (status.md, held.txt, pulse.log, pulse.pid) are treated as a PREDECESSOR:
# recorded, never read as this session's, never truncated. A claim held under
# the OLD lane-scoped worker id keeps working unchanged — the ledger's fence is
# `worker + epoch` and this script writes no ledger state at all. `bp task
# claim/pulse/close` still take `lead-<lane>`; the SESSION discriminator on the
# claim is the server's (`claim.session`, PR #17293), not this filename.
#
# USAGE
#   session-files.sh open   <lane-dir> <session>   # mkdir, stamp, print PATHS
#   session-files.sh path   <lane-dir> <session> status|held|pulse-log|pulse-pid
#   session-files.sh verify <lane-dir> <session>   # predecessors unchanged?
#   session-files.sh --selftest
#
# EXIT: 0 ok · 1 a NAMED violation (a predecessor moved, or a path is owned by
# another session) · 2 bad arguments / cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
MARKER="bp-lane-session"

die() { echo "session-files.sh: $*" >&2; exit 2; }

_digest() { # <file> -> "<bytes> <sha256>" ; a read that FAILS is never a zero
  local f="$1" sz sum
  [ -f "$f" ] || { echo "CANNOT READ $f"; return 1; }
  sz=$(wc -c < "$f" | tr -d ' ') || { echo "CANNOT READ $f"; return 1; }
  sum=$(shasum -a 256 < "$f" 2>/dev/null | awk '{print $1}')
  [ -n "$sum" ] || sum=$(sha256sum < "$f" 2>/dev/null | awk '{print $1}')
  [ -n "$sum" ] || { echo "CANNOT READ $f"; return 1; }
  echo "$sz $sum"
}

_kindfile() { # <lane-dir> <session> <kind>
  case "$3" in
    status)    echo "$1/status.$2.md" ;;
    held)      echo "$1/held.$2.txt" ;;
    pulse-log) echo "$1/pulse.$2.log" ;;
    pulse-pid) echo "$1/pulse.$2.pid" ;;
    *) die "unknown kind '$3' (status|held|pulse-log|pulse-pid)" ;;
  esac
}

_owner() { # <file> -> the session named in its header, or empty
  [ -f "$1" ] || return 0
  sed -n "1,5p" "$1" | sed -n "s/.*$MARKER: \\([A-Za-z0-9._-][A-Za-z0-9._-]*\\).*/\\1/p" | head -1
}

# Every file in the lane dir that this session does NOT own: other sessions'
# suffixed files AND the legacy un-suffixed shapes.
_predecessors() { # <lane-dir> <session>
  local dir="$1" s="$2" f
  for f in "$dir"/status.*.md "$dir"/held.*.txt "$dir"/pulse.*.log "$dir"/status.md "$dir"/held.txt "$dir"/pulse.log; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      status."$s".md|held."$s".txt|pulse."$s".log) continue ;;
    esac
    echo "$f"
  done
}

cmd_open() {
  local dir="${1:-}" s="${2:-}" kind f owner n=0
  [ -n "$dir" ] && [ -n "$s" ] || die "usage: open <lane-dir> <session>"
  case "$s" in *[!A-Za-z0-9._-]*) die "session id '$s' must be [A-Za-z0-9._-]+" ;; esac
  mkdir -p "$dir" || die "cannot create $dir"

  for kind in status held pulse-log; do
    f=$(_kindfile "$dir" "$s" "$kind")
    owner=$(_owner "$f")
    if [ -f "$f" ] && [ -n "$owner" ] && [ "$owner" != "$s" ]; then
      echo "COLLISION: $f is owned by session '$owner', not '$s' — NOT truncating" >&2
      return 1
    fi
    if [ ! -f "$f" ]; then
      case "$kind" in
        status) printf '<!-- %s: %s -->\n' "$MARKER" "$s" > "$f" ;;
        *)      printf '# %s: %s\n' "$MARKER" "$s" > "$f" ;;
      esac
    fi
  done

  # Record predecessors so `verify` can red on a size that moved.
  : > "$dir/.predecessors.$s"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    printf '%s\t%s\n' "$(_digest "$f")" "$f" >> "$dir/.predecessors.$s"
  done <<EOF
$(_predecessors "$dir" "$s")
EOF

  echo "STATUS=$(_kindfile "$dir" "$s" status)"
  echo "HELD=$(_kindfile "$dir" "$s" held)"
  echo "PULSE_LOG=$(_kindfile "$dir" "$s" pulse-log)"
  echo "PULSE_PID=$(_kindfile "$dir" "$s" pulse-pid)"
  echo "PREDECESSORS=$n"
  if [ "$n" -gt 0 ]; then
    echo "INHERITED: $n file(s) belong to earlier sessions of this lane. APPEND, never rewrite:"
    cut -f2 "$dir/.predecessors.$s" | sed 's/^/  /'
  fi
  return 0
}

cmd_path() {
  local dir="${1:-}" s="${2:-}" kind="${3:-}"
  [ -n "$dir" ] && [ -n "$s" ] && [ -n "$kind" ] || die "usage: path <lane-dir> <session> <kind>"
  _kindfile "$dir" "$s" "$kind"
}

cmd_verify() {
  local dir="${1:-}" s="${2:-}" rec f now bad=0 n=0
  [ -n "$dir" ] && [ -n "$s" ] || die "usage: verify <lane-dir> <session>"
  rec="$dir/.predecessors.$s"
  [ -f "$rec" ] || { echo "session-files.sh: CANNOT READ $rec — run 'open' first" >&2; return 2; }
  while IFS=$'\t' read -r was f; do
    [ -n "${f:-}" ] || continue
    n=$((n + 1))
    now=$(_digest "$f") || { echo "MOVED: $f — CANNOT READ (deleted?), was: $was"; bad=1; continue; }
    if [ "$now" != "$was" ]; then
      echo "MOVED: $f — was [$was], is [$now]"
      bad=1
    fi
  done < "$rec"
  if [ "$bad" -eq 0 ]; then
    echo "OK: $n predecessor file(s) byte-identical since session '$s' opened"
    return 0
  fi
  echo "session-files.sh: a predecessor file changed — a successor overwrote work it did not own" >&2
  return 1
}

selftest() {
  local d rc=0 pass=0 fail=0
  d=$(mktemp -d) || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT
  ok()   { pass=$((pass + 1)); echo "  PASS $*"; }
  bad()  { fail=$((fail + 1)); echo "  FAIL $*"; }

  echo "== arm 1 (criterion 0): two sessions of ONE lane get DIFFERENT paths"
  bash "$SELF" open "$d/lane" s1 > "$d/o1" || bad "open s1 exited $?"
  bash "$SELF" open "$d/lane" s2 > "$d/o2" || bad "open s2 exited $?"
  local st1 st2 h1 h2
  st1=$(sed -n 's/^STATUS=//p' "$d/o1"); st2=$(sed -n 's/^STATUS=//p' "$d/o2")
  h1=$(sed -n 's/^HELD=//p' "$d/o1");    h2=$(sed -n 's/^HELD=//p' "$d/o2")
  [ "$st1" != "$st2" ] && [ "$h1" != "$h2" ] && ok "status and held paths differ ($(basename "$st1") vs $(basename "$st2"))" \
    || bad "paths collided: $st1 / $st2"

  echo "== arm 2 (criterion 3): a removal from a PEER's pulse list is impossible by construction"
  printf 'task-aaa\ntask-bbb\n' >> "$h1"
  printf 'task-ccc\n' >> "$h2"
  # s2 rewrites ITS OWN held file wholesale — the exact act that destroyed held.txt.
  printf '# %s: s2\ntask-ccc\n' "$MARKER" > "$h2"
  grep -q 'task-aaa' "$h1" && grep -q 'task-bbb' "$h1" \
    && ok "s2's wholesale rewrite left both of s1's rows in place" \
    || bad "s1 lost a row to s2's rewrite"
  grep -q 'task-aaa' "$h2" && bad "s2's file swallowed s1's rows" || ok "s2's file holds only its own row"

  echo "== arm 3 (criterion 5): an INHERITED start does not truncate a predecessor"
  local before after
  printf 'P0 arming record\nboth-directions gate proof\nfiled-rows note\n' >> "$st1"
  before=$(shasum -a 256 < "$st1" | awk '{print $1}')
  bash "$SELF" open "$d/lane" s3 > "$d/o3" || bad "open s3 exited $?"
  after=$(shasum -a 256 < "$st1" | awk '{print $1}')
  [ "$before" = "$after" ] && ok "predecessor status file byte-identical ($before)" \
    || bad "predecessor status changed: $before -> $after"
  grep -q '^INHERITED:' "$d/o3" && ok "the inheriting session is TOLD it inherited" || bad "no INHERITED banner"
  grep -q "$(basename "$st1")" "$d/o3" && ok "the banner names the predecessor file" || bad "banner does not name $st1"

  echo "== arm 4 (the alarm): verify REDS when a predecessor's size moves — and is SILENT when it does not"
  bash "$SELF" verify "$d/lane" s3 > "$d/v1" 2>&1 && ok "verify exits 0 while nothing moved" || bad "verify false-alarmed: $(cat "$d/v1")"
  grep -q '^OK:' "$d/v1" && ok "the quiet verdict is a printed OK, not an empty read" || bad "no OK line"
  # 149 lines -> 94: the 2026-09-07 shape.
  printf '<!-- %s: s1 -->\nrewritten by a successor\n' "$MARKER" > "$st1"
  if bash "$SELF" verify "$d/lane" s3 > "$d/v2" 2>&1; then bad "verify stayed green after a wholesale rewrite"
  else grep -q "^MOVED: $st1" "$d/v2" && ok "verify NAMES the file that moved" || bad "verify red but did not name it: $(cat "$d/v2")"; fi

  echo "== arm 5 (criterion 4, backward compat): a LEGACY un-suffixed file is a predecessor, never truncated"
  mkdir -p "$d/legacy"
  printf 'old lane-scoped status, no session header\n' > "$d/legacy/status.md"
  printf 'task-old\n' > "$d/legacy/held.txt"
  before=$(shasum -a 256 < "$d/legacy/status.md" | awk '{print $1}')
  bash "$SELF" open "$d/legacy" s9 > "$d/o9" || bad "open over a legacy dir exited $?"
  after=$(shasum -a 256 < "$d/legacy/status.md" | awk '{print $1}')
  [ "$before" = "$after" ] && ok "legacy status.md untouched" || bad "legacy status.md was rewritten"
  grep -q 'task-old' "$d/legacy/held.txt" && ok "legacy held.txt still holds its row" || bad "legacy held.txt lost its row"
  grep -q '^PREDECESSORS=2$' "$d/o9" && ok "both legacy files counted as predecessors" || bad "predecessor count wrong: $(grep '^PREDECESSORS=' "$d/o9")"

  echo "== arm 6 (control): reopening MY OWN session is allowed — the guard is not a blanket refusal"
  printf 'my own note\n' >> "$st2"
  bash "$SELF" open "$d/lane" s2 > /dev/null && ok "s2 can reopen its own files" || bad "s2 refused its own files"
  grep -q 'my own note' "$st2" && ok "reopen did not truncate my own file" || bad "reopen truncated my own file"

  echo "== arm 7 (control): a path whose header names ANOTHER session is REFUSED, not truncated"
  printf '<!-- %s: sX -->\nsX content\n' "$MARKER" > "$d/lane/status.s7.md"
  if bash "$SELF" open "$d/lane" s7 > "$d/o7" 2>"$d/e7"; then bad "open took a file owned by sX"
  else grep -q '^COLLISION:' "$d/e7" && ok "COLLISION refusal printed" || bad "refused without a COLLISION line"; fi
  grep -q 'sX content' "$d/lane/status.s7.md" && ok "the refused file kept its bytes" || bad "the refused file was truncated"

  echo
  echo "session-files.sh selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || rc=1
  return $rc
}

case "${1:---selftest}" in
  --selftest|selftest) selftest ;;
  open)   shift; cmd_open "$@" ;;
  path)   shift; cmd_path "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  -h|--help) sed -n '1,60p' "$SELF" ;;
  *) die "unknown command '$1' (open|path|verify|--selftest)" ;;
esac
