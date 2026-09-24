#!/usr/bin/env bash
# shell-harnesses-dispatch.test.sh — the partition guard and fixture matrix for
# the `changes` dispatcher in .github/workflows/shell-harnesses.yml.
#
# THE DEFECT IT GUARDS. That workflow's `paths:` list is an OR over the inputs
# of ~30 unrelated harness jobs. Measured on PR #15631 (three files, all under
# cloud/lib/): 55 check runs, 28 from this one workflow, 27 of them measuring
# nothing. The dispatcher partitions the list per job so a PR runs only the
# harnesses whose inputs it touched. A partition is two lists that must agree —
# the workflow-level list and the roster — and nothing else makes them, so:
#
#   A  SUBSET   every roster row names a verbatim on.pull_request.paths entry
#   B  UNION    every on.pull_request.paths entry has a roster row (the
#               workflow file itself is in every set implicitly and is exempt)
#   C  GATING   every job under jobs: except `changes` carries
#               `needs: [changes]` and `if: needs.changes.outputs.<id> == 'true'`
#   D  OUTPUTS  every gated job has ≥1 roster row AND an entry in the changes
#               job's `outputs:` map — a gate on an undeclared output is a
#               silent false (the expression is empty, never 'true')
#   E  FIXTURES the dispatcher's `run:` body is EXTRACTED (yaml-parsed, GitHub
#               expressions substituted, leftovers refused) and run over mktemp
#               git repos: push → all true; empty diff → all true; the measured
#               router.ex change → cloud-static-gz ONLY; a cloud/lib file no set
#               names → all false; a new workflow file → exactly the seven
#               corpus readers; the workflow file itself → all true; an
#               unresolvable base → exit 1 with the named refusal
#   F  MUTATION the `# MUT: unresolvable-base` line is deleted from a scratch
#               copy (anchor matched EXACTLY ONCE, diff non-empty) and the named
#               refusal must DISAPPEAR — a mutation the harness cannot see is
#               not a catch
#   G  ARM NAME  every leg arm whose `run` invokes `--axis`/`--check-alloc` is
#               NAMED for exactly the set it runs. Both sides come from the same
#               regex over the same JSON (comments stripped from the body), so a
#               new axis added to a loop alone reds here; mutation-proved by
#               adding a fifth axis `q` to one loop in a scratch copy
#   H  FALLBACK the `sets` step's REAL body is run over two staged repos — a
#               head WITHOUT scripts/shell-harness-dispatch.sh (the base's copy
#               must run, exit 0) and a head WITH its own (the head's copy must
#               run). Both preconditions asserted before either verdict. This
#               is the exit-127 that took every harness leg dark on 42 PRs
#               (task-ecb7fc56b5868bfc)
#
# bash 3.2 compatible (macOS runs it too): no associative arrays, no mapfile.
# python3 + PyYAML are the only unstubbed dependencies; their absence is exit 2
# HARNESS-UNAVAILABLE, never a pass.
#
# EXIT CODES: 0 all assertions pass · 1 at least one failed · 2 cannot measure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${SHELL_HARNESSES_WORKFLOW:-$REPO_ROOT/.github/workflows/shell-harnesses.yml}"
SELF_ENTRY=".github/workflows/shell-harnesses.yml"
# THE DISPATCHER MOVED OUT OF THE WORKFLOW (task-ca50ed283930706a). The
# `changes` step's body is now a file, because an interpolated `run:` scalar is
# compiled into ONE expression and capped at 21000 chars. That file inherits
# the workflow file's property exactly: an edit to it changes what every
# harness means, so it is implicit in every set, must NOT be a roster row, and
# must be an on.*.paths entry or an edit to it starts no run at all. Both
# entries are exempt from clause B for the same reason.
SELF_SCRIPT="scripts/shell-harness-dispatch.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
unavailable() { echo "HARNESS-UNAVAILABLE: $*" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || unavailable "python3 is required (the workflow is yaml-parsed)"
python3 -c 'import yaml' 2>/dev/null || unavailable "PyYAML is required (pip3 install pyyaml)"
[ -f "$WORKFLOW" ] || unavailable "workflow not found: $WORKFLOW"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shd.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── extraction (one python pass, several plain-text products) ───────────────
# Products: paths.txt (on.pull_request.paths, one per line), jobs.txt (job id,
# then needs-ok/if-ok flags), outputs.txt (keys of jobs.changes.outputs),
# body.sh (the dispatcher step with expressions substituted).
if ! python3 - "$WORKFLOW" "$TMP" <<'PY'
import json, os, re, sys, yaml
wf, out = sys.argv[1], sys.argv[2]
with open(wf) as fh:
    doc = yaml.safe_load(fh)
on = doc.get(True) or doc.get("on")  # PyYAML reads a bare `on:` key as True
paths = on["pull_request"]["paths"]
if not paths:
    sys.stderr.write("on.pull_request.paths is empty\n"); sys.exit(2)
with open(out + "/paths.txt", "w") as fh:
    fh.write("\n".join(paths) + "\n")
jobs = doc["jobs"]
if "changes" not in jobs:
    sys.stderr.write("no jobs.changes\n"); sys.exit(2)
# THE GATED UNIT IS A MATRIX LEG, NOT A JOB (matrix collapse, 2026-09-17).
# The 53 sibling jobs each gated by `if: needs.changes.outputs.<jid> == 'true'`
# are now ONE `harness` job fanning out over the legs in
# .github/shell-harness-legs.json. Clauses C and D are unchanged in what they
# assert — every dispatched unit has a roster row and a declared output, and
# nothing is dispatched that the roster does not name — but the unit they
# iterate is now the leg slug. jobs.txt keeps its `<id> <needs-ok> <if-ok>`
# shape so the arms below did not have to move.
#
# The `harness` job's OWN shape is checked here rather than per-leg, because it
# is the single point where a whole collapse can go wrong:
#   · it must `needs: [changes]`
#   · it must be gated on `needs.changes.outputs.any == 'true'` and NOT on the
#     matrix being non-empty — an empty `strategy.matrix` DELETES the job
#     instead of skipping it, and a job that renders no check run at all is
#     indistinguishable from a workflow that never started
#   · it must carry an explicit `name:` template, or GitHub auto-suffixes every
#     leg's check-run name with `(leg)` and renames 53 checks at once
job_ids = sorted(k for k in jobs if k != "changes")
if job_ids != ["harness"]:
    sys.stderr.write("expected exactly one non-dispatcher job `harness`, got: %s\n" % ", ".join(job_ids))
    sys.exit(2)
h = jobs["harness"]
hneeds = h.get("needs")
if isinstance(hneeds, str):
    hneeds = [hneeds]
if not hneeds or "changes" not in hneeds:
    sys.stderr.write("jobs.harness does not `needs: [changes]`\n"); sys.exit(2)
if str(h.get("if", "")).strip() != "needs.changes.outputs.any == 'true'":
    sys.stderr.write("jobs.harness must be gated on needs.changes.outputs.any == 'true' "
                     "(an empty matrix deletes the job rather than skipping it); got %r\n"
                     % h.get("if"))
    sys.exit(2)
if str(h.get("name", "")).strip() != "${{ matrix.leg.name }}":
    sys.stderr.write("jobs.harness must carry name: ${{ matrix.leg.name }} — without an explicit "
                     "name template GitHub renames every leg's check run; got %r\n" % h.get("name"))
    sys.exit(2)
if (h.get("strategy") or {}).get("fail-fast") is not False:
    sys.stderr.write("jobs.harness must set strategy.fail-fast: false — a cancelled sibling "
                     "harness reports nothing and reads as 'did not run'\n")
    sys.exit(2)

legs_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(wf))),
                         "shell-harness-legs.json")
