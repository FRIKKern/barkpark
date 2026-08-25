#!/usr/bin/env bash
#
# gate-announces-skips.test.sh — the shape ratchet for D377/D378: every gate
# aggregator must SAY SO, on a surface an API can read, when it concludes
# success having dispatched nothing.
#
# THE ONE FACT THIS FILE EXISTS FOR:
#
#   MEASURED on real heads. A skip-shim aggregator concludes `success` whenever
#   the diff misses its path set, and the check run it publishes is
#   BYTE-IDENTICAL to one where the whole suite passed:
#     * cloud-only PR #9656 (head 6fce7655e): `Elixir gate | success | ann=0 |
#       title=null | summary=null`, `Test (…)` and `Prod compile gate (…)` both
#       skipped.
#     * api-only PR #9529 (head 48d960092): `Cloud gate` AND `Console gate`,
#       same shape, every substantive job skipped.
#     * docs-only PR #9637 (head 7bfeb28da): all four aggregators green with
#       every substantive job skipped.
#   Three of those four names are REQUIRED contexts on main under
#   enforce_admins=true, so a merge queue and a human read the same green for
#   "the suite passed" and for "nothing ran".
#
# TWO FIXES ARE RULED OUT BY MEASUREMENT, and this ratchet deliberately does not
# accept either as a substitute:
#   * `$GITHUB_STEP_SUMMARY` NEVER populates the check-run API. Eight workflows
#     write one; 0 of 32 check-runs on that sha returned a non-null summary,
#     including pr-task-gate, which writes one and ran on that very sha.
#   * RENAMING the check is forbidden — `Elixir gate`, `Cloud gate` and
#     `Console gate` are frozen required contexts; a rename deadlocks main.
#   What DOES reach the annotations endpoint is a bare `::notice::` from a
#   succeeding, checkout-less, unmatrixed job: probe branch
#   probe/elixir-gate-annotation, commit e9be79a8d, run 31055317124, five
#   retrievable annotations, name unchanged, and it survives a red conclusion.
#
# THE VACUITY TRAP THIS RATCHET REFUSES TO FALL INTO (D378):
#   A guard shaped `annotations_count > 0` is satisfied by the runner's own
#   incidental `actions/checkout` Node-20 deprecation warning — 14 neighbouring
#   checks on #9656 carry exactly that annotation, and the aggregators read
#   ann=0 only because they have no checkout step. A count proves a runner ran,
#   never that a gate disclosed anything. SO EVERY ASSERTION BELOW MATCHES THE
#   MESSAGE TEXT, and the sentinel it matches is DERIVED from each aggregator's
#   own `name:` in the YAML, never hardcoded — rename the gate and the expected
#   sentence renames with it.
#
# A harness with only green cases is the defect, not the proof, so every
# assertion has a planted mutant that makes it FIRE — including, per workflow,
# the deletion of the notice line itself.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"

# The four aggregators, as `<workflow-file>:<job-key>`. The gate NAME and the
# expected sentence are derived from the YAML, not from this list; this list
# only says WHICH files must carry the shape.
GATES='elixir.yml:elixir-gate
cloud.yml:cloud-gate
console-harness.yml:console-gate
security.yml:security-gate'

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   — $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL — $1" >&2
}

