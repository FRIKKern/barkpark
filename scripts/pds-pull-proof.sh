#!/usr/bin/env bash
#
# pds-pull-proof.sh — THE PDS CROWN PROOF, WRITTEN AS AN EXECUTABLE SPECIFICATION.
#
#   scripts/pds-pull-proof.sh --plan        print every step, its precondition and
#                                           whether it is runnable today. NO side
#                                           effects, always exit 0.
#   scripts/pds-pull-proof.sh --all         run the whole ladder.
#   scripts/pds-pull-proof.sh --only 0a,7   run a subset (same rules).
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
# COST DISCIPLINE (PDS-D31/D44/D69). Two exports, at most, per run:
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
#   PDS_CONTROL_PG       maintenance conninfo for `pds-secret-scan.sh control`
#   BARKPARK_HOME        the scratch target's root. PINNED per run (PDS-D54).
#   PDS_SCRATCH_POINTER  pinned per run — it is ONE global path and two
#                        concurrent PDS runs clobber each other.
#   PDS_FULL_EXPORT_DIR  default /tmp/pds-full-export — the RUN-STABLE home of
#                        the one full bundle, its .meta, its attempt counter and
#                        its lock. Deliberately NOT under ART_DIR.
#   PDS_FULL_EXPORT_BUDGET       default 1 attempt, ever, per store
#   PDS_FULL_EXPORT_MIN_MEM_MB   default 2200 — the source's MemAvailable floor
#   PDS_STEP5_FAILDEMO=0 skip step 5's truncate/restore failure demonstration
#                        (the pass then says so: nothing proved the comparator
#                        can fail)
#   PDS_STEP6_GUARD_DEMO=0  skip step 6's guard-off control (same honesty)
#   PDS_PROOF_LIB=1      load the rungs as a library without running any
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

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
ART_DIR="${PDS_PROOF_ARTIFACTS:-/tmp/pds-proof-art.$RUN_TAG}"
MAX_HOME_LEN=85

# ── the ONE full-fidelity export (PDS-D69/D70/D71) ───────────────────────────
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
FULL_LOCK_OWNED=""
FULL_WHY=""            # why acquisition aborted, if it did
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

# ── temp hygiene ─────────────────────────────────────────────────────────────