try:
    legs = json.load(open(legs_path))
except Exception as exc:
    sys.stderr.write("cannot read %s: %s\n" % (legs_path, exc)); sys.exit(2)
if not isinstance(legs, list) or not legs:
    sys.stderr.write("%s must be a non-empty list\n" % legs_path); sys.exit(2)
slugs = [l["slug"] for l in legs]
if len(set(slugs)) != len(slugs):
    sys.stderr.write("duplicate leg slug in %s\n" % legs_path); sys.exit(2)
for l in legs:
    if not (l.get("arms") or []):
        sys.stderr.write("leg %r carries ZERO arms — it would report a green over nothing\n"
                         % l["slug"])
        sys.exit(2)
with open(out + "/jobs.txt", "w") as fh:
    for slug in slugs:
        # Every leg is gated identically, by construction: the dispatcher emits
        # the matrix from exactly these slugs' verdicts, so needs/if are 1/1 and
        # what clauses C and D actually measure is the roster/outputs agreement.
        fh.write("%s 1 1\n" % slug)
outputs = jobs["changes"].get("outputs") or {}
# `matrix` and `any` are the collapse's own plumbing, not harness gates; clause
# D's "an output with no job" arm would otherwise read them as orphans.
outputs = dict((k, v) for k, v in outputs.items() if k not in ("matrix", "any"))
with open(out + "/outputs.txt", "w") as fh:
    for k, v in outputs.items():
        fh.write("%s %s\n" % (k, v))
steps = jobs["changes"]["steps"]
hit = [s for s in steps if s.get("id") == "sets"]
if len(hit) != 1:
    sys.stderr.write("expected exactly one step with id sets, got %d\n" % len(hit)); sys.exit(2)
step = hit[0]
run = step["run"]

# THE BODY IS A FILE NOW, AND THAT IS THE POINT (task-ca50ed283930706a).
# The dispatcher body used to be this scalar. With the two `${{ }}` values
# inline GitHub compiled the whole thing into ONE expression against a
# 21000-char cap, and at 19968 bytes the roster had 32 bytes of headroom — a
# cap deciding dispatch policy, and over it a STARTUP FAILURE with zero jobs.
# So THREE things are asserted here, and each one of them failing would put the
# bomb back:
#   · the scalar carries NO `${{` at all (it is a literal, never an expression)
#   · the two GitHub values arrive as step `env:` under the names the script
#     reads, or the script sees an empty event and an empty base
#   · the scalar is a THIN WRAPPER around a script under scripts/, whose path is
#     READ FROM HERE rather than hardcoded, so the clauses below measure
#     whatever the workflow actually runs. It used to have to be ONE LINE. It no
#     longer can be: the checkout is the PR HEAD while this file comes from the
#     merge ref, so a head that predates the script's own creation commit ran
#     the bare line into `No such file or directory`, exit 127, and took every
#     harness leg dark with it (run 35517160933, task-ecb7fc56b5868bfc). The
#     body therefore carries an absent-file fallback, and THAT is now asserted
#     instead: one script path, a preamble small enough to read, an existence
#     test, and a recovery that does not read the head tree.
if "${{" in run:
    sys.stderr.write("the `sets` step's run: scalar carries a ${{ }} expression, so GitHub compiles it "
                     "into ONE expression under the 21000-char cap. Keep the body in a script file.\n")
    sys.exit(2)
