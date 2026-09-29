#!/usr/bin/env bash
#
# undispatched-target-check.sh — the MIRROR of the *-path-escape-check.sh family.
#
# ── THE DEFECT THIS EXISTS TO REFUSE ─────────────────────────────────────────
#
# The escape-check family asks ONE direction: is everything the gate READS
# inside the declared target set? A set that misses a read means a PR editing
# that read skips the gate, and the skip reports green.
#
# This file asks the OTHER direction, which nothing in the tree asked before:
# does every DECLARED target actually DISPATCH? Where a guard's target list
# lives in one file and the consuming workflow carries its OWN `paths:` filter
# (or its own copy of the list), a target can be DECLARED and never DISPATCH.
# The workflow never starts on that head, so the gated job never runs, the
# aggregate context reports green, and NO RED IS EVER EMITTED — the check that
# would have caught it is the one that did not run. It is a silent failure by
# construction, which is why it sits for months behind a guard everyone trusts.
#
# Same family as "a path widening with no roster row is INERT: the path starts
# the workflow and fires nothing", wearing a different file's clothes.
#
# ── THE THREE IMMUNITY PROPERTIES (the reusable pattern) ─────────────────────
#
# scripts/console-path-escape-check.sh is the WORKED INSTANCE. It is immune for
# three reasons that generalise, and `--pattern` prints them with the evidence
# this script measures for each:
#
#   P1  SINGLE DERIVATION POINT. The consumer keeps NO copy of the list: it
#       shells `--match <set>` and takes the answer. Two copies drift in
#       silence and the half that drifts is the half nobody re-reads.
#       EVIDENCE: the consuming workflow's own `paths:` list is absent, or is
#       byte-identical to what the guard prints (the go-tests.yml degenerate
#       case, where the declaration IS the trigger and cannot diverge).
#   P2  NO WORKFLOW-LEVEL `paths:` FILTER ON THE CONSUMER'S pull_request ARM.
#       A paths-filtered workflow emits NO check run at all on a non-matching
#       head (honest-gates D18), so there is a trigger to fall through BEFORE
#       the dispatcher ever gets a vote.
#       EVIDENCE: `on.pull_request.paths` / `paths-ignore` absent.
#   P3  SELF-INCLUSION. The guard is in its OWN target set, so it cannot be
#       edited without dispatching the harness that proves it.
#       EVIDENCE: the guard's own repo-relative path is matched by the set it
#       prints.
#
# A candidate satisfying all three is IMMUNE. A candidate failing any is
# AT-RISK, and the failing property is NAMED — an unclassified entry is not a
# finding, and a count without dispositions is not an audit.
#
# ── THE CANDIDATE SET IS DERIVED, NEVER TYPED ────────────────────────────────
#
# A hand-written roster rots silently: the entry added tomorrow is unguarded
# and the file still reads complete. Two candidate generators built for the
# related sweep each missed a known instance — one keyed on VOCABULARY (missed
# a case whose name did not match), one keyed STRUCTURALLY (silently dropped a
# case because a step carried an `id:`). So this file derives three ways and
# UNIONS them, then prints the derivation before the verdict:
#
#   D1  GUARDS. A script under scripts/ carrying a `--match)` case arm — the
#       shape of a target list that answers a dispatcher's question. Keyed on
#       SHAPE, not on the `*-path-escape-check.sh` name.
#   D2  CONSUMER JOINS. (a) a workflow naming the guard in a `pin_script=`
#       assignment together with a literal `--match <set>`; (b) a guard naming
#       a `.github/workflows/*.yml` file in an assignment (the inverted case:
#       the declaration lives in the workflow and the guard parses it).
#   D3  EVERY WORKFLOW CARRYING AN `on.*.paths` OR `on.*.paths-ignore` KEY.
#       Every one is classified, including the ones with no external
#       declaration — those are IMMUNE because their trigger list is their only
#       declaration, and one list cannot disagree with itself.
#   D4  IN-WORKFLOW ROSTERS. A workflow carrying a `roster='` two-column
#       (job, path) block: a target list and its consumer in ONE file, where
#       the roster column must be a subset of the workflow's own paths.
#
# THE GENERATOR IS TESTED AGAINST THE KNOWN-IMMUNE CASE BEFORE ITS OUTPUT IS
# TRUSTED ANYWHERE ELSE: the run FAILS if the console pair is absent from the
# derivation or classified anything but IMMUNE (`assert_console_control`).
#
# ── BOTH ARMS, IN ONE RUN ────────────────────────────────────────────────────
#
# For every AT-RISK entry this run plants a declared-but-undispatched target
# into a scratch copy of that entry's real declared set and asserts the checker
# REDS on it, and asserts a correctly-dispatched target from the SAME set is
# NOT flagged. Both arms go through `cover.py`, the same code path the live
# classification uses — a control that exercises different code proves nothing.
# If the enumeration finds NO at-risk entry, that ABSENCE is the result and is
# printed with its mechanism; a synthetic at-risk pair still runs both arms, so
# the checker is never silently skipped on a clean tree.
#
# ── REFUSAL ──────────────────────────────────────────────────────────────────
#
# A detector for silent failure must not itself be capable of failing silently.
# Every unreadable or empty input prints a distinct `CANNOT READ:` line and
# exits 2. Zero findings exits 0 and prints `OK:`. The two are never
# byte-identical.
#
# EXIT: 0 every entry classified, no undispatched target · 1 at least one
#       undispatched declared target (or a control arm failed) · 2 CANNOT READ.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.
# python3 + PyYAML are the only unstubbed dependencies; their absence is a
# CANNOT READ refusal, never a pass.

set -uo pipefail

# The guard below is copied verbatim (modulo the script name) from
# scripts/committed-symlink-check.sh:82-91. It must stay POSIX-parseable and
# must stay ABOVE the first process substitution: bash reads incrementally, so
# anything the guard sits after is code a POSIX-mode shell has already run.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "undispatched-target-check.sh: needs bash (this script uses process substitution); run: bash scripts/undispatched-target-check.sh${1:+ $1}" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "undispatched-target-check.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this script's process substitution; run: bash scripts/undispatched-target-check.sh${1:+ $1}" >&2
    exit 2
    ;;
