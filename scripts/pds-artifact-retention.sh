#!/usr/bin/env bash
#
# pds-artifact-retention.sh — KEEP-N retention over the PDS run-scoped artifact
# directories, and a mechanical proof that the parked full-export store is not
# in its scope.
#
# THE LEAK, RE-MEASURED (pds-bl-artifact-dir-retention)
# ----------------------------------------------------
# Every PDS run that reaches rung 0a writes a dev-profile export of PRODUCTION
# content into a RUN-scoped directory `$PDS_ARTIFACT_ROOT/pds-proof-art.<tag>`.
# The filed row said "~51 MB"; that number is a MEAN, not a per-run constant,
# and it has grown. Measured from the harness's own transcripts rather than
# inherited:
#
#   · 952 MB across 18 abandoned directories  = 52.9 MB mean per directory
#     (the backlog the ownership trap in pds-pull-proof.sh was built against)
#   · run 3fa886ec, 2026-07-20, a run that took BOTH legs of rung 1:
#       pull-default-production.tar         55,947,776 B   (53.4 MiB)
#       pull-default-production.tar.blobs    7,987,874 B   ( 7.6 MiB)
#                                    total  63,935,650 B   (61.0 MiB)
#   · the wave-21 fire record cites a 76 MB directory.
#   · a run that ABORTS before the export costs ~4 KB: the two directories
#     standing on the author's box on 2026-09-16 each hold one 351-byte tar.
#
# So the denominator is PER RUN THAT COMPLETES RUNG 0a, not per invocation, and
# the figure is content-size dependent: 53-76 MB over the measured window, not
# a fixed 51.
#
# WHAT ALREADY EXISTS, AND THE GAP THIS FILLS
# -------------------------------------------
# `pds-pull-proof.sh` owns the directory IT creates and removes it on a CLEAN
# exit, and `pds-pull-proof.sh --sweep-artifacts --apply` is an operator verb
# for the backlog. Two things are still missing, and both are why a leak stays
# a leak:
#
#   1. THE SWEEP CANNOT SEE THE LAUNCHER'S DIRECTORIES. Its name predicate
#      accepts `pds-proof-art.<hex>` only — any non-hex byte after the dot is
#      REFUSED as "not a name this harness makes". `pds-crown-launch.sh` exports
#      `PDS_PROOF_ARTIFACTS=/tmp/pds-proof-art.pds-w14.<hex>`, so every
#      launcher-fired run's directory is PERMANENTLY unsweepable — and the
#      launcher's runs are exactly the ones that FAIL and are therefore retained
#      rather than removed by the trap. That predicate lives in the FROZEN
#      harness and correcting it there needs a chartered thaw; this verb reads
#      both shapes from outside the freeze.
#   2. NOTHING PRESERVES THE MOST RECENT RUNS. The sweep's only recency notion
#      is a 24h floor for UNMARKED directories; a MARKED directory whose run
#      died five minutes ago is removed on the next sweep — which is precisely
#      the evidence a reader wants after a FAIL. Retention here is KEEP-N: the
#      N newest candidates survive unconditionally, whatever their age.
#
# IT IS A DELETION MECHANISM, SO IT FAILS CLOSED
# ----------------------------------------------
# Nothing is removed unless this run PROVED it may be. Every refusal is printed
# with its reason, on both sides of the line. In refusal order:
#
#   REFUSED  not a directory
#   REFUSED  a name this apparatus does not make
#   REFUSED  owned by another unix user (stat uid != ours)
#   REFUSED  an owner marker naming another HOST — liveness undecidable here
#   REFUSED  an owner marker naming a LIVE pid on this host — a run owns it
#   REFUSED  TOUCHED WITHIN THE QUIESCE WINDOW — a run may still be writing it,
#            whatever its marker says (a marker is written at mkdir; the export
#            lands minutes later, and an unmarked legacy directory has none)
#   REFUSED  no marker at all AND younger than the minimum age — the pre-marker
#            backlog is unmarked, so "no marker" alone can never mean abandoned
#   REFUSED  inside the KEEP window — one of the N most recently touched
#
# There is no wildcard removal anywhere below: each `rm -rf` names one path this
# loop proved, one at a time, and only under --apply.
#
# THE PARKED FULL-EXPORT STORE IS OUT OF SCOPE, AND THAT IS ASSERTED
# ------------------------------------------------------------------
# `$PDS_FULL_EXPORT_DIR` (default /tmp/pds-full-export) holds the one full
# bundle, its .meta, its attempt counter and its lock. It is deliberately NOT
# run-scoped, and re-taking it costs a ~1.03 GB export against a budget. It
# cannot match this verb's glob — but "cannot" is the kind of claim that stops
# being true in a later edit, so it is MEASURED: a listing is taken before and
# after the loop and a difference is a hard exit 3, even under a dry run.
#
# USAGE
#   scripts/pds-artifact-retention.sh                 # dry run, keeps 3
#   scripts/pds-artifact-retention.sh --apply
#   scripts/pds-artifact-retention.sh --keep 5 --apply
#   scripts/pds-artifact-retention.sh --root /tmp --keep 0 --apply
#
# ENVIRONMENT (every flag has one; the flag wins)
#   PDS_ARTIFACT_ROOT        default /tmp    — the parent this verb walks
#   PDS_ARTIFACT_KEEP        default 3       — how many newest candidates survive
#   PDS_SWEEP_MIN_AGE_HOURS  default 24      — the unmarked-backlog floor, the
#                                              same knob the harness sweep reads
#   PDS_ARTIFACT_QUIESCE_MIN default 10      — a directory touched more recently
#                                              than this is never removed
#   PDS_FULL_EXPORT_DIR      default /tmp/pds-full-export — asserted UNTOUCHED
#
# EXIT STATUS
#   0  the walk completed (removals only under --apply)
#   2  this verb refused to run at all — it measured nothing, claim nothing
#   3  the parked full-export store CHANGED across the walk. Never expected.
#
# bash 3.2 compatible (macOS system bash).