env = step.get("env") or {}
want_env = {"EVENT_NAME": "${{ github.event_name }}",
            "BASE_SHA": "${{ github.event.pull_request.base.sha }}"}
for k, v in want_env.items():
    if str(env.get(k, "")).strip() != v:
        sys.stderr.write("the `sets` step must pass %s: %s as step env (got %r) — the script reads it "
                         "from the environment\n" % (k, v, env.get(k)))
        sys.exit(2)
paths = sorted(set(re.findall(r"(scripts/[A-Za-z0-9._/-]+\.sh)", run)))
if len(paths) != 1 or len(run.strip().splitlines()) > 24:
    sys.stderr.write("the `sets` step must be a thin wrapper around exactly ONE script under "
                     "scripts/ (found %r, %d line(s)); got %r\n"
                     % (paths, len(run.strip().splitlines()), run))
    sys.exit(2)
if not (re.search(r"(?:\[\[?[ \t]+|\btest[ \t]+)-[efxrs][ \t]", run)
        and re.search(r"\bgit[ \t]+(?:show|fetch|cat-file)\b", run)):
    sys.stderr.write("the `sets` step has NO absent-file fallback: a PR head whose merge base "
                     "predates the dispatcher's creation commit has this `run:` line and not the "
                     "file, so the step exits 127 and every harness leg goes ABSENT. Test for the "
                     "file and read the base's copy when it is missing.\n")
    sys.exit(2)
script_rel = paths[0]
script_abs = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(wf))), "..", script_rel)
script_abs = os.path.normpath(script_abs)
if not os.path.isfile(script_abs):
    sys.stderr.write("the `sets` step invokes %s, which does not exist\n" % script_rel); sys.exit(2)
with open(out + "/dispatcher-path.txt", "w") as fh:
    fh.write(script_rel + "\n")
with open(out + "/body.sh", "w") as fh:
    fh.write(open(script_abs).read())
PY
then
  unavailable "could not extract the dispatcher from $WORKFLOW (unparseable, or the shape moved)"
fi

BODY="$TMP/body.sh"
# The body is now a FILE the step invokes, and bash does not expand `${{ }}`:
# one in EXECUTABLE code would be a literal string, silently comparing a path
# against markup. Comment lines are exempt — this file's own header explains
# the expression cap, and counting prose would make the guard agree with
# itself. The scalar's freedom from `${{` is asserted in the extractor above,
# which is where the 21000-char cap actually applies.
if grep -v '^[[:space:]]*#' "$BODY" | grep -q '\${{'; then
  echo "a GitHub expression survives in EXECUTABLE lines of the dispatcher body:" >&2
  grep -n '\${{' "$BODY" | grep -v ':[[:space:]]*#' >&2
  unavailable "the dispatcher must read its GitHub values from the environment, never inline"
fi

# The roster: rows between roster=' and the closing quote, as the dispatcher
# reads them. Extracted from the SAME body the fixtures run.
awk '/^roster=\x27$/ { on = 1; next } on && /^\x27$/ { exit } on && NF { print $1, $2 }' "$BODY" >"$TMP/roster.txt"
ROWS=$(wc -l <"$TMP/roster.txt" | tr -d ' ')
[ "$ROWS" -gt 0 ] || unavailable "the roster came out empty — the extraction anchors no longer match"
awk '{ print $1 }' "$TMP/roster.txt" | awk '!seen[$0]++' >"$TMP/roster-jobs.txt"

N_PATHS=$(wc -l <"$TMP/paths.txt" | tr -d ' ')
N_JOBS=$(wc -l <"$TMP/jobs.txt" | tr -d ' ')
echo "── shell-harnesses dispatcher: $N_PATHS workflow paths, $ROWS roster rows, $N_JOBS dispatched legs ──"

# ── A: SUBSET ────────────────────────────────────────────────────────────────
missing_up=""
while read -r job pat; do
  grep -qxF -- "$pat" "$TMP/paths.txt" || missing_up="$missing_up $job:$pat"
done <"$TMP/roster.txt"
if [ -z "$missing_up" ]; then ok "A subset: every roster row is a verbatim on.pull_request.paths entry"
else bad "A subset: roster rows naming paths the workflow never triggers on:$missing_up"; fi

implicit_rows=""
for e in "$SELF_ENTRY" "$SELF_SCRIPT"; do
  grep -q "^[^ ]* $e\$" "$TMP/roster.txt" && implicit_rows="$implicit_rows $e"
done
if [ -z "$implicit_rows" ]; then ok "A: neither the workflow file nor the dispatcher script is a roster row (both are implicit in every set)"
else bad "A: implicit-in-every-set entries that are ALSO roster rows:$implicit_rows"; fi

# A2: and the dispatcher path the workflow actually invokes is the one this
# harness exempts. Without this the exemption could drift onto a dead path
# while the real script silently acquired no trigger at all.
DISPATCHER="$(cat "$TMP/dispatcher-path.txt" 2>/dev/null)"
if [ "$DISPATCHER" = "$SELF_SCRIPT" ]; then
  ok "A2: the changes step invokes $DISPATCHER, the path this harness exempts and runs"
else bad "A2: the changes step invokes '$DISPATCHER' but this harness exempts '$SELF_SCRIPT'"; fi

# A3: both implicit entries are on.pull_request.paths entries. Implicit in
# every SET is worthless if an edit to the file starts no RUN.
untriggered=""
for e in "$SELF_ENTRY" "$SELF_SCRIPT"; do
  grep -qxF -- "$e" "$TMP/paths.txt" || untriggered="$untriggered $e"
