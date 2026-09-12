#!/usr/bin/env bash
# deploy-supersede-exit.test.sh — the harness for task-01f48337d83a0d15:
# ".github/workflows/deploy.yml must let a SUPERSEDED (production) run exit at
# its START, before any remote box mutation, when a newer main-ancestry sha is
# already in flight — never by cancelling, never touching the newest run."
#
# TWO SUBJECTS, because the change has two halves:
#
# PART A — scripts/deploy-supersede-exit.sh, the ancestry classifier. Its own
#   --selftest is the full matrix (both directions, ancestry-beats-created-at,
#   the fail-open cases). This file RUNS that selftest AND then MUTATES a scratch
#   copy of the script to prove the two load-bearing guards are not vacuous:
#     * gut the supersession decision -> the fixture that MUST skip no longer
#       returns the superseded code (criterion 1's gate).
#     * swap the ancestry test for a created-at comparison -> the
#       ancestry-beats-time fixture flips (criterion 2).
#
# PART B — the WIRING in .github/workflows/deploy.yml, extracted with a YAML
#   parser (never copied, so this measures what ships). It proves:
#     * the exit is in the `changes` job, strictly UPSTREAM of the scp/ssh steps
#       (criterion 1);
#     * the superseded branch SKIPS both deploy jobs and exits 0 — never FAILED
#       (criterion 3), and a real mutation to `exit 1` reds the arm;
#     * report-deploy-failure keeps `failure()` and needs both deploy jobs, so a
#       superseded (green, skipped-legs) run is NOT counted, while a newer run
#       that dies at Setup/Fetch deps IS reported (criteria 3 + 4);
#     * the convergence (deploy_stalled) reader is gated on a deploy leg having
#       SUCCEEDED, so it too ignores a superseded run (criterion 3);
#     * concurrency stays `cancel-in-progress: false` and nothing runs
#       `gh run cancel` — the exit is at START only (criterion 5 / D12).
#
# Nothing here reaches the network, a credential, or a box.
#
# EXIT CODES
#   0  every case passed
#   1  at least one case FAILED
#   2  the harness could not run
set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
SUBJECT="$REPO_ROOT/scripts/deploy-supersede-exit.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/deploy.yml"

command -v python3 >/dev/null || { echo "HARNESS-UNAVAILABLE: no python3" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "HARNESS-UNAVAILABLE: no PyYAML" >&2; exit 2; }
command -v git >/dev/null || { echo "HARNESS-UNAVAILABLE: no git" >&2; exit 2; }
[ -f "$SUBJECT" ]  || { echo "HARNESS-UNAVAILABLE: $SUBJECT missing" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "HARNESS-UNAVAILABLE: $WORKFLOW missing" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A real 3-commit repo A<-B<-C for the direct decide arms below.
REPO="$TMP/repo"; mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m A
  git commit -q --allow-empty -m B
  git commit -q --allow-empty -m C
  git log --format='%H' --reverse | tr '\n' ' ' > "$TMP/shas"
)
read -r A B C _ < "$TMP/shas"

# decide against a script (or a scratch copy); rc captured WITHOUT a pipe.
decide_rc() { # script want name our-run our-sha fixture-file
  local script="$1" want="$2" name="$3" run="$4" sha="$5" fixture="$6" got=0
  bash "$script" decide --our-run-id "$run" --our-sha "$sha" --git-dir "$REPO" \
      < "$fixture" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else bad "$name — wanted rc=$want got rc=$got"; fi
}

echo "PART A — the ancestry classifier"

# A0: the subject's own full matrix.
if bash "$SUBJECT" --selftest >/dev/null 2>&1; then
  ok "A0 deploy-supersede-exit.sh --selftest is green (full decide matrix)"
else
  bad "A0 deploy-supersede-exit.sh --selftest FAILED"
fi

