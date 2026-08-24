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


# D18: a workflow-level paths filter emits NO check run — the required name then
# sits "is expected." forever and the PR is BLOCKED with nothing to fix.
emit("workflow_paths", any(
    isinstance(v, dict) and ("paths" in v or "paths-ignore" in v)
    for v in (on or {}).values()))

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

# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job in this
# workflow that nobody wired into `needs`. The aggregator cannot judge a job it
# was never told about, so it greens while that job reds.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != AGG}
emit("blocking_not_in_needs", ",".join(sorted(blocking - set(needs))))

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
emit("needs_without_decide",
     ",".join(sorted(j for j in needs if var_for.get(j) not in consumed)))

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
assert_fact agg_present True
assert_fact agg_matrix False
assert_fact agg_if "always()"
assert_fact agg_name "Security gate"
assert_fact dispatcher_present True
assert_fact dispatcher_if ""
assert_fact dispatcher_matrix False
assert_fact dispatcher_outputs "api"
echo "  info — continue-on-error jobs in security.yml: '$(fact coe_jobs)'"
echo "  info — Security gate needs: '$(fact agg_needs)'"
echo

echo "case 2: THE LAUNDERING GUARD and its mirror"
# THE assertion. Not hardcoded to `sobelow`: whatever carries continue-on-error
# must stay out of the aggregator's needs, because its `result` reads `success`
# even when the job concluded FAILURE.
assert_fact coe_in_needs ""
# Every blocking job must be IN needs. Self-correcting by construction: the day
# sobelow loses continue-on-error, it moves from the first set into the second
# and this line demands it be added.
assert_fact blocking_not_in_needs ""
# …and every job that IS in needs must actually be judged (D36).
assert_fact needs_without_decide ""
assert_fact_min needs_count 3
assert_fact_min needs_results_count 3
assert_fact_min decide_consumes_count 3
assert_fact_min blocking_count 3
echo

echo "case 3: every heavy job is gated on the dispatcher, not on a path filter"
for j in sobelow sobelow-inline-overlap sobelow-baseline-fingerprint mix-audit; do
  assert_fact "if::$j" "needs.changes.outputs.api == 'true'"
  assert_fact "needs::$j" "changes"
done
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
assert mode in ("clean", "launder", "unwired", "orphan", "paths", "matrix"), mode

if mode == "launder":
    # Put the continue-on-error job back into needs — the exact regression the
    # measurement forbids.
    coe = [n for n, j in jobs.items() if j.get("continue-on-error") is True]
    agg["needs"] = list(agg["needs"]) + coe
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
elif mode == "matrix":
    agg["strategy"] = {"matrix": {"otp": ["27.0"]}}

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

mutant clean    coe_in_needs          ""                # round-trip alone is silent
mutant clean    blocking_not_in_needs ""
mutant launder  coe_in_needs          "sobelow"         # the laundering regression is DETECTED
mutant unwired  blocking_not_in_needs "mix-audit"       # an unjudged blocking job is DETECTED
mutant orphan   needs_without_decide  "a11y-ceiling"    # reaching needs is not enough (D36)
mutant paths    workflow_paths        "True"            # a re-added on:paths is DETECTED
mutant matrix   agg_matrix            "True"            # a matrixed aggregator is DETECTED
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

# dispatch <label> <expected-rc> <expected-api> <event> <base>
dispatch() {
  local label="$1" want="$2" wa="$3" ev="$4" bs="$5"
  local rc got
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
dispatch "docs-only PR" 0 false pull_request "$BASE_SHA"

git -C "$DR" checkout -q -b apichange "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/thing.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm api >/dev/null 2>&1
dispatch "api/** PR" 0 true pull_request "$BASE_SHA"

# the workflow's own file is in the set — editing the gate must run the gate
git -C "$DR" checkout -q -b wfchange "$BASE_SHA"
printf 'x\n' >"$DR/.github/workflows/security.yml"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm wf >/dev/null 2>&1
dispatch "security.yml-only PR" 0 true pull_request "$BASE_SHA"

# …and a NEIGHBOURING workflow is not, so the filter is a filter and not a
# tautology that returns true for everything.
git -C "$DR" checkout -q -b otherwf "$BASE_SHA"
printf 'x\n' >"$DR/.github/workflows/elixir.yml"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm otherwf >/dev/null 2>&1
dispatch "elixir.yml-only PR" 0 false pull_request "$BASE_SHA"

# push to main never skips, regardless of what changed
dispatch "push event" 0 true push ""

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
dispatch 'a path containing a double quote' 0 true pull_request "$BASE_SHA"

# (2) a rename OUT of the declared set. Analysed code just left api/** — the
#     scan MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv api/lib/moved.ex docs/moved.ex >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true pull_request "$BASE_SHA"

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md api/lib/guide.md >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renamein >/dev/null 2>&1
dispatch "a rename INTO the declared set" 0 true pull_request "$BASE_SHA"

# THE FAILURE PATHS — the polarity that makes the shim safe.
# An empty diff is the ONE "cannot tell" that does not fail: a revert pair or a
# branch-sync PR nets to nothing and is perfectly legal, and an ::error:: there
# leaves its author with a red check run and no self-service fix. It dispatches
# TRUE — the whole security suite: expensive, never wrong. Everything else reds.
git -C "$DR" checkout -q -b emptydiff "$BASE_SHA"
dispatch "empty diff (base == HEAD)" 0 true pull_request "$(git -C "$DR" rev-parse HEAD)"
says "changed-file set is EMPTY" "names the shape"
says "::warning" "as a WARNING, not a brick"
dispatch "unresolvable base sha" 1 - pull_request 0000000000000000000000000000000000000000
says "not resolvable in this checkout" "refuses to guess a base"
says "::error::" "refuses with an annotation"
dispatch "missing base sha" 1 - pull_request ""
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
dispatch "a base with no common ancestor" 1 - pull_request "$BASE_SHA"
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
  env -i PATH="$PATH" HOME="$HOME" "$@" bash --noprofile --norc "$AGG" >"$OUT" 2>&1 && rc=0 || rc=$?
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
  R_CHANGES=success R_SHAPE=success R_OVERLAP=skipped R_FINGERPRINT=skipped R_AUDIT=skipped O_API=false
gate "a blocking job FAILED" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=failure O_API=true
gate "the CVE audit was CANCELLED" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=cancelled O_API=true
gate "a job skipped though its gate said true" 1 \
  R_CHANGES=success R_SHAPE=success R_OVERLAP=success R_FINGERPRINT=success R_AUDIT=skipped O_API=true
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

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