done
if [ -z "$untriggered" ]; then ok "A3: both implicit entries are on.pull_request.paths entries (an edit to either starts a run)"
else bad "A3: implicit entries that trigger NO run:$untriggered"; fi

# ── B: UNION ─────────────────────────────────────────────────────────────────
# The roster's path column is MATERIALISED once, never piped per candidate.
# `awk … | grep -qxF` reads like a lookup but is a PIPELINE: `grep -q` exits at
# its first match, the `awk` takes SIGPIPE on its next write, and `pipefail`
# makes the pipeline's status the awk's 141 — which this `||` reads as "no
# match". On Linux the whole roster fits the pipe buffer before grep is
# scheduled, so awk never blocks and CI is green; on macOS it lost EVERY path
# (20 passed / 1 failed here against 21/0 in CI, deterministic across 5 runs).
# One file, one grep, one exit status — and it is faster besides.
awk '{ print $2 }' "$TMP/roster.txt" >"$TMP/roster-paths.txt"
missing_down=""
while IFS= read -r p; do
  [ "$p" = "$SELF_ENTRY" ] && continue
  [ "$p" = "$SELF_SCRIPT" ] && continue
  grep -qxF -- "$p" "$TMP/roster-paths.txt" || missing_down="$missing_down $p"
done <"$TMP/paths.txt"
if [ -z "$missing_down" ]; then ok "B union: every on.pull_request.paths entry has a roster row"
else bad "B union: workflow paths with NO roster row (a harness that would never fire):$missing_down"; fi

# ── B2: THE AXIS-D CORPUS REACHES ITS JOB ────────────────────────────────────
# Arm B is satisfied by DELETING a path entry just as well as by adding a roster
# row. Measured: with `scripts/pds-*.sh` and `tooling/pds/**` struck from both
# paths lists, this harness printed 21 passed / 0 failed — byte-identical to the
# real fix — while an edit to scripts/pds-secret-scan.sh started no run at all.
# An arm that cannot tell a repair from an amputation is not a ratchet.
#
# So this arm is a PREDICATE over the real tree, not a list: it derives the
# axis-d corpus the way scripts/pds-record-parity.sh's axis_d_corpus_files()
# does (scripts/pds-*.sh at depth 1, minus the harnesses, plus all of
# tooling/pds), and demands of EVERY member that it (a) matches an
# on.pull_request.paths entry — or the workflow never starts — and (b) matches a
# `pds-harnesses` roster row — or the run starts with that job skipped. Both
# halves are matched with `case`, which is exactly how the dispatcher itself
# reads the roster; `case` lets `*` cross `/`, so it is the PERMISSIVE side of
# GitHub's filter and a MISS here is a real miss, never an artefact.
#
# Non-vacuity: the corpus must be non-empty. An empty find is UNAVAILABLE, not a
# pass — that is the shape that would let this whole arm green on a tree where
# the PDS scripts had simply been deleted out from under it.
awk '$1 == "pds-harnesses" { print $2 }' "$TMP/roster.txt" >"$TMP/pdsh-paths.txt"
d_corpus="$TMP/axis-d-corpus.txt"
: >"$d_corpus"
if [ -d "$REPO_ROOT/scripts" ]; then
  find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name 'pds-*.sh' >>"$d_corpus"
fi
if [ -d "$REPO_ROOT/tooling/pds" ]; then
  find "$REPO_ROOT/tooling/pds" -type f >>"$d_corpus"
fi
N_CORPUS=$(wc -l <"$d_corpus" | tr -d ' ')
if [ "$N_CORPUS" -eq 0 ]; then
  unavailable "the axis-d corpus (scripts/pds-*.sh + tooling/pds/**) matched NO file under $REPO_ROOT — this arm would green over an empty set"
fi
undispatched=""
unrostered=""
while IFS= read -r abs; do
  [ -n "$abs" ] || continue
  rel="${abs#"$REPO_ROOT"/}"
  case "$rel" in *.test.sh|*_test.sh) continue ;; esac   # axis d skips its own harnesses
  covered=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$rel" in $pat) covered=1; break ;; esac
  done <"$TMP/paths.txt"
  [ "$covered" = 1 ] || undispatched="$undispatched $rel"
  rostered=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$rel" in $pat) rostered=1; break ;; esac
  done <"$TMP/pdsh-paths.txt"
  [ "$rostered" = 1 ] || unrostered="$unrostered $rel"
done <"$d_corpus"
if [ -n "$undispatched" ]; then
  bad "B2: axis-d corpus files that match NO on.pull_request.paths entry (editing them starts no run):$undispatched"
elif [ -n "$unrostered" ]; then
  bad "B2: axis-d corpus files that match no pds-harnesses roster row (the run starts, the job is skipped):$unrostered"
else
  ok "B2: all $N_CORPUS axis-d corpus files both trigger the workflow and dispatch pds-harnesses"
fi


# ── C: GATING ────────────────────────────────────────────────────────────────
ungated=""
while read -r jid needs_ok if_ok; do
  [ "$needs_ok" = 1 ] && [ "$if_ok" = 1 ] || ungated="$ungated $jid(needs=$needs_ok,if=$if_ok)"
done <"$TMP/jobs.txt"
if [ -z "$ungated" ]; then ok "C gating: the harness job needs [changes], is gated on outputs.any, names its legs explicitly, and all $N_JOBS legs are dispatched"
else bad "C gating: jobs missing the gate:$ungated"; fi