# ── charter D37: never `printf … | grep -q` ────────────────────────────────
# Under `set -o pipefail` on BSD grep (macOS), grep exits 0 the instant it
# matches, printf dies of SIGPIPE, pipefail promotes 141 over grep's success and
# the `if` takes the ELSE branch — a FALSE failure for a match that did occur.
# A here-string has no writer process to kill.
has() { grep -q -F -- "$2" <<<"$1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-announces-skips.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "gate-announces-skips.test.sh"
echo

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  FAIL — python3 with PyYAML is required to read the workflows structurally." >&2
  echo "         Refusing to fall back to regex: a regex reader silently agrees with" >&2
  echo "         every shape, which is the failure mode this ratchet exists to remove." >&2
  exit 1
fi

for spec in $GATES; do
  wf="$REAL_ROOT/.github/workflows/${spec%%:*}"
  if [ ! -f "$wf" ]; then
    echo "  FAIL — $wf does not exist" >&2
    exit 1
  fi
done

# ── the emitter ────────────────────────────────────────────────────────────
# A FILE rather than an inline heredoc, so the mutation proofs below run the
# very same code over deliberately-broken copies of the real workflows. A
# detector never pointed at a broken input has not been shown to detect
# anything.
EMIT="$TMPROOT/emit-gate-facts.py"
cat >"$EMIT" <<'PY'
import re, sys, yaml

wf = yaml.safe_load(open(sys.argv[1]))
job_key = sys.argv[2]
out = open(sys.argv[3], "w")
jobs = wf["jobs"]
agg = jobs.get(job_key, {})


def emit(k, v):
    out.write(f"{k}={v}\n")


emit("agg_present", bool(agg))
name = agg.get("name") or ""
emit("agg_name", name)

# THE SENTINEL IS DERIVED, never hardcoded: "Elixir gate" -> "NOTHING ELIXIR
# RAN". Rename the gate and the demanded sentence renames with it; a gate whose
# name stops ending in " gate" is itself reported, rather than silently
# producing an empty sentinel that every string trivially contains.
m = re.match(r"^(.+?)\s+gate$", name.strip())
emit("sentinel", ("NOTHING %s RAN" % m.group(1).upper()) if m else "")

step = next((s for s in agg.get("steps", []) if "run" in s), {})
run = step.get("run", "")
emit("step_present", bool(step))

# EVERY workflow-command EMISSION in the step body, classified. Anchored on
# `echo "` on purpose: the surrounding comments discuss `::notice::` in prose,
# and counting those would let a workflow satisfy this ratchet with a comment.
# ONE notice is the contract: GitHub caps annotations at 10 per level per step,
# so an N-per-skipped-job emitter would truncate silently — the same quiet lie
# the notice exists to remove.
notices = re.findall(r'echo "::notice[^\n]*', run)
emit("notice_count", len(notices))
notice = notices[0] if notices else ""
emit("notice_has_sentinel", bool(m) and ("NOTHING %s RAN" % m.group(1).upper()) in notice)
emit("notice_has_name", bool(name) and name in notice)
# The two claims a reader must be able to act on: green != tested, and green
# here means "not applicable".
emit("notice_says_not_tested", "NOT because anything was tested" in notice)
emit("notice_says_not_applicable", "NOT APPLICABLE" in notice)
# It must NAME the skipped upstreams rather than merely asserting the fact.
emit("notice_names_skipped", "${not_dispatched}" in notice)
# Multi-line, in the only encoding an annotation body accepts.
emit("notice_multiline", "%0A" in notice)

# ── THE TITLE, PARSED THE WAY GITHUB PARSES IT ─────────────────────────────
# MEASURED on PR #9677's head (dad4b33bb): all four aggregators delivered
# `title="<X> gate: green"` — the disclosure clause was GONE, because `,` is
# the workflow-command PROPERTY SEPARATOR and ` nothing ran` parsed as a
# valueless property and was dropped. The body survived whole, so the source
# read fine and only the one field a person skims lied.
# So this reader SPLITS ON `,` exactly like the runner does, and reports the
# title as DELIVERED, never as written.
tm = re.match(r'echo "::notice(?: (?P<props>.*?))?::', notice)
props = tm.group("props") if (tm and tm.group("props")) else ""
title = ""
for prop in props.split(","):
    k, sep, v = prop.partition("=")
    if k.strip() == "title" and sep:
        title = v
emit("notice_title_present", bool(title.strip()))
# A comma ANYWHERE in the property section truncates the title at delivery.
# Scoped to the comma ALONE — an ABSENT title is a different defect with its
# own assertion above, and one failure reporting two diagnoses sends a reader
# to the wrong fix.
emit("notice_title_comma_free", "," not in props)
# …and what survives must still be the disclosure, not a bare "green".
emit("notice_title_discloses", "nothing ran" in title.lower())

# The tally the notice is gated on must EXIST and must exclude NEVER-gated jobs
# (the dispatcher and the unfiltered ratchets run on every head, so counting
# them would make the notice unreachable — a guard that can never fire).
emit("tally_declared", bool(re.search(r"^\s*dispatched=0\s*$", run, re.M)))
emit("tally_excludes_never", bool(re.search(r'\[\s*"\$gate"\s*!=\s*"NEVER"\s*\]', run)))
emit("notice_guarded", bool(re.search(
    r'if \[ "\$dispatched" -eq 0 \]; then\s*\n\s*echo "::notice', run)))
# …and it must sit AFTER the fail-closed exit, so a red run never publishes a
# reassuring "nothing ran, all good".
ei = run.find("exit 1")
ni = run.find('echo "::notice')
emit("notice_after_exit", ei != -1 and ni != -1 and ni > ei)

# Companion cardinality. An empty/false answer is only meaningful if the body it
# was computed from was actually read: a parser that stopped matching would
# report a serene "0" forever.
emit("decide_consumes_count", len(re.findall(r'^\s*decide\s+"', run, re.M)))
out.close()
PY

facts_for() { # facts_for <workflow-path> <job-key> <out-file>
  python3 "$EMIT" "$1" "$2" "$3"
}

echo "case 1: each of the four aggregators emits ONE derived, self-naming notice"
for spec in $GATES; do
  file="${spec%%:*}"
  job="${spec##*:}"
  wf="$REAL_ROOT/.github/workflows/$file"
  f="$TMPROOT/facts-$job.txt"
  facts_for "$wf" "$job" "$f"
  fact() { sed -n "s|^$1=||p" "$f"; }

  want_name="$(fact agg_name)"
  sentinel="$(fact sentinel)"

  [ "$(fact agg_present)" = "True" ] && ok "$file: job '$job' exists" ||
    no "$file: job '$job' is missing"
  [ "$(fact step_present)" = "True" ] && ok "$file: the decide step exists" ||
    no "$file: the decide step is missing"
  [ -n "$sentinel" ] && ok "$file: sentinel derived from name '$want_name' -> '$sentinel'" ||
    no "$file: could not derive a sentinel from name '$want_name' (expected '<X> gate')"
  # ONE, never N. Both directions are wrong: zero is the defect this slice
  # exists to fix, and >1 is the annotation cap truncating silently.
  [ "$(fact notice_count)" = "1" ] && ok "$file: exactly one ::notice:: in the step" ||
    no "$file: notice_count = '$(fact notice_count)', wanted exactly 1"
  # ── THE ANTI-VACUITY ASSERTIONS (D378) ──────────────────────────────────
  # Text, never a count: a count is satisfied by the runner's incidental
  # actions/checkout Node-20 warning, which discloses nothing about this gate.
  [ "$(fact notice_has_sentinel)" = "True" ] && ok "$file: notice says '$sentinel'" ||
    no "$file: notice does not carry the derived sentence '$sentinel'"
  [ "$(fact notice_has_name)" = "True" ] && ok "$file: notice names '$want_name'" ||
    no "$file: notice never names the gate '$want_name'"
  [ "$(fact notice_says_not_tested)" = "True" ] && ok "$file: notice says green != tested" ||
    no "$file: notice never says green does not mean tested"
  [ "$(fact notice_says_not_applicable)" = "True" ] && ok "$file: notice says NOT APPLICABLE" ||
    no "$file: notice never says green here means 'not applicable'"
  [ "$(fact notice_names_skipped)" = "True" ] && ok "$file: notice names the skipped upstreams" ||
    no "$file: notice does not interpolate \${not_dispatched}"
  [ "$(fact notice_multiline)" = "True" ] && ok "$file: notice is multi-line (%0A)" ||
    no "$file: notice is single-line — %0A is the only newline an annotation body takes"
  # ── THE HEADLINE, AS DELIVERED ──────────────────────────────────────────
  # The body above can be perfect while the title — the one field a person
  # skims in the Checks list — says the flat opposite. Every assertion here is
  # on the title GitHub will actually publish, after its own comma-splitting.
  [ "$(fact notice_title_present)" = "True" ] && ok "$file: notice carries a title= property" ||
    no "$file: the notice has NO title= property — the Checks list headline is empty"
  [ "$(fact notice_title_comma_free)" = "True" ] && ok "$file: the notice property section is comma-free, so the title survives delivery" ||
    no "$file: the notice properties contain a ',' — GitHub reads it as a property separator and TRUNCATES the title"
  [ "$(fact notice_title_discloses)" = "True" ] && ok "$file: the delivered title still says 'nothing ran'" ||
    no "$file: the DELIVERED title does not say 'nothing ran' — the headline reads as a plain green pass"
  # ── the guard's own wiring ───────────────────────────────────────────────
  [ "$(fact tally_declared)" = "True" ] && ok "$file: the dispatched tally is declared" ||
    no "$file: no 'dispatched=0' — the notice is gated on an unset variable"
  [ "$(fact tally_excludes_never)" = "True" ] && ok "$file: the tally excludes NEVER-gated jobs" ||
    no "$file: the tally counts NEVER-gated jobs, so the notice can never fire"
  [ "$(fact notice_guarded)" = "True" ] && ok "$file: notice fires only when nothing was dispatched" ||
    no "$file: the notice is not guarded by 'if [ \"\$dispatched\" -eq 0 ]'"
  [ "$(fact notice_after_exit)" = "True" ] && ok "$file: notice sits after the fail-closed exit" ||
    no "$file: the notice can be reached on a RED run"
  # Populated-parser floor: 0 here means the reader stopped matching, not that
  # the workflow got simpler.
  case "$(fact decide_consumes_count)" in
    '' | *[!0-9]*) no "$file: decide_consumes_count = '$(fact decide_consumes_count)' — the emitter is broken" ;;
    *) if [ "$(fact decide_consumes_count)" -ge 4 ]; then
         ok "$file: decide calls read = $(fact decide_consumes_count) (>= 4)"
       else
         no "$file: decide calls read = $(fact decide_consumes_count), wanted >= 4 — the reader is neutered, not the workflow clean"
       fi ;;
  esac
