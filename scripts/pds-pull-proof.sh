#!/usr/bin/env bash
#
# pds-pull-proof.sh — THE PDS CROWN PROOF, WRITTEN AS AN EXECUTABLE SPECIFICATION.
#
#   scripts/pds-pull-proof.sh --plan        print every step, its precondition and
#                                           whether it is runnable today. NO side
#                                           effects, always exit 0.
#   scripts/pds-pull-proof.sh --all         run the whole ladder.
#   scripts/pds-pull-proof.sh --only 0a,7   run a subset (same rules).
#   scripts/pds-pull-proof.sh --sweep-artifacts [--apply]
#                                           list the stale artifact directories
#                                           this harness can PROVE it owns, and
#                                           with --apply remove exactly those.
#                                           Refuses everything else, by name.
#   scripts/pds-pull-proof.sh --selftest-conninfo
#                                           OFFLINE two-arm control over the
#                                           PDS_SCRATCH_DB reader: an unquoted
#                                           hand-written scratch.env must still
#                                           fail closed AND be named, and the
#                                           quoted recipe must parse all four
#                                           keys in SILENCE. No network, no
#                                           target, no export.
#   scripts/pds-pull-proof.sh --selftest-citations
#                                           OFFLINE two-arm control over this
#                                           file's OWN decision citations: a
#                                           slash-compressed citation carries
#                                           the PDS-D prefix on the first
#                                           number only, so the standard census
#                                           grep silently misses every later
#                                           one. Fixtures prove the detector
#                                           fires and stays quiet; the last arm
#                                           runs it on this script.
#   scripts/pds-pull-proof.sh --selftest-roster
#                                           OFFLINE control that the rung-6
#                                           sentinel exclusion roster has ONE
#                                           edit site: scripts/pds-schema-row-
#                                           census.md declares
#                                           PDS_SENTINEL_EXCLUSION and this
#                                           harness derives its NOT IN clause
#                                           from it. Positive arm reads the
#                                           real census; negative arm drifts a
#                                           fixture by one row; refusal arms
#                                           prove an unusable source reads as
#                                           NOT DERIVED, never derived-empty.
#   scripts/pds-pull-proof.sh --help
#
# WHY THIS EXISTS BEFORE THE ENGINES DO (PDS-D39, "the proof is the program").
# Wave 2 ended with a headline claim nobody had paid for. A proof written last,
# blind, against a live 3.8 GB box is how that happens. So the ladder is authored
# FIRST: roughly half of it passes today against live guerrilla with zero new
# code, and the rest ABORTS by name. A partial transcript with named ABORTs is a
# real artifact; a green one that skipped is not.
#
# THE THREE OUTCOMES — there is no fourth, and there is no silent skip:
#   PASS   the step ran and every assertion held, printed with the numbers it
#          DERIVED at run time. Never a number pasted from a survey.
#   ABORT  the step cannot run yet. It names the exact bp task whose merge
#          unblocks it (or the exact command an operator must run). It is not a
#          failure and it is not a pass.
#   FAIL   the step ran and an assertion did NOT hold. That is the interesting
#          case; it is never downgraded to an ABORT.
#
# Exit: 0 = every selected step PASSed. 1 = at least one FAIL. 2 = no FAILs but
# at least one ABORT (blocked, honestly). 3 = usage/environment error.
#
# ANTI-VACUITY (PDS-D20). Every green here must be one a broken build could not
# also produce. That is why step 0b refuses to assert `/status.json` migration
# health (a stale build prints the identical green), why step 2 refuses
# `/v1/data/counts` (it hard-codes the published perspective and hides every
# draft row), and why step 4's clean scan is only ever reported next to a control
# that FIRES.
#
# COST DISCIPLINE (PDS-D31/PDS-D44/PDS-D69). Two exports, at most, per run:
#   · the DEV export of step 0a, re-used by step 1's pull;
#   · exactly ONE full-fidelity export, shared by steps 3 and 4 and by nothing
#     else. It is parked at a RUN-STABLE path with a .meta sidecar so the NEXT
#     run reuses it for zero attempts — but ONLY when that sidecar's served_sha
#     matches the sha this run pinned, because a bundle from an older deploy
#     dated by a fresh pin is the silent wrong answer, not a saving; its attempt
#     counter is flushed BEFORE the
#     request (an export that DIES still paid its memory peak); it is locked with
#     mkdir (flock does not exist on Darwin); and all five abort conditions are
#     printed with their measured values before a single byte moves. Two
#     concurrent full exports would OOM the LIVE content API on a 3.8 GB box.
# THE LADDER IS SEVERABLE: if the full export cannot be taken, ONLY steps 3 and 4
# abort — every other rung still runs and still reports.
#
# It does NOT reimplement its two siblings — it CONSUMES them:
#   scripts/pds-scratch-target.sh   boots/tears down the personal-local target
#   scripts/pds-secret-scan.sh      the value-based scan and its control
#
# IT IS NOT RELOCATABLE, AND THE REHEARSAL RECIPE MUST SAY SO (pds-bl-harness-
# not-relocatable). Its own location is SEMANTIC: SCRIPT_DIR and REPO_ROOT are
# derived from the path this file was invoked by, and everything it consumes
# hangs off them — scripts/lib/bp-curl.sh and scripts/pds-blind-spot.sh are
# SOURCED at load, before argument parsing, and the two siblings above are
# resolved as $SCRIPT_DIR/<name>. So a bare copy of THIS ONE FILE cannot run.
# The failure is not deferred to the step you selected; it happens at load:
#
#   $ git show origin/main:scripts/pds-pull-proof.sh > /tmp/x.sh
#   $ bash /tmp/x.sh --only 1,6
#   /tmp/x.sh: line 111: /tmp/lib/bp-curl.sh: No such file or directory
#
# — reproduced verbatim at blob 9a7618d40 (origin/main, 2026-09-11); line 111 is
# that revision's `. "$SCRIPT_DIR/lib/bp-curl.sh"`, and the line NUMBER drifts
# with every edit to this header while the failure does not. The claim is not
# left to this comment: scripts/pds-pull-proof_test.sh relocates the shipped file
# to a temp directory on every run and reds if it ever starts working there.
#
# A copy that clears THAT first source still dies at the unconditional preflight
# `[ -x "$SCAN_SCRIPT" ] || die "... missing — this harness consumes it, it does
# not reimplement it"`, which runs before any --only gating.
#
# THE RUNNABLE RECIPE, therefore, is a REAL CHECKOUT — never an extracted file:
#
#   git worktree add /tmp/pds-rehearsal <sha-or-ref>     # or a fresh clone
#   cd /tmp/pds-rehearsal
#   git rev-parse HEAD:scripts/pds-pull-proof.sh         # the freeze check
#   scripts/pds-pull-proof.sh --plan
#
# THE FREEZE IS VERIFIED WITH `git rev-parse HEAD:scripts/pds-pull-proof.sh`,
# NEVER WITH `shasum` (PDS-D159). The two answer different questions: shasum
# proves bytes, `git rev-parse` proves those bytes are the RECORDED BLOB of the
# frozen instrument. A shasum that matches a number somebody pasted into a
# runbook proves only that the paste and the file agree.
#
# Environment (all optional; every default is printed by --plan):
#   PDS_SOURCE_BASE      default https://guerrilla.barkpark.cloud
#   PDS_SOURCE_TOKEN     default: the `token` for PDS_SOURCE_BASE in
#                        ~/.config/barkpark/config.json. Never printed.
#   PDS_SOURCE_WORKSPACE default default          PDS_SOURCE_DATASET default production
#   PDS_SOURCE_SSH       default root@157.180.90.121 (read-only provenance +
#                        scan ammo; set empty to refuse SSH entirely)
#   PDS_SOURCE_SSH_KEY   default ~/.ssh/barkpark_indx
#   PDS_SOURCE_PG_DB     default barkpark_prod
#   PDS_NO_SSH_AMMO=1    do not pull scan ammo over SSH (step 4 then ABORTs for
#                        want of ammo rather than scanning with none)
#   PDS_CONTROL_PG       maintenance conninfo for `pds-secret-scan.sh control`.
#                        OPTIONAL: step 4 now RESOLVES one — the scratch
#                        target's own server first, then the local libpq
#                        default — and accepts a candidate only when the
#                        SERVER says it is unix/loopback, that the role may
#                        CREATE DATABASE and that it is not the source
#                        production database. Set this to override that
#                        discovery; it is then honoured as given, unprobed.
#   PDS_CONTROL_PG_TIMEOUT  default 5 — PGCONNECT_TIMEOUT for that probe
#   BARKPARK_HOME        the scratch target's root. PINNED per run (PDS-D54).
#   PDS_SCRATCH_POINTER  pinned per run — it is ONE global path and two
#                        concurrent PDS runs clobber each other.
#   PDS_FULL_EXPORT_DIR  default /tmp/pds-full-export — the RUN-STABLE home of
#                        the one full bundle, its .meta, its attempt counter and
#                        its lock. Deliberately NOT under ART_DIR.
#   PDS_FULL_EXPORT_BUDGET       default 1 attempt, ever, per store
#   PDS_FULL_EXPORT_MIN_MEM_MB   default 2200 — the source's MemAvailable floor
#   PDS_FULL_EXPORT_MAX_BEAM_SWAP_MB  default 256 — the ceiling on how much of
#                        the LIVE beam.smp may be paged out. MemAvailable alone
#                        RISES as the BEAM is evicted, so the floor above is
#                        anti-correlated with safety unless it is paired with
#                        this (PDS-D741, pds-bl-gate-b-anticorrelated)
#   PDS_STEP5_FAILDEMO=0 skip step 5's truncate/restore failure demonstration
#                        (the pass then says so: nothing proved the comparator
#                        can fail)
#   PDS_STEP6_GUARD_DEMO=0  skip step 6's guard-off control (same honesty)
#   PDS_STEP1_GRAIN_DEMO=0  skip step 1's manifest-grain negative control — the
#                        locally built mis-grained bundles that prove the
#                        PDS-D61/PDS-D62 guard can REFUSE. On by default (it costs no
#                        network, no export and no credentials); the pass then
#                        says so, because the green is weaker without it.
#   PDS_PROOF_LIB=1      load the rungs as a library without running any
#   PDS_DEPLOYED_SHA     the SSH-less deploy pin, READ ONLY when SSH resolved no
#                        sha of its own. It is believed, never verified, so every
#                        line dating a claim by it says OPERATOR-ASSERTED.
#   PDS_KEEP_ARTIFACTS=1 keep this run's ART_DIR on a CLEAN exit (it is kept
#                        anyway after any FAIL, any ABORT or a non-zero exit)
#   PDS_ARTIFACT_ROOT    default /tmp — the parent of pds-proof-art.<run tag>,
#                        and the directory --sweep-artifacts walks
#   PDS_PROOF_ARTIFACTS  ART_DIR outright. A directory you name here and that
#                        already exists is NEVER removed by the trap: the harness
#                        only ever deletes a directory it created itself
#   PDS_SWEEP_MIN_AGE_HOURS  default 24 — an UNMARKED artifact directory younger
#                        than this is refused by the sweep: the pre-marker
#                        backlog is unmarked, so "no marker" alone can never mean
#                        "abandoned"
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bp-curl.sh"   # 429 backoff, shared (task-c2f96f8121c64601)

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
API_DIR="$REPO_ROOT/api"
SCRATCH_SCRIPT="$SCRIPT_DIR/pds-scratch-target.sh"
SCAN_SCRIPT="$SCRIPT_DIR/pds-secret-scan.sh"

# THE BLIND-SPOT SENTENCE, BY REFERENCE (PDS-D633) — `$PDS_BLIND_SPOT` and
# `pds_blind_spot_note` come from ONE file, never a retyped copy;
# scripts/pds-blind-spot-check.sh reds if a copy drifts. Fail-closed on purpose:
# an instrument that cannot find the sentence it is obliged to print beside a
# duration must refuse, not print the duration bare.
# shellcheck source=scripts/pds-blind-spot.sh
. "$SCRIPT_DIR/pds-blind-spot.sh"

# ── source under proof ───────────────────────────────────────────────────────

SOURCE_BASE="${PDS_SOURCE_BASE:-https://guerrilla.barkpark.cloud}"
SOURCE_WS="${PDS_SOURCE_WORKSPACE:-default}"
SOURCE_DS="${PDS_SOURCE_DATASET:-production}"
SOURCE_SSH="${PDS_SOURCE_SSH-root@157.180.90.121}"
SOURCE_SSH_KEY="${PDS_SOURCE_SSH_KEY:-$HOME/.ssh/barkpark_indx}"
SOURCE_PG_DB="${PDS_SOURCE_PG_DB:-barkpark_prod}"

# ── per-run pinning (PDS-D54) ────────────────────────────────────────────────
#
# BARKPARK_HOME must be short (barkpark-pg's unix socket is capped at 103 bytes
# and pds-scratch-target.sh enforces an 85-byte root cap), and it must live on
# /tmp rather than under an agent scratchpad — see that script's TRAP 3.
# PDS_SCRATCH_POINTER is ONE global path; two concurrent PDS runs sharing it
# tear down each other's target. This wave runs beside two other cycles.

RUN_ID="${PDS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_TAG="$(printf '%s' "$RUN_ID" | cksum | awk '{printf "%x", $1}')"
export BARKPARK_HOME="${BARKPARK_HOME:-/tmp/pds-proof.$RUN_TAG}"
export PDS_SCRATCH_POINTER="${PDS_SCRATCH_POINTER:-/tmp/pds-scratch.$RUN_TAG.last}"
ART_ROOT="${PDS_ARTIFACT_ROOT:-/tmp}"
ART_DIR="${PDS_PROOF_ARTIFACTS:-$ART_ROOT/pds-proof-art.$RUN_TAG}"
# THE ARTIFACT LEAK, AND WHY THE FIX IS OWNERSHIP RATHER THAN `rm -rf` (PDS-D641)
#
# ART_DIR used to be created and never removed: 18 stale /tmp/pds-proof-art.*
# directories totalling 952 MB were measured on the scratch-target host, each
# holding a real dev-profile export of PRODUCTION content in a world-readable
# /tmp. But the naive fix — rm -rf the pattern on exit — is WORSE than the leak:
# this wave runs beside two other cycles, and a concurrent run's ART_DIR looks
# exactly like a stale one from outside.
#
# So removal is gated on PROVEN OWNERSHIP, never on a name match alone:
#   · ART_DIR_OWNED is set ONLY when THIS process created the directory itself
#     (an operator-supplied PDS_PROOF_ARTIFACTS pointing at a pre-existing
#     directory is therefore NEVER removed — we did not make it, we do not take
#     it), and
#   · a marker file named this run: run_id, run_tag, pid and host, re-read at
#     exit. A directory re-owned under us between mkdir and exit is refused.
# Retained on ANY non-clean outcome (non-zero exit, any FAIL, any ABORT) and on
# PDS_KEEP_ARTIFACTS=1, because the thing you want after a failure is the bundle.
ART_MARKER_NAME=".pds-proof-owner"
ART_DIR_OWNED=""
MAX_HOME_LEN=85

# ── the ONE full-fidelity export (PDS-D69/PDS-D70/PDS-D71) ───────────────────
#
# ART_DIR is RUN_TAG-scoped: a bundle parked there is INVISIBLE to the next run,
# which then spends a second attempt on a 3.8 GB box. So the one full export
# lives at a RUN-STABLE path with a .meta sidecar, a persistent attempt counter
# and a mkdir lock (flock does not exist on Darwin). Steps 3 and 4 CONSUME it
# from disk and never fetch.
FULL_DIR="${PDS_FULL_EXPORT_DIR:-/tmp/pds-full-export}"
FULL_TAR="$FULL_DIR/full-$SOURCE_WS.tar"
FULL_META="$FULL_TAR.meta"
FULL_ATTEMPTS_FILE="$FULL_DIR/attempts"
FULL_LOCK="$FULL_DIR/lock"
FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"
FULL_MIN_MEM_MB="${PDS_FULL_EXPORT_MIN_MEM_MB:-2200}"
# THE INCOMING BODY NEVER LANDS ON THE PARKED PATH (pds-bl-w16-failed-refetch-
# destroys-parked-bundle). `curl -o "$FULL_TAR"` opens the destination in
# TRUNCATE mode, so the instant a re-fetch was ISSUED the old, intact, otherwise
# usable bundle was gone — and a 503 then left the run with NEITHER a fresh
# bundle NOR the fallback, having already spent the attempt. The download lands
# on a per-run sibling path and is moved into place only after full_meta_ok has
# passed on THAT path, so every failure mode leaves the parked bundle untouched.
FULL_TMP_TAR="$FULL_TAR.incoming.$RUN_TAG.$$"
# (f) FREE SPACE, measured before the request. Nothing in this ladder looked at
# disk at all; a ~1.03 GB export that runs the filesystem out mid-download fails
# as a truncated body — a shape indistinguishable from a dead export — after
# paying the source's full memory peak. The floor covers the incoming copy while
# the parked bundle is still on disk, which is exactly what the temp-then-rename
# shape above requires; a parked bundle LARGER than the floor raises it.
FULL_MIN_FREE_MB="${PDS_FULL_EXPORT_MIN_FREE_MB:-1536}"
# (b) IS A CONJUNCTION, AND THIS IS ITS SECOND HALF (pds-bl-gate-b-anticorrelated,
# PDS-D741). A MemAvailable floor ON ITS OWN is ANTI-CORRELATED with the thing
# gate (b) exists to prevent. MEASURED on the source 2026-07-20, over 55 s:
# MemAvailable rose 1,586,644 -> 2,984,512 kB precisely BECAUSE the live BEAM was
# being paged out — over the same window its VmSwap rose 51,624 -> 874,760 kB and
# its RSS collapsed 1,024,468 -> 216,852 kB. Seven of eight samples PASSED the
# floor. So the old gate opened most reliably in the state where materialising a
# ~1.03 GB bundle is MOST dangerous: the working set the export must fault back
# in is on disk, and the "headroom" the floor read is that working set's grave.
#
# THE CEILING'S DERIVATION, not a round number picked for looking round: the
# same measured window puts ordinary residue at 51,624 kB (50 MB) of beam swap
# and the pathological readings at 859,944-874,760 kB (839-854 MB). 256 MB sits
# 5x above the residue and 3.3x below the pathology, and is ~25% of the ~1,000 MB
# healthy beam.smp RSS baseline measured in that same window — i.e. it refuses
# once a quarter of the live BEAM's working set is on disk.
FULL_MAX_SWAP_MB="${PDS_FULL_EXPORT_MAX_BEAM_SWAP_MB:-256}"
FULL_LOCK_OWNED=""
FULL_WHY=""            # why acquisition aborted, if it did
FULL_META_WHY=""       # which full_meta_ok expectation failed, if one did
FULL_RSS_LINE=""       # the measured RSS sentence (method + baseline + peak)

# ── output helpers ───────────────────────────────────────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

# ── numeric guards ───────────────────────────────────────────────────────────
# A NON-INTEGER OPERAND DOES NOT STOP `[`; IT MAKES IT SAY NO. `[ "$n" -eq 0 ]`
# on the two-line string $'0\n0' writes "integer expression expected" to stderr,
# returns 2, and the `if` reads that as FALSE — so control takes the ELSE branch,
# which in every guard below is the PASS branch. An unreadable count and a count
# that is fine are then indistinguishable, and the harness reports the reassuring
# one. That is the whole defect class (PDS-D99).
#
# TWO SOURCES MANUFACTURE THE BAD OPERAND, and both read as defensive:
#
#   `grep -c . f || echo 0`   grep -c PRINTS "0" *and* EXITS 1 on no-match, so
#                             BOTH sides fire and the capture is $'0\n0'.
#                             Reproduced: an EMPTY file yields a two-line value.
#   `wc -c <f | tr -d ' ' || echo 0`
#                             `||` binds to the LAST pipeline stage. `tr` always
#                             succeeds, so the fallback NEVER fires; a missing
#                             file yields the EMPTY string, not 0.
#
# The fix has to be at both ends, because either alone is a lie: the capture
# sites below are corrected so they cannot manufacture a non-integer, and every
# comparison over an externally-derived value is preceded by `int_ok` so a value
# nobody anticipated FAILS THE STEP BY NAME instead of skipping it. An
# unparseable count is UNKNOWN, and unknown is not zero.
#
# `int_ok` deliberately rejects the empty string, leading `+`/`-`, whitespace and
# multi-line values — every count in this harness is a cardinality, so a
# non-negative digit run is the only shape that can be true.
int_ok() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# THE RIGHT-HAND OPERAND IS AN OPERAND TOO. FULL_BUDGET and FULL_MIN_MEM_MB are
# the only numbers here that arrive straight from the environment, and both are
# compared with `-lt` / `-ge` further down. `PDS_FULL_EXPORT_BUDGET=one` does not
# stop the run: the comparison errors, evaluates FALSE, and the else branch
# writes "FAILED — the budget is exhausted" into an append-only evidence
# artifact. Fail-CLOSED, which is why nobody noticed — but the reason it records
# is FABRICATED, and no reader can tell it from a real exhaustion. Refusing at
# the door is the difference between a wrong number and a wrong story.
int_ok "$FULL_BUDGET"     || die "PDS_FULL_EXPORT_BUDGET must be a non-negative integer, got '$FULL_BUDGET'"
int_ok "$FULL_MIN_MEM_MB" || die "PDS_FULL_EXPORT_MIN_MEM_MB must be a non-negative integer, got '$FULL_MIN_MEM_MB'"
int_ok "$FULL_MAX_SWAP_MB" || die "PDS_FULL_EXPORT_MAX_BEAM_SWAP_MB must be a non-negative integer, got '$FULL_MAX_SWAP_MB'"

# One integer from a counter capture, or the EMPTY string when there isn't one.
# Never invents a zero: emptiness is what `int_ok` is for. The `head -n 1` is
# what disarms the grep -c double-fire at the capture site rather than at the
# comparison, so the value that reaches the evidence log is the one that was
# measured.
first_int() { printf '%s' "${1-}" | head -n 1 | tr -dc '0-9'; }

RESULTS=""          # one "id<TAB>outcome<TAB>blocker<TAB>detail" line per step
N_PASS=0; N_ABORT=0; N_FAIL=0

record() { # id outcome blocker detail
  RESULTS="$RESULTS$1	$2	$3	$4
"
}

pass() { # id detail
  N_PASS=$((N_PASS + 1))
  printf '  PASS   %-4s %s\n' "$1" "$2"
  record "$1" PASS "-" "$2"
}

abort() { # id blocker detail
  N_ABORT=$((N_ABORT + 1))
  printf '  ABORT  %-4s waits on %s\n' "$1" "$2"
  printf '         %s\n' "$3"
  record "$1" ABORT "$2" "$3"
}

fail() { # id detail
  N_FAIL=$((N_FAIL + 1))
  printf '  FAIL   %-4s %s\n' "$1" "$2"
  record "$1" FAIL "-" "$2"
}

head_step() { # id title
  printf '\n'
  rule
  printf 'STEP %s — %s\n' "$1" "$2"
  rule
}

# ── artifact ownership ──────────────────────────────────────────

art_marker_field() { # field dir -> value on stdout (empty when unreadable)
  local f="$1" d="$2"
  [ -f "$d/$ART_MARKER_NAME" ] || return 0
  # NOT `sed … | head -n 1`: `head` exits after one line, `sed` takes SIGPIPE on
  # the rest of the marker file, and under this script's `set -euo pipefail` the
  # bare pipeline's 141 KILLS THE HARNESS — on a marker file that is merely
  # longer than the pipe buffer.  Capture, then take the first line in the shell.
  local raw
  raw="$(sed -n "s/^$f:[[:space:]]*//p" "$d/$ART_MARKER_NAME" 2>/dev/null || true)"
  [ -n "$raw" ] && printf '%s\n' "${raw%%$'\n'*}"
  return 0
}

art_dir_ensure() { # create ART_DIR, claiming ownership ONLY if we made it
  if [ ! -d "$ART_DIR" ]; then
    mkdir -p "$ART_DIR" || return 1
    {
      printf 'harness: pds-pull-proof.sh\n'
      printf 'run_id:  %s\n' "$RUN_ID"
      printf 'run_tag: %s\n' "$RUN_TAG"
      printf 'pid:     %s\n' "$$"
      printf 'host:    %s\n' "$(uname -n 2>/dev/null || echo unknown)"
      printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$ART_DIR/$ART_MARKER_NAME" 2>/dev/null || true
    ART_DIR_OWNED=1
  elif [ -z "$ART_DIR_OWNED" ] && [ "$(art_marker_field run_id "$ART_DIR")" = "$RUN_ID" ]; then
    # our own directory from earlier in THIS process (the marker names this run)
    ART_DIR_OWNED=1
  fi
  return 0
}

art_dir_cleanup() { # exit_status — called from the EXIT trap, must never abort it
  local rc="${1:-0}"
  [ -n "$ART_DIR_OWNED" ] || return 0
  [ -d "$ART_DIR" ] || return 0
  if [ -n "${PDS_KEEP_ARTIFACTS:-}" ]; then
    printf '  artifacts RETAINED at %s (PDS_KEEP_ARTIFACTS is set)\n' "$ART_DIR"
    return 0
  fi
  if [ "$rc" != "0" ] || [ "${N_FAIL:-0}" -gt 0 ] || [ "${N_ABORT:-0}" -gt 0 ]; then
    printf '  artifacts RETAINED for diagnosis at %s (exit %s, %s FAIL, %s ABORT) — sweep later with PDS_ARTIFACT_ROOT=%s %s --sweep-artifacts --apply\n' \
      "$ART_DIR" "$rc" "${N_FAIL:-0}" "${N_ABORT:-0}" "$ART_ROOT" "$SELF"
    return 0
  fi
  # Re-read the marker at exit: a directory re-owned under us is not ours to remove.
  if [ "$(art_marker_field run_id "$ART_DIR")" != "$RUN_ID" ]; then
    printf '  artifacts REFUSED at %s — the owner marker no longer names this run (%s); left in place\n' \
      "$ART_DIR" "$RUN_ID"
    return 0
  fi
  rm -rf "$ART_DIR" 2>/dev/null || true
  printf '  artifacts removed: %s (this run created it and its marker still named this run)\n' "$ART_DIR"
  return 0
}

# ── temp hygiene ─────────────────────────────────────────────────────────────

TMP_FILES=""
TMP_DIRS=""
cleanup() {
  local rc=$?
  local f d
  for f in $TMP_FILES; do [ -f "$f" ] && rm -f "$f"; done
  for d in $TMP_DIRS; do [ -d "$d" ] && rm -rf "$d"; done
  # Release the full-export lock ONLY if this run took it. A lock we did not
  # create belongs to a concurrent run and removing it would let two full
  # exports overlap — the one thing PDS-D31 forbids.
  [ -n "$FULL_LOCK_OWNED" ] && [ -d "$FULL_LOCK" ] && rmdir "$FULL_LOCK" 2>/dev/null || true
  # A step-5 failure demo must never leave a blob truncated on the target.
  restore_blob_backup
  # THIS RUN'S OWN artifacts, and nobody else's (see the ART_DIR block above).
  art_dir_cleanup "$rc"
  return 0
}
trap cleanup EXIT

mktmp() { # -> path, tracked
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/pds-proof.XXXXXX")"
  TMP_FILES="$TMP_FILES $f"
  printf '%s\n' "$f"
}

# ── source token: resolved, never printed ────────────────────────────────────

SOURCE_TOKEN=""
resolve_source_token() {
  if [ -n "${PDS_SOURCE_TOKEN:-}" ]; then
    SOURCE_TOKEN="$PDS_SOURCE_TOKEN"
    return 0
  fi
  local cfg="$HOME/.config/barkpark/config.json"
  [ -r "$cfg" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  SOURCE_TOKEN="$(BASE="$SOURCE_BASE" python3 - "$cfg" <<'PY' || true
import json, os, sys
base = os.environ["BASE"].rstrip("/")
cfg = json.load(open(sys.argv[1]))
cands = [cfg] + list(cfg.get("known_servers") or [])
for c in cands:
    if str(c.get("server", "")).rstrip("/") == base and c.get("token"):
        print(c["token"])
        break
PY
)"
  [ -n "$SOURCE_TOKEN" ]
}

curl_src() { # path [curl args…] — GET with the admin token, never echoing it
  local path="$1"; shift
  curl -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" \
    -H "Authorization: Bearer $SOURCE_TOKEN" "$SOURCE_BASE$path" "$@"
}

jqp() { # python "field extractor": jqp '<python expr over d>' <<< json
  python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(eval(sys.argv[1]))' "$1"
}

# ── SSH: read-only provenance + scan ammo ────────────────────────────────────
#
# Guerrilla's Postgres is NOT reachable externally, and `/status.json` carries a
# marketing version string, not a sha. SSH is the only run-time source of both
# the deployed sha and the scan's ammo. It is used read-only and the ammo values
# are never printed — pds-secret-scan.sh masks them to length + sha256 prefix.

SSH_OK=""
ssh_available() {
  [ -n "$SSH_OK" ] && { [ "$SSH_OK" = yes ]; return; }
  SSH_OK=no
  if [ -n "$SOURCE_SSH" ] && [ -r "$SOURCE_SSH_KEY" ] && command -v ssh >/dev/null 2>&1; then
    if ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 \
         -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" true >/dev/null 2>&1; then
      SSH_OK=yes
    fi
  fi
  [ "$SSH_OK" = yes ]
}

ssh_src() { # command string, run on the source box
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" "$1" 2>/dev/null
}

src_psql() { # sql — read-only. The SQL travels on ssh's STDIN (psql -f -) rather
             # than in the remote command line, so no layer of shell quoting on
             # either side can mangle or re-split it.
  printf '%s\n' "$1" | ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
    "sudo -u postgres psql -d '$SOURCE_PG_DB' -At -f -" 2>/dev/null
}

# ── the TARGET: the disposable personal-local box booted by the sibling ──────
#
# Everything about it comes from ITS OWN scratch.env (pds-scratch-target.sh
# writes PDS_SCRATCH_BASE/_TOKEN/_DB/_TREE there). Nothing here re-derives a
# port, a token or a conninfo — a harness that guesses them is proving something
# about its guess.

# ── the conninfo, READ THE SAME WAY EVERYWHERE ──────────────────────────────
#
# `PDS_SCRATCH_DB` is a libpq conninfo: `host=… port=… dbname=… user=…`. Two
# pure helpers read it, and BOTH the warning in load_target and the abort in
# step 0c go through them, so the two can never name different key sets.
#
# WHY THE WARNING EXISTS (pds-w6-scratch-env-quoting-trap). load_target sources
# scratch.env with `. "$envf"`. A HAND-WRITTEN line
#
#     PDS_SCRATCH_DB=host=127.0.0.1 port=59999 dbname=nope user=nope
#
# is a shell assignment followed by three COMMAND WORDS: the variable gets
# `host=127.0.0.1` and the rest is dropped at the first space. The generated
# scratch.env is safe — pds-scratch-target.sh writes `export PDS_SCRATCH_DB="…"`
# — so this only ever bites a fixture somebody typed. It already FAILS CLOSED
# (step 0c aborts `env:scratch-db-unparsed` and refuses the ambient dev Repo),
# and that is NOT traded away here: nothing below repairs, completes or guesses
# at a half-parsed conninfo. The only change is that the operator is told WHICH
# keys are missing, and that the cause is the missing quotes, at the moment the
# value is read rather than several steps downstream.

conninfo_part() { # key conninfo -> the value for that key ('' when absent)
  local want="$1" kv
  # Word-splitting $2 IS the parse: a libpq conninfo is space-separated.
  # shellcheck disable=SC2086
  for kv in $2; do
    case "$kv" in
      "$want"=*) printf '%s' "${kv#"$want"=}"; return 0 ;;
    esac
  done
  printf ''
}

conninfo_missing_keys() { # conninfo -> the missing key names, space-separated
  local k missing=""        # empty output = all four keys present
  for k in host port dbname user; do
    [ -n "$(conninfo_part "$k" "$1")" ] || missing="$missing $k"
  done
  printf '%s' "${missing# }"
}

TARGET_BASE=""; TARGET_TOKEN=""; TARGET_DB=""; TARGET_TREE=""; TARGET_MEDIA=""
SCRATCH_DB_WARNED=""
load_target() { # 0 = a booted target is loaded
  local envf="$BARKPARK_HOME/scratch.env"
  [ -f "$envf" ] || return 1
  # shellcheck disable=SC1090
  . "$envf"
  TARGET_BASE="${PDS_SCRATCH_BASE:-}"
  TARGET_TOKEN="${PDS_SCRATCH_TOKEN:-}"
  TARGET_DB="${PDS_SCRATCH_DB:-}"
  TARGET_TREE="${PDS_SCRATCH_TREE:-}"
  TARGET_MEDIA="${BARKPARK_MEDIA_DIR:-}"
  # A non-empty conninfo missing any of the four keys is named HERE, once per
  # distinct value, on stderr. TARGET_DB is left exactly as it was read.
  local missing
  if [ -n "$TARGET_DB" ]; then
    missing="$(conninfo_missing_keys "$TARGET_DB")"
    if [ -n "$missing" ] && [ "$SCRATCH_DB_WARNED" != "$TARGET_DB" ]; then
      SCRATCH_DB_WARNED="$TARGET_DB"
      printf 'WARN  %s/scratch.env: PDS_SCRATCH_DB parsed to fewer than four keys — missing: %s (value read: %s)\n' \
        "$BARKPARK_HOME" "$missing" "$TARGET_DB" >&2
      printf 'WARN  a HAND-WRITTEN scratch.env must QUOTE the value — export PDS_SCRATCH_DB="host=… port=… dbname=… user=…" — because sourcing an unquoted multi-field assignment keeps only the first field. Nothing is guessed from a short conninfo: step 0c still aborts rather than fall back to the ambient dev Repo.\n' >&2
    fi
  fi
  [ -n "$TARGET_BASE" ] && [ -n "$TARGET_TOKEN" ]
}

target_hint() { # the exact command that produces a target
  printf 'BARKPARK_HOME=%s PDS_SCRATCH_POINTER=%s %s up --verify' \
    "$BARKPARK_HOME" "$PDS_SCRATCH_POINTER" "$SCRATCH_SCRIPT"
}

http_code() { # normalise a `curl -w %{http_code}` capture
  # curl PRINTS 000 on a connection failure AND exits non-zero, so the common
  # `|| echo 000` fallback concatenates two codes ("000000") and every later
  # comparison against "401" silently misses. Keep the last three digits.
  local c
  c="$(printf '%s' "${1:-}" | tr -dc '0-9' | tail -c 3)"
  printf '%s' "${c:-000}"
}

curl_tgt() { # path [curl args…] — authed GET against the target
  local path="$1"; shift
  curl -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" \
    -H "Authorization: Bearer $TARGET_TOKEN" "$TARGET_BASE$path" "$@"
}

curl_tgt_anon() { # path [curl args…] — the SAME call with no Authorization header
  local path="$1"; shift
  curl -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" "$TARGET_BASE$path" "$@"
}

tgt_psql() { # sql -> rows, tab-separated, no header. Runs through the target's
             # OWN bin/barkpark, which knows its socket (PDS-D65: the guard has
             # no CLI or HTTP off-switch, so SQL is the sanctioned idiom).
  [ -n "$TARGET_TREE" ] || return 1
  "$TARGET_TREE/bin/barkpark" psql --quiet --tuples-only --no-align --field-separator=$'\t' \
    --command "$1" 2>/dev/null
}

# ── the instrument control's maintenance PG, RESOLVED not demanded ──────────
#
# Step 4's positive control (`pds-secret-scan.sh control`) is the one leg that
# proves the scanner CAN fire. It costs no guerrilla export — it seeds its own
# throwaway local database — and it used to run only when an operator had
# exported PDS_CONTROL_PG by hand, so the default `--all` transcript printed
# `instrument control: NOT RUN` and the clean scan beside it stood alone. A
# clean scan with no firing control is the vacuous green PDS-D20 exists to
# refuse, so the connection is now DISCOVERED.
#
# DISCOVERY IS LOCAL-OR-NOTHING, AND IT ASKS THE SERVER RATHER THAN THE STRING.
# A conninfo is a claim; `inet_server_addr()`, `current_database()` and the
# connecting role's `rolcreatedb` are the server's own answers. A candidate is
# accepted only if the server says it is a unix socket or loopback, that the
# role may CREATE DATABASE (the control's first act — an unprivileged candidate
# would turn a passing step into a FAIL), and that the database it landed in is
# not the source production database. Anything else — including a probe that
# does not answer in the expected shape — is REFUSED BY NAME, and the step then
# falls back to NOT RUN carrying the refusals rather than a bare instruction.
#
# An operator-supplied PDS_CONTROL_PG is honoured as given, unprobed: it is an
# explicit opt-in that predates this discovery and must not start refusing.
CONTROL_PG=""; CONTROL_PG_SRC=""; CONTROL_PG_WHY=""

