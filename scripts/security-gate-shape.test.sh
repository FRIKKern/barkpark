#!/usr/bin/env bash
#
# security-gate-shape.test.sh — the shape ratchet for .github/workflows/security.yml.
#
# security.yml gained the wave-9 skip shim in wave 10: no workflow-level
# `on: … paths:`, an always-running `changes` dispatcher that FAILS rather than
# guesses, and an unmatrixed `Security gate` aggregator that ASSERTS on every
# upstream result. This harness pins that shape so it cannot quietly rot back.
#
# THE ONE FACT THIS FILE EXISTS FOR — `coe_in_needs`:
#
#   MEASURED on a throwaway probe repo: a job with `continue-on-error: true`
#   that exits 1 CONCLUDES FAILURE and renders a RED check run, but
#   `needs.<job>.result` reads `success` — byte-identical to a genuine pass.
#   `failure` and `skipped` stay distinguishable; `success` does NOT decompose,
#   and no rewrite of the aggregator's `decide()` can recover the difference,
#   because the information is destroyed before the aggregator's shell starts.
#
#   So a continue-on-error job in the aggregator's `needs` launders its own red
#   into a green required context, accidentally and unfalsifiably. Today that is
#   `sobelow`, which is why `Security gate` does not list it.
#
# …and its mirror, `blocking_not_in_needs`: a BLOCKING job present in the
# workflow but absent from `needs` is a job the aggregator cannot judge, so it
# greens while that job reds. Both sets are DERIVED FROM security.yml, never
# hardcoded — that is what makes this ratchet self-correcting. When
# `felix-w24-s7-continue-on-error-flip` makes Sobelow blocking, `coe_jobs`
# empties and `blocking_not_in_needs` immediately demands that `sobelow` be
# ADDED to `needs`, which is the correct answer under the new shape.
#
# A harness with only green cases is the defect, not the proof, so every
# assertion below has a planted mutant that makes it FIRE.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"
WF="$REAL_ROOT/.github/workflows/security.yml"

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
# `printf '%s\n' "$x" | grep -q …` under `set -o pipefail` is a SIGPIPE trap on
# BSD grep (macOS): grep exits 0 the instant it matches, printf is killed by
# SIGPIPE, pipefail promotes 141 over grep's success, and the `if` takes the
# ELSE branch — a FALSE failure for a match that did occur. A here-string has no
# writer process to kill.
has() { grep -q -- "$2" <<<"$1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/security-gate-shape.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "security-gate-shape.test.sh"
echo

if [ ! -f "$WF" ]; then
  echo "  FAIL — $WF does not exist" >&2
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  FAIL — python3 with PyYAML is required to read the workflow structurally." >&2
  echo "         Refusing to fall back to regex: a regex reader silently agrees with" >&2
  echo "         every shape, which is the failure mode this ratchet exists to remove." >&2
  exit 1
fi

# ── the emitter ────────────────────────────────────────────────────────────
# A FILE rather than an inline heredoc, so the mutation proofs below run the
# very same code over deliberately-broken copies of security.yml. A detector
# never pointed at a broken input has not been shown to detect anything.
EMIT="$TMPROOT/emit-security-yml-facts.py"
cat >"$EMIT" <<'PY'
import re, sys, yaml

wf = yaml.safe_load(open(sys.argv[1]))
out = open(sys.argv[2], "w")
on = wf.get(True, wf.get("on"))            # PyYAML parses bare `on:` as True
jobs = wf["jobs"]
AGG = "security-gate"


def emit(k, v):
    out.write(f"{k}={v}\n")


# D18: a paths filter on the PULL_REQUEST arm emits NO check run — the required
# name then sits "is expected." forever and the PR is BLOCKED with nothing to
# fix. NARROWED TO THAT ARM 2026-09-10 (task-7ef9d81ed33d2b9c), from `any arm`.
# The reason D18 gives is about a REQUIRED CONTEXT ON A PULL REQUEST, and branch
# protection never evaluates a push-to-main run: it gates merges INTO main, and
# the push arm fires after the merge. Reading every arm therefore refused a key
# on `push:` for a hazard that key cannot cause — and it is the same predicate
# scripts/shim-trigger-filter-check.sh has always used
# (`on.pull_request.paths`/`paths-ignore`, nothing else). The mutant below
# plants its filter on `pull_request`, so this assertion still fires.
emit("workflow_paths", any(
    isinstance((on or {}).get(arm), dict)
    and ("paths" in on[arm] or "paths-ignore" in on[arm])
    for arm in ("pull_request", "pull_request_target")))

# THE VENUE PIN, the positive half (task-7ef9d81ed33d2b9c). The push:main arm
# IS paths-filtered on purpose — measured 2026-09-10T11:30Z, 11 of the day's 122
# stacked push:main runs were this workflow, every one for a superseded sha, and
# this workflow is per-sha grouped so it never collapses. Asserted TRUE below so
# deleting that filter is a RED here and not a silent return to a full run per
# merge; scripts/main-verdict-presence.sh re-derives the same key into the
# ALWAYS/CONDITIONAL tier of .github/main-push-workflows.txt.
push = (on or {}).get("push")
emit("push_paths", isinstance(push, dict) and "paths" in push)

agg = jobs.get(AGG, {})
needs = list(agg.get("needs", []))
emit("agg_present", bool(agg))
emit("agg_matrix", "strategy" in agg and "matrix" in agg.get("strategy", {}))
emit("agg_if", str(agg.get("if")).strip())
emit("agg_name", agg.get("name"))
emit("agg_needs", ",".join(needs))

# DERIVED, never hardcoded — see the header. A continue-on-error job in `needs`
# launders a red into a green required context.
coe = [n for n, j in jobs.items() if j.get("continue-on-error") is True]
emit("coe_jobs", ",".join(sorted(coe)))
emit("coe_in_needs", ",".join(sorted(set(coe) & set(needs))))
# NOTE: the three coe_* verdicts that actually gate this harness are emitted
# further down, after the aggregator's env bindings and decide() call sites have
# been parsed — they are predicates over BOTH sides of the wiring.

# THE POST-VERDICT CATEGORY, ported verbatim in shape from
# scripts/cloud-path-escape-check.test.sh, where cloud.yml's identical reporter
# already forced it. Exactly one shape of blocking job legitimately cannot live
# in `needs`: a reporter that runs AFTER the aggregator concluded, to carry
# main's own red to a human. Wiring it in is not a trade-off, it is a CYCLE
# (security-gate -> reporter -> security-gate) and GitHub refuses to load it.
#
# THIS IS A PREDICATE, NOT A SKIP LIST — a named exemption would go stale the
# moment a second reporter is added, and would also exempt a job that merely
# borrowed the name. A job is post-verdict iff ALL THREE hold:
#   (1) needs == [AGG] EXACTLY — so `needs` really is the cycle, not a wiring
#       decision somebody declined to make;
#   (2) its `if:` starts with an ANCHORED failure(). The loose \bfailure\(\)
#       admits `success() || failure()` — a job that runs on EVERY GREEN wearing
#       post-verdict clothes. The anchor is load-bearing;
#   (3) it is NOT continue-on-error, so it keeps its own exit-1. That retained
#       can-lose property is what the exemption is granted in exchange for; a
#       MUTED reporter is named by post_verdict_muted and never exempted.
POST_VERDICT_IF = re.compile(r"^failure\(\)(\s|&|$)")
def post_verdict_shape(j):
    return (list(j.get("needs") or []) == [AGG]
            and bool(POST_VERDICT_IF.match(str(j.get("if", "")).strip())))
post_verdict = {n for n, j in jobs.items()
                if post_verdict_shape(j) and j.get("continue-on-error") is not True}
post_verdict_muted = {n for n, j in jobs.items()
                      if post_verdict_shape(j) and j.get("continue-on-error") is True}
emit("post_verdict_jobs", ",".join(sorted(post_verdict)))
emit("post_verdict_muted", ",".join(sorted(post_verdict_muted)))

# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job in this
# workflow that nobody wired into `needs`. The aggregator cannot judge a job it
# was never told about, so it greens while that job reds. Post-verdict jobs are
# subtracted — they cannot be in `needs` without a cycle, and they are held to
# the three-part predicate above instead, which is STRICTER, not laxer.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != AGG}
emit("blocking_not_in_needs",
     ",".join(sorted(blocking - set(needs) - post_verdict)))

# D36 — THE OTHER HALF OF THAT GUARD. Reaching `needs` alone changes nothing:
# `needs.<job>.result` is only consulted if the job is bound to a step env var
# AND that var is passed to `decide`. Walk the whole chain per job —
#   needs entry -> env var bound to needs.<job>.result -> decide's 2nd argument
# — and name every job that falls out of it. The decide side keys on the SECOND
# positional argument, which is label-independent: the first argument is a human
# label that deliberately does not match the job name.
step = next((s for s in agg.get("steps", []) if "run" in s), {})
var_for = {}
for var, expr in (step.get("env") or {}).items():
    m = re.search(r"needs\.([A-Za-z0-9_.-]+)\.result", str(expr))
    if m:
        var_for[m.group(1)] = var
consumed = set(re.findall(
    r'^\s*decide\s+"[^"]*"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"',
    step.get("run", ""), re.M))

# ── THE CORRECTED LAUNDERING PREDICATE (dr-w25-bl-security-gate-cannot-see-
#    sobelow, 2026-09-17) ─────────────────────────────────────────────────────
# The old rule was a blanket ban: no continue-on-error job may appear in
# `needs`, full stop. That ban is WIDER THAN ITS OWN MEASUREMENT. What was
# measured is that `needs.<job>.result` reads `success` over a FAILED
# continue-on-error job. `continue-on-error` does not touch a job's OUTPUTS, so
# `needs.<job>.outputs.verdict` arrives intact — and the blanket ban therefore
# forbade the one honest way to aggregate such a job, which is why a fresh
# Sobelow finding reached no rollup at all for as long as it stood.
#
# THE RULE NOW, a predicate over both sides of the wiring rather than a list. A
# continue-on-error job in `needs` is ACCEPTABLE iff ALL THREE hold:
#   (1) the job declares `outputs.verdict`;
#   (2) the aggregator binds `needs.<job>.outputs.verdict` to an env var;
#   (3) the aggregator does NOT bind that job's `.result` to any env var
#       (binding it is the hazard; a bound var is one edit away from a
#       decide() call, and the ban must sit on the binding, not on the call).
# Anything else is the original laundering hazard, named by job.
verdict_var_for = {}
for var, expr in (step.get("env") or {}).items():
    m = re.search(r"needs\.([A-Za-z0-9_.-]+)\.outputs\.verdict", str(expr))
    if m:
        verdict_var_for[m.group(1)] = var
coe_in_needs = set(coe) & set(needs)
def verdict_channelled(n):
    # (1) the job declares outputs.verdict, (2) the aggregator binds it, AND
    # the declaration is not a dangling reference: `outputs.verdict` names a
    # `steps.<id>.outputs.verdict`, and a step with that id must still exist in
    # the job. Deleting the Publish step leaves the output permanently empty
    # while the `outputs:` block still LOOKS wired — an absence that inspection
    # cannot catch, so it is a parse, not a read.
    j = jobs.get(n, {})
    expr = str((j.get("outputs") or {}).get("verdict", ""))
    m = re.search(r"steps\.([A-Za-z0-9_-]+)\.outputs\.verdict", expr)
    if not m:
        return False
    if not any(st.get("id") == m.group(1) for st in (j.get("steps") or [])):
        return False
    return n in verdict_var_for
emit("coe_verdict_judged",
     ",".join(sorted(n for n in coe_in_needs if verdict_channelled(n))))
# MUST be empty: a continue-on-error job in needs with no verdict channel.
emit("coe_in_needs_unchannelled",
     ",".join(sorted(n for n in coe_in_needs if not verdict_channelled(n))))
# MUST be empty: a continue-on-error job whose laundered `.result` is bound at
# all in the aggregator.
emit("coe_result_bound",
     ",".join(sorted(n for n in coe_in_needs if n in var_for)))
# Companion cardinality: an empty difference computed from an empty set proves
# nothing, so a neutered `outputs.verdict` regex reds instead of going serene.
emit("verdict_bindings_count", len(verdict_var_for))

# D36, AMENDED. Every job in `needs` must actually be judged — on its `.result`
# via decide(), OR, for a verdict-judged continue-on-error job, on its verdict.
# Subtracting the latter is not a loophole: coe_in_needs_unchannelled and
# coe_result_bound above hold that set to a STRICTER standard than decide().
emit("needs_without_decide",
     ",".join(sorted(j for j in needs
                     if var_for.get(j) not in consumed
                     and not (j in coe_in_needs and verdict_channelled(j)))))

# Companion cardinalities. An empty difference is only meaningful if the sets it
# is computed from are populated: a regex that stopped matching would report a
# serene "" forever. These make a NEUTERED detector red instead.
emit("needs_count", len(needs))
emit("needs_results_count", len(var_for))
emit("decide_consumes_count", len(consumed))
emit("blocking_count", len(blocking))

disp = jobs.get("changes", {})
emit("dispatcher_present", bool(disp))
emit("dispatcher_if", str(disp.get("if", "")))
emit("dispatcher_matrix", "strategy" in disp)
emit("dispatcher_outputs", ",".join(sorted(disp.get("outputs", {}))))

# Every heavy job must be gated on the dispatcher, never on a path filter.
for n in sorted(n for n in jobs if n not in (AGG, "changes")):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
    emit(f"needs::{n}", ",".join(
        [jobs[n]["needs"]] if isinstance(jobs[n].get("needs"), str)
        else list(jobs[n].get("needs", []))))
out.close()
PY

FACTS="$TMPROOT/security-yml-facts.txt"
python3 "$EMIT" "$WF" "$FACTS"

fact() { sed -n "s|^$1=||p" "$FACTS"; }
assert_fact() {
  if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi
}
# A lower bound, never an equality: pinning the exact roster would red this
# harness the day a legitimate blocking job is added, which is churn, not
# safety. The bound only has to exclude ZERO — what a broken parser returns.
assert_fact_min() {
  local got
  got="$(fact "$1")"
  case "$got" in
    '' | *[!0-9]*) no "$1 = '$got' — not a number, the emitter is broken" ;;
    *)
      if [ "$got" -ge "$2" ]; then ok "$1 = $got (>= $2)"; else
        no "$1 = $got, wanted >= $2 — the detector is neutered, not the tree clean"
      fi
      ;;
  esac
}