set -uo pipefail

SELF="$(basename "$0")"

ROOT="${PDS_ARTIFACT_ROOT:-/tmp}"
KEEP="${PDS_ARTIFACT_KEEP:-3}"
MIN_AGE_HOURS="${PDS_SWEEP_MIN_AGE_HOURS:-24}"
QUIESCE_MIN="${PDS_ARTIFACT_QUIESCE_MIN:-10}"
FULL_DIR="${PDS_FULL_EXPORT_DIR:-/tmp/pds-full-export}"
MARKER_NAME=".pds-proof-owner"   # written by pds-pull-proof.sh's art_dir_ensure
APPLY=0

say()  { printf '%s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 76); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --keep)  [ $# -ge 2 ] || die "--keep needs a value"; KEEP="$2"; shift 2 ;;
    --root)  [ $# -ge 2 ] || die "--root needs a value"; ROOT="$2"; shift 2 ;;
    --help|-h)
      sed -n '/^# USAGE/,/^# bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    # A flag this parser does not understand is REFUSED, never silently dropped.
    *) die "unknown argument: $1" ;;
  esac
done

# ── the guard on the guard ───────────────────────────────────────────────────
# `[ abc -lt 3 ]` is a bash ERROR that evaluates FALSE, so a non-numeric knob
# would slip past every comparison below and silently disable the clause it
# governs. Validate as integers FIRST, and refuse rather than measure a weaker
# policy than the one this transcript will claim.
is_int "$KEEP"          || die "--keep / PDS_ARTIFACT_KEEP='$KEEP' is not an integer. Nothing was examined."
is_int "$MIN_AGE_HOURS" || die "PDS_SWEEP_MIN_AGE_HOURS='$MIN_AGE_HOURS' is not an integer. Nothing was examined."
is_int "$QUIESCE_MIN"   || die "PDS_ARTIFACT_QUIESCE_MIN='$QUIESCE_MIN' is not an integer. Nothing was examined."
[ -d "$ROOT" ] || die "artifact root '$ROOT' is not a directory. Nothing was examined."