TMP_FILES=""
TMP_DIRS=""
cleanup() {
  local f d
  for f in $TMP_FILES; do [ -f "$f" ] && rm -f "$f"; done
  for d in $TMP_DIRS; do [ -d "$d" ] && rm -rf "$d"; done
  # Release the full-export lock ONLY if this run took it. A lock we did not
  # create belongs to a concurrent run and removing it would let two full
  # exports overlap — the one thing PDS-D31 forbids.
  [ -n "$FULL_LOCK_OWNED" ] && [ -d "$FULL_LOCK" ] && rmdir "$FULL_LOCK" 2>/dev/null || true
  # A step-5 failure demo must never leave a blob truncated on the target.
  restore_blob_backup
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

TARGET_BASE=""; TARGET_TOKEN=""; TARGET_DB=""; TARGET_TREE=""; TARGET_MEDIA=""
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
  mkdir -p "$ART_DIR"
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
DEPLOYED_VERSION=""
DEPLOYED_UPTIME_0A=""
DEV_BUNDLE=""
PULL_BUNDLE=""      # the bundle step 1 actually imported
AMMO_FILE=""

# ═════════════════════════════════════════════════════════════════════════════
# THE PLAN
# ═════════════════════════════════════════════════════════════════════════════

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
  say "full export:   $FULL_TAR"
  say "               budget=$FULL_BUDGET attempt(s) · spent so far=$([ -f "$FULL_ATTEMPTS_FILE" ] && cat "$FULL_ATTEMPTS_FILE" || echo 0) · on-disk bundle=$([ -s "$FULL_TAR" ] && echo "PRESENT ($(wc -c <"$FULL_TAR" | tr -d ' ') bytes, would be REUSED for 0 attempts)" || echo absent)"
  say "               min MemAvailable on the source before it is taken: ${FULL_MIN_MEM_MB} MB"
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
    "RUNNABLE. Runs the PAIR (PDS-D58) with explicit -s/--token on both calls — BARKPARK_TOKEN is read NOWHERE. ASSERTS: (1) the built bp advertises --profile/--merge/--with-blobs in its own --help; (2) the export exits 0 and the tar carries a manifest; (3) the manifest's dataset EQUALS the dataset asked for — a workspace-grain bundle ABORTS naming pds-w4-pull-dataset-flag rather than being imported (PDS-D61/D62); (4) the import exits 0 and its receipt names tables+rows; (5) blob failures exit non-zero by the CLI's own contract. --merge is MANDATORY: mode=clean answers an opaque 500 (25P02 at workspace_bundle.ex:233) on a populated target. PDS-D9 adoption is reported by diffing the workspaces row across the import — the CLI never says it."

  plan_row 2 "RAW-PERSPECTIVE CENSUS — per-type ?perspective=raw&count=true, BOTH ends" \
    "source HTTP; for the target half, step 1's import" \
    "RUNNABLE both halves. Roster derived at RUN TIME from /v1/schemas on each end — never hardcoded (production/post is 0 on BOTH ends; this workspace has no post documents at all). ASSERTS AUTHEDNESS INDEPENDENTLY on each end before believing any total: an UNAUTHED raw query does NOT 401, it silently returns the published view, so the authed and unauthed censuses must DIFFER — and when a dataset genuinely has no drafts, an admin-only route must 401/403 instead. The import assertion is BUNDLE→TARGET per type (the bundle's own documents.copy rows, parsed with manifest column positions); SOURCE→BUNDLE deltas are printed as the scrub's scope, never asserted as loss. NEVER /v1/data/counts/:dataset (hard-codes published). Bare-slug E3 (PDS-D45) stays excluded."

  plan_row 3 "TICKET-DENY BYTE-SCAN — bytes at ROW grain, never a count diff" \
    "the dev bundle (0a) plus THE ONE full-fidelity bundle for the FIRING control" \
    "RUNNABLE when the one budgeted full export is acquirable; otherwise ABORTS with the acquisition's own named reason (severable — only 3 and 4 pay). doc_id and row uuid are RE-DERIVED at run time. ASSERTS: no ticket-carrying member and zero ROWS in documents.copy whose own doc_id/type/id identify the ticket (column positions from the manifest), because those identifiers are QUOTED IN PROSE elsewhere and a naive byte-absence assertion fires on a bundle where the deny held perfectly. THE CONTROL: the same identifiers must be FOUND at row grain in the FULL bundle — a zero with no control that fires is the vacuous green PDS-D20 forbids."

  plan_row 4 "VALUE-BASED SECRET SCAN — consumes scripts/pds-secret-scan.sh" \
    "run-time ammo (the source's webhook secrets) + the dev bundle + the full bundle + the target DB" \
    "RUNNABLE. Three assertions, none reimplemented here: (1) the dev bundle is CLEAN; (2) the SAME ammo FIRES on the one full bundle (the positive control — a scan that has never fired is not an instrument); (3) the TARGET DB is scanned via \`pds-secret-scan.sh scan --db \$PDS_SCRATCH_DB\` and the step FAILS when UNSCANNED > 0 or when zero tables were scanned — that script's own exit code is driven only by HITS (PDS-D68), so an unreadable table would otherwise print CLEAN with the secret sitting in the database."

  plan_row 5 "SERVED ASSET — every imported asset serves HTTP 200 with a matching content-length" \
    "step 1 imported blobs into the scratch target" \
    "RUNNABLE. Resolves from the TARGET's OWN /v1/media/:dataset (the flat /media index emits no originalUrl and ignores limit) and takes originalUrl and size VERBATIM per asset — originalUrl may be signed, so it is never rebuilt from a path. ASSERTS HTTP 200 AND content-length == the stored size for EVERY asset. FAILURE DEMO, run inline and reversed: one blob truncated to 100 bytes still serves 200 — only the stored size convicts it. SEPARATE ASSERTION: a missing blob answers the typed 404 'media blob missing', never a 500."

  plan_row 6 "CONVERGENCE — the imported state survives a REBOOT (PDS-D23/D62/D65)" \
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
  say "   · Refusal scope — step 7 proves the source refuses a MERGE import. The"
  say "     clean/restore mode is NOT gated by that flag, so 'guerrilla cannot be"
  say "     written' is a claim this transcript does not make (PDS-D73)."
  say "   · Asset scope — step 5 asserts served bytes against the size the TARGET's"
  say "     own database stores. It does not compare bytes against the SOURCE."
  say "   · Full-export scope — exactly ONE full-fidelity export is taken per store,"
  say "     and only as the FIRING control for steps 3 and 4. Its memory figure is"
  say "     measured by a 1 Hz ps sampler over SSH during that export; no cgroup"
  say "     number and no survey number is reprinted as this run's."
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
  code="$(http_code "$(curl -sS -o "$status" -w '%{http_code}' --max-time 30 "$SOURCE_BASE/status.json" 2>/dev/null || true)")"
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
    info "deployed sha    $DEPLOYED_SHA  (source of truth: the box's own git HEAD over SSH)"
  else
    info "deployed sha    UNRESOLVED over SSH ($SOURCE_SSH, key $SOURCE_SSH_KEY)"
  fi
  if command -v gh >/dev/null 2>&1; then
    local last_deploy
    last_deploy="$(gh run list --workflow deploy.yml --branch main --limit 1 \
      --json headSha,conclusion,createdAt -q '.[]|"\(.headSha[0:9]) \(.conclusion) \(.createdAt)"' 2>/dev/null || true)"
    info "last deploy run ${last_deploy:-none visible (auto-deploy may not be firing — see task-85eb87a30db908ec)}"
  fi

  # The one budgeted export: DEV profile. Never :full here (PDS-D31/D44).
  mkdir -p "$ART_DIR"
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
  pass 0a "source pinned: version=$version sha=${DEPLOYED_SHA:-unresolved}; dev dialect LIVE (HTTP 200, $bytes bytes, ${elapsed}s, $members members, profile=$profile dataset=$dataset, source_* present)"
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
      "no run-time source of the deployed sha. /status.json carries a version string, not a sha. FIX: make SSH reachable (PDS_SOURCE_SSH=$SOURCE_SSH, key $SOURCE_SSH_KEY) or export PDS_DEPLOYED_SHA=<sha> from an authenticated source. Asserting on the version string alone would be exactly the vacuous green this step exists to refuse."
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
    pass 0b "deployed sha EQUALS the worktree the target migrated from ($worktree_sha)"
    return 0
  fi

  if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$DEPLOYED_SHA" "$worktree_sha"; then
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

  pass 0b "deploy provenance holds: the deployed sha $DEPLOYED_SHA IS AN ANCESTOR OF the worktree the target migrated from ($worktree_sha), $ahead commit(s) behind — $code_ahead code, $docs_ahead docs-only"
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
  local pg_host pg_port pg_db pg_user kv
  pg_host=""; pg_port=""; pg_db=""; pg_user=""
  for kv in $TARGET_DB; do
    case "$kv" in
      host=*)   pg_host="${kv#host=}" ;;
      port=*)   pg_port="${kv#port=}" ;;
      dbname=*) pg_db="${kv#dbname=}" ;;
      user=*)   pg_user="${kv#user=}" ;;
    esac
  done
  if [ -z "$pg_host" ] || [ -z "$pg_port" ] || [ -z "$pg_db" ] || [ -z "$pg_user" ]; then
    abort 0c "env:scratch-db-unparsed" \
      "PDS_SCRATCH_DB did not parse into host/port/dbname/user ('$TARGET_DB'). Refusing to fall back to the ambient dev Repo."
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

