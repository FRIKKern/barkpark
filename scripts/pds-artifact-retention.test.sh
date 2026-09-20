#!/usr/bin/env bash
#
# pds-artifact-retention.test.sh — hermetic matrix for the KEEP-N retention verb.
#
# NOTHING HERE TOUCHES A REAL /tmp PATH. Every arm builds its own root under
# mktemp -d, plants its own parked full-export store beside the run-scoped
# directories, and points the subject at it with --root / PDS_FULL_EXPORT_DIR.
# No export is fired, no network is reached, no credential is read.
#
# THE TWO ARMS THAT MAKE THE REST WORTH RUNNING are 9 and 10: the SAME fixture,
# once against the shipped script and once against a copy with the keep-window
# clause deleted. The shipped one keeps the newest directory; the mutant deletes
# it. A retention policy that could not be shown deleting the wrong thing when
# reverted is a policy nobody can tell is working.
#
#   bash scripts/pds-artifact-retention.test.sh
#
# EXIT 0 all arms passed · 1 an arm failed · 99 the harness itself could not run.
#
# WIRED: the `PDS census / parity / scratch-target harnesses` leg of
# .github/workflows/shell-harnesses.yml runs this file — the arm lives in
# .github/shell-harness-legs.json beside its pds-* siblings, and the
# `scripts/pds-*.sh` glob in the workflow's paths lists and `changes` dispatcher
# admits it (task-0dee9077fed25129). shell-harnesses.yml is not a required
# context, so wiring makes this harness RUN, not BLOCK. Wiring it is what
# produced the 24/11 Linux reading recorded below: before it, this file had
# never once started on Linux.
#
# 2026-09-20 — THE BASELINE ABOVE WAS A macOS BASELINE, AND IT WAS NOT THE WHOLE
# TRUTH. The first Linux run of this file (GH Actions run 35504059438, job
# 106061128225, via the wiring PR) read 24 passed, 11 FAILED — the same tree,
# the same arms. The cause was a BSD-ism in the SUBJECT and in this file's own
# store_fingerprint: `stat -f %m` is BSD's mtime, but on GNU coreutils `-f`
# means FILE SYSTEM status, so the BSD form prints a block-count report to
# STDOUT and only then fails, and the `|| stat -c …` fallback appends the right
# number to that garbage. Every mtime and uid downstream was nonsense, so every
# directory read as "owned by another unix user" and nothing was ever retained
# or removed. Fixed by probing stat's flavour ONCE in the subject and by
# GNU-first ordering here; scripts/stat-portability-check.sh now refuses the
# spelling tree-wide. Baseline is now 35/0 on macOS AND 35/0 under a
# GNU-semantics stat. An arm that has only ever run on ONE platform has a
# baseline from one platform, and this header should say which.