echo "case 1: security.yml carries the shim shape"
assert_fact workflow_paths False
assert_fact push_paths True
assert_fact agg_present True
assert_fact agg_matrix False
assert_fact agg_if "always()"
assert_fact agg_name "Security gate"
assert_fact dispatcher_present True
assert_fact dispatcher_if ""
assert_fact dispatcher_matrix False
# TWO outputs since 2026-09-20 (task-76e529e61d9e34d0): `api` gates the three
# code-reading jobs, `locks` gates mix-audit, whose question is about the
# lockfiles and not about any source file. Pinned as the exact comma-joined set,
# so ADDING a third — a new venue split nobody judged in the aggregator — reds
# here, and so does silently dropping `locks` back to one.
assert_fact dispatcher_outputs "api,locks"
echo "  info — continue-on-error jobs in security.yml: '$(fact coe_jobs)'"
echo "  info — Security gate needs: '$(fact agg_needs)'"
echo

echo "case 2: THE LAUNDERING GUARD and its mirror"
# THE assertion, CORRECTED 2026-09-17 (see the emitter block of the same name).
# It is no longer `coe_in_needs = ""`. That blanket ban forbade the only honest
# way to aggregate a continue-on-error job — its `outputs.verdict`, which
# `continue-on-error` does not launder — and the cost was that a fresh Sobelow
# finding reached NO rollup at all: it reddened one advisory, unaggregated,
# unrequired check run and nothing else could tell it from "Sobelow never ran".
# The two assertions below are the predicate that replaced it. Neither is
# hardcoded to `sobelow`; both are derived from security.yml.
#
#   * a continue-on-error job in `needs` with no verdict channel IS the
#     laundering hazard, unchanged;
#   * a continue-on-error job whose `.result` is bound in the aggregator at all
#     is one edit from being judged on the laundered channel.
assert_fact coe_in_needs_unchannelled ""
assert_fact coe_result_bound ""
assert_fact_min verdict_bindings_count 3
echo "  info — continue-on-error jobs judged on outputs.verdict: '$(fact coe_verdict_judged)'"
# Every blocking job must be IN needs. Self-correcting by construction: the day
# sobelow loses continue-on-error, it moves from the first set into the second
# and this line demands it be added.
assert_fact blocking_not_in_needs ""
# The reporter that carries main's post-merge red to a human is the one blocking
# job that cannot be in `needs` (it would be a cycle). It must be present, and
# it must not be muted: a continue-on-error reporter cannot report its own
# non-delivery, which is the failure this arm exists to make loud.
assert_fact post_verdict_jobs "report-main-failure"
assert_fact post_verdict_muted ""
# …and every job that IS in needs must actually be judged (D36).
assert_fact needs_without_decide ""
assert_fact_min needs_count 3
assert_fact_min needs_results_count 3
assert_fact_min decide_consumes_count 3
assert_fact_min blocking_count 3
echo