# manifest_field <tar> <key> -> the value, or the empty string. Extracts ONLY
# manifest.json, never the whole bundle.
manifest_field() {
  local tar="$1" key="$2" d
  d="$(mktemp -d "${TMPDIR:-/tmp}/pds-mf.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $d"
  tar -xf "$tar" -C "$d" manifest.json 2>/dev/null || { printf '\n'; return 0; }
  KEY="$key" python3 -c '
import json,os,sys
d=json.load(open(sys.argv[1]))
v=d.get(os.environ["KEY"])
print("" if v is None else v)' "$d/manifest.json" 2>/dev/null || printf '\n'
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
  info "bp binary       $BP_BIN (built from $REPO_ROOT this run; its own \`cloud workspace --help\` advertises --profile, --dataset, --merge and --with-blobs)"
  info "target          $TARGET_BASE  (media dir $TARGET_MEDIA)"

  local tar out rc t0 t1
  tar="$ART_DIR/pull-$SOURCE_WS-$SOURCE_DS.tar"
  mkdir -p "$ART_DIR"
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
  local m_ds m_profile
  m_profile="$(manifest_field "$tar" profile)"
  m_ds="$(manifest_field "$tar" dataset)"
  info "manifest        profile='${m_profile:-<absent>}' dataset='${m_ds:-<absent>}' (asked for profile=dev dataset=$SOURCE_DS)"
  if [ -z "$m_ds" ]; then
    abort 1 "pds-w4-pull-dataset-flag" \
      "the exported manifest carries NO dataset field — this is a WORKSPACE-GRAIN bundle wearing a dataset command line. Refusing to import it: every per-type census downstream would silently describe the whole workspace while the transcript claimed dataset=$SOURCE_DS (PDS-D61/D62). The bundle is on disk at $tar if you want to look."
    return 0
  fi
  if [ "$m_ds" != "$SOURCE_DS" ]; then
    fail 1 "the exported manifest says dataset='$m_ds' but the export asked for '$SOURCE_DS' — the scope flag is not reaching the engine. Nothing was imported."
    return 0
  fi
  if [ "$m_profile" != "dev" ]; then
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
  pass 1 "the pull ran through the front-door PAIR: export --profile dev --dataset $SOURCE_DS --with-blobs ($bytes bytes, $n_blobs blobs) then import --yes --merge --with-blobs into $TARGET_BASE, exit 0 in $((t1 - t0))s. Manifest grain ASSERTED dataset=$m_ds profile=$m_profile. Receipt: ${receipt:-<none printed>}"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — RAW-PERSPECTIVE CENSUS
# ═════════════════════════════════════════════════════════════════════════════

# Bare-slug E3 tables, from api/lib/barkpark/tenancy/workspace_bundle/catalog.ex
# (@e3_dataset_keyed). Derived from the source at run time when it is readable;
# this fallback is only used to NAME the exclusion, never to assert a count.
E3_BARE_SLUG_FALLBACK="preview_token_jti shares"

src_total() { # type perspective -> integer (or empty)
  local t="$1" p="$2"
  curl_src "/v1/data/query/$SOURCE_DS/$t?perspective=$p&count=true&limit=0" \
    | jqp 'd["result"]["total"]' 2>/dev/null || true
}

src_total_anon() { # type perspective -> integer (or empty) — NO Authorization
  local t="$1" p="$2"
  curl -sS --max-time "${PDS_HTTP_TIMEOUT:-120}" \
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
  local bare_slug shares_rows owners
  bare_slug="$E3_BARE_SLUG_FALLBACK"
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
# THE ONE FULL EXPORT (PDS-D69/D70/D71) — acquired once, consumed twice
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
# retry), a mkdir lock (flock does not exist on Darwin), and five conditions
# printed with their measured values BEFORE any byte moves.
#
# THE RSS NUMBER IS MEASURED, NOT QUOTED. A 1 Hz `ps -o rss= -p <beam pid>`
# sampler over SSH, with NO slot restart: cgroup memory.peak is mode 0444 on
# this kernel and only a restart resets it, and a restart costs ~26 s of LIVE
# content-API downtime. Any cgroup figure that appears anywhere is labelled
# CUMULATIVE-SINCE-BOOT. The survey's numbers are never reprinted as this run's.

full_meta_ok() { # 0 = the on-disk bundle is a usable FULL bundle
  [ -s "$FULL_TAR" ] || return 1
  local p
  p="$(manifest_field "$FULL_TAR" profile)"
  case "$p" in
    ""|full) return 0 ;;   # "" = an engine that predates the profile field
    *) return 1 ;;
  esac
}