control_pg_verdict() { # <probe line: "<server-addr|unix> <port> <t|f> <database>">
  # Pure — it decides over the server's four answers and nothing else, so the
  # harness's own test can drive every refusal without a PostgreSQL.
  # Sets CONTROL_PG_WHY on refusal; clears it on acceptance.
  local line="${1-}" addr port cancreate db n
  CONTROL_PG_WHY=""
  # shellcheck disable=SC2086  # deliberate word split: the probe emits 4 fields
  set -- $line
  n=$#
  if [ "$n" -ne 4 ]; then
    CONTROL_PG_WHY="the probe did not answer in the expected 4-field shape (got $n field(s): '$line') — an answer nobody can parse is not a permission"
    return 1
  fi
  addr="$1"; port="$2"; cancreate="$3"; db="$4"
  case "$addr" in
    unix|127.0.0.1|::1|localhost) ;;
    *) CONTROL_PG_WHY="the server reports its own address as '$addr' (port $port), which is neither a unix socket nor loopback — this control creates and drops a database and is never pointed at a remote server"
       return 1 ;;
  esac
  # `boolean::text` is 'true'/'false' in psql's unaligned output, but `t`/`f` is
  # what a tuples-only client can hand back and what every fixture in this file's
  # test harness was first written against — a verdict that knew only one
  # spelling passed every fixture and refused the real server. Both spellings of
  # YES are accepted; anything else is not a yes.
  case "$cancreate" in
    t|true) ;;
    *)
      CONTROL_PG_WHY="the connecting role cannot CREATE DATABASE there (the server answered '$cancreate'), and the control's first act is \`CREATE DATABASE\` — accepting it would convert a skipped control into a FAILED step"
       return 1 ;;
  esac
  case "$db" in
    "$SOURCE_PG_DB"|*prod*)   # *prod* already covers *production*
      CONTROL_PG_WHY="it landed in database '$db', which is the source production database or named like one — the control seeds and drops schema objects and is refused anywhere near production"
      return 1 ;;
  esac
  return 0
}

control_pg_probe() { # <conninfo> -> 0 when the SERVER says it is local, privileged and not production
  local conninfo="${1-}" out
  CONTROL_PG_WHY=""
  if [ -z "$conninfo" ]; then
    CONTROL_PG_WHY="empty conninfo"
    return 1
  fi
  if ! out="$(PGCONNECT_TIMEOUT="${PDS_CONTROL_PG_TIMEOUT:-5}" psql "$conninfo" -X -Atq \
      -c "SELECT coalesce(host(inet_server_addr())::text, 'unix') || ' ' || coalesce(current_setting('port', true), '?') || ' ' || (SELECT (rolsuper OR rolcreatedb)::text FROM pg_roles WHERE rolname = current_user) || ' ' || current_database()" 2>/dev/null)"; then
    CONTROL_PG_WHY="psql could not connect"
    return 1
  fi
  out="$(printf '%s\n' "$out" | head -1)"
  control_pg_verdict "$out"
}

control_pg_from_target() { # the scratch target's OWN server, maintenance database
  local kv h="" pt="" u=""
  [ -n "${TARGET_DB:-}" ] || return 1
  for kv in $TARGET_DB; do
    case "$kv" in
      host=*) h="${kv#host=}" ;;
      port=*) pt="${kv#port=}" ;;
      user=*) u="${kv#user=}" ;;
    esac
  done
  [ -n "$h" ] && [ -n "$pt" ] && [ -n "$u" ] || return 1
  printf 'host=%s port=%s dbname=postgres user=%s' "$h" "$pt" "$u"
}

resolve_control_pg() { # 0 = $CONTROL_PG is usable; 1 = NOT RUN, with $CONTROL_PG_WHY saying why
  CONTROL_PG=""; CONTROL_PG_SRC=""; CONTROL_PG_WHY=""
  if [ -n "${PDS_CONTROL_PG:-}" ]; then
    CONTROL_PG="$PDS_CONTROL_PG"
    CONTROL_PG_SRC="PDS_CONTROL_PG (operator-supplied; honoured as given and not printed)"
    return 0
  fi
  if ! command -v psql >/dev/null 2>&1; then
    CONTROL_PG_WHY="psql is not on PATH, so no candidate can even be probed"
    return 1
  fi
  local cand why_all="" src
  for src in target local; do
    cand=""
    case "$src" in
      target) load_target >/dev/null 2>&1 || true
              cand="$(control_pg_from_target || true)" ;;
      local)  cand="dbname=postgres" ;;
    esac
    if [ -z "$cand" ]; then
      why_all="$why_all; $src: no candidate conninfo (the scratch target is not booted, or its scratch.env carries no parseable PDS_SCRATCH_DB)"
      continue
    fi
    if control_pg_probe "$cand"; then
      CONTROL_PG="$cand"
      CONTROL_PG_SRC="$src"
      return 0
    fi
    why_all="$why_all; $src ($cand): $CONTROL_PG_WHY"
  done
  CONTROL_PG_WHY="${why_all#; }"
  return 1
}

# ── the target's TASK-LIFECYCLE CHECK, as a PRECONDITION (PDS-D32) ───────────
#
# Migrations 20260719030000/20260719030100 widen
# `documents_task_lifecycle_status_check` from 5 accepted values to 7, adding the
# two thought states `considering` and `researching`. A scratch target booted
# from a pre-widening tree accepts the bundle right up until the first task row
# carrying one of those two, and then the import dies MID-TRANSACTION on a raw
# Postgrex CHECK violation — which in clean mode compounds with the 25P02
# cascade and reads, to everyone downstream, like a defect in the import engine.
#
# Step 0b's deploy-provenance check (sha implies migration-file set, PDS-D47) is
# NOT a substitute for two reasons: it is about the SOURCE deploy, not the
# target's applied schema, and the harness documents legitimate partial `--only`
# re-runs that never execute it at all. So the constraint is read from the LIVE
# target, once, before a byte is imported.
#
# The list is the migration's list, spelled once.
LIFECYCLE_VALUES_7="open in_progress blocked done cancelled considering researching"

lifecycle_missing_values() { # <pg_get_constraintdef text> -> the values it does NOT accept
  # Pure: no database, no globals but the list above — so the harness's own test
  # can drive it against a real pre-widening `pg_get_constraintdef` string.
  # Each value is matched WITH its SQL quotes: an unquoted substring search would
  # find `open` inside `owner_scoped` and call a 5-value constraint widened.
  local def="${1-}" v out=""
  for v in $LIFECYCLE_VALUES_7; do
    case "$def" in
      *"'$v'"*) ;;
      *)        out="$out $v" ;;
    esac
  done
  printf '%s' "${out# }"
}

# ── a bp binary NEW ENOUGH to speak the pull dialect (PDS-D63) ───────────────
#
# The installed bp predates --profile/--dataset/--merge/--with-blobs, and an old
# binary does not error on an unknown flag in a way anyone reads — it is refused
# up front instead. The binary is built FROM THIS WORKTREE and its own --help is
# the freshness assertion.

BP_BIN=""
BP_WHY=""
ensure_bp() { # 0 = $BP_BIN is a fresh binary that speaks the dialect
  [ -n "$BP_BIN" ] && return 0
  if ! command -v go >/dev/null 2>&1; then
    BP_WHY="go is not on PATH, so a fresh bp cannot be built from this worktree (the installed bp predates the pull dialect and must not be used)"
    return 1
  fi
  art_dir_ensure
  local out log cc
  out="$ART_DIR/bp"
  log="$ART_DIR/bp-build.log"
  # `cc` on this host is a Claude wrapper, not a C compiler (a known local trap).
  cc="${PDS_CC:-/usr/bin/clang}"
  [ -x "$cc" ] || cc="cc"
  if ! ( cd "$REPO_ROOT" && CC="$cc" go build -o "$out" ./cmd/barkpark ) >"$log" 2>&1; then
    BP_WHY="go build ./cmd/barkpark failed — see $log ($(tail -3 "$log" | tr '\n' ' '))"
    return 1
  fi
  local help
  help="$("$out" cloud workspace --help 2>&1 || true)"
  case "$help" in
    *"--profile full|dev"*) : ;;
    *) BP_WHY="the bp built from this worktree does not advertise --profile in \`cloud workspace --help\` — the dialect is not in this tree"; return 1 ;;
  esac
  # --dataset is asserted for the SAME reason as the other three, and it is the
  # one this gate was blind to while two info lines claimed it covered (PDS-D86).
  # D61 — the global parser silently swallowing `--dataset` — is a regression
  # this binary would still ADVERTISE its way past if nobody read the help.
  case "$help" in *"--dataset"*) : ;; *) BP_WHY="the built bp does not advertise --dataset — an un-scoped export would silently take the whole workspace (the D61 class)"; return 1 ;; esac
  case "$help" in *"--merge"*) : ;; *) BP_WHY="the built bp does not advertise --merge"; return 1 ;; esac
  case "$help" in *"--with-blobs"*) : ;; *) BP_WHY="the built bp does not advertise --with-blobs"; return 1 ;; esac
  BP_BIN="$out"
  return 0
}

# ── step-5 blob backup (a failure demo must be reversible) ───────────────────

BLOB_BACKUP=""     # a copy of the blob the demo mutates
BLOB_ORIGINAL=""   # where it belongs
restore_blob_backup() {
  if [ -n "$BLOB_BACKUP" ] && [ -f "$BLOB_BACKUP" ] && [ -n "$BLOB_ORIGINAL" ]; then
    cp "$BLOB_BACKUP" "$BLOB_ORIGINAL" 2>/dev/null || true
    rm -f "$BLOB_BACKUP" 2>/dev/null || true
  fi
  BLOB_BACKUP=""; BLOB_ORIGINAL=""
  return 0
}

# ── cross-step state (derived at RUN time, never from a snapshot) ────────────

DEPLOYED_SHA=""
# HOW the sha above was obtained: "ssh" (measured off the box's own git HEAD
# this run) or "operator-asserted" (PDS_DEPLOYED_SHA, believed, never verified).
# It is carried, not discarded, because an asserted pin WEAKENS every claim it
# dates and the transcript must say so wherever it prints one (PDS-D642).
DEPLOYED_SHA_SOURCE=""
DEPLOYED_VERSION=""
DEPLOYED_UPTIME_0A=""
DEV_BUNDLE=""
PULL_BUNDLE=""      # the bundle step 1 actually imported
AMMO_FILE=""

# ═════════════════════════════════════════════════════════════════════════════
# THE PLAN
# ═════════════════════════════════════════════════════════════════════════════

# THE SSH-LESS ESCAPE HATCH, AND IT IS REAL NOW (PDS-D642).
# step 0b's FIX text has always told the operator to `export PDS_DEPLOYED_SHA`.
# No code read it — it was the ONLY occurrence of that name in the whole file,
# inside a prose string — so an operator who followed the harness's own
# remediation got no effect and no warning. It is read here, and ONLY when SSH
# resolved nothing: a measured pin always wins over an asserted one, never the
# other way round. It is tagged so every line quoting it discloses it.
apply_deployed_sha_override() {
  [ -z "$DEPLOYED_SHA" ] || return 0
  [ -n "${PDS_DEPLOYED_SHA:-}" ] || return 0
  DEPLOYED_SHA="$(printf '%s' "$PDS_DEPLOYED_SHA" | tr -d '[:space:]')"
  DEPLOYED_SHA_SOURCE="operator-asserted"
  info "deployed sha    $DEPLOYED_SHA  (OPERATOR-ASSERTED via PDS_DEPLOYED_SHA — this run did NOT measure it against the box)"
  return 0
}

sha_provenance_note() { # -> the disclosure that must ride beside an asserted pin
  case "$DEPLOYED_SHA_SOURCE" in
    operator-asserted) printf ' [sha OPERATOR-ASSERTED via PDS_DEPLOYED_SHA — believed, not measured against the box this run; every claim dated by it is only as good as that assertion]' ;;
    *) printf '' ;;
  esac
}

plan_row() { # id | title | precondition | today
  printf '  %-4s %s\n' "$1" "$2"
  printf '       precondition: %s\n' "$3"
  printf '       today:        %s\n\n' "$4"
}

cmd_plan() {
  rule
  say "PDS CROWN PROOF — PLAN (no side effects; this mode never touches a network,"
  say "a database, or a filesystem outside its own stdout)"
  rule
  say "source:        $SOURCE_BASE  workspace=$SOURCE_WS  dataset=$SOURCE_DS"
  say "scratch root:  $BARKPARK_HOME  (${#BARKPARK_HOME} bytes, cap $MAX_HOME_LEN)"
  say "pointer:       $PDS_SCRATCH_POINTER"
  say "artifacts:     $ART_DIR   (RUN-scoped — invisible to the next run, by design)"
  say "               removed on a CLEAN exit by this run's own trap; kept after any FAIL/ABORT"
  say "               or with PDS_KEEP_ARTIFACTS=1. Backlog: $SELF --sweep-artifacts"
  say "full export:   $FULL_TAR"
  say "               budget=$FULL_BUDGET attempt(s) · spent so far=$([ -f "$FULL_ATTEMPTS_FILE" ] && cat "$FULL_ATTEMPTS_FILE" || echo 0) · on-disk bundle=$([ -s "$FULL_TAR" ] && echo "PRESENT ($(wc -c <"$FULL_TAR" | tr -d ' ') bytes, would be REUSED for 0 attempts)" || echo absent)"
  say "               gate (b) before it is taken: MemAvailable >= ${FULL_MIN_MEM_MB} MB AND the live"
  say "               beam.smp's own VmSwap <= ${FULL_MAX_SWAP_MB} MB. BOTH, because MemAvailable RISES"
  say "               as the BEAM is evicted — the floor alone opens on a swapped-out box"
  say "siblings:      $(basename "$SCRATCH_SCRIPT") $([ -x "$SCRATCH_SCRIPT" ] && echo present || echo MISSING) · $(basename "$SCAN_SCRIPT") $([ -x "$SCAN_SCRIPT" ] && echo present || echo MISSING)"
  say "tooling:       curl $(command -v curl >/dev/null 2>&1 && echo yes || echo NO) · python3 $(command -v python3 >/dev/null 2>&1 && echo yes || echo NO) · psql $(command -v psql >/dev/null 2>&1 && echo yes || echo NO) · ssh $(command -v ssh >/dev/null 2>&1 && echo yes || echo NO) · bp $(command -v bp >/dev/null 2>&1 && echo yes || echo NO)"
  say ""
  say "OUTCOMES: PASS (ran, assertions held, numbers derived at run time) ·"
  say "ABORT (cannot run yet — names the bp task or command that unblocks it) ·"
  say "FAIL (ran, an assertion did not hold). There is no silent skip."
  say ""
  rule

  plan_row 0a "SOURCE FRESHNESS — believe nothing about a differential until the source is pinned" \
    "the source answers /status.json; the dev export dialect (profile+dataset) is DEPLOYED, not merely merged" \
    "RUNNABLE. Takes the one budgeted DEV export (~51 MB, ~7 s) and asserts the manifest's additive profile/dataset/source_* fields. FAILS with 'guerrilla is running older code than main' and the sha it actually served if the dialect is absent."

  plan_row 0b "DEPLOY-PROVENANCE — NOT schema_migrations parity (PDS-D47)" \
    "0a resolved a deployed sha; this worktree is a git checkout" \
    "RUNNABLE. There is NO schema_migrations HTTP surface anywhere and the source's Postgres is unreachable externally; /status.json's migrations component is a boolean over the RUNNING BINARY's own migration files, so a stale build prints the identical green — the vacuous green PDS-D20 forbids. The assertion is instead: the deployed sha EQUALS OR IS AN ANCESTOR OF the worktree the target migrated from."

  plan_row 0c "SENTINELS — Catalog.assert_partition!/1 + assert_dev_partition!/1" \
    "a booted scratch target, and a Repo that provably points AT IT" \
    "RUNNABLE when a target is up. ASSERTS, before the sentinels: the Repo it started answers current_database()/inet_server_port() equal to the conninfo in scratch.env. WHY (PDS-D64): the bare \`MIX_ENV=dev mix run\` idiom resolves to the DEVELOPER'S OWN barkpark_dev even with BARKPARK_HOME/BARKPARK_PG_PORT/PDS_SCRATCH_DB/DATABASE_URL all pointed at the scratch box (dev.exs hardcodes host/port/user). This step now starts the Repo with the scratch conninfo explicitly and ABORTS rather than emit 'SENTINELS OK' measured against the wrong database. A NEW tenant table RAISES the fail-closed sentinel — reported as a FAIL, never bypassed."

  plan_row 1 "THE PULL — export --profile dev + import --yes --merge, both --with-blobs" \
    "a booted scratch target + a bp built FROM THIS WORKTREE (the installed one predates the dialect)" \
    "RUNNABLE. Runs the PAIR (PDS-D58) with explicit -s/--token on both calls — BARKPARK_TOKEN is read NOWHERE. ASSERTS: (1) the built bp advertises --profile/--merge/--with-blobs in its own --help; (2) the export exits 0 and the tar carries a manifest; (3) the manifest's dataset EQUALS the dataset asked for — a workspace-grain bundle ABORTS naming pds-w4-pull-dataset-flag rather than being imported (PDS-D61/PDS-D62) — and that assertion carries a NEGATIVE CONTROL, on by default (PDS_STEP1_GRAIN_DEMO=0 to skip, and the pass then says so), which puts five locally built manifests through the same assertion and FAILs the step unless it refuses every mis-grained one; (4) the import exits 0 and its receipt names tables+rows; (5) blob failures exit non-zero by the CLI's own contract. --merge is MANDATORY: mode=clean answers an opaque 500 (25P02 at workspace_bundle.ex:233) on a populated target. PDS-D9 adoption is reported by diffing the workspaces row across the import — the CLI never says it. PRECONDITION READ FROM THE LIVE TARGET, not from a migration file: documents_task_lifecycle_status_check must already accept all seven lifecycle values (PDS-D32 migrations 20260719030000 + 20260719030100); a pre-widening target ABORTS by name here instead of dying mid-import on a raw CHECK violation that reads like an engine defect."

  plan_row 2 "RAW-PERSPECTIVE CENSUS — per-type ?perspective=raw&count=true, BOTH ends" \
    "source HTTP; for the target half, step 1's import" \
    "RUNNABLE both halves. Roster derived at RUN TIME from /v1/schemas on each end — never hardcoded (production/post is 0 on BOTH ends; this workspace has no post documents at all). ASSERTS AUTHEDNESS INDEPENDENTLY on each end before believing any total: an UNAUTHED raw query does NOT 401, it silently returns the published view, so the authed and unauthed censuses must DIFFER — and when a dataset genuinely has no drafts, an admin-only route must 401/403 instead. The import assertion is BUNDLE→TARGET per type (the bundle's own documents.copy rows, parsed with manifest column positions); SOURCE→BUNDLE deltas are printed as the scrub's scope, never asserted as loss. NEVER /v1/data/counts/:dataset (hard-codes published). Bare-slug E3 (PDS-D45) stays excluded."

  plan_row 3 "TICKET-DENY BYTE-SCAN — bytes at ROW grain, never a count diff" \
    "the dev bundle (0a) plus THE ONE full-fidelity bundle for the FIRING control" \
    "RUNNABLE when the one budgeted full export is acquirable; otherwise ABORTS with the acquisition's own named reason (severable — only 3 and 4 pay). doc_id and row uuid are RE-DERIVED at run time. ASSERTS: no ticket-carrying member and zero ROWS in documents.copy whose own doc_id/type/id identify the ticket (column positions from the manifest), because those identifiers are QUOTED IN PROSE elsewhere and a naive byte-absence assertion fires on a bundle where the deny held perfectly. THE CONTROL: the same identifiers must be FOUND at row grain in the FULL bundle — a zero with no control that fires is the vacuous green PDS-D20 forbids."

  plan_row 4 "VALUE-BASED SECRET SCAN — consumes scripts/pds-secret-scan.sh" \
    "run-time ammo (the source's webhook secrets) + the dev bundle + the full bundle + the target DB" \
    "RUNNABLE. Three assertions, none reimplemented here: (1) the dev bundle is CLEAN; (2) the SAME ammo FIRES on the one full bundle (the positive control — a scan that has never fired is not an instrument); (3) the TARGET DB is scanned via \`pds-secret-scan.sh scan --db \$PDS_SCRATCH_DB\` and the step FAILS when UNSCANNED > 0 or when zero tables were scanned — that script's own exit code is driven only by HITS (PDS-D68), so an unreadable table would otherwise print CLEAN with the secret sitting in the database. The instrument's OWN control (\`pds-secret-scan.sh control\`, a locally seeded throwaway fixture that spends NO guerrilla export) no longer waits for a hand-set PDS_CONTROL_PG: the maintenance connection is RESOLVED — the scratch target's own server, then the local libpq default — and a candidate is accepted only when the SERVER answers that it is unix/loopback, that the role may CREATE DATABASE and that it is not the source production database. NOT RUN survives only as a named refusal, never as a silent default."

  plan_row 5 "SERVED ASSET — every imported asset serves HTTP 200 with a matching content-length" \
    "step 1 imported blobs into the scratch target" \
    "RUNNABLE. Resolves from the TARGET's OWN /v1/media/:dataset (the flat /media index emits no originalUrl and ignores limit) and takes originalUrl and size VERBATIM per asset — originalUrl may be signed, so it is never rebuilt from a path. ASSERTS HTTP 200 AND content-length == the stored size for EVERY asset. FAILURE DEMO, run inline and reversed: one blob truncated to 100 bytes still serves 200 — only the stored size convicts it. SEPARATE ASSERTION: a missing blob answers the typed 404 'media blob missing', never a 500."

  plan_row 6 "CONVERGENCE — the imported state survives a REBOOT (PDS-D23/PDS-D62/PDS-D65)" \
    "step 1's import, stamped" \
    "RUNNABLE. Reboot is \`bin/barkpark stop\` then \`up\` in the SAME BARKPARK_HOME — there is NO restart verb and teardown stops Postgres. ASSERTS the eight columns the boot-time schema upsert would otherwise revert (title, icon, visibility, owner_scoped, fields, cors_origins, desk_groups, list_preview) are byte-identical across the reboot, and the pull_provenance stamp survives. THEN — sequenced AFTER the convergence it demonstrates against — the guard is switched OFF by direct SQL (no CLI/HTTP surface exists) with the RETURNING value ASSERTED, because jsonb_set is a proven silent no-op when the parent path is absent, and the next boot must CLOBBER those columns. A demo that fails to clobber makes the convergence green uninterpretable and is reported as a FAIL."

  plan_row 7 "THE NEGATIVE GUARD — a MERGE import against the SOURCE is refused 403" \
    "the source answers HTTP" \
    "RUNNABLE, and it PASSES. SCOPE (PDS-D73): :allow_bundle_import wraps ONLY the merge branch — clean is the DEFAULT mode and is UNGATED — so the claim is 'the source refuses a MERGE import', never 'the source cannot be written'. Re-derived at RUN time on purpose: this is a blue/green box and a deploy could land between the survey and the run. The single point of failure is anyone appending BARKPARK_ALLOW_BUNDLE_IMPORT=1 to an env source."

  plan_row 8 "CLOSING RE-PIN — the box must not have redeployed under the run (PDS-D72)" \
    "step 0a captured a sha and/or an uptime baseline" \
    "RUNNABLE whenever 0a ran. The deployed sha is captured ONCE at the top and every differential above is dated by it; this box has redeployed three times inside one 15-minute survey, Caddy flipping :4000 → :4001 mid-command. ASSERTS the sha re-read over SSH equals 0a's, with /status.json's uptime_seconds going BACKWARDS as the SSH-free fallback. A drift is a FAIL (the signal fired); no signal at all is an ABORT (never a silent pass)."

  rule
  say "Run it:  $0 --all      (or --only 0a,0b,7)"
  rule
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# THE SWEEP — the pre-existing backlog, and the four things it REFUSES
# ═════════════════════════════════════════════════════════════════════════════
#
# The trap above only ever owns the directories THIS harness creates from here
# on. The 952 MB already on disk predates it, so it needs a deliberate operator
# verb — and that verb's whole design is what it will NOT touch:
#
#   REFUSED  a name this harness does not make      (not $ART_ROOT/pds-proof-art.<hex>)
#   REFUSED  a directory owned by another unix user (stat uid != ours)
#   REFUSED  a marker naming a LIVE pid on THIS host — a concurrent cycle owns it
#   REFUSED  a directory younger than PDS_SWEEP_MIN_AGE_HOURS (default 24) when
#            it carries no marker at all — the legacy backlog is unmarked, so
#            "no marker" can never by itself mean "abandoned"
#   REFUSED  this run's own ART_DIR
#
# It is a DRY RUN unless --apply is passed, and it prints the reason for every
# directory on both sides of the line. There is no wildcard rm anywhere in it:
# each removal names one path the loop proved it owns.

art_uid_of() { # dir -> numeric owner uid ('' when unreadable)
  # GNU FIRST, BSD second — never the reverse. On GNU coreutils `-f` means
  # FILESYSTEM status, so `stat -f %s` SUCCEEDS on Linux with a block-count
  # report instead of failing, and a BSD-first `||` chain never reaches the
  # GNU form. BSD stat rejects `-c` outright, so GNU-first fails loudly on
  # the wrong platform instead of quietly.
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
}

art_dir_age_hours_ok() { # dir min_hours -> 0 when OLDER than min_hours
  local d="$1" h="$2" found
  found="$(find "$d" -maxdepth 0 -mmin +"$((h * 60))" 2>/dev/null || true)"
  [ -n "$found" ]
}

cmd_sweep_artifacts() { # [--apply]
  local apply=0 d name uid me pid host marker min_age kb
  [ "${1:-}" = "--apply" ] && apply=1
  min_age="${PDS_SWEEP_MIN_AGE_HOURS:-24}"
  me="$(id -u)"

  rule
  say "PDS CROWN PROOF — ARTIFACT SWEEP over $ART_ROOT/pds-proof-art.*"
  say "$([ "$apply" = 1 ] && echo 'MODE: --apply — proven-owned directories WILL be removed' || echo 'MODE: dry run — nothing is removed. Re-run with --apply to act.')"
  say "unmarked directories must be older than ${min_age}h · this run is $RUN_ID (tag $RUN_TAG)"
  rule

  local n_own=0 n_refused=0 bytes_own=0
  for d in "$ART_ROOT"/pds-proof-art.*; do
    [ -e "$d" ] || continue
    name="$(basename "$d")"
    if [ ! -d "$d" ]; then
      printf '  REFUSED  %-46s not a directory\n' "$name"; n_refused=$((n_refused + 1)); continue
    fi
    case "$name" in
      pds-proof-art.*[!0-9a-f]*|pds-proof-art.)
        printf '  REFUSED  %-46s not a name this harness makes (expected pds-proof-art.<hex run tag>)\n' "$name"
        n_refused=$((n_refused + 1)); continue ;;
    esac
    if [ "$d" = "$ART_DIR" ]; then
      printf '  REFUSED  %-46s THIS run owns it and is still using it\n' "$name"
      n_refused=$((n_refused + 1)); continue
    fi
    uid="$(art_uid_of "$d")"
    if [ -z "$uid" ] || [ "$uid" != "$me" ]; then
      printf '  REFUSED  %-46s owned by uid %s, not by uid %s — another unix user\n' "$name" "${uid:-unreadable}" "$me"
      n_refused=$((n_refused + 1)); continue
    fi
    marker="$(art_marker_field run_id "$d")"
    if [ -n "$marker" ]; then
      pid="$(art_marker_field pid "$d")"
      host="$(art_marker_field host "$d")"
      if [ "$host" != "$(uname -n 2>/dev/null || echo unknown)" ]; then
        printf '  REFUSED  %-46s marker names host %s, not this one — liveness undecidable here\n' "$name" "${host:-unknown}"
        n_refused=$((n_refused + 1)); continue
      fi
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '  REFUSED  %-46s pid %s is ALIVE on this host — a concurrent run owns it (%s)\n' "$name" "$pid" "$marker"
        n_refused=$((n_refused + 1)); continue
      fi
    elif ! art_dir_age_hours_ok "$d" "$min_age"; then
      printf '  REFUSED  %-46s no owner marker AND younger than %sh — cannot be proved abandoned\n' "$name" "$min_age"
      n_refused=$((n_refused + 1)); continue
    fi

    n_own=$((n_own + 1))
    kb="$(du -sk "$d" 2>/dev/null | awk 'NR==1{print $1}')"
    case "${kb:-}" in ''|*[!0-9]*) kb=0 ;; esac
    bytes_own=$((bytes_own + kb))
    if [ "$apply" = 1 ]; then
      rm -rf "$d" 2>/dev/null || true
      printf '  REMOVED  %-46s %s\n' "$name" "$([ -n "$marker" ] && echo "marker run $marker, pid ${pid:-?} not alive" || echo "unmarked and older than ${min_age}h")"
    else
      printf '  WOULD    %-46s %s\n' "$name" "$([ -n "$marker" ] && echo "marker run $marker, pid ${pid:-?} not alive" || echo "unmarked and older than ${min_age}h")"
    fi
  done

  rule
  say "$n_own directory(ies) proved owned ($((bytes_own / 1024)) MB) · $n_refused refused"
  [ "$apply" = 1 ] || say "Nothing was removed. Re-run: $SELF --sweep-artifacts --apply"
  rule
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# THE BANNER — the transcript opens by bounding every claim it is about to make
# ═════════════════════════════════════════════════════════════════════════════

banner() {
  local worktree_sha worktree_desc
  worktree_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  worktree_desc="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

  rule
  say "PDS CROWN PROOF — run $RUN_ID"
  rule
  say "HONESTY BANNER — what this transcript does and does not claim."
  say ""
  say "  SOURCE          $SOURCE_BASE (workspace=$SOURCE_WS dataset=$SOURCE_DS)"
  if [ -n "${PDS_DEPLOYED_SHA:-}" ]; then
    say "  PIN OVERRIDE    PDS_DEPLOYED_SHA IS SET (${PDS_DEPLOYED_SHA}). If step 0a resolves"
    say "                  no sha over SSH it will use that value — BELIEVED, not measured"
    say "                  against the box this run. Every line dating a claim by it then"
    say "                  says OPERATOR-ASSERTED, and step 8's sha re-pin is skipped,"
    say "                  because a measured re-pin would convict the assertion rather"
    say "                  than a redeploy. A measured pin always wins over this one."
  fi
  say "  SERVED          resolved live in step 0a and printed there — version AND"
  say "                  git sha. Auto-deploy has been observed NOT firing, so the"
  say "                  box may be running older code than main; if it is, the"
  say "                  transcript says so in step 0a/0b rather than blaming a slice."
  say "  PLANE           the proof runs on THIS host against a disposable"
  say "                  personal-local target ($BARKPARK_HOME), booted by"
  say "                  scripts/pds-scratch-target.sh. Nothing is written to the"
  say "                  source: every source call here is a GET, a read-only psql,"
  say "                  or the import POST of step 7 whose whole point is being REFUSED."
  say "  WORKTREE        $worktree_sha ($worktree_desc)"
  say ""
  say "  SCOPE OF EVERY CLAIM BELOW:"
  say "   · Profile scope — the pull and its scans are the DEV profile. A clean dev"
  say "     scan proves the carrying TABLES ARE ABSENT (:deny), never that a field"
  say "     was scrubbed: @dev_scrub is genuinely empty (PDS-D25)."
  say "   · Convergence scope — content-and-presence convergence of the imported"
  say "     rows, not byte-identity of two independently produced tar files."
  say "   · Census scope — raw-perspective row counts per type. Bare-slug E3 tables"
  say "     are EXCLUDED and the shortfall is pre-declared in step 2 (PDS-D45)."
  say "   · Deploy scope — step 0b asserts DEPLOY PROVENANCE, not migration parity."
  say "     No schema_migrations HTTP surface exists; a stale build prints the same"
  say "     /status.json green (PDS-D47). Step 8 re-pins the same sha at the CLOSE:"
  say "     everything between them is dated by ONE build or the run says so."
  say "   · Artifact scope — this run's artifacts live at $ART_DIR and are removed"
  say "     by its own EXIT trap on a clean finish, scoped to a marker naming THIS"
  say "     run. No other session's directory is ever touched; the backlog needs the"
  say "     deliberate \`$SELF --sweep-artifacts --apply\`, which refuses by name"
  say "     anything it cannot prove it owns."
  say "   · Refusal scope — step 7 proves the source refuses a MERGE import. The"
  say "     clean/restore mode is NOT gated by that flag, so 'guerrilla cannot be"
  say "     written' is a claim this transcript does not make (PDS-D73)."
  say "   · Asset scope — step 5 asserts served bytes against the size the TARGET's"
  say "     own database stores. It does not compare bytes against the SOURCE."
  say "   · Full-export scope — exactly ONE full-fidelity export is taken per store,"
  say "     and only as the FIRING control for steps 3 and 4. Its memory figure is"
  say "     measured by a 1 Hz ps sampler over SSH during that export; no cgroup"
  say "     number and no survey number is reprinted as this run's."
  say "   · Full-export GATE scope — precondition (b) asserts a CONJUNCTION: the"
  say "     source's MemAvailable is at or above ${FULL_MIN_MEM_MB} MB AND the live beam.smp"
  say "     has at most ${FULL_MAX_SWAP_MB} MB of itself swapped out, both read in ONE probe"
  say "     immediately before the request. The second half is not decoration:"
  say "     MemAvailable RISES as the BEAM is evicted (measured 2026-07-20 —"
  say "     MemAvailable 1,586,644 -> 2,984,512 kB while beam VmSwap rose"
  say "     51,624 -> 874,760 kB), so a floor read ALONE opens most reliably in"
  say "     the most dangerous state and is not a safety property (PDS-D741)."
  say "     WHAT IT STILL DOES NOT CLAIM: it is a point-in-time reading taken"
  say "     before a multi-minute export, not a reservation — nothing holds that"
  say "     memory, the box can degrade the instant after the probe, and no"
  say "     precondition on this box makes a ONE-BINARY ~1.03 GB export safe."
  say "     Only streaming the export removes the allocation; the gate narrows"
  say "     the window, it does not close it."
  say "   · RSS scope — that peak is WHOLE-PROCESS beam.smp RSS over the export"
  say "     window, NOT export-exclusive. The same BEAM serves the live content"
  say "     API throughout, and \`ps -o rss=\` cannot separate export-caused memory"
  say "     from concurrent request traffic at OS granularity — doing so would"
  say "     need per-Erlang-process instrumentation this harness does not have."
  say "     Read it as a box-level OOM-risk ceiling (PDS-D31), never as the"
  say "     export's own cost."
  say ""
  say "  THE SCAN'S OWN LIMITS, VERBATIM (they bound every 'clean' below):"
  say "   1. VERBATIM-VALUE-BASED ONLY. It matches the exact bytes it was given. It"
  say "      does NOT detect derived material — base64/hex re-encodings, prefix"
  say "      slices, HMACs, hashes, or values inside compressed members."
  say "   2. ABSENCE-OF-GIVEN-VALUES ONLY. A clean result proves the target is free"
  say "      of the values you ENUMERATED — never that it is free of secrets nobody"
  say "      enumerated."
  rule
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0a — SOURCE FRESHNESS
# ═════════════════════════════════════════════════════════════════════════════

step_0a() {
  head_step 0a "SOURCE FRESHNESS — pin the source before believing any differential"

  local status code version uptime
  status="$(mktmp)"
  code="$(http_code "$(bp_curl_code -sS -o "$status" --max-time 30 "$SOURCE_BASE/status.json" 2>/dev/null || true)")"
  if [ "$code" != "200" ]; then
    fail 0a "GET $SOURCE_BASE/status.json -> $code (the source is not answering; nothing downstream is believable)"
    return 0
  fi
  version="$(jqp 'd["version"]' <"$status" || echo unknown)"
  uptime="$(jqp 'd.get("uptime_seconds","?")' <"$status" || echo '?')"
  DEPLOYED_VERSION="$version"
  # The step-8 baseline. uptime_seconds going BACKWARDS is the SSH-free proof
  # that the BEAM this run has been talking to was replaced under it (PDS-D72).
  case "$uptime" in
    ''|*[!0-9]*) DEPLOYED_UPTIME_0A="" ;;
    *) DEPLOYED_UPTIME_0A="$uptime" ;;
  esac
  info "status.json     status=$(jqp 'd["status"]' <"$status" || echo '?') version=$version uptime_seconds=$uptime"
  info "step-8 baseline uptime_seconds=${DEPLOYED_UPTIME_0A:-UNAVAILABLE} — re-read at close; backwards means the box redeployed mid-run"

  # The sha, three ways — the version string above is NOT one (it is a marketing
  # number and two different builds print it identically).
  if ssh_available; then
    DEPLOYED_SHA="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
    [ -n "$DEPLOYED_SHA" ] && DEPLOYED_SHA_SOURCE="ssh"
    info "deployed sha    $DEPLOYED_SHA  (source of truth: the box's own git HEAD over SSH)"
  else
    info "deployed sha    UNRESOLVED over SSH ($SOURCE_SSH, key $SOURCE_SSH_KEY)"
  fi
  apply_deployed_sha_override
  if command -v gh >/dev/null 2>&1; then
    local last_deploy
    last_deploy="$(gh run list --workflow deploy.yml --branch main --limit 1 \
      --json headSha,conclusion,createdAt -q '.[]|"\(.headSha[0:9]) \(.conclusion) \(.createdAt)"' 2>/dev/null || true)"
    info "last deploy run ${last_deploy:-none visible (auto-deploy may not be firing — see task-85eb87a30db908ec)}"
  fi

  # The one budgeted export: DEV profile. Never :full here (PDS-D31/PDS-D44).
  art_dir_ensure
  local bundle hdr t0 t1 bytes elapsed fname
  bundle="$ART_DIR/dev-$SOURCE_WS-$SOURCE_DS.tar"
  hdr="$(mktmp)"
  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around an HTTP/CLI call issued
  # from THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock
  # OUTSIDE every BEAM. It has to be: the BEAM doing the work is the SERVER, on
  # another host, and there is no in-BEAM meter this instrument could reach even
  # if it wanted one. The unit is wall by necessity and the figure is quoted as a
  # LATENCY, never as a price: PDS-D605 forbids a wall-clock second standing in
  # for CPU (wall swung 2.5x on an unchanged census where user CPU moved 9%), so
  # nothing here may be read as what the export COST. A price for this instrument
  # comes from `pds-door-census.sh --measure`; a regression ratchet would need
  # `Process.info(pid, :reductions)`, which a shell has not got.
  t0="$(date +%s)"
  code="$(curl_src "/api/workspaces/$SOURCE_WS/export?profile=dev&dataset=$SOURCE_DS" \
            -D "$hdr" -o "$bundle" -w '%{http_code}' 2>/dev/null || true)"; code="$(http_code "$code")"
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  bytes="$(first_int "$(wc -c <"$bundle" 2>/dev/null | tr -d ' ')")"
  fname="$(grep -i '^content-disposition:' "$hdr" | sed -n 's/.*filename=\"\{0,1\}\([^\";]*\).*/\1/p' | tr -d '\r' || true)"
  info "dev export      HTTP $code · $bytes bytes · ${elapsed}s · filename=${fname:-none}"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around an HTTP/CLI call issued from this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM doing the work is the remote SERVER, so no in-BEAM meter is reachable. A LATENCY, never a price (PDS-D605)" \
    "dev export"

  if [ "$code" != "200" ] || ! int_ok "$bytes" || [ "$bytes" -lt 1024 ]; then
    fail 0a "dev export returned HTTP $code / ${bytes:-unreadable} bytes — guerrilla is running older code than main (served sha ${DEPLOYED_SHA:-unresolved}, version $version)"
    return 0
  fi

  local mdir profile dataset src_ws src_ds has_src_server members
  mdir="$(mktemp -d "${TMPDIR:-/tmp}/pds-manifest.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $mdir"
  if ! tar -xf "$bundle" -C "$mdir" manifest.json 2>/dev/null; then
    fail 0a "the export is not a bp-export-v1 bundle — no manifest.json member"
    return 0
  fi
  members="$(first_int "$(tar -tf "$bundle" | wc -l | tr -d ' ')")"
  profile="$(jqp 'd.get("profile")' <"$mdir/manifest.json" || echo None)"
  dataset="$(jqp 'd.get("dataset")' <"$mdir/manifest.json" || echo None)"
  src_ws="$(jqp 'd.get("source_workspace")' <"$mdir/manifest.json" || echo None)"
  src_ds="$(jqp 'd.get("source_dataset")' <"$mdir/manifest.json" || echo None)"
  has_src_server="$(jqp '"source_server" in d' <"$mdir/manifest.json" || echo False)"
  info "manifest        format=$(jqp 'd.get("format")' <"$mdir/manifest.json") members=$members"
  info "                profile=$profile dataset=$dataset source_workspace=$src_ws source_dataset=$src_ds source_server_key=$has_src_server"

  if [ "$profile" != "dev" ] || [ "$dataset" != "$SOURCE_DS" ] || [ "$has_src_server" != "True" ]; then
    fail 0a "the manifest lacks the additive dev dialect (profile=$profile dataset=$dataset source_server_key=$has_src_server) — guerrilla is running older code than main; served sha ${DEPLOYED_SHA:-unresolved}, version $version"
    return 0
  fi

  DEV_BUNDLE="$bundle"
  pass 0a "source pinned: version=$version sha=${DEPLOYED_SHA:-unresolved}$(sha_provenance_note); dev dialect LIVE (HTTP 200, $bytes bytes, ${elapsed}s, $members members, profile=$profile dataset=$dataset, source_* present)"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0b — DEPLOY-PROVENANCE, NOT schema_migrations PARITY (PDS-D47)