done
echo

# ── case 2: the mutants — the ratchet must be able to LOSE, four times ──────
echo "case 2: deleting the notice from EACH of the four workflows reds this ratchet"
MUT="$TMPROOT/mutate-workflow.py"
cat >"$MUT" <<'PY'
import re, sys, yaml

src, dst, job_key, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
wf = yaml.safe_load(open(src))
agg = wf["jobs"][job_key]
step = next(s for s in agg["steps"] if "run" in s)
run = step["run"]
assert mode in ("clean", "drop-notice", "double-notice", "ungate",
                "count-never", "before-exit", "gut-sentence", "rename",
                "comma-title", "drop-title"), mode


def notice_props(body):
    """The `::notice <props>::` property section, or die loudly.

    Every title mutation below asserts its anchor BEFORE patching: a mutation
    that silently fails to mutate reports a serene green, which is the exact
    failure this harness exists to make impossible.
    """
    m = re.search(r'echo "::notice (title=[^\n]*?)::', body)
    assert m, "no `::notice title=` property section to mutate"
    return m.group(1)

def cut_guard(body):
    """Remove the `if [ "$dispatched" -eq 0 ]` … `fi` block, line-based.

    A regex over the whole body is not reliable here: the notice line is long
    and the four workflows indent it differently. A mutation that silently
    fails to mutate would report a serene green — the exact failure this
    harness exists to make impossible.
    """
    lines = body.split("\n")
    i = next(k for k, l in enumerate(lines)
             if 'if [ "$dispatched" -eq 0 ]; then' in l)
    j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() == "fi")
    return "\n".join(lines[:i] + lines[j + 1:])