ME="$(id -u)"
HOST="$(uname -n 2>/dev/null || echo unknown)"

marker_field() { # field dir -> value on stdout ('' when unreadable)
  local f="$1" d="$2" raw
  [ -f "$d/$MARKER_NAME" ] || return 0
  # NOT `sed … | head -n 1`: head exits after one line, sed takes SIGPIPE on the
  # rest, and the pipeline's 141 would be read as a failure on a marker file
  # that is merely longer than the pipe buffer. Capture, then take line one.
  raw="$(sed -n "s/^$f:[[:space:]]*//p" "$d/$MARKER_NAME" 2>/dev/null || true)"
  [ -n "$raw" ] && printf '%s\n' "${raw%%$'\n'*}"
  return 0
}

# ── stat(1) PORTABILITY: PROBE ONCE, REMEMBER THE ANSWER ────────────────────
# `-f` means OPPOSITE things in the two stats, and that is why the usual
# defensive idiom is broken here:
#   BSD / macOS   stat -f FORMAT path   — "render path with this FORMAT"
#   GNU coreutils stat -f path          — "print FILE SYSTEM status of path",
#                                         and the format flag is `-c`.
# So on Linux `stat -f %m "$d"` does NOT fail. It treats `%m` as a FILE operand
# (which does not exist) and `$d` as another, prints a block-size/inode-count
# report for the containing filesystem, and the `|| stat -c …` fallback either
# never fires or appends a second line to garbage. Either way every mtime and
# uid compared downstream is nonsense, SILENTLY — every directory then reads as
# "owned by another unix user" and NOTHING is ever retained or removed.
# Measured: GH Actions run 35504059438, job 106061128225 — nine arms of
# pds-artifact-retention.test.sh red on a Linux runner, green on this Mac.
#
# A `||` fallback is only safe when the FIRST form FAILS on the other platform.
# BSD stat rejects `-c` outright, so GNU-FIRST is the safe ordering — but a
# fallback chain also mis-fires on a path that simply does not exist (the GNU
# form fails for the right reason, and the BSD form then answers with garbage).
# So this file does not chain at all: it PROBES ONCE, on a path that certainly
# exists, and every call below reuses the one answer. There is no literal
# `stat -f` in this file for a later editor to copy.
if stat -c %u . >/dev/null 2>&1; then
  STAT_FLAG=-c;  STAT_F_UID=%u; STAT_F_MTIME=%Y; STAT_F_SIZE=%s   # GNU coreutils
else
  STAT_FLAG=-f;  STAT_F_UID=%u; STAT_F_MTIME=%m; STAT_F_SIZE=%z   # BSD / macOS
fi

uid_of()   { stat "$STAT_FLAG" "$STAT_F_UID"   "$1" 2>/dev/null || true; }
mtime_of() { stat "$STAT_FLAG" "$STAT_F_MTIME" "$1" 2>/dev/null || true; }
size_of()  { stat "$STAT_FLAG" "$STAT_F_SIZE"  "$1" 2>/dev/null || true; }

# The probe is a claim, so it is CHECKED before anything is classified: if the
# chosen flavour cannot read the uid and mtime of a directory that certainly
# exists, this verb refuses rather than reading every entry as unreadable and
# reporting a confident "0 removable".
is_int "$(uid_of .)"   || die "stat $STAT_FLAG $STAT_F_UID gave no numeric uid for '.'; neither GNU nor BSD stat works here. Nothing was examined."
is_int "$(mtime_of .)" || die "stat $STAT_FLAG $STAT_F_MTIME gave no numeric mtime for '.'; neither GNU nor BSD stat works here. Nothing was examined."