echo "case 3: every heavy job is gated on the dispatcher, not on a path filter"
# THE THREE CODE-READING JOBS share one gate: they analyse api/ source, so any
# api/ change can change what they say.
for j in sobelow sobelow-inline-overlap sobelow-baseline-fingerprint; do
  assert_fact "if::$j" "needs.changes.outputs.api == 'true'"
  assert_fact "needs::$j" "changes"
done
# mix-audit IS NOT ONE OF THEM (2026-09-20, task-76e529e61d9e34d0). It reads no
# source at all: it resolves the LOCKFILES against an advisory database, so its
# gate is the lock set, not the api set. This line is the ratchet on that
# decision — it is pinned by predicate, so silently reverting the job to the
# `api` gate (which would put 2.58 median minutes back on every api/ PR push)
# reds here by name rather than passing as "still gated on the dispatcher".
assert_fact "if::mix-audit" "needs.changes.outputs.locks == 'true'"
assert_fact "needs::mix-audit" "changes"
# …and the gate it is judged against in the aggregator must be the SAME output.
# A job gated on `locks` and judged against `O_API` reds every lock-untouched
# api/ PR ("skipped though its gate said true"), which is the exact wiring
# mistake this pair exists to make impossible to leave half-done.
if grep -Eq '^ *decide "mix-audit" +"\$\{R_AUDIT\}" +"\$\{O_LOCKS' "$WF"; then
  ok "the aggregator judges mix-audit's skip against O_LOCKS, the output that gates it"
else
  no "the aggregator does not judge mix-audit against O_LOCKS — a skip authorised by locks=false would red"
fi
if grep -q 'O_LOCKS: \${{ needs.changes.outputs.locks }}' "$WF"; then
  ok "the aggregator binds O_LOCKS from the dispatcher"
else
  no "O_LOCKS is not bound in the aggregator — it would always be empty, and an empty gate is not 'false'"
fi
echo