# ═════════════════════════════════════════════════════════════════════════════

step_0b() {
  head_step 0b "DEPLOY-PROVENANCE — the assertion schema_migrations parity cannot make"

  say "  WHY NOT MIGRATION PARITY: there is NO schema_migrations HTTP surface"
  say "  anywhere in this API, and the source's Postgres is not reachable"
  say "  externally. /status.json's migrations component is a boolean computed by"
  say "  the RUNNING BINARY over its OWN migration files, so a stale build prints"
  say "  an identical green. That is a green a broken build could also produce, and"
  say "  PDS-D20 forbids it. The assertion made here instead is DEPLOY PROVENANCE:"
  say "  the deployed sha EQUALS OR IS AN ANCESTOR OF the worktree the target"
  say "  migrated from."
  say ""

  if [ -z "$DEPLOYED_SHA" ]; then
    abort 0b "env:deployed-sha-unresolved" \
      "no run-time source of the deployed sha. /status.json carries a version string, not a sha. FIX (in this order): make SSH reachable (PDS_SOURCE_SSH=$SOURCE_SSH, key $SOURCE_SSH_KEY) — that is the only MEASURED pin. Failing that, \`export PDS_DEPLOYED_SHA=<sha>\` from an authenticated source: step 0a reads it, but only when SSH resolved nothing, and every line dating a claim by it then carries the words OPERATOR-ASSERTED, because the harness is believing you rather than the box. Asserting on the version string alone would be exactly the vacuous green this step exists to refuse."
    return 0
  fi

  local worktree_sha ahead code_ahead docs_ahead
  worktree_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo)"
  if [ -z "$worktree_sha" ]; then
    fail 0b "this is not a git checkout — the worktree the target migrated from cannot be named"
    return 0
  fi
  info "deployed  $DEPLOYED_SHA (version $DEPLOYED_VERSION)"
  info "worktree  $worktree_sha"

  if ! git -C "$REPO_ROOT" cat-file -e "$DEPLOYED_SHA^{commit}" 2>/dev/null; then
    fail 0b "the deployed sha $DEPLOYED_SHA is not an object in this checkout — the box is serving code this worktree has never seen"
    return 0
  fi

  if [ "$DEPLOYED_SHA" = "$worktree_sha" ]; then
    pass 0b "deployed sha EQUALS the worktree the target migrated from ($worktree_sha)$(sha_provenance_note)"
    return 0
  fi

  # ANCESTRY IS GUARDED, never bare. `merge-base --is-ancestor` folds "the worktree
  # genuinely does not contain it" and "my walk was truncated before it got there"
  # into the SAME rc=1, and THIS script runs on the CP box, whose checkout the
  # deploy-reliability charter records as SHALLOW. A bare rc=1 there would print
  # FAIL 0b — "the box is serving code this worktree does not contain" — off a
  # question the checkout could not answer. scripts/ancestry-guard.sh probes ref,
  # object and walk-truncation separately and exits 2 when no claim is sound; that
  # is an ABORT (a blocker to clear), never a FAIL (a verdict about the deploy).
  "$REPO_ROOT/scripts/ancestry-guard.sh" --repo "$REPO_ROOT" "$DEPLOYED_SHA" "$worktree_sha" >/dev/null 2>&1
  _anc_rc=$?
  if [ "$_anc_rc" = 2 ]; then
    abort 0b "readable git history" "$("$REPO_ROOT/scripts/ancestry-guard.sh" --repo "$REPO_ROOT" "$DEPLOYED_SHA" "$worktree_sha" 2>&1) — the containment of $DEPLOYED_SHA in $worktree_sha is UNDECIDABLE in this checkout, so neither a pass nor a fail may be recorded. Deepen the checkout (git fetch --unshallow) or re-derive with: gh api repos/FRIKKern/barkpark/compare/$DEPLOYED_SHA...$worktree_sha --jq .status"
    return 0
  fi
  if [ "$_anc_rc" != 0 ]; then
    fail 0b "the deployed sha $DEPLOYED_SHA is NOT an ancestor of the worktree $worktree_sha — the source is serving code this worktree does not contain, so a schema differential against it is unsound"
    return 0
  fi

  ahead="$(git -C "$REPO_ROOT" rev-list --count "$DEPLOYED_SHA..$worktree_sha")"
  code_ahead="$(git -C "$REPO_ROOT" rev-list "$DEPLOYED_SHA..$worktree_sha" -- api internal cloud js web | wc -l | tr -d ' ')"
  docs_ahead=$((ahead - code_ahead))
  info "worktree is $ahead commit(s) ahead: $code_ahead touching code (api/internal/cloud/js/web), $docs_ahead docs-only"
  git -C "$REPO_ROOT" log --oneline "$DEPLOYED_SHA..$worktree_sha" | sed 's/^/      · /'

  if int_ok "$code_ahead" && [ "$code_ahead" -gt 0 ]; then
    info "NOTE: the box is behind on CODE, not only docs. Auto-deploy has been"
    info "observed not firing (task-85eb87a30db908ec). Every source-derived number"
    info "below describes the DEPLOYED build, not main."
  fi

  pass 0b "deploy provenance holds$(sha_provenance_note): the deployed sha $DEPLOYED_SHA IS AN ANCESTOR OF the worktree the target migrated from ($worktree_sha), $ahead commit(s) behind — $code_ahead code, $docs_ahead docs-only"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0c — THE FAIL-CLOSED SENTINELS
# ═════════════════════════════════════════════════════════════════════════════