# A name this apparatus makes. TWO shapes, and the second is the whole point:
#   pds-proof-art.<hex>              — pds-pull-proof.sh's own default
#   pds-proof-art.<label>.<hex>      — what pds-crown-launch.sh exports
# Anything else is refused: a directory nobody here can account for is not ours
# to delete, however much it looks like one.
name_ok() {
  case "$1" in
    pds-proof-art.) return 1 ;;
    pds-proof-art.*[!0-9a-f]*)
      case "${1#pds-proof-art.}" in
        *.*)
          local label="${1#pds-proof-art.}"
          local tag="${label##*.}"; label="${label%.*}"
          case "$label" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
          case "$tag"   in ''|*[!0-9a-f]*)      return 1 ;; esac
          return 0 ;;
        *) return 1 ;;
      esac ;;
    pds-proof-art.*) return 0 ;;
    *) return 1 ;;
  esac
}

full_store_listing() { # a stable, comparable description of the parked store
  if [ ! -e "$FULL_DIR" ]; then
    printf 'ABSENT %s\n' "$FULL_DIR"
    return 0
  fi
  # name, size and mtime of every entry — enough to catch a removal, a
  # truncation or a re-write, and it never reads a ~1 GB body.
  find "$FULL_DIR" -mindepth 0 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r e; do
        printf '%s\t%s\t%s\n' "$e" "$(size_of "$e")" "$(mtime_of "$e")"
      done
  return 0
}

rule
say "PDS ARTIFACT RETENTION — keep the $KEEP newest of $ROOT/pds-proof-art.*"
say "$([ "$APPLY" = 1 ] && echo 'MODE: --apply — proven-removable directories WILL be removed' || echo 'MODE: dry run — nothing is removed. Re-run with --apply to act.')"
say "unmarked directories must be older than ${MIN_AGE_HOURS}h · nothing touched within ${QUIESCE_MIN}min is removed"
say "parked full-export store: $FULL_DIR — OUT OF SCOPE, asserted before and after"
rule

FULL_BEFORE="$(full_store_listing)"
say "PARKED STORE BEFORE:"
printf '%s\n' "$FULL_BEFORE" | sed 's/^/    /'
rule

now="$(date -u +%s)"
quiesce_s=$((QUIESCE_MIN * 60))
min_age_s=$((MIN_AGE_HOURS * 3600))

# PASS 1 — classify. Candidates are collected with their mtime so the KEEP
# window can be decided over the SURVIVING set, never over the raw glob: a
# directory refused for liveness must not consume a keep slot a removable one
# would otherwise have had.
candidates=""   # newline-joined "<mtime>\t<path>"
n_refused=0

for d in "$ROOT"/pds-proof-art.*; do
  [ -e "$d" ] || continue
  name="$(basename "$d")"
  if [ ! -d "$d" ]; then
    printf '  REFUSED  %-46s not a directory\n' "$name"; n_refused=$((n_refused + 1)); continue
  fi
  if ! name_ok "$name"; then
    printf '  REFUSED  %-46s not a name this apparatus makes (pds-proof-art.<hex> or pds-proof-art.<label>.<hex>)\n' "$name"
    n_refused=$((n_refused + 1)); continue
  fi
  uid="$(uid_of "$d")"
  if [ -z "$uid" ] || [ "$uid" != "$ME" ]; then
    printf '  REFUSED  %-46s owned by uid %s, not by uid %s — another unix user\n' "$name" "${uid:-unreadable}" "$ME"
    n_refused=$((n_refused + 1)); continue
  fi
  mt="$(mtime_of "$d")"
  if ! is_int "$mt"; then
    printf '  REFUSED  %-46s mtime unreadable — age and recency undecidable\n' "$name"
    n_refused=$((n_refused + 1)); continue
  fi
  age=$((now - mt))
  marker="$(marker_field run_id "$d")"
  if [ -n "$marker" ]; then
    mhost="$(marker_field host "$d")"
    mpid="$(marker_field pid "$d")"
    if [ "$mhost" != "$HOST" ]; then
      printf '  REFUSED  %-46s marker names host %s, not this one — liveness undecidable here\n' "$name" "${mhost:-unknown}"
      n_refused=$((n_refused + 1)); continue
    fi
    if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
      printf '  REFUSED  %-46s pid %s is ALIVE on this host — a run owns it (%s)\n' "$name" "$mpid" "$marker"
      n_refused=$((n_refused + 1)); continue
    fi
  fi
  # THE IN-FLIGHT GUARD, and it is deliberately independent of the marker. A
  # marker is written at mkdir; the ~60 MB export body lands minutes later, and
  # a pid can be recycled between the two. A directory still being written to is
  # refused on its mtime alone.
  if [ "$age" -lt "$quiesce_s" ]; then
    printf '  REFUSED  %-46s touched %ss ago, inside the %smin quiesce window — a run may still be writing it\n' "$name" "$age" "$QUIESCE_MIN"
    n_refused=$((n_refused + 1)); continue
  fi
  if [ -z "$marker" ] && [ "$age" -lt "$min_age_s" ]; then
    printf '  REFUSED  %-46s no owner marker AND younger than %sh — cannot be proved abandoned\n' "$name" "$MIN_AGE_HOURS"
    n_refused=$((n_refused + 1)); continue
  fi
  candidates="$candidates$mt	$d