if mode == "drop-notice":
    # THE regression: the disclosure is deleted and the gate goes back to
    # greening in silence.
    run = cut_guard(run)
elif mode == "double-notice":
    # One per skipped job — GitHub caps at 10 per level per step and truncates
    # the rest without saying so.
    run = run.replace('echo "::notice', 'echo "::notice extra::x"\n            echo "::notice', 1)
elif mode == "ungate":
    # Fires on every run, including full ones: the notice then says "nothing
    # ran" about runs where everything ran.
    run = run.replace('if [ "$dispatched" -eq 0 ]; then', 'if true; then')
elif mode == "count-never":
    # The tally counts the always-on dispatcher/ratchet, so `dispatched` is
    # never 0 and the notice is unreachable — green forever, discloses never.
    run = run.replace('[ "$gate" != "NEVER" ]', '[ "$gate" != "IMPOSSIBLE" ]')
elif mode == "before-exit":
    # Reachable on a RED run: a failing gate that also claims nothing ran.
    run = cut_guard(run).replace(
        "          bad=0\n",
        '          bad=0\n          if [ "$dispatched" -eq 0 ]; then\n'
        '            echo "::notice::x"\n          fi\n', 1)
elif mode == "gut-sentence":
    # The vacuity trap made concrete: an annotation IS published (a count-based
    # guard is satisfied) but it discloses nothing.
    run = re.sub(r'echo "::notice[^\n]*', 'echo "::notice::done"', run)
elif mode == "comma-title":
    # THE SHIPPED DEFECT, planted back: `,` is GitHub's property separator, so
    # `<X> gate: green, nothing ran` DELIVERS as `<X> gate: green` — the four
    # words carrying the whole disclosure never reach the annotation.
    props = notice_props(run)
    assert "," not in props, "the property section already carries a comma"
    mutated = props.replace(" — ", ", ", 1)
    assert mutated != props, "expected ' — ' in the title to swap for a comma"
    run = run.replace(props, mutated, 1)
elif mode == "drop-title":
    # The title deleted OUTRIGHT. Before this slice the ratchet still reported
    # 106 passed / 0 failed on exactly this mutant, because `notice_has_name`
    # is satisfied by the gate name appearing in the BODY sentence.
    props = notice_props(run)
    run = run.replace('echo "::notice %s::' % props, 'echo "::notice::', 1)
    assert 'echo "::notice::' in run, "the title property was not removed"