# ── case 4: the mutants — every assertion above must be able to FIRE ────────
# `coe_in_needs = ""` and `blocking_not_in_needs = ""` prove nothing unless the
# same emitter, on the same file, returns a non-empty answer when the shape is
# genuinely broken.
echo "case 4: each assertion is proven able to fail"
MUT="$TMPROOT/mutate-security-yml.py"
cat >"$MUT" <<'PY'
import sys, yaml

src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
jobs = wf["jobs"]
agg = jobs["security-gate"]
step = next(s for s in agg["steps"] if "run" in s)
assert mode in ("clean", "launder", "unwired", "orphan", "paths", "pushpaths", "matrix",
                "reporter-muted", "reporter-alwaysruns", "reporter-unwired",
                "coe-unchannelled", "coe-result-bound", "verdict-step-deleted"), mode

if mode == "launder":
    # Add a NEW continue-on-error job to needs with no verdict channel at all —
    # the exact laundering regression, in the shape it actually arrives in
    # (someone wires a muted job into the rollup and reads its result).
    jobs["fleet-drift"] = {"runs-on": "ubuntu-latest", "continue-on-error": True,
                           "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["fleet-drift"]
elif mode == "coe-unchannelled":
    # The real regression THIS change guards: somebody deletes the `outputs:`
    # block from the continue-on-error job that IS in needs. Its verdict binding
    # then resolves to empty at run time and the aggregator is blind again —
    # while `needs` still lists it, so the shape LOOKS wired.
    for n, j in jobs.items():
        if j.get("continue-on-error") is True and n in agg["needs"]:
            j.pop("outputs", None)
elif mode == "coe-result-bound":
    # The laundered channel, re-bound. Reading `.result` for a continue-on-error
    # job is `success` over a red; the ban sits on the BINDING, not on the call.
    for n, j in jobs.items():
        if j.get("continue-on-error") is True and n in agg["needs"]:
            step["env"]["R_LAUNDERED"] = "${{ needs.%s.result }}" % n
            break
elif mode == "verdict-step-deleted":
    # The other half of the same regression: the job keeps `outputs.verdict`,
    # but the step that populates it is gone, so the output is permanently the
    # empty string. Caught by the emitter's `outputs.verdict` -> step id chain.
    for n, j in jobs.items():
        if j.get("continue-on-error") is True and n in agg["needs"]:
            j["steps"] = [st for st in j["steps"] if st.get("id") != "verdict"]
elif mode == "unwired":
    # Drop a real blocking job out of needs: the aggregator can no longer judge
    # it, and would green while it reds.
    agg["needs"] = [n for n in agg["needs"] if n != "mix-audit"]
elif mode == "orphan":
    # In needs, but never bound to an env var and never passed to decide.
    jobs["a11y-ceiling"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["a11y-ceiling"]
elif mode == "paths":
    on = wf.pop(True, None) or wf.pop("on", None)
    on["pull_request"] = {"paths": ["api/**"]}
    wf["on"] = on
elif mode == "pushpaths":
    # THE VENUE PIN's negative half: strip the push arm's paths filter and the
    # workflow is back to a full run on every merge to main.
    on = wf.pop(True, None) or wf.pop("on", None)
    on["push"].pop("paths", None)
    wf["on"] = on
elif mode == "matrix":
    agg["strategy"] = {"matrix": {"otp": ["27.0"]}}
elif mode == "reporter-muted":
    # A MUTED reporter cannot report its own non-delivery. It must lose the
    # exemption and fall back into blocking_not_in_needs.
    jobs["report-main-failure"]["continue-on-error"] = True
elif mode == "reporter-alwaysruns":
    # `success() || failure()` runs on EVERY GREEN wearing post-verdict clothes.
    # The anchored regex must refuse it.
    jobs["report-main-failure"]["if"] = "success() || failure()"
elif mode == "reporter-unwired":
    # A blocking job that merely LOOKS post-verdict because someone deleted its
    # needs must NOT be exempted — that is the mirror hazard, not a reporter.
    jobs["report-main-failure"]["needs"] = []

yaml.safe_dump(wf, open(dst, "w"))
PY

# mutant <mode> <fact> <expected>
mutant() {
  local mode="$1" key="$2" want="$3" f="$TMPROOT/mut-$1.yml" ff="$TMPROOT/mut-$1.facts" got
  # `clean` goes through the same load/dump round-trip as the broken copies, so
  # the ONLY variable between them is the mutation itself.
  python3 "$MUT" "$WF" "$f" "$mode"
  python3 "$EMIT" "$f" "$ff"
  got="$(sed -n "s|^${key}=||p" "$ff")"
  if [ "$got" = "$want" ]; then
    ok "mutation[$mode]: $key = '${got}'"
  else
    no "mutation[$mode]: $key = '${got}', wanted '${want}'"
  fi
}

mutant clean    coe_in_needs_unchannelled ""            # round-trip alone is silent
mutant clean    coe_result_bound          ""
mutant clean    blocking_not_in_needs ""
# The laundering regression, in each of the three shapes it arrives in. Every
# one of these was INVISIBLE to the blanket `coe_in_needs = ""` rule's
# replacement until it was proven able to fire here.
mutant launder  coe_in_needs_unchannelled "fleet-drift"   # a muted job wired in raw
mutant launder  needs_without_decide      "fleet-drift"   # …and unjudged on either channel
mutant coe-unchannelled coe_in_needs_unchannelled "sobelow"   # outputs: block deleted
mutant coe-unchannelled needs_without_decide      "sobelow"
mutant verdict-step-deleted coe_in_needs_unchannelled "sobelow"  # Publish step deleted
mutant coe-result-bound coe_result_bound          "sobelow"   # the laundered channel re-bound
# …and the corrected rule still ACCEPTS the shipped shape, which is the arm that
# would go silent if verdict_channelled() were neutered to always-False.
mutant clean    coe_verdict_judged        "sobelow"
mutant unwired  blocking_not_in_needs "mix-audit"       # an unjudged blocking job is DETECTED
mutant orphan   needs_without_decide  "a11y-ceiling"    # reaching needs is not enough (D36)
mutant paths    workflow_paths        "True"            # a re-added pull_request paths is DETECTED
mutant clean    push_paths            "True"            # the venue pin is TRUE on the shipped file
mutant pushpaths push_paths           "False"           # deleting the push paths filter is DETECTED
mutant matrix   agg_matrix            "True"            # a matrixed aggregator is DETECTED
# The post-verdict exemption is a PREDICATE, and each of its three clauses is
# proven able to withdraw it.
mutant clean            post_verdict_jobs     "report-main-failure"
mutant clean            post_verdict_muted    ""
mutant reporter-muted   post_verdict_jobs     ""                    # clause (3): muting withdraws it
mutant reporter-muted   post_verdict_muted    "report-main-failure"
# A MUTED reporter does NOT fall into blocking_not_in_needs — continue-on-error
# removes it from `blocking` in the first place. Its detector is
# post_verdict_muted above (which fires, one line up); this line pins that the
# mirror guard is NOT the detector, so nobody later reads its silence as cover.
mutant reporter-muted   blocking_not_in_needs ""
mutant reporter-alwaysruns post_verdict_jobs  ""                    # clause (2): an unanchored if is refused
mutant reporter-alwaysruns blocking_not_in_needs "report-main-failure"
mutant reporter-unwired post_verdict_jobs     ""                    # clause (1): empty needs is not the cycle
mutant reporter-unwired blocking_not_in_needs "report-main-failure"
echo

# ── case 5: the dispatcher, driven against a real git repo ─────────────────
# The step body is EXTRACTED FROM security.yml and executed, so this cannot
# drift from what CI runs. The two `${{ … }}` expressions are substituted from
# the environment so the body can run outside Actions.
echo "case 5: the dispatcher fails rather than skips when it cannot tell"
DISP="$TMPROOT/dispatch-step.sh"
python3 - "$WF" "$DISP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["changes"]["steps"] if s.get("id") == "sets"][0]
body = (step["run"]
        .replace("${{ github.event_name }}", "${T_EVENT}")
        .replace("${{ github.event.pull_request.base.sha }}", "${T_BASE}"))
open(sys.argv[2], "w").write(body)
PY

OUT="$TMPROOT/step.out"
DR="$TMPROOT/dispatchrepo"
mkdir -p "$DR/api/lib" "$DR/docs" "$DR/.github/workflows"
: >"$DR/api/lib/thing.ex"
# NON-EMPTY on purpose: the rename cases below need git's rename detection to
# actually fire, and an empty blob is not a rename source worth the name.
printf 'moved-a\nmoved-b\nmoved-c\n' >"$DR/api/lib/moved.ex"
: >"$DR/docs/guide.md"
: >"$DR/.github/workflows/security.yml"
: >"$DR/.github/workflows/elixir.yml"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# dispatch <label> <expected-rc> <expected-api> <event> <base> <expected-locks>
#
# THE SIXTH ARGUMENT IS REQUIRED, not optional (2026-09-20,
# task-76e529e61d9e34d0). An optional one would leave every pre-existing call
# site silently unmeasured on the new output, and an output no arm reads is
# exactly how a venue split disarms a gate without reddening anything. `-` is
# the explicit "this arm does not reach a verdict" marker, the same spelling the
# api column already uses for the refusal cases.
dispatch() {
  local label="$1" want="$2" wa="$3" ev="$4" bs="$5" wl="${6:?dispatch: the expected locks value is required}"
  local rc got gotl
  : >"$TMPROOT/gh_output"
  (cd "$DR" && env T_EVENT="$ev" T_BASE="$bs" GITHUB_OUTPUT="$TMPROOT/gh_output" \
    bash --noprofile --norc "$DISP") >"$OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$OUT" >&2
    return 0
  fi
  # A bare `return` here would propagate the test's exit status and, under
  # `set -e`, abort the whole harness mid-run — silently truncating the
  # remaining cases into an apparent pass.
  [ "$want" -eq 0 ] || return 0
  got="$(sed -n 's/^api=//p' "$TMPROOT/gh_output")"
  if [ "$got" = "$wa" ]; then
    ok "  …emits api=$got"
  else
    no "  …emitted api=$got, wanted api=$wa"
  fi
  gotl="$(sed -n 's/^locks=//p' "$TMPROOT/gh_output")"
  if [ "$gotl" = "$wl" ]; then
    ok "  …emits locks=$gotl"
  else
    no "  …emitted locks='$gotl', wanted locks=$wl"
  fi
}

says() {
  if has "$(cat "$OUT")" "$1"; then ok "  …$2"; else
    no "  …never printed '$1': $(cat "$OUT")"
  fi
}

# a docs-only PR is the whole point of the shim: skip the heavy jobs honestly —
# and, unlike the old workflow-level filter, still publish a check run.
git -C "$DR" checkout -q -b docs-only
: >"$DR/docs/another.md"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
dispatch "docs-only PR" 0 false pull_request "$BASE_SHA" false

git -C "$DR" checkout -q -b apichange "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/thing.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm api >/dev/null 2>&1
dispatch "api/** PR" 0 true pull_request "$BASE_SHA" false

# the workflow's own file is in the set — editing the gate must run the gate
git -C "$DR" checkout -q -b wfchange "$BASE_SHA"
printf 'x\n' >"$DR/.github/workflows/security.yml"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm wf >/dev/null 2>&1
dispatch "security.yml-only PR" 0 true pull_request "$BASE_SHA" true

# …and a NEIGHBOURING workflow is not, so the filter is a filter and not a
# tautology that returns true for everything.
git -C "$DR" checkout -q -b otherwf "$BASE_SHA"
printf 'x\n' >"$DR/.github/workflows/elixir.yml"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm otherwf >/dev/null 2>&1
dispatch "elixir.yml-only PR" 0 false pull_request "$BASE_SHA" false

# ── THE LOCK SET (task-76e529e61d9e34d0) ─────────────────────────────────
# `api/** PR` above already carries the headline: api=true with locks=FALSE —
# an api/lib edit runs Sobelow and does NOT run the CVE audit. These two arms
# are the other side of it, so the pair cannot pass by the lock arm being
# unreachable: a lockfile edit MUST dispatch the audit, and a lockfile in the
# OTHER tree (cloud/) must too, because the second oracle reads both.
git -C "$DR" checkout -q -b lockchange "$BASE_SHA"
mkdir -p "$DR/api"
printf 'lock\n' >"$DR/api/mix.lock"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm lock >/dev/null 2>&1
dispatch "api/mix.lock PR" 0 true pull_request "$BASE_SHA" true

git -C "$DR" checkout -q -b cloudlock "$BASE_SHA"
mkdir -p "$DR/cloud"
printf 'lock\n' >"$DR/cloud/mix.lock"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm cloudlock >/dev/null 2>&1
# api=FALSE, locks=TRUE — the ONE shape that proves the two outputs are
# independent and not two names for the same predicate. (The job is still gated
# behind this dispatcher only; the pre-existing topological note in the
# mix-audit step about cloud-only PRs is what this arm now makes reachable.)
dispatch "cloud/mix.lock-only PR" 0 false pull_request "$BASE_SHA" true

git -C "$DR" checkout -q -b oraclechange "$BASE_SHA"
mkdir -p "$DR/scripts"
printf 'x\n' >"$DR/scripts/hex-audit-oracle.sh"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm oracle >/dev/null 2>&1
dispatch "the oracle script itself" 0 false pull_request "$BASE_SHA" true

# push to main never skips, regardless of what changed — BOTH sets, because a
# `locks` that forgot this arm would strand the CVE audit off main entirely and
# the venue move would be a deletion wearing a venue move's comment.
dispatch "push event" 0 true push "" true

# ── THE FALSE-GREEN CLASSES the plain `--name-only` producer let through ────
# Wave 10 closed these in elixir.yml, cloud.yml and console-harness.yml; this
# workflow was transplanted from the PRE-FIX shim and carried them in. Every
# probe above this line is ASCII and rename-free, which is exactly why the shape
# ratchet could not have caught either family — and here the consequence is that
# `Security gate` greens over a Sobelow/mix-audit run that never happened.
# `git diff --name-only` QUOTES a path containing `"` (even under
# core.quotepath=false), and rename detection prints only the DESTINATION.

# (1) a DOUBLE-QUOTE path inside the declared set. Not merely a non-ASCII one:
#     core.quotepath=false silences the octal escaping and leaves this class
#     wide open, so a fix tested only against é would certify a hole.
git -C "$DR" checkout -q -b dquote "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/we\"ird.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1
dispatch 'a path containing a double quote' 0 true pull_request "$BASE_SHA" false

# (2) a rename OUT of the declared set. Analysed code just left api/** — the
#     scan MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv api/lib/moved.ex docs/moved.ex >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true pull_request "$BASE_SHA" false

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md api/lib/guide.md >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renamein >/dev/null 2>&1
dispatch "a rename INTO the declared set" 0 true pull_request "$BASE_SHA" false

# THE FAILURE PATHS — the polarity that makes the shim safe.
# An empty diff is the ONE "cannot tell" that does not fail: a revert pair or a
# branch-sync PR nets to nothing and is perfectly legal, and an ::error:: there
# leaves its author with a red check run and no self-service fix. It dispatches
# TRUE — the whole security suite: expensive, never wrong. Everything else reds.
git -C "$DR" checkout -q -b emptydiff "$BASE_SHA"
dispatch "empty diff (base == HEAD)" 0 true pull_request "$(git -C "$DR" rev-parse HEAD)" true
says "changed-file set is EMPTY" "names the shape"
says "::warning" "as a WARNING, not a brick"
dispatch "unresolvable base sha" 1 - pull_request 0000000000000000000000000000000000000000 -
says "not resolvable in this checkout" "refuses to guess a base"
says "::error::" "refuses with an annotation"
dispatch "missing base sha" 1 - pull_request "" -
says "carries no base sha" "says why"
says "::error::" "refuses with an annotation"

# a base with NO common ancestor: `git diff base...HEAD` exits 128 with a bare
# `fatal: … no merge base` and zero annotation. Named, not fatalled.
git -C "$DR" checkout -q --orphan noancestor >/dev/null 2>&1
git -C "$DR" rm -rq --cached . >/dev/null 2>&1 || true
rm -rf "${DR:?}/api" "${DR:?}/docs"
mkdir -p "$DR/api/lib"
printf 'z\n' >"$DR/api/lib/orphan.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm orphan >/dev/null 2>&1
dispatch "a base with no common ancestor" 1 - pull_request "$BASE_SHA" -
says "share NO common ancestor" "names the condition, not a raw git fatal"
says "refusing a two-dot fallback" "refuses the fallback that sweeps in the whole base"
echo

# ── case 6: the Security gate decides, and can be made red on purpose ───────
# The step body is EXTRACTED FROM security.yml and executed, so this cannot be a
# paraphrase of what CI runs. Each case supplies exactly the env GitHub would.
echo "case 6: the Security gate decides over every upstream result"
AGG="$TMPROOT/security-gate-step.sh"
python3 - "$WF" "$AGG" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["security-gate"]["steps"] if "run" in s][0]
open(sys.argv[2], "w").write(step["run"])
PY

# gate <label> <expected-rc> KEY=VAL...
gate() {
  local label="$1" want="$2" rc
  shift 2
  # V_SOBELOW defaults to the clean verdict so the pre-existing arms below keep
  # measuring what they were written to measure; `env` takes the LAST occurrence
  # of a name, so any caller that passes its own V_SOBELOW overrides this.
  env -i PATH="$PATH" HOME="$HOME" V_SOBELOW=MEASURED-CLEAN "$@" bash --noprofile --norc "$AGG" >"$OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$OUT" >&2
  fi
}

gate "everything succeeded" 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true
gate "docs-only: gated jobs skipped against api=false" 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=false O_LOCKS=false V_SOBELOW=
# ── THE VENUE MOVE, BOTH DIRECTIONS (task-76e529e61d9e34d0) ────────────────
# The new shape is api=true + locks=false: an api/ PR that does not move a
# lockfile. Without the first arm the move is unmeasured; without the second the
# gate would accept ANY mix-audit skip and the move would have silently disarmed
# the CVE audit's aggregation instead of relocating it. Both arms run the
# EXTRACTED step body, so neither is a paraphrase of the decision in CI.
gate "api PR that touches no lockfile: the CVE audit skipped against locks=false" 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=skipped O_API=true O_LOCKS=false
gate "the CVE audit skipped though locks said true" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=skipped O_API=true O_LOCKS=true
gate "the CVE audit skipped with an EMPTY locks gate (unbound O_LOCKS)" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=skipped O_API=true
gate "a blocking job FAILED" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=failure O_API=true
gate "the CVE audit was CANCELLED" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=cancelled O_API=true
gate "a job skipped though its gate said true" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=success R_AUDIT=success O_API=true O_LOCKS=true
gate "the dispatcher itself failed" 1 \
  R_CHANGES=failure R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=
gate "an EMPTY result (job not in needs)" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT= O_API=true
gate "an unrecognised result" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=neutral O_API=true
# The shape ratchet is unfiltered, so a SKIP of it is never legitimate — it can
# only mean the job never ran. Without this clause the new needs entry would be
# judged by `decide` but never exercised in any direction that can red.
gate "the shape ratchet was SKIPPED (never legitimate — it is unfiltered)" 1 \
  R_CHANGES=success R_SHAPE=skipped R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true
gate "the shape ratchet FAILED" 1 \
  R_CHANGES=success R_SHAPE=failure R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true
# Same reasoning for the fingerprint ratchet: reaching `needs` and being read by
# `decide` proves it is WIRED, not that either verdict travels. These two drive
# it in the only directions that can red.
gate "the fingerprint ratchet FAILED" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=failure R_AUDIT=success O_API=true
gate "the fingerprint ratchet skipped though its gate said true" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=skipped R_AUDIT=success O_API=true
echo

# ── case 6b: the Sobelow verdict actually travels (dr-w25-bl-security-gate-
#    cannot-see-sobelow) ──────────────────────────────────────────────────────
# The whole point of the change these arms guard: BEFORE it, the extracted step
# body above exited 0 for EVERY Sobelow state — MEASURED-DEFECT, REFUSED,
# UNKNOWN and empty alike, with `needs.sobelow.result` set to `failure` or to
# `success`, 8 of 8 green — because `sobelow` was in no `needs` and bound to no
# env var. The gate could not distinguish "Sobelow found nothing" from "Sobelow
# was never in the picture". Each arm below is one of those eight worlds, now
# driven through the channel `continue-on-error` cannot launder.
#
# These use the REAL vocabulary scripts/run-instrument.sh emits
# (MEASURED-CLEAN / MEASURED-DEFECT / REFUSED / UNKNOWN / empty) — a fixture
# encoding a shape the tool never emits measures nothing.
echo "case 6b: a Sobelow regression reaches the aggregate"
gate "Sobelow measured clean" 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=MEASURED-CLEAN
gate "Sobelow found a NEW finding (the regression this gate was blind to)" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=MEASURED-DEFECT
says "MEASURED-DEFECT" "names the verdict, not just 'something is wrong'"
gate "Sobelow REFUSED to measure — not installed, crashed, wiring broken" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=REFUSED
says "REFUSED TO MEASURE" "an unreadable result is CANNOT READ, never a pass"
gate "Sobelow exited on a signal (UNKNOWN)" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=UNKNOWN
# THE ABSENCE ARM. An empty verdict on a DISPATCHED job is the shape a deleted
# Publish step, an early job death, or a broken binding all produce — and it is
# exactly the state the old wiring made indistinguishable from clean.
gate "Sobelow was dispatched and published NO verdict" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=
says "CANNOT READ is not a pass" "refuses over the hole instead of greening"
gate "an unrecognised verdict word" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=success O_API=true V_SOBELOW=neutral
# …and the one legitimate empty: the dispatcher said api was untouched, so the
# job never ran. Without this arm the CANNOT-READ rule above would red every
# docs-only head.
gate "docs-only: Sobelow legitimately not dispatched" 0 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=false O_LOCKS=false V_SOBELOW=
echo

# ── case 7: the baseline census in security.yml's header is DERIVED, not told ─
#
# THE DEFECT THIS EXISTS FOR. security.yml's header carried a row count for
# api/.sobelow-skips. It read 57, then 41, then 35 — each true when written,
# each rotted in place. The wave that wrote 35 noticed the rot and its remedy
# was PROSE: it published the derivation command beside the number so "the next
# reader re-measures instead of trusting this line". Nobody ran it. Measured at
# 6c4b904f9 the file held 24 rows, and three of six per-class figures had
# drifted (Traversal.FileModule 18->9, DOS.StringToAtom 6->4, AST-anchored
# 28->17). A command in a comment is not an instrument — nothing executes it.
#
# This case executes it. The `census:` lines in the header are a table; the
# table is compared against the file it describes, and a mismatch NAMES the
# class that drifted rather than saying "something is stale".
#
# WHY IT BELONGS HERE. `gate-shape` is unfiltered and NEVER-gated, so it runs
# on every head, and it is a leaf of `Security gate` — which is ADVISORY
# (S7 exclusion, .github/required-checks.json), so this reds a context nobody
# merges on and blocks nothing. It is the same job that already pins the rest
# of this workflow's shape.
echo "case 7: the .sobelow-skips census in the header is compared, not trusted"

# census_diff <workflow-file> <baseline-file>
#   prints one line per disagreement; prints nothing when the table is true.
#   REFUSES loudly (prints a REFUSED line) when either input is unreadable or
#   the header carries no census table at all — an absent table must never read
#   as "nothing disagrees".
census_diff() {
  local wf="$1" bl="$2"
  if [ ! -r "$wf" ]; then echo "REFUSED: cannot read $wf"; return; fi
  if [ ! -r "$bl" ]; then echo "REFUSED: cannot read $bl"; return; fi

  local declared
  declared="$(sed -n 's/^#[[:space:]]*census:[[:space:]]*\(.*\)$/\1/p' "$wf")"
  if [ -z "$declared" ]; then
    echo "REFUSED: $wf declares no 'census:' table — an absent census is not a clean one"
    return
  fi

  # DERIVED, never hardcoded: total = non-blank rows; per-class = the detector
  # prefix before the first colon on each non-blank row.
  local actual
  actual="$(
    {
      awk 'NF{n++} END{printf "total=%d\n", n+0}' "$bl"
      grep -v '^[[:space:]]*$' "$bl" | sed 's/:.*//' | sort | uniq -c \
        | awk '{printf "%s=%d\n", $2, $1}'
    } | sort
  )"
  local want
  want="$(printf '%s\n' "$declared" | sed 's/[[:space:]]*$//' | sort)"

  # Both directions: a class that appeared in the file and was never declared is
  # as much a rot as a declared class that vanished.
  #
  # TEMP FILES, NOT `comm -3 <(…) <(…)`. Process substitution is a bashism that
  # scripts/posix-vacuous-green-census.sh reds on by name: under `sh` it is a
  # syntax error, and a harness that dies before its first assertion exits
  # having compared NOTHING while still looking like it ran. This file carries
  # no interpreter guard, so it must not contain one.
  local wf_want="$TMPROOT/census-want.$$" wf_have="$TMPROOT/census-have.$$"
  printf '%s\n' "$want"   > "$wf_want"
  printf '%s\n' "$actual" > "$wf_have"
  comm -3 "$wf_want" "$wf_have" \
    | sed -e 's/^\t/FILE-HAS-NOT-DECLARED: /' -e 's/^\([^ ]\)/DECLARED-NOT-IN-FILE: \1/'
  rm -f "$wf_want" "$wf_have"
}