step_0c() {
  head_step 0c "SENTINELS — Catalog.assert_partition!/1 and assert_dev_partition!/1"

  say "  A NEW tenant table RAISES these sentinels by design. If that happens the"
  say "  transcript reports it as a FAIL with the raise message intact — it is"
  say "  never bypassed, never downgraded, and never 'handled' by narrowing the"
  say "  assertion. An unclassified table is an unproven export."
  say ""

  say "  AND THE REPO MUST BE THE SCRATCH REPO (PDS-D64). \`MIX_ENV=dev mix run\`"
  say "  resolves [hostname: localhost, username: postgres, database: barkpark_dev]"
  say "  — the DEVELOPER'S OWN database — even with BARKPARK_HOME, BARKPARK_PG_PORT,"
  say "  PDS_SCRATCH_DB and DATABASE_URL all pointed at the scratch box, because"
  say "  dev.exs hardcodes host/port/user and DATABASE_URL is read on the prod"
  say "  branch only. So the Repo is started HERE with the scratch conninfo and its"
  say "  identity is asserted from inside the BEAM before either sentinel runs. A"
  say "  'SENTINELS OK' measured against the wrong database is worse than an ABORT."
  say ""

  if ! load_target; then
    abort 0c "env:scratch-target-not-booted" \
      "no Repo to run the sentinels against ($BARKPARK_HOME/scratch.env absent). FIX: $(target_hint)   (budget one ~3.5 min cold compile per NEW worktree so a slow first boot is not mistaken for a hang)."
    return 0
  fi
  if [ -z "$TARGET_DB" ]; then
    abort 0c "env:scratch-db-unknown" \
      "the target booted but its scratch.env carries no PDS_SCRATCH_DB conninfo, so the Repo cannot be aimed at it and a run would silently measure barkpark_dev. FIX: re-boot the target with a current pds-scratch-target.sh ($(target_hint))."
    return 0
  fi

  # Parse libpq conninfo -> the four parts Ecto needs. Written by
  # pds-scratch-target.sh as: host=… port=… dbname=… user=…
  # Same reader as load_target's warning (conninfo_part), so the abort below
  # cannot disagree with the WARN line about which keys are missing.
  local pg_host pg_port pg_db pg_user missing
  pg_host="$(conninfo_part host "$TARGET_DB")"
  pg_port="$(conninfo_part port "$TARGET_DB")"
  pg_db="$(conninfo_part dbname "$TARGET_DB")"
  pg_user="$(conninfo_part user "$TARGET_DB")"
  missing="$(conninfo_missing_keys "$TARGET_DB")"
  if [ -n "$missing" ]; then
    abort 0c "env:scratch-db-unparsed" \
      "PDS_SCRATCH_DB did not parse into host/port/dbname/user — MISSING: $missing ('$TARGET_DB'). A hand-written scratch.env must QUOTE the value (export PDS_SCRATCH_DB=\"host=… port=… dbname=… user=…\"); sourcing an unquoted multi-field assignment keeps only the first field. Refusing to fall back to the ambient dev Repo."
    return 0
  fi
  info "scratch Repo    host=$pg_host port=$pg_port dbname=$pg_db user=$pg_user (from scratch.env, not from dev.exs)"

  local out rc
  out="$(mktmp)"
  rc=0
  # --no-start: no supervision tree, no dev Repo. The Repo below is started by
  # hand with the scratch conninfo, and PROVES where it landed before asserting
  # anything about a partition.
  ( cd "$API_DIR" && \
    PDS_PG_HOST="$pg_host" PDS_PG_PORT="$pg_port" PDS_PG_DB="$pg_db" PDS_PG_USER="$pg_user" \
    MIX_ENV=dev mix run --no-start -e '
      alias Barkpark.Tenancy.WorkspaceBundle.Catalog

      want_db   = System.get_env("PDS_PG_DB")
      want_port = String.to_integer(System.get_env("PDS_PG_PORT"))

      # --no-start starts NO applications, so DBConnection.Watcher and
      # Ecto.Repo.Registry do not exist and Repo.start_link/0 dies with
      # "no process ... possibly because its application is not started".
      # :postgrex ALONE is insufficient — the Ecto registry is next (PDS-D94).
      {:ok, _} = Application.ensure_all_started(:ecto_sql)
      {:ok, _} = Application.ensure_all_started(:postgrex)

      Application.put_env(:barkpark, Barkpark.Repo,
        hostname: System.get_env("PDS_PG_HOST"),
        port: want_port,
        database: want_db,
        username: System.get_env("PDS_PG_USER"),
        password: System.get_env("PDS_PG_PASSWORD") || "",
        pool_size: 2
      )

      {:ok, _} = Barkpark.Repo.start_link()

      %{rows: [[got_db, got_port]]} =
        Barkpark.Repo.query!("SELECT current_database(), inet_server_port()")

      IO.puts("REPO IS #{got_db}:#{got_port}")

      if got_db != want_db or got_port != want_port do
        IO.puts("REPO MISMATCH — wanted #{want_db}:#{want_port}")
        System.halt(9)
      end

      :ok = Catalog.assert_partition!(Barkpark.Repo)
      :ok = Catalog.assert_dev_partition!(Barkpark.Repo)
      IO.puts("SENTINELS OK")
    ' ) >"$out" 2>&1 || rc=$?

  local repo_line
  repo_line="$(grep -m1 '^REPO IS ' "$out" 2>/dev/null || true)"
  [ -n "$repo_line" ] && info "$repo_line (asserted from inside the BEAM, not from the env it was handed)"

  if [ "$rc" -eq 9 ] || grep -q 'REPO MISMATCH' "$out" 2>/dev/null; then
    info "$(tail -20 "$out" | sed 's/^/  /')"
    abort 0c "env:repo-resolved-elsewhere" \
      "the Repo did NOT land on the scratch database ($pg_db:$pg_port) — see the mismatch above. Refusing to report a sentinel result measured against another database (PDS-D64)."
    return 0
  fi

  if [ "$rc" -eq 0 ] && grep -q 'SENTINELS OK' "$out"; then
    pass 0c "both sentinels returned :ok against the SCRATCH Repo (proven $pg_db:$pg_port from inside the BEAM) — the live tenant-table membership matches the reviewed E1/E2/E3 partition AND every bundle-reachable table has a dev-partition classification"
  elif [ -z "$repo_line" ]; then
    # The run never printed 'REPO IS ', so the Repo never connected and NEITHER
    # sentinel ever executed. Reporting that as "a sentinel RAISED" invents an
    # ENGINE finding out of an environment failure — the most expensive line an
    # append-only transcript can carry (PDS-D96).
    info "$(tail -20 "$out" | sed 's/^/  /')"
    # rc=0 here means the heredoc RAN TO COMPLETION yet printed neither marker,
    # which is not a connection failure but an unrecognised harness state — say
    # so rather than guessing a cause, since guessing is the defect D96 fixes.
    if [ "$rc" -eq 0 ]; then
      fail 0c "the 0c probe exited 0 but printed NEITHER 'REPO IS' NOR 'SENTINELS OK' — an unrecognised state, not a measurement. The cause is UNDIAGNOSED (the probe's own output is above); what is certain is that NEITHER sentinel is known to have run against $pg_db:$pg_port, so the sentinels are UNMEASURED — this is NOT a partition finding. File it as a HARNESS bug, never as an engine one."
    else
      fail 0c "the scratch Repo never connected (exit $rc) — no 'REPO IS' line was printed, so NEITHER sentinel ran. This is a BOOT failure against $pg_db:$pg_port, NOT a partition finding: the sentinels are UNMEASURED, neither passed nor failed. See the tail above."
    fi
  else
    info "$(tail -20 "$out" | sed 's/^/  /')"
    fail 0c "a sentinel RAISED (exit $rc) after the Repo reached $pg_db:$pg_port — see the message above. A new/unclassified tenant table must be classified, not bypassed."
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — THE PULL
# ═════════════════════════════════════════════════════════════════════════════

# manifest_field <tar> <key> -> the value on stdout. Extracts ONLY manifest.json,
# never the whole bundle.
#
# THE EXIT CODE IS THE ANSWER TO A SECOND QUESTION (PDS-D261). This function used
# to `printf '\n'; return 0` on EVERY failure it has, so its caller could not tell
# "this bundle's manifest genuinely carries no such key" — the legacy pre-profile
# engine — from "this file is not a bundle and nothing could be read out of it".
# Collapsing those two into one empty string is what let `case "$p" in ""|full)`
# accept an HTML error page as a full-fidelity bundle.
#
#   0 = the manifest was read and the key is PRESENT (its value is on stdout)
#   1 = the manifest was read and the key is ABSENT  (stdout empty)
#   2 = NOTHING could be read: no extractable manifest.json, or it is not a JSON
#       object (stdout empty)
#
# stdout is unchanged for every existing caller — a caller that ignores the exit
# code behaves exactly as before. Callers that must tell 1 from 2 read $?.
manifest_field() {
  local tar="$1" key="$2" d out rc
  d="$(mktemp -d "${TMPDIR:-/tmp}/pds-mf.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $d"
  if ! tar -xf "$tar" -C "$d" manifest.json 2>/dev/null || [ ! -s "$d/manifest.json" ]; then
    printf '\n'
    return 2
  fi
  out="$(KEY="$key" python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(2)
if not isinstance(d, dict):
    raise SystemExit(2)
v = d.get(os.environ["KEY"])
if v is None:
    raise SystemExit(1)
print(v)' "$d/manifest.json" 2>/dev/null)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# ── THE GRAIN VERDICT, AS ONE CALLABLE (PDS-D20) ─────────────────────────────
#
# The PDS-D61/PDS-D62 grain-hazard guard used to live INLINE in step_1, which is why
# it was the one asserting rung nobody could point a control at. It is the same
# comparison, moved behind a name so a locally built bundle can be put through
# the EXACT assertion the live bundle goes through. stdout and the exit code of
# every branch step_1 prints are unchanged — the abort/fail/info wording below is
# byte-for-byte what it was.
#
# grain_verdict <tar> <want_dataset> -> one line on stdout:
#     <verdict>|<profile>|<dataset>|<profile_rc>|<dataset_rc>
#
#   ok                the manifest is dev-profile and dataset-grain, as asked
#   no-dataset        NO dataset field: a WORKSPACE-grain bundle (or nothing was
#                     readable at all — manifest_field rc 2, PDS-D261)
#   dataset-mismatch  a dataset field naming a DIFFERENT dataset
#   profile-mismatch  right dataset, but not the scrubbed dev profile
grain_verdict() {
  local tar="$1" want="$2" p d prc=0 drc=0 v
  p="$(manifest_field "$tar" profile)" || prc=$?
  d="$(manifest_field "$tar" dataset)" || drc=$?
  if [ -z "$d" ]; then
    v="no-dataset"
  elif [ "$d" != "$want" ]; then
    v="dataset-mismatch"
  elif [ "$p" != "dev" ]; then
    v="profile-mismatch"
  else
    v="ok"
  fi
  printf '%s|%s|%s|%s|%s\n' "$v" "$p" "$d" "$prc" "$drc"
}

# THE ROUTING IS DATA, NOT A COMMENT. step_1 raises its ABORT with whatever this
# returns, so the control can assert that a workspace-grain manifest really does
# route to pds-w4-pull-dataset-flag — if someone re-points the branch, the
# control reds instead of silently agreeing with itself.
GRAIN_ABORT_TASK="pds-w4-pull-dataset-flag"
grain_blocker() { # <verdict> -> the bp task an ABORT on that verdict waits on
  case "$1" in
    no-dataset) printf '%s\n' "$GRAIN_ABORT_TASK" ;;
    *)          printf '\n' ;;
  esac
}

# ── STEP 1'S NEGATIVE CONTROL (PDS-D20) ──────────────────────────────────────
#
# Step 1 was, until this control, the ONLY asserting rung with nothing that
# FIRES. It had been run live and its assertion had MATCHED against a real
# export — which proves the assertion was evaluated, and proves nothing at all
# about whether it is capable of refusing. An assertion never observed failing is
# not known to assert.
#
# So: build the mis-grained bundles here, on this machine, and put them through
# grain_verdict — the same function the live bundle goes through, in the same
# process, this run. It needs no network, no export, no credentials and no target,
# which is why it runs BEFORE the environment preconditions: a default run on any
# machine exercises it even when the rung goes on to ABORT for want of a target.
#
# Returns 0 when every fixture was classified as expected; on any miss it has
# ALREADY called `fail 1` and returns 1 — a control that does not fire is a FAIL
# of the step it controls, never a footnote.
GRAIN_DEMO_NOTE=""
grain_control() {
  local dir want other name expect body json f v n=0 bad=0 blk
  dir="$(mktemp -d "${TMPDIR:-/tmp}/pds-grain.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $dir"
  want="$SOURCE_DS"
  other="$SOURCE_DS-not-the-one-asked-for"

  say ""
  info "GRAIN CONTROL (PDS-D20) — the SAME assertion, this run, against manifests"
  info "  built HERE (no network, no export, no credentials). The manifest line"
  info "  below is a measurement only if this assertion has been SEEN to refuse:"

  while IFS='|' read -r name expect body; do
    [ -z "${name:-}" ] && continue
    f="$dir/$name.tar"
    if [ "$body" = "@NOTATAR@" ]; then
      # not a tar at all — the HTML error page of PDS-D261. manifest_field
      # answers rc 2 (nothing readable), which must still be a refusal.
      printf '<html><body>502 Bad Gateway</body></html>\n' >"$f"
    else
      json="$(printf '%s' "$body" | sed -e "s#@WANT@#$want#g" -e "s#@OTHER@#$other#g")"
      mkdir -p "$dir/$name"
      printf '%s\n' "$json" >"$dir/$name/manifest.json"
      tar -cf "$f" -C "$dir/$name" manifest.json
    fi
    v="$(grain_verdict "$f" "$want" | cut -d'|' -f1)"
    n=$((n + 1))
    if [ "$v" = "$expect" ]; then
      info "  $name -> $v (expected $expect)"
    else
      info "  $name -> $v (expected $expect)  *** DID NOT FIRE ***"
      bad=$((bad + 1))
    fi
  done <<'GRAIN_FIXTURES'
happy-dev-dataset|ok|{"profile":"dev","dataset":"@WANT@"}
workspace-grain-no-dataset|no-dataset|{"profile":"dev"}
wrong-dataset|dataset-mismatch|{"profile":"dev","dataset":"@OTHER@"}
unscrubbed-profile|profile-mismatch|{"profile":"full","dataset":"@WANT@"}
not-a-bundle-at-all|no-dataset|@NOTATAR@
GRAIN_FIXTURES

  if [ "$bad" -ne 0 ]; then
    fail 1 "THE GRAIN CONTROL DID NOT FIRE: $bad of $n locally built manifests were classified WRONG by the same grain assertion the live bundle goes through. Until it has been shown capable of refusing a workspace-grain bundle, step 1's manifest line proves only that the comparison was evaluated (PDS-D20). Nothing was exported and nothing was imported."
    return 1
  fi
  blk="$(grain_blocker no-dataset)"
  if [ "$blk" != "pds-w4-pull-dataset-flag" ]; then
    fail 1 "THE GRAIN CONTROL DID NOT FIRE: a dataset-less (workspace-grain) manifest routes to blocker '${blk:-<none>}', not the pds-w4-pull-dataset-flag ABORT this rung claims to raise for it (PDS-D61/PDS-D62). Nothing was exported and nothing was imported."
    return 1
  fi
  info "  $n/$n classified as expected, and a workspace-grain manifest routes to ABORT $blk."
  return 0
}

# WHAT pds-w1-pull-cli ACTUALLY SHIPPED (corrected at wave-3 review). This step
# was authored expecting a single `bp dev pull` verb. That verb does NOT exist:
# the pull front door landed as the EXISTING pair, extended —
#
#   bp cloud workspace export <ws> --profile dev --dataset <ds> \
#        --file <tar> --with-blobs [--blobs <dir>]
#   bp cloud workspace import <ws> --file <tar> --yes --merge --with-blobs [--blobs <dir>]
#
# (a single-verb wrapper was filed and REFUSED by the dedup wall as a duplicate
# of that slice — the two composable verbs ARE the front door). So this step does
# NOT self-green on merge: pds-w1-crown-proof must wire the pair, carrying the tar
# path and the sidecar dir between the two commands and pointing the second at the
# scratch target's own base URL + admin token from $BARKPARK_HOME/scratch.env. The
# `bp dev pull` probe below is kept because it is free and correct IF that verb
# ever lands (pds-bl / wave 5).
step_1() {
  head_step 1 "THE PULL — export --profile dev + import --yes --merge (both --with-blobs)"

  say "  ENV DIALECT (PDS-D63): BARKPARK_TOKEN is read NOWHERE by this CLI. Both"
  say "  calls below carry an explicit -s <base> --token <tok>, and the two are"
  say "  never the same pair — the source token is a PRODUCTION admin token and a"
  say "  mirrored typo would aim it at production."
  say ""

  # ── the negative control, BEFORE the preconditions ────────────────────────
  #
  # Deliberately ahead of load_target/ensure_bp: it needs neither, and putting it
  # after them would mean a machine with no scratch target ABORTs step 1 without
  # ever exercising the assertion — which is the vacuous default this control
  # exists to remove. On by default (PDS_STEP1_GRAIN_DEMO=0 to skip).
  if [ "${PDS_STEP1_GRAIN_DEMO:-1}" = "1" ]; then
    grain_control || return 0
    GRAIN_DEMO_NOTE=" The grain assertion was CONTROLLED this run: five manifests built on this machine were put through it and it refused every mis-grained one — a dataset-less workspace-grain bundle routes to ABORT $GRAIN_ABORT_TASK — while accepting the correctly grained one."
  else
    GRAIN_DEMO_NOTE=" NOTE: the grain control was DISABLED (PDS_STEP1_GRAIN_DEMO=0), so nothing this run proved the manifest-grain assertion is capable of REFUSING a workspace-grain bundle; the green is weaker for it."
    info "grain control   DISABLED (PDS_STEP1_GRAIN_DEMO=0) — the pass below is weaker for it: nothing proved the manifest-grain assertion can refuse"
  fi
  say ""

  if ! load_target; then
    abort 1 "env:scratch-target-not-booted" \
      "there is no target to import into ($BARKPARK_HOME/scratch.env absent). FIX: $(target_hint)"
    return 0
  fi
  if ! ensure_bp; then
    abort 1 "env:bp-dialect-unavailable" \
      "no bp that speaks the pull dialect: $BP_WHY. The INSTALLED bp must not be substituted — it predates --profile/--dataset/--merge/--with-blobs and would send an un-scoped, un-merged request."
    return 0
  fi

  # ── the target's lifecycle CHECK, BEFORE a single row moves (PDS-D32) ─────
  #
  # Named here, or discovered later as an opaque engine error. The query is one
  # catalog read against a target this run is about to write to anyway.
  # `x="$(cmd | head -1)" || rc=$?` would read HEAD's exit code, never the
  # query's — the PDS-D99 shape this file documents. The substitution is taken
  # alone so the `if !` sees tgt_psql's own status, and only then trimmed.
  local lc_def lc_raw lc_rc lc_missing
  lc_rc=0; lc_raw=""
  if ! lc_raw="$(tgt_psql "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'documents_task_lifecycle_status_check' AND t.relname = 'documents' AND n.nspname = 'public'")"; then
    lc_rc=1
  fi
  lc_def="$(printf '%s\n' "$lc_raw" | head -1)"
  if [ "$lc_rc" -ne 0 ]; then
    abort 1 "env:target-constraint-unreadable" \
      "the target's catalog could not be read through \`$TARGET_TREE/bin/barkpark psql\` (the catalog query returned non-zero), so nothing here knows whether documents_task_lifecycle_status_check accepts the 7 lifecycle values this bundle carries. An UNKNOWN precondition is not a met one. FIX: $(target_hint)"
    return 0
  fi
  if [ -z "$lc_def" ]; then
    abort 1 "env:target-lifecycle-check-absent" \
      "the target has no public.documents constraint named documents_task_lifecycle_status_check at all. Either the target was never migrated, or the constraint was dropped by hand; in both cases the schema this run would measure is not the schema the proof is about. FIX: re-boot the target from a current worktree ($(target_hint))."
    return 0
  fi
  lc_missing="$(lifecycle_missing_values "$lc_def")"
  if [ -n "$lc_missing" ]; then
    abort 1 "env:target-lifecycle-check-stale" \
      "the target's documents_task_lifecycle_status_check does NOT accept: $lc_missing. That is a PRE-WIDENING target (PDS-D32 migrations 20260719030000 + 20260719030100 take it from 5 values to 7). Importing this bundle would die mid-transaction on a raw CHECK violation the moment a task row carries one of those values — an environmental failure that reads like an import-engine defect. Live constraint: $lc_def   FIX: bring the target's schema up (\`cd \"$TARGET_TREE\" && bin/barkpark eval 'Barkpark.Release.migrate()'\`, or re-boot it: $(target_hint))."
    return 0
  fi
  info "lifecycle CHECK documents_task_lifecycle_status_check accepts all 7 values (open in_progress blocked done cancelled considering researching) — read from the LIVE target, not inferred from a migration file"
  info "bp binary       $BP_BIN (built from $REPO_ROOT this run; its own \`cloud workspace --help\` advertises --profile, --dataset, --merge and --with-blobs)"
  info "target          $TARGET_BASE  (media dir $TARGET_MEDIA)"

  local tar out rc t0 t1
  tar="$ART_DIR/pull-$SOURCE_WS-$SOURCE_DS.tar"
  art_dir_ensure
  out="$(mktmp)"

  # ── the workspaces row BEFORE the import (PDS-D9 adoption fires silently) ──
  local ws_before ws_after
  ws_before="$(tgt_psql "SELECT id || ' ' || slug FROM workspaces ORDER BY inserted_at LIMIT 5" | tr '\n' ';' || true)"

  # ── export ────────────────────────────────────────────────────────────────
  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around an HTTP/CLI call issued
  # from THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock
  # OUTSIDE every BEAM. It has to be: the BEAM doing the work is the SERVER, on
  # another host, and there is no in-BEAM meter this instrument could reach even
  # if it wanted one. The unit is wall by necessity and the figure is quoted as a
  # LATENCY, never as a price: PDS-D605 forbids a wall-clock second standing in
  # for CPU (wall swung 2.5x on an unchanged census where user CPU moved 9%), so
  # nothing here may be read as what the export COST. A price for this instrument
  # comes from `pds-door-census.sh --measure`; a regression ratchet would need
  # `Process.info(pid, :reductions)`, which a shell has not got.
  rc=0; t0="$(date +%s)"
  "$BP_BIN" -s "$SOURCE_BASE" --token "$SOURCE_TOKEN" \
    cloud workspace export "$SOURCE_WS" \
      --profile dev --dataset "$SOURCE_DS" --file "$tar" --with-blobs >"$out" 2>&1 || rc=$?
  t1="$(date +%s)"
  sed 's/^/      /' "$out"
  if [ "$rc" -ne 0 ]; then
    fail 1 "\`cloud workspace export $SOURCE_WS --profile dev --dataset $SOURCE_DS --with-blobs\` exited $rc against $SOURCE_BASE — see above. A non-zero exit here is the CLI's blob-failure contract as well as its HTTP contract; it is never downgraded."
    return 0
  fi
  local bytes blobs_dir n_blobs
  bytes="$(first_int "$(wc -c <"$tar" 2>/dev/null | tr -d ' ')")"
  blobs_dir="$tar.blobs"
  n_blobs="$(first_int "$(find "$blobs_dir" -type f 2>/dev/null | wc -l | tr -d ' ')")"
  info "export          exit 0 · $bytes bytes · $((t1 - t0))s · $n_blobs blob(s) in $blobs_dir"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around an HTTP/CLI call issued from this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM doing the work is the remote SERVER, so no in-BEAM meter is reachable. A LATENCY, never a price (PDS-D605)" \
    "export"

  # ── the GRAIN assertion, before a single byte is imported ──────────────────
  #
  # A workspace-grain bundle wearing a dev command line is the silent-wrong-
  # answer hazard of this whole wave: it imports fine, and every census below
  # then measures a workspace, not the dataset the transcript claims.
  local m_ds m_profile m_prc=0 m_drc=0 m_note m_verdict
  IFS='|' read -r m_verdict m_profile m_ds m_prc m_drc <<GRAIN_VERDICT
$(grain_verdict "$tar" "$SOURCE_DS")
GRAIN_VERDICT
  # rc 2 is NOT "the field is absent" — it is "nothing was readable here". Saying
  # <absent> for both is the conflation PDS-D261 removed from full_meta_ok.
  m_note=""
  [ "$m_prc" -eq 2 ] && m_note=" — manifest UNREADABLE (no extractable manifest.json, or it is not a JSON object), so neither field below is an absence, it is a non-answer"
  info "manifest        profile='${m_profile:-$([ "$m_prc" -eq 2 ] && echo '<unreadable>' || echo '<absent>')}' dataset='${m_ds:-$([ "$m_drc" -eq 2 ] && echo '<unreadable>' || echo '<absent>')}' (asked for profile=dev dataset=$SOURCE_DS)$m_note"
  if [ "$m_verdict" = "no-dataset" ]; then
    abort 1 "$(grain_blocker "$m_verdict")" \
      "the exported manifest carries NO dataset field — this is a WORKSPACE-GRAIN bundle wearing a dataset command line. Refusing to import it: every per-type census downstream would silently describe the whole workspace while the transcript claimed dataset=$SOURCE_DS (PDS-D61/PDS-D62). The bundle is on disk at $tar if you want to look."
    return 0
  fi
  if [ "$m_verdict" = "dataset-mismatch" ]; then
    fail 1 "the exported manifest says dataset='$m_ds' but the export asked for '$SOURCE_DS' — the scope flag is not reaching the engine. Nothing was imported."
    return 0
  fi
  if [ "$m_verdict" = "profile-mismatch" ]; then
    fail 1 "the exported manifest says profile='${m_profile:-<absent>}' but the export asked for 'dev' — this bundle is NOT scrubbed and must not be treated as one. Nothing was imported."
    return 0
  fi

  # ── import (--merge is MANDATORY) ─────────────────────────────────────────
  #
  # Without --merge the CLI sends mode=clean, and clean against a POPULATED
  # target answers an opaque HTTP 500 whose real cause is 25P02
  # in_failed_sql_transaction at workspace_bundle.ex:233.
  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around an HTTP/CLI call issued
  # from THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock
  # OUTSIDE every BEAM. It has to be: the BEAM doing the work is the SERVER, on
  # another host, and there is no in-BEAM meter this instrument could reach even
  # if it wanted one. The unit is wall by necessity and the figure is quoted as a
  # LATENCY, never as a price: PDS-D605 forbids a wall-clock second standing in
  # for CPU (wall swung 2.5x on an unchanged census where user CPU moved 9%), so
  # nothing here may be read as what the export COST. A price for this instrument
  # comes from `pds-door-census.sh --measure`; a regression ratchet would need
  # `Process.info(pid, :reductions)`, which a shell has not got.
  rc=0; t0="$(date +%s)"
  "$BP_BIN" -s "$TARGET_BASE" --token "$TARGET_TOKEN" \
    cloud workspace import "$SOURCE_WS" \
      --file "$tar" --yes --merge --with-blobs >"$out" 2>&1 || rc=$?
  t1="$(date +%s)"
  sed 's/^/      /' "$out"
  if [ "$rc" -ne 0 ]; then
    fail 1 "\`cloud workspace import $SOURCE_WS --yes --merge --with-blobs\` exited $rc against the target — see above. Per the CLI's own contract this exit is also what a FAILED BLOB PUSH produces, so a partially-populated target is a FAIL, never a pass with a footnote."
    return 0
  fi
  local receipt
  receipt="$(grep -iE 'table|row|blob' "$out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-220 || true)"

  ws_after="$(tgt_psql "SELECT id || ' ' || slug FROM workspaces ORDER BY inserted_at LIMIT 5" | tr '\n' ';' || true)"
  if [ -n "$ws_before" ] && [ "$ws_before" != "$ws_after" ]; then
    info "PDS-D9 ADOPTION FIRED — the target's workspaces row changed across the import"
    info "  before: $ws_before"
    info "  after:  $ws_after"
    info "  Nothing in the CLI output, the HTTP receipt or the provenance block says"
    info "  so; it is only visible by diffing the row, which is why it is diffed."
  else
    info "workspaces row unchanged across the import (no PDS-D9 adoption observed this run)"
  fi

  PULL_BUNDLE="$tar"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around an HTTP/CLI call issued from this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM doing the work is the remote SERVER, so no in-BEAM meter is reachable. A LATENCY, never a price (PDS-D605)" \
    "exit 0 in Ns"
  pass 1 "the pull ran through the front-door PAIR: export --profile dev --dataset $SOURCE_DS --with-blobs ($bytes bytes, $n_blobs blobs) then import --yes --merge --with-blobs into $TARGET_BASE, exit 0 in $((t1 - t0))s. Manifest grain ASSERTED dataset=$m_ds profile=$m_profile. Receipt: ${receipt:-<none printed>}.$GRAIN_DEMO_NOTE"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — RAW-PERSPECTIVE CENSUS
# ═════════════════════════════════════════════════════════════════════════════

# Bare-slug E3 tables, from api/lib/barkpark/tenancy/workspace_bundle/catalog.ex
# (@e3_dataset_keyed). This literal is only ever used to NAME the pre-declared
# PDS-D45 exclusion, never to assert a count. It is NOT silently authoritative:
# e3_bare_slug_derive below reads @e3_dataset_keyed out of the catalog source at
# run time, and step 2 FAILS LOUDLY if the two disagree. The literal is used
# unchecked only when the source is unreadable, and the run says so when it is.
E3_BARE_SLUG_FALLBACK="preview_token_jti shares"
E3_BARE_SLUG_SOURCE_REL="api/lib/barkpark/tenancy/workspace_bundle/catalog.ex"

# The derivation the comment above promises. Prints the space-separated table
# list from the catalog's `@e3_dataset_keyed ~w(...)` attribute, or nothing (and
# a non-zero exit) when the source is unreadable or the attribute does not parse
# — an unparseable source must read as "not derived", never as "derived empty",
# because an empty derivation would otherwise mismatch the literal and red a
# healthy run for a reason that has nothing to do with the catalog's contents.
e3_bare_slug_derive() {
  local src="$REPO_ROOT/$E3_BARE_SLUG_SOURCE_REL" out
  [ -r "$src" ] || return 1
  out="$(sed -n 's/^[[:space:]]*@e3_dataset_keyed[[:space:]]*~w(\([^)]*\)).*/\1/p' "$src" \
          | head -n 1 | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

src_total() { # type perspective -> integer (or empty)
  local t="$1" p="$2"
  curl_src "/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

src_total_anon() { # type perspective -> integer (or empty) — NO Authorization
  local t="$1" p="$2"
  bp_curl_body -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" \
    "$SOURCE_BASE/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

tgt_total() { # type perspective -> integer (or empty)
  local t="$1" p="$2"
  curl_tgt "/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

tgt_total_anon() { # type perspective -> integer (or empty) — NO Authorization
  local t="$1" p="$2"
  curl_tgt_anon "/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

# ── authedness, asserted INDEPENDENTLY of any total it is used to justify ────
#
# An unauthed ?perspective=raw query does NOT 401. It silently answers the
# PUBLISHED view, so a census taken with a dropped header reads as a clean,
# plausible, WRONG number (a 7-document false differential on the live bundle),
# and on a PRIVATE-visibility schema an anonymous caller gets a flat 404 instead.
# Two acceptable proofs, in order: the authed and unauthed raw censuses DIFFER
# (only a real token could widen the view), or — when a dataset genuinely has no
# drafts to widen — an admin-only route refuses the anonymous caller.
AUTHED_METHOD=""
assert_authed() { # base token authed_raw_total unauthed_raw_total label
  local base="$1" token="$2" a="$3" u="$4" label="$5" code
  AUTHED_METHOD=""
  if [ -n "$a" ] && [ -n "$u" ] && [ "$a" != "$u" ]; then
    AUTHED_METHOD="the authed raw census ($a) is WIDER than the same call with no Authorization header ($u) — only a real token widens it"
    return 0
  fi
  code="$(http_code "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
            "$base/api/workspaces/$SOURCE_WS/export?profile=dev&dataset=$SOURCE_DS" 2>/dev/null || true)")"
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then
    AUTHED_METHOD="the raw and published views coincide on $label (no drafts to widen), so authedness was proven on an admin-only route instead: anonymous GET /api/workspaces/$SOURCE_WS/export -> HTTP $code"
    return 0
  fi
  AUTHED_METHOD="UNPROVEN — the authed and unauthed raw censuses are identical ($a vs $u) AND the anonymous admin route answered HTTP $code instead of 401/403. The census below cannot be distinguished from a published-only read."
  return 1
}

# ── the bundle's OWN per-type row counts ────────────────────────────────────
#
# The import assertion that means something is BUNDLE -> TARGET: everything the
# bundle carried must be present. SOURCE -> BUNDLE is the scrub's scope and is
# printed, never asserted as loss. Column position comes from the manifest, so a
# column addition can never silently shift this onto the wrong field.
BUNDLE_TYPES_FILE=""
bundle_type_counts() { # tar -> writes "type<TAB>count" lines to $BUNDLE_TYPES_FILE; 1 on failure
  local tar="$1" d cols i_type n_cols first
  BUNDLE_TYPES_FILE=""
  d="$(mktemp -d "${TMPDIR:-/tmp}/pds-btc.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $d"
  tar -xf "$tar" -C "$d" manifest.json tables/documents.copy 2>/dev/null || return 1
  [ -s "$d/tables/documents.copy" ] || return 1
  cols="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
t=[x for x in d["tables"] if x["name"]=="documents"]
if not t: sys.exit(1)
c=t[0]["columns"]
print(c.index("type")+1, len(c))' "$d/manifest.json" 2>/dev/null || true)"
  [ -n "$cols" ] || return 1
  i_type="$(printf '%s' "$cols" | awk '{print $1}')"
  n_cols="$(printf '%s' "$cols" | awk '{print $2}')"
  first="$(head -n 1 "$d/tables/documents.copy" | awk -F'\t' '{print NF}')"
  # The parse IS an assertion: a non-COPY-TEXT member tab-splits into nothing
  # and every count below would come back 0, reading as a clean empty bundle.
  int_ok "${first:-}" && int_ok "$n_cols" || return 1
  [ "$first" -eq "$n_cols" ] || return 1
  BUNDLE_TYPES_FILE="$d/types.tsv"
  awk -F'\t' -v it="$i_type" '{ c[$it]++ } END { for (t in c) printf "%s\t%s\n", t, c[t] }' \
    "$d/tables/documents.copy" | sort >"$BUNDLE_TYPES_FILE"
  return 0
}

step_2() {
  head_step 2 "RAW-PERSPECTIVE CENSUS — per-type ?perspective=raw&count=true"

  say "  CARRIER CHOICE: /v1/data/counts/:dataset is NOT used. It hard-codes"
  say "  perspective:\"published\" and ignores ?perspective (raw and default return"
  say "  byte-identical bodies), so every draft row is invisible to it. The per-type"
  say "  query route genuinely honours the parameter, and the raw-vs-published"
  say "  spread printed below is the proof that it does."
  say ""

  local types n_types schemas_json
  schemas_json="$(mktmp)"
  if ! curl_src "/v1/schemas/$SOURCE_DS" >"$schemas_json" 2>/dev/null; then
    fail 2 "GET /v1/schemas/$SOURCE_DS failed — the type roster cannot be derived, and a census over a hardcoded type list is exactly the snapshot this step refuses"
    return 0
  fi
  types="$(jqp '" ".join(sorted(s["name"] for s in d["schemas"]))' <"$schemas_json" 2>/dev/null || true)"
  if [ -z "$types" ]; then
    fail 2 "could not derive the type roster from /v1/schemas/$SOURCE_DS"
    return 0
  fi
  n_types="$(printf '%s\n' "$types" | wc -w | tr -d ' ')"

  # A type whose count call FAILS is NOT the same as a type with zero rows, and
  # collapsing the two is the silent skip this ladder forbids: a broken type
  # would simply vanish from the table and the totals would still look sane.
  # An unreadable count is NAMED in the table (ERR) and fails the step.
  local t raw pub total_raw=0 total_pub=0 drafts unreadable="" top_type="" top_raw=0
  printf '      %-28s %10s %10s %10s\n' TYPE RAW PUBLISHED DRAFT-ONLY
  for t in $types; do
    raw="$(src_total "$t" raw)"
    pub="$(src_total "$t" published)"
    if [ -z "$raw" ] || [ -z "$pub" ]; then
      printf '      %-28s %10s %10s %10s\n' "$t" "${raw:-ERR}" "${pub:-ERR}" ERR
      unreadable="$unreadable $t"
      continue
    fi
    drafts=$((raw - pub))
    # Guarded ABOVE the arithmetic, not between it and the comparison: under
    # `set -u` a non-integer would otherwise die in `$((raw - pub))` with a bash
    # error instead of this harness's own named refusal.
    if ! int_ok "$raw" || ! int_ok "$pub"; then
      fail 2 "the source census for type '$t' read raw='${raw:-<empty>}' published='${pub:-<empty>}' — at least one is not an integer, so this run cannot say what the source holds"
      return 0
    fi
    [ "$raw" -eq 0 ] && [ "$pub" -eq 0 ] && continue
    printf '      %-28s %10s %10s %10s\n' "$t" "$raw" "$pub" "$drafts"
    total_raw=$((total_raw + raw))
    total_pub=$((total_pub + pub))
    if [ "$raw" -gt "$top_raw" ]; then top_raw="$raw"; top_type="$t"; fi
  done
  printf '      %-28s %10s %10s %10s\n' TOTAL "$total_raw" "$total_pub" "$((total_raw - total_pub))"

  # AUTHEDNESS OF THE SOURCE CENSUS, asserted independently of the numbers it
  # justifies. The heaviest type is the discriminator: if the header were being
  # dropped, its raw total would collapse to the published one.
  local src_anon_raw
  src_anon_raw=""
  if [ -n "$top_type" ]; then
    src_anon_raw="$(src_total_anon "$top_type" raw)"
    if assert_authed "$SOURCE_BASE" "$SOURCE_TOKEN" "$top_raw" "${src_anon_raw:-}" "$SOURCE_BASE/$top_type"; then
      info "authedness      SOURCE census is AUTHED — $AUTHED_METHOD"
    else
      fail 2 "the SOURCE census cannot be shown to be authed: $AUTHED_METHOD"
      return 0
    fi
  fi

  if [ -n "$unreadable" ]; then
    fail 2 "the census is INCOMPLETE — no count could be derived for:${unreadable}. A census missing a type is not a census; re-run once the source answers for every declared type rather than reading the totals above as complete."
    return 0
  fi

  local n_schemas n_media
  n_schemas="$(jqp 'len(d["schemas"])' <"$schemas_json" 2>/dev/null || echo '?')"
  n_media="$(curl_src "/v1/media/$SOURCE_DS?limit=1" | jqp 'd["result"]["count"]' 2>/dev/null || echo '?')"
  info "schemas=$n_schemas (GET /v1/schemas/$SOURCE_DS)  media=$n_media (GET /v1/media/$SOURCE_DS)  types with rows: counted above out of $n_types declared"

  if [ "$total_raw" -le "$total_pub" ]; then
    fail 2 "raw ($total_raw) is not greater than published ($total_pub) — either this dataset genuinely has zero drafts, or the perspective parameter is being ignored and this census is measuring the published view while claiming raw. Re-check the carrier before trusting any differential."
    return 0
  fi

  # ── the pre-declared shortfall (PDS-D45) ───────────────────────────────────
  say ""
  say "  *** PRE-DECLARED SHORTFALL — bare-slug E3, EXPECTED, NOT corruption ***"
  say "  :full is NOT lossless. The dataset slug '$SOURCE_DS' is owned by MORE THAN"
  say "  ONE workspace, so dataset_slugs_for/1 drops it under the D21 exclusivity"
  say "  rule and bare-slug E3 tables are exported with dataset = ANY('{}') — i.e."
  say "  nothing. tables/shares.copy is 0 BYTES in the full bundle for exactly this"
  say "  reason. Discovering it mid-run looks like data loss; it is a known,"
  say "  bounded ownership artifact."
  local bare_slug shares_rows owners e3_derived
  bare_slug="$E3_BARE_SLUG_FALLBACK"
  e3_derived="$(e3_bare_slug_derive || true)"
  if [ -z "$e3_derived" ]; then
    info "bare-slug E3 list NOT derived this run ($E3_BARE_SLUG_SOURCE_REL unreadable, or its @e3_dataset_keyed did not parse) — the exclusion below is named from the in-script literal, UNCHECKED against the catalog"
  elif [ "$e3_derived" != "$E3_BARE_SLUG_FALLBACK" ]; then
    fail 2 "THE BARE-SLUG E3 TABLE LIST HAS MOVED: $E3_BARE_SLUG_SOURCE_REL declares @e3_dataset_keyed = '$e3_derived', this harness names '$E3_BARE_SLUG_FALLBACK'. The PDS-D45 pre-declared shortfall would name the WRONG tables, so step 2's honest shortfall declaration would be quietly wrong rather than loudly wrong. FIX: set E3_BARE_SLUG_FALLBACK to '$e3_derived' and re-read the exclusion prose above it."
    return 0
  else
    bare_slug="$e3_derived"
    info "bare-slug E3 list DERIVED this run from $E3_BARE_SLUG_SOURCE_REL (@e3_dataset_keyed = '$e3_derived') and it MATCHES the in-script literal"
  fi
  if ssh_available; then
    shares_rows="$(src_psql "SELECT count(*) FROM shares WHERE dataset='$SOURCE_DS'" | tr -d '[:space:]' || true)"
    owners="$(src_psql "SELECT count(DISTINCT p.workspace_id) FROM datasets d JOIN projects p ON p.id=d.project_id WHERE d.slug='$SOURCE_DS'" | tr -d '[:space:]' || true)"
    info "derived live: shares rows at dataset='$SOURCE_DS' = ${shares_rows:-?} · workspaces owning the slug '$SOURCE_DS' = ${owners:-?} (>1 is what triggers the exclusivity drop)"
  else
    info "the shortfall's magnitude was NOT derived this run (source DB unreachable) — only the exclusion is asserted"
  fi
  info "EXCLUDED from every parity assertion in this step: $bare_slug"

  # ── THE TARGET HALF ────────────────────────────────────────────────────────
  say ""
  say "  ── TARGET HALF ──────────────────────────────────────────────────────"
  say "  The assertion that means something is BUNDLE -> TARGET: every document"
  say "  row the bundle CARRIED must be present at the raw perspective on the"
  say "  target. SOURCE -> BUNDLE is the dev scrub's scope; it is printed as a"
  say "  delta and never asserted as loss (a dev bundle is SUPPOSED to be smaller)."
  say ""

  if ! load_target; then
    abort 2 "env:scratch-target-not-booted" \
      "the SOURCE census above is live and complete (raw $total_raw / published $total_pub across $n_types declared types, $n_schemas schemas, $n_media media), but there is no target to diff it against. FIX: $(target_hint), then re-run --only 1,2."
    return 0
  fi
  local pull_tar
  pull_tar="${PULL_BUNDLE:-}"
  if [ -z "$pull_tar" ]; then
    abort 2 "step:1" \
      "no bundle was imported this run, so there is nothing to assert the target AGAINST. Re-run with step 1 selected (--only 1,2); a target populated by an earlier run is not evidence for this one."
    return 0
  fi
  if ! bundle_type_counts "$pull_tar"; then
    fail 2 "the imported bundle's tables/documents.copy could not be parsed at the COPY TEXT grammar its manifest declares — a per-type count over an unparsed member reads as an empty bundle, which would make every 'target matches bundle' below vacuous"
    return 0
  fi

  # Authedness of the TARGET census, proven the same way, on its own box.
  local tgt_top_type tgt_top_raw tgt_anon
  tgt_top_type="$(awk -F'\t' 'NR==1||$2>m{m=$2;t=$1} END{print t}' "$BUNDLE_TYPES_FILE")"
  tgt_top_raw="$(tgt_total "$tgt_top_type" raw)"
  tgt_anon="$(tgt_total_anon "$tgt_top_type" raw)"
  if assert_authed "$TARGET_BASE" "$TARGET_TOKEN" "${tgt_top_raw:-}" "${tgt_anon:-}" "$TARGET_BASE/$tgt_top_type"; then
    info "authedness      TARGET census is AUTHED — $AUTHED_METHOD"
  else
    fail 2 "the TARGET census cannot be shown to be authed: $AUTHED_METHOD"
    return 0
  fi

  local bt bc tr sr short=0 missing=""
  printf '\n      %-28s %10s %10s %10s\n' TYPE BUNDLE 'TARGET raw' 'SOURCE raw'
  while IFS="$(printf '\t')" read -r bt bc; do
    [ -n "$bt" ] || continue
    tr="$(tgt_total "$bt" raw)"
    sr="$(src_total "$bt" raw)"
    printf '      %-28s %10s %10s %10s\n' "$bt" "$bc" "${tr:-ERR}" "${sr:-?}"
    # `[ -z ]` alone cannot see this: tgt_total runs through jqp, which is
    # print(eval(...)) over the response, so a JSON null arrives as the STRING
    # "None" — non-empty, non-integer, and enough to make the `-lt` error into
    # a FALSE that silently reads as "not short".
    if ! int_ok "$tr"; then
      missing="$missing $bt(unreadable)"
      continue
    fi
    if ! int_ok "$bc"; then
      missing="$missing $bt(bundle count unreadable)"
      continue
    fi
    if [ "$tr" -lt "$bc" ]; then
      short=$((short + 1))
      missing="$missing $bt($tr<$bc)"
    fi
  done <"$BUNDLE_TYPES_FILE"

  if [ -n "$missing" ]; then
    fail 2 "the target does NOT carry everything the bundle did:${missing}. A type whose count could not be read is reported here too — an unreadable count is not a zero and is never collapsed into one."
    return 0
  fi

  info "EXCLUDED from every parity assertion (PDS-D45, bare-slug E3): $bare_slug"
  pass 2 "raw-perspective census, BOTH ends, authedness proven on each: source raw $total_raw / published $total_pub across $n_types declared types; every type the dev bundle carried is present on the target at >= the bundle's own row count (bundle types: $(wc -l <"$BUNDLE_TYPES_FILE" | tr -d ' ')). The source->bundle delta above is the DEV SCRUB's scope, not loss."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — TICKET-DENY BYTE-SCAN
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# THE ONE FULL EXPORT (PDS-D69/PDS-D70/PDS-D71) — acquired once, consumed twice
# ═════════════════════════════════════════════════════════════════════════════
#
# Steps 3 and 4 both need a FULL-fidelity bundle: step 3 for the ticket control
# that must FIRE, step 4 for the secret-scan control that must FIRE. Neither may
# fetch one. This function is the single acquisition point, and it is severable
# (PDS-D71): when it aborts, ONLY steps 3 and 4 pay — 0/0b/0c/1/2/5/6/7/8 run
# regardless, so one unaffordable export never collapses the whole ladder.
#
# WHY IT IS THIS CAREFUL. A full export peaks the source's beam.smp well into
# gigabytes on a 3.8 GB box that is ALSO serving the live content API, and an
# export that DIES still pays the peak. So: one run-stable copy, a persistent
# attempt counter flushed BEFORE the request (a killed run must not get a free
# retry), a mkdir lock (flock does not exist on Darwin), and six conditions
# printed with their measured values BEFORE any byte moves.
#
# THE RSS NUMBER IS MEASURED, NOT QUOTED. A 1 Hz `ps -o rss= -p <beam pid>`
# sampler over SSH, with NO slot restart: cgroup memory.peak is mode 0444 on
# this kernel and only a restart resets it, and a restart costs ~26 s of LIVE
# content-API downtime. Any cgroup figure that appears anywhere is labelled
# CUMULATIVE-SINCE-BOOT. The survey's numbers are never reprinted as this run's.

# full_meta_ok — 0 = the on-disk bundle at $FULL_TAR is a USABLE FULL bundle.
# On 1 it sets $FULL_META_WHY to the ONE expectation that failed, by name.
#
# PDS-D261 / pds-bl-w16-full-meta-permissive-default. This predicate used to be
# `[ -s "$FULL_TAR" ]` plus `case "$p" in ""|full) return 0`, where `$p` came
# from manifest_field — which returns the EMPTY STRING on EVERY failure path:
# a body that is not a tar, a tar with no manifest.json member, a manifest that
# is not JSON. So "" meant BOTH "an engine that predates the profile field" AND
# "this file is not a bundle at all", and the legacy branch accepted the second.
#
# MEASURED on origin/main before this change (scripts/pds-pull-proof_test.sh
# replays every shape): a 3096-byte HTML proxy error page, a 21-byte JSON error
# body, a gzip that is not a tar, a 512-byte truncated tar, a valid tar with no
# members, a tar carrying only manifest.json and no tables, and a tar whose
# members are all zero bytes were ALL accepted as full bundles. The ONLY refusals
# were a 0-byte file and an explicitly non-full profile string. That is a
# predicate that cannot fail on the shapes it exists to catch — and it sits on
# the reuse path (`if full_meta_ok` in acquire_full_bundle), which has no HTTP
# code and no byte floor, over a bundle parked in world-writable /tmp.
#
# The predicate now asserts what the CONSUMERS need, no more: step 3 extracts
# `manifest.json tables/documents.copy` out of this exact tar and step 4 hands
# it to pds-secret-scan.sh. The legacy pre-profile accept SURVIVES, but only for
# a manifest that PARSED and genuinely carries no `profile` key — an unreadable
# manifest is not a legacy engine.
full_meta_ok() { # [path] -> 0 = THAT bundle is a usable FULL bundle (default $FULL_TAR)
  FULL_META_WHY=""
  local d p sz kind prc=0 listing lrc=0 nmembers tarball
  # THE PATH IS AN ARGUMENT so the predicate can judge a body that has NOT been
  # moved into place yet (pds-bl-w16-failed-refetch-destroys-parked-bundle): the
  # fetch validates its temp file HERE and only a pass renames it over the parked
  # bundle. Default $FULL_TAR — every existing caller reads the parked path and
  # is unchanged, and the refusal text still names the file it actually judged.
  tarball="${1:-$FULL_TAR}"

  if [ ! -f "$tarball" ]; then
    FULL_META_WHY="there is no file at $tarball"
    return 1
  fi
  if [ ! -s "$tarball" ]; then
    FULL_META_WHY="$tarball is 0 bytes"
    return 1
  fi

  # An operator has to tell a proxy error page from a truncated download from a
  # gzip, and the byte count alone does not: name the type AND the size. Both
  # refusals below carry the same "What is actually on disk" clause, because
  # WHICH of the two fires is a property of the local tar(1), not of the body.
  sz="$(wc -c <"$tarball" 2>/dev/null | tr -d ' ')"
  kind="$(file -b "$tarball" 2>/dev/null | tr -d '\n')"

  listing="$(tar -tf "$tarball" 2>/dev/null)" || lrc=$?
  if [ "$lrc" -ne 0 ]; then
    FULL_META_WHY="$tarball does not read as a tar archive at all — \`tar -tf\` refused it (exit $lrc). What is actually on disk: ${sz:-?} bytes, file(1) says [${kind:-unidentifiable}]. An error page, a truncated download or any non-tar body reaches this predicate looking exactly like a bundle, and every downstream extraction off it would read as an EMPTY bundle rather than a failed one"
    return 1
  fi

  # ZERO MEMBERS IS ITS OWN REFUSAL, and it is not pedantry — it is the only
  # branch that makes this predicate say the same true thing on both tars.
  # MEASURED on GNU tar 1.35 (debian:stable-slim) against bsdtar on Darwin:
  #
  #     gzipped non-tar body   GNU: tar -tf rc=0, 0 members   bsdtar: rc=1
  #     HTML / JSON body       GNU: rc=2                      bsdtar: rc=1
  #     512-byte truncated tar GNU: rc=2                      bsdtar: rc=1
  #
  # GNU tar decompresses transparently, finds no tar stream inside, and reports
  # an EMPTY ARCHIVE with exit 0. Without this branch the gzip fell through to
  # the manifest check and the harness printed "is a readable tar but carries no
  # manifest.json member" — a message that is FALSE about a gzip, emitted on
  # exactly the Linux boxes the climb runs on. A genuinely empty tar lands here
  # too, and the sentence is true of it as well: no members, so no bundle.
  nmembers="$(printf '%s' "$listing" | grep -c .)" || nmembers=0
  if [ "$nmembers" -eq 0 ]; then
    FULL_META_WHY="$tarball lists ZERO members — \`tar -tf\` accepted it but named nothing inside it. What is actually on disk: ${sz:-?} bytes, file(1) says [${kind:-unidentifiable}]. An archive with no members carries no manifest and no tables, so it is not a bp-export-v1 bundle whatever it is. TWO different bodies land here: a genuinely empty tar, and — on GNU tar only — a GZIPPED non-tar body, which GNU decompresses transparently and then reports as an empty archive with exit 0 where bsdtar refuses it one branch earlier. Read file(1) above to tell which one you have"
    return 1
  fi

  d="$(mktemp -d "${TMPDIR:-/tmp}/pds-fm.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $d"

  if ! tar -xf "$tarball" -C "$d" manifest.json 2>/dev/null || [ ! -s "$d/manifest.json" ]; then
    FULL_META_WHY="$tarball is a readable tar but carries no non-empty manifest.json member, so it is not a bp-export-v1 bundle at all"
    return 1
  fi

  # manifest_field's EXIT CODE is what makes the legacy accept safe: 1 is "the
  # manifest was read and carries no profile key" (the pre-profile engine), 2 is
  # "nothing was readable". The old predicate saw the same empty string for both.
  p="$(manifest_field "$tarball" profile)" || prc=$?
  case "$prc" in
    2)
      FULL_META_WHY="manifest.json is present but is not a JSON object — its profile cannot be read, and an UNREADABLE manifest is not the legacy pre-profile engine the absent-profile branch exists for"
      return 1 ;;
    1)
      : ;;   # key absent from a manifest that PARSED — the legacy accept
    *)
      if [ "$p" != "full" ]; then
        FULL_META_WHY="the manifest declares profile=[$p], not [full] — a $p bundle is not a full-fidelity control"
        return 1
      fi ;;
  esac

  if ! tar -xf "$tarball" -C "$d" tables/documents.copy 2>/dev/null || [ ! -s "$d/tables/documents.copy" ]; then
    FULL_META_WHY="the bundle carries no non-empty tables/documents.copy member — step 3's ticket-deny control and step 4's scan both read exactly that member, and a zero over an absent member is vacuous, not clean"
    return 1
  fi

  return 0
}

full_meta_field() { # key -> the value recorded in the .meta sidecar (empty if absent)
  [ -f "$FULL_META" ] || return 0
  awk -v k="$1:" '$1 == k { $1=""; sub(/^[ \t]+/, ""); print; exit }' "$FULL_META"
}

# ── RSS ATTRIBUTION ACROSS INVOCATIONS (pds-bl-step8-cross-invocation-gap) ──
# The RSS peak lives in a per-invocation RUN_TAG-keyed artifact directory, so
# ONLY the invocation that actually spent the attempt has one. A reuse
# invocation measured nothing, and must say so rather than letting the parked
# sidecar's figure read as its own. Reads $FULL_META and nothing else.
rss_reuse_attribution() { # -> the sentence a reusing invocation prints
  local meta_run meta_peak
  meta_run="$(full_meta_field run_id)"
  meta_peak="$(full_meta_field rss_peak_kb)"
  printf 'this invocation measured NO RSS of its own — it spent 0 attempts and reused the parked bundle. The peak recorded beside it (%s KB) was measured by run %s and is attributed to THAT invocation, never to run %s (tag %s).' \
    "${meta_peak:-unknown}" "${meta_run:-unknown}" "$RUN_ID" "$RUN_TAG"
}

full_attempts() { # -> integer (never empty — an empty/garbage counter file reads 0)
  local n=""
  if [ -f "$FULL_ATTEMPTS_FILE" ]; then
    n="$(tr -dc '0-9' <"$FULL_ATTEMPTS_FILE" | head -c 6)"
  fi
  printf '%s' "${n:-0}"
}

# ── GATE (b): THE PAIRED MEMORY PREDICATE ───────────────────────────────────
# (pds-bl-gate-b-anticorrelated, PDS-D741)
#
# A PURE FUNCTION OVER NUMBERS, deliberately: it performs no SSH, reads no file
# and touches no global but the two configured limits, so the exact figures the
# source produced on 2026-07-20 can be replayed through the SHIPPED predicate
# without a box. Everything measured lives in the caller; everything judged
# lives here.
#
# WHAT IT ASSERTS: MemAvailable >= floor AND the live beam.smp's own VmSwap <=
# ceiling. The conjunction is the whole point — see the FULL_MAX_SWAP_MB block
# above for the measurement that makes the floor alone anti-correlated.
#
# FAIL-CLOSED ON BLINDNESS, exactly as (d) does (PDS-D98): an unreadable
# MemAvailable or an unreadable VmSwap is UNKNOWN, never OK. The swapped-out
# state is precisely the one where a probe is slow enough to be dropped, so a
# missing VmSwap must not degrade into the old single-value gate.
gate_b_verdict() { # <memavail_kb> <vmswap_kb> <floor_mb> [beam_rss_kb] -> the cond_b text; 0 = OK
  local avail_kb="${1-}" swap_kb="${2-}" floor_mb="${3-0}" rss_kb="${4-}"
  local avail_mb swap_mb rss_mb committed=""

  if ! int_ok "$avail_kb"; then
    printf 'UNKNOWN (MemAvailable unreadable — SSH is the only route to it, and a gate that cannot see is never OK)\n'
    return 1
  fi
  avail_mb=$((avail_kb / 1024))
  if ! int_ok "$swap_kb"; then
    printf 'UNKNOWN (MemAvailable is %s MB, but NO comm-anchored beam.smp VmSwap could be read — and VmSwap is the half of this gate that tells a healthy box from an evicted one. The floor ALONE would have said OK here; that is the reading PDS-D741 refuses)\n' "$avail_mb"
    return 1
  fi
  swap_mb=$((swap_kb / 1024))
  if int_ok "$rss_kb"; then
    rss_mb=$((rss_kb / 1024))
    committed="$(printf ', beam committed footprint %s MB = RSS %s + swap %s' "$((rss_mb + swap_mb))" "$rss_mb" "$swap_mb")"
  fi

  if [ "$avail_mb" -lt "$floor_mb" ]; then
    printf 'FAILED (%s MB available, floor %s MB; beam swapped out %s MB, ceiling %s MB)%s — too little headroom to materialise the bundle beside a LIVE content API\n' \
      "$avail_mb" "$floor_mb" "$swap_mb" "$FULL_MAX_SWAP_MB" "$committed"
    return 1
  fi
  if [ "$swap_mb" -gt "$FULL_MAX_SWAP_MB" ]; then
    printf 'FAILED — %s MB available CLEARS the %s MB floor, but %s MB of the LIVE beam.smp is SWAPPED OUT (ceiling %s MB)%s. That headroom IS the evicted working set: the export would fault it all back in. This is the exact reading the floor alone passed on 2026-07-20\n' \
      "$avail_mb" "$floor_mb" "$swap_mb" "$FULL_MAX_SWAP_MB" "$committed"
    return 1
  fi
  printf 'OK (%s MB available >= floor %s MB, AND %s MB of the live beam.smp swapped out <= ceiling %s MB)%s\n' \
    "$avail_mb" "$floor_mb" "$swap_mb" "$FULL_MAX_SWAP_MB" "$committed"
  return 0
}

# ── (d)'s DISCRIMINATOR: which in-flight deploy.yml runs can touch THE BOX ───
# `deploy.yml` is TWO independent deploy jobs behind one `changes` job: the
# `control-plane` job (`if: needs.changes.outputs.cp == 'true'`) ships to
# CP_HOST, and the `instance` job (`if: needs.changes.outputs.instance ==
# 'true'`) ships to GUERRILLA_HOST. A PDS climb pulls from the INSTANCE box,
# so only the `instance` job can swap the slot under an export. The old (d)
# asked `gh run list --workflow deploy.yml --status in_progress` and stopped
# there — a cloud-only merge, which never runs `instance` and cannot possibly
# disturb the export, read identically to a real api deploy and tripped a FALSE
# ABORT that cost the run its whole precondition set
# (pds-bl-cond-d-job-blind-false-abort).
#
# PURE ON PURPOSE. The classification takes the jobs listing as TEXT so it is
# decidable from a fixture: a gate whose only route to its own verdict is a live
# GitHub API call is a gate nobody can show failing in both directions, and
# PDS-D31 forbids buying that demonstration with a real export.
deploy_run_instance_verdict() { # <jobs-tsv: name\tstatus\tconclusion per line> -> instance | control-plane-only | unknown:<why>
  local tsv="${1-}" name status conclusion
  local have_changes=0 changes_done=0 changes_status="" have_instance=0 inst_conc=""

  while IFS="$(printf '\t')" read -r name status conclusion; do
    [ -n "$name" ] || continue
    case "$name" in
      changes)  have_changes=1; changes_status="$status"
                if [ "$status" = "completed" ]; then changes_done=1; fi ;;
      instance) have_instance=1; inst_conc="$conclusion" ;;
    esac
  done <<EOF
$tsv
EOF

  if [ "$have_instance" -eq 1 ]; then
    # `skipped` is the ONLY conclusion that means the instance box was not and
    # will not be touched. A NULL/empty conclusion is a job still running, and
    # `success`/`failure` is a job that already ran — both touched the box.
    if [ "$inst_conc" = "skipped" ]; then
      printf 'control-plane-only'
    else
      printf 'instance'
    fi
    return 0
  fi

  # NO `instance` LINE IS NOT "NO INSTANCE JOB". GitHub materialises a job in
  # the listing only once the run reaches it, so before `changes` completes the
  # `instance` job's fate is undecided and its absence says nothing. Reading an
  # absence as "control-plane only" is the most reassuring possible answer to a
  # question that was never answered — the shape PDS-D98 makes this gate fail
  # CLOSED over.
  if [ "$have_changes" -eq 0 ]; then
    printf 'unknown:the run listed no `changes` job, so its job graph could not be read at all'
  elif [ "$changes_done" -eq 0 ]; then
    printf 'unknown:the `changes` job is %s, so whether the `instance` job runs is not yet decided' "${changes_status:-in an unreported state}"
  else
    printf 'unknown:`changes` completed but no `instance` job is listed, so the job that targets the source box cannot be ruled in or out'
  fi
  return 0
}

gate_d_verdict() { # <gh_rc> [<run-id>=<verdict> ...] -> the cond_d text; 0 = OK
  local gh_rc="${1-0}"; shift || true
  local pair id verdict
  local instance_ids="" unknown_notes="" cp_ids=""

  if [ "$gh_rc" -ne 0 ]; then
    printf 'UNKNOWN (gh exited %s — the GitHub API did not answer, so an in-flight deploy cannot be ruled out)\n' "$gh_rc"
    return 1
  fi
  if [ "$#" -eq 0 ]; then
    printf 'OK (no deploy.yml run in progress)\n'
    return 0
  fi

  for pair in "$@"; do
    id="${pair%%=*}"; verdict="${pair#*=}"
    case "$verdict" in
      instance)           instance_ids="$instance_ids $id" ;;
      control-plane-only) cp_ids="$cp_ids $id" ;;
      unknown:*)          unknown_notes="$unknown_notes; run $id: ${verdict#unknown:}" ;;
      *)                  unknown_notes="$unknown_notes; run $id: unrecognised job verdict [$verdict]" ;;
    esac
  done

  if [ -n "$instance_ids" ]; then
    printf 'FAILED — deploy.yml run(s) whose `instance` job targets the source box are in progress:%s. A deploy mid-export swaps the slot under the request\n' "$instance_ids"
    return 1
  fi
  if [ -n "$unknown_notes" ]; then
    printf 'UNKNOWN (a deploy.yml run is in progress and its job graph did not settle the question%s). A gate that cannot see is never OK\n' "$unknown_notes"
    return 1
  fi
  printf 'OK (deploy.yml run(s) in progress:%s, but every one of them is CONTROL-PLANE ONLY — the `instance` job that ships to the source box is skipped in each, so none can swap the slot under this export)\n' "$cp_ids"
  return 0
}