elif mode == "rename":
    # The gate is renamed; the sentinel must follow it, not stay pinned to the
    # old word.
    agg["name"] = "Renamed gate"

step["run"] = run
yaml.safe_dump(wf, open(dst, "w"))
PY

# mutant <workflow-file> <job-key> <mode> <fact> <expected>
mutant() {
  local file="$1" job="$2" mode="$3" key="$4" want="$5"
  local wf="$REAL_ROOT/.github/workflows/$file"
  local f="$TMPROOT/mut-$job-$mode.yml" ff="$TMPROOT/mut-$job-$mode.facts" got
  # `clean` goes through the same load/dump round-trip as the broken copies, so
  # the ONLY variable between them is the mutation itself.
  python3 "$MUT" "$wf" "$f" "$job" "$mode"
  python3 "$EMIT" "$f" "$job" "$ff"
  got="$(sed -n "s|^${key}=||p" "$ff")"
  if [ "$got" = "$want" ]; then
    ok "mutation[$file/$mode]: $key = '${got}'"
  else
    no "mutation[$file/$mode]: $key = '${got}', wanted '${want}'"
  fi
}

# THE FOUR REDS, one per workflow, named. This is the criterion: deleting the
# notice from ANY of the four must be detected.
for spec in $GATES; do
  file="${spec%%:*}"
  job="${spec##*:}"
  mutant "$file" "$job" clean       notice_count 1
  mutant "$file" "$job" drop-notice notice_count 0
  # The round-trip alone must not change the title facts, so the two title
  # mutants below have exactly one variable: the mutation.
  mutant "$file" "$job" clean       notice_title_comma_free True
  mutant "$file" "$job" clean       notice_title_discloses  True
done
echo

# ── case 2b: the TITLE mutants — the headline assertions must lose, per file ─
# Both of these were green before this slice: the ratchet asserted nothing at
# all about the title, so the field a person actually skims could be truncated,
# reworded or deleted outright and the guard stayed at 106 passed / 0 failed.
echo "case 2b: comma-ing or deleting the title in EACH of the four workflows reds this ratchet"
for spec in $GATES; do
  file="${spec%%:*}"
  job="${spec##*:}"
  # Planting the comma back: the property section is no longer comma-free AND
  # the DELIVERED title loses the disclosure clause.
  mutant "$file" "$job" comma-title notice_title_comma_free False
  mutant "$file" "$job" comma-title notice_title_discloses  False
  # …while the body is untouched, which is precisely why the old assertions
  # could not see this: the defect lives only in the title.
  mutant "$file" "$job" comma-title notice_has_sentinel     True
  # Deleting the title property outright.
  mutant "$file" "$job" drop-title  notice_title_present    False
  mutant "$file" "$job" drop-title  notice_has_name         True
done
echo

echo "case 3: every other assertion is proven able to fail (elixir.yml as the probe)"
mutant elixir.yml elixir-gate double-notice notice_count           2
mutant elixir.yml elixir-gate ungate        notice_guarded         False
mutant elixir.yml elixir-gate count-never   tally_excludes_never   False
mutant elixir.yml elixir-gate before-exit   notice_after_exit      False
# THE VACUITY MUTANT. `gut-sentence` still emits an annotation — a
# count-based guard passes it — and this ratchet still reds, because it matches
# the message text.
mutant elixir.yml elixir-gate gut-sentence  notice_has_sentinel    False
mutant elixir.yml elixir-gate gut-sentence  notice_count           1
# …and the sentinel really is derived: rename the gate and the old sentence no
# longer satisfies it.
mutant elixir.yml elixir-gate rename        sentinel               "NOTHING RENAMED RAN"
mutant elixir.yml elixir-gate rename        notice_has_sentinel    False
echo

# ── case 4: the step bodies, EXTRACTED and EXECUTED ────────────────────────
# A static read proves the line is written. Only running it proves the line
# fires on the "nothing ran" path and stays silent on every other one. The body
# comes out of the real YAML, so this cannot be a paraphrase of what CI runs.
echo "case 4: each aggregator's step, executed — the notice fires only when nothing ran"
EXTRACT="$TMPROOT/extract-step.py"
cat >"$EXTRACT" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"][sys.argv[2]]["steps"] if "run" in s)
open(sys.argv[3], "w").write(step["run"])
PY