set -uo pipefail
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
SUBJECT="$SCRIPT_DIR/pds-artifact-retention.sh"
[ -x "$SUBJECT" ] || { echo "TEST HARNESS FAIL: $SUBJECT is not executable" >&2; exit 99; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
check(){ # got want label
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
rule() { printf -- '─%.0s' $(seq 1 72); printf '\n'; }

# PORTABLE mktemp (explicit path + XXXXXX): `-t NAME` without XXXXXX is BSD-only.
TMPTOP="$(mktemp -d "${TMPDIR:-/tmp}/pds-art-retention-test.XXXXXX")" || { echo "TEST HARNESS FAIL: mktemp" >&2; exit 99; }
cleanup() { [ -n "${TMPTOP:-}" ] && [ -d "$TMPTOP" ] && rm -rf "$TMPTOP"; }
trap cleanup EXIT

HOSTNAME_NOW="$(uname -n 2>/dev/null || echo unknown)"
MARKER=".pds-proof-owner"

# ── fixture builders ─────────────────────────────────────────────────────────

plant_dir() { # root name age_seconds [pid|'' for no marker]
  local root="$1" name="$2" age="$3" pid="${4-}"
  local d="$root/$name"
  mkdir -p "$d"
  # a body, so a removal is visible as bytes and not only as a name
  head -c 4096 /dev/zero >"$d/dev-default-production.tar" 2>/dev/null || :
  if [ -n "$pid" ]; then
    {
      printf 'harness: pds-pull-proof.sh\n'
      printf 'run_id:  run-%s\n' "$name"
      printf 'run_tag: %s\n' "$name"
      printf 'pid:     %s\n' "$pid"
      printf 'host:    %s\n' "$HOSTNAME_NOW"
    } >"$d/$MARKER"
  fi
  # age the DIRECTORY itself — the subject reads the dir's own mtime
  touch_ago "$d" "$age"
}

touch_ago() { # path age_seconds
  local p="$1" age="$2" ts
  ts="$(python3 -c 'import sys,time;print(time.strftime("%Y%m%d%H%M.%S",time.localtime(time.time()-int(sys.argv[1]))))' "$age")"
  touch -t "$ts" "$p"
}

plant_full_store() { # root
  local f="$1/pds-full-export"
  mkdir -p "$f"
  head -c 8192 /dev/zero >"$f/full-default.tar"
  printf 'served_sha: deadbeef\n' >"$f/full-default.tar.meta"
  printf '1\n' >"$f/attempts"
  touch_ago "$f" 100000
}

store_fingerprint() { # root -> a stable description of the parked store
  local f="$1/pds-full-export"
  find "$f" -mindepth 0 2>/dev/null | LC_ALL=C sort | while IFS= read -r e; do
    # GNU FIRST, BSD second — never the reverse. On GNU coreutils `-f` means
    # FILESYSTEM status, so `stat -f %s` SUCCEEDS on Linux with a
    # block-count report instead of failing, and a BSD-first `||` chain
    # never reaches the GNU form. BSD stat rejects `-c` outright, so
    # GNU-first fails loudly on the wrong platform instead of quietly.
    printf '%s\t%s\n' "$(basename "$e")" "$(stat -c %s "$e" 2>/dev/null || stat -f %z "$e" 2>/dev/null)"
  done
}

run_subject() { # subject_path root extra-args... -> stdout in OUT, status in RC
  local subj="$1" root="$2"; shift 2
  OUT="$(PDS_FULL_EXPORT_DIR="$root/pds-full-export" "$subj" --root "$root" "$@" 2>&1)"
  RC=$?
  return 0
}

rule
echo "pds-artifact-retention.test.sh — hermetic, $TMPTOP"
rule

# ── ARM 1-3 · keep-N over a plain backlog ────────────────────────────────────
R1="$TMPTOP/r1"; mkdir -p "$R1"; plant_full_store "$R1"
plant_dir "$R1" pds-proof-art.aaaa1111 100000 99999999
plant_dir "$R1" pds-proof-art.bbbb2222  90000 99999999
plant_dir "$R1" pds-proof-art.cccc3333  80000 99999999
plant_dir "$R1" pds-proof-art.dddd4444  70000 99999999
plant_dir "$R1" pds-proof-art.eeee5555  60000 99999999
FP_BEFORE="$(store_fingerprint "$R1")"

run_subject "$SUBJECT" "$R1"
check "$RC" 0 "arm 1 · dry run exits 0"
check "$(printf '%s' "$OUT" | grep -c '^  WOULD')" 2 "arm 1 · 5 dirs, keep 3 -> 2 removable"
check "$(ls -d "$R1"/pds-proof-art.* | wc -l | tr -d ' ')" 5 "arm 2 · dry run removed NOTHING"

run_subject "$SUBJECT" "$R1" --apply
check "$RC" 0 "arm 3 · --apply exits 0"
check "$(ls -d "$R1"/pds-proof-art.* | wc -l | tr -d ' ')" 3 "arm 3 · 3 directories survive"
check "$([ -d "$R1/pds-proof-art.eeee5555" ] && echo yes || echo no)" yes "arm 3 · the NEWEST survives"
check "$([ -d "$R1/pds-proof-art.dddd4444" ] && echo yes || echo no)" yes "arm 3 · the 2nd newest survives"
check "$([ -d "$R1/pds-proof-art.aaaa1111" ] && echo yes || echo no)" no  "arm 3 · the OLDEST is gone"

# ── ARM 4 · the parked full-export store is untouched, measured ──────────────
check "$(store_fingerprint "$R1")" "$FP_BEFORE"                      "arm 4 · parked store byte-identical after --apply"
check "$(printf '%s' "$OUT" | grep -c 'parked store UNCHANGED')" 1   "arm 4 · the subject asserts it itself"

# ── ARM 5 · the launcher's name shape is IN scope (the gap this verb fills) ──
R5="$TMPTOP/r5"; mkdir -p "$R5"; plant_full_store "$R5"
plant_dir "$R5" pds-proof-art.pds-w14.c7528814 100000 99999999
plant_dir "$R5" pds-proof-art.pds-w14.1b515ee5  90000 99999999
run_subject "$SUBJECT" "$R5" --keep 1 --apply
check "$RC" 0 "arm 5 · exits 0"
check "$([ -d "$R5/pds-proof-art.pds-w14.c7528814" ] && echo yes || echo no)" no \
      "arm 5 · a pds-crown-launch.sh-shaped directory IS removable"
check "$([ -d "$R5/pds-proof-art.pds-w14.1b515ee5" ] && echo yes || echo no)" yes \
      "arm 5 · … and keep-N still protects the newest of them"

# ── ARM 6 · a name this apparatus does not make is REFUSED ──────────────────
R6="$TMPTOP/r6"; mkdir -p "$R6"; plant_full_store "$R6"
plant_dir "$R6" 'pds-proof-art.someone elses thing' 100000 99999999
plant_dir "$R6" 'pds-proof-art.' 100000 99999999
run_subject "$SUBJECT" "$R6" --keep 0 --apply
check "$(printf '%s' "$OUT" | grep -c 'not a name this apparatus makes')" 2 "arm 6 · both odd names refused"
check "$([ -d "$R6/pds-proof-art.someone elses thing" ] && echo yes || echo no)" yes "arm 6 · and left on disk"

# ── ARM 7 · a LIVE pid in the marker is refused even with keep 0 ────────────
R7="$TMPTOP/r7"; mkdir -p "$R7"; plant_full_store "$R7"
plant_dir "$R7" pds-proof-art.aaaa0001 100000 "$$"
run_subject "$SUBJECT" "$R7" --keep 0 --apply
check "$(printf '%s' "$OUT" | grep -c 'is ALIVE on this host')" 1 "arm 7 · live pid refused"
check "$([ -d "$R7/pds-proof-art.aaaa0001" ] && echo yes || echo no)" yes "arm 7 · and left on disk"

# ── ARM 8 · the in-flight quiesce window, and the unmarked-young floor ──────
R8="$TMPTOP/r8"; mkdir -p "$R8"; plant_full_store "$R8"
plant_dir "$R8" pds-proof-art.aaaa0002 60 99999999          # marked, dead pid, FRESH
plant_dir "$R8" pds-proof-art.aaaa0003 3600 ''              # unmarked, 1h old
run_subject "$SUBJECT" "$R8" --keep 0 --apply
check "$(printf '%s' "$OUT" | grep -c 'quiesce window')" 1 "arm 8 · a directory being written is refused"
check "$(printf '%s' "$OUT" | grep -c 'no owner marker AND younger')" 1 "arm 8 · unmarked-and-young refused"
check "$(ls -d "$R8"/pds-proof-art.* | wc -l | tr -d ' ')" 2 "arm 8 · both left on disk"

# ── ARM 9/10 · THE MUTATION PAIR ────────────────────────────────────────────
# Same fixture twice. Arm 9 is the CONTROL: the shipped script keeps the newest.
# Arm 10 deletes the keep-window clause from a COPY and shows the newest
# directory being destroyed — the exact regression this row exists to prevent.
MUT="$TMPTOP/mutant-no-keep-window.sh"
sed 's/^    if \[ "$kept" -lt "$KEEP" \]; then$/    if false; then/' "$SUBJECT" >"$MUT"
chmod +x "$MUT"
if cmp -s "$SUBJECT" "$MUT"; then
  bad "arm 10 · the mutation edited NOTHING — the keep-window clause was not found, so this pair measures nothing"
else
  ok "arm 10 · the mutation changed the subject (keep-window clause removed)"
fi

mk9() { # root
  mkdir -p "$1"; plant_full_store "$1"
  plant_dir "$1" pds-proof-art.f00d0001 100000 99999999
  plant_dir "$1" pds-proof-art.f00d0002  50000 99999999
}
R9="$TMPTOP/r9";  mk9 "$R9"
R10="$TMPTOP/r10"; mk9 "$R10"

run_subject "$SUBJECT" "$R9" --keep 1 --apply
check "$([ -d "$R9/pds-proof-art.f00d0002" ] && echo yes || echo no)" yes \
      "arm 9  · CONTROL — shipped script PRESERVES the newest run"
check "$([ -d "$R9/pds-proof-art.f00d0001" ] && echo yes || echo no)" no \
      "arm 9  · CONTROL — and still prunes the older one (the arm is not vacuous)"

run_subject "$MUT" "$R10" --keep 1 --apply
check "$([ -d "$R10/pds-proof-art.f00d0002" ] && echo yes || echo no)" no \
      "arm 10 · MUTANT — with the keep window gone the NEWEST run is destroyed"
check "$(store_fingerprint "$R10")" "$(store_fingerprint "$R9")" \
      "arm 10 · … and even the mutant never reaches the parked store"

# ── ARM 13 · THE QUIET MUTATION ─────────────────────────────────────────────
# The pair above only proves an arm can go red. It says nothing about whether it
# goes red for the RIGHT reason — a matrix that reds on any edit at all is a
# checksum, not a test. So: mutate a COMMENT line and nothing else, on the same
# fixture, and require the verdict to be byte-identical to arm 9's control.
QUIET="$TMPTOP/mutant-comment-only.sh"
sed 's|^# THE LEAK, RE-MEASURED (pds-bl-artifact-dir-retention)$|# THE LEAK, RE-MEASURED — a comment edit, and nothing else|' "$SUBJECT" >"$QUIET"
chmod +x "$QUIET"
if cmp -s "$SUBJECT" "$QUIET"; then
  bad "arm 13 · the quiet mutation edited NOTHING — it measures nothing"
else
  ok "arm 13 · the quiet mutation changed the subject (one comment line)"
fi
R13="$TMPTOP/r13"; mk9 "$R13"
run_subject "$QUIET" "$R13" --keep 1 --apply
check "$RC" 0 "arm 13 · QUIET — a comment-only edit still exits 0"
check "$([ -d "$R13/pds-proof-art.f00d0002" ] && echo yes || echo no)" yes \
      "arm 13 · QUIET — the newest run still survives (the red in arm 10 was the CLAUSE, not the edit)"
check "$([ -d "$R13/pds-proof-art.f00d0001" ] && echo yes || echo no)" no \
      "arm 13 · QUIET — and the older one is still pruned"

# ── ARM 11 · fail-closed on knobs it cannot evaluate ────────────────────────
R11="$TMPTOP/r11"; mkdir -p "$R11"; plant_full_store "$R11"
plant_dir "$R11" pds-proof-art.aaaa0004 100000 99999999
OUT="$(PDS_ARTIFACT_KEEP=abc "$SUBJECT" --root "$R11" --apply 2>&1)"; RC=$?
check "$RC" 2 "arm 11 · a non-integer keep REFUSES (exit 2)"
check "$([ -d "$R11/pds-proof-art.aaaa0004" ] && echo yes || echo no)" yes "arm 11 · … having examined nothing"
OUT="$("$SUBJECT" --root "$TMPTOP/does-not-exist" --apply 2>&1)"; RC=$?
check "$RC" 2 "arm 11 · a missing root REFUSES (exit 2)"
OUT="$("$SUBJECT" --root "$R11" --wat 2>&1)"; RC=$?
check "$RC" 2 "arm 11 · an unknown flag REFUSES, never silently dropped"

# ── ARM 12 · an empty root is a clean no-op, not an error ───────────────────
R12="$TMPTOP/r12"; mkdir -p "$R12"; plant_full_store "$R12"
run_subject "$SUBJECT" "$R12" --apply
check "$RC" 0 "arm 12 · an empty root exits 0"
check "$(printf '%s' "$OUT" | grep -c '^  REMOVED')" 0 "arm 12 · … removing nothing"

rule
printf '%s pass(es), %s failure(s)\n' "$PASS" "$FAIL"
rule
[ "$FAIL" -eq 0 ] || exit 1
exit 0