# ── D: OUTPUTS ───────────────────────────────────────────────────────────────
no_row=""; no_out=""; bad_out=""
while read -r jid _ _; do
  grep -qx -- "$jid" "$TMP/roster-jobs.txt" || no_row="$no_row $jid"
  if line=$(grep "^$jid " "$TMP/outputs.txt"); then
    case "$line" in
      "$jid \${{ steps.sets.outputs.$jid }}") ;;
      *) bad_out="$bad_out $jid" ;;
    esac
  else
    no_out="$no_out $jid"
  fi
done <"$TMP/jobs.txt"
if [ -z "$no_row" ]; then ok "D: every gated job has at least one roster row"
else bad "D: gated jobs with NO roster row (their output would be empty — a silent false):$no_row"; fi
if [ -z "$no_out$bad_out" ]; then ok "D: every gated job has a matching outputs: entry on the changes job"
else bad "D: outputs missing:$no_out  outputs mis-wired:$bad_out"; fi
extra_out=""
while read -r k _; do
  grep -q "^$k " "$TMP/jobs.txt" || extra_out="$extra_out $k"
done <"$TMP/outputs.txt"
if [ -z "$extra_out" ]; then ok "D: no outputs: entry without a job"
else bad "D: outputs: entries naming no job:$extra_out"; fi
extra_rows=""
while read -r j; do
  grep -q "^$j " "$TMP/jobs.txt" || extra_rows="$extra_rows $j"
done <"$TMP/roster-jobs.txt"
if [ -z "$extra_rows" ]; then ok "D: no roster row names a job that does not exist"
else bad "D: roster rows for jobs that do not exist:$extra_rows"; fi

# ── E: FIXTURES ──────────────────────────────────────────────────────────────
# A throwaway repo: base commit A holds one file from every relevant area; each
# case branches from A, changes one path, and the dispatcher runs at that head.
FIX="$TMP/repo"
mkdir -p "$FIX"
G() { git -C "$FIX" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
G init -q >/dev/null 2>&1 || unavailable "git init failed"
seed() { mkdir -p "$FIX/$(dirname "$1")"; printf '%s\n' "$2" >"$FIX/$1"; }
seed cloud/lib/barkpark_cloud/web/router.ex "a"
seed cloud/lib/barkpark_cloud/other.ex "a"
seed scripts/doctor.sh "a"
seed .github/workflows/shell-harnesses.yml "a"
seed .github/workflows/elixir.yml "a"
seed README.md "a"
G add -A >/dev/null && G commit -qm A >/dev/null || unavailable "seed commit failed"
BASE_A="$(G rev-parse HEAD)"

# run_dispatcher <event> <base> <outfile> ; prints rc
run_dispatcher() {
  : >"$3"
  ( cd "$FIX" && EVENT_NAME="$1" BASE_SHA="$2" GITHUB_OUTPUT="$3" bash "$BODY" >"$3.log" 2>&1 )
  echo $?
}
# make_case <name> <path> <content> → checks out a branch from A with one change
make_case() {
  G checkout -q "$BASE_A" 2>/dev/null
  G checkout -qB "case-$1" 2>/dev/null
  seed "$2" "$3"
  G add -A >/dev/null && G commit -qm "$1" >/dev/null
}
count_true()  { grep -c '=true$'  "$1" | tr -d ' '; }
count_false() { grep -c '=false$' "$1" | tr -d ' '; }
true_set()    { grep '=true$' "$1" | sed 's/=true$//' | sort | tr '\n' ' ' | sed 's/ $//'; }

# E1 push → all true, exactly N_JOBS outputs
G checkout -q "$BASE_A" 2>/dev/null
rc=$(run_dispatcher push "" "$TMP/e1.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e1.out")" -eq "$N_JOBS" ] && [ "$(count_false "$TMP/e1.out")" -eq 0 ]; then
  ok "E1 push: rc=0, all $N_JOBS harnesses true"
else bad "E1 push: rc=$rc true=$(count_true "$TMP/e1.out") false=$(count_false "$TMP/e1.out") (want $N_JOBS/0)"; fi

# E2 empty diff (head == base) → all true, with the warning
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e2.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e2.out")" -eq "$N_JOBS" ] && grep -q '::warning::.*EMPTY' "$TMP/e2.out.log"; then
  ok "E2 empty diff: rc=0, all $N_JOBS true, warning annotated"
else bad "E2 empty diff: rc=$rc true=$(count_true "$TMP/e2.out") warning=$(grep -c '::warning::' "$TMP/e2.out.log")"; fi

# E3 THE MEASURED CASE: router.ex alone → cloud-static-gz only
make_case router cloud/lib/barkpark_cloud/web/router.ex "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e3.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e3.out")" = "cloud-static-gz" ] && [ "$(count_false "$TMP/e3.out")" -eq $((N_JOBS - 1)) ]; then
  ok "E3 router.ex only: cloud-static-gz true, the other $((N_JOBS - 1)) false (PR #15631's shape)"
else bad "E3 router.ex only: rc=$rc true={$(true_set "$TMP/e3.out")} false=$(count_false "$TMP/e3.out")"; fi

# E4 a cloud/lib file no set names → all false, all outputs still emitted
make_case other cloud/lib/barkpark_cloud/other.ex "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e4.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e4.out")" -eq 0 ] && [ "$(count_false "$TMP/e4.out")" -eq "$N_JOBS" ]; then
  ok "E4 unlisted cloud/lib file: rc=0, all $N_JOBS false (every output still emitted)"
else bad "E4 unlisted file: rc=$rc true=$(count_true "$TMP/e4.out") false=$(count_false "$TMP/e4.out")"; fi