esac


ROOT="${UNDISPATCHED_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WF_DIR="$ROOT/.github/workflows"
SCRIPT_DIR="$ROOT/scripts"
SELF_REL="scripts/undispatched-target-check.sh"

FINDINGS=0
ARMS_RUN=0
ENTRIES=0
ATRISK=0
IMMUNE=0

cannot_read() { echo "CANNOT READ: $*" >&2; exit 2; }
finding() { FINDINGS=$((FINDINGS + 1)); echo "::error::$*"; }

command -v python3 >/dev/null 2>&1 || cannot_read "python3 is not on PATH — the workflow YAML cannot be parsed. This is NOT a pass."
python3 -c 'import yaml' 2>/dev/null || cannot_read "PyYAML is not importable — the workflow YAML cannot be parsed. This is NOT a pass. (pip3 install pyyaml)"
[ -d "$WF_DIR" ] || cannot_read "workflow directory does not exist: $WF_DIR"
[ -d "$SCRIPT_DIR" ] || cannot_read "scripts directory does not exist: $SCRIPT_DIR"


TMP="$(mktemp -d "${TMPDIR:-/tmp}/udt.XXXXXX")" || cannot_read "could not create a scratch directory under ${TMPDIR:-/tmp}"
trap 'rm -rf "$TMP"' EXIT
CLASSES="$TMP/classes.txt"; : >"$CLASSES"
ARMOUT=""

# ── the matcher, written once and shared by the live pass AND both arms ──────
# ONE CODE PATH. A control that exercises different code from the live pass
# proves nothing about the live pass.
cat >"$TMP/cover.py" <<'PY'
import re, sys

def to_ere(glob):
    out, i = [], 0
    while i < len(glob):
        c = glob[i]
        if c == "*":
            if glob[i:i+2] == "**":
                out.append(".*"); i += 2; continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c in ".^$+(){}[]|\\":
            out.append("\\" + c)
        else:
            out.append(c)
        i += 1
    return "".join(out)

def witness(glob):
    w = glob.replace("**", "__w__/__w__").replace("*", "__w__").replace("?", "w")
    return re.sub(r"/+", "/", w)

def load(p):
    try:
        with open(p) as f:
            return [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    except OSError as e:
        sys.stderr.write("CANNOT READ: %s (%s)\n" % (p, e)); sys.exit(2)

declared_p, paths_p, ignore_p = sys.argv[1], sys.argv[2], sys.argv[3]
declared = load(declared_p)
paths = load(paths_p) if paths_p != "-" else []
ignore = load(ignore_p) if ignore_p != "-" else []

if not declared:
    sys.stderr.write("CANNOT READ: the declared target set at %s is EMPTY. An empty set is not zero findings.\n" % declared_p); sys.exit(2)
if paths_p != "-" and not paths:
    sys.stderr.write("CANNOT READ: the trigger path list at %s is EMPTY. An empty list is not zero findings.\n" % paths_p); sys.exit(2)

pre = re.compile("|".join("(?:%s)" % to_ere(p) for p in paths)) if paths else None
igre = re.compile("|".join("(?:%s)" % to_ere(p) for p in ignore)) if ignore else None

bad = 0
for d in declared:
    w = witness(d)
    why = ""
    if pre is not None and not pre.fullmatch(w):
        why = "no trigger alternative matches"
    elif igre is not None and igre.fullmatch(w):
        why = "excluded by paths-ignore"
    if why:
        bad += 1
        print("UNDISPATCHED\t%s\t%s\t%s" % (d, w, why))
sys.exit(1 if bad else 0)
PY

# ── D3: every workflow's on.<event>.paths / paths-ignore, arm by arm ─────────
cat >"$TMP/wf.py" <<'PY'
import os, sys, yaml

wf_dir, out_dir = sys.argv[1], sys.argv[2]
names = sorted(n for n in os.listdir(wf_dir) if n.endswith((".yml", ".yaml")))
if not names:
    sys.stderr.write("CANNOT READ: no workflow files under %s\n" % wf_dir); sys.exit(2)

parsed = 0
index = open(os.path.join(out_dir, "wfarms.tsv"), "w")
for n in names:
    p = os.path.join(wf_dir, n)
    try:
        with open(p) as f:
            doc = yaml.safe_load(f)
    except Exception as e:
        sys.stderr.write("CANNOT READ: %s could not be parsed as YAML (%s)\n" % (p, e)); sys.exit(2)
    if not isinstance(doc, dict):
        sys.stderr.write("CANNOT READ: %s did not parse to a mapping\n" % p); sys.exit(2)
    parsed += 1
    # PyYAML resolves the bare key `on` to the boolean True (YAML 1.1), so a
    # lookup for the string alone silently finds NOTHING on every workflow.
    trig = doc.get("on", doc.get(True))
    if not isinstance(trig, dict):
        continue
    for event, body in trig.items():
        if not isinstance(body, dict):
            continue
        for key in ("paths", "paths-ignore"):
            vals = body.get(key)
            if not isinstance(vals, list) or not vals:
                continue
            fn = "%s__%s__%s.txt" % (n, event, key)
            with open(os.path.join(out_dir, fn), "w") as g:
                for v in vals:
                    g.write("%s\n" % v)
            index.write("%s\t%s\t%s\t%s\n" % (n, event, key, fn))
index.close()
if parsed == 0:
    sys.stderr.write("CANNOT READ: parsed zero workflows under %s\n" % wf_dir); sys.exit(2)
print(parsed)
PY

mkdir -p "$TMP/arms"
WF_COUNT="$(python3 "$TMP/wf.py" "$WF_DIR" "$TMP/arms")" || cannot_read "workflow trigger extraction failed (the cause is on the line above)"
[ -n "$WF_COUNT" ] && [ "$WF_COUNT" -gt 0 ] 2>/dev/null || cannot_read "workflow trigger extraction reported ${WF_COUNT:-<nothing>} parsed workflows"

# ── D1: guard scripts (SHAPE: a `--match)` case arm, never the file NAME) ────
: >"$TMP/guards.txt"
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*--match\)' "$f" && echo "scripts/$(basename "$f")" >>"$TMP/guards.txt"
done
GUARD_N="$(grep -c . "$TMP/guards.txt" 2>/dev/null || echo 0)"
[ "$GUARD_N" -gt 0 ] || cannot_read "D1 derived ZERO guard scripts (no '--match)' case arm under $SCRIPT_DIR). An empty derivation is not zero findings — either the generator broke or the shape moved."