# ── THE PER-RUN DESCENT, AND ITS COUNT IDENTITY (task-adad29e7487ed2b6) ─────
# EXTRACTED so it can be driven from a fixture. The loop below used to sit
# inline in the full-export precondition block, wedged between an ssh memory
# probe and a `df`, which meant the only route to its behaviour was a live
# export against a live box — the exact shape PDS-D31 forbids buying a
# demonstration with. Its body is otherwise unchanged.
#
# WHY THE IDENTITY EXISTS. `$gh_out` is read on fd 0 (a heredoc). Any body
# child that reads stdin — a `gh` invoked with `--input -`, a future `ssh`, a
# `psql`, a stray `read` — swallows the remaining run ids, the loop ENDS EARLY
# with no error and no non-zero status, and `d_pairs` is simply SHORTER than
# the listing it was built from. gate_d_verdict is worst-case over the pairs it
# is HANDED, so a run it never examined cannot be represented: an in-flight
# `instance` deploy on run 3 of 3 then reads as "every one of them is
# CONTROL-PLANE ONLY", or — if the loop died on iteration 1 of 1 — as "no
# deploy.yml run in progress". That is the precise false-clear this gate exists
# to prevent, and it is the same sentence a true clear uses.
#
# THE IDENTITY IS: pairs built == NON-EMPTY lines the enumeration handed the
# loop. Non-empty on both sides, because the body's own `[ -n "$d_run" ] ||
# continue` arm skips a blank line without appending a pair, so a blank line
# must not be counted on the enumeration side either. `awk 'NF'` and the body
# guard agree on what "non-empty" means: a whitespace-only line is NF==0 on one
# side and IFS-stripped to empty on the other.
#
# It is the same identity scripts/pds-secret-scan.sh landed in #19577 over its
# table list, and the same one the deploy.yml anchor loop landed in #19561.
gate_d_conditions() { # <gh_rc> <gh_out> -> the cond_d text; 0 = OK
  local gh_rc="${1-0}" gh_out="${2-}"
  local d_run d_jobs d_jrc d_pairs=() d_enumerated=0

  if [ "$gh_rc" -eq 0 ] && [ -n "$gh_out" ]; then
    # COUNTED BEFORE THE LOOP READS A BYTE. This is the number of in-flight
    # runs the enumeration HANDED the loop; `${#d_pairs[@]}` below is the number
    # it actually examined. Nothing else in this block can tell "3 of 3" from
    # "1 of 3" — both look like a completed loop.
    d_enumerated="$(printf '%s\n' "$gh_out" | awk 'NF { n++ } END { print n+0 }')"

    while read -r d_run; do
      [ -n "$d_run" ] || continue
      d_jrc=0
      # MUT-ANCHOR: gate-d-body-child
      d_jobs="$(gh run view "$d_run" --json jobs \
                  -q '.jobs[] | [.name, .status, (.conclusion // "")] | @tsv' 2>/dev/null)" || d_jrc=$?
      if [ "$d_jrc" -ne 0 ]; then
        d_pairs+=("$d_run=unknown:gh run view exited $d_jrc, so this run's job graph was never read")
      else
        d_pairs+=("$d_run=$(deploy_run_instance_verdict "$d_jobs")")
      fi
    done <<EOF
$gh_out
EOF

    # MUT-ANCHOR: gate-d-count-identity
    if [ "${#d_pairs[@]}" -ne "$d_enumerated" ]; then
      printf 'UNKNOWN (SHORT RUN SCAN — built %s run/verdict pair(s) from the %s in-flight deploy.yml run(s) the enumeration handed the loop. The loop ended before the list did, so %s run(s) were never examined and cannot be represented in the verdict; a gate that looked at part of the listing must never clear in the same words as one that looked at all of it)\n' \
        "${#d_pairs[@]}" "$d_enumerated" "$((d_enumerated - ${#d_pairs[@]}))"
      return 1
    fi
    # MUT-END: gate-d-count-identity
  fi

  gate_d_verdict "$gh_rc" ${d_pairs[@]+"${d_pairs[@]}"}
}