# E5 a single-set literal → exactly that job
make_case doctor scripts/doctor.sh "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e5.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e5.out")" = "doctor-matrix" ]; then
  ok "E5 scripts/doctor.sh: doctor-matrix only"
else bad "E5 scripts/doctor.sh: rc=$rc true={$(true_set "$TMP/e5.out")}"; fi

# E6 a new workflow file → the SEVEN corpus readers via the *.yml glob (selftest-wiring-census
#    joined in task-8780f3b465edea5b: it resolves execution FROM the workflow corpus, so a new
#    workflow can change which self-tests count as run; undispatched-target joined in
#    task-3fd49a953afffd2f: it derives its candidate set from every workflow's on.*.paths key,
#    so a new workflow can add a candidate; workflow-owner joined in
#    task-dee226be3107a98b c4: its population is the set of workflows carrying a `push:` arm and
#    no `pull_request:` arm, derived from the trigger blocks, so a NEW workflow file is exactly
#    the event that can strand one off the PR path with no named owner;
#    console-refusal-capture joined in task-ea44d7b4a12eaf38: its two
#    EXCLUDED-reachability arms readdirSync .github/workflows and red if any
#    `run:` line there reaches an excluded emitter, so a NEW workflow file is
#    exactly the event that can retire one of those nine written exclusions)
make_case newwf .github/workflows/brand-new.yml "a"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e6.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e6.out")" = "console-refusal-capture deploy-concurrency selftest-wiring-census undispatched-target workflow-owner workflow-portability workflow-trigger-coverage" ]; then
  ok "E6 new workflow file: exactly the seven .github/workflows/*.yml readers"
else bad "E6 new workflow file: rc=$rc true={$(true_set "$TMP/e6.out")}"; fi

# E7 this workflow file itself → all true
make_case self .github/workflows/shell-harnesses.yml "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e7.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e7.out")" -eq "$N_JOBS" ]; then
  ok "E7 the workflow file itself: all $N_JOBS true"
else bad "E7 the workflow file: rc=$rc true=$(count_true "$TMP/e7.out")"; fi

# E7b THE DISPATCHER SCRIPT ITSELF → all true. It is not a roster row, so if
#     the implicit branch ever loses it, an edit to the dispatcher would select
#     NOTHING and every harness would skip on the very PR that changed them.
make_case selfscript "$SELF_SCRIPT" "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e7b.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e7b.out")" -eq "$N_JOBS" ]; then
  ok "E7b the dispatcher script itself: all $N_JOBS true"
else bad "E7b the dispatcher script: rc=$rc true=$(count_true "$TMP/e7b.out")"; fi

# E8 unresolvable base → exit 1, named refusal, NO outputs
G checkout -q "case-router" 2>/dev/null
BOGUS="dddddddddddddddddddddddddddddddddddddddd"
rc=$(run_dispatcher pull_request "$BOGUS" "$TMP/e8.out")
if [ "$rc" -eq 1 ] && grep -q 'is not resolvable in this checkout' "$TMP/e8.out.log" && [ ! -s "$TMP/e8.out" ]; then
  ok "E8 unresolvable base: rc=1, named refusal, zero outputs emitted"
else bad "E8 unresolvable base: rc=$rc refusal=$(grep -c 'is not resolvable' "$TMP/e8.out.log") outputs=$(wc -l <"$TMP/e8.out" | tr -d ' ')"; fi

# E9 missing base sha on a pull_request → exit 1
rc=$(run_dispatcher pull_request "" "$TMP/e9.out")
if [ "$rc" -eq 1 ] && grep -q 'no base sha' "$TMP/e9.out.log" && [ ! -s "$TMP/e9.out" ]; then
  ok "E9 empty base sha: rc=1, refused, zero outputs"
else bad "E9 empty base sha: rc=$rc"; fi

# E10 no common ancestor → exit 1, named refusal
ORPH="$TMP/orphan"; mkdir -p "$ORPH"
git -C "$ORPH" -c init.defaultBranch=main init -q >/dev/null 2>&1
printf 'x\n' >"$ORPH/x"
git -C "$ORPH" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A >/dev/null
git -C "$ORPH" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm orphan >/dev/null
ORPH_SHA="$(git -C "$ORPH" rev-parse HEAD)"
G fetch -q "$ORPH" "$ORPH_SHA" 2>/dev/null || unavailable "could not fetch the orphan commit into the fixture"
rc=$(run_dispatcher pull_request "$ORPH_SHA" "$TMP/e10.out")
if [ "$rc" -eq 1 ] && grep -q 'NO common ancestor' "$TMP/e10.out.log" && [ ! -s "$TMP/e10.out" ]; then
  ok "E10 no common ancestor: rc=1, named refusal, zero outputs"
else bad "E10 no common ancestor: rc=$rc refusal=$(grep -c 'common ancestor' "$TMP/e10.out.log")"; fi

# ── F: MUTATION — the unresolvable-base refusal is load-bearing ──────────────
MUT="$TMP/body-mut.sh"
ANCHOR='# MUT: unresolvable-base'
n_anchor=$(grep -cF -- "$ANCHOR" "$BODY" | tr -d ' ')
if [ "$n_anchor" -eq 1 ]; then
  ok "F: mutation anchor '$ANCHOR' matched exactly once"
else
  bad "F: mutation anchor matched $n_anchor times (want 1) — the mutation below cannot be trusted"