OUT="$TMPROOT/step.out"
# run_gate <label> <script> <expect-notice:yes|no> <expected-rc> KEY=VAL...
run_gate() {
  local label="$1" script="$2" expect="$3" want="$4" rc
  shift 4
  env -i PATH="$PATH" HOME="$HOME" "$@" bash --noprofile --norc "$script" >"$OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$OUT" >&2
    return 0
  fi
  if has "$(cat "$OUT")" "::notice"; then
    if [ "$expect" = yes ]; then ok "$label -> exit $rc, notice emitted"; else
      no "$label -> emitted a ::notice:: it must not: $(cat "$OUT")"
    fi
  else
    if [ "$expect" = no ]; then ok "$label -> exit $rc, no notice (correct)"; else
      no "$label -> emitted NO ::notice:: on the nothing-ran path: $(cat "$OUT")"
    fi
  fi
}

# The env each aggregator's step needs, and the two interesting worlds:
# NOTHING dispatched (gate output false, gated jobs skipped) vs SOMETHING
# dispatched. Derived per workflow would mean re-deriving GitHub's own `needs`
# context; these are the literal env blocks read out of the YAML above.
elixir_step="$TMPROOT/step-elixir.sh"
python3 "$EXTRACT" "$REAL_ROOT/.github/workflows/elixir.yml" elixir-gate "$elixir_step"
run_gate "Elixir gate: docs-only, nothing dispatched" "$elixir_step" yes 0 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=false
run_gate "Elixir gate: the suite actually ran" "$elixir_step" no 0 \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
# PARTIAL dispatch is NOT "nothing ran": one real job is enough to make the
# green mean something, and a notice there would be its own false statement.
run_gate "Elixir gate: only the test lane ran" "$elixir_step" no 0 \
  R_CHANGES=success R_TEST=success R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=true
run_gate "Elixir gate: RED — no reassuring notice on a failure" "$elixir_step" no 1 \
  R_CHANGES=success R_TEST=failure R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=false

cloud_step="$TMPROOT/step-cloud.sh"
python3 "$EXTRACT" "$REAL_ROOT/.github/workflows/cloud.yml" cloud-gate "$cloud_step"
run_gate "Cloud gate: api-only, nothing dispatched" "$cloud_step" yes 0 \
  R_CHANGES=success R_COMPILE=skipped R_TEST=skipped R_ESCAPE=success O_CLOUD=false
run_gate "Cloud gate: cloud/** touched, mix test really ran" "$cloud_step" no 0 \
  R_CHANGES=success R_COMPILE=success R_TEST=success R_ESCAPE=success O_CLOUD=true
run_gate "Cloud gate: RED — no reassuring notice on a failure" "$cloud_step" no 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=failure R_ESCAPE=success O_CLOUD=true

console_step="$TMPROOT/step-console.sh"
python3 "$EXTRACT" "$REAL_ROOT/.github/workflows/console-harness.yml" console-gate "$console_step"
run_gate "Console gate: api-only, nothing dispatched" "$console_step" yes 0 \
  R_CHANGES=success R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped \
  R_ESCAPE=success O_CONSOLE=false
run_gate "Console gate: the harness really ran" "$console_step" no 0 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=success \
  R_ESCAPE=success O_CONSOLE=true
run_gate "Console gate: RED — no reassuring notice on a failure" "$console_step" no 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success \
  R_ESCAPE=success O_CONSOLE=true

security_step="$TMPROOT/step-security.sh"
python3 "$EXTRACT" "$REAL_ROOT/.github/workflows/security.yml" security-gate "$security_step"
run_gate "Security gate: docs-only, nothing dispatched" "$security_step" yes 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=false
run_gate "Security gate: the scans really ran" "$security_step" no 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true
run_gate "Security gate: RED — no reassuring notice on a failure" "$security_step" no 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=failure O_API=true
echo

# ── case 5: the emitted annotation body actually says the derived sentence ──
# case 4 proves a notice fires; this proves WHAT it says, on the executed
# output rather than on the source text — the two can diverge through shell
# quoting, and only this direction is what a reader will actually see.
echo "case 5: the emitted body carries the derived sentence and names the skips"
body_says() { # body_says <label> <sentinel> <needle>
  if has "$(cat "$OUT")" "$3"; then ok "$1 …says '$3'"; else
    no "$1 …never said '$3': $(cat "$OUT")"
  fi
}
run_gate "Elixir gate: docs-only" "$elixir_step" yes 0 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=false
body_says "Elixir gate" - "NOTHING ELIXIR RAN"
body_says "Elixir gate" - "NOT because anything was tested"
body_says "Elixir gate" - "NOT APPLICABLE"
# NAMES the skipped upstreams, resolved — not the literal variable.
body_says "Elixir gate" - "mix-test"
body_says "Elixir gate" - "mix-prod-compile"
if has "$(cat "$OUT")" '${not_dispatched}'; then
  no "Elixir gate: the notice printed the literal \${not_dispatched}, unexpanded"