acquire_full_bundle() { # 0 = $FULL_TAR is on disk and usable; 1 = FULL_WHY says why not
  FULL_WHY=""
  local stale_note=""
  mkdir -p "$FULL_DIR" 2>/dev/null || true

  # ── REUSE IS PROVENANCE-GATED (PDS-D20) ───────────────────────────────────
  # The store is RUN-STABLE by design, which is exactly what makes a bundle
  # taken off an OLDER deploy survive into a run that pinned a NEWER sha. Every
  # differential steps 3 and 4 take off this bundle is dated by step 0a's sha,
  # so reusing a bundle from another sha would date a stale artifact with a
  # fresh pin — the silent-wrong-answer class this whole ladder exists to kill.
  # A mismatch therefore does NOT reuse: it falls through to the five
  # conditions, which either buy a fresh bundle within budget or ABORT saying
  # the staleness out loud (severable — it costs steps 3 and 4 only).
  if ! full_meta_ok && [ -e "$FULL_TAR" ]; then
    # A file IS parked at the run-stable path and it is NOT a usable bundle.
    # Silence here is what let a non-tar body be reused as a full-fidelity
    # control for as long as it sat on disk (PDS-D261). $FULL_DIR defaults to
    # world-writable /tmp, so this branch is reachable without any bad export.
    info "full bundle     PARKED FILE REFUSED — $FULL_META_WHY. Not reused; falling through to the six conditions."
  fi

  if full_meta_ok; then
    local meta_sha
    meta_sha="$(full_meta_field served_sha)"
    if [ -n "$DEPLOYED_SHA" ] && [ -n "$meta_sha" ] && [ "$meta_sha" != "unresolved" ] && [ "$meta_sha" != "$DEPLOYED_SHA" ]; then
      stale_note="the parked bundle was taken off sha $meta_sha but step 0a pinned $DEPLOYED_SHA — it is NOT reusable for a differential dated by this run's pin. "
      info "full bundle     STALE — parked at sha $meta_sha, this run pinned $DEPLOYED_SHA. Not reused."
    else
      info "full bundle     REUSED from $FULL_TAR ($(wc -c <"$FULL_TAR" | tr -d ' ') bytes) — 0 attempts spent this run"
      [ -f "$FULL_META" ] && sed 's/^/                /' "$FULL_META"
      if [ -z "$meta_sha" ] || [ "$meta_sha" = "unresolved" ]; then
        info "                PROVENANCE UNKNOWN — this bundle records no served sha, so the controls taken off it are NOT dated by step 0a's pin. Say so in the transcript."
      fi
      FULL_RSS_LINE="$(rss_reuse_attribution)"
      info "                RSS ATTRIBUTION — $FULL_RSS_LINE"
      return 0
    fi
  fi

  # ── the six conditions, printed with measured values, before any byte moves
  local spent mem_kb sha_now gh_rc gh_out cond_a cond_b cond_c cond_d cond_e cond_f ok=1
  local parked_note free_mb need_mb parked_mb parked_bytes
  spent="$(full_attempts)"

  sha_now=""
  if ssh_available; then sha_now="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"; fi
  if [ -z "$DEPLOYED_SHA" ] || [ -z "$sha_now" ]; then
    cond_a="UNKNOWN (0a sha='${DEPLOYED_SHA:-unresolved}', re-pin='${sha_now:-unresolved}')"; ok=0
  elif [ "$sha_now" = "$DEPLOYED_SHA" ]; then
    cond_a="OK ($sha_now, re-pinned this instant)"
  else
    cond_a="FAILED — the box redeployed since step 0a ($DEPLOYED_SHA -> $sha_now)"; ok=0
  fi

  # ── (b) BOTH HALVES COME BACK IN ONE PROBE (pds-bl-gate-b-anticorrelated) ─
  # ONE round trip, so the two numbers describe the SAME instant: a MemAvailable
  # read at T and a VmSwap read at T+2s can disagree about the box by a hundred
  # megabytes on a thrashing host, and the pair is the whole assertion.
  #
  # `pgrep -x beam.smp` — comm-anchored and UNANCHORED-to-argv, matching the RSS
  # sampler below, for the reason recorded there (PDS-D135): `pgrep -f beam` also
  # matches THIS VERY ssh command line. Every slot's VmSwap is SUMMED, because
  # every slot's evicted pages compete for the same faults during the export.
  local mem_probe swap_kb beam_rss_kb
  mem_probe=""; swap_kb=""; beam_rss_kb=""
  if ssh_available; then
    mem_probe="$(ssh_src "awk '/^MemAvailable:/{print \"memavail \" \$2}' /proc/meminfo; pgrep -x beam.smp | while read -r bp; do awk '/^VmSwap:/{print \"vmswap \" \$2} /^VmRSS:/{print \"vmrss \" \$2}' /proc/\$bp/status 2>/dev/null; done" || true)"
    mem_kb="$(first_int "$(printf '%s\n' "$mem_probe" | awk '/^memavail /{print $2; exit}')")"
    # NO DEFAULT ZERO. An absent vmswap line means the probe could not see the
    # BEAM at all; defaulting it to 0 would read as "nothing is swapped out",
    # which is the most reassuring possible answer to a question that was never
    # answered. awk's `END {print s+0}` would do exactly that, so the presence
    # of the line is checked FIRST and the sum is only taken when there is one.
    if printf '%s\n' "$mem_probe" | grep -q '^vmswap '; then
      swap_kb="$(first_int "$(printf '%s\n' "$mem_probe" | awk '/^vmswap /{s += $2} END {print s}')")"
      beam_rss_kb="$(first_int "$(printf '%s\n' "$mem_probe" | awk '/^vmrss /{s += $2} END {print s}')")"
    fi
  fi
  cond_b="$(gate_b_verdict "$mem_kb" "$swap_kb" "$FULL_MIN_MEM_MB" "$beam_rss_kb")" || ok=0

  if [ "$spent" -lt "$FULL_BUDGET" ]; then
    cond_c="OK ($spent of $FULL_BUDGET attempt(s) spent)"
  else
    # "or reuse $FULL_TAR" was advice the run had ALREADY made impossible: every
    # path that reaches the conditions has either no parked file, or a parked
    # file this very invocation refused. Telling an operator to reuse a bundle
    # full_meta_ok rejected sends them to a control that cannot be consumed —
    # so the guidance is DERIVED from the parked path's measured state instead
    # of being a fixed sentence (pds-bl-w16-failed-refetch-destroys-parked-bundle).
    if [ ! -e "$FULL_TAR" ]; then
      parked_note="there is NO file at $FULL_TAR, so there is nothing to fall back on either"
    elif full_meta_ok; then
      parked_note="the bundle parked at $FULL_TAR IS a usable full bundle, but this run did not reuse it: ${stale_note:-it was refused above; see the transcript. }Reusing it anyway would date another sha's artifact with this run's pin, which is the silent-wrong-answer class PDS-D20 exists to refuse — so reuse is an operator decision taken out loud, not a default"
    else
      parked_note="do NOT reuse $FULL_TAR — the validity check has ALREADY rejected the file parked there ($FULL_META_WHY), so it is not a fallback. Remove it or replace it deliberately"
    fi
    cond_c="FAILED — the budget is exhausted ($spent of $FULL_BUDGET). A dead export still paid its peak; raise PDS_FULL_EXPORT_BUDGET deliberately. On the parked path: $parked_note"; ok=0
  fi

  if command -v gh >/dev/null 2>&1; then
    # gh's EXIT STATUS is captured apart from its stdout. Piping it straight into
    # `tr … || true` made an API error and a genuinely empty result identical —
    # both read "no deploy.yml run in progress" — and the GitHub API answers 503
    # often enough to matter (5 of 8 back-to-back calls, measured). A gate that
    # cannot see is UNKNOWN, never OK: this must fail CLOSED exactly as the
    # gh-missing branch below already does (PDS-D98).
    gh_rc=0
    gh_out="$(gh run list --workflow deploy.yml --branch main --status in_progress --limit 5 \
                --json databaseId -q '.[].databaseId' 2>/dev/null)" || gh_rc=$?
    # SECOND QUERY, PER RUN: the listing above knows only that A deploy.yml run
    # is live, never WHICH of its two deploy jobs that run will reach. That is
    # the whole defect PDS-D746 thaws this block to fix — the discriminator is
    # the `instance` job, and it is only visible one level down, in the run's
    # own job graph.
    #
    # THE DESCENT AND ITS COUNT IDENTITY LIVE IN gate_d_conditions (above), so
    # both directions are reachable from a fixture rather than only from a live
    # export (PDS-D31). It refuses outright when it built fewer run/verdict
    # pairs than the enumeration handed it — a short loop can no longer hand
    # gate_d_verdict a truncated pair list and have it read as a clear.
    cond_d="$(gate_d_conditions "$gh_rc" "$gh_out")" || ok=0
  else
    cond_d="UNKNOWN (gh is not on PATH, so an in-flight deploy cannot be ruled out)"; ok=0
  fi

  # ── (f) FREE SPACE — measured, with the figures, BEFORE the request ──────
  # `grep -n 'df -\|disk'` over this file returned nothing before this change:
  # the acquisition path pulled ~1.03 GB with no idea whether the filesystem
  # could hold it. Running out mid-download produces a TRUNCATED body, which is
  # indistinguishable on disk from a dead export, after the source has already
  # paid its full memory peak — the most expensive way to learn about `df`.
  # The requirement is the incoming copy sitting BESIDE the parked bundle (the
  # temp-then-rename shape), so a parked bundle bigger than the floor raises it.
  parked_bytes=0; parked_mb=0
  if [ -s "$FULL_TAR" ]; then
    parked_bytes="$(first_int "$(wc -c <"$FULL_TAR" 2>/dev/null | tr -d ' ')")"
    int_ok "$parked_bytes" || parked_bytes=0
    parked_mb=$((parked_bytes / 1048576))
  fi
  need_mb="$FULL_MIN_FREE_MB"
  if [ "$((parked_mb + 256))" -gt "$need_mb" ]; then need_mb=$((parked_mb + 256)); fi
  # -P forces the one-line POSIX format (a long device name otherwise wraps and
  # $4 reads the wrong column); -m fixes the unit so no block-size guess is made.
  free_mb="$(first_int "$(df -Pm "$FULL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')")"
  if ! int_ok "$free_mb" || [ -z "$free_mb" ]; then
    cond_f="UNKNOWN (df -Pm could not measure free space under $FULL_DIR — a gate that cannot see is never OK)"; ok=0
  elif [ "$free_mb" -ge "$need_mb" ]; then
    cond_f="OK (${free_mb} MB free under $FULL_DIR, floor ${need_mb} MB = ${FULL_MIN_FREE_MB} MB base vs parked ${parked_mb} MB + 256)"
  else
    cond_f="FAILED (${free_mb} MB free under $FULL_DIR, floor ${need_mb} MB) — short by $((need_mb - free_mb)) MB. The incoming bundle must fit BESIDE the parked one (parked: ${parked_bytes} bytes); starting the request would buy a truncated body at the price of the source's full memory peak"; ok=0
  fi

  cond_e="not attempted (an earlier condition already failed)"
  if [ "$ok" -eq 1 ]; then
    if mkdir "$FULL_LOCK" 2>/dev/null; then
      FULL_LOCK_OWNED=1
      cond_e="OK (took $FULL_LOCK)"
    else
      cond_e="FAILED — $FULL_LOCK is held by another run. Two concurrent full exports OOM the box (PDS-D31)"; ok=0
    fi
  fi

  say ""
  info "FULL-EXPORT PRECONDITIONS (all six printed BEFORE any byte moves):"
  info "  (a) served sha re-pinned == step 0a's ....... $cond_a"
  info "  (b) MemAvail >= ${FULL_MIN_MEM_MB} MB AND beam swap <= ${FULL_MAX_SWAP_MB} MB ... $cond_b"
  info "  (c) attempts < budget ...................... $cond_c"
  info "  (d) no INSTANCE-job deploy.yml run live .... $cond_d"
  info "  (f) free space >= the incoming bundle ...... $cond_f"
  info "  (e) lock acquired .......................... $cond_e"
  say ""
  # (d) IS A SAMPLE, NOT A RESERVATION. It reads the run list at ONE instant and
  # holds nothing: a merge landing one second later races the export
  # uninterrupted, and only rung 0b's sha-ancestor check would notice, after the
  # fact. There is no deploy freeze a climb can take — `main`'s branch
  # protection gates the MERGE on four CI contexts (`Elixir gate`, `Cloud gate`,
  # `Console gate`, `PR references an active task`) and says nothing about
  # deploys, and the box-side deploy lock in `deploy/instance-deploy.sh`
  # serialises deploys against EACH OTHER, never against an export. The
  # protection this gate gives an export is a sample plus a social convention,
  # and the transcript says so rather than letting an OK read as a lock.
  info "  (d) SCOPE — that is a SAMPLE taken just now, NOT a reservation held across the export."
  info "      A deploy merged one second from now races this export uninterrupted; there is no"
  info "      deploy freeze in this repo for a climb to take (branch protection gates the MERGE"
  info "      on CI contexts only, and the box-side deploy lock serialises deploys against each"
  info "      other, not against an export). Only rung 0b's sha-ancestor check sees that, after."
  say ""

  if [ "$ok" -ne 1 ]; then
    FULL_WHY="${stale_note}a full-export precondition did not hold — (a) $cond_a · (b) $cond_b · (c) $cond_c · (d) $cond_d · (f) $cond_f · (e) $cond_e"
    return 1
  fi

  # ── the attempt is spent BEFORE the request, and flushed to disk ───────────
  local spent_now
  spent_now=$((spent + 1))
  printf '%s\n' "$spent_now" >"$FULL_ATTEMPTS_FILE"
  # A killed run must not come back to a counter that never moved.
  ( command -v sync >/dev/null 2>&1 && sync ) 2>/dev/null || true
  info "attempt         $spent_now of $FULL_BUDGET — counter flushed to $FULL_ATTEMPTS_FILE BEFORE the request"

  # ── the RSS sampler: 1 Hz ps over SSH, NO slot restart (PDS-D70) ──────────
  # RSS is MEASURED for THIS export, never quoted from a prior run's figure;
  # when no sampler can be started the run says so and quotes nothing (below).
  local rss_log rss_pid beam_pid beam_all beam_n baseline_kb peak_kb
  rss_log="$ART_DIR/full-export-rss.log"
  art_dir_ensure
  : >"$rss_log"
  beam_pid=""; rss_pid=""; beam_all=""; beam_n=0
  if ssh_available; then
    # ── WHICH BEAM (PDS-D135) ─────────────────────────────────────────────
    #
    # The selector was `pgrep -f beam.smp | head -1`, and BOTH halves were
    # wrong. `-f` matches any process whose ARGV merely CONTAINS the literal,
    # so the harness's own `ssh … pgrep -f beam.smp` shell is itself a match;
    # and `head -1` is a PID sort, not an age sort, so under PID wraparound a
    # freshly spawned foreign matcher outranks a long-running BEAM. A captured
    # run sampled a monitoring shell (pid 619341) instead of the real BEAM
    # (pid 663029) and under-read RSS by ~342x, while criterion 9 of the crown
    # proof asks for the run's OWN measured peak. Wave 7 could only vouch for
    # the figure with a manual `head1 == oldest` bracket; an instrument whose
    # honesty depends on a human side-check is not an instrument.
    #
    # `-x` anchors on the process NAME (comm), so a shell whose argv mentions
    # beam.smp cannot match at all; `-o` selects the OLDEST match — the BEAM
    # that was already running when the export started, not one a mid-run
    # deploy brought up.
    #
    # The source is a BLUE/GREEN box and legitimately runs TWO slots at once
    # (measured live: pids 873329 and 875573 alive together, 466 MB and 208 MB).
    # The oldest is reported as the primary, but EVERY comm-anchored BEAM is
    # sampled and the peak is the MAX ACROSS THE SET — pinning one pid would
    # silently under-read whenever the export is served by the other slot, and
    # peak RSS is quoted as a box-level OOM-risk figure (PDS-D31), not as a
    # per-process attribution.
    beam_pid="$(ssh_src "pgrep -o -x beam.smp" | tr -d '[:space:]' || true)"
    beam_all="$(ssh_src "pgrep -x beam.smp | tr '\n' ' '" | tr -s '[:space:]' ' ' || true)"
    beam_n="$(printf '%s' "$beam_all" | wc -w | tr -d ' ')"
    baseline_kb="$(ssh_src "ps -o rss= -p ${beam_pid:-0}" | tr -d '[:space:]' || true)"
    if [ -n "$beam_pid" ]; then
      ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
        -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
        "for i in \$(seq 1 900); do pgrep -x beam.smp | while read -r p; do ps -o rss= -p \$p 2>/dev/null; done; sleep 1; done" \
        >"$rss_log" 2>/dev/null &
      rss_pid=$!
      info "rss sampler     1 Hz \`ps -o rss=\` over SSH (pid $rss_pid) across ALL ${beam_n} comm-anchored beam.smp slot(s) [$(printf '%s' "${beam_all:-none}" | tr -s ' ' ' ')], primary (oldest) pid $beam_pid at baseline ${baseline_kb:-?} KB. Selector is \`pgrep -o -x beam.smp\`, NOT \`pgrep -f … | head -1\` (PDS-D135: -f self-matches this very ssh command and a PID sort is not an age sort). No slot restart: cgroup memory.peak is 0444 on this kernel and only a restart resets it, at ~26 s of LIVE content-API downtime — so any cgroup figure would be CUMULATIVE-SINCE-BOOT, not this export's."
    else
      info "rss sampler     NOT STARTED — no process on the source has comm == beam.smp. Nothing is quoted for RSS rather than sampling whatever a looser argv match happened to return."
    fi
  fi

  local t0 t1 code bytes parked_before parked_sum
  # THE DOWNLOAD LANDS ON A SIBLING PATH, NEVER ON THE PARKED ONE. Recorded here
  # so every failure branch below can state, with measured figures, that the
  # bundle an operator may still need is exactly where it was.
  parked_before="absent"
  if [ -s "$FULL_TAR" ]; then
    parked_before="$(first_int "$(wc -c <"$FULL_TAR" 2>/dev/null | tr -d ' ')") bytes"
  fi
  TMP_FILES="$TMP_FILES $FULL_TMP_TAR"
  rm -f "$FULL_TMP_TAR"
  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around an HTTP/CLI call issued
  # from THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock
  # OUTSIDE every BEAM. It has to be: the BEAM doing the work is the SERVER, on
  # another host, and there is no in-BEAM meter this instrument could reach even
  # if it wanted one. The unit is wall by necessity and the figure is quoted as a
  # LATENCY, never as a price: PDS-D605 forbids a wall-clock second standing in
  # for CPU (wall swung 2.5x on an unchanged census where user CPU moved 9%), so
  # nothing here may be read as what the export COST. A price for this instrument
  # comes from `pds-door-census.sh --measure`; a regression ratchet would need
  # `Process.info(pid, :reductions)`, which a shell has not got.
  t0="$(date +%s)"
  code="$(http_code "$(curl_src "/api/workspaces/$SOURCE_WS/export" -o "$FULL_TMP_TAR" -w '%{http_code}' \
            --max-time "${PDS_FULL_EXPORT_TIMEOUT:-900}" 2>/dev/null || true)")"
  t1="$(date +%s)"

  if [ -n "$rss_pid" ]; then kill "$rss_pid" 2>/dev/null || true; wait "$rss_pid" 2>/dev/null || true; fi
  peak_kb="$(first_int "$(awk '{ if ($1+0 > m) m = $1+0 } END { print m+0 }' "$rss_log" 2>/dev/null)")"

  bytes="$(first_int "$(wc -c <"$FULL_TMP_TAR" 2>/dev/null | tr -d ' ')")"
  if [ "$code" != "200" ] || ! int_ok "$bytes" || [ "$bytes" -lt 1024 ]; then
    rm -f "$FULL_TMP_TAR"
    FULL_WHY="the full export returned HTTP $code / $bytes bytes and the attempt is spent ($spent_now of $FULL_BUDGET). A dead export still paid its memory peak, which is exactly why the counter moved first. The body landed on $FULL_TMP_TAR and has been removed; the previously parked bundle at $FULL_TAR is UNTOUCHED ($parked_before before the request, $([ -s "$FULL_TAR" ] && printf '%s bytes' "$(wc -c <"$FULL_TAR" | tr -d ' ')" || printf 'absent') after it)."
    [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
    return 1
  fi
  # THE SIBLING BRANCH CLEANS UP TOO (the absorbed task-ded188685e54afef). HTTP
  # 200, >= 1024 bytes and a profile the predicate refuses used to release the
  # lock and return 1 with NO rm — leaving ~1 GB of unusable, provenance-free
  # archive at the run-stable path, indistinguishable on disk from a good bundle,
  # which every future acquire then deterministically refused. `rm -f` appears
  # on BOTH branches now, and neither can reach the parked path at all.
  if ! full_meta_ok "$FULL_TMP_TAR"; then
    rm -f "$FULL_TMP_TAR"
    FULL_WHY="the export returned HTTP 200 and $bytes bytes, but what came back is not a usable full-profile bp-export-v1 bundle: $FULL_META_WHY. The rejected body was removed from $FULL_TMP_TAR rather than parked; the previously parked bundle at $FULL_TAR is UNTOUCHED ($parked_before before the request, $([ -s "$FULL_TAR" ] && printf '%s bytes' "$(wc -c <"$FULL_TAR" | tr -d ' ')" || printf 'absent') after it)."
    [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
    return 1
  fi

  # ── MOVE INTO PLACE, and only now ────────────────────────────────────────
  # Same directory, so this is a rename(2): the parked path goes from the OLD
  # bundle to the NEW one with no window in which it holds a partial body.
  if ! mv -f "$FULL_TMP_TAR" "$FULL_TAR"; then
    FULL_WHY="the export returned a valid $bytes-byte full bundle at $FULL_TMP_TAR but it could not be moved onto $FULL_TAR. The validated body is left at $FULL_TMP_TAR; the previously parked bundle is untouched ($parked_before)."
    [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
    return 1
  fi
  parked_sum="replaced the $parked_before parked bundle"
  [ "$parked_before" = "absent" ] && parked_sum="parked where nothing was"

  if int_ok "$peak_kb" && [ "$peak_kb" -gt 0 ]; then
    FULL_RSS_LINE="beam.smp RSS peaked at $((peak_kb / 1024)) MB — the MAX over ${beam_n:-?} comm-anchored beam.smp slot(s), measured by a 1 Hz ps sampler over SSH across this export only (primary/oldest pid ${beam_pid:-?}, baseline ${baseline_kb:-?} KB, $(grep -c . "$rss_log" 2>/dev/null || echo 0) samples, no slot restart)"
  else
    FULL_RSS_LINE="beam.smp RSS was NOT measured this run (no sampler could be started) — no figure is quoted in its place"
  fi

  cat >"$FULL_META" <<EOF
served_sha:     ${DEPLOYED_SHA:-unresolved}
served_version: ${DEPLOYED_VERSION:-unknown}
bytes:          $bytes
wall_seconds:   $((t1 - t0))
taken_at:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')
attempt:        $spent_now of $FULL_BUDGET
rss_method:     1 Hz ps -o rss= -p <beam pid> over SSH, no slot restart
rss_scope:      WHOLE-PROCESS beam.smp RSS over the export window, ambient live-API traffic INCLUDED — not export-exclusive
rss_peak_kb:    $peak_kb
rss_baseline_kb: ${baseline_kb:-unknown}
run_id:         $RUN_ID
EOF

  info "full bundle     HTTP 200 · $bytes bytes · $((t1 - t0))s · $FULL_RSS_LINE"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around an HTTP/CLI call issued from this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM doing the work is the remote SERVER, so no in-BEAM meter is reachable. A LATENCY, never a price (PDS-D605)" \
    "full bundle"
  info "                parked at $FULL_TAR (+ .meta) — run-stable, so the NEXT run reuses it for 0 attempts. Downloaded to $FULL_TMP_TAR and moved into place ONLY after full_meta_ok passed on it ($parked_sum)."
  [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
  return 0
}

step_3() {
  head_step 3 "TICKET-DENY BYTE-SCAN — bytes at ROW grain, never a count diff"

  say "  WHAT A RAW BYTE SCAN CANNOT DO ALONE, learned by running it. The ticket's"
  say "  doc_id and row uuid are DISCUSSED IN PROSE inside other documents (this"
  say "  wave's own papers and tasks quote them). A naive 'these bytes appear"
  say "  nowhere' assertion therefore FIRES on a bundle where the deny held"
  say "  perfectly — a false alarm that reads exactly like a leak. So the assertion"
  say "  is made at ROW grain: no ticket-carrying table member, and zero ROWS in"
  say "  documents.copy whose own doc_id/type/id fields identify the ticket. The"
  say "  byte hits are still printed — and each one is CLASSIFIED by the document"
  say "  that contains it, so a prose reference is never silently equated with the row."
  say ""

  if [ -z "$DEV_BUNDLE" ]; then
    abort 3 "step:0a" "no dev bundle to scan — step 0a did not produce one."
    return 0
  fi

  local doc_id row_uuid
  doc_id="$(curl_src "/v1/data/query/$SOURCE_DS/ticket?perspective=raw&limit=1" \
    | jqp 'd["result"]["documents"][0]["_id"]' 2>/dev/null || true)"
  if [ -z "$doc_id" ]; then
    fail 3 "no ticket row is visible on the source at the raw perspective — the deny leg has nothing to prove absent, so a clean scan below would be vacuous"
    return 0
  fi
  # The published id, if this is a draft (the source's sole ticket is one).
  local pub_id
  pub_id="${doc_id#drafts.}"
  info "ticket doc_id   $doc_id (published id: $pub_id) — RE-DERIVED this run"

  row_uuid=""
  if ssh_available; then
    row_uuid="$(src_psql "SELECT id FROM documents WHERE doc_id IN ('$doc_id','$pub_id') LIMIT 1" | tr -d '[:space:]' || true)"
    info "ticket row uuid $row_uuid — RE-DERIVED this run (the surveys disagree on it; the run is the arbiter)"
  else
    info "ticket row uuid NOT derivable (source DB unreachable) — the row assertion below falls back to doc_id and type"
  fi

  # (a) no ticket-carrying table member at all.
  local bdir ticket_members
  bdir="$(mktemp -d "${TMPDIR:-/tmp}/pds-bundle.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $bdir"
  tar -xf "$DEV_BUNDLE" -C "$bdir"
  ticket_members="$(tar -tf "$DEV_BUNDLE" | grep -i ticket | tr '\n' ' ' | sed 's/ *$//' || true)"
  if [ -n "$ticket_members" ]; then
    fail 3 "the dev bundle carries ticket-named member(s): $ticket_members"
    return 0
  fi
  info "members         no ticket-carrying table member in $(tar -tf "$DEV_BUNDLE" | wc -l | tr -d ' ') members"

  # (b) zero ROWS in documents.copy that ARE the ticket. Column positions come
  # from the manifest's own column list for `documents` — never a hardcoded
  # ordinal, which would silently mis-read after any column addition.
  local cols i_id i_docid i_type n_cols rows
  cols="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
t=[x for x in d["tables"] if x["name"]=="documents"]
if not t: sys.exit(1)
c=t[0]["columns"]
print(c.index("id")+1, c.index("doc_id")+1, c.index("type")+1, len(c))' "$bdir/manifest.json" 2>/dev/null || true)"
  if [ -z "$cols" ]; then
    fail 3 "the manifest does not describe a documents member — the row-grain assertion cannot be made, and a byte scan alone cannot distinguish the row from prose about it"
    return 0
  fi
  i_id="$(printf '%s' "$cols" | awk '{print $1}')"
  i_docid="$(printf '%s' "$cols" | awk '{print $2}')"
  i_type="$(printf '%s' "$cols" | awk '{print $3}')"
  n_cols="$(printf '%s' "$cols" | awk '{print $4}')"
  # THE OPERAND OF THE GRAMMAR ASSERTION IS ITSELF AN ASSERTION. If n_cols is
  # not an integer the `-ne` below errors, evaluates FALSE, and the grammar
  # check is SKIPPED — after which the tab-split scan finds no ticket rows by
  # construction and step 3 passes. The check that exists to stop a vacuous
  # clean is the one a non-integer disables, so it is guarded first.
  if ! int_ok "$n_cols"; then
    fail 3 "the manifest's documents column count read as '${n_cols:-<empty>}', not an integer — the COPY TEXT grammar assertion below cannot be evaluated, and an unevaluated grammar check makes every ticket-row zero that follows it vacuous"
    return 0
  fi
  info "columns         documents: id=\$$i_id doc_id=\$$i_docid type=\$$i_type of $n_cols (from the manifest, this run)"

  # (b0) THE PARSE ITSELF IS AN ASSERTION. The row grammar below is Postgres
  # COPY TEXT — tab-separated, one row per line, embedded newlines escaped. If
  # the member is missing, empty, or ever moves to CSV/BINARY, a tab-split awk
  # reports zero ticket rows and step 3 goes FALSELY CLEAN — the exact failure
  # this step exists to catch. So refuse to trust the parse until it is shown to
  # BE that grammar: the member must exist, carry rows, and its first row must
  # split into exactly the number of fields the manifest declares.
  local docs_copy docs_rows first_fields
  docs_copy="$bdir/tables/documents.copy"
  if [ ! -s "$docs_copy" ]; then
    fail 3 "tables/documents.copy is absent or empty in the dev bundle — a zero ticket-row count over an empty member is vacuous, not clean"
    return 0
  fi
  docs_rows="$(first_int "$(grep -c . "$docs_copy" 2>/dev/null)")"
  first_fields="$(first_int "$(head -n 1 "$docs_copy" | awk -F'\t' '{print NF}')")"
  if ! int_ok "$first_fields"; then
    fail 3 "tables/documents.copy's first row yielded no field count — the member could not be read as text at all, so the COPY TEXT grammar assertion cannot be evaluated"
    return 0
  fi
  if [ "$first_fields" -ne "$n_cols" ]; then
    fail 3 "tables/documents.copy is not the COPY TEXT grammar this assertion parses: its first row splits into ${first_fields:-0} tab-separated fields, the manifest declares $n_cols columns. A tab-split scan of a non-text dump silently finds nothing — refusing to report clean off an unparsed member."
    return 0
  fi
  info "grammar         COPY TEXT confirmed: $docs_rows row(s), first row = $first_fields fields = the manifest's $n_cols columns"

  rows="$(awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v u="$row_uuid" \
            -v ii="$i_id" -v idc="$i_docid" -v it="$i_type" '
          $it == "ticket" || $idc == a || $idc == b || (u != "" && $ii == u) { n++ }
          END { print n + 0 }' "$docs_copy" 2>/dev/null || echo ERR)"
  if ! int_ok "$rows"; then
    fail 3 "could not read tables/documents.copy out of the dev bundle — the row count read as '${rows:-<empty>}', not an integer"
    return 0
  fi
  info "ticket ROWS in tables/documents.copy: $rows (asserted 0)"
  if [ "$rows" -ne 0 ]; then
    fail 3 "the DEV bundle CARRIES $rows ticket row(s) in documents.copy — the type deny did not cascade"
    return 0
  fi

  # (c) the byte scan, printed and CLASSIFIED.
  local args rc out
  out="$(mktmp)"
  args="--bundle $DEV_BUNDLE --profile dev --value $doc_id --value $pub_id"
  [ -n "$row_uuid" ] && args="$args --value $row_uuid"
  rc=0
  # shellcheck disable=SC2086
  "$SCAN_SCRIPT" scan $args >"$out" 2>&1 || rc=$?
  sed 's/^/      /' "$out"
  if [ "$rc" -gt 1 ]; then
    fail 3 "the scan could not run (exit $rc) — see above"
    return 0
  fi

  if [ "$rc" -eq 1 ]; then
    say ""
    info "CLASSIFYING every byte hit — which document CONTAINS it:"
    awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v u="$row_uuid" \
        -v idc="$i_docid" -v it="$i_type" '
      { line = $0 }
      index(line, a) || index(line, b) || (u != "" && index(line, u)) {
        printf "        containing row: doc_id=%s type=%s  (a PROSE reference in this row'\''s own content, not the ticket row)\n", $idc, $it
      }' "$docs_copy" | sort -u | head -20
    info "None of the above IS the ticket row — the row-grain count is 0. This is the"
    info "false-alarm shape a naive byte scan produces for an identifier that other"
    info "documents talk about, and it is reported rather than suppressed."
  else
    info "dev bundle: zero byte hits as well (mechanism = type DENY cascading into documents)"
  fi

  # ── (d) THE POSITIVE CONTROL: the same identifiers, FOUND in a FULL bundle ─
  #
  # A row-grain zero that has never been shown to be capable of a non-zero is
  # not a proof. The control is the SAME assertion, same run, same binary,
  # against the one full-fidelity bundle: the ticket row MUST be there.
  say ""
  info "POSITIVE CONTROL — the same row-grain assertion against the ONE full bundle:"
  if ! acquire_full_bundle; then
    abort 3 "env:full-export-unavailable" \
      "the ROW-GRAIN zero above is real — and it is HALF a proof without a control that fires. The one full-fidelity bundle could not be acquired: $FULL_WHY. This ABORT is SEVERABLE: it costs steps 3 and 4 only; every other rung ran."
    return 0
  fi

  local fdir f_cols f_i_docid f_i_type f_n_cols f_docs_copy f_docs_rows f_first_fields f_rows
  fdir="$(mktemp -d "${TMPDIR:-/tmp}/pds-full.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $fdir"
  if ! tar -xf "$FULL_TAR" -C "$fdir" manifest.json tables/documents.copy 2>/dev/null; then
    fail 3 "the full bundle carries no manifest.json + tables/documents.copy pair — the control cannot be run, and a zero without a control is not reportable"
    return 0
  fi
  f_cols="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
t=[x for x in d["tables"] if x["name"]=="documents"]
if not t: sys.exit(1)
c=t[0]["columns"]
print(c.index("doc_id")+1, c.index("type")+1, len(c))' "$fdir/manifest.json" 2>/dev/null || true)"
  if [ -z "$f_cols" ]; then
    fail 3 "the full bundle's manifest does not describe a documents member — the control cannot be run"
    return 0
  fi
  f_i_docid="$(printf '%s' "$f_cols" | awk '{print $1}')"
  f_i_type="$(printf '%s' "$f_cols" | awk '{print $2}')"
  f_n_cols="$(printf '%s' "$f_cols" | awk '{print $3}')"

  # (d0) THE CONTROL'S PARSE IS AN ASSERTION TOO — the mirror of (b0) above.
  # The dev leg refuses to trust its tab-split until the member is shown to BE
  # COPY TEXT; the control leg used to parse blind. Its polarity ("> 0") means a
  # broken grammar collapses NF, matches nothing, and surfaces as the generic
  # "THE CONTROL DID NOT FIRE" — which BLAMES THE AMMO for a grammar problem.
  # So the same three assertions run here, and they fail with a NAMED grammar
  # message that says the ammo is not the suspect.
  if ! int_ok "$f_n_cols"; then
    fail 3 "CONTROL GRAMMAR, NOT AMMO: the FULL bundle manifest's documents column count read as '${f_n_cols:-<empty>}', not an integer — the control's COPY TEXT grammar assertion cannot be evaluated, and an unevaluated grammar check makes the control's own count vacuous."
    return 0
  fi
  f_docs_copy="$fdir/tables/documents.copy"
  if [ ! -s "$f_docs_copy" ]; then
    fail 3 "CONTROL GRAMMAR, NOT AMMO: tables/documents.copy is absent or empty in the FULL bundle — a control that counts zero over an empty member has not been shown capable of a non-zero at all, so it says nothing about the ammo and nothing about the dev bundle's zero."
    return 0
  fi
  f_docs_rows="$(first_int "$(grep -c . "$f_docs_copy" 2>/dev/null)")"
  f_first_fields="$(first_int "$(head -n 1 "$f_docs_copy" | awk -F'\t' '{print NF}')")"
  if ! int_ok "$f_first_fields"; then
    fail 3 "CONTROL GRAMMAR, NOT AMMO: the FULL bundle's tables/documents.copy first row yielded no field count — the member could not be read as text at all, so the control's COPY TEXT grammar assertion cannot be evaluated."
    return 0
  fi
  if [ "$f_first_fields" -ne "$f_n_cols" ]; then
    fail 3 "CONTROL GRAMMAR, NOT AMMO: the FULL bundle's tables/documents.copy is not the COPY TEXT grammar this control parses — its first row splits into $f_first_fields tab-separated fields, its own manifest declares $f_n_cols columns. A tab-split scan of a non-text dump finds nothing for ANY ammo, so the doc_id is not the suspect: the member's grammar is."
    return 0
  fi
  info "control grammar COPY TEXT confirmed in the FULL bundle: $f_docs_rows row(s), first row = $f_first_fields fields = its manifest's $f_n_cols columns"

  # The non-empty predicates on a and b mirror the dev leg's (u != "") guard.
  # Empty ammo compared against a field an NF-short member does not have matches
  # EVERY line, which would manufacture a firing control out of garbage.
  f_rows="$(awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v idc="$f_i_docid" -v it="$f_i_type" '
            $it == "ticket" || (a != "" && $idc == a) || (b != "" && $idc == b) { n++ }
            END { print n + 0 }' "$f_docs_copy" 2>/dev/null || echo ERR)"
  info "full bundle     ticket ROWS in tables/documents.copy: $f_rows (the control must be > 0)"
  if ! int_ok "$f_rows" || [ "$f_rows" -eq 0 ]; then
    fail 3 "THE CONTROL DID NOT FIRE — AND IT IS NOT A GRAMMAR PROBLEM: the FULL bundle's COPY TEXT grammar was CONFIRMED above ($f_docs_rows rows, first row = $f_first_fields fields = its manifest's $f_n_cols columns), so the parse is sound and this count of $f_rows is a real read. That leaves AMMO or FIDELITY: either the ammo (doc_id=$doc_id) is wrong, or this bundle is not full fidelity — and until the assertion is shown capable of a non-zero, the dev bundle's zero above proves nothing (PDS-D20)."
    return 0
  fi

  pass 3 "the type deny cascades into documents at ROW grain: 0 ticket rows in the DEV bundle, $f_rows in the FULL bundle taken from the same source and asserted the same way this run. The dev zero is a measurement, not an absence of measurement."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — VALUE-BASED SECRET SCAN
# ═════════════════════════════════════════════════════════════════════════════

# Ammo resolution, in order. NEVER printed — pds-secret-scan.sh masks every value
# to length + sha256 prefix, and the file is mode 600 and removed on exit.
resolve_ammo() {
  if [ -n "${PDS_AMMO_FILE:-}" ] && [ -r "${PDS_AMMO_FILE}" ]; then
    AMMO_FILE="$PDS_AMMO_FILE"
    info "ammo            $(wc -l <"$AMMO_FILE" | tr -d ' ') value(s) from PDS_AMMO_FILE"
    return 0
  fi
  if [ "${PDS_NO_SSH_AMMO:-0}" = "1" ]; then
    return 1
  fi
  ssh_available || return 1
  local f n
  f="$(mktmp)"
  chmod 600 "$f"
  src_psql "SELECT secret FROM webhooks WHERE secret IS NOT NULL AND secret <> ''" >"$f" || true
  n="$(first_int "$(grep -c . "$f" 2>/dev/null)")"
  # FAIL CLOSED ON UNKNOWN. This refusal is the only thing standing between an
  # unusable ammo file and a step 4 that prints "dev bundle: CLEAN" / "target
  # DB: CLEAN" having fired zero values. Before this guard the capture was
  # `grep -c . "$f" || echo 0`, which on an EMPTY file printed 0 AND exited 1 —
  # both sides fired, the value was $'0\n0', the `-eq` errored to FALSE, and
  # the refusal was skipped. An unreadable count is not a count of zero, but
  # both must refuse here, so they share one branch.
  if ! int_ok "$n" || [ "$n" -eq 0 ]; then
    return 1
  fi
  AMMO_FILE="$f"
  info "ammo            $n webhook secret(s) pulled read-only from the source DB this run; lengths $(awk '{print length($0)}' "$f" | sort -u | tr '\n' ',' | sed 's/,$//') bytes. Values are never printed."
  return 0
}

step_4() {
  head_step 4 "VALUE-BASED SECRET SCAN — consuming scripts/pds-secret-scan.sh"

  if [ ! -x "$SCAN_SCRIPT" ]; then
    fail 4 "$SCAN_SCRIPT is missing or not executable — this step consumes it and must never reimplement it"
    return 0
  fi

  # Steps 2/5/6 each refuse to measure a target this run did not populate; step 4
  # did not, so --only 4 would scan a target left behind — or step-6-clobbered —
  # by a DIFFERENT process and report it as a leg of a PASS (PDS-D97). Checked
  # BEFORE resolve_ammo: this costs nothing, while ammo resolution may reach for
  # the source DB over SSH to answer a question this run cannot use.
  if [ -z "${PULL_BUNDLE:-}" ]; then
    abort 4 "step:1" \
      "no bundle was imported this run, so the TARGET-DB leg below has nothing it can honestly attribute to this transcript. Re-run with step 1 selected (--only 1,4); a target populated by an earlier run is not evidence for this one."
    return 0
  fi

  if ! resolve_ammo; then
    abort 4 "env:no-ammo" \
      "no run-time ammo. The one real discriminator is webhooks.secret, which the HTTP API deliberately never re-exposes after creation, so ammo comes from the source DB (SSH, read-only) or from PDS_AMMO_FILE. A scan with no ammo is not a scan — it is refused rather than reported clean."
    return 0
  fi

  local rc out unscanned dev_leg
  out="$(mktmp)"
  rc=0
  # Which legs actually ran is reported by the PASS line, never assumed by it.
  dev_leg=0
  if [ -n "$DEV_BUNDLE" ]; then
    "$SCAN_SCRIPT" scan --bundle "$DEV_BUNDLE" --ammo-file "$AMMO_FILE" --profile dev >"$out" 2>&1 || rc=$?
    sed 's/^/      /' "$out"
    unscanned="$(grep -c 'UNSCANNED' "$out" 2>/dev/null || true)"
    info "UNSCANNED notices in the output above: ${unscanned:-0} (never silenced — an unscannable table is not a clean table)"
    if [ "$rc" -eq 1 ]; then
      fail 4 "the DEV bundle CARRIES enumerated secret values — the dev partition's table deny did not hold"
      return 0
    elif [ "$rc" -ne 0 ]; then
      fail 4 "the scan could not run against the dev bundle (exit $rc)"
      return 0
    fi
    dev_leg=1
    info "dev bundle: CLEAN"
  else
    info "no dev bundle from step 0a — the bundle half of this step did not run"
  fi

  # The instrument's OWN control: a local throwaway fixture, no guerrilla export.
  # The maintenance connection is RESOLVED (see resolve_control_pg), so the
  # default run no longer reports a clean scan next to a control that never ran.
  if resolve_control_pg; then
    local crc cout leftovers
    cout="$(mktmp)"
    crc=0
    info "instrument control: maintenance PG resolved from $CONTROL_PG_SRC — no guerrilla export is spent by this leg"
    "$SCAN_SCRIPT" control --pg "$CONTROL_PG" >"$cout" 2>&1 || crc=$?
    sed 's/^/      /' "$cout"
    # THE FIXTURE MUST BE GONE, whichever way the control went. The drop is the
    # sibling's own EXIT trap (pds-secret-scan.sh's cleanup, which runs on
    # success and on failure) — so this does not reimplement the cleanup, it
    # JUDGES it, the same way the UNSCANNED gate below judges coverage rather
    # than re-scanning. Leftovers are named with the exact command that removes
    # them; a stray throwaway database does not invalidate the scan above, so it
    # is reported rather than promoted to a FAIL.
    leftovers=""
    if command -v psql >/dev/null 2>&1; then
      leftovers="$(PGCONNECT_TIMEOUT="${PDS_CONTROL_PG_TIMEOUT:-5}" psql "$CONTROL_PG" -X -Atq \
        -c "SELECT datname FROM pg_database WHERE datname LIKE 'pds!_secret!_scan!_ctl!_%' ESCAPE '!'" 2>/dev/null | tr '\n' ' ' || true)"
      leftovers="$(printf '%s' "$leftovers" | sed 's/ *$//')"
    fi
    if [ -n "$leftovers" ]; then
      info "control fixture: NOT fully cleaned — throwaway database(s) still present: $leftovers (drop with: psql <maintenance conninfo> -c 'DROP DATABASE \"<name>\"')"
    else
      info "control fixture: cleaned — no pds_secret_scan_ctl_* database remains on the maintenance server"
    fi
    if [ "$crc" -eq 0 ]; then
      info "instrument control: PASSED — the scan FIRES on a full-shaped fixture and comes back clean on a deny-shaped one"
    else
      fail 4 "the scan's own control did not behave as a control (exit $crc) — every clean result above is therefore uninterpretable"
      return 0
    fi
  else
    info "instrument control: NOT RUN — no maintenance PostgreSQL this harness could PROVE is local, privileged and non-production: $CONTROL_PG_WHY"
    info "                    (set PDS_CONTROL_PG=<maintenance conninfo> to name one; \`$SCAN_SCRIPT control\` builds its own throwaway fixture and spends no guerrilla export)"
  fi

  # ── (b) THE TARGET DB — and a HARD gate on UNSCANNED (PDS-D68) ────────────
  #
  # pds-secret-scan.sh's exit code is driven ONLY by $HITS. An unscannable table
  # prints a skip line and a NOTE, and a table the role cannot read at all is
  # invisible even to that NOTE — "tables scanned: 0 · CLEAN" is a reachable
  # output with the secret sitting in the database. So the gate lives HERE: the
  # step FAILS on any UNSCANNED table and on a zero-table scan. No scan logic is
  # reimplemented — only its coverage is judged.
  if load_target && [ -n "$TARGET_DB" ]; then
    local drc dout unscanned_n tables_n
    dout="$(mktmp)"
    drc=0
    "$SCAN_SCRIPT" scan --db "$TARGET_DB" --ammo-file "$AMMO_FILE" --profile dev >"$dout" 2>&1 || drc=$?
    sed 's/^/      /' "$dout"
    unscanned_n="$(sed -n 's/^NOTE: \([0-9][0-9]*\) table(s) were UNSCANNED.*/\1/p' "$dout" | tail -1)"
    if [ -z "$unscanned_n" ]; then
      # grep -c PRINTS "0" *and* EXITS 1 on no-match, so `|| echo 0` fired BOTH
      # sides and yielded the two-line string "0\n0". The -gt test below then
      # errored to stderr ("integer expression expected") and evaluated FALSE —
      # silently skipping the PDS-D68 gate, and dropping a raw bash error into an
      # append-only evidence artifact. This fallback yields ONE integer (PDS-D99).
      unscanned_n="$(grep -c 'counted as UNSCANNED' "$dout" 2>/dev/null || true)"
      unscanned_n="${unscanned_n%%[!0-9]*}"
      [ -n "$unscanned_n" ] || unscanned_n=0
    fi
    tables_n="$(sed -n 's/.*tables scanned: \([0-9][0-9]*\).*/\1/p' "$dout" | tail -1)"
    info "target DB       exit=$drc · tables scanned=${tables_n:-?} · UNSCANNED=${unscanned_n:-0}"
    if [ "$drc" -eq 1 ]; then
      fail 4 "the TARGET DATABASE carries enumerated secret values after a dev-profile pull — the whole point of the dev profile did not hold"
      return 0
    elif [ "$drc" -ne 0 ]; then
      fail 4 "the scan could not run against the target DB (exit $drc)"
      return 0
    fi
    if [ -z "$tables_n" ] || [ "$tables_n" -eq 0 ]; then
      fail 4 "the target-DB scan reported ${tables_n:-no} tables scanned — a CLEAN over zero tables is not a clean database, it is an unscanned one (PDS-D68)"
      return 0
    fi
    if [ "${unscanned_n:-0}" -gt 0 ]; then
      fail 4 "$unscanned_n table(s) in the target database were UNSCANNED. pds-secret-scan.sh exits 0 on this by design — this step does not: an unscannable table is not a clean table."
      return 0
    fi
    info "target DB: CLEAN over $tables_n table(s), 0 UNSCANNED"
  else
    abort 4 "env:scratch-target-not-booted" \
      "the bundle half above ran, but the TARGET-DB half — scanning the rows that actually landed — needs a booted, populated target. FIX: $(target_hint) then re-run --only 1,4."
    return 0
  fi

  # ── (c) THE CONTROL THAT MATTERS: the same ammo FIRING on a FULL bundle ────
  say ""
  info "POSITIVE CONTROL — the SAME ammo against the ONE full-fidelity bundle:"
  if ! acquire_full_bundle; then
    abort 4 "env:full-export-unavailable" \
      "the dev bundle and the target database are both CLEAN over $(wc -l <"$AMMO_FILE" | tr -d ' ') enumerated value(s) — and a scan that has never fired is not an instrument. The full-fidelity bundle that makes those cleans interpretable could not be acquired: $FULL_WHY. SEVERABLE: this costs steps 3 and 4 only."
    return 0
  fi
  local frc fout
  fout="$(mktmp)"
  frc=0
  "$SCAN_SCRIPT" scan --bundle "$FULL_TAR" --ammo-file "$AMMO_FILE" --profile full >"$fout" 2>&1 || frc=$?
  sed 's/^/      /' "$fout"
  if [ "$frc" -ne 1 ]; then
    fail 4 "THE CONTROL DID NOT FIRE: the same ammo found NOTHING in the FULL bundle (exit $frc). Full fidelity carries webhooks.secret verbatim, so a clean here means the ammo is wrong — and every clean above is therefore uninterpretable (PDS-D20)."
    return 0
  fi

  # The PASS names the legs that ACTUALLY ran. Claiming a DEV-bundle leg in the
  # same breath as "no dev bundle from step 0a" printed twenty lines earlier is
  # the kind of overclaim rung 4 exists to catch (PDS-D97).
  local legs_ran
  if [ "$dev_leg" -eq 1 ]; then
    legs_ran="all three legs this run: the DEV bundle is CLEAN, the TARGET DATABASE"
  else
    legs_ran="two of three legs this run (NO dev bundle was available from step 0a, so that leg did NOT run and nothing here speaks to it): the TARGET DATABASE"
  fi
  pass 4 "value-based scan, $legs_ran is CLEAN over $tables_n table(s) with 0 UNSCANNED (gated here, not by the scan's own exit code), and the SAME ammo FIRES on the one full-fidelity bundle taken from the same source — the instrument is shown able to see before its silence is believed."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — THE SERVED ASSET
# ═════════════════════════════════════════════════════════════════════════════

# HEAD one asset -> "<http_code> <content-length>". originalUrl is taken
# VERBATIM from the target's own index: it may be SIGNED, and a URL rebuilt from
# /media/files/<path> would be a different request answering a different way.
head_asset() { # url_or_path -> "code<TAB>content_length"
  local u="$1" full hdr code clen
  case "$u" in
    http://*|https://*) full="$u" ;;
    *) full="$TARGET_BASE$u" ;;
  esac
  hdr="$(mktmp)"
  code="$(http_code "$(curl -sS -I --max-time 60 -H "Authorization: Bearer $TARGET_TOKEN" \
            -o "$hdr" -w '%{http_code}' "$full" 2>/dev/null || true)")"
  clen="$(grep -i '^content-length:' "$hdr" | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
  printf '%s\t%s\n' "$code" "${clen:-}"
}

step_5() {
  # (PDS-D67) the asset roster is resolved from the TARGET's own index and its
  # originalUrl/size are taken VERBATIM — never a path composed from the source.
  head_step 5 "SERVED ASSET — EVERY imported asset serves 200 with a matching content-length"

  say "  RESOLVED FROM THE TARGET'S OWN INDEX, never from a path guessed off the"
  say "  source: GET /v1/media/:dataset (the v1 route — the flat /media index emits"
  say "  no originalUrl at all and ignores ?limit). originalUrl and size are taken"
  say "  VERBATIM per asset; originalUrl may be signed."
  say ""

  if ! load_target; then
    abort 5 "env:scratch-target-not-booted" \
      "there is no target to serve an asset from. FIX: $(target_hint)"
    return 0
  fi
  if [ -z "${PULL_BUNDLE:-}" ]; then
    abort 5 "step:1" \
      "no pull ran this run, so any asset on the target came from somewhere this transcript cannot vouch for. Re-run with step 1 selected (--only 1,5)."
    return 0
  fi

  local idx count
  idx="$(mktmp)"
  curl_tgt "/v1/media/$SOURCE_DS?limit=500" >"$idx" 2>/dev/null || true
  count="$(jqp 'd["result"]["count"]' <"$idx" 2>/dev/null || true)"
  if [ -z "$count" ]; then
    fail 5 "GET $TARGET_BASE/v1/media/$SOURCE_DS did not answer a media index — the assets cannot be resolved from the target's own view, and resolving them any other way would be proving something about a guess"
    return 0
  fi
  if ! int_ok "$count"; then
    fail 5 "the media index count read as '${count:-<empty>}', not an integer — whether the --with-blobs import landed any media at all is UNKNOWN, and unknown is not zero"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    fail 5 "the target's media index is EMPTY after a --with-blobs import. The source carries assets, so a zero here is an import failure, not an empty dataset."
    return 0
  fi

  # One line per asset: path <TAB> size <TAB> originalUrl
  local rows n_ok=0 n_bad=0 bad=""
  rows="$(mktmp)"
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for a in d["result"]["assets"]:
    print("\t".join([str(a.get("path","")), str(a.get("size","")), str(a.get("originalUrl",""))]))
' "$idx" >"$rows" 2>/dev/null || true
  if [ ! -s "$rows" ]; then
    fail 5 "the media index answered count=$count but no asset rows could be read out of it"
    return 0
  fi

  local apath asize aurl r code clen
  while IFS="$(printf '\t')" read -r apath asize aurl; do
    [ -n "$aurl" ] || { n_bad=$((n_bad + 1)); bad="$bad $apath(no-originalUrl)"; continue; }
    r="$(head_asset "$aurl")"
    code="$(printf '%s' "$r" | cut -f1)"
    clen="$(printf '%s' "$r" | cut -f2)"
    if [ "$code" != "200" ]; then
      n_bad=$((n_bad + 1)); bad="$bad $apath(HTTP $code)"
    elif [ -z "$clen" ] || [ "$clen" != "$asize" ]; then
      n_bad=$((n_bad + 1)); bad="$bad $apath(len ${clen:-none} != size $asize)"
    else
      n_ok=$((n_ok + 1))
    fi
  done <"$rows"

  info "assets          $n_ok/$((n_ok + n_bad)) served 200 with content-length == the stored size"
  if [ "$n_bad" -ne 0 ]; then
    fail 5 "$n_bad asset(s) did not serve correctly:$bad"
    return 0
  fi

  # ── the failure demo, run inline and REVERSED ─────────────────────────────
  #
  # A 200 is not the assertion — the SIZE is. Truncate one blob and the route
  # still answers 200, with a content-length that matches the truncated body.
  # Only the size stored in the database convicts it. Disable with
  # PDS_STEP5_FAILDEMO=0 (and then say so, because the green is weaker).
  local demo="" demo_row demo_path demo_url demo_size disk r2 c2 l2
  if [ "${PDS_STEP5_FAILDEMO:-1}" = "1" ] && [ -n "$TARGET_MEDIA" ]; then
    # The LARGEST asset, not the last one: truncating to 100 bytes only
    # demonstrates anything when the blob is bigger than 100 bytes — on a
    # smaller one the "truncated" file is byte-identical and the demo would
    # report a comparator that cannot fire when in fact nothing was cut.
    demo_row="$(sort -t"$(printf '\t')" -k2,2n "$rows" | tail -1)"
    demo_path="$(printf '%s' "$demo_row" | cut -f1)"
    demo_size="$(printf '%s' "$demo_row" | cut -f2)"
    demo_url="$(printf '%s' "$demo_row" | cut -f3)"
    disk="$TARGET_MEDIA/$demo_path"
    if ! int_ok "${demo_size:-}"; then
      info "        skipping the size-comparator demo: the stored size read as '${demo_size:-<empty>}', not an integer — truncating a blob to prove a comparator fires against a size we could not parse would prove nothing"
    elif [ "$demo_size" -le 100 ]; then
      info "failure demo    SKIPPED — the largest imported asset is ${demo_size:-0} bytes, so a truncate-to-100 cuts nothing. Nothing was mutated, and the pass below is weaker for it."
      disk=""
    fi
    if [ -n "$disk" ] && [ -f "$disk" ]; then
      BLOB_ORIGINAL="$disk"
      BLOB_BACKUP="$(mktemp "${TMPDIR:-/tmp}/pds-blob.XXXXXX")"
      TMP_FILES="$TMP_FILES $BLOB_BACKUP"
      cp "$disk" "$BLOB_BACKUP"

      # (i) truncated blob — still 200, and the comparator must catch it.
      dd if="$BLOB_BACKUP" of="$disk" bs=1 count=100 2>/dev/null
      r2="$(head_asset "$demo_url")"; c2="$(printf '%s' "$r2" | cut -f1)"; l2="$(printf '%s' "$r2" | cut -f2)"
      info "FAILURE DEMO 1  $demo_path truncated to 100 bytes on disk -> HTTP $c2, content-length ${l2:-none}, stored size $demo_size"
      if [ "$c2" = "200" ] && [ "${l2:-0}" != "$demo_size" ]; then
        demo="the size comparator FIRED on a truncated blob that still served HTTP $c2"
      else
        demo=""
      fi

      # (ii) missing blob — the typed 404, never a 500.
      rm -f "$disk"
      r2="$(head_asset "$demo_url")"; c2="$(printf '%s' "$r2" | cut -f1)"
      info "FAILURE DEMO 2  $demo_path removed from disk -> HTTP $c2 (the typed 'media blob missing' 404, never a 500)"
      restore_blob_backup
      r2="$(head_asset "$demo_url")"; l2="$(printf '%s' "$r2" | cut -f2)"
      info "RESTORED        $demo_path -> content-length ${l2:-none} (stored size $demo_size)"

      if [ -z "$demo" ]; then
        fail 5 "the failure demonstration did NOT fire: a blob truncated to 100 bytes was not caught by the content-length assertion. An assertion that cannot fail is not an instrument (PDS-D20)."
        return 0
      fi
      # The claim is the TYPED 404, so assert 404 — not merely "not a 500".
      # A 200 here would mean a missing blob still served bytes from somewhere
      # (a cache, a fallback), which is a worse answer than a 500 and would
      # sail through a not-500 check.
      if [ "$c2" != "404" ]; then
        fail 5 "a MISSING blob answered HTTP $c2, not the typed 404 'media blob missing'$([ "$c2" = "500" ] && printf ' — the honest-404 guard is not holding' || printf ' — a missing blob must never serve, and must never be a bare 5xx')"
        return 0
      fi
    elif [ -n "$disk" ]; then
      info "failure demo    SKIPPED — that asset's blob is not at \$BARKPARK_MEDIA_DIR/$demo_path (nothing was mutated)"
    fi
  else
    info "failure demo    DISABLED (PDS_STEP5_FAILDEMO=0) — the pass below is weaker for it: nothing proved the size comparator can fail"
  fi

  pass 5 "$((n_ok)) imported asset(s) resolved from the TARGET's own /v1/media/$SOURCE_DS and every one served HTTP 200 with content-length == the size stored in the target's database.${demo:+ Control: $demo, and a missing blob answered the typed 404 rather than a 500.}"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — REBOOTED CONVERGENCE (what the Bootstrap clobber guard MEASURES)
# ═════════════════════════════════════════════════════════════════════════════

# The EIGHT columns the boot-time plugin schema upsert reverts when it matches a
# row in the Default slot — title, icon, visibility, owner_scoped, fields, plus
# cors_origins, desk_groups and list_preview, which revert to bare plugin-struct
# defaults even when the plugin says nothing about them. Digested as one value so
# a single changed byte anywhere shows up.
# KEYED BY (dataset, name) — that pair, not `name` alone, is the table's unique
# index (create_initial_tables.exs:35). Digesting with `ORDER BY name` on a
# target holding the same schema name in two datasets leaves string_agg's order
# undefined between the tied rows, so two reads of an UNCHANGED database can
# differ and the reboot comparison would report a clobber that never happened.
GUARDED_DIGEST_SQL="SELECT md5(string_agg(dataset || '|' || name || '|' || coalesce(title,'') || '|' || coalesce(icon,'') || '|' || coalesce(visibility,'') || '|' || coalesce(owner_scoped::text,'') || '|' || coalesce(fields::text,'') || '|' || coalesce(cors_origins::text,'') || '|' || coalesce(desk_groups::text,'') || '|' || coalesce(list_preview::text,''), E'\n' ORDER BY dataset, name)) || ' rows=' || count(*) FROM schema_definitions"

# The same eight, addressable one at a time. A whole-table digest answers "did
# ANYTHING move"; leg B needs "did EVERY ONE of the eight move", because a
# partial clobber that reverts six columns and leaves two alone still moves the
# aggregate and would read as a clean control firing (PDS-D130).
GUARDED_COLUMNS="title icon visibility owner_scoped fields cors_origins desk_groups list_preview"

# ── THE 34 (PDS-D127/PDS-D128) ───────────────────────────────────────────────
#
# `schema_definitions` on a pulled target holds 36 rows in three CLASSES, and
# only one of them behaves the way the guard is about:
#
#   34  plugin-declared    Bootstrap walks them every boot. SURVIVE stamped,
#                          REVERT cleared. These, and only these, are the guard.
#    1  `tag`              TagRegistry writes it every boot from a five-key map,
#                          BEFORE register_all_schemas/0 and outside BOOTSTRAP's
#                          registry walk — but NOT outside the guard. It goes
#                          through the SAME `Tenancy.pulled_schema_row/2`
#                          predicate as the 34 — PDS-D125/PDS-D126, in
#                          `Content.TagRegistry.register_attrs!/2` — so it
#                          SURVIVES stamped and REVERTS cleared, exactly like
#                          them. It is excluded for SCOPING reasons, not for
#                          want of a guard: (a) its skip is logged by
#                          `Content.TagRegistry.skip_pulled/2`, not by Bootstrap,
#                          so counting it reds the ROSTER DRIFT tripwire below
#                          at 35-against-34 on a healthy target (PDS-D129);
#                          (b) its five-key map reverts only FOUR of the eight
#                          guarded columns — `owner_scoped`, `cors_origins`,
#                          `desk_groups` and `list_preview` are absent from its
#                          attrs and `cast/3` never touches them — so leg B's
#                          "did EVERY ONE of the eight move" (PDS-D130) would
#                          hang red on the other four; (c)
#                          `SchemaBootstrap.init/1` hardcodes dataset
#                          "production" (PDS-D145), so its writer does not run
#                          at all when SOURCE_DS is not production.
#    1  `metric`           declared by no local plugin, so Bootstrap's
#                          Registry.all() walk never visits it. SURVIVES FOREVER
#                          on both legs.
#
# A table-wide sentinel therefore hangs leg B red — forever on `metric`, and on
# the four columns TagRegistry never writes for `tag` — and reds the ROSTER
# DRIFT tripwire at 35-against-34. On `metric` the transcript would also show a
# digest that moved with the stamp present, which reads exactly like "the guard
# failed". Scope IS the fix, not a detail of it.
#
# There is NO SQL discriminator for "plugin-declared": `schema_definitions` has
# 23 columns and none records a source (`dataset_id IS NULL` is an artefact of
# hand-insertion, not a marker). The exclusion list is a HAND-MAINTAINED roster,
# which is exactly why the sentinel UPDATE's RETURNING count is asserted against
# the SKIP count in the target's own server.log below (PDS-D129). That
# cross-check is the only thing that turns a future guerrilla-only orphan, or a
# third core writer, from a silent vacuous green into a loud red.
#
# ── ONE EDIT SITE, NOT TWO (PDS-D129) ────────────────────────────────────────
#
# The roster used to live here as a typed-in `NOT IN ('tag','metric')` AND again
# as prose in scripts/pds-schema-row-census.md, and a third time in step 6's
# scope banner. Three copies of a hand-maintained list is the drift shape the
# census file was written to warn about, reproduced by the pair that wrote it.
#
# Now the census declares it once, machine-readably, and this harness DERIVES:
#
#   scripts/pds-schema-row-census.md   `PDS_SENTINEL_EXCLUSION = tag metric`
#
# The literal below is a FALLBACK for the one case where that file is not
# readable, never a second authority. When both are readable and they disagree,
# step 6 FAILS before the sentinel is written — sentinelling a set nobody
# declared is exactly the vacuous green this rung exists to prevent. When the
# census is unreadable the run says so and proceeds on the fallback, UNCHECKED.
# Same shape as step 2's @e3_dataset_keyed derivation.
SENTINEL_EXCLUSION_FALLBACK="tag metric"
SENTINEL_EXCLUSION_SOURCE_REL="scripts/pds-schema-row-census.md"
# The resolved roster, space separated. Seeded with the fallback so every reader
# has a defined value; sentinel_roster_resolve below replaces it from the census
# (or leaves it, loudly) before step 6 touches a row.
SENTINEL_EXCLUSION="$SENTINEL_EXCLUSION_FALLBACK"
# The census's answer, set only when it DISAGREES with the fallback, so the fail
# message can name both sides. Defined up here because `set -u` is on.
SENTINEL_ROSTER_DRIFT=""

# Print the space-separated roster declared by the census, or nothing and a
# non-zero exit when the file is unreadable or the declaration does not parse.
# An unparseable source must read as "NOT derived", never as "derived empty":
# an empty derivation would mismatch the fallback and red a healthy run for a
# reason that has nothing to do with the census's contents.
#
# Takes the file to read as $1 so the selftest can point it at a fixture — a
# derivation that can only ever read the real file cannot be given a negative
# control, and a detector with no negative control is a claim, not a check.
sentinel_exclusion_derive() {
  local src="${1:-$REPO_ROOT/$SENTINEL_EXCLUSION_SOURCE_REL}" out
  [ -r "$src" ] || return 1
  out="$(sed -n 's/^PDS_SENTINEL_EXCLUSION[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$src" \
          | sed -n '1p' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  [ -n "$out" ] || return 1
  # A name is interpolated into a SQL string literal below. Anything that could
  # close that literal is REFUSED, not escaped: the roster is a handful of
  # lowercase schema names and a surprise there is a defect, not a quoting job.
  case "$out" in
    *"'"*|*\\*) return 1 ;;
  esac
  printf '%s' "$out"
}

# The roster as a SQL IN-list: `tag metric` -> `'tag','metric'`.
sentinel_exclusion_sql_list() {
  local n out=""
  for n in $SENTINEL_EXCLUSION; do
    [ -n "$out" ] && out="$out,"
    out="$out'$n'"
  done
  printf '%s' "$out"
}

# Resolve SENTINEL_EXCLUSION from the census. Exit 1 (having printed nothing)
# when the census and the fallback DISAGREE — the caller turns that into a
# `fail`, before any row is written.
sentinel_roster_resolve() {
  local derived
  if ! derived="$(sentinel_exclusion_derive)"; then
    SENTINEL_EXCLUSION="$SENTINEL_EXCLUSION_FALLBACK"
    info "sentinel roster NOT derived this run ($SENTINEL_EXCLUSION_SOURCE_REL unreadable, or its PDS_SENTINEL_EXCLUSION line did not parse) — the exclusion below is named from the in-script fallback ('$SENTINEL_EXCLUSION_FALLBACK'), UNCHECKED against the census"
    return 0
  fi
  if [ "$derived" != "$SENTINEL_EXCLUSION_FALLBACK" ]; then
    SENTINEL_ROSTER_DRIFT="$derived"
    return 1
  fi
  SENTINEL_EXCLUSION="$derived"
  info "sentinel roster DERIVED this run from $SENTINEL_EXCLUSION_SOURCE_REL (PDS_SENTINEL_EXCLUSION = '$derived') and it MATCHES the in-script fallback"
  return 0
}

# ── THE THIRD SCOPING TERM: dataset (PDS_SOURCE_DATASET MUST STAY UNSET) ─────
#
# `sentinel_scope_sql` below joins THREE terms and until now only two of them
# had anything watching. `workspace_id` is CAPTURED by stamp_before rather than
# assumed (PDS-D132); the `name NOT IN (...)` roster is DERIVED from the census
# above and reds when the two copies disagree (PDS-D129). The third term is
# `$SOURCE_DS`, i.e. `${PDS_SOURCE_DATASET:-production}` resolved at the top of
# this file, and nothing checked it at all.
#
# It cannot be anything but `production` and leave step 6 interpretable, and the
# reason lives in the application, not here:
#
#   api/lib/barkpark/plugins/bootstrap.ex  `register_schema/3`:
#       dataset = schema.dataset || "production"
#     Every plugin-declared row lands in `production` unless its own plugin
#     names something else -- and none does. The string-literal declarations in
#     api/lib/barkpark/plugins/ all read `dataset: "production"`, and the one
#     non-literal (`tickets.ex`, `dataset: dataset`) defaults from
#     `@dataset_default "production"`. The roster selftest re-derives BOTH of
#     those rather than trusting this comment.
#
#   api/lib/barkpark/schema_bootstrap.ex   `init/1` calls
#       Barkpark.Content.TagRegistry.register!("production")
#     with the dataset as a LITERAL (PDS-D145), so the `tag` row's other writer
#     does not run at all off production -- which is also why (c) in the `tag`
#     exclusion note far above is worded the way it is.
#
# So exporting PDS_SOURCE_DATASET to anything else scopes the sentinel to a
# dataset that holds none of the rows, and the UPDATE matches ZERO. There IS
# already a `fail` for that further down ("the sentinel UPDATE matched ZERO
# rows"), and it is true -- but it diagnoses the symptom. It says there is
# nothing for the boot-time upsert to clobber; it does not say an environment
# variable moved the scope off the only dataset the rows have ever lived in.
# The refusal below is that diagnosis, taken BEFORE a row is written, in the
# same place and for the same reason as the roster-drift refusal.
#
# QUIET on the real tree: PDS_SOURCE_DATASET unset resolves to `production`,
# the predicate returns 0 and nothing is printed.
SENTINEL_DATASET_REQUIRED="production"

# dataset -> exit 0, no output, when it is the dataset the rows live in; exit 1
# and the offending value otherwise. Takes the dataset as $1 instead of reading
# $SOURCE_DS so the selftest can drive BOTH directions without exporting
# anything into the process that is doing the measuring.
sentinel_dataset_refusal() {
  [ "${1-}" = "$SENTINEL_DATASET_REQUIRED" ] && return 0
  printf 'PDS_SOURCE_DATASET=%s' "${1-}"
  return 1
}

sentinel_scope_sql() { # workspace_id -> the WHERE clause selecting exactly those 34
  printf "workspace_id = '%s' AND dataset = '%s' AND name NOT IN (%s)" \
    "$1" "$SOURCE_DS" "$(sentinel_exclusion_sql_list)"
}

scoped_column_digests() { # workspace_id -> ONE tab-separated line, one md5 per
                          # column, in GUARDED_COLUMNS order
  local ws="$1" col sel=""
  for col in $GUARDED_COLUMNS; do
    [ -n "$sel" ] && sel="$sel || E'\t' || "
    sel="${sel}md5(coalesce(string_agg(coalesce(${col}::text,'<null>'), E'\n' ORDER BY dataset, name),'<no-rows>'))"
  done
  tgt_psql "SELECT $sel FROM schema_definitions WHERE $(sentinel_scope_sql "$ws")" | head -1
}

columns_where() { # <same|diff> before_line after_line -> the column names whose
                  # per-column digest is identical / differs, space separated
  local want="$1" b="$2" a="$3" i=1 col out="" bv av
  for col in $GUARDED_COLUMNS; do
    bv="$(printf '%s' "$b" | cut -f "$i")"
    av="$(printf '%s' "$a" | cut -f "$i")"
    if { [ "$want" = "same" ] && [ "$bv" = "$av" ]; } ||
       { [ "$want" = "diff" ] && [ "$bv" != "$av" ]; }; then
      out="$out $col"
    fi
    i=$((i + 1))
  done
  printf '%s' "${out# }"
}

columns_intersect() { # "<names>" "<names>" -> the names present in BOTH, in
                      # GUARDED_COLUMNS order. Used to say out loud which
                      # columns an assertion rests on rather than inheriting the
                      # eight from a literal.
  local col out=""
  for col in $GUARDED_COLUMNS; do
    case " $1 " in *" $col "*) : ;; *) continue ;; esac
    case " $2 " in *" $col "*) out="$out $col" ;; esac
  done
  printf '%s' "${out# }"
}

# ── THE THIRD DIGEST STATE: PRE-SENTINEL, PER ROW, PER COLUMN (PDS-D742) ─────
#
# `scoped_column_digests` answers "is this column's aggregate what it was". That
# is enough for leg A and for leg B ONCE THE DRIFT EXISTS, and it says nothing
# about whether the drift exists at all. The sentinel writes the CONSTANT
# `visibility = 'private'`, and `visibility` is
# `validate_inclusion(:visibility, ~w(public private))`
# (api/lib/barkpark/content/schema_definition.ex) — a binary enum with no third
# legal value — so on every row that is ALREADY private that write is a literal
# no-op. Measured on a live scratch target in wave 9: 31 of the 34 in-scope rows
# were already private, so leg B's visibility control rested on THREE rows. On
# an all-private roster it would rest on NONE, and the rung would still go green
# off the other seven columns while one of its eight guarded controls proved
# nothing — PDS-D130's partial clobber arriving through the back door.
#
# THE FIX IS A MEASUREMENT, NOT A STRONGER SENTINEL. Drifting `visibility` the
# other way — flipping the 31 private rows to 'public' to buy an n=34 control —
# would INVERT the exposure the sentinel comment below relies on ('private' 404s
# anonymous document reads, contained ONLY because step 6 is terminal among
# target-reading rungs), so it is refused. Instead the run captures a THIRD
# state taken BEFORE the sentinel UPDATE, at per-ROW granularity, and diffs
# pre-vs-sentinelled: the set of columns leg B must see revert becomes the set
# the sentinel is MEASURED to have moved, each column's moved-row count is
# printed, and a guarded column the sentinel moved on ZERO rows REDS the rung by
# name instead of riding the other seven's green.
scoped_row_column_fingerprints() { # workspace_id -> one line per in-scope row:
                                   # `dataset|name` TAB md5(col) … in
                                   # GUARDED_COLUMNS order. Per-ROW on purpose:
                                   # a per-column aggregate cannot say HOW MANY
                                   # rows a write actually moved, and "how many"
                                   # is the whole question here.
  local ws="$1" col sel=""
  for col in $GUARDED_COLUMNS; do
    sel="$sel || E'\t' || md5(coalesce(${col}::text,'<null>'))"
  done
  tgt_psql "SELECT dataset || '|' || name$sel FROM schema_definitions WHERE $(sentinel_scope_sql "$ws") ORDER BY dataset, name"
}

moved_column_counts() { # before_block after_block -> `<col>=<n>` per guarded
                        # column, space separated, in GUARDED_COLUMNS order.
                        #
                        # rc 1 = the two blocks do not describe the SAME row set.
                        # That is a scope that shifted under the run, not a
                        # movement to count; folding it into the counts would
                        # manufacture coverage for a column nothing was written
                        # to, which is precisely the silent green this function
                        # exists to refuse. So it is a REFUSAL by exit code, not
                        # a number the caller cannot tell apart from a real one.
  local b="$1" a="$2"
  { printf '%s\n' "$b"; printf '%s\n' '__PDS_SIDE_BREAK__'; printf '%s\n' "$a"; } |
  awk -F'\t' -v cols="$GUARDED_COLUMNS" '
    BEGIN { n = split(cols, name, " "); side = 0; nb = 0; na = 0 }
    $0 == "__PDS_SIDE_BREAK__" { side = 1; next }
    $0 == "" { next }
    {
      if (side == 0) { nb++; seen_b[$1] = 1; for (i = 2; i <= n + 1; i++) before[$1, i] = $i }
      else           { na++; seen_a[$1] = 1; for (i = 2; i <= n + 1; i++) after[$1, i]  = $i }
    }
    END {
      if (nb == 0 || nb != na) { exit 1 }
      for (k in seen_b) { if (!(k in seen_a)) { exit 1 } }
      for (k in seen_b)
        for (i = 2; i <= n + 1; i++)
          if (before[k, i] != after[k, i]) moved[i]++
      out = ""
      for (i = 2; i <= n + 1; i++) out = out (out == "" ? "" : " ") name[i - 1] "=" (moved[i] + 0)
      print out
    }'
}

moved_columns_where() { # <zero|nonzero> "<col>=<n> …" -> the column names whose
                        # measured moved-row count is / is not zero, in the
                        # order the vector carries them.
  local want="$1" tok out=""
  for tok in $2; do
    case "$want:${tok##*=}" in
      zero:0)    out="$out ${tok%%=*}" ;;
      zero:*)    : ;;
      nonzero:0) : ;;
      *)         out="$out ${tok%%=*}" ;;
    esac
  done
  printf '%s' "${out# }"
}