CENSUS_BL="$REAL_ROOT/api/.sobelow-skips"

# ARM (b) — THE REAL TREE. This must be green against the baseline as it
# actually is, not a hypothetical clean one: a ratchet that reds on arrival gets
# dismissed and then guards nothing.
d="$(census_diff "$WF" "$CENSUS_BL")"
if [ -z "$d" ]; then
  ok "the header census matches api/.sobelow-skips exactly (real tree, both directions)"
else
  no "the header census disagrees with api/.sobelow-skips:"$'\n'"$d"
fi

# The declared table must actually be a table — this is the control that proves
# the arm above is not passing on an empty comparison (an absence is never
# caught by inspection: print the key set).
n_declared="$(sed -n 's/^#[[:space:]]*census:.*/x/p' "$WF" | wc -l | tr -d ' ')"
if [ "$n_declared" -ge 2 ]; then
  ok "the census table is non-empty ($n_declared rows declared) — the arm above compared something"
else
  no "the census table has $n_declared rows; the match above is vacuous"
fi

# ── the mutants: every assertion above must be able to FIRE ─────────────────
CENSUS_MUT="$TMPROOT/census"
mkdir -p "$CENSUS_MUT"

# M1 — the total rots (the exact historical failure: 57 -> 41 -> 35, file moved on)
sed 's/^#\([[:space:]]*\)census: total=.*/#\1census: total=999/' "$WF" > "$CENSUS_MUT/m1.yml"
d="$(census_diff "$CENSUS_MUT/m1.yml" "$CENSUS_BL")"
if has "$d" "total=999"; then
  ok "MUTANT total: a rotted row count fires, and the line names total"