# ── D2a: workflow -> guard (a `pin_script=` assignment + a literal --match) ──
: >"$TMP/pairs.tsv"
for wf in "$WF_DIR"/*.yml; do
  [ -f "$wf" ] || continue
  wfb="$(basename "$wf")"
  gs="$(grep -oE 'pin_script="scripts/[A-Za-z0-9._-]+\.sh"' "$wf" | sed -e 's/pin_script="//' -e 's/"$//' | sort -u)"
  [ -n "$gs" ] || continue
  for g in $gs; do
    grep -qxF "$g" "$TMP/guards.txt" || continue
    sets="$(grep -oE -- '--match ([a-z][a-z0-9_-]*)' "$wf" | awk '{print $2}' | sort -u)"
    if [ -z "$sets" ]; then
      printf '%s|%s|%s|shelled\n' "$g" "" "$wfb" >>"$TMP/pairs.tsv"
    else
      for st in $sets; do printf '%s|%s|%s|shelled\n' "$g" "$st" "$wfb" >>"$TMP/pairs.tsv"; done
    fi
  done
done

# ── D2b: guard -> workflow (the INVERTED case: the declaration lives in the
#         workflow and the guard parses it out, so there is only ever one copy)
while IFS= read -r g; do
  [ -n "$g" ] || continue
  wfs="$(grep -oE '^[[:space:]]*[A-Z_]+=.*\.github/workflows/[A-Za-z0-9._-]+\.ya?ml' "$ROOT/$g" | grep -oE '\.github/workflows/[A-Za-z0-9._-]+\.ya?ml' | sed 's#.*/##' | sort -u)"
  for w in $wfs; do
    [ -f "$WF_DIR/$w" ] || continue
    awk -F'|' -v g="$g" -v w="$w" '$1==g && $3==w {found=1} END{exit found?0:1}' "$TMP/pairs.tsv" 2>/dev/null \
      || printf '%s|%s|%s|parsed-from-workflow\n' "$g" "" "$w" >>"$TMP/pairs.tsv"
  done
done <"$TMP/guards.txt"

sort -u "$TMP/pairs.tsv" -o "$TMP/pairs.tsv"
PAIR_N="$(grep -c . "$TMP/pairs.tsv" 2>/dev/null || echo 0)"
[ "$PAIR_N" -gt 0 ] || cannot_read "D2 derived ZERO guard/consumer joins from $GUARD_N guard script(s). An empty join is not zero findings."