fi
grep -vF -- "$ANCHOR" "$BODY" >"$MUT"
if ! cmp -s "$BODY" "$MUT"; then ok "F: the mutant differs from the original (mutation applied)"
else bad "F: the mutant is byte-identical to the original — nothing was mutated"; fi
G checkout -q "case-router" 2>/dev/null
: >"$TMP/f.out"
( cd "$FIX" && EVENT_NAME=pull_request BASE_SHA="$BOGUS" GITHUB_OUTPUT="$TMP/f.out" bash "$MUT" >"$TMP/f.log" 2>&1 )
mrc=$?
if ! grep -q 'is not resolvable in this checkout' "$TMP/f.log"; then
  ok "F: with the guard deleted the named refusal DISAPPEARS (mutant rc=$mrc) — the guard is load-bearing"
else
  bad "F: the mutant still printed the unresolvable-base refusal — the anchor no longer covers the guard"
fi

# ── G: ARM NAME ↔ ARM LOOP — an arm is named for every axis it runs ─────────
#
# THE DEFECT (measured 2026-09-18 on probe PR #19286, task-b183f790876ad00f c3).
# The pds-harnesses arm named "…: --check-alloc and --axis a over the merged
# tree" ran FOUR arms — `for arm in --check-alloc "--axis a" "--axis d"
# "--axis f"` — because #19093 added d and f to the loop and left the name
# where it was. A planted defect reddened --axis f; the FAILED-arms line still
# said check-alloc/axis a, and a lead reading it would go to two green arms.
#
# THE GUARD IS A PREDICATE, NOT A LIST. Both sides are derived from the same
# JSON with the SAME regex, so no arm is special-cased and a SIXTH axis added
# tomorrow to the loop alone reds here with nothing to update but the name:
#
#   RUN SIDE   the arm's `run` body with whole-line `#` comments stripped (the
#              body's prose names --axis a/d/f while explaining WHY they joined;
#              counting prose would make the guard agree with itself), then
#              every `--axis <tok>` plus `--check-alloc` if present.
#   NAME SIDE  the same two patterns over the arm's `name`.
#   VERDICT    the sets must be EQUAL for every arm whose RUN side is non-empty.
#
# An arm that invokes neither pattern is out of the corpus, and G0 refuses a run
# where the corpus came out empty — an empty corpus compares equal to anything.

arm_token_guard() {  # <legs.json> → 0 equal · 1 drift (named) · 2 cannot measure
  python3 - "$1" <<'PYG'
import json, re, sys
path = sys.argv[1]
try:
    legs = json.load(open(path))
except Exception as exc:
    sys.stderr.write("cannot read %s: %s\n" % (path, exc)); sys.exit(2)

AXIS = re.compile(r'--axis\s+([A-Za-z0-9]+)')
def tokens(text):
    t = set(AXIS.findall(text))
    if '--check-alloc' in text:
        t.add('--check-alloc')
    return t

corpus = 0
drift = 0
for leg in legs:
    for arm in leg.get("arms") or []:
        name = str(arm.get("name", ""))
        body = "\n".join(ln for ln in str(arm.get("run", "")).split("\n")
                         if not ln.lstrip().startswith("#"))
        run_t, name_t = tokens(body), tokens(name)
        if not run_t:
            continue
        corpus += 1
        if run_t == name_t:
            continue
        drift += 1
        sys.stderr.write(
            "DRIFT in leg %r arm %r:\n  the loop RUNS   %s\n  the name SAYS   %s\n"
            "  missing from the name: %s\n  named but not run:     %s\n"
            % (leg.get("slug"), name,
               ", ".join(sorted(run_t)) or "<none>",
               ", ".join(sorted(name_t)) or "<none>",
               ", ".join(sorted(run_t - name_t)) or "<none>",
               ", ".join(sorted(name_t - run_t)) or "<none>"))
if corpus == 0:
    sys.stderr.write("CANNOT MEASURE: no arm invokes --axis or --check-alloc — "
                     "an empty corpus compares equal to anything\n")
    sys.exit(2)
if drift:
    sys.stderr.write("RED: %d of %d arm(s) are named for a different axis set than they run. "
                     "Rename the arm to list every axis its loop runs.\n" % (drift, corpus))
    sys.exit(1)
print("arm name/loop parity: %d arm(s) checked, every name lists exactly the axes it runs" % corpus)
PYG
}

LEGS_JSON="$(dirname "$WORKFLOW")/../shell-harness-legs.json"
if [ ! -f "$LEGS_JSON" ]; then
  bad "G: $LEGS_JSON not found"
else
  if arm_token_guard "$LEGS_JSON" >"$TMP/g1.out" 2>"$TMP/g1.err"; then
    ok "G1 arm name/loop parity holds: $(cat "$TMP/g1.out")"
  else
    bad "G1 arm name/loop parity: $(cat "$TMP/g1.err")"
  fi

  # G2 MUTATION. A fifth axis joins the LOOP ONLY, in a scratch copy. If the
  # guard still greens, it is not reading the loop and G1 proved nothing.
  MUTLEGS="$TMP/legs-mut.json"
  if python3 - "$LEGS_JSON" "$MUTLEGS" <<'PYM'
import json, sys
legs = json.load(open(sys.argv[1]))
hits = 0
for leg in legs:
    for arm in leg.get("arms") or []:
        run = str(arm.get("run", ""))
        if 'for arm in --check-alloc' in run:
            arm["run"] = run.replace('"--axis f"', '"--axis f" "--axis q"', 1)
            hits += 1
if hits != 1:
    sys.stderr.write("mutation anchor matched %d arms (want 1)\n" % hits); sys.exit(2)