else
  no "MUTANT total: a rotted row count did NOT fire"
fi

# M2 — one class rots while the total stays right (the half that a bare row
#      count can never see, and the half that actually drifted this time).
#
#      THE CLASS IS DERIVED FROM THE TABLE, NEVER TYPED. This arm used to sed
#      for the literal `Traversal.FileModule`, and when api #19726 emptied that
#      detector out of api/.sobelow-skips the correcting PR deleted the row --
#      at which point the sed matched nothing, the mutant was byte-identical to
#      the original, and the arm could not fire. It was caught only because the
#      `no` branch reds; a mutation arm that silently matches nothing is the
#      same vacuous green this whole case exists to prevent. An enumeration is
#      a snapshot of the roster; the rule is "whatever per-class row is there".
# NO TRUNCATING READER. The first draft of this ended `| grep -vx 'total' | head -1`,
# and `head` never reads to EOF: it takes its N lines and CLOSES the pipe, so the
# upstream `sed` dies of SIGPIPE and the command substitution yields 141 under
# pipefail — no buffer overrun needed. scripts/pipefail-sigpipe-scan.sh rates a
# head reader HIGH unless the producer is provably bounded, and this one is not:
# the census table's length is whatever security.yml declares. That one line took
# the high-confidence ratchet from its 89 baseline to 90 and reddened main.
# The fix is the scanner's own preference 1, no pipe to truncate: `grep -v` reads
# to EOF, and the shell takes the first line with a parameter expansion.
mut_class_list="$(sed -n 's/^#[[:space:]]*census:[[:space:]]*\([A-Za-z][A-Za-z0-9._]*\)=.*/\1/p' "$WF" \
  | grep -vx 'total' || true)"