reboot_target() { # 0 = the target answered HTTP again
  local i code
  "$TARGET_TREE/bin/barkpark" stop >/dev/null 2>&1 || true
  "$TARGET_TREE/bin/barkpark" up >"$BARKPARK_HOME/reboot.log" 2>&1 || return 1
  i=0
  while [ "$i" -lt 90 ]; do
    code="$(http_code "$(bp_curl_code -sS -o /dev/null --max-time 10 "$TARGET_BASE/api/schemas" 2>/dev/null || true)")"
    [ "$code" = "200" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

step_6() {
  head_step 6 "CONVERGENCE — the imported state survives a REBOOT (PDS-D23/PDS-D62/PDS-D65)"

  say "  The Bootstrap clobber fires only on BOOT. A convergence proof that does not"
  say "  restart the target measures nothing: it re-reads rows from a process that"
  say "  never had the chance to overwrite them. Reboot here is \`bin/barkpark stop\`"
  say "  then \`up\` in the SAME BARKPARK_HOME — there is NO restart verb, and"
  say "  \`teardown\` would stop Postgres and take the data with it."
  say ""
  say "  SCOPE: this is CONTENT-AND-PRESENCE convergence of the imported rows — not"
  say "  byte-identity of two independently produced tar files. On a WORKSPACE-grain"
  say "  pull it would additionally be measuring identical plugin declarations rather"
  say "  than a guard; step 1 asserts the grain so that ambiguity cannot arise here."
  say ""

  if ! load_target; then
    abort 6 "env:scratch-target-not-booted" \
      "nothing to reboot. FIX: $(target_hint)"
    return 0
  fi
  if [ -z "${PULL_BUNDLE:-}" ]; then
    abort 6 "step:1" \
      "no pull ran this run. Convergence is a property OF an import; measuring it against a target populated by some earlier run proves nothing about this transcript. Re-run --only 1,6."
    return 0
  fi
  if [ -z "$TARGET_TREE" ]; then
    abort 6 "env:scratch-tree-unknown" \
      "scratch.env carries no PDS_SCRATCH_TREE, so the target's own bin/barkpark cannot be located and the reboot cannot be performed honestly."
    return 0
  fi

  # ── read the stamp, AND the workspace it lives on (PDS-D132) ──────────────
  #
  # This read used to be `… WHERE settings ? 'pull_provenance' LIMIT 1` with no
  # ORDER BY and no id, while the guard-off UPDATE below used the SAME predicate
  # with NO LIMIT: the read sampled one arbitrary stamped workspace and the
  # write cleared every one of them. Benign at exactly one stamped workspace,
  # but the sentinel cannot reuse a resolution that does not exist — so the id
  # is captured under a total order and fed to BOTH writes.
  local stamp_row stamp_ws stamp_before digest_before digest_after
  stamp_row="$(tgt_psql "SELECT id::text, coalesce(settings->'pull_provenance'->>'$SOURCE_DS','<none>') FROM workspaces WHERE settings ? 'pull_provenance' ORDER BY id LIMIT 1" | head -1 || true)"
  stamp_ws="$(printf '%s' "$stamp_row" | cut -f1)"
  stamp_before="$(printf '%s' "$stamp_row" | cut -f2)"
  info "stamped slot    workspace ${stamp_ws:-<none>}"
  info "                pull_provenance[$SOURCE_DS] = ${stamp_before:-<none>}"

  # ── the stamp check HOISTS above digest_before (PDS-D133) ─────────────────
  #
  # It used to sit after the digest. Sentinelling a slot that turns out to be
  # unstamped would leave a deliberately corrupted target standing with nothing
  # to revert it, so validity is established before anything is written.
  if [ -z "$stamp_ws" ] || [ "${stamp_before:-<none>}" = "<none>" ]; then
    fail 6 "the import left NO pull_provenance stamp for dataset '$SOURCE_DS'. The guard is stamp-keyed, so an unstamped target is one the boot-time upsert is free to clobber — convergence below would be luck, not a guard. Nothing was written to the target."
    return 0
  fi

  # ── THE SENTINEL (PDS-D128..D133) ─────────────────────────────────────────
  #
  # WHY THIS EXISTS AT ALL. Under step 0b's sha-parity precondition the target's
  # plugin declarations are byte-identical to what is stored, and at
  # stamp-present `bootstrap.ex` SKIPS the upsert entirely. So without a
  # sentinel this rung measures NOTHING IN EITHER DIRECTION: leg B cannot move
  # the digest, and leg A ("the eight columns did not change") would hold with
  # the guard DELETED from the codebase. Writing a deliberate DRIFT into the 34
  # first turns leg A from "nothing happened" into "the guard PRESERVED a
  # drifted row across a reboot" — the hazard the guard actually exists for.
  #
  # TYPE SAFETY, and it is not cosmetic. `fields` and `desk_groups` are POSTGRES
  # `jsonb[]` (`udt_name` `_jsonb`); Ecto's `{:array,:map}` is a different view
  # of the same column. `fields || '[{"k":"v"}]'::jsonb` resolves as
  # `array_append` and appends ONE element whose value is a JSON ARRAY. The
  # UPDATE succeeds silently — `UPDATE 34`, no error — and the break surfaces
  # only on the NEXT read, as an ArgumentError inside Repo.all -> /api/schemas
  # 500 -> reboot_target polls for 90 s -> the rung ABORTS looking like an
  # environment fault. Two-stage silence. Append a bare OBJECT; `coalesce` the
  # nullable ones. `list_preview` is plain `jsonb`, so `||` there is an object
  # MERGE and is correct as written.
  #
  # `visibility` is `validate_inclusion ~w(public private)`, so 'private' is the
  # only legal alternate. It does NOT hide rows from /api/schemas
  # (`Schema.list_schemas` has no visibility predicate) but it DOES 404
  # anonymous document reads. THAT IS CONTAINED ONLY BECAUSE STEP 6 IS TERMINAL
  # AMONG TARGET-READING RUNGS (PDS-D101/PDS-D116) — steps 2 and 5 run BEFORE it and
  # `--all`'s own order is the only safe one. Re-ordering this rung earlier
  # silently poisons every later read; do not.
  #
  # `dataset` and `name` are KEYS in the digest and are NEVER sentinelled.
  local mark sentinel_id sentinel_rows
  sentinel_id="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9._-' '-')"
  mark="PDS-SENTINEL-$sentinel_id"
  say ""
  # THE ROSTER, BEFORE ANYTHING IS WRITTEN. Resolving it here rather than at
  # source-time means a census/harness disagreement reds the rung with the
  # target untouched, instead of after a sentinel has already gone into a set
  # nobody declared.
  # THE DATASET TERM, BEFORE ANYTHING IS WRITTEN. Same placement and same
  # reason as the roster check immediately below: a scope that selects none of
  # the rows must red by NAME here, not as a bare zero-rows count after the
  # fact.
  if ! sentinel_dataset_refusal "$SOURCE_DS"; then
    fail 6 "SENTINEL SCOPE OFF DATASET: this run resolved dataset '$SOURCE_DS' from PDS_SOURCE_DATASET, but every row this rung is about lives in '$SENTINEL_DATASET_REQUIRED'. \`Plugins.Bootstrap.register_schema/3\` writes plugin rows to \`schema.dataset || \"production\"\` and no plugin names anything else, and \`SchemaBootstrap.init/1\` passes the dataset to TagRegistry as the literal \"production\" (PDS-D145). The sentinel UPDATE would therefore match ZERO rows and both legs would be vacuous -- the zero-rows fail further down would report that truthfully and diagnose the wrong thing. NOTHING was written to the target. FIX: leave PDS_SOURCE_DATASET unset; it has no supported non-production value."
    return 0
  fi
  if ! sentinel_roster_resolve; then
    fail 6 "SENTINEL ROSTER DRIFT: $SENTINEL_EXCLUSION_SOURCE_REL declares PDS_SENTINEL_EXCLUSION = '$SENTINEL_ROSTER_DRIFT', this harness's fallback names '$SENTINEL_EXCLUSION_FALLBACK'. The two are the same roster and only one of them can be right, so the sentinel would scope to a set nobody declared and both legs would be uninterpretable (PDS-D129). NOTHING was written to the target. FIX: make them agree — the census is the edit site, the fallback follows it."
    return 0
  fi
  info "SENTINEL        writing deliberate drift into all eight guarded columns"
  info "                scope: workspace $stamp_ws · dataset $SOURCE_DS · name NOT IN ($(sentinel_exclusion_sql_list))"
  # THE PRE-SENTINEL STATE (PDS-D742), taken BEFORE the UPDATE and per row, so
  # the run can MEASURE which guarded columns the sentinel moved rather than
  # assume all eight moved because all eight appear in the SET list.
  local rows_pre_sentinel
  rows_pre_sentinel="$(scoped_row_column_fingerprints "$stamp_ws")"
  if [ -z "$rows_pre_sentinel" ]; then
    fail 6 "could not read the PRE-SENTINEL per-row fingerprints for workspace $stamp_ws / dataset '$SOURCE_DS' — without the third digest state this run cannot tell a guarded column the sentinel MOVED from one it wrote a no-op into, so leg B's per-column claim would rest on an assumption (PDS-D742). Nothing was written to the target."
    return 0
  fi
  sentinel_rows="$(tgt_psql "WITH upd AS (UPDATE schema_definitions SET title = '$mark', icon = '$mark', visibility = 'private', owner_scoped = NOT coalesce(owner_scoped, false), fields = coalesce(fields, ARRAY[]::jsonb[]) || '{\"__pds_sentinel\":\"$sentinel_id\"}'::jsonb, cors_origins = coalesce(cors_origins, ARRAY[]::text[]) || ARRAY['$mark'], desk_groups = coalesce(desk_groups, ARRAY[]::jsonb[]) || '{\"__pds_sentinel\":\"$sentinel_id\"}'::jsonb, list_preview = coalesce(list_preview, '{}'::jsonb) || '{\"__pds_sentinel\":\"$sentinel_id\"}'::jsonb WHERE $(sentinel_scope_sql "$stamp_ws") RETURNING id) SELECT count(*) FROM upd" | head -1 | tr -d '[:space:]' || true)"
  info "RETURNING       ${sentinel_rows:-<nothing>} rows sentinelled"
  case "${sentinel_rows:-}" in
    ''|*[!0-9]*)
      fail 6 "the sentinel UPDATE returned no countable row count ('${sentinel_rows:-<nothing>}') — without a drifted row this rung measures nothing in either direction (at sha parity the boot-time upsert SKIPS, so leg A would hold with the guard deleted). Refusing to report a convergence that was never at risk."
      return 0 ;;
  esac
  if [ "$sentinel_rows" -eq 0 ]; then
    fail 6 "the sentinel UPDATE matched ZERO rows in workspace $stamp_ws / dataset '$SOURCE_DS'. There is nothing for the boot-time upsert to clobber, so both legs below would be vacuous."
    return 0
  fi

  # ── WHAT THE SENTINEL ACTUALLY MOVED, PER COLUMN (PDS-D742) ───────────────
  #
  # Third state minus second state. Printed, then ASSERTED: a guarded column the
  # sentinel moved on zero rows is a control that could not fire, and it reds
  # here rather than riding the other columns' green all the way to `pass 6`.
  local rows_sentinelled sentinel_moved sentinel_dead sentinel_live
  rows_sentinelled="$(scoped_row_column_fingerprints "$stamp_ws")"
  if ! sentinel_moved="$(moved_column_counts "$rows_pre_sentinel" "$rows_sentinelled")"; then
    fail 6 "the PRE-SENTINEL and SENTINELLED reads do not describe the same row set in workspace $stamp_ws / dataset '$SOURCE_DS' — the sentinel scope moved under the run, so a per-column moved-row count taken across them would be counting rows that appeared or vanished rather than a write (PDS-D742). NOTE: the target is SENTINELLED and was not reverted."
    return 0
  fi
  info "sentinel moved  $sentinel_moved"
  info "                ^ rows the sentinel GENUINELY changed, per guarded column, out of $sentinel_rows in scope. A column at 0 is a control that could not fire."
  sentinel_dead="$(moved_columns_where zero "$sentinel_moved")"
  sentinel_live="$(moved_columns_where nonzero "$sentinel_moved")"
  if [ -n "$sentinel_dead" ]; then
    fail 6 "THIS CONTROL COULD NOT FIRE: the sentinel UPDATE changed ZERO of the $sentinel_rows in-scope rows in these guarded columns: $sentinel_dead (measured pre-sentinel against sentinelled: $sentinel_moved). The written value is a no-op on this target's roster, not a drift — \`visibility\` takes only public|private, so an all-private slot makes that column's write a no-op on every row. Leg B below would then 'prove' reversion on a column nothing drifted and the rung would go green off the remaining columns: the PDS-D130 partial clobber arriving through the back door (PDS-D742). NOTE: the target is SENTINELLED and was not reverted."
    return 0
  fi

  # digest_before now reflects the SENTINELLED state — that is the whole point.
  digest_before="$(tgt_psql "$GUARDED_DIGEST_SQL" | head -1 || true)"
  local cols_before
  cols_before="$(scoped_column_digests "$stamp_ws")"
  if [ -z "$digest_before" ] || [ -z "$cols_before" ]; then
    fail 6 "could not digest schema_definitions on the target — the eight guarded columns cannot be compared across a reboot, so a 'converged' verdict would be unmeasured"
    return 0
  fi
  info "before reboot   guarded-column digest $digest_before   [WHOLE TABLE]"
  info "                ^ WHOLE-TABLE digest: GUARDED_DIGEST_SQL carries no WHERE, so its \`rows=\` counts EVERY schema_definitions row on the target, including the \`tag\` and \`metric\` rows the sentinel scope deliberately excludes. It is a headline, not the quantity either leg measures — that is the SCOPED per-column vector over $sentinel_rows rows, printed above and below (PDS-D743)."

  # The SKIP count is read from the log the BOOT BELOW appends, so the offset is
  # taken now. `bin/barkpark` APPENDS to $BARKPARK_HOME/server.log across
  # reboots — counting the whole file would sum every boot this root ever had.
  local log_off
  log_off="$(wc -c <"$BARKPARK_HOME/server.log" 2>/dev/null | tr -d ' ' || printf 0)"
  # A failed REDIRECTION leaves the pipeline's exit status at `tr`'s (0), so the
  # `|| printf 0` never fires and `log_off` comes back EMPTY, which `$((…))`
  # then reads as 0 — silently restoring the whole-file count this offset exists
  # to prevent. Normalise explicitly rather than relying on that arithmetic.
  case "${log_off:-}" in ''|*[!0-9]*) log_off=0 ;; esac

  if ! reboot_target; then
    fail 6 "the target did not come back after \`bin/barkpark stop\` + \`up\` (see $BARKPARK_HOME/reboot.log) — convergence cannot be measured across a boot that did not happen. NOTE: the target is SENTINELLED and was not reverted."
    return 0
  fi

  # ── THE TRIPWIRE ON THE HAND-MAINTAINED ROSTER (PDS-D129) ─────────────────
  #
  # The boot just logged one WARNING per row the guard skipped. That count is
  # Bootstrap's own opinion of how many plugin-declared rows live in this slot,
  # derived from `Registry.all()` rather than from this script's exclusion list.
  # If a future guerrilla-only orphan joins the table, or a third core writer
  # appears, the two numbers diverge and this rung goes LOUD instead of quietly
  # measuring a scope that no longer means what it says.
  # THE GREP IS SCOPED TO BOOTSTRAP, AND THAT SCOPING IS LOAD-BEARING (PDS-D125).
  #
  # There are now TWO writers that log the phrase "skipping the content update":
  # `Plugins.Bootstrap.skip_pulled/3` (one line per plugin-declared row it
  # skipped — the number this roster is reconciled against) and, since the
  # TagRegistry guard landed, `Content.TagRegistry.skip_pulled/2` (exactly the
  # `tag` row, which the sentinel scope DELIBERATELY EXCLUDES). An unscoped
  # count returns 35 against 34 sentinelled rows and reds ROSTER DRIFT on a
  # perfectly healthy target — a false red caused by the sibling fix in this
  # very wave. The count must therefore come from Bootstrap's walk alone.
  local skip_count register_count tag_skip_count
  skip_count="$(tail -c "+$((log_off + 1))" "$BARKPARK_HOME/server.log" 2>/dev/null | grep -cE 'Plugins\.Bootstrap: schema .*skipping the content update' || true)"
  register_count="$(tail -c "+$((log_off + 1))" "$BARKPARK_HOME/server.log" 2>/dev/null | grep -c 'Plugins.Bootstrap: registered schema' || true)"
  tag_skip_count="$(tail -c "+$((log_off + 1))" "$BARKPARK_HOME/server.log" 2>/dev/null | grep -cE 'TagRegistry: core .*skipping the content update' || true)"
  info "boot log        $skip_count Bootstrap SKIP (guard fired) · $register_count REGISTER, this boot only"
  info "                $tag_skip_count TagRegistry SKIP (the core \`tag\` row, outside the sentinel scope)"
  info "                REGISTER is informational: it is Logger.info and can be filtered out by log level, so only the Bootstrap SKIP count is asserted."
  info "                The TagRegistry count is reported, NOT asserted: \`SchemaBootstrap.init/1\` hardcodes dataset \"production\", so it is legitimately 1 when SOURCE_DS is production and 0 otherwise."

  # Leg A's own reading is taken BEFORE the count assertions so that a red can
  # say what actually happened to the columns rather than only that two numbers
  # disagreed.
  digest_after="$(tgt_psql "$GUARDED_DIGEST_SQL" | head -1 || true)"
  local cols_after leg_a_changed survivors
  cols_after="$(scoped_column_digests "$stamp_ws")"
  leg_a_changed="$(columns_where diff "$cols_before" "$cols_after")"
  info "after reboot    guarded-column digest ${digest_after:-<unreadable>}   [WHOLE TABLE]"
  info "leg A columns   changed across the STAMPED reboot: ${leg_a_changed:-<none — every guarded column held>}   (measured, scoped to the $sentinel_rows sentinelled rows)"

  # ZERO SKIPs is a different fact from a MISCOUNT, and conflating them puts a
  # roster-drift diagnosis on a boot where the guard simply never ran.
  #
  # UNREADABLE is a THIRD fact, and it must not borrow either one's message. The
  # capture is `grep -c … || true`, which is the SAFE spelling — grep -c prints
  # its 0 and `|| true` only swallows the exit, so one integer arrives. That is
  # true today and is a property of the capture, not of this comparison; the
  # guard is what keeps it true if the capture is ever rewritten to the `|| echo 0`
  # form that manufactured $'0\n0' three steps up this file.
  if ! int_ok "${skip_count:-}"; then
    fail 6 "LEG A — the Bootstrap SKIP count read as '${skip_count:-<empty>}', not an integer. Whether the guard fired is UNKNOWN, and unknown is not zero: reporting 'the guard did not fire' off an unreadable count would name a defect this run did not observe."
    return 0
  fi
  if [ "$skip_count" -eq 0 ]; then
    fail 6 "LEG A — THE GUARD DID NOT FIRE: $sentinel_rows rows were sentinelled and stamped, yet the boot logged ZERO Bootstrap guard SKIPs and $register_count plugin REGISTERs. The boot-time upsert walked straight through a stamped slot. Guarded columns that moved on those rows: ${leg_a_changed:-<none, which would be stranger still>}. This is what a broken or absent provenance guard looks like from outside the engine."
    return 0
  fi
  if [ "${skip_count:-0}" != "$sentinel_rows" ]; then
    fail 6 "ROSTER DRIFT: the sentinel wrote $sentinel_rows rows but the boot logged ${skip_count:-0} Bootstrap guard SKIPs (the core \`tag\` row's own TagRegistry skip, ${tag_skip_count:-0} this boot, is excluded from both sides on purpose). Those two numbers are derived independently — the sentinel from the roster declared in $SENTINEL_EXCLUSION_SOURCE_REL ($(sentinel_exclusion_sql_list)), the SKIPs from Bootstrap's own Registry.all() walk — and no SQL discriminator for plugin-declared rows exists to reconcile them (PDS-D129). A mismatch means the scope below no longer selects the rows the guard is about, so neither leg can be interpreted."
    return 0
  fi

  if [ "$digest_before" != "$digest_after" ]; then
    fail 6 "the eight guarded columns CHANGED across the reboot ($digest_before -> ${digest_after:-unreadable}) — the boot-time plugin upsert clobbered pulled rows despite the provenance stamp"
    return 0
  fi
  if [ -n "$leg_a_changed" ]; then
    fail 6 "LEG A: the guard did NOT preserve the drifted rows — these guarded columns moved across the stamped reboot on the $sentinel_rows sentinelled rows: $leg_a_changed"
    return 0
  fi

  # Leg A's positive statement, not merely "nothing moved": the deliberate drift
  # is STILL THERE, row for row, after a boot that had every opportunity to
  # revert it. `owner_scoped` is a per-row flip and so has no absolute value to
  # assert — it is covered by the per-column digest above.
  survivors="$(tgt_psql "SELECT count(*) FROM schema_definitions WHERE $(sentinel_scope_sql "$stamp_ws") AND title = '$mark' AND icon = '$mark' AND visibility = 'private' AND '$mark' = ANY(cors_origins) AND fields::text LIKE '%$sentinel_id%' AND desk_groups::text LIKE '%$sentinel_id%' AND list_preview::text LIKE '%$sentinel_id%'" | head -1 | tr -d '[:space:]' || true)"
  info "sentinel intact ${survivors:-0} of $sentinel_rows rows still carry the drift"
  if [ "${survivors:-0}" != "$sentinel_rows" ]; then
    fail 6 "LEG A: only ${survivors:-0} of $sentinel_rows sentinelled rows still carry the deliberate drift after the stamped reboot — the guard is leaking rows even though the aggregate digest happened to hold."
    return 0
  fi

  # ── the guard's own control, sequenced AFTER the convergence it explains ──
  #
  # A convergence green is only interesting if the same box CLOBBERS when the
  # stamp is gone. The off-switch has no CLI or HTTP surface (tenancy.ex says so
  # verbatim), so this is direct SQL — and the RETURNING value is ASSERTED,
  # because jsonb_set is a proven silent NO-OP when the parent path is absent.
  if [ "${PDS_STEP6_GUARD_DEMO:-1}" != "1" ]; then
    pass 6 "content-and-presence convergence across a real reboot: $sentinel_rows rows were deliberately DRIFTED with the MEASURED per-column coverage [$sentinel_moved] (every guarded column moved on at least one row; a zero would have redded this rung by name, PDS-D742) and the guard preserved every one of them — leg A changed columns: ${leg_a_changed:-<none>}; $survivors/$sentinel_rows sentinels intact; $skip_count SKIPs logged; whole-table digest $digest_before, unchanged — and the pull_provenance stamp survived. NOTE: the guard-off control was DISABLED (PDS_STEP6_GUARD_DEMO=0), so nothing here proves this box would clobber without the stamp — the green is weaker for it, and the target is left SENTINELLED."
    return 0
  fi

  say ""
  info "GUARD-OFF CONTROL — clearing the stamp by SQL, then booting again:"
  # Scoped to the workspace the read above resolved (PDS-D132). The old form
  # cleared EVERY stamped workspace while the read sampled one arbitrary one.
  local ret digest_clobbered
  ret="$(tgt_psql "UPDATE workspaces SET settings = jsonb_set(settings,'{pull_provenance,$SOURCE_DS}','{}'::jsonb) WHERE id = '$stamp_ws' RETURNING settings->'pull_provenance'" | head -1 || true)"
  info "RETURNING       ${ret:-<nothing>}"
  case "${ret:-}" in
    *"\"$SOURCE_DS\": {}"*)
      : ;;
    *)
      fail 6 "the stamp clear did NOT take: RETURNING says '${ret:-<nothing>}'. jsonb_set is a silent no-op when the parent path is absent, which is precisely why this is asserted rather than assumed — the guard-off control cannot be trusted to have run, so the convergence above stays uncontrolled."
      return 0 ;;
  esac

  if ! reboot_target; then
    fail 6 "the target did not come back after the guard-off reboot (see $BARKPARK_HOME/reboot.log)"
    return 0
  fi
  digest_clobbered="$(tgt_psql "$GUARDED_DIGEST_SQL" | head -1 || true)"
  info "after guard-off ${digest_clobbered:-<unreadable>}   [WHOLE TABLE]"
  if [ "$digest_clobbered" = "$digest_before" ]; then
    fail 6 "THE CONTROL DID NOT FIRE: with the provenance stamp cleared, a boot left the eight guarded columns unchanged. Then the converged green above was not measuring a guard — it was measuring a plugin whose declaration happens to match. Uninterpretable either way (PDS-D20)."
    return 0
  fi

  # ── LEG B ASSERTS PER-COLUMN REVERSION (PDS-D130) ─────────────────────────
  #
  # The whole-table digest moving is necessary and NOT sufficient. A clobber
  # that reverted six of the eight and left two alone moves that aggregate just
  # as convincingly, and the control would read as firing cleanly while two
  # columns went unprotected. No partial-coverage path exists inside
  # bootstrap.ex today — schema_definition.ex casts a strict superset of the
  # eight in one Repo.update, pinned by the committed S7 probe — but the
  # per-column assertion costs nothing and is the only shape that stays honest
  # if that cast list ever narrows.
  #
  # AND IT ASSERTS OVER THE COLUMNS IT CAN NAME SUPPORT FOR (PDS-D742). The
  # required set is $sentinel_live — the columns the pre-sentinel diff MEASURED
  # the sentinel to have moved — not the eight names in the GUARDED_COLUMNS
  # literal. On any run that reaches this line the two sets are IDENTICAL,
  # because a zero-coverage column redded the rung terminally above; the
  # intersection therefore removes nothing today. It is here so the assertion
  # names its own support rather than inheriting it from a constant, which is
  # the difference between a control that is measured and one that is assumed.
  local cols_clobbered leg_b_unmoved leg_b_moved survivors_after
  cols_clobbered="$(scoped_column_digests "$stamp_ws")"
  leg_b_moved="$(columns_where diff "$cols_before" "$cols_clobbered")"
  leg_b_unmoved="$(columns_intersect "$(columns_where same "$cols_before" "$cols_clobbered")" "$sentinel_live")"
  info "leg B columns   moved by the GUARD-OFF boot: ${leg_b_moved:-<none>}   (required: $sentinel_live)"
  survivors_after="$(tgt_psql "SELECT count(*) FROM schema_definitions WHERE $(sentinel_scope_sql "$stamp_ws") AND (title = '$mark' OR icon = '$mark' OR '$mark' = ANY(cors_origins) OR fields::text LIKE '%$sentinel_id%' OR desk_groups::text LIKE '%$sentinel_id%' OR list_preview::text LIKE '%$sentinel_id%')" | head -1 | tr -d '[:space:]' || true)"
  info "sentinel wiped  ${survivors_after:-?} of $sentinel_rows rows still carry ANY trace of the drift"
  if [ -n "$leg_b_unmoved" ]; then
    fail 6 "LEG B IS PARTIAL: with the stamp cleared, the boot reverted some guarded columns but left these UNCHANGED on the $sentinel_rows sentinelled rows: $leg_b_unmoved. The aggregate digest moved, which is exactly how a partial clobber hides (PDS-D130) — those columns are not covered by anything this rung can vouch for."
    return 0
  fi
  if [ "${survivors_after:-1}" != "0" ]; then
    fail 6 "LEG B: ${survivors_after} of $sentinel_rows rows still carry a trace of the sentinel after the guard-off boot, so the clobber did not fully revert the drift it is supposed to revert."
    return 0
  fi

  info "NOTE            the target is now CLOBBERED on purpose. Steps 2 and 5 are"
  info "                sequenced BEFORE this control for exactly that reason; a"
  info "                re-pull is required before any further assertion about it."
  pass 6 "content-and-presence convergence across a real reboot, measured against DELIBERATE DRIFT rather than against an untouched target: $sentinel_rows rows (workspace $stamp_ws · dataset $SOURCE_DS · minus the tag/metric non-plugin rows) were sentinelled with the MEASURED per-column coverage [$sentinel_moved] — every guarded column moved on at least one row, and a zero would have redded this rung by name rather than riding the others' green (PDS-D742) — the boot logged exactly $skip_count Bootstrap guard SKIPs to match (plus ${tag_skip_count:-0} TagRegistry skip of the core \`tag\` row, which the scope excludes), and the stamped reboot preserved every column and all $survivors sentinels — leg A changed columns: ${leg_a_changed:-<none>}; whole-table digest $digest_before, unchanged (that headline counts every schema_definitions row, \`tag\` and \`metric\` included; the scoped per-column vectors are the measured quantity, PDS-D743) — AND the control fires per column: with the stamp cleared by asserted SQL, the very next boot moved leg B columns [$leg_b_moved] against the required set [$sentinel_live] and wiped every trace of the drift (whole-table digest ${digest_clobbered}). At sha parity a sentinel-free version of this rung would pass with the guard deleted from the codebase; this one cannot."
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — THE NEGATIVE GUARD (runs today, and passes)
# ═════════════════════════════════════════════════════════════════════════════