"
done

# PASS 2 — THE KEEP WINDOW. The N most recently touched candidates survive
# unconditionally, whatever their age or their marker. This is the clause the
# harness sweep does not have: after a FAIL the freshest directory is the one
# holding the bundle a reader needs, and a policy that prunes purely on age
# deletes the evidence first.
kept=0
n_removed=0
kb_removed=0
sorted="$(printf '%s' "$candidates" | grep -v '^$' | LC_ALL=C sort -rn -k1,1)"

if [ -n "$sorted" ]; then
  while IFS='	' read -r mt d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    if [ "$kept" -lt "$KEEP" ]; then
      kept=$((kept + 1))
      printf '  KEPT     %-46s newest #%s of %s — inside the keep window\n' "$name" "$kept" "$KEEP"
      continue
    fi
    kb="$(du -sk "$d" 2>/dev/null | awk 'NR==1{print $1}')"
    is_int "${kb:-}" || kb=0
    kb_removed=$((kb_removed + kb))
    n_removed=$((n_removed + 1))
    if [ "$APPLY" = 1 ]; then
      rm -rf "$d" 2>/dev/null || true
      printf '  REMOVED  %-46s %s KB, outside the keep window of %s\n' "$name" "$kb" "$KEEP"
    else
      printf '  WOULD    %-46s %s KB, outside the keep window of %s\n' "$name" "$kb" "$KEEP"
    fi
  done <<SORTED
$sorted
SORTED
fi

rule
FULL_AFTER="$(full_store_listing)"
say "PARKED STORE AFTER:"
printf '%s\n' "$FULL_AFTER" | sed 's/^/    /'
if [ "$FULL_BEFORE" != "$FULL_AFTER" ]; then
  rule
  say "FATAL: the parked full-export store at $FULL_DIR CHANGED across this walk."
  say "This verb must never reach it. Diff:"
  # NOT process substitution: this file is run under whatever bash the operator
  # has, and bash 3.2 in POSIX mode refuses `<(…)` at EXPANSION time — which
  # would abort the very branch that exists to report the worst outcome.
  # PORTABLE mktemp (explicit path + XXXXXX): `-t NAME` without XXXXXX is BSD-only
  # and GNU coreutils refuses it outright.
  _b="$(mktemp "${TMPDIR:-/tmp}/pds-art-before.XXXXXX")" || { say "FATAL: mktemp failed"; exit 3; }
  _a="$(mktemp "${TMPDIR:-/tmp}/pds-art-after.XXXXXX")"  || { say "FATAL: mktemp failed"; exit 3; }
  printf '%s\n' "$FULL_BEFORE" >"$_b"; printf '%s\n' "$FULL_AFTER" >"$_a"
  diff "$_b" "$_a" | sed 's/^/    /'
  rm -f "$_b" "$_a"
  exit 3
fi
say "parked store UNCHANGED across the walk (listing compared byte for byte)"
rule
say "$kept kept · $n_removed $([ "$APPLY" = 1 ] && echo removed || echo removable) ($((kb_removed / 1024)) MB) · $n_refused refused"
[ "$APPLY" = 1 ] || say "Nothing was removed. Re-run: $SELF --apply"
rule
exit 0