mut_class="${mut_class_list%%$'\n'*}"
if [ -z "$mut_class" ]; then
  no "MUTANT per-class: the table declares no per-class row to mutate — nothing to prove"
else
  sed "s/^#\([[:space:]]*\)census: ${mut_class}=.*/#\1census: ${mut_class}=18/" "$WF" > "$CENSUS_MUT/m2.yml"
  # PLANT CHECK: the mutation must actually have changed the file. Without it a
  # sed that matches nothing yields a mutant equal to the original and the arm
  # below would be asserting against an unmutated table.
  if cmp -s "$WF" "$CENSUS_MUT/m2.yml"; then
    no "MUTANT per-class: the plant did not change the table (class '${mut_class}' did not sed) — the arm would have proven nothing"
  else
    d="$(census_diff "$CENSUS_MUT/m2.yml" "$CENSUS_BL")"
    if has "$d" "$mut_class"; then
      ok "MUTANT per-class: a drifted class fires even with the total correct (mutated '${mut_class}', derived from the table)"
    else
      no "MUTANT per-class: a drifted class did NOT fire (mutated '${mut_class}')"
    fi
  fi
fi

# M3 — the baseline gains a row and nobody updates the table
{ cat "$CENSUS_BL"; echo "XSS.Raw: Unsafe raw,lib/barkpark_web/nope.ex:1,DEADBEE"; } > "$CENSUS_MUT/m3-skips"
d="$(census_diff "$WF" "$CENSUS_MUT/m3-skips")"
if has "$d" "total="; then
  ok "MUTANT baseline-grew: adding a baseline row without touching the table fires"