else
  ok "Elixir gate …the skip list is expanded, not literal"
fi

run_gate "Cloud gate: api-only" "$cloud_step" yes 0 \
  R_CHANGES=success R_COMPILE=skipped R_TEST=skipped R_ESCAPE=success O_CLOUD=false
body_says "Cloud gate" - "NOTHING CLOUD RAN"
run_gate "Console gate: api-only" "$console_step" yes 0 \
  R_CHANGES=success R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped \
  R_ESCAPE=success O_CONSOLE=false
body_says "Console gate" - "NOTHING CONSOLE RAN"
run_gate "Security gate: docs-only" "$security_step" yes 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=false
body_says "Security gate" - "NOTHING SECURITY RAN"
echo

# ── case 6: the one string that told readers a lie about branch protection ──
# `Security gate` is NOT one of the four required contexts on main. It said it
# was, in the ::error:: a reader sees exactly when they are deciding whether a
# red blocks their merge.
echo "case 6: security.yml does not claim to be a required context"
SEC="$REAL_ROOT/.github/workflows/security.yml"
if grep -n 'Security gate:.*This is the required context' "$SEC" >/dev/null 2>&1; then
  no "security.yml still calls Security gate 'the required context' — it is not one of the four"
else
  ok "security.yml no longer claims Security gate is the required context"
fi
# …and the three that ARE required still say so, so this fix cannot be
# over-applied into deleting a true statement.
for spec in elixir.yml:Elixir cloud.yml:Cloud console-harness.yml:Console; do
  f="${spec%%:*}"
  g="${spec##*:}"
  if grep -q "$g gate:.*This is the required context" "$REAL_ROOT/.github/workflows/$f"; then
    ok "$f still states (truthfully) that $g gate is a required context"
  else
    no "$f no longer states that $g gate is a required context — it IS one of the four"
  fi
done
echo

# ── case 7: the RED annotation NAMES the job that refused (D770/D771) ───────
# THE DEFECT, measured by executing these very step bodies with one upstream =
# failure: every aggregator emitted a bare `<Gate>: at least one upstream job is
# not in the allow-set (see above).` The step LOG names the job one line above;
# the ANNOTATION — the only line the check-run API carries, and so the only line
# a human at the merge button or the merge queue reads — named NOTHING. "See
# above" is an instruction to open a log the reader was not given.
#
# WHY THIS ASSERTION IS SHAPED AS A PAIR, and why a single red run would have
# proved nothing: a hardcoded sentence (`NOT IN THE ALLOW-SET: test.`, derived
# from no measurement) satisfies any one-run guard, and satisfied BOTH existing
# harnesses green at 164/0 and 146/0. So each gate is driven TWICE with a
# DIFFERENT upstream failing, and the annotation must NAME the failing job in
# the run where it failed AND NOT name it in the run where it passed. A string
# that cannot vary cannot pass both halves.
#
# It reads the ANNOTATION ONLY — never the step log above it, which has always
# named the job and is not what the API publishes.
#
# It is deliberately NOT a byte-parallel comparison across the four files:
# security.yml's sentence ends with an advisory-context clause its siblings do
# not carry (case 6), and a full-string equality assertion would red on it by
# construction. Only the named SET is compared.
echo "case 7: the RED ::error:: names the job that refused, and no job that passed"

# red_names <label> <script> <must-name> <must-not-name> KEY=VAL...
red_names() {
  local label="$1" script="$2" want_in="$3" want_out="$4" rc
  shift 4
  env -i PATH="$PATH" HOME="$HOME" "$@" bash --noprofile --norc "$script" >"$OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -ne 1 ]; then
    no "$label -> exit $rc, wanted 1 (this input must be RED)"
    sed 's/^/        /' "$OUT" >&2
    return 0
  fi
  local ann
  ann="$(grep '^::error' "$OUT" | tr '\n' ' ')"
  if [ -z "$ann" ]; then
    no "$label -> RED but emitted NO ::error:: annotation at all"
    return 0
  fi
  local named="${ann#*NOT IN THE ALLOW-SET: }"
  if [ "$named" = "$ann" ]; then
    no "$label -> the annotation carries no 'NOT IN THE ALLOW-SET:' clause — it names nothing: $ann"
    return 0
  fi
  # Everything after the first `%0A` belongs to a LATER clause (console appends
  # its measured-defect list); the set is what precedes it.
  local nl='%0A'
  named="${named%%$nl*}"
  if has "$named" "$want_in"; then
    ok "$label -> the annotation names '$want_in'"
  else
    no "$label -> the annotation never named the failing job '$want_in': $ann"
  fi
  if has "$named" "$want_out"; then
    no "$label -> the annotation names '$want_out', which PASSED in this run: $ann"
  else
    ok "$label -> …and does not name the passing '$want_out'"
  fi
}