# Fixtures: our run 100 carries A; candidate run 200 carries C (a descendant),
# created EARLIER than our run — so a created-at rule would reach the WRONG
# answer and only ancestry gets it right.
printf '200 %s in_progress 2000-01-01T00:00:00Z\n' "$C" > "$TMP/superseded"

decide_rc "$SUBJECT" 3 "A1 our older sha superseded by an in-flight descendant" 100 "$A" "$TMP/superseded"

printf '400 %s in_progress 2099-01-01T00:00:00Z\n' "$A" > "$TMP/newest"
decide_rc "$SUBJECT" 0 "A2 our newest sha is not superseded by an in-flight ancestor" 300 "$C" "$TMP/newest"

# ── A3: MUTATION — gut the supersession decision (criterion 1's gate) ────────
# Replace the branch that RECORDS a superseding run with a no-op, so the decider
# can never return the superseded code. old gate green (A1), new gate red here.
MUT_GATE="$TMP/mut-gate.sh"
sed 's/^\([[:space:]]*\)superseded_by_run="\$id"; superseded_by_sha="\$full"; break ;;/\1: ;;/' \
  "$SUBJECT" > "$MUT_GATE"
if cmp -s "$SUBJECT" "$MUT_GATE"; then
  bad "A3 mutation changed nothing — the gate is anchored on text the script no longer contains"
else
  decide_rc "$MUT_GATE" 0 "A3 gutting the supersession gate stops the skip (was 3, now 0)" 100 "$A" "$TMP/superseded"
fi

# ── A4: MUTATION — decide by CREATED-AT instead of ancestry (criterion 2) ────
# Force the ancestry verdict to depend on created-at text order, not the commit
# graph. On the A1 fixture the real subject returns 3 by ancestry; a created-at
# rule would return 0. Assert the mutant no longer returns 3.
MUT_TIME_SH="$TMP/mut-time.sh"
python3 - "$SUBJECT" "$MUT_TIME_SH" > "$TMP/muttime.log" 2>&1 <<'PY' || { echo "HARNESS-UNAVAILABLE: could not build the created-at mutant" >&2; exit 2; }
import sys
src, out = sys.argv[1], sys.argv[2]
t = open(src).read()
needle = 'is_ancestor "$our_full" "$full" || rc=$?'
assert needle in t, "anchor for the ancestry mutation is gone"
t = t.replace(needle, 'if [ -n "$created" ] && [ -z "$created" ]; then rc=0; else rc=1; fi  # MUT: created-at, not ancestry')
open(out, "w").write(t)
PY
decide_rc "$MUT_TIME_SH" 0 "A4 deciding by created-at (not ancestry) drops the skip our A1 fixture needs" 100 "$A" "$TMP/superseded"

echo ""
echo "PART B — the wiring in .github/workflows/deploy.yml"

# ── One portable python probe emits every fact as KEY=VALUE (no heredoc inside
#    $(), no multi-line awk — both are bash-3.2 traps). It also builds the FAIL
#    mutant in-memory and reports the mutant's superseded-branch exit, so B4 is
#    proven for real.
PROBE="$TMP/probe.py"
cat > "$PROBE" <<'PY'
import sys, re, yaml
wf = sys.argv[1]
text = open(wf).read()
d = yaml.safe_load(open(wf))

def emit(k, v): print("%s=%s" % (k, v))

ch = d["jobs"]["changes"]
fstep = [s for s in ch["steps"] if s.get("id") == "f"]
if len(fstep) != 1:
    emit("PROBE_ERR", "expected one changes step id=f, found %d" % len(fstep)); sys.exit(0)
body = fstep[0]["run"]

emit("B1_CALL", int("deploy-supersede-exit.sh decide" in body))
emit("B1B_ARGS", int('--our-run-id "$GITHUB_RUN_ID" --our-sha "$GITHUB_SHA"' in body))

def needs(j):
    n = d["jobs"][j].get("needs", [])
    return [n] if isinstance(n, str) else list(n)