else
  no "MUTANT baseline-grew: adding a baseline row did NOT fire"
fi

# M4 — a WHOLE CLASS appears in the file that the table never mentions. The
#      direction a one-way check misses.
{ cat "$CENSUS_BL"; echo "SQL.Query: SQL injection,lib/barkpark/nope.ex:1,DEADBEE"; } > "$CENSUS_MUT/m4-skips"
d="$(census_diff "$WF" "$CENSUS_MUT/m4-skips")"
if has "$d" "SQL.Query"; then
  ok "MUTANT new-class: an undeclared detector class fires by name"
else
  no "MUTANT new-class: an undeclared detector class did NOT fire"
fi

# M5 — the table is DELETED. The failure a "no disagreements" check reports as
#      clean unless it refuses on an absent table.
grep -v '^#[[:space:]]*census:' "$WF" > "$CENSUS_MUT/m5.yml"
d="$(census_diff "$CENSUS_MUT/m5.yml" "$CENSUS_BL")"
if has "$d" "REFUSED"; then
  ok "MUTANT table-deleted: an absent census REFUSES instead of reading clean"
else
  no "MUTANT table-deleted: an absent census read as clean — the hole this case exists for"
fi

# M6 — the baseline file is gone. Unreadable input is CANNOT READ, not a pass.
d="$(census_diff "$WF" "$CENSUS_MUT/does-not-exist")"
if has "$d" "REFUSED"; then
  ok "MUTANT baseline-missing: an unreadable baseline REFUSES rather than greening"
else
  no "MUTANT baseline-missing: an unreadable baseline read as clean"
fi
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