step_7() {
  head_step 7 "THE NEGATIVE GUARD — a MERGE import against the SOURCE must be REFUSED"

  say "  SCOPE, exactly (PDS-D73): the :allow_bundle_import gate wraps ONLY the merge"
  say "  branch of the import controller. \`clean\` is the DEFAULT mode and is NOT"
  say "  gated by that flag. So what is proven below is that the source refuses a"
  say "  MERGE import — never the broader claim that guerrilla cannot be written."
  say ""
  say "  Re-derived at RUN time on purpose. This is a blue/green box: a deploy could"
  say "  land between any survey and this run, and the single point of failure is"
  say "  anyone appending BARKPARK_ALLOW_BUNDLE_IMPORT=1 to an env source. A refusal"
  say "  proven yesterday is not a refusal proven now."
  say ""

  local body code
  body="$(mktmp)"
  code="$(curl_src "/api/workspaces/$SOURCE_WS/import?mode=merge" \
            -X POST -H 'Content-Type: application/octet-stream' \
            --data-binary 'pds-proof-probe' -o "$body" -w '%{http_code}' 2>/dev/null || true)"; code="$(http_code "$code")"
  local err
  err="$(jqp 'd["error"]["code"]' <"$body" 2>/dev/null || echo '')"
  info "POST /api/workspaces/$SOURCE_WS/import?mode=merge -> HTTP $code  code=${err:-none}"
  info "body: $(head -c 300 "$body")"

  if [ "$code" = "403" ] && [ "$err" = "bundle_import_disabled" ]; then
    pass 7 "the source refuses a MERGE import: POST …/import?mode=merge -> HTTP 403 bundle_import_disabled, re-derived this run against $SOURCE_BASE (deployed sha ${DEPLOYED_SHA:-unresolved}). SCOPED CLAIM: the clean/restore mode is ungated by this flag and is NOT covered by this line."
  else
    fail 7 "the source did NOT refuse the MERGE import: HTTP $code code=${err:-none}. If this is a 2xx, a live content API is accepting bundle merges — check every env source (including .slots/*.env) for BARKPARK_ALLOW_BUNDLE_IMPORT."
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — THE CLOSING RE-PIN (PDS-D72)
# ═════════════════════════════════════════════════════════════════════════════
#
# DEPLOYED_SHA is captured once, in step 0a, and EVERY differential above is
# dated by it. This box has redeployed three times inside one 15-minute survey
# and once inside a three-minute probe, with Caddy flipping :4000 -> :4001
# mid-command. A run that straddles a deploy is comparing two different builds
# and calling the difference a finding. So the pin is re-read at the close.
#
# FAIL (the signal fired) and ABORT (there is no signal) are different outcomes
# and this step never collapses one into the other.

# ── THE CROSS-INVOCATION PIN TRIPLE (pds-bl-step8-cross-invocation-gap) ─────
# Step 8's guarantee is strictly PROCESS-LOCAL: it has no baseline from any
# earlier invocation, so it can only say that THIS process's 0a and THIS
# process's 8 agree. PDS-D101 makes a deferred 3/4 a SECOND full --all
# invocation, so a real transcript can span several — and contiguity ACROSS them
# is a check a reader has to make by hand. This prints the (run tag, 0a sha,
# 8 sha) triple on ONE grep-able line so that check is mechanical: chain the
# lines in transcript order and every run's sha_8 must equal the next run's
# sha_0a. Pure: it reads globals and prints, it decides nothing.
PIN_TRIPLE_PREFIX="PDS-PIN-TRIPLE"
pin_triple_line() { # sha_now uptime_now -> ONE machine-readable line
  printf '%s run_tag=%s run_id=%s sha_0a=%s sha_8=%s uptime_0a=%s uptime_8=%s pin_source=%s' \
    "$PIN_TRIPLE_PREFIX" "$RUN_TAG" "$RUN_ID" \
    "${DEPLOYED_SHA:-unresolved}" "${1:-unresolved}" \
    "${DEPLOYED_UPTIME_0A:-unresolved}" "${2:-unresolved}" \
    "${DEPLOYED_SHA_SOURCE:-unknown}"
}

step_8() {
  head_step 8 "CLOSING RE-PIN — did the source redeploy under this run?"

  if [ -z "$DEPLOYED_SHA" ] && [ -z "$DEPLOYED_UPTIME_0A" ]; then
    abort 8 "step:0a" \
      "no baseline to re-pin against: step 0a resolved neither a deployed sha (SSH) nor an uptime_seconds. Every source-derived number above is therefore undated — that is a real limit of this transcript, not a pass."
    return 0
  fi

  local sha_now
  sha_now=""
  if [ -n "$DEPLOYED_SHA" ] && [ "$DEPLOYED_SHA_SOURCE" = "ssh" ] && ssh_available; then
    sha_now="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
  elif [ "$DEPLOYED_SHA_SOURCE" = "operator-asserted" ]; then
    # A measured re-pin differing from an ASSERTED one convicts the assertion,
    # not the box, and this rung is about the box. Fall through to uptime.
    info "sha re-pin      SKIPPED — 0a's pin was OPERATOR-ASSERTED (PDS_DEPLOYED_SHA), so a mismatch here would convict the assertion rather than a redeploy. The uptime signal below is this rung's evidence."
  fi
  if [ -n "$sha_now" ]; then
    info "sha at 0a       $DEPLOYED_SHA"
    info "sha now         $sha_now"
    if [ "$sha_now" != "$DEPLOYED_SHA" ]; then
      info "$(pin_triple_line "$sha_now" "")"
      fail 8 "THE SOURCE REDEPLOYED UNDER THIS RUN: $DEPLOYED_SHA -> $sha_now. Every differential above straddles two builds and none of it is safe to quote. Re-run against a settled box."
      return 0
    fi
  else
    info "sha now         UNRESOLVED over SSH — falling back to the uptime signal"
  fi

  # The SSH-free fallback: uptime_seconds going BACKWARDS means the BEAM this
  # run was talking to was replaced under it.
  local status code uptime_now
  uptime_now=""
  status="$(mktmp)"
  code="$(http_code "$(bp_curl_code -sS -o "$status" --max-time 30 "$SOURCE_BASE/status.json" 2>/dev/null || true)")"
  if [ "$code" = "200" ]; then
    uptime_now="$(jqp 'd.get("uptime_seconds","")' <"$status" 2>/dev/null || true)"
    case "$uptime_now" in ''|*[!0-9]*) uptime_now="" ;; esac
  fi

  if [ -n "$DEPLOYED_UPTIME_0A" ] && [ -n "$uptime_now" ]; then
    info "uptime at 0a    ${DEPLOYED_UPTIME_0A}s"
    info "uptime now      ${uptime_now}s"
    if [ "$uptime_now" -lt "$DEPLOYED_UPTIME_0A" ]; then
      fail 8 "uptime_seconds went BACKWARDS ($DEPLOYED_UPTIME_0A -> $uptime_now): the process this run measured was replaced under it, whatever the sha says. Nothing above is safely quotable."
      return 0
    fi
  elif [ -z "$sha_now" ]; then
    abort 8 "env:no-repin-signal" \
      "neither signal was readable at the close (sha over SSH unresolved, /status.json -> HTTP $code). The run may or may not have straddled a deploy; refusing to print a green over an unread instrument."
    return 0
  fi

  info "$(pin_triple_line "$sha_now" "$uptime_now")"
  info "cross-invocation THIS RUNG IS PROCESS-LOCAL and does not claim otherwise. It holds no baseline from any earlier invocation, so it vouches for NOTHING about: (a) the interval BETWEEN invocations — a deploy landing after one run's green step 8 and before the next run's 0a is invisible to both; (b) anything carried across them, notably a parked full bundle, which is gated separately by its own .meta served_sha; (c) the TARGET's state — the pin is source-side only. A transcript spanning more than one invocation is contiguous only if a reader chains the $PIN_TRIPLE_PREFIX lines above in transcript order and checks that each run's sha_8 equals the next run's sha_0a."
  pass 8 "the source did not move under this run: ${sha_now:+sha re-read over SSH is unchanged ($sha_now)}${sha_now:+; }uptime_seconds ${DEPLOYED_UPTIME_0A:-?} -> ${uptime_now:-?} (monotonic). Every source-derived number above is dated by the SAME build."
}

# ═════════════════════════════════════════════════════════════════════════════
# DRIVER
# ═════════════════════════════════════════════════════════════════════════════

ALL_STEPS="0a 0b 0c 1 2 3 4 5 6 7 8"

summary() {
  printf '\n'
  rule
  say "SUMMARY — run $RUN_ID"
  rule
  printf '%s' "$RESULTS" | while IFS="$(printf '\t')" read -r id outcome blocker _detail; do
    [ -n "$id" ] || continue
    if [ "$outcome" = "ABORT" ]; then
      printf '  %-6s %-4s waits on %s\n' "$outcome" "$id" "$blocker"
    else
      printf '  %-6s %-4s\n' "$outcome" "$id"
    fi
  done
  rule
  printf '  %d PASS · %d ABORT (blocked, named) · %d FAIL\n' "$N_PASS" "$N_ABORT" "$N_FAIL"
  rule
  if [ "$N_FAIL" -gt 0 ]; then
    say "RESULT: FAIL — an assertion did not hold. That is the finding; do not re-run until it is explained."
    return 1
  fi
  if [ "$N_ABORT" -gt 0 ]; then
    say "RESULT: BLOCKED — every step above either passed with run-time numbers or"
    say "named the merge it waits on. This is the honest partial artifact the wave"
    say "is supposed to carry; it is NOT a green."
    return 2
  fi
  # ── a PARTIAL run NEVER claims the whole ladder (PDS-D86 class) ────────────
  #
  # `--only 0a,0b,7,8` used to print "the whole ladder ran and held" after
  # running four of eleven rungs. That line is the one a reader pastes into a
  # transcript as the crown proof, and it was the harness's own loudest
  # overclaim — the same defect class as a self-check that advertises a flag it
  # never asserts. A green is only "the ladder" when every rung of it ran.
  local n_ran n_all
  n_ran=$((N_PASS + N_ABORT + N_FAIL))
  n_all="$(printf '%s' "$ALL_STEPS" | wc -w | tr -d ' ')"
  if [ "$n_ran" -lt "$n_all" ]; then
    say "RESULT: PASS (PARTIAL) — the $n_ran rung(s) requested held, but $((n_all - n_ran)) of"
    say "the ladder's $n_all never ran. This is NOT the crown proof and must not be"
    say "quoted as one: only \`--all\` can pay that claim."
    return 0
  fi
  say "RESULT: PASS — the whole ladder ran and held."
  return 0
}

# canonical_order — reorder a requested step list into LADDER order.
#
# The ladder is SEQUENCED, not a menu: step 6's guard-off control deliberately
# leaves the target CLOBBERED, so `--only 6,5` typed in that order would measure
# step 5 against a target step 6 had already wrecked and report it as a finding.
# The steps a user asks for are honoured exactly; only their ORDER is corrected,
# and the correction is announced.
canonical_order() { # space-separated ids -> the same ids in ALL_STEPS order
  local want="$1" known unknown="" out="" s w
  for s in $ALL_STEPS; do
    for w in $want; do
      [ "$w" = "$s" ] && { out="$out $s"; break; }
    done
  done
  for w in $want; do
    known=0
    for s in $ALL_STEPS; do [ "$w" = "$s" ] && known=1; done
    [ "$known" -eq 1 ] || unknown="$unknown $w"
  done
  [ -z "$unknown" ] || die "unknown step(s)$unknown (known: $ALL_STEPS)"
  printf '%s' "${out# }"
}

run_steps() { # space-separated ids
  local s ordered
  ordered="$(canonical_order "$1")"
  banner
  if [ "$ordered" != "$(printf '%s' "$1" | tr -s ' ' | sed 's/^ //;s/ $//')" ]; then
    say "NOTE: steps reordered to ladder order ($ordered). The ladder is sequenced —"
    say "      step 6's guard-off control leaves the target clobbered on purpose, so"
    say "      running a later rung before an earlier one would measure wreckage."
    say ""
  fi
  for s in $ordered; do
    case "$s" in
      0a) step_0a ;;
      0b) step_0b ;;
      0c) step_0c ;;
      1)  step_1 ;;
      2)  step_2 ;;
      3)  step_3 ;;
      4)  step_4 ;;
      5)  step_5 ;;
      6)  step_6 ;;
      7)  step_7 ;;
      8)  step_8 ;;
      *)  die "unknown step '$s' (known: $ALL_STEPS)" ;;
    esac
  done
}

preflight() {
  command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH (used to read JSON without a jq dependency)"
  command -v tar >/dev/null 2>&1 || die "tar not found on PATH"
  [ -x "$SCAN_SCRIPT" ] || die "$SCAN_SCRIPT missing — this harness consumes it, it does not reimplement it"
  if [ "${#BARKPARK_HOME}" -ge "$MAX_HOME_LEN" ]; then
    die "BARKPARK_HOME is ${#BARKPARK_HOME} bytes (cap $MAX_HOME_LEN): $BARKPARK_HOME
  Postgres caps the unix-socket path at 103 bytes and barkpark-pg puts the socket
  inside this root. Use a short root, e.g. BARKPARK_HOME=/tmp/pds.\$\$"
  fi
  resolve_source_token || die "no source token. Set PDS_SOURCE_TOKEN, or add $SOURCE_BASE to ~/.config/barkpark/config.json. (It is never printed by this script.)"
}

# ── THE CONNINFO READER'S OWN CONTROL (pds-w6-scratch-env-quoting-trap) ─────
#
# A warning that is present in the file is not a warning that FIRES. This runs
# the SHIPPED load_target against two scratch.env fixtures it writes itself and
# pins BOTH directions:
#
#   NEGATIVE — a hand-written UNQUOTED assignment. The value must still arrive
#     truncated (nothing repairs it), the missing keys must be named exactly
#     `port dbname user`, the WARN must reach stderr, and the step-0c
#     classifier must still select the ABORT branch. Fail-closed is pinned as
#     an assertion, not as a promise in a comment.
#   POSITIVE — the QUOTED recipe. All four keys parse to their exact values and
#     stderr is EMPTY. A warner that shouts on a correct fixture is noise, and
#     it is this arm that makes the negative arm mean something.
#
# Offline and side-effect free: one mktemp directory, removed on the way out.
cmd_selftest_conninfo() {
  local tmpd arms=0 fails=0 err db missing
  tmpd="$(mktemp -d)"

  _sc_ok()  { arms=$((arms + 1)); printf '  ok   %s\n' "$1"; }
  _sc_bad() { arms=$((arms + 1)); fails=$((fails + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
  _sc_eq()  { # arm expected actual
    if [ "$2" = "$3" ]; then _sc_ok "$1"; else _sc_bad "$1" "expected [$2], got [$3]"; fi
  }

  say "selftest: the PDS_SCRATCH_DB conninfo reader"
  say ""
  say "  NEGATIVE CONTROL — hand-written, UNQUOTED (the form that bites)"

  mkdir -p "$tmpd/unquoted"
  {
    printf 'export PDS_SCRATCH_BASE=http://127.0.0.1:59999\n'
    printf 'export PDS_SCRATCH_TOKEN=selftest-token\n'
    printf 'PDS_SCRATCH_DB=host=127.0.0.1 port=59999 dbname=nope user=nope\n'
  } > "$tmpd/unquoted/scratch.env"

  db="$( BARKPARK_HOME="$tmpd/unquoted" ; load_target >/dev/null 2>&1 || true ; printf '%s' "$TARGET_DB" )"
  _sc_eq "unquoted: the sourced value is TRUNCATED at the first space and NOT repaired" \
    "host=127.0.0.1" "$db"

  missing="$(conninfo_missing_keys "$db")"
  _sc_eq "unquoted: the missing keys are named exactly" "port dbname user" "$missing"

  err="$( BARKPARK_HOME="$tmpd/unquoted" ; load_target 2>&1 1>/dev/null || true )"
  case "$err" in
    *"missing: port dbname user"*) _sc_ok "unquoted: load_target WARNS on stderr and names the missing keys" ;;
    *) _sc_bad "unquoted: load_target WARNS on stderr and names the missing keys" "stderr was [$err]" ;;
  esac
  case "$err" in
    *'must QUOTE the value'*) _sc_ok "unquoted: the WARN names the CAUSE (the missing quotes)" ;;
    *) _sc_bad "unquoted: the WARN names the CAUSE (the missing quotes)" "stderr was [$err]" ;;
  esac

  # FAIL-CLOSED, ASSERTED: step 0c aborts exactly when conninfo_missing_keys is
  # non-empty, so a non-empty answer here IS the abort branch being selected.
  if [ -n "$missing" ] && [ -z "$(conninfo_part port "$db")" ]; then
    _sc_ok "unquoted: step 0c still takes env:scratch-db-unparsed (no port -> no ambient-Repo fallback)"
  else
    _sc_bad "unquoted: step 0c still takes env:scratch-db-unparsed" \
      "missing=[$missing] port=[$(conninfo_part port "$db")] — the warning must not have bought a fallback"
  fi

  say ""
  say "  POSITIVE CONTROL — the CORRECTED, QUOTED recipe"

  mkdir -p "$tmpd/quoted"
  {
    printf 'export PDS_SCRATCH_BASE=http://127.0.0.1:59999\n'
    printf 'export PDS_SCRATCH_TOKEN=selftest-token\n'
    printf 'export PDS_SCRATCH_DB="host=127.0.0.1 port=59999 dbname=nope user=nope"\n'
  } > "$tmpd/quoted/scratch.env"

  db="$( BARKPARK_HOME="$tmpd/quoted" ; load_target >/dev/null 2>&1 || true ; printf '%s' "$TARGET_DB" )"
  _sc_eq "quoted: host"   "127.0.0.1" "$(conninfo_part host "$db")"
  _sc_eq "quoted: port"   "59999"     "$(conninfo_part port "$db")"
  _sc_eq "quoted: dbname" "nope"      "$(conninfo_part dbname "$db")"
  _sc_eq "quoted: user"   "nope"      "$(conninfo_part user "$db")"
  _sc_eq "quoted: nothing is missing" "" "$(conninfo_missing_keys "$db")"

  err="$( BARKPARK_HOME="$tmpd/quoted" ; load_target 2>&1 1>/dev/null || true )"
  _sc_eq "quoted: load_target is SILENT (a warner that shouts on a good fixture is noise)" "" "$err"

  # A PREDICATE, NOT AN ENUMERATION: one absent key is named on its own.
  _sc_eq "one missing key is named alone" "user" \
    "$(conninfo_missing_keys 'host=127.0.0.1 port=59999 dbname=nope')"

  rm -rf "$tmpd"
  say ""
  if [ "$fails" -eq 0 ]; then
    say "selftest: $arms/$arms arms pass"
    return 0
  fi
  say "selftest: $fails of $arms arms FAILED"
  return 1
}

# ── CITATION GREP HONESTY (pds-w5-citation-grep-honesty) ─────────────────────
#
# The census contract for this harness is a grep: `grep -oE 'PDS-D[0-9]+'`
# over the source is how a reader finds every ruling a line is governed by.
# A citation written the compressed way — one PDS-D number, then a bare `/D`
# continuation for each sibling — satisfies a HUMAN reader and defeats that
# grep, because the prefix appears on the FIRST number only. The census
# reports the head and silently loses every sibling behind it. The loss is
# invisible: nothing errors, the number is just quietly too low.
#
# (This comment deliberately does not spell an example out. The guard below
# reads THIS FILE, so an illustration here would be a real finding — which is
# itself the proof that the guard carries no exception list.)
#
# A PREDICATE, NOT AN ENUMERATION. The row that asked for this named two
# sites; the file had fourteen. So the guard is a shape — any PDS-D number
# followed by a bare /D number — and not a list of the places we happened to
# look. A list goes stale the first time someone writes a fifteenth.
#
# DENOMINATOR, STATED: `grep -o` counts MATCHES, not LINES. Two compressed
# citations on one line are two findings, and `grep -c` would call them one.
# Every count this selftest prints is a match count.
compressed_citations() {
  # Each offending citation, one per line. Empty output == clean.
  grep -oE 'PDS-D[0-9]+(/D[0-9]+)+' "$1" 2>/dev/null || true
}

# What the standard census actually sees in a file: the distinct rulings a
# naive `grep -oE 'PDS-D[0-9]+'` can reach.
census_identifiers() {
  grep -oE 'PDS-D[0-9]+' "$1" 2>/dev/null | sort -u || true
}

cmd_selftest_citations() {
  local tmpd arms=0 fails=0 found n_compressed n_seen bad
  # THE DEFECT SHAPE, BUILT FROM PARTS — never written as a literal.
  # A fixture that spelled the compressed form out as a literal would itself
  # be a finding in this file, and the last arm below would have to carve an
  # exception for its own test data. A guard with an exception list is a guard
  # you have to trust; this one measures the whole file with none.
  bad='/D'

  _st_ok()  { arms=$((arms + 1)); printf '  ok   %s\n' "$1"; }
  _st_bad() { arms=$((arms + 1)); fails=$((fails + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
  _st_eq()  { if [ "$2" = "$3" ]; then _st_ok "$1"; else _st_bad "$1" "expected [$2], got [$3]"; fi; }

  tmpd="$(mktemp -d)"

  say "selftest: decision-citation grep honesty"
  say ""
  say "  NEGATIVE CONTROL — the compressed form (the shape that loses numbers)"

  {
    printf '# the ONE full-fidelity export (PDS-D69%s70%s71)\n' "$bad" "$bad"
    printf '# THE 34 (PDS-D127%s128)\n' "$bad"
  } > "$tmpd/compressed.txt"

  found="$(compressed_citations "$tmpd/compressed.txt")"
  n_compressed="$(printf '%s' "$found" | grep -c . || true)"
  _st_eq "compressed: the detector FIRES, and names 2 citations (match count, not line count)" \
    "2" "$n_compressed"

  # THE ACTUAL DAMAGE, MEASURED: five rulings are cited, the census reaches two.
  n_seen="$(census_identifiers "$tmpd/compressed.txt" | grep -c . || true)"
  _st_eq "compressed: the standard census reaches only 2 of the 5 cited rulings" "2" "$n_seen"
  case "$(census_identifiers "$tmpd/compressed.txt" | tr '\n' ' ')" in
    *PDS-D70*) _st_bad "compressed: D70 is INVISIBLE to the census" "the fixture did not reproduce the defect, so the positive arm proves nothing" ;;
    *)         _st_ok  "compressed: PDS-D70 is INVISIBLE to the census (this is the bug)" ;;
  esac

  say ""
  say "  POSITIVE CONTROL — the expanded form (a guard that shouts here is noise)"

  {
    printf '# the ONE full-fidelity export (PDS-D69/PDS-D70/PDS-D71)\n'
    printf '# THE 34 (PDS-D127/PDS-D128)\n'
  } > "$tmpd/expanded.txt"
  # The expanded fixture IS spelled out: it is the correct shape, so it is
  # exactly what the last arm should find nothing wrong with.

  _st_eq "expanded: the detector is SILENT" "" "$(compressed_citations "$tmpd/expanded.txt")"
  n_seen="$(census_identifiers "$tmpd/expanded.txt" | grep -c . || true)"
  _st_eq "expanded: the census now reaches all 5 cited rulings" "5" "$n_seen"

  say ""
  say "  THE SUBJECT — this harness's own source"

  found="$(compressed_citations "$0")"
  n_compressed="$(printf '%s' "$found" | grep -c . || true)"
  if [ "$n_compressed" -eq 0 ]; then
    _st_ok "$SELF cites every ruling in full-prefix form ($(census_identifiers "$0" | grep -c . || true) distinct rulings reachable by the census grep)"
  else
    _st_bad "$SELF cites every ruling in full-prefix form" \
      "$n_compressed compressed citation(s) still present — the census under-reports this file: $(printf '%s' "$found" | tr '\n' ' ')"
  fi

  rm -rf "$tmpd"
  say ""
  if [ "$fails" -eq 0 ]; then
    say "selftest: $arms/$arms arms pass"
    return 0
  fi
  say "selftest: $fails of $arms arms FAILED"
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# SELFTEST — THE SENTINEL EXCLUSION ROSTER HAS ONE EDIT SITE (PDS-D129)
# ═════════════════════════════════════════════════════════════════════════════
#
# What this measures, in one sentence: that the roster this harness scopes its
# rung-6 sentinel with is the roster scripts/pds-schema-row-census.md declares,
# and that a disagreement between them is LOUD rather than silent.
#
# The old failure was not a wrong list. It was TWO lists — a `NOT IN` literal
# here and prose there — that a reader had to keep in step by hand, with nothing
# that noticed when they stopped agreeing. Both could be individually correct on
# the day they were written and wrong together a month later.
#
# THREE ARMS, and the middle one is the point:
#
#   POSITIVE   the real census, read from disk, derives EXACTLY the fallback.
#              This is the arm that reds if someone edits one file and not the
#              other — in EITHER direction, because it compares, not asserts.
#   NEGATIVE   a fixture census naming a third row derives that third row and is
#              REJECTED against the fallback. Without this arm the positive arm
#              proves only that the parser can return something.
#   REFUSALS   unreadable / absent declaration / a name carrying a quote all read
#              as NOT DERIVED (exit 1, no output), never as "derived empty" —
#              because an empty derivation would mismatch the fallback and red a
#              healthy run for a reason that is not about the roster at all.
#
# Offline. It reads two files and writes fixtures into a mktemp dir; it never
# needs a target, a network or a database.
cmd_selftest_roster() {
  local tmpd arms=0 fails=0 got rc census

  _sr_ok()  { arms=$((arms + 1)); printf '  ok   %s\n' "$1"; }
  _sr_bad() { arms=$((arms + 1)); fails=$((fails + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
  _sr_eq()  { if [ "$2" = "$3" ]; then _sr_ok "$1"; else _sr_bad "$1" "expected [$2], got [$3]"; fi; }
  # Runs the derivation on a fixture and reports "<exit>|<stdout>", so an arm can
  # tell "returned nothing and said so" from "returned nothing and claimed
  # success" — the distinction the whole not-derived-vs-derived-empty rule rests on.
  _sr_derive() { local o; if o="$(sentinel_exclusion_derive "$1")"; then printf '0|%s' "$o"; else printf '1|%s' "$o"; fi; }

  tmpd="$(mktemp -d)"
  census="$REPO_ROOT/$SENTINEL_EXCLUSION_SOURCE_REL"

  say "selftest: the sentinel exclusion roster has ONE edit site"
  say ""
  say "  POSITIVE CONTROL — the real census on disk"

  if [ -r "$census" ]; then
    _sr_eq "the census declares a roster and it parses" "0|$SENTINEL_EXCLUSION_FALLBACK" "$(_sr_derive "$census")"
  else
    _sr_bad "the census declares a roster and it parses" \
      "$SENTINEL_EXCLUSION_SOURCE_REL is not readable from $REPO_ROOT — the derivation has no source, so this harness is running on its UNCHECKED fallback"
  fi

  # The same comparison the run makes, made here where it costs nothing.
  got="$(_sr_derive "$census")"
  case "$got" in
    "0|$SENTINEL_EXCLUSION_FALLBACK")
      _sr_ok "census and in-script fallback AGREE ('$SENTINEL_EXCLUSION_FALLBACK') — step 6 would scope the sentinel to the declared roster" ;;
    0\|*)
      _sr_bad "census and in-script fallback AGREE" \
        "they do NOT: the census declares '${got#0|}', this harness's fallback names '$SENTINEL_EXCLUSION_FALLBACK'. Step 6 would FAIL before writing. FIX: the census is the edit site; the fallback follows it." ;;
    *)
      _sr_bad "census and in-script fallback AGREE" "the census did not derive, so nothing was compared" ;;
  esac

  say ""
  say "  NEGATIVE CONTROL — a census that names a THIRD row (the drift this catches)"

  printf 'prose\nPDS_SENTINEL_EXCLUSION = tag metric a_third_row\nmore prose\n' > "$tmpd/drifted.md"
  _sr_eq "a drifted census derives the drifted roster" "0|tag metric a_third_row" "$(_sr_derive "$tmpd/drifted.md")"
  if [ "tag metric a_third_row" = "$SENTINEL_EXCLUSION_FALLBACK" ]; then
    _sr_bad "the drifted roster is REJECTED against the fallback" \
      "the fixture happens to equal the fallback, so it reproduces no drift and the positive arm above proves nothing"
  else
    _sr_ok "the drifted roster is REJECTED against the fallback (this is the red step 6 would print)"
  fi

  say ""
  say "  REFUSALS — every unusable source reads as NOT DERIVED, never as derived-empty"

  _sr_eq "an absent file: exit 1, no output" "1|" "$(_sr_derive "$tmpd/nope.md")"

  printf 'a census with no declaration at all\n' > "$tmpd/silent.md"
  _sr_eq "no PDS_SENTINEL_EXCLUSION line: exit 1, no output" "1|" "$(_sr_derive "$tmpd/silent.md")"

  printf 'PDS_SENTINEL_EXCLUSION =    \n' > "$tmpd/empty.md"
  _sr_eq "an empty declaration: exit 1, no output (NOT an empty roster)" "1|" "$(_sr_derive "$tmpd/empty.md")"

  printf "PDS_SENTINEL_EXCLUSION = tag me'tric\n" > "$tmpd/quoted.md"
  _sr_eq "a name carrying a quote is REFUSED, not escaped" "1|" "$(_sr_derive "$tmpd/quoted.md")"

  say ""
  say "  THE DATASET TERM — PDS_SOURCE_DATASET must stay unset"

  # Same "<exit>|<stdout>" shape as _sr_derive, for the same reason: an arm has
  # to tell "accepted" from "refused and said nothing about it".
  _sr_ds() { local o; if o="$(sentinel_dataset_refusal "$1")"; then printf '0|%s' "$o"; else printf '1|%s' "$o"; fi; }

  # The expression, not a retyped copy of it: each arm resolves
  # ${PDS_SOURCE_DATASET:-production} itself, in a subshell whose environment it
  # sets, so what is under test is the same default the top of this file uses.
  _sr_eq "UNSET resolves to '$SENTINEL_DATASET_REQUIRED' and is accepted" \
    "0|" "$(unset PDS_SOURCE_DATASET; _sr_ds "${PDS_SOURCE_DATASET:-production}")"
  _sr_eq "exported EMPTY still resolves to '$SENTINEL_DATASET_REQUIRED' (:- not :=) and is accepted" \
    "0|" "$(PDS_SOURCE_DATASET=; _sr_ds "${PDS_SOURCE_DATASET:-production}")"
  _sr_eq "an explicit '$SENTINEL_DATASET_REQUIRED' is accepted" \
    "0|" "$(PDS_SOURCE_DATASET=production; _sr_ds "${PDS_SOURCE_DATASET:-production}")"

  # NEGATIVE CONTROL. Without this the three arms above prove only that the
  # predicate can return zero.
  _sr_eq "a non-production dataset is REFUSED (this is the red step 6 prints)" \
    "1|PDS_SOURCE_DATASET=scratch" "$(PDS_SOURCE_DATASET=scratch; _sr_ds "${PDS_SOURCE_DATASET:-production}")"
  _sr_eq "so is one that merely LOOKS like it" \
    "1|PDS_SOURCE_DATASET=production-2" "$(PDS_SOURCE_DATASET=production-2; _sr_ds "${PDS_SOURCE_DATASET:-production}")"

  # The live arm: what THIS process would actually scope to.
  got="$(_sr_ds "$SOURCE_DS")"
  case "$got" in
    "0|") _sr_ok "this process's own SOURCE_DS is '$SOURCE_DS' — step 6 would scope to the dataset the rows live in" ;;
    *)    _sr_bad "this process's own SOURCE_DS is usable" \
            "it is '$SOURCE_DS'; step 6 would FAIL before writing a row. FIX: leave PDS_SOURCE_DATASET unset." ;;
  esac

  say ""
  say "  THE PREMISE BEHIND THAT REFUSAL, re-derived from the application source"

  # The refusal above is only correct while the rows really do all live in
  # `production`. That is a fact about api/lib, not about this harness, so it is
  # DERIVED here rather than asserted in the comment block. A future plugin that
  # declares another dataset reds this arm and the roster needs re-deriving.
  #
  # BOUND, stated because a detector without one is a claim: the first arm sees
  # STRING-LITERAL `dataset:` declarations only. The one declaration in the tree
  # that is not a literal (tickets.ex `dataset: dataset`) is covered by the
  # second arm, which reads its default. A third shape would be seen by neither.
  local plugdir lits others attr_default
  plugdir="$REPO_ROOT/api/lib/barkpark/plugins"
  if [ -d "$plugdir" ]; then
    lits="$(grep -rhoE 'dataset:[[:space:]]*"[^"]*"' "$plugdir" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | sort | uniq -c | sed 's/^ *//' | tr '\n' ';' || true)"
    others="$(grep -rhoE 'dataset:[[:space:]]*"[^"]*"' "$plugdir" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | sort -u | grep -v "^$SENTINEL_DATASET_REQUIRED\$" | tr '\n' ' ' || true)"
    if [ -z "$lits" ]; then
      _sr_bad "every string-literal \`dataset:\` under api/lib/barkpark/plugins names '$SENTINEL_DATASET_REQUIRED'" \
        "the grep found NO literal declaration at all — an empty key set is not evidence of agreement, it is evidence the probe stopped matching. The shape changed; re-derive it."
    elif [ -z "$others" ]; then
      _sr_ok "every string-literal \`dataset:\` under api/lib/barkpark/plugins names '$SENTINEL_DATASET_REQUIRED' [$lits]"
    else
      _sr_bad "every string-literal \`dataset:\` under api/lib/barkpark/plugins names '$SENTINEL_DATASET_REQUIRED'" \
        "these do not: ${others}— the premise behind the dataset refusal no longer holds, and the sentinel roster in $SENTINEL_EXCLUSION_SOURCE_REL needs re-deriving against the new dataset."
    fi

    attr_default="$(sed -n 's/^[[:space:]]*@dataset_default[[:space:]]*"\([^"]*\)".*/\1/p' "$plugdir/tickets.ex" 2>/dev/null | head -n 1 || true)"
    if [ -z "$attr_default" ]; then
      _sr_bad "tickets.ex's non-literal \`dataset: dataset\` defaults to '$SENTINEL_DATASET_REQUIRED'" \
        "no @dataset_default literal was found in $plugdir/tickets.ex — the one declaration the literal grep cannot see is now unaccounted for"
    else
      _sr_eq "tickets.ex's non-literal \`dataset: dataset\` defaults to '$SENTINEL_DATASET_REQUIRED'" \
        "$SENTINEL_DATASET_REQUIRED" "$attr_default"
    fi
  else
    _sr_bad "the plugin sources are readable" \
      "$plugdir is not a directory from $REPO_ROOT — the premise behind the dataset refusal could not be re-derived this run"
  fi

  say ""
  say "  THE CLAUSE — what the roster becomes in SQL"

  _sr_eq "the IN-list is built from the roster, not typed" "'tag','metric'" "$(SENTINEL_EXCLUSION='tag metric'; sentinel_exclusion_sql_list)"
  got="$(SENTINEL_EXCLUSION='tag metric a_third_row'; sentinel_exclusion_sql_list)"
  _sr_eq "a three-name roster widens the clause with no further edit" "'tag','metric','a_third_row'" "$got"

  rm -rf "$tmpd"
  say ""
  if [ "$fails" -eq 0 ]; then
    say "selftest: $arms/$arms arms pass"
    return 0
  fi
  say "selftest: $fails of $arms arms FAILED"
  return 1
}

main() {
  # ── --plan WINS WHEREVER IT APPEARS, and nothing trailing is ignored (PDS-D89)
  #
  # The parser used to be a bare `case` on $1 with no shift loop, so
  # `--only 0a --plan` dispatched --only and DROPPED --plan on the floor: the
  # operator read "dry run" and the harness took a real ~51 MB export off live
  # guerrilla. A dry-run flag that is silently ignored is worse than one that
  # does not exist. Two rules, in this order:
  #   1. --plan anywhere in the argument vector means PLAN, and nothing runs.
  #   2. anything else the parser does not understand DIES, never gets dropped.
  # bash 3.2: a plain positional loop, no arrays, no mapfile, no ${var,,}.
  local a
  for a in "$@"; do
    case "$a" in
      --plan|plan) cmd_plan; exit 0 ;;
    esac
  done
  # no arguments at all is still the PLAN — the safe default is unchanged.
  [ $# -eq 0 ] && { cmd_plan; exit 0; }

  case "$1" in
    --all|all)
      [ $# -le 1 ] || die "--all takes no further arguments (got: $*). Nothing after it is ignored — say what you mean."
      preflight
      run_steps "$ALL_STEPS"
      summary
      exit $?
      ;;
    --only)
      [ $# -ge 2 ] || die "--only needs a comma-separated step list (e.g. --only 0a,0b,7)"
      [ $# -le 2 ] || die "--only takes exactly one comma-separated step list; unrecognised trailing arguments: $(printf '%s ' "${@:3}")
  A flag this parser does not understand is REFUSED, never silently dropped —
  \`--only 0a --plan\` used to take a real live export while printing nothing
  about the flag it ignored (PDS-D89)."
      preflight
      run_steps "$(printf '%s' "$2" | tr ',' ' ')"
      summary
      exit $?
      ;;
    --sweep-artifacts)
      [ $# -le 2 ] || die "--sweep-artifacts takes at most --apply (got: $*)"
      if [ $# -eq 2 ] && [ "$2" != "--apply" ]; then
        die "--sweep-artifacts understands only --apply (got: $2). A flag this parser does not understand is REFUSED, never silently dropped (PDS-D89)."
      fi
      cmd_sweep_artifacts "${2:-}"
      exit 0
      ;;
    --selftest-conninfo)
      [ $# -le 1 ] || die "--selftest-conninfo takes no further arguments (got: $*). A flag this parser does not understand is REFUSED, never silently dropped (PDS-D89)."
      cmd_selftest_conninfo
      exit $?
      ;;
    --selftest-citations)
      [ $# -le 1 ] || die "--selftest-citations takes no further arguments (got: $*). A flag this parser does not understand is REFUSED, never silently dropped (PDS-D89)."
      cmd_selftest_citations
      exit $?
      ;;
    --selftest-roster)
      [ $# -le 1 ] || die "--selftest-roster takes no further arguments (got: $*). A flag this parser does not understand is REFUSED, never silently dropped (PDS-D89)."
      cmd_selftest_roster
      exit $?
      ;;
    -h|--help|help)
      sed -n '2,/^# bash 3\.2 compatible/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'usage: %s {--plan|--all|--only <ids>|--sweep-artifacts [--apply]|--selftest-conninfo|--selftest-citations|--selftest-roster|--help}\n' "$SELF" >&2
      exit 3
      ;;
  esac
}

# PDS_PROOF_LIB=1 loads every rung WITHOUT running one. It exists so a rung can
# be exercised — and made to FAIL — in isolation, which is the only way to show
# an assertion is an instrument rather than a decoration (PDS-D20). It changes
# nothing about --plan/--all/--only.
if [ -z "${PDS_PROOF_LIB:-}" ]; then
  main "$@"
fi