# Command tokens must be judged over EXECUTABLE lines, not comment prose — this
# harness's own subject-describing comments say "ssh" and "gh run cancel", and a
# naive substring scan would read those as commands.
def code_only(s):
    return "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("#"))

cp_up = "changes" in needs("control-plane")
in_up = "changes" in needs("instance")
changes_code = code_only("\n".join(str(s.get("run", "")) for s in ch["steps"]))
no_scp = not any(tok in changes_code for tok in ["$SCP ", "$SSH ", "scp ", "ssh "])
cp_run = "\n".join(str(s.get("run", "")) for s in d["jobs"]["control-plane"]["steps"])
scp_down = "$SCP " in cp_run and "$SSH " in cp_run
emit("UPSTREAM", "OK" if (cp_up and in_up and no_scp and scp_down) else "NO")

emit("B3A", int('echo "cp=false" >> "$GITHUB_OUTPUT"' in body))
emit("B3B", int('echo "instance=false" >> "$GITHUB_OUTPUT"' in body))

def super_exit(b):
    inb = False
    for ln in b.splitlines():
        if 'if [ "$super_rc" -eq 3 ]; then' in ln:
            inb = True
        if inb:
            m = re.match(r'\s*(exit \d+)\s*$', ln)
            if m:
                return m.group(1)
    return ""
emit("SUPER_EXIT", super_exit(body))

# FAIL mutant: flip the superseded branch's first `exit 0` to `exit 1`.
mut = re.sub(r'(if \[ "\$super_rc" -eq 3 \]; then[\s\S]*?)\n(\s*)exit 0\b',
             r'\1\n\2exit 1', text, count=1)
try:
    dm = yaml.safe_load(mut)
    mbody = [s for s in dm["jobs"]["changes"]["steps"] if s.get("id") == "f"][0]["run"]
    emit("SUPER_EXIT_MUT", super_exit(mbody))
except Exception as e:
    emit("SUPER_EXIT_MUT", "PARSE_ERR:%s" % e)

emit("RDF_IF", " ".join(str(d["jobs"]["report-deploy-failure"]["if"]).split()))
rn = d["jobs"]["report-deploy-failure"].get("needs", [])
emit("RDF_NEEDS", " ".join([rn] if isinstance(rn, str) else rn))
emit("CONV_IF", " ".join(str(d["jobs"]["convergence"]["if"]).split()))
emit("CIP", d.get("concurrency", {}).get("cancel-in-progress"))
emit("BODY_CANCEL", int("gh run cancel" in code_only(body)))
PY

FACTS="$TMP/facts"
python3 "$PROBE" "$WORKFLOW" > "$FACTS" 2>"$TMP/probe.err" || {
  echo "HARNESS-UNAVAILABLE: probe failed:" >&2; cat "$TMP/probe.err" >&2; exit 2; }
if grep -q '^PROBE_ERR=' "$FACTS"; then
  echo "HARNESS-UNAVAILABLE: $(sed -n 's/^PROBE_ERR=//p' "$FACTS")" >&2; exit 2
fi

# read one fact's value (everything after the first '=').
fact() { sed -n "s/^$1=//p" "$FACTS" | head -1; }

# B1 (criterion 1): the step calls the ancestry classifier at START.
[ "$(fact B1_CALL)" = "1" ]  && ok "B1 the changes step calls deploy-supersede-exit.sh decide" \
                             || bad "B1 the changes step does not call deploy-supersede-exit.sh decide"
[ "$(fact B1B_ARGS)" = "1" ] && ok "B1b it passes our run id and sha" \
                             || bad "B1b it does not pass --our-run-id/--our-sha"

# B2 (criterion 1): the exit is STRICTLY UPSTREAM of the scp/ssh (they live only
# in the deploy jobs, which need `changes`).
[ "$(fact UPSTREAM)" = "OK" ] && ok "B2 changes (holding the exit) is upstream of the scp/ssh, which live only in the deploy jobs" \
                              || bad "B2 the exit is not strictly upstream of the remote step (got '$(fact UPSTREAM)')"