red_names "Elixir gate: mix-test failed" "$elixir_step" "mix-test" "mix-prod-compile" \
  R_CHANGES=success R_TEST=failure R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
red_names "Elixir gate: mix-prod-compile failed" "$elixir_step" "mix-prod-compile" "mix-test" \
  R_CHANGES=success R_TEST=success R_PROD=failure R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

red_names "Cloud gate: test failed" "$cloud_step" "test" "compile" \
  R_CHANGES=success R_COMPILE=success R_TEST=failure R_ESCAPE=success O_CLOUD=true
red_names "Cloud gate: compile failed" "$cloud_step" "compile" "test" \
  R_CHANGES=success R_COMPILE=failure R_TEST=success R_ESCAPE=success O_CLOUD=true

red_names "Console gate: cssom-parity failed" "$console_step" "cssom-parity" "tier-floor-render" \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success \
  R_ESCAPE=success O_CONSOLE=true
red_names "Console gate: tier-floor-render failed" "$console_step" "tier-floor-render" "cssom-parity" \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=failure R_OVERFLOW=success \
  R_ESCAPE=success O_CONSOLE=true

red_names "Security gate: mix-audit failed" "$security_step" "mix-audit" "sobelow-inline-overlap" \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=failure O_API=true
red_names "Security gate: sobelow-inline-overlap failed" "$security_step" "sobelow-inline-overlap" "mix-audit" \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=failure R_FINGERPRINT=success R_AUDIT=success O_API=true

# The OTHER `bad=1` sites, which a failure-only guard would leave unaccumulated:
# a skip against a gate that is not 'false', and an EMPTY result. Both are reds
# the annotation used to describe as "at least one upstream job" and nothing
# more.
red_names "Cloud gate: test skipped against a true gate" "$cloud_step" "test" "compile" \
  R_CHANGES=success R_COMPILE=success R_TEST=skipped R_ESCAPE=success O_CLOUD=true
red_names "Cloud gate: test result EMPTY (not in the needs set)" "$cloud_step" "test" "compile" \
  R_CHANGES=success R_COMPILE=success R_TEST= R_ESCAPE=success O_CLOUD=true
red_names "Cloud gate: unrecognised result" "$cloud_step" "test" "compile" \
  R_CHANGES=success R_COMPILE=success R_TEST=neither R_ESCAPE=success O_CLOUD=true
echo

# ── case 7b: the corrections the named set may not run over ────────────────
# security.yml's sentence is NOT byte-parallel to its siblings and must stay
# that way: the advisory-context clause is a correction a previous wave landed
# (case 6), and appending a named set is exactly the kind of edit that quietly
# re-parallelises four sentences.
echo "case 7b: naming the set did not flatten security.yml's advisory clause"
run_gate "Security gate: RED" "$security_step" no 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=failure O_API=true
SEC_ANN="$(grep '^::error' "$OUT" | tr '\n' ' ')"
if has "$SEC_ANN" "advisory context, not one of the four required on main"; then
  ok "Security gate …still says it is advisory, not one of the four required"
else
  no "Security gate …lost the advisory-context clause: $SEC_ANN"
fi
if has "$SEC_ANN" "This is the required context"; then
  no "Security gate …now claims to be the required context: $SEC_ANN"
else
  ok "Security gate …still does not claim to be the required context"
fi
# …and console still names its measured defects on the plain arm, which is the
# fact #11377 left on the floor: `measured` was collected and then discarded on
# every red where no upstream published a REFUSED verdict.
run_gate "Console gate: RED, no refusal" "$console_step" no 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success \
  R_ESCAPE=success O_CONSOLE=true V_CSSOM=MEASURED_DEFECT
CON_ANN="$(grep '^::error' "$OUT" | tr '\n' ' ')"
if has "$CON_ANN" "Measured defects (exit 1) in this run: cssom-parity"; then
  ok "Console gate …the plain red arm names the measured defect"
else
  no "Console gate …the plain red arm still discards \${measured}: $CON_ANN"
fi
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