json.dump(legs, open(sys.argv[2], "w"), indent=2)
PYM
  then
    ok "G2 mutation applied to exactly one arm's loop (a fifth axis q, name untouched)"
    if arm_token_guard "$MUTLEGS" >"$TMP/g2.out" 2>"$TMP/g2.err"; then
      bad "G2 the mutant PASSED — the guard does not read the loop, so G1 is vacuous"
    elif grep -q 'missing from the name: q' "$TMP/g2.err"; then
      ok "G2 the mutant REDS and names the drift: $(grep -m1 'missing from the name' "$TMP/g2.err" | sed 's/^ *//')"
    else
      bad "G2 the mutant failed for the wrong reason: $(head -3 "$TMP/g2.err" | tr '\n' ' ')"
    fi
  else
    bad "G2 could not build the mutant legs file"
  fi
fi

# ── H  THE ABSENT-FILE FALLBACK, HERMETICALLY (task-ecb7fc56b5868bfc) ────────
# The checkout in this job is the PR HEAD; the workflow FILE comes from the
# merge ref. So the moment the dispatcher body moved into scripts/ (befc8cbbf,
# 2026-09-20T14:21Z), every head whose merge base predated that commit carried
# the new `run:` line and NOT the file: `No such file or directory`, exit 127,
# matrix never rendered, every harness leg ABSENT (run 35517160933 job
# 106094923976, head 1badf9dc5). This arm runs the step's REAL body — extracted
# from the workflow, not retyped — against two staged trees:
#   H1  a head WITHOUT the script, with the base's copy reachable  -> exit 0,
#       and the BASE's copy is what ran
#   H2  a head WITH its own copy                                   -> exit 0,
#       and the HEAD's copy is what ran (a PR editing the dispatcher must test
#       its own edit, never the base's)
# The precondition is asserted in both directions before either verdict is
# believed: a "green" from a tree that quietly still had the file measures
# nothing.
SETS_BODY="$TMP/sets-body.sh"
if python3 - "$WORKFLOW" "$SETS_BODY" <<'PYH'
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(wf))
steps = doc["jobs"]["changes"]["steps"]
hit = [s for s in steps if s.get("id") == "sets"]
if len(hit) != 1:
    sys.stderr.write("expected exactly one `sets` step\n"); sys.exit(2)
run = hit[0]["run"]
if "${{" in run:
    sys.stderr.write("the sets body carries a GitHub expression\n"); sys.exit(2)
open(out, "w").write(run)
PYH
then
  ok "H extracted the real \`sets\` body from the workflow ($(wc -l <"$SETS_BODY" | tr -d ' ') lines)"

  _stage_repo() { # $1 = dir, $2 = "absent" | "present"
    local r="$1" mode="$2"
    mkdir -p "$r/scripts"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@t; git -C "$r" config user.name t
    printf 'echo "RAN=base"\n' >"$r/scripts/shell-harness-dispatch.sh"
    git -C "$r" add -A >/dev/null; git -C "$r" commit -qm base
    # `origin/main` WITHOUT a network: the ref is what `git show` reads.
    git -C "$r" update-ref refs/remotes/origin/main refs/heads/main
    if [ "$mode" = absent ]; then
      git -C "$r" rm -q scripts/shell-harness-dispatch.sh
      git -C "$r" commit -qm "a head that predates the dispatcher"
    else
      printf 'echo "RAN=head"\n' >"$r/scripts/shell-harness-dispatch.sh"
      git -C "$r" commit -qam "a head that edits the dispatcher"
    fi
  }

  for mode in absent present; do
    R="$TMP/fallback-$mode"; rm -rf "$R"; mkdir -p "$R"
    _stage_repo "$R" "$mode" >/dev/null 2>&1
    # PRECONDITION, both directions — never inferred from the exit code.
    if [ "$mode" = absent ] && [ -f "$R/scripts/shell-harness-dispatch.sh" ]; then
      bad "H($mode) the staged head still HAS the dispatcher — the case is vacuous"
      continue
    fi
    if [ "$mode" = present ] && [ ! -f "$R/scripts/shell-harness-dispatch.sh" ]; then
      bad "H($mode) the staged head LACKS the dispatcher — the case is vacuous"
      continue
    fi
    if [ "$mode" = absent ]; then
      ok "H(absent) precondition: the staged head has NO dispatcher, and origin/main does"
    else
      ok "H(present) precondition: the staged head carries its OWN dispatcher"
    fi
    rt="$TMP/rt-$mode"; mkdir -p "$rt"
    hrc=0
    ( cd "$R" && RUNNER_TEMP="$rt" GITHUB_BASE_REF=main GITHUB_OUTPUT="$TMP/out-$mode.txt" \
        bash "$SETS_BODY" ) >"$TMP/h-$mode.out" 2>&1 || hrc=$?
    if [ "$hrc" -eq 0 ]; then
      ok "H($mode) the real step body exits 0"
    else
      bad "H($mode) the real step body exited $hrc: $(tail -3 "$TMP/h-$mode.out" | tr '\n' ' ')"
    fi
    want=base; [ "$mode" = present ] && want=head
    if grep -q "RAN=$want" "$TMP/h-$mode.out"; then
      ok "H($mode) the $want copy (RAN=$want) is the one that ran"
    else
      bad "H($mode) wanted RAN=$want, got: $(tr '\n' ' ' <"$TMP/h-$mode.out" | head -c 200)"
    fi
  done
else
  bad "H could not extract the \`sets\` body (the shape moved)"
fi

echo ""
echo "shell-harnesses-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -ge 25 ] || { echo "only $PASS assertions ran — the harness shrank" >&2; exit 2; }
exit 0