# B3 (criterion 3): the superseded branch SKIPS both deploy jobs and exits 0.
[ "$(fact B3A)" = "1" ] && ok "B3a superseded branch sets cp=false"       || bad "B3a superseded branch does not set cp=false"
[ "$(fact B3B)" = "1" ] && ok "B3b superseded branch sets instance=false" || bad "B3b superseded branch does not set instance=false"

SUPER_EXIT="$(fact SUPER_EXIT)"
case "$SUPER_EXIT" in
  "exit 0") ok "B3c the superseded branch exits 0 — never FAILED ($SUPER_EXIT)" ;;
  "")       bad "B3c could not find the exit in the superseded branch" ;;
  *)        bad "B3c the superseded branch exits non-zero ('$SUPER_EXIT') — a superseded run must never FAIL" ;;
esac

# ── B4: MUTATION — the FAIL mutant flips B3c red ─────────────────────────────
SUPER_EXIT_MUT="$(fact SUPER_EXIT_MUT)"
[ "$SUPER_EXIT_MUT" = "exit 1" ] && ok "B4 the FAIL mutant is what B3c rejects — B3c is not vacuous (mutant exits '$SUPER_EXIT_MUT')" \
                                 || bad "B4 could not produce the FAIL mutant (got '$SUPER_EXIT_MUT') — B3c cannot be shown to discriminate"

# ── report-deploy-failure: ignores a superseded run, catches a real early death
RDF_IF="$(fact RDF_IF)"
RDF_NEEDS="$(fact RDF_NEEDS)"
if [[ "$RDF_IF" == *"failure()"* ]]; then
  ok "B5 report-deploy-failure fires on failure() — a superseded (green) run is not counted"
else
  bad "B5 report-deploy-failure no longer keys on failure(): '$RDF_IF'"
fi
if [[ "$RDF_IF" == *"always()"* ]]; then
  bad "B5b report-deploy-failure uses always() — it would fire on a superseded run too"
else
  ok "B5b report-deploy-failure does not use always()"
fi
if [[ " $RDF_NEEDS " == *" control-plane "* && " $RDF_NEEDS " == *" instance "* ]]; then
  ok "B6 report-deploy-failure needs both control-plane and instance — an early death in either is reported"
else
  bad "B6 report-deploy-failure does not need both deploy jobs: $RDF_NEEDS"
fi

# ── B7 (criterion 3): the convergence (deploy_stalled) reader is gated on a
#    deploy leg SUCCEEDING; a superseded run skips both, so it never reaches
#    convergence or report-convergence-failure.
CONV_IF="$(fact CONV_IF)"
if [[ "$CONV_IF" == *"needs.control-plane.result == 'success'"* \
   || "$CONV_IF" == *"needs.instance.result == 'success'"* ]]; then
  ok "B7 convergence is gated on a deploy leg SUCCEEDING — a superseded run (both legs skipped) does not reach it"
else
  bad "B7 convergence no longer requires a successful deploy leg: '$CONV_IF'"
fi

# ── B8 (criterion 5 / D12): exit at START only — no cancel, cancel-in-progress
#    stays false.
CIP="$(fact CIP)"
[ "$CIP" = "False" ] && ok "B8 concurrency keeps cancel-in-progress: false (never-cancel)" \
                     || bad "B8 concurrency.cancel-in-progress is '$CIP', not false — D12 at risk"
[ "$(fact BODY_CANCEL)" = "0" ] && ok "B8b the changes step never runs 'gh run cancel'" \
                                || bad "B8b the changes step runs 'gh run cancel' — the exit must be at START, never a cancel"

echo ""
printf 'deploy-supersede-exit.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$PASS" -eq 0 ]; then
  echo "HARNESS-UNAVAILABLE: zero cases ran — a green over an empty matrix is not a verdict" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ] || exit 1