full_meta_field() { # key -> the value recorded in the .meta sidecar (empty if absent)
  [ -f "$FULL_META" ] || return 0
  awk -v k="$1:" '$1 == k { $1=""; sub(/^[ \t]+/, ""); print; exit }' "$FULL_META"
}

full_attempts() { # -> integer (never empty — an empty/garbage counter file reads 0)
  local n=""
  if [ -f "$FULL_ATTEMPTS_FILE" ]; then
    n="$(tr -dc '0-9' <"$FULL_ATTEMPTS_FILE" | head -c 6)"
  fi
  printf '%s' "${n:-0}"
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
      return 0
    fi
  fi

  # ── the five conditions, printed with measured values, before any byte moves
  local spent mem_kb mem_mb sha_now deploy_running gh_rc gh_out cond_a cond_b cond_c cond_d cond_e ok=1
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

  mem_mb=""
  if ssh_available; then
    mem_kb="$(ssh_src "awk '/MemAvailable/{print \$2}' /proc/meminfo" | tr -d '[:space:]' || true)"
    [ -n "$mem_kb" ] && mem_mb=$((mem_kb / 1024))
  fi
  if [ -z "$mem_mb" ]; then
    cond_b="UNKNOWN (MemAvailable unreadable — SSH is the only route to it)"; ok=0
  elif [ "$mem_mb" -ge "$FULL_MIN_MEM_MB" ]; then
    cond_b="OK (${mem_mb} MB available, floor ${FULL_MIN_MEM_MB} MB)"
  else
    cond_b="FAILED (${mem_mb} MB available, floor ${FULL_MIN_MEM_MB} MB) — taking it now risks OOMing the LIVE content API"; ok=0
  fi

  if [ "$spent" -lt "$FULL_BUDGET" ]; then
    cond_c="OK ($spent of $FULL_BUDGET attempt(s) spent)"
  else
    cond_c="FAILED — the budget is exhausted ($spent of $FULL_BUDGET). A dead export still paid its peak; raise PDS_FULL_EXPORT_BUDGET deliberately or reuse $FULL_TAR"; ok=0
  fi

  deploy_running=""
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
    deploy_running="$(printf '%s' "$gh_out" | tr '\n' ' ')"
    if [ "$gh_rc" -ne 0 ]; then
      cond_d="UNKNOWN (gh exited $gh_rc — the GitHub API did not answer, so an in-flight deploy cannot be ruled out)"; ok=0
    elif [ -z "$gh_out" ]; then
      cond_d="OK (no deploy.yml run in progress)"
    else
      cond_d="FAILED — deploy.yml run(s) in progress: $deploy_running. A deploy mid-export swaps the slot under the request"; ok=0
    fi
  else
    cond_d="UNKNOWN (gh is not on PATH, so an in-flight deploy cannot be ruled out)"; ok=0
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
  info "FULL-EXPORT PRECONDITIONS (all five printed BEFORE any byte moves):"
  info "  (a) served sha re-pinned == step 0a's ....... $cond_a"
  info "  (b) MemAvailable >= ${FULL_MIN_MEM_MB} MB ................. $cond_b"
  info "  (c) attempts < budget ...................... $cond_c"
  info "  (d) no deploy.yml run in progress .......... $cond_d"
  info "  (e) lock acquired .......................... $cond_e"
  say ""

  if [ "$ok" -ne 1 ]; then
    FULL_WHY="${stale_note}a full-export precondition did not hold — (a) $cond_a · (b) $cond_b · (c) $cond_c · (d) $cond_d · (e) $cond_e"
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
  mkdir -p "$ART_DIR"
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

  local t0 t1 code bytes
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
  code="$(http_code "$(curl_src "/api/workspaces/$SOURCE_WS/export" -o "$FULL_TAR" -w '%{http_code}' \
            --max-time "${PDS_FULL_EXPORT_TIMEOUT:-900}" 2>/dev/null || true)")"
  t1="$(date +%s)"

  if [ -n "$rss_pid" ]; then kill "$rss_pid" 2>/dev/null || true; wait "$rss_pid" 2>/dev/null || true; fi
  peak_kb="$(first_int "$(awk '{ if ($1+0 > m) m = $1+0 } END { print m+0 }' "$rss_log" 2>/dev/null)")"

  bytes="$(first_int "$(wc -c <"$FULL_TAR" 2>/dev/null | tr -d ' ')")"
  if [ "$code" != "200" ] || ! int_ok "$bytes" || [ "$bytes" -lt 1024 ]; then
    rm -f "$FULL_TAR"
    FULL_WHY="the full export returned HTTP $code / $bytes bytes and the attempt is spent ($spent_now of $FULL_BUDGET). A dead export still paid its memory peak, which is exactly why the counter moved first."
    [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
    return 1
  fi
  if ! full_meta_ok; then
    FULL_WHY="the export succeeded but the bundle is not a readable full-profile bp-export-v1 bundle (manifest profile='$(manifest_field "$FULL_TAR" profile)')"
    [ -n "$FULL_LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null && FULL_LOCK_OWNED=""
    return 1
  fi

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
rss_peak_kb:    $peak_kb
rss_baseline_kb: ${baseline_kb:-unknown}
run_id:         $RUN_ID
EOF

  info "full bundle     HTTP 200 · $bytes bytes · $((t1 - t0))s · $FULL_RSS_LINE"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around an HTTP/CLI call issued from this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM doing the work is the remote SERVER, so no in-BEAM meter is reachable. A LATENCY, never a price (PDS-D605)" \
    "full bundle"
  info "                parked at $FULL_TAR (+ .meta) — run-stable, so the NEXT run reuses it for 0 attempts"
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

  local fdir f_cols f_i_docid f_i_type f_rows
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
print(c.index("doc_id")+1, c.index("type")+1)' "$fdir/manifest.json" 2>/dev/null || true)"
  if [ -z "$f_cols" ]; then
    fail 3 "the full bundle's manifest does not describe a documents member — the control cannot be run"
    return 0
  fi
  f_i_docid="$(printf '%s' "$f_cols" | awk '{print $1}')"
  f_i_type="$(printf '%s' "$f_cols" | awk '{print $2}')"
  f_rows="$(awk -F'\t' -v a="$doc_id" -v b="$pub_id" -v idc="$f_i_docid" -v it="$f_i_type" '
            $it == "ticket" || $idc == a || $idc == b { n++ } END { print n + 0 }' \
            "$fdir/tables/documents.copy" 2>/dev/null || echo ERR)"
  info "full bundle     ticket ROWS in tables/documents.copy: $f_rows (the control must be > 0)"
  if ! int_ok "$f_rows" || [ "$f_rows" -eq 0 ]; then
    fail 3 "THE CONTROL DID NOT FIRE: the FULL bundle carries $f_rows ticket rows too. Either the ammo (doc_id=$doc_id) is wrong or this bundle is not full fidelity — and until the assertion is shown capable of a non-zero, the dev bundle's zero above proves nothing (PDS-D20)."
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
  if [ -n "${PDS_CONTROL_PG:-}" ]; then
    local crc cout
    cout="$(mktmp)"
    crc=0
    "$SCAN_SCRIPT" control --pg "$PDS_CONTROL_PG" >"$cout" 2>&1 || crc=$?
    sed 's/^/      /' "$cout"
    if [ "$crc" -eq 0 ]; then
      info "instrument control: PASSED — the scan FIRES on a full-shaped fixture and comes back clean on a deny-shaped one"
    else
      fail 4 "the scan's own control did not behave as a control (exit $crc) — every clean result above is therefore uninterpretable"
      return 0
    fi
  else
    info "instrument control: NOT RUN (set PDS_CONTROL_PG=<maintenance conninfo> to run \`$SCAN_SCRIPT control\` — it builds its own throwaway fixture and spends no guerrilla export)"
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

# ── THE 34 (PDS-D127/D128) ───────────────────────────────────────────────────
#
# `schema_definitions` on a pulled target holds 36 rows in three CLASSES, and
# only one of them behaves the way the guard is about:
#
#   34  plugin-declared    Bootstrap walks them every boot. SURVIVE stamped,
#                          REVERT cleared. These, and only these, are the guard.
#    1  `tag`              TagRegistry writes it every boot from a five-key map,
#                          BEFORE register_all_schemas/0 and outside the guard
#                          entirely (PDS-D125). REVERTS on both legs.
#    1  `metric`           declared by no local plugin, so Bootstrap's
#                          Registry.all() walk never visits it. SURVIVES FOREVER
#                          on both legs.
#
# A table-wide sentinel therefore reds leg A on `tag` and hangs leg B red
# forever on `metric` — and the transcript would show a digest that moved with
# the stamp present, which reads exactly like "the guard failed". Scope IS the
# fix, not a detail of it.
#
# There is NO SQL discriminator for "plugin-declared": `schema_definitions` has
# 23 columns and none records a source (`dataset_id IS NULL` is an artefact of
# hand-insertion, not a marker). The exclusion list is a HAND-MAINTAINED roster,
# which is exactly why the sentinel UPDATE's RETURNING count is asserted against
# the SKIP count in the target's own server.log below (PDS-D129). That
# cross-check is the only thing that turns a future guerrilla-only orphan, or a
# third core writer, from a silent vacuous green into a loud red.
sentinel_scope_sql() { # workspace_id -> the WHERE clause selecting exactly those 34
  printf "workspace_id = '%s' AND dataset = '%s' AND name NOT IN ('tag','metric')" \
    "$1" "$SOURCE_DS"
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

reboot_target() { # 0 = the target answered HTTP again
  local i code
  "$TARGET_TREE/bin/barkpark" stop >/dev/null 2>&1 || true
  "$TARGET_TREE/bin/barkpark" up >"$BARKPARK_HOME/reboot.log" 2>&1 || return 1
  i=0
  while [ "$i" -lt 90 ]; do
    code="$(http_code "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$TARGET_BASE/api/schemas" 2>/dev/null || true)")"
    [ "$code" = "200" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

step_6() {
  head_step 6 "CONVERGENCE — the imported state survives a REBOOT (PDS-D23/D62/D65)"

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
  # AMONG TARGET-READING RUNGS (PDS-D101/D116) — steps 2 and 5 run BEFORE it and
  # `--all`'s own order is the only safe one. Re-ordering this rung earlier
  # silently poisons every later read; do not.
  #
  # `dataset` and `name` are KEYS in the digest and are NEVER sentinelled.
  local mark sentinel_id sentinel_rows
  sentinel_id="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9._-' '-')"
  mark="PDS-SENTINEL-$sentinel_id"
  say ""
  info "SENTINEL        writing deliberate drift into all eight guarded columns"
  info "                scope: workspace $stamp_ws · dataset $SOURCE_DS · name NOT IN ('tag','metric')"
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

  # digest_before now reflects the SENTINELLED state — that is the whole point.
  digest_before="$(tgt_psql "$GUARDED_DIGEST_SQL" | head -1 || true)"
  local cols_before
  cols_before="$(scoped_column_digests "$stamp_ws")"
  if [ -z "$digest_before" ] || [ -z "$cols_before" ]; then
    fail 6 "could not digest schema_definitions on the target — the eight guarded columns cannot be compared across a reboot, so a 'converged' verdict would be unmeasured"
    return 0
  fi
  info "before reboot   guarded-column digest $digest_before"

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
  info "after reboot    guarded-column digest ${digest_after:-<unreadable>}"

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
    fail 6 "ROSTER DRIFT: the sentinel wrote $sentinel_rows rows but the boot logged ${skip_count:-0} Bootstrap guard SKIPs (the core \`tag\` row's own TagRegistry skip, ${tag_skip_count:-0} this boot, is excluded from both sides on purpose). Those two numbers are derived independently — the sentinel from this script's hand-maintained exclusion list ('tag','metric'), the SKIPs from Bootstrap's own Registry.all() walk — and no SQL discriminator for plugin-declared rows exists to reconcile them (PDS-D129). A mismatch means the scope below no longer selects the rows the guard is about, so neither leg can be interpreted."
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
    pass 6 "content-and-presence convergence across a real reboot: $sentinel_rows rows were deliberately DRIFTED in all eight guarded columns and the guard preserved every one of them ($digest_before, unchanged; $survivors/$sentinel_rows sentinels intact; $skip_count SKIPs logged), and the pull_provenance stamp survived. NOTE: the guard-off control was DISABLED (PDS_STEP6_GUARD_DEMO=0), so nothing here proves this box would clobber without the stamp — the green is weaker for it, and the target is left SENTINELLED."
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
  info "after guard-off ${digest_clobbered:-<unreadable>}"
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
  local cols_clobbered leg_b_unmoved survivors_after
  cols_clobbered="$(scoped_column_digests "$stamp_ws")"
  leg_b_unmoved="$(columns_where same "$cols_before" "$cols_clobbered")"
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
  pass 6 "content-and-presence convergence across a real reboot, measured against DELIBERATE DRIFT rather than against an untouched target: $sentinel_rows rows (workspace $stamp_ws · dataset $SOURCE_DS · minus the tag/metric non-plugin rows) were sentinelled in all eight guarded columns, the boot logged exactly $skip_count Bootstrap guard SKIPs to match (plus ${tag_skip_count:-0} TagRegistry skip of the core \`tag\` row, which the scope excludes), and the stamped reboot preserved every column and all $survivors sentinels ($digest_before, unchanged) — AND the control fires per column: with the stamp cleared by asserted SQL, the very next boot reverted ALL EIGHT of $GUARDED_COLUMNS and wiped every trace of the drift (${digest_clobbered}). At sha parity a sentinel-free version of this rung would pass with the guard deleted from the codebase; this one cannot."
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

step_8() {
  head_step 8 "CLOSING RE-PIN — did the source redeploy under this run?"

  if [ -z "$DEPLOYED_SHA" ] && [ -z "$DEPLOYED_UPTIME_0A" ]; then
    abort 8 "step:0a" \
      "no baseline to re-pin against: step 0a resolved neither a deployed sha (SSH) nor an uptime_seconds. Every source-derived number above is therefore undated — that is a real limit of this transcript, not a pass."
    return 0
  fi

  local sha_now
  sha_now=""
  if [ -n "$DEPLOYED_SHA" ] && ssh_available; then
    sha_now="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
  fi
  if [ -n "$sha_now" ]; then
    info "sha at 0a       $DEPLOYED_SHA"
    info "sha now         $sha_now"
    if [ "$sha_now" != "$DEPLOYED_SHA" ]; then
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
  code="$(http_code "$(curl -sS -o "$status" -w '%{http_code}' --max-time 30 "$SOURCE_BASE/status.json" 2>/dev/null || true)")"
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
    -h|--help|help)
      sed -n '2,83p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'usage: %s {--plan|--all|--only <ids>|--help}\n' "$SELF" >&2
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