# ── D4: in-workflow rosters (target list and consumer in ONE file) ──────────
: >"$TMP/rosters.txt"
for wf in "$WF_DIR"/*.yml; do
  grep -q "roster='" "$wf" 2>/dev/null && basename "$wf" >>"$TMP/rosters.txt"
done

# ── helpers ─────────────────────────────────────────────────────────────────
arms_for() { awk -F'\t' -v w="$1" '$1==w {print $2"\t"$3"\t"$4}' "$TMP/arms/wfarms.tsv"; }

print_set_into() { # guard set outfile -> 0 ok, non-zero when the set came back empty
  local g="$1" st="$2" out="$3"
  if [ -n "$st" ]; then bash "$ROOT/$g" --print-set "$st" >"$out" 2>"$out.err"
  else bash "$ROOT/$g" --print-set >"$out" 2>"$out.err"; fi
  grep -qE '^[^[:space:]]' "$out" 2>/dev/null || return 2
  return 0
}

classify_line() { # class · entry · mechanism
  ENTRIES=$((ENTRIES + 1))
  case "$1" in IMMUNE) IMMUNE=$((IMMUNE + 1)) ;; AT-RISK) ATRISK=$((ATRISK + 1)) ;; esac
  printf '%s|%s\n' "$1" "$2" >>"$CLASSES"
  printf '%-8s  %s\n            %s\n' "$1" "$2" "$3"
}

print_pattern() {
  cat <<'PAT'
THE PATTERN — three properties that make a declared target set DISPATCH-SAFE.
Worked instance: scripts/console-path-escape-check.sh + .github/workflows/console-harness.yml.

  P1  SINGLE DERIVATION POINT — the consumer keeps no copy of the list.
      console-harness.yml shells `scripts/console-path-escape-check.sh --match console`
      and takes the answer; that flag exists, in the script's own words, "so the
      workflow and the ratchet can never disagree about what the path set contains".
      EVIDENCE MEASURED HERE: the guard is named in the consumer's `pin_script=`
      assignment and invoked with a literal `--match <set>`, and the consumer's
      pull_request trigger carries no competing list. (The degenerate form also
      satisfies P1: go-tests.yml, where the declaration IS the trigger key and the
      guard parses it — one file cannot disagree with itself.)

  P2  NO WORKFLOW-LEVEL `paths:` FILTER ON THE CONSUMER'S pull_request ARM.
      A paths-filtered workflow emits NO workflow run and NO check run at all on a
      non-matching head (honest-gates D18), so a required name over it reports
      "is expected." forever and the trigger falls through before the dispatcher
      ever gets a vote. console-harness.yml's pull_request arm has no paths key.
      EVIDENCE MEASURED HERE: `on.pull_request.paths` / `paths-ignore` absent.

  P3  SELF-INCLUSION — the guard sits inside its own target set, so the guard
      cannot be edited without dispatching the harness that proves it. (This also
      explains PR #16870, which edited CONSOLE_PATHS: `Console gate` was ABSENT on
      the first tally and later rendered and passed — the harness genuinely ran
      BECAUSE of self-inclusion. One mechanism, two questions.)
      EVIDENCE MEASURED HERE: the guard's own repo-relative path is matched by the
      set the guard prints.

  ALL THREE, AND A CLEAN DISPATCH CHECK ON EVERY TRIGGER ARM => IMMUNE.
  Any one missing => AT-RISK, and the missing one is NAMED.
  P1 without P2 still fails: a correct list nothing ever consults is not a dispatch.
PAT
}

run_arms() { # label declared_file paths_file — BOTH ARMS, through cover.py
  local label="$1" dfile="$2" pfile="$3" rc out pick
  local AO="${ARMOUT:-/dev/stdout}"
  local red="$TMP/red.txt" grn="$TMP/green.txt"
  cp "$dfile" "$red" || { finding "arms[$label]: could not copy the declared set"; return 1; }
  echo "__undispatched_probe__/**" >>"$red"
  out="$(python3 "$TMP/cover.py" "$red" "$pfile" - 2>/dev/null)"; rc=$?
  case "$out" in
    *"UNDISPATCHED	__undispatched_probe__/**"*)
      echo "  RED   ok — $label: the PLANTED declared-but-undispatched target __undispatched_probe__/** REDS (rc=$rc)" >>"$AO" ;;
    *)
      finding "arms[$label]: RED ARM FAILED — a planted declared-but-undispatched target was NOT flagged (rc=$rc). The checker is not measuring, so every green it prints is vacuous."
      return 1 ;;
  esac
  pick=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$d" >"$grn"
    if python3 "$TMP/cover.py" "$grn" "$pfile" - >/dev/null 2>&1; then pick="$d"; break; fi
  done <"$dfile"
  if [ -z "$pick" ]; then
    finding "arms[$label]: GREEN ARM HAS NO SUBJECT — not one declared alternative is dispatched by this trigger. That is the finding, not a skip."
    return 1
  fi
  echo "  GREEN ok — $label: the correctly-dispatched declared target '$pick' is NOT flagged" >>"$AO"
  ARMS_RUN=$((ARMS_RUN + 1))
  return 0
}

case "${1:-}" in
  --pattern) print_pattern; exit 0 ;;
  --selftest) UDT_SELFTEST=1 ;;
  --list|"") : ;;
  *) echo "usage: $0 [--list|--pattern|--selftest]" >&2; exit 2 ;;
esac

if [ "${UDT_SELFTEST:-0}" = 1 ]; then
  P=0; F=0
  ok() { P=$((P+1)); echo "ok   - $*"; }
  no() { F=$((F+1)); echo "FAIL - $*"; }
  S="$TMP/st"; mkdir -p "$S"

  printf 'web/**\ntemplates/**\n' >"$S/d1.txt"; printf 'web/**\n' >"$S/p1.txt"
  out="$(python3 "$TMP/cover.py" "$S/d1.txt" "$S/p1.txt" - 2>/dev/null)"; rc=$?
  case "$out" in *"UNDISPATCHED	templates/**"*) ok "cover: an undispatched declared alternative is flagged" ;; *) no "cover: templates/** was NOT flagged (rc=$rc, out='$out')" ;; esac
  [ "$rc" = 1 ] && ok "cover: a finding exits 1" || no "cover: expected rc=1 on a finding, got $rc"

  printf 'web/**\n' >"$S/d2.txt"
  out="$(python3 "$TMP/cover.py" "$S/d2.txt" "$S/p1.txt" - 2>/dev/null)"; rc=$?
  { [ -z "$out" ] && [ "$rc" = 0 ]; } && ok "cover: a dispatched declared alternative is not flagged (rc=0, no output)" || no "cover: a dispatched alternative was flagged (rc=$rc, out='$out')"

  : >"$S/d3.txt"
  out="$(python3 "$TMP/cover.py" "$S/d3.txt" "$S/p1.txt" - 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*) [ "$rc" = 2 ] && ok "cover: an EMPTY declared set prints CANNOT READ and exits 2" || no "cover: empty set printed CANNOT READ but exited $rc" ;; *) no "cover: an empty declared set did not refuse (rc=$rc, out='$out')" ;; esac

  out="$(python3 "$TMP/cover.py" "$S/nope.txt" "$S/p1.txt" - 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*) [ "$rc" = 2 ] && ok "cover: an UNREADABLE declared set prints CANNOT READ and exits 2" || no "cover: unreadable set printed CANNOT READ but exited $rc" ;; *) no "cover: an unreadable declared set did not refuse (rc=$rc, out='$out')" ;; esac

  : >"$S/p5.txt"
  out="$(python3 "$TMP/cover.py" "$S/d2.txt" "$S/p5.txt" - 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*) [ "$rc" = 2 ] && ok "cover: an EMPTY trigger list prints CANNOT READ and exits 2" || no "cover: empty trigger list printed CANNOT READ but exited $rc" ;; *) no "cover: an empty trigger list did not refuse (rc=$rc, out='$out')" ;; esac

  printf 'docs/**\n' >"$S/d6.txt"; printf '**\n' >"$S/p6.txt"; printf 'docs/**\n' >"$S/i6.txt"
  out="$(python3 "$TMP/cover.py" "$S/d6.txt" "$S/p6.txt" "$S/i6.txt" 2>/dev/null)"
  case "$out" in *"excluded by paths-ignore"*) ok "cover: a declared target excluded by paths-ignore is flagged" ;; *) no "cover: paths-ignore exclusion not flagged (out='$out')" ;; esac

  out="$(UNDISPATCHED_ROOT="$S/nowhere" bash "$ROOT/$SELF_REL" --list 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*) [ "$rc" = 2 ] && ok "script: a missing workflow directory prints CANNOT READ and exits 2" || no "script: missing dir printed CANNOT READ but exited $rc" ;; *) no "script: a missing workflow directory did not refuse (rc=$rc)" ;; esac

  mkdir -p "$S/empty/.github/workflows" "$S/empty/scripts"
  out="$(UNDISPATCHED_ROOT="$S/empty" bash "$ROOT/$SELF_REL" --list 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*) [ "$rc" = 2 ] && ok "script: an EMPTY workflow directory prints CANNOT READ and exits 2" || no "script: empty dir printed CANNOT READ but exited $rc" ;; *) no "script: an empty workflow directory did not refuse (rc=$rc)" ;; esac

  # a tree with workflows but NO guard script: D1 must refuse, not read as clean
  mkdir -p "$S/noguard/.github/workflows" "$S/noguard/scripts"
  printf 'on:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >"$S/noguard/.github/workflows/x.yml"
  out="$(UNDISPATCHED_ROOT="$S/noguard" bash "$ROOT/$SELF_REL" --list 2>&1)"; rc=$?
  case "$out" in *"CANNOT READ"*"ZERO guard scripts"*) [ "$rc" = 2 ] && ok "script: ZERO derived guards prints CANNOT READ and exits 2" || no "script: zero guards printed CANNOT READ but exited $rc" ;; *) no "script: a tree with zero guard scripts did not refuse (rc=$rc, out='$out')" ;; esac

  # run_arms: the RED arm must actually be able to FAIL (a trigger that matches
  # everything cannot flag the planted target) — a control that cannot fail is
  # not a control.
  ARMS_RUN=0; ARMOUT="$S/arm.txt"; : >"$ARMOUT"
  printf '**\n' >"$S/p7.txt"
  before="$FINDINGS"
  run_arms "SELFTEST negative control" "$S/d2.txt" "$S/p7.txt" >/dev/null 2>&1
  [ "$FINDINGS" -gt "$before" ] && ok "run_arms: the RED arm FAILS LOUDLY when the trigger matches everything (the control can fail)" || no "run_arms: the RED arm passed against a match-everything trigger — it cannot fail, so it proves nothing"
  FINDINGS="$before"; ARMOUT=""

  ARMS_RUN=0; ARMOUT="$S/arm2.txt"; : >"$ARMOUT"
  run_arms "SELFTEST positive control" "$S/d1.txt" "$S/p1.txt" >/dev/null 2>&1
  { grep -q "RED   ok" "$ARMOUT" && grep -q "GREEN ok" "$ARMOUT" && [ "$ARMS_RUN" = 1 ]; } \
    && ok "run_arms: BOTH arms run and are both recorded in one call" || no "run_arms: did not record both arms (ARMS_RUN=$ARMS_RUN)"
  ARMOUT=""

  # THE VERDICT WIRING, graded on the whole program (task-92a213f01ca30817).
  # Every arm above grades cover.py / run_arms IN PROCESS, and the script arms
  # only reach the CANNOT READ refusals; none reaches the audit tail that turns
  # FINDINGS into the process exit, so flipping its `exit 1` to `exit 0` kept
  # this selftest green while CI certified an undispatched target. Same idiom
  # as PR #13405 / #20180: RE-EXEC THE WHOLE PROGRAM on a fixture root and
  # assert the PROCESS exit. The fixture mirrors this tree's workflows
  # and derived guards (so the generator control and the acknowledged block
  # hold exactly as on the real tree); the plant deletes one declared target
  # from ci.yml's push.paths — the exact defect this script exists to find.
  # The fixture is a SYMLINK FARM over this root: the guards derive their own
  # root from their (logical) location and read declaration sources all over
  # the tree, so every top-level entry is linked and only ci.yml is a real,
  # plantable file.
  E2E="$S/e2e"
  mkdir -p "$E2E/.github/workflows"
  for e in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$e" ] || continue
    case "$(basename "$e")" in .github|.git) continue ;; esac
    ln -s "$e" "$E2E/$(basename "$e")"
  done
  for e in "$ROOT"/.github/* "$ROOT"/.github/.[!.]*; do
    [ -e "$e" ] || continue
    [ "$(basename "$e")" = workflows ] && continue
    ln -s "$e" "$E2E/.github/$(basename "$e")"
  done
  for e in "$WF_DIR"/*; do
    [ "$(basename "$e")" = ci.yml ] && continue
    ln -s "$e" "$E2E/.github/workflows/$(basename "$e")"
  done
  grep -vxF '      - "design/tokens.json"' "$WF_DIR/ci.yml" >"$E2E/.github/workflows/ci.yml"
  if cmp -s "$WF_DIR/ci.yml" "$E2E/.github/workflows/ci.yml"; then
    no "whole program: the plant did not apply (ci.yml push.paths carries no design/tokens.json line) — the next arm would be vacuous"
  else
    out="$(UNDISPATCHED_ROOT="$E2E" bash "$E2E/$SELF_REL" 2>&1)"; rc=$?
    case "$out" in
      *"UNDISPATCHED DECLARED TARGET: 'design/tokens.json'"*) [ "$rc" = 1 ] && ok "whole program: a planted undispatched target exits 1, naming it" || no "whole program: the plant was named but the PROCESS exited $rc, not 1" ;;
      *) no "whole program: the planted undispatched target was not named (rc=$rc)" ;;
    esac
  fi
  cp "$WF_DIR/ci.yml" "$E2E/.github/workflows/ci.yml"
  out="$(UNDISPATCHED_ROOT="$E2E" bash "$E2E/$SELF_REL" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && ok "whole program: the plant removed, the PROCESS exits 0" || no "whole program: the plant removed, the PROCESS exited $rc, not 0: $(printf '%s\n' "$out" | grep -E '::error::|CANNOT READ' | head -3)"

  pat="$(print_pattern)"
  for needle in "SINGLE DERIVATION POINT" "NO WORKFLOW-LEVEL" "SELF-INCLUSION" "scripts/console-path-escape-check.sh" "console-harness.yml"; do
    case "$pat" in *"$needle"*) ok "pattern: names '$needle'" ;; *) no "pattern: does NOT name '$needle'" ;; esac
  done

  echo
  echo "selftest: $P passed, $F failed"
  [ "$F" = 0 ] || exit 1
  exit 0
fi

# ── the audit ───────────────────────────────────────────────────────────────
echo "undispatched-target-check — does every DECLARED target actually DISPATCH?"
echo "root: $ROOT"
echo
echo "DERIVATION (shown, never typed)"
echo "  D1 guard scripts carrying a '--match)' case arm ..... $GUARD_N"
sed 's/^/       /' "$TMP/guards.txt"
echo "  D2 guard/consumer joins ............................. $PAIR_N"
awk -F'|' '{printf "       %s  --match %-9s -> %s  (%s)\n", $1, ($2==""?"(default)":$2), $3, $4}' "$TMP/pairs.tsv"
WFARM_N="$(grep -c . "$TMP/arms/wfarms.tsv" 2>/dev/null || echo 0)"
WFP_N="$(cut -f1 "$TMP/arms/wfarms.tsv" 2>/dev/null | sort -u | grep -c . || echo 0)"
echo "  D3 workflows parsed ................................. $WF_COUNT"
echo "     of which carry an on.*.paths/paths-ignore key .... $WFP_N  ($WFARM_N trigger arm(s))"
ROSTER_N="$(grep -c . "$TMP/rosters.txt" 2>/dev/null || echo 0)"
echo "  D4 workflows carrying an in-file roster ............. $ROSTER_N"
sed 's/^/       /' "$TMP/rosters.txt" 2>/dev/null
echo

# ── ACKNOWLEDGED — undispatched targets that are REAL, MEASURED, not yet fixed
# One line per "<workflow> <event>.<key> <declared alternative>". Each becomes a
# ::warning:: instead of an ::error::, so a NEW one still reds. A RATCHET HAS TWO
# FAILURE DIRECTIONS: a line here that this run does NOT measure as undispatched
# also reds, so an exemption cannot outlive the defect it excuses.
#
# ci.yml push.paths templates/** and js/** — MEASURED 2026-09-13 on
# d76ade0b809b7be3c4281da74e8fcdc0b8bfb779 by this script's own dispatch check.
# scripts/web-path-escape-check.sh declares `templates/**` and `js/**` (the
# MAX_HITS lock's scan roots, task-19107773e2c41c5d); ci.yml's on.push.paths
# enumerates the js/ subtrees and omits both. ci.yml's pull_request arm carries
# NO paths key, so THE MERGE GATE IS UNAFFECTED — the hole is the push-to-main
# arm: a merge touching only templates/** or js/docs/** starts no ci.yml run at
# all and the MAX_HITS lock does not re-measure on main. Widening that trigger
# is a workflow-LEVEL edit, outside the fence of the change that added this
# file, so it is DECLARED here rather than silently tolerated.
cat >"$TMP/known.txt" <<'KNOWN'
ci.yml push.paths templates/**
ci.yml push.paths js/**
KNOWN
: >"$TMP/known.seen"

echo "CLASSIFICATION (every entry disposed; the mechanism is named)"
echo
: >"$TMP/entry-report.txt"
: >"$TMP/claimed-wf.txt"

# ---- entries from D2 (guard + consumer) ------------------------------------
# MEASURE FIRST, CLASSIFY AFTER. An entry's class depends on what the dispatch
# check FINDS, so the check runs for EVERY entry — never only for the ones a
# property test already condemned. A classification that decides which entries
# get measured can never be corrected by the measurement.
while IFS='|' read -r g st wfb how; do
  [ -n "$g" ] || continue
  echo "$wfb" >>"$TMP/claimed-wf.txt"
  label="$g --match ${st:-(default)} -> $wfb"
  dfile="$TMP/decl.$(printf '%s' "$g$st" | tr -c 'A-Za-z0-9' '_').txt"
  print_set_into "$g" "$st" "$dfile" \
    || cannot_read "$g --print-set ${st:-} produced an EMPTY declared set (stderr: $(tr '\n' ' ' <"$dfile.err" 2>/dev/null)). An empty set is not zero findings."

  all_arms="$(arms_for "$wfb")"
  pr_key="$(printf '%s\n' "$all_arms" | awk -F'\t' '$1=="pull_request" && $3!="" {print $2; exit}')"
  pr_fn="$(printf '%s\n' "$all_arms" | awk -F'\t' '$1=="pull_request" && $2=="paths" {print $3; exit}')"

  # ── P1 — does the MERGE-GATING surface keep a SECOND copy of the list? ────
  # Evaluated on the pull_request arm, because that is the surface immunity is
  # ABOUT: branch protection never evaluates a push-to-main run. A push-arm copy
  # is a second declaration too, and it IS dispatch-checked below — it simply
  # cannot deadlock or falsely green a MERGE.
  p1="single"
  p1_why="the consumer's pull_request trigger keeps no list of its own; it shells --match and takes the answer"
  if [ -n "$pr_fn" ] && diff -q <(sort -u "$dfile") <(sort -u "$TMP/arms/$pr_fn") >/dev/null 2>&1; then
    p1_why="the declaration IS the pull_request trigger list (byte-identical after sort): one file, so the two cannot diverge"
  elif [ -n "$pr_key" ]; then
    p1="copy"
    p1_why="the consumer's pull_request trigger carries its OWN list that is NOT the set the guard prints — TWO declarations that drift in silence"
  elif [ -n "$all_arms" ]; then
    ident=0
    while IFS="$(printf '\t')" read -r ev key fn; do
      [ -n "$fn" ] && [ "$key" = "paths" ] || continue
      diff -q <(sort -u "$dfile") <(sort -u "$TMP/arms/$fn") >/dev/null 2>&1 && ident=1
    done <<EOF
$all_arms
EOF
    if [ "$ident" = 1 ]; then
      p1_why="the declaration IS the trigger list (byte-identical after sort): the guard parses the workflow's own key, so the two cannot diverge"
    else
      p1_why="the consumer's pull_request trigger keeps no list of its own (a push-arm list exists and is dispatch-checked below; branch protection never evaluates a push run)"
    fi
  fi

  # ── P3 — self-inclusion, through the SAME matcher ────────────────────────
  printf '%s\n' "$g" >"$TMP/self.txt"
  if python3 "$TMP/cover.py" "$TMP/self.txt" "$dfile" - >/dev/null 2>&1; then p3="self"; else p3="no-self"; fi

  # ── the dispatch check + BOTH ARMS, on every trigger arm this consumer has
  ARMOUT="$TMP/entry-report.txt"
  arm_findings=0
  ran=0
  while IFS="$(printf '\t')" read -r ev key fn; do
    [ -n "$fn" ] || continue
    ran=$((ran + 1))
    run_arms "$label @ $wfb $ev.$key" "$dfile" "$TMP/arms/$fn"
    out="$(python3 "$TMP/cover.py" "$dfile" "$TMP/arms/$fn" - 2>"$TMP/cover.err")"; rc=$?
    [ "$rc" = 2 ] && cannot_read "the coverage matcher refused on $label @ $wfb $ev.$key: $(tr '\n' ' ' <"$TMP/cover.err")"
    if [ "$rc" = 1 ]; then
      while IFS="$(printf '\t')" read -r _tag d w why; do
        [ -n "$d" ] || continue
        k="$wfb $ev.$key $d"
        if grep -qxF "$k" "$TMP/known.txt"; then
          echo "$k" >>"$TMP/known.seen"
          echo "::warning::KNOWN UNDISPATCHED DECLARED TARGET (acknowledged; see the ACKNOWLEDGED block in $SELF_REL): '$d' is declared by $label but $wfb's $ev.$key never dispatches on it ($why; witness '$w')." >>"$ARMOUT"
        else
          echo "::error::UNDISPATCHED DECLARED TARGET: '$d' is declared by $label but $wfb's $ev.$key never dispatches on it ($why; witness path '$w'). The job that target was declared for does not run on that head, the aggregate reports green, and no red is emitted anywhere else. Widen $wfb's $ev.$key, or drop the row from the declared set — never leave the two disagreeing." >>"$ARMOUT"
          FINDINGS=$((FINDINGS + 1))
        fi
        arm_findings=$((arm_findings + 1))
      done <<EOF
$out
EOF
    else
      echo "  LIVE  ok — $label @ $wfb $ev.$key: every declared target is dispatched" >>"$ARMOUT"
    fi
  done <<EOF
$all_arms
EOF
  if [ "$ran" = 0 ]; then
    # NO TRIGGER ARM AT ALL — there is no dispatch surface to check. "No
    # surface" must never be byte-identical to "skipped", so the arms still run
    # against this entry's own declared set and the report says what they proved.
    run_arms "$label @ $wfb (no trigger arm)" "$dfile" "$dfile"
    echo "  LIVE  n/a — $label: $wfb carries no on.*.paths key, so nothing can be filtered out at the trigger." >>"$ARMOUT"
  fi
  ARMOUT=""

  if [ "$arm_findings" = 0 ] && [ "$p1" = "single" ] && [ -z "$pr_key" ] && [ "$p3" = "self" ]; then
    classify_line "IMMUNE" "$label" "P1 $p1_why · P2 no on.pull_request.paths on $wfb · P3 the guard is inside its own set · dispatch check clean on $ran trigger arm(s)"
  else
    reasons=""
    [ -n "$pr_key" ] && reasons="P2 FAILS: $wfb carries on.pull_request.$pr_key, so a non-matching head emits NO check run at all (honest-gates D18)"
    [ "$p1" = "copy" ] && reasons="${reasons:+$reasons · }P1 FAILS: $p1_why"
    [ "$p3" = "no-self" ] && reasons="${reasons:+$reasons · }P3 FAILS: $g is not matched by the set it prints, so editing the guard does not dispatch the job that set governs"
    [ "$arm_findings" -gt 0 ] && reasons="${reasons:+$reasons · }DISPATCH CHECK FOUND $arm_findings declared target(s) that never dispatch (named under BOTH ARMS below)"
    classify_line "AT-RISK" "$label" "$reasons"
  fi
done <"$TMP/pairs.tsv"

# ---- entries from D4 (in-workflow roster) ----------------------------------
while IFS= read -r wfb; do
  [ -n "$wfb" ] || continue
  echo "$wfb" >>"$TMP/claimed-wf.txt"
  cite="$(grep -lE 'SUBSET' "$SCRIPT_DIR"/*.test.sh 2>/dev/null | while read -r t; do grep -qF "$wfb" "$t" && echo "scripts/$(basename "$t")"; done | head -1)"
  if [ -n "$cite" ]; then
    classify_line "IMMUNE" "$wfb (in-file roster: target list and consumer in ONE file)" \
      "COVERED BY AN EXISTING CHECK — $cite asserts SUBSET (every roster row names a VERBATIM on.pull_request.paths entry), so a roster target that never dispatches is already a red there. Not re-implemented here."
  else
    classify_line "AT-RISK" "$wfb (in-file roster)" "no scripts/*.test.sh asserts the roster-is-a-subset-of-its-own-paths property for $wfb"
  fi
done <"$TMP/rosters.txt"

# ---- entries from D3 (every remaining workflow carrying a paths: key) ------
sort -u "$TMP/claimed-wf.txt" -o "$TMP/claimed-wf.txt" 2>/dev/null || :
cut -f1 "$TMP/arms/wfarms.tsv" | sort -u >"$TMP/wfp.txt"
: >"$TMP/rest.txt"
REST=0
while IFS= read -r wfb; do
  [ -n "$wfb" ] || continue
  grep -qxF "$wfb" "$TMP/claimed-wf.txt" 2>/dev/null && continue
  REST=$((REST + 1))
  ENTRIES=$((ENTRIES + 1)); IMMUNE=$((IMMUNE + 1))
  echo "IMMUNE|$wfb (no external declaration)" >>"$CLASSES"
  echo "$wfb" >>"$TMP/rest.txt"
done <"$TMP/wfp.txt"
if [ "$REST" -gt 0 ]; then
  printf '%-8s  %d further workflow(s) carrying an on.*.paths key and NO external declaration\n' "IMMUNE" "$REST"
  echo "            MECHANISM: no guard script declares a target set for these and none carries an"
  echo "            in-file roster, so the trigger list is the ONLY declaration of what they dispatch"
  echo "            on — one list cannot disagree with itself, and this hazard needs two. (The other"
  echo "            direction — a declared alternative matching nothing on disk — is"
  echo "            scripts/workflow-trigger-coverage.sh ARM B; the D18 rule that a SHIMMED workflow"
  echo "            must not regain a workflow-level paths: key is scripts/shim-trigger-filter-check.sh.)"
  sort "$TMP/rest.txt" | sed 's/^/              /'
fi

# ── THE GENERATOR IS TESTED AGAINST THE KNOWN-IMMUNE CASE ───────────────────
# Two candidate generators built for the related sweep each missed a known
# instance — one keyed on vocabulary, one structurally. So this one is trusted
# on nothing else until it both FINDS the console pair and CLEARS it.
echo
# THE CONTROL ASSERTS TWO DIFFERENT THINGS AND MUST SAY WHICH ONE BROKE.
# "Was the console pair DERIVED" is a fact about this generator. "Did it
# classify IMMUNE" is a fact about the TREE — the pair goes AT-RISK the moment
# console-harness.yml's own trigger falls behind CONSOLE_PATHS, which is the
# very drift this file exists to find. Both still red, and the pass condition
# below is unchanged; but a run that blames the GENERATOR for a real dispatch
# finding sends its reader to debug the instrument instead of the tree. That
# misdiagnosis cost this check hours of being read as broken-and-unownable
# while it was reporting correctly. So: name the direction.
ccls="$(awk -F'|' '$2 ~ /console-path-escape-check.sh/ && $2 ~ /console-harness.yml/ {print $1; exit}' "$CLASSES")"
if [ "$ccls" = "IMMUNE" ]; then
  echo "GENERATOR CONTROL: the known-immune console pair was derived AND classified IMMUNE by this run."
elif [ -z "$ccls" ]; then
  finding "GENERATOR CONTROL FAILED — THE GENERATOR: the known-immune pair (scripts/console-path-escape-check.sh -> console-harness.yml) is ABSENT FROM THE DERIVATION. D1/D2 stopped seeing a pair that is still in the tree, so this run's output is not trustable on any other entry: an entry the generator never derived cannot be classified, and a derivation that silently shrank reads exactly like a clean tree."
elif grep -q '^::error::UNDISPATCHED DECLARED TARGET.*console-path-escape-check\.sh' "$TMP/entry-report.txt" 2>/dev/null; then
  finding "GENERATOR CONTROL FAILED — THE TREE, NOT THE GENERATOR: the console pair WAS derived and its P1/P2/P3 properties were evaluated; it classified '$ccls' because the dispatch check found REAL undispatched declared targets on it, named as ::error::UNDISPATCHED lines above. Those lines are MEASURED, and the both-arm controls for this entry ran and held in this same run — read them and fix console-harness.yml's trigger (or drop the rows from CONSOLE_PATHS). Do NOT debug this script: it is reporting, not failing."
else
  finding "GENERATOR CONTROL FAILED — A PROPERTY: the known-immune pair (scripts/console-path-escape-check.sh -> console-harness.yml) classified '$ccls', not IMMUNE, and NOT because of a dispatch finding — one of P1/P2/P3 no longer holds (the failing property is NAMED on the entry's own line above). Either the pair genuinely stopped being immune, or the property test broke; this run's output is not trustable on any other entry until that is settled."
fi

echo
echo "DISPOSITIONS: $ENTRIES entries — $IMMUNE IMMUNE, $ATRISK AT-RISK. Every entry above carries its mechanism."
echo
echo "BOTH ARMS (a planted undispatched target MUST red; a dispatched one MUST NOT be flagged)"
echo
cat "$TMP/entry-report.txt"
if [ "$ATRISK" = 0 ]; then
  echo
  echo "  NO AT-RISK ENTRY. That ABSENCE is the RESULT of the enumeration above"
  echo "  ($ENTRIES entries, every one classified IMMUNE with its mechanism named) — it is"
  echo "  not an assumption and it is not a skip. The checker is still proven live on a"
  echo "  SYNTHETIC at-risk entry, so a clean tree can never be byte-identical to a checker"
  echo "  that quietly stopped working:"
  printf 'web/**\ntemplates/**\n' >"$TMP/syn.d.txt"
  printf 'web/**\n' >"$TMP/syn.p.txt"
  run_arms "SYNTHETIC control" "$TMP/syn.d.txt" "$TMP/syn.p.txt"
fi

echo
# A ratchet has two failure directions: an acknowledged entry that is no longer
# undispatched must be DELETED, or the block rots into a standing licence.
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -qxF "$k" "$TMP/known.seen" 2>/dev/null && continue
  finding "STALE ACKNOWLEDGEMENT: '$k' is listed in the ACKNOWLEDGED block of $SELF_REL but this run did NOT measure it as undispatched. Either the trigger was widened (delete the line) or the derivation stopped seeing the entry (fix the derivation). An exemption that outlives its defect is a licence."
done <"$TMP/known.txt"

# COVERAGE IS ASSERTED. A checker over zero entries reports success.
[ "$ENTRIES" -gt 0 ] || cannot_read "classified ZERO entries. A checker over no input is not a clean tree."
[ "$ARMS_RUN" -gt 0 ] || cannot_read "ran ZERO both-arm control pairs. Both arms must run in every run."
echo "COVERAGE: $ENTRIES entries classified; $ARMS_RUN both-arm control pair(s) run in THIS run."
echo
print_pattern
echo

if [ "$FINDINGS" -gt 0 ]; then
  echo "FINDINGS: $FINDINGS. A declared target that never dispatches emits no red of its own — these lines are the only ones."
  exit 1
fi
echo "OK: $ENTRIES entries classified ($IMMUNE IMMUNE, $ATRISK AT-RISK); every declared target of every entry dispatches on every trigger arm its consumer carries, and both control arms held in $ARMS_RUN pair(s)."
exit 0
