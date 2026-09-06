#!/usr/bin/env bash
# ci-measure.sh — the CI measurement harness for the "fast and valuable checks"
# goal (task-dee226be3107a98b, child task-ee3fc32d1615bd58).
#
# WHY THIS EXISTS, AND THE ONE MISTAKE IT REFUSES TO MAKE
# ------------------------------------------------------
# The first CI diet table was built from GitHub's job `started_at` -> `completed_at`
# span. On a saturated queue that span is mostly WAITING, not computing: a job that
# is cancelled while still queued never executes a single step, yet reports minutes.
# Measured 2026-09-02: 747 of 1180 job-minutes (63%) belonged to cancelled jobs, and
# job 33658884190 ("Validation perf bench") reported 5m25s with an EMPTY `.steps`
# array. Diet candidates were ranked on that number: "Validation perf 4.1 min/run"
# was really 1.00, and "Format 2.9" was really 0.48 — both were nominated for removal
# on minutes they never spent.
#
# THE RULE, and it is the whole point of this script:
#   A job's COMPUTE is derived from its STEPS. A job with zero executed steps
#   contributed ZERO compute, whatever its wall clock says.
# Wall time is still reported, separately and by name, because latency is a real
# cost — it is just not the same cost, and the two must never be summed.
#
# CONCURRENCY IS PART OF EVERY READING. Doubling the concurrent-job ceiling changes
# queue time drastically and compute time not at all, so a before/after that spans a
# ceiling change and does not say so is lying. Declare it in CONCURRENCY_LEDGER
# below; the report prints it per day and REFUSES to compare two windows whose
# ceilings differ unless --allow-mixed-concurrency is passed.
#
# SAMPLING, AND WHY IT IS NOT OPTIONAL
# -----------------------------------
# The baseline window 2026-08-30..2026-09-02 holds 25,617 runs (30 / 4,583 / 8,181
# / 12,823). Job detail is one API call PER RUN, against a 5,000/hour core budget,
# so a full census of that window is not merely slow — it is arithmetically
# impossible. This harness therefore SAMPLES, and says so in every number it
# prints.
# What sampling does and does not buy:
#   RATIOS survive it — min-per-executed-job, red rate, and zero-step share are
#   per-job averages, and a systematic sample across the day estimates them well.
#   TOTALS do not — a daily job-minute total from a sample is an ESTIMATE scaled
#   by population/sample, and it is labelled ESTIMATED everywhere it appears.
# THE 1000-ITEM CAP, which silently ruined the first attempt at this. GitHub's
# list-runs endpoint stops paginating at 1000 items. A "systematic sample evenly
# spaced across the day" therefore degenerates, with NO error, into "a sample of
# the first 1000 runs" on exactly the days worth measuring: asking for 60 runs on
# 2026-09-01 (8,181 runs) returned ONE, and on 2026-09-02 (12,823) returned nine.
# The fix is to partition each day into HOURLY windows through the `created=`
# filter, none of which exceeds the cap, and sample inside each. The harness now
# also REFUSES a sample that came back materially short of what was asked, because
# the failure mode is a quiet under-fill that still prints a confident table.
#
# The sample is SYSTEMATIC (evenly spaced across each day's run list), never "the
# first N", because runs cluster by hour and the first page of a day is a
# time-of-day slice, not a sample of it.
#
# USAGE
#   bash scripts/ci-measure.sh --since 2026-08-30 --until 2026-09-02
#   bash scripts/ci-measure.sh --since … --until … --json          # machine-readable
#   bash scripts/ci-measure.sh --breaker --since 2026-09-03        # main-red breaker value
#   bash scripts/ci-measure.sh --selftest                          # fixtures, no network
#   CI_MEASURE_FIXTURE=<file> bash scripts/ci-measure.sh --since … --until …
#
# EXIT CODES
#   0 ok · 1 a measurement refused (see the message) · 2 usage · 70 selftest died early
set -uo pipefail

REPO="${CI_MEASURE_REPO:-FRIKKern/barkpark}"
# Absolute, so --breaker can reach .github/workflows and main-red-breaker.sh from
# any cwd — the relative form exited 127 on main 0f6c9937 for exactly this reason.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
BREAKER_JOBS_TSV=""

# CONCURRENCY LEDGER — one line per date range, oldest first. A reading is only
# comparable with another at the SAME ceiling. Add a line when the plan changes;
# never edit a past line, because it describes what was true then.
CONCURRENCY_LEDGER='2026-01-01..2026-09-02T21:00Z=10=GitHub Free/Team baseline, ~10 concurrent jobs
2026-09-02T21:00Z..=20=GitHub Pro purchased 2026-09-02 evening, concurrent jobs doubled'

usage() { sed -n '2,40p' "$0"; exit 2; }

SINCE=""; UNTIL=""; MODE=report; JSON=0; ALLOW_MIXED=0; SAMPLE="${CI_MEASURE_SAMPLE:-80}"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --allow-mixed-concurrency) ALLOW_MIXED=1; shift ;;
    --sample) SAMPLE="${2:-}"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    --census) MODE=census; shift ;;
    --value-audit) MODE=value; shift ;;
    --breaker) MODE=breaker; shift ;;
    -h|--help) usage ;;
    *) echo "ci-measure: unknown argument '$1'" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# analyze — reads newline-delimited job JSON on stdin, emits the report.
# Kept in python3 because this is arithmetic over timestamps and percentiles,
# and an awk version of the percentile logic would be the least readable part
# of the repo. Every runner here has python3.
# ---------------------------------------------------------------------------
# NOTE ON THE HEREDOC: the analyzer body is written to a TEMP FILE and then run,
# never fed to `python3 -` on stdin. `python3 - <<X` makes the heredoc BE stdin,
# so the script would be reading its own source where the job data should be and
# would report a confident, empty, entirely wrong zero. Selftest arm a5 exists
# because that failure looks exactly like "a quiet CI day".
analyze() {
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'PY'
import json, sys, datetime, collections

since, until, as_json, ledger = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

def parse(ts):
    if not ts: return None
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))

jobs = []
population = {}
sample_meta = {}
sampled_runs = collections.defaultdict(set)
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: obj = json.loads(line)
    except json.JSONDecodeError: continue
    if obj.get("__population__"):
        population[obj["day"]] = obj.get("runs", 0)
        sample_meta[obj["day"]] = (obj.get("requested", 0), obj.get("fetched", 0))
        continue
    jobs.append(obj)

by_day = collections.defaultdict(lambda: {"compute": 0.0, "queue": 0.0,
                                          "executed": 0, "zero_step": 0, "jobs": 0})
per_workflow = collections.defaultdict(lambda: {"compute": 0.0, "runs": 0,
                                                "zero_step": 0, "red": 0})

for j in jobs:
    started, completed = parse(j.get("started_at")), parse(j.get("completed_at"))
    steps = j.get("steps") or []
    day = (started or completed).date().isoformat() if (started or completed) else "unknown"
    d = by_day[day]; d["jobs"] += 1
    if j.get("run_id"): sampled_runs[day].add(j["run_id"])

    # THE RULE: compute comes from steps. Zero steps => zero compute, whatever
    # the wall clock says. This is the line the selftest exists to protect.
    step_times = [(parse(s.get("started_at")), parse(s.get("completed_at")))
                  for s in steps]
    step_times = [(a, b) for a, b in step_times if a and b]
    if step_times:
        compute = (max(b for _, b in step_times) - min(a for a, _ in step_times)).total_seconds()
        d["compute"] += compute; d["executed"] += 1
        w = per_workflow[j.get("workflow_name") or j.get("name") or "?"]
        w["compute"] += compute; w["runs"] += 1
        if j.get("conclusion") == "failure": w["red"] += 1
    else:
        compute = 0.0
        d["zero_step"] += 1
        w = per_workflow[j.get("workflow_name") or j.get("name") or "?"]
        w["zero_step"] += 1
    if started and completed:
        d["queue"] += max(0.0, (completed - started).total_seconds() - compute)

def ceilings(l):
    out = []
    for line in l.strip().splitlines():
        rng, cap, note = line.split("=", 2)
        out.append((rng, int(cap), note))
    return out

caps = ceilings(ledger)
def cap_for(day):
    hit = None
    for rng, cap, note in caps:
        lo = rng.split("..")[0][:10]
        if day >= lo: hit = (cap, note)
    return hit or (None, "undeclared")

days = sorted(d for d in by_day if d != "unknown")
day_caps = {d: cap_for(d)[0] for d in days}
mixed = len(set(day_caps.values())) > 1

report = {
    "window": {"since": since, "until": until},
    "rule": "compute is derived from job STEPS; a zero-step job contributes ZERO compute",
    "concurrency_mixed": mixed,
    "days": [],
    "workflows": [],
    "totals": {},
}
tc = tq = 0.0; te = tz = 0
for day in days:
    d = by_day[day]
    report["days"].append({
        "day": day, "concurrent_job_ceiling": day_caps[day],
        "compute_min": round(d["compute"] / 60, 1),
        "queue_min": round(d["queue"] / 60, 1),
        "jobs": d["jobs"], "executed": d["executed"], "zero_step": d["zero_step"],
    })
    tc += d["compute"]; tq += d["queue"]; te += d["executed"]; tz += d["zero_step"]

for name, w in sorted(per_workflow.items(), key=lambda kv: -kv[1]["compute"]):
    total = w["runs"] + w["zero_step"]
    report["workflows"].append({
        "name": name,
        "compute_min": round(w["compute"] / 60, 1),
        "executed": w["runs"], "zero_step": w["zero_step"],
        "min_per_executed": round(w["compute"] / 60 / w["runs"], 2) if w["runs"] else 0.0,
        "red_rate": round(w["red"] / w["runs"], 3) if w["runs"] else None,
        "zero_step_share": round(w["zero_step"] / total, 3) if total else 0.0,
    })

underfilled = []
for day, pop in population.items():
    req, got = sample_meta.get(day, (0, 0))
    want = min(req, pop)
    if want and got < want * 0.8:
        underfilled.append({"day": day, "population": pop, "requested": req, "fetched": got})
report["population"] = population
report["underfilled"] = underfilled
report["sampling"] = {
    "note": "RATIOS (min/exec, red rate, zero-step share) are estimated well by a "
            "systematic sample. TOTALS below are SAMPLE totals; the estimated_* "
            "fields scale them by population/sample and are ESTIMATES, not measurements.",
}
report["totals"] = {
    "compute_min": round(tc / 60, 1), "queue_min": round(tq / 60, 1),
    "executed_jobs": te, "zero_step_jobs": tz,
    "zero_step_share": round(tz / (te + tz), 3) if (te + tz) else 0.0,
}

if as_json:
    print(json.dumps(report, indent=2)); sys.exit(0)

print(f"CI MEASUREMENT — {since} .. {until}")
if population:
    print("SAMPLED, not a census — totals below are SAMPLE totals:")
    for day in sorted(population):
        req, got = sample_meta.get(day, (0, 0))
        print(f"  {day}: population {population[day]} runs, requested {req}, fetched {got}")
    print("  RATIOS (min/exec, red rate, zero-step share) survive sampling. TOTALS DO NOT —")
    print("  scale them by population/sample yourself and label the result ESTIMATED.")
    print()
print(f"RULE: {report['rule']}")
print()
print(f"{'day':<12}{'ceiling':>8}{'compute':>10}{'queue':>10}{'exec':>7}{'0-step':>8}")
for d in report["days"]:
    print(f"{d['day']:<12}{str(d['concurrent_job_ceiling']):>8}"
          f"{d['compute_min']:>10.1f}{d['queue_min']:>10.1f}"
          f"{d['executed']:>7}{d['zero_step']:>8}")
t = report["totals"]
print(f"{'TOTAL':<12}{'':>8}{t['compute_min']:>10.1f}{t['queue_min']:>10.1f}"
      f"{t['executed_jobs']:>7}{t['zero_step_jobs']:>8}")
print()
print(f"zero-step jobs: {t['zero_step_jobs']} of {t['executed_jobs'] + t['zero_step_jobs']} "
      f"({t['zero_step_share'] * 100:.1f}%) — these executed NOTHING and contribute no compute")
print()
print(f"{'workflow':<46}{'compute':>9}{'exec':>6}{'0-step':>8}{'min/exec':>10}{'red':>7}")
for w in report["workflows"][:30]:
    rr = "-" if w["red_rate"] is None else f"{w['red_rate']:.2f}"
    print(f"{w['name'][:45]:<46}{w['compute_min']:>9.1f}{w['executed']:>6}"
          f"{w['zero_step']:>8}{w['min_per_executed']:>10.2f}{rr:>7}")
if underfilled:
    print()
    print("!! SAMPLE UNDER-FILLED — this report is NOT usable as a baseline.")
    for u in underfilled:
        print(f"   {u['day']}: asked for {u['requested']} runs of {u['population']}, got {u['fetched']}")
    print("   A short sample is not a small sample: it is a BIASED one, skewed to whatever")
    print("   slice the fetch could still reach. Fix the fetch; do not scale these numbers.")
    _underfill_exit = 1
else:
    _underfill_exit = 0

if mixed:
    print()
    print("!! CONCURRENCY CHANGED INSIDE THIS WINDOW — queue minutes are NOT comparable")
    print("   across these days. Compute minutes are. Split the window or compare compute only.")
sys.exit(_underfill_exit)
PY
  python3 "$pyf" "$1" "$2" "$3" "$4"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

# ---------------------------------------------------------------------------
# drop_phantom_queued — NDJSON run rows in, NDJSON run rows out, minus the ones
# GitHub will never dequeue and will not let anyone cancel.
#
# THE POPULATION, measured 2026-09-03 08:03Z (task-82059e31bcccdbd7): eight
# `status: queued` run records — seven created 2026-08-07T09:08:43Z
# (breakglass-watch, cloud, console-harness, doc-gates, elixir, release-artifact,
# required-checks-drift) and one 2026-08-19T05:23:37Z (compose-smoke), all
# push/main. Both `POST .../cancel` and `POST .../force-cancel` answer 409
# "Cannot cancel a workflow run that has not been queued yet" (measured on the
# seven of 2026-08-07). They are stuck in GitHub's pre-queue state, they execute
# no step, and they will still be there tomorrow. THE COUNT IS A CONSTANT, THE
# SHARE IS NOT: at 08:03Z on 2026-09-03 the queued feed returned 8 rows and all
# 8 were phantoms; at 16:11Z the same feed returned 31 rows of which 8 were.
#
# WHY THIS SCRIPT CARES, in the two places it reads run rows:
#   fetch()        a phantom drawn into the systematic sample consumes a slot,
#                  counts in `fetched`, and delivers ZERO jobs. That is the
#                  worst direction: the under-fill guard (arm a6) reads a full
#                  sample while the analyzer got nothing from that slot.
#   value_audit()  a phantom counts in a workflow's `runs` denominator, so its
#                  red rate and rerun rate are divided by runs that never ran.
#
# THE COUNT IS PRINTED, NEVER SWALLOWED — one line on stderr, always, including
# the zero. A filter nobody can see the size of is indistinguishable from a
# filter that has gone blind.
#
# WHAT IT REFUSES TO DROP: a row with no `status`, a row whose `created_at` will
# not parse, and any row younger than the cutoff. Only a row PROVABLY queued and
# PROVABLY old leaves; everything else stays and is measured.
PHANTOM_QUEUE_HOURS="${CI_MEASURE_PHANTOM_HOURS:-24}"

drop_phantom_queued() {
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'PPY'
import json, os, sys, datetime

hours = float(os.environ.get("PHANTOM_HOURS", "24"))
now_env = os.environ.get("CI_MEASURE_NOW", "")

def parse(ts):
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None

now = parse(now_env) or datetime.datetime.now(datetime.timezone.utc)
dropped = 0
for line in sys.stdin:
    raw = line.strip()
    if not raw:
        continue
    try:
        o = json.loads(raw)
    except json.JSONDecodeError:
        sys.stdout.write(line)
        continue
    created = parse(o.get("created") or o.get("created_at"))
    # PROVABLY queued AND PROVABLY old, or it stays.
    if o.get("status") == "queued" and created is not None:
        if (now - created).total_seconds() > hours * 3600:
            dropped += 1
            continue
    sys.stdout.write(line)
# WHERE THE DISCLOSURE GOES. stderr by default — but the value audit publishes
# its machine-readable JSON on stderr, and a second line there would make that
# payload unparseable for every consumer that json.loads it (the selftest arms
# v1..v3 among them). So a caller whose stderr is a DATA channel passes
# PHANTOM_LOG and prints the file itself, on the channel a human reads.
msg = ("ci-measure: phantom queued runs ignored: %d (status=queued, created more than %gh ago; "
       "GitHub answers 409 'has not been queued yet' to both cancel paths on these — "
       "measured 2026-09-03 on all 8 specimens)" % (dropped, hours))
log = os.environ.get("PHANTOM_LOG", "")
if log:
    with open(log, "a") as fh:
        fh.write(msg + "\n")
else:
    print(msg, file=sys.stderr)
PPY
  PHANTOM_HOURS="$PHANTOM_QUEUE_HOURS" python3 "$pyf"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

fetch() {
  if [ -n "${CI_MEASURE_FIXTURE:-}" ]; then cat "$CI_MEASURE_FIXTURE"; return; fi
  local d="$SINCE"
  while :; do
    local day_total=0 day_got=0 day_phantom=0 h
    # HOURLY partition — see "THE 1000-ITEM CAP" above. Each window is well under
    # the cap, so a systematic sample inside it is a real sample of that hour.
    for h in $(seq 0 23); do
      local hh; hh=$(printf '%02d' "$h")
      local lo="${d}T${hh}:00:00Z" hi="${d}T${hh}:59:59Z"
      local total
      total=$(gh api "repos/$REPO/actions/runs?created=$lo..$hi&per_page=1" --jq '.total_count' 2>/dev/null) || total=0
      [ -z "$total" ] && total=0
      day_total=$(( day_total + total ))
      [ "$total" -eq 0 ] && continue
      # per-hour quota, at least 1 where the hour has any runs
      local take=$(( SAMPLE / 24 )); [ "$take" -lt 1 ] && take=1
      [ "$total" -lt "$take" ] && take="$total"
      local i=0
      while [ "$i" -lt "$take" ]; do
        local off=$(( i * total / take ))
        [ "$off" -ge 1000 ] && break            # the cap, honoured explicitly
        local page=$(( off / 100 + 1 )) idx=$(( off % 100 ))
        local rrow kept rid
        # The ROW, not just the id: `status` and `created_at` are what separate a
        # run that will produce jobs from a phantom that never will. Same call,
        # two fields more.
        rrow=$(gh api "repos/$REPO/actions/runs?created=$lo..$hi&per_page=100&page=$page" \
                --jq ".workflow_runs[$idx] | {id, status, created_at}" 2>/dev/null)
        # ONE implementation of "is this a phantom", never two: the row goes
        # through the same filter the value audit uses, and a non-empty row that
        # comes back empty WAS the drop. A second copy of the rule here would be
        # free to drift from the one the selftest proves.
        kept=$(printf '%s\n' "$rrow" | drop_phantom_queued 2>/dev/null)
        if [ -n "$rrow" ] && [ -z "$(printf '%s' "$kept" | tr -d '[:space:]')" ]; then
          day_phantom=$(( day_phantom + 1 ))
          i=$(( i + 1 )); continue
        fi
        rid=$(printf '%s' "$kept" | jq -r '.id // empty' 2>/dev/null)
        if [ -n "$rid" ] && [ "$rid" != "null" ]; then
          day_got=$(( day_got + 1 ))
          gh api "repos/$REPO/actions/runs/$rid/jobs?per_page=100" \
            --jq '.jobs[] | {name, workflow_name, run_id, conclusion, started_at, completed_at, steps: [.steps[]? | {started_at, completed_at}]}' \
            2>/dev/null
        fi
        i=$(( i + 1 ))
      done
    done
    # The ignored count is PRINTED, per day, including the zero. A sample slot
    # spent on a phantom delivers no jobs while still counting as fetched, which
    # is exactly the direction that would quiet the under-fill guard (arm a6).
    echo "ci-measure: phantom queued runs skipped while sampling $d: $day_phantom" >&2
    echo "{\"__population__\":true,\"day\":\"$d\",\"runs\":$day_total,\"requested\":$SAMPLE,\"fetched\":$day_got}"
    [ "$d" = "$UNTIL" ] && break
    d=$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=1)).isoformat())" "$d")
    [ "$d" \> "$UNTIL" ] && break
  done
}

selftest() {
  local tmp fail=0 pass=0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

  # THE ARM THIS HARNESS EXISTS FOR: a cancelled job with a LARGE wall span and
  # ZERO executed steps must contribute ZERO compute. This is the exact shape of
  # job 33658884190 (5m25s wall, empty .steps) that inflated the first diet table.
  cat > "$tmp/cancelled.jsonl" <<'FIX'
{"name":"Validation perf bench","workflow_name":"elixir","conclusion":"cancelled","started_at":"2026-09-01T10:00:00Z","completed_at":"2026-09-01T10:05:25Z","steps":[]}
{"name":"Test","workflow_name":"elixir","conclusion":"success","started_at":"2026-09-01T10:00:00Z","completed_at":"2026-09-01T10:02:00Z","steps":[{"started_at":"2026-09-01T10:00:10Z","completed_at":"2026-09-01T10:01:10Z"}]}
FIX
  local out
  out=$(CI_MEASURE_FIXTURE="$tmp/cancelled.jsonl" bash "$0" --since 2026-09-01 --until 2026-09-01 --json)
  local compute zero
  compute=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totals"]["compute_min"])')
  zero=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totals"]["zero_step_jobs"])')
  if [ "$compute" = "1.0" ]; then
    pass=$((pass+1)); echo "  ok   a1 zero-step cancelled job contributes NO compute (total 1.0 min = the one real job)"
  else
    fail=$((fail+1)); echo "  FAIL a1 total compute is $compute, expected 1.0 — a cancelled job's WALL TIME is being counted as compute"
  fi
  if [ "$zero" = "1" ]; then
    pass=$((pass+1)); echo "  ok   a2 the zero-step job is COUNTED and reported, not silently dropped"
  else
    fail=$((fail+1)); echo "  FAIL a2 zero_step_jobs is $zero, expected 1"
  fi

  # a3 — the naive implementation must FAIL this fixture. If wall-span were used,
  # total would be 5.42+2.0 = 7.42 min. Asserting the number we would have got
  # keeps the arm honest about WHICH bug it catches.
  if [ "$compute" != "7.4" ] && [ "$compute" != "7.42" ]; then
    pass=$((pass+1)); echo "  ok   a3 the wall-span answer (7.4) is NOT what we report"
  else
    fail=$((fail+1)); echo "  FAIL a3 reported the wall-span answer"
  fi

  # a4 — a concurrency change inside the window must be flagged, not averaged over.
  cat > "$tmp/mixed.jsonl" <<'FIX'
{"name":"Test","workflow_name":"elixir","conclusion":"success","started_at":"2026-09-01T10:00:00Z","completed_at":"2026-09-01T10:02:00Z","steps":[{"started_at":"2026-09-01T10:00:10Z","completed_at":"2026-09-01T10:01:10Z"}]}
{"name":"Test","workflow_name":"elixir","conclusion":"success","started_at":"2026-09-03T10:00:00Z","completed_at":"2026-09-03T10:02:00Z","steps":[{"started_at":"2026-09-03T10:00:10Z","completed_at":"2026-09-03T10:01:10Z"}]}
FIX
  local mixed
  mixed=$(CI_MEASURE_FIXTURE="$tmp/mixed.jsonl" bash "$0" --since 2026-09-01 --until 2026-09-03 --json \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["concurrency_mixed"])')
  if [ "$mixed" = "True" ]; then
    pass=$((pass+1)); echo "  ok   a4 a window spanning the GitHub Pro ceiling change is flagged as not comparable"
  else
    fail=$((fail+1)); echo "  FAIL a4 concurrency_mixed is $mixed — a before/after across a ceiling change would read as a win"
  fi

  # a5 — non-vacuity: the harness must actually have parsed jobs. A fixture that
  # silently produced zero rows would pass a1 by accident (0.0 != 7.4).
  local execd
  execd=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totals"]["executed_jobs"])')
  if [ "$execd" = "1" ]; then
    pass=$((pass+1)); echo "  ok   a5 non-vacuous: 1 executed job was parsed (an empty parse cannot pass a1 by accident)"
  else
    fail=$((fail+1)); echo "  FAIL a5 executed_jobs is $execd, expected 1 — the fixture did not parse"
  fi

  # a6 — THE UNDER-FILL ARM. The real fetch asked for 60 runs a day and returned
  # 1, 9 and 11 on the three busy days, because GitHub's list-runs endpoint stops
  # paginating at 1000 items and said so with no error. The table it printed
  # looked entirely normal. A short sample is not a small sample, it is a BIASED
  # one — skewed to whatever slice the fetch could still reach — so this must be
  # loud and must exit non-zero, never a footnote.
  cat > "$tmp/underfill.jsonl" <<'FIX'
{"__population__":true,"day":"2026-09-02","runs":12823,"requested":60,"fetched":9}
{"name":"Test","workflow_name":"elixir","conclusion":"success","started_at":"2026-09-02T10:00:00Z","completed_at":"2026-09-02T10:02:00Z","steps":[{"started_at":"2026-09-02T10:00:10Z","completed_at":"2026-09-02T10:01:10Z"}]}
FIX
  local uf_rc uf_json
  CI_MEASURE_FIXTURE="$tmp/underfill.jsonl" bash "$0" --since 2026-09-02 --until 2026-09-02 >/dev/null 2>&1
  uf_rc=$?
  uf_json=$(CI_MEASURE_FIXTURE="$tmp/underfill.jsonl" bash "$0" --since 2026-09-02 --until 2026-09-02 --json \
              | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["underfilled"]))')
  if [ "$uf_json" = "1" ] && [ "$uf_rc" -ne 0 ]; then
    pass=$((pass+1)); echo "  ok   a6 a sample that came back 9-of-60 is flagged AND exits non-zero"
  else
    fail=$((fail+1)); echo "  FAIL a6 under-filled sample: flagged=$uf_json rc=$uf_rc — expected flagged=1 and rc!=0"
  fi

  # a7 — and the guard must not cry wolf on a healthy sample.
  cat > "$tmp/full.jsonl" <<'FIX'
{"__population__":true,"day":"2026-09-02","runs":12823,"requested":60,"fetched":60}
{"name":"Test","workflow_name":"elixir","conclusion":"success","started_at":"2026-09-02T10:00:00Z","completed_at":"2026-09-02T10:02:00Z","steps":[{"started_at":"2026-09-02T10:00:10Z","completed_at":"2026-09-02T10:01:10Z"}]}
FIX
  local full_rc
  CI_MEASURE_FIXTURE="$tmp/full.jsonl" bash "$0" --since 2026-09-02 --until 2026-09-02 >/dev/null 2>&1
  full_rc=$?
  if [ "$full_rc" -eq 0 ]; then
    pass=$((pass+1)); echo "  ok   a7 a full 60-of-60 sample is NOT flagged (the guard discriminates)"
  else
    fail=$((fail+1)); echo "  FAIL a7 a healthy sample was flagged as under-filled — the guard cries wolf"
  fi

  # ── v1 THE ARM THE VALUE AUDIT EXISTS FOR ────────────────────────────────
  # A red and a later GREEN on the SAME head sha is a RERUN-GREEN: nothing about
  # the code changed between them, so the red carried no information. Counting
  # it as a catch is not a rounding error, it is BACKWARDS — a flaky check
  # reruns green often and would score the HIGHEST catch rate in the repo.
  cat > "$tmp/rerun.jsonl" <<'FIX'
{"wf":"flaky.yml","sha":"aaa111","concl":"failure","created":"2026-09-01T10:00:00Z","pr":7,"id":1}
{"wf":"flaky.yml","sha":"aaa111","concl":"success","created":"2026-09-01T10:30:00Z","pr":7,"id":2}
FIX
  local vj
  vj=$(CI_MEASURE_FIXTURE="$tmp/rerun.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null)
  local rg cc
  rg=$(printf '%s' "$vj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["rerun_green"])' 2>/dev/null)
  cc=$(printf '%s' "$vj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["catch_candidate"])' 2>/dev/null)
  if [ "$rg" = "1" ] && [ "$cc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   v1 a rerun-green on the SAME sha counts as a flake and NOT as a catch"
  else
    fail=$((fail+1)); echo "  FAIL v1 rerun_green=$rg catch_candidate=$cc — expected 1 and 0. A rerun-green is being counted as a catch, which scores flaky checks HIGHEST."
  fi

  # v1b — THE SHAPE THAT ACTUALLY OCCURS. `gh run rerun` re-runs the SAME run
  # id in place, so a rerun-green never appears as a second run row. The first
  # real pass of this audit reported rerun=0 for EVERY workflow — not credible,
  # and the tell that the detector was blind. run_attempt > 1 with a green
  # conclusion is that event seen correctly.
  cat > "$tmp/attempt.jsonl" <<'FIX'
{"wf":"inplace.yml","sha":"fff111","concl":"success","created":"2026-09-01T10:00:00Z","pr":13,"id":8,"attempt":2}
FIX
  local va
  va=$(CI_MEASURE_FIXTURE="$tmp/attempt.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"][0]; print(r["rerun_green"], r["catch_candidate"])' 2>/dev/null)
  if [ "$va" = "1 0" ]; then
    pass=$((pass+1)); echo "  ok   v1b an in-place rerun (run_attempt 2, green) is a flake — the shape that actually occurs"
  else
    fail=$((fail+1)); echo "  FAIL v1b got '$va', expected '1 0' — in-place reruns are invisible, so rerun=0 will read as 'no flakes'"
  fi

  # v1c — A RERUN OF A CANCELLED ATTEMPT IS NOT A FLAKE. The first attempt never
  # produced a verdict, so there is no red to explain. Measured by the ci-team
  # second pass: 79 of 230 required-context rerun-greens (34%) were reruns of
  # cancelled attempts, and ALL SEVEN of cloud's were — three ids this harness
  # first published as flakes were ONE dispatcher-cancellation event. Counting
  # them inflates the flake rate on exactly the busy days when cancellations
  # cluster, which is the worst possible direction for this measurement to err.
  cat > "$tmp/cancelprior.jsonl" <<'FIX'
{"wf":"evicted.yml","sha":"ggg111","concl":"success","created":"2026-09-01T10:00:00Z","pr":15,"id":9,"attempt":2,"prior_concl":"cancelled"}
{"wf":"evicted.yml","sha":"hhh222","concl":"success","created":"2026-09-01T11:00:00Z","pr":15,"id":10,"attempt":2,"prior_concl":"failure"}
FIX
  local vc
  vc=$(CI_MEASURE_FIXTURE="$tmp/cancelprior.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"][0]; print(r["rerun_green"], r["rerun_after_cancel"])' 2>/dev/null)
  if [ "$vc" = "1 1" ]; then
    pass=$((pass+1)); echo "  ok   v1c a rerun of a CANCELLED attempt is counted apart from a rerun of a FAILED one"
  else
    fail=$((fail+1)); echo "  FAIL v1c got '$vc', expected '1 1' — cancelled-prior reruns are being counted as flakes, which inflates the rate exactly when the queue is deep"
  fi

  # v1d — THE LIVE PATH ENRICHES. v1c's fixture lines already CARRY prior_concl,
  # so v1c never executes enrich_prior at all — a harness that proves a property
  # on one path leaves every other path unproven. Measured 2026-09-03
  # (task-089b46ad36be9e8d): the live path printed rerun_after_cancel 0 while
  # nine of nine cited cloud/console/elixir rerun-greens were reruns of
  # CANCELLED attempts, because the env assignment for the python enrichment
  # sat AFTER the command and reached it as argv, so os.environ raised, stderr
  # was discarded, and the un-enriched line fell through. This arm drives the
  # REAL enrich_prior with gh stubbed, so the arm cannot go dark again.
  local vd
  vd=$(gh() { printf 'cancelled\n'; }
       printf '%s\n' '{"wf":"live.yml","sha":"iii111","concl":"success","created":"2026-09-01T10:00:00Z","pr":16,"id":11,"attempt":2,"prior":"https://api.github.com/repos/o/r/actions/runs/11/attempts/1"}' \
         | enrich_prior \
         | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline()).get("prior_concl"))' 2>/dev/null)
  if [ "$vd" = "cancelled" ]; then
    pass=$((pass+1)); echo "  ok   v1d enrich_prior attaches prior_concl on the LIVE path (gh stubbed, real function)"
  else
    fail=$((fail+1)); echo "  FAIL v1d got '$vd', expected 'cancelled' — the live path drops the prior conclusion, so every cancelled-prior rerun is booked as a flake"
  fi

  # v2 — and the discriminator works the other way: a green on a LATER sha of
  # the same PR is a catch CANDIDATE. If v1 and v2 both passed for the same
  # reason (everything classed as flake) the audit would be useless.
  cat > "$tmp/fixed.jsonl" <<'FIX'
{"wf":"real.yml","sha":"bbb111","concl":"failure","created":"2026-09-01T10:00:00Z","pr":9,"id":3}
{"wf":"real.yml","sha":"ccc222","concl":"success","created":"2026-09-01T11:00:00Z","pr":9,"id":4}
FIX
  local vj2 rg2 cc2
  vj2=$(CI_MEASURE_FIXTURE="$tmp/fixed.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null)
  rg2=$(printf '%s' "$vj2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["rerun_green"])' 2>/dev/null)
  cc2=$(printf '%s' "$vj2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["catch_candidate"])' 2>/dev/null)
  if [ "$cc2" = "1" ] && [ "$rg2" = "0" ]; then
    pass=$((pass+1)); echo "  ok   v2 a green on a LATER sha is a catch CANDIDATE, not a flake (the two buckets discriminate)"
  else
    fail=$((fail+1)); echo "  FAIL v2 rerun_green=$rg2 catch_candidate=$cc2 — expected 0 and 1"
  fi

  # v3 — a workflow that never went red is NEVER-RED, never a catch. A green
  # streak proves the check ran, not that it protects anything.
  cat > "$tmp/never.jsonl" <<'FIX'
{"wf":"quiet.yml","sha":"ddd111","concl":"success","created":"2026-09-01T10:00:00Z","pr":11,"id":5}
{"wf":"quiet.yml","sha":"eee222","concl":"success","created":"2026-09-01T11:00:00Z","pr":11,"id":6}
FIX
  local vv
  vv=$(CI_MEASURE_FIXTURE="$tmp/never.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"][0]; print(r["verdict"], r["catch_candidate"])' 2>/dev/null)
  if [ "$vv" = "NEVER-RED 0" ]; then
    pass=$((pass+1)); echo "  ok   v3 an all-green workflow is NEVER-RED with zero catches (a green streak proves nothing)"
  else
    fail=$((fail+1)); echo "  FAIL v3 got '$vv', expected 'NEVER-RED 0'"
  fi

  # ── p1..p5 THE PHANTOM QUEUED RUN ────────────────────────────────────────
  # RAW run lines, the exact shape the live `gh api` projection emits — never a
  # pre-filtered fixture, because a fixture that arrives already clean proves
  # only that the harness can count.
  #
  # THE SPECIMEN, measured 2026-09-03 08:03Z (task-82059e31bcccdbd7): eight
  # queued runs from 2026-08-07 and 2026-08-19 that GitHub refuses to cancel by
  # either path. `--now` is pinned here through CI_MEASURE_NOW so "27 days old"
  # is a fact about the fixture and not about when CI ran.
  local PNOW=2026-09-03T00:00:00Z
  cat > "$tmp/phantom.jsonl" <<'FIX'
{"wf":"elixir.yml","sha":"jjj111","concl":"success","created":"2026-09-01T10:00:00Z","pr":21,"id":30,"attempt":1,"status":"completed"}
{"wf":"elixir.yml","sha":"kkk222","concl":null,"created":"2026-08-07T09:08:43Z","pr":0,"id":31,"attempt":1,"status":"queued"}
FIX
  local p_runs p_line
  p_runs=$(CI_MEASURE_NOW="$PNOW" CI_MEASURE_FIXTURE="$tmp/phantom.jsonl" bash "$0" --value-audit --since 2026-08-01 2>&1 >/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["runs"])' 2>/dev/null)
  if [ "$p_runs" = "1" ]; then
    pass=$((pass+1)); echo "  ok   p1 a 27-day-old queued run is NOT counted in elixir.yml's run total (1, not 2) — the denominator holds only runs that ran"
  else
    fail=$((fail+1)); echo "  FAIL p1 runs=$p_runs, expected 1 — a run GitHub will not dequeue is being counted as a run, so every rate for this workflow is divided by it"
  fi

  # p2 — and the count is DISCLOSED. A filter whose size nobody can read is
  # indistinguishable from a filter that has gone blind.
  p_line=$(CI_MEASURE_NOW="$PNOW" CI_MEASURE_FIXTURE="$tmp/phantom.jsonl" bash "$0" --value-audit --since 2026-08-01 2>/dev/null \
            | grep -c 'phantom queued runs ignored: 1' || true)
  if [ "$p_line" = "1" ]; then
    pass=$((pass+1)); echo "  ok   p2 the report states 'phantom queued runs ignored: 1' — the ignored count is printed, not swallowed"
  else
    fail=$((fail+1)); echo "  FAIL p2 the disclosure line for 1 ignored run is missing (matched $p_line times)"
  fi

  # p3 — THE THRESHOLD DOES THE WORK, not the id and not a date literal. The
  # identical fixture under a wider cutoff must keep the row.
  local p_wide
  p_wide=$(CI_MEASURE_NOW="$PNOW" CI_MEASURE_PHANTOM_HOURS=100000 CI_MEASURE_FIXTURE="$tmp/phantom.jsonl" \
             bash "$0" --value-audit --since 2026-08-01 2>&1 >/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["runs"])' 2>/dev/null)
  if [ "$p_wide" = "2" ]; then
    pass=$((pass+1)); echo "  ok   p3 …and under a 100000h cutoff the SAME row is kept (runs=2) — the threshold is doing the work"
  else
    fail=$((fail+1)); echo "  FAIL p3 runs=$p_wide under an enormous cutoff, expected 2 — the drop is keyed on something other than age"
  fi

  # p4 — IT IS NOT "DROP EVERY QUEUED RUN". A run queued an hour ago is a real
  # queue: it will execute, and removing it would understate the queue instead
  # of correcting it.
  cat > "$tmp/fresh-queued.jsonl" <<'FIX'
{"wf":"elixir.yml","sha":"jjj111","concl":"success","created":"2026-09-01T10:00:00Z","pr":21,"id":30,"attempt":1,"status":"completed"}
{"wf":"elixir.yml","sha":"lll333","concl":null,"created":"2026-09-02T23:00:00Z","pr":22,"id":32,"attempt":1,"status":"queued"}
FIX
  local p_fresh
  p_fresh=$(CI_MEASURE_NOW="$PNOW" CI_MEASURE_FIXTURE="$tmp/fresh-queued.jsonl" bash "$0" --value-audit --since 2026-08-01 2>&1 >/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["runs"])' 2>/dev/null)
  if [ "$p_fresh" = "2" ]; then
    pass=$((pass+1)); echo "  ok   p4 a run queued ONE HOUR ago is kept (runs=2) — the filter discriminates by age, it does not delete the queue"
  else
    fail=$((fail+1)); echo "  FAIL p4 runs=$p_fresh, expected 2 — a live queued run was dropped, which understates the queue"
  fi

  # p5 — AND IT NEVER GUESSES A ROW AWAY. A row whose created_at will not parse
  # is not PROVABLY old, so it stays and is measured. (v1/v1b/v2/v3's fixtures
  # carry no `status` field at all and must likewise survive — they do, above.)
  cat > "$tmp/unparseable-queued.jsonl" <<'FIX'
{"wf":"elixir.yml","sha":"jjj111","concl":"success","created":"2026-09-01T10:00:00Z","pr":21,"id":30,"attempt":1,"status":"completed"}
{"wf":"elixir.yml","sha":"mmm444","concl":null,"created":"not-a-timestamp","pr":0,"id":33,"attempt":1,"status":"queued"}
FIX
  local p_bad
  p_bad=$(CI_MEASURE_NOW="$PNOW" CI_MEASURE_FIXTURE="$tmp/unparseable-queued.jsonl" bash "$0" --value-audit --since 2026-08-01 2>&1 >/dev/null \
           | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["runs"])' 2>/dev/null)
  if [ "$p_bad" = "2" ]; then
    pass=$((pass+1)); echo "  ok   p5 a queued row with an UNPARSEABLE created_at is kept (runs=2) — only a PROVABLE phantom leaves"
  else
    fail=$((fail+1)); echo "  FAIL p5 runs=$p_bad, expected 2 — an unreadable date is being treated as proof of age"
  fi

  # ── t1..t3 THE 300-RUN CAP, AND THE NOTICE THAT MAKES IT QUOTABLE ────────
  # EVERY assertion below greps a FILE, never `printf … | grep -q`. Under
  # `set -o pipefail` grep -q exits on the first match, printf takes SIGPIPE,
  # and the pipeline returns 141 — an arm that reads "no match" precisely when
  # the match arrives early. Measured on this file 2026-09-06: t1 failed while
  # its own output, printed by hand, contained every string it was looking for.
  _has()   { grep -qF -- "$1" "$2"; }
  _hasre() { grep -qE -- "$1" "$2"; }

  # The collector used to page exactly three times at per_page=100 and say
  # nothing when the third page came back full. Thirteen rows of the published
  # table were cut off at 300 and read as though they shared a 30-day window
  # with rows that really did cover 30 days.

  # t1 — A TRUNCATED ROW ANNOUNCES ITSELF, LOUDLY, BEFORE THE TABLE.
  cat > "$tmp/trunc.jsonl" <<'FIX'
{"__truncated__":true,"wf":"doc-gates.yml","cap":1000,"since":"2026-08-07"}
{"wf":"doc-gates.yml","sha":"aaa111","concl":"failure","created":"2026-09-05T00:00:00Z","pr":7,"id":901,"attempt":1,"status":"completed"}
{"wf":"doc-gates.yml","sha":"bbb222","concl":"failure","created":"2026-09-05T18:00:00Z","pr":8,"id":902,"attempt":1,"status":"completed"}
FIX
  CI_MEASURE_FIXTURE="$tmp/trunc.jsonl" bash "$0" --value-audit --since 2026-08-07 > "$tmp/t1.out" 2>/dev/null
  if _has 'TRUNCATED' "$tmp/t1.out" \
     && _has 'DO NOT SHARE A DENOMINATOR' "$tmp/t1.out" \
     && _has 'cap 1000 runs reached' "$tmp/t1.out" \
     && _has 'doc-gates.yml' "$tmp/t1.out"; then
    pass=$((pass+1)); echo "  ok   t1 a capped workflow prints a loud truncation notice naming the workflow, the cap and the real span — a reader cannot reach the table without walking past it"
  else
    fail=$((fail+1)); echo "  FAIL t1 no truncation notice in the report — a 0.5-day row would sit beside a 30-day row with nothing saying so, and every ratio taken across them is a coincidence"
  fi

  # t2 — AND IT DISCRIMINATES. Identical data with no cap marker must print NO
  # truncation block: a notice that always fires teaches nothing and would be
  # ignored by the third table.
  cat > "$tmp/untrunc.jsonl" <<'FIX'
{"wf":"doc-gates.yml","sha":"aaa111","concl":"failure","created":"2026-09-05T00:00:00Z","pr":7,"id":901,"attempt":1,"status":"completed"}
{"wf":"doc-gates.yml","sha":"bbb222","concl":"failure","created":"2026-09-05T18:00:00Z","pr":8,"id":902,"attempt":1,"status":"completed"}
FIX
  CI_MEASURE_FIXTURE="$tmp/untrunc.jsonl" bash "$0" --value-audit --since 2026-08-07 > "$tmp/t2.out" 2>/dev/null
  if _has 'DO NOT SHARE A DENOMINATOR' "$tmp/t2.out"; then
    fail=$((fail+1)); echo "  FAIL t2 an UNTRUNCATED run printed the truncation notice — a warning on every table is a warning on none"
  else
    pass=$((pass+1)); echo "  ok   t2 an uncapped workflow prints no truncation block — the notice is driven by the marker, not by the template"
  fi

  # t3 — THE COLLECTOR PAGES TO THE WINDOW AND ONLY THEN CRIES CAP. Driven with
  # `gh` stubbed, because this is the loop that was wrong: a SHORT page ends the
  # walk (and a quiet workflow costs ONE call, not three), a FULL page at the
  # ceiling emits the marker.
  _stub_rows() {   # $1 = how many rows
    local i=1
    while [ "$i" -le "$1" ]; do
      printf '{"wf":"fake.yml","sha":"s%s","concl":"success","created":"2026-09-0%sT00:00:00Z","pr":1,"id":%s,"attempt":1,"status":"completed"}\n' \
        "$i" "$(( (i % 5) + 1 ))" "$i"
      i=$((i+1))
    done
  }
  # bash 3.2 mis-parses a `case` inside $( ), so the stubbed runs go to files —
  # which is also what keeps these assertions off `printf | grep -q` (see _has).
  (
    gh() {
      case "$2" in
        *"actions/workflows?per_page"*) printf '111\t.github/workflows/fake.yml\n' ;;
        *"page=1"*|*"page=2"*) _stub_rows 100 ;;
        *) : ;;
      esac
    }
    SINCE=2026-08-07 VALUE_AUDIT_MAX_PAGES=2 value_audit 2>/dev/null
  ) > "$tmp/t_cap.out" 2>/dev/null
  (
    gh() {
      case "$2" in
        *"actions/workflows?per_page"*) printf '111\t.github/workflows/fake.yml\n' ;;
        *"page=1"*) _stub_rows 40 ;;
        *"page=2"*) echo "STUB-SECOND-PAGE-SHOULD-NOT-BE-FETCHED" >&2; _stub_rows 100 ;;
        *) : ;;
      esac
    }
    SINCE=2026-08-07 VALUE_AUDIT_MAX_PAGES=2 value_audit 2>/dev/null
  ) > "$tmp/t_short.out" 2>/dev/null
  if _has 'cap 200 runs reached' "$tmp/t_cap.out" \
     && ! _has 'DO NOT SHARE A DENOMINATOR' "$tmp/t_short.out" \
     && _hasre '^fake\.yml +40 ' "$tmp/t_short.out"; then
    pass=$((pass+1)); echo "  ok   t3 the collector walks until a SHORT page (40 rows, one call) and emits the cap marker only when the ceiling page comes back FULL"
  else
    fail=$((fail+1)); echo "  FAIL t3 pagination/cap detection wrong — see $tmp/t_cap.out and $tmp/t_short.out; a fixed page count silently truncates the busy half of the roster and a full ceiling page must announce itself"
  fi
  unset -f _stub_rows

  # ── v7 THE VERDICT THIS DOCUMENT WITHDREW AND THE INSTRUMENT KEPT PRINTING ─
  # docs/ops/ci-value-audit.md retracted FLAKE-DOMINANT for pr-task-gate on
  # 2026-09-03: its inputs are the PR body and the ledger, so a same-sha
  # red->green is an author fixing the input, not a flake. The prose was fixed;
  # the classifier was not, and went on printing the retracted verdict.

  cat > "$tmp/extinputs.jsonl" <<'FIX'
{"__wfmeta__":true,"wf":"pr-task-gate.yml","ext_inputs":"github.event.pull_request.body"}
{"wf":"pr-task-gate.yml","sha":"aaa111","concl":"failure","created":"2026-09-01T10:00:00Z","pr":7,"id":1,"attempt":1,"status":"completed"}
{"wf":"pr-task-gate.yml","sha":"aaa111","concl":"success","created":"2026-09-01T11:00:00Z","pr":7,"id":2,"attempt":1,"status":"completed"}
FIX
  local v_ext
  CI_MEASURE_FIXTURE="$tmp/extinputs.jsonl" bash "$0" --value-audit --since 2026-09-01 > "$tmp/v7.out" 2>/dev/null
  v_ext=$(CI_MEASURE_FIXTURE="$tmp/extinputs.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null \
           | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["verdict"])' 2>/dev/null)
  if [ "$v_ext" = "INPUTS-OUTSIDE-SHA" ] && _has 'NOT FLAKE EVIDENCE' "$tmp/v7.out"; then
    pass=$((pass+1)); echo "  ok   v7 a workflow whose inputs are NOT in the sha is verdicted INPUTS-OUTSIDE-SHA, and its same-sha greens print as NOT FLAKE EVIDENCE"
  else
    fail=$((fail+1)); echo "  FAIL v7 got '$v_ext' — the classifier is printing the verdict its own document withdrew, and anyone re-deriving the table gets the retracted answer with no warning"
  fi

  # v7b — AND IT IS A DISCRIMINATION, NOT A BLANKET SUPPRESSION. The same run
  # rows WITHOUT the metadata line must still read FLAKE-DOMINANT, or the fix
  # would have deleted the flake verdict for the whole roster.
  local v_noext
  v_noext=$(grep -v '__wfmeta__' "$tmp/extinputs.jsonl" > "$tmp/noext.jsonl"; \
            CI_MEASURE_FIXTURE="$tmp/noext.jsonl" bash "$0" --value-audit --since 2026-09-01 2>&1 >/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["verdict"])' 2>/dev/null)
  if [ "$v_noext" = "FLAKE-DOMINANT" ]; then
    pass=$((pass+1)); echo "  ok   v7b identical rows with no external-input metadata still read FLAKE-DOMINANT — v7 measures the discrimination, not a suppressed verdict"
  else
    fail=$((fail+1)); echo "  FAIL v7b got '$v_noext', expected FLAKE-DOMINANT — v7 is vacuous: FLAKE-DOMINANT may have been removed for every workflow"
  fi

  # v7c — THE PROPERTY IS DERIVED FROM THE WORKFLOW FILE, NOT TYPED INTO A LIST.
  # A list would go stale the day a fourth PR-metadata gate lands; the grep would
  # not. It must also stay NARROW: a workflow that merely mentions pull_request
  # is not one whose verdict rule changes.
  mkdir -p "$tmp/extwf"
  cat > "$tmp/extwf/reads-body.yml" <<'FIX'
on: pull_request
jobs:
  gate:
    steps:
      - env:
          PR_BODY: ${{ github.event.pull_request.body }}
        run: bash scripts/gate.sh
FIX
  cat > "$tmp/extwf/reads-code.yml" <<'FIX'
on: pull_request
jobs:
  test:
    steps:
      - run: mix test
FIX
  local e_yes e_no
  e_yes=$(wf_external_inputs "$tmp/extwf/reads-body.yml")
  e_no=$(wf_external_inputs "$tmp/extwf/reads-code.yml")
  if [ -n "$e_yes" ] && [ -z "$e_no" ]; then
    pass=$((pass+1)); echo "  ok   v7c the external-input property is DERIVED from the workflow file ('$e_yes'), and a workflow that only reads the code yields nothing"
  else
    fail=$((fail+1)); echo "  FAIL v7c body='$e_yes' code='$e_no' — the detector fires on everything or on nothing, and either way the verdict stops depending on what the check reads"
  fi

  # ── d1..d3 THE FOUR-DAY CENSUS THAT MANUFACTURED FIVE DORMANT VERDICTS ────
  # docs/ops/ci-workflow-verdicts.md called five workflows DORMANT off a 4-day
  # window. Over 30 days all five fired and two had REFUSED — hundesteder 4 reds
  # / 14 runs and vendored-assets 2 / 6. Retiring on that label would have
  # deleted two working gates.

  # d1 — THE REFUSAL, on the exact case that was got wrong.
  local d_ref
  dormancy_verdict hundesteder.yml 4 0 90 14 > "$tmp/d1.out"
  d_ref=$(cat "$tmp/d1.out")
  if _has 'WINDOW-TOO-SHORT' "$tmp/d1.out" \
     && ! _has 'DORMANT' "$tmp/d1.out" \
     && _has '14 time' "$tmp/d1.out" \
     && _has 'needs at least' "$tmp/d1.out"; then
    pass=$((pass+1)); echo "  ok   d1 a 4-day window over a workflow that fires every ~6 days REFUSES the dormancy verdict and says what window it would need"
  else
    fail=$((fail+1)); echo "  FAIL d1 got '$d_ref' — a short window is minting a DORMANT label, which is the label that nearly deleted hundesteder and vendored-assets"
  fi

  # d2 — AND IT STILL ANSWERS. A workflow with zero runs over the whole lookback
  # IS dormant, and the verdict carries both windows so it cannot be quoted bare.
  local d_yes
  dormancy_verdict truly-dead.yml 30 0 90 0 > "$tmp/d2.out"
  d_yes=$(cat "$tmp/d2.out")
  if _has 'DORMANT' "$tmp/d2.out" \
     && _has '30 d window' "$tmp/d2.out" \
     && _has '90 d lookback' "$tmp/d2.out"; then
    pass=$((pass+1)); echo "  ok   d2 a workflow with zero runs across the whole lookback IS called dormant, and the verdict names both windows inline"
  else
    fail=$((fail+1)); echo "  FAIL d2 got '$d_yes' — the guard refuses even a supportable verdict, which makes the mode unable to find a genuinely dead workflow"
  fi

  # d3 — THE SUFFICIENT-WINDOW CASE, so d1 is not passing because the guard says
  # no to everything. A workflow that fired daily for 90 days and then went
  # silent for 4 clears 3x its own period, and the window is still on the line.
  local d_ok
  dormancy_verdict busy-then-silent.yml 4 0 90 90 > "$tmp/d3.out"
  d_ok=$(cat "$tmp/d3.out")
  if _has 'DORMANT' "$tmp/d3.out" && _has '4 d window' "$tmp/d3.out"; then
    pass=$((pass+1)); echo "  ok   d3 a window that DOES clear 3x the observed firing period yields DORMANT — the guard is keyed on the ratio, not on a blanket refusal"
  else
    fail=$((fail+1)); echo "  FAIL d3 got '$d_ok' — d1's refusal is vacuous: the guard refuses regardless of the window"
  fi

  # ── b1..b7 THE MAIN-RED BREAKER MEASUREMENT ──────────────────────────────
  # EVERY fixture below is a RAW line: workflow YAML as committed, a job-log
  # excerpt as the logs endpoint returns it, and jobs-endpoint rows. None of
  # them carries a derived field, so none of them can pass by arriving already
  # answered — that is the v1c blind spot this whole block is shaped against.

  # b1 — THE JOB LIST IS DERIVED, NOT TYPED. Two Decide steps in one file, plus
  # a job with no Decide step that must NOT appear.
  mkdir -p "$tmp/wf"
  cat > "$tmp/wf/go-format.yml" <<'FIX'
jobs:
  gofmt:
    name: gofmt -l (advisory)
    steps:
      - name: gofmt
        id: s1
        continue-on-error: true  # main-red breaker: the Decide step below owns the verdict
        run: gofmt -l .
      - name: Decide (main-red breaker — inherited reds are neutral, own reds fail)
        if: always()
        env:
          STEP_OUTCOMES: ${{ toJSON(steps) }}
          STEP_NAMES: "{\"s1\": \"gofmt\"}"
          JOB_NAME: "gofmt -l (advisory)"
          WORKFLOW_FILE: go-format.yml
        run: bash "$GITHUB_WORKSPACE/scripts/main-red-breaker.sh"
  gofmt-ceiling:
    name: gofmt drift ceiling (blocking)
    steps:
      - name: ceiling
        id: s1
        continue-on-error: true
        run: exit 0
      - name: Decide (main-red breaker — inherited reds are neutral, own reds fail)
        env:
          STEP_NAMES: "{\"s1\": \"ceiling\"}"
          JOB_NAME: "gofmt drift ceiling (blocking)"
          WORKFLOW_FILE: go-format.yml
        run: bash "$GITHUB_WORKSPACE/scripts/main-red-breaker.sh"
  unrelated:
    name: A job with no breaker at all
    steps:
      - name: something
        run: exit 0
FIX
  local b_jobs
  b_jobs=$(BREAKER_WORKFLOWS="$tmp/wf" breaker_jobs 2>/dev/null | tr '\n' '|')
  if [ "$b_jobs" = "go-format.yml	gofmt -l (advisory)|go-format.yml	gofmt drift ceiling (blocking)|" ]; then
    pass=$((pass+1)); echo "  ok   b1 the breaker job list is DERIVED from the workflow YAML (2 jobs, and the job without a Decide step is not among them)"
  else
    fail=$((fail+1)); echo "  FAIL b1 derived '$b_jobs' — a typed list would go stale the day a ninth breaker job lands, and a wrong list silently zeroes a row"
  fi

  # b2 — AND AN EMPTY DERIVATION REFUSES. A workflows dir with no Decide step
  # must not yield a confident table of zeroes.
  mkdir -p "$tmp/wf-empty"
  cat > "$tmp/wf-empty/other.yml" <<'FIX'
jobs:
  plain:
    name: No breaker here
    steps:
      - name: run
        run: exit 0
FIX
  if BREAKER_WORKFLOWS="$tmp/wf-empty" breaker_jobs >/dev/null 2>&1; then
    fail=$((fail+1)); echo "  FAIL b2 an empty derivation succeeded — every count downstream would be a truthful-looking zero"
  else
    pass=$((pass+1)); echo "  ok   b2 a workflows dir with no Decide step REFUSES (exit 1) instead of printing zeroes"
  fi

  # b3 — THE VERDICT IS READ FROM A RAW LOG LINE, the exact sentence
  # main-red-breaker.sh emits. A FAIL log of the same job must read NONE, or the
  # AFTER count would be "every breaker job that ran".
  local b_inh b_fail
  b_inh=$(printf '%s\n' \
    '2026-09-03T09:12:44.1Z ##[group]Run bash "$GITHUB_WORKSPACE/scripts/main-red-breaker.sh"' \
    '2026-09-03T09:12:45.9Z main-red-breaker: INHERITED-FROM-MAIN — '"'"'Doc budgets + anchors'"'"' failed only on step(s) main'"'"'s newest completed run (31999001) already fails: citation guard;' \
    | breaker_verdict)
  b_fail=$(printf '%s\n' \
    '2026-09-03T09:12:45.9Z main-red-breaker: FAIL — '"'"'Doc budgets + anchors'"'"' failed on a step main does not: budget check;' \
    | breaker_verdict)
  if [ "$b_inh" = "INHERITED-FROM-MAIN" ] && [ "$b_fail" = "NONE" ]; then
    pass=$((pass+1)); echo "  ok   b3 a RAW job log reads INHERITED-FROM-MAIN, and a FAIL log of the same job reads NONE (the two verdicts discriminate)"
  else
    fail=$((fail+1)); echo "  FAIL b3 inherited='$b_inh' fail='$b_fail' — expected 'INHERITED-FROM-MAIN' and 'NONE'"
  fi

  # b4 — THE LIVE ENRICHMENT PATH RUNS, with gh stubbed. The row fed in carries
  # NO verdict, so the count is zero unless breaker_after_enrich actually calls
  # the logs endpoint and parses what comes back. This is the v1d lesson applied
  # before the bug rather than after it: a fixture that arrives pre-enriched
  # leaves this function unexecuted while every number still looks right.
  local b_live
  b_live=$(gh() { printf '%s\n' 'main-red-breaker: INHERITED-FROM-MAIN — job x failed only on step(s) main already fails: y;'; }
           printf '%s\n' '{"arm":"AFTER","day":"2026-09-03","wf":"doc-gates.yml","job":"Doc budgets + anchors","run_id":31999,"job_id":420001,"conclusion":"success"}' \
             | breaker_after_enrich \
             | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline()).get("verdict"))' 2>/dev/null)
  if [ "$b_live" = "INHERITED-FROM-MAIN" ]; then
    pass=$((pass+1)); echo "  ok   b4 breaker_after_enrich attaches the verdict on the LIVE path (gh stubbed, real function, raw row in)"
  else
    fail=$((fail+1)); echo "  FAIL b4 got '$b_live' — the live path drops the verdict, so the AFTER column reads 0 on a day the breaker fired"
  fi

  # b5 — THE BEFORE ARM REPLAYS scripts/main-red-breaker.sh. Ours ⊆ main's, so
  # the gating script itself says INHERITED. Nothing here reimplements that rule.
  cat > "$tmp/before-inherited.jsonl" <<'FIX'
{"kind":"main_jobs","wf":"doc-gates.yml","run_id":31000001,"created":"2026-09-01T00:00:00Z","body":{"jobs":[{"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"citation guard","conclusion":"failure"},{"name":"EXIT-trap selftest","conclusion":"failure"}]}]}}
{"kind":"pr_red","arm":"BEFORE","day":"2026-09-01","wf":"doc-gates.yml","job":"Doc budgets + anchors","run_id":31000099,"created":"2026-09-01T10:00:00Z","steps":[{"name":"checkout","conclusion":"success"},{"name":"citation guard","conclusion":"failure"}]}
FIX
  local b_before
  b_before=$(breaker_before_classify < "$tmp/before-inherited.jsonl" \
              | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline()).get("verdict"))' 2>/dev/null)
  if [ "$b_before" = "INHERITED-FROM-MAIN" ]; then
    pass=$((pass+1)); echo "  ok   b5 a historical red whose failing step main already fails replays as INHERITED — decided by main-red-breaker.sh itself, not a second copy of the rule"
  else
    fail=$((fail+1)); echo "  FAIL b5 got '$b_before' — the BEFORE window would count zero and the whole comparison would read as 'the breaker changed nothing'"
  fi

  # b6 — AND THE DISCRIMINATOR HOLDS. The same job, the same main run, one step
  # main does NOT fail: not inherited. Without this, b5 could pass because the
  # replay says INHERITED to everything.
  cat > "$tmp/before-own.jsonl" <<'FIX'
{"kind":"main_jobs","wf":"doc-gates.yml","run_id":31000001,"created":"2026-09-01T00:00:00Z","body":{"jobs":[{"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"citation guard","conclusion":"failure"}]}]}}
{"kind":"pr_red","arm":"BEFORE","day":"2026-09-01","wf":"doc-gates.yml","job":"Doc budgets + anchors","run_id":31000100,"created":"2026-09-01T10:00:00Z","steps":[{"name":"citation guard","conclusion":"failure"},{"name":"doc budget check","conclusion":"failure"}]}
FIX
  local b_own
  b_own=$(breaker_before_classify < "$tmp/before-own.jsonl" \
           | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline()).get("verdict"))' 2>/dev/null)
  if [ "$b_own" = "NONE" ]; then
    pass=$((pass+1)); echo "  ok   b6 a red on a step main does NOT fail is not inherited — the BEFORE arm discriminates instead of waving everything through"
  else
    fail=$((fail+1)); echo "  FAIL b6 got '$b_own', expected NONE — the BEFORE count would swallow the author's own reds and overstate the breaker's value"
  fi

  # b7 — END TO END. Both fixtures through the real mode: one BEFORE, one AFTER,
  # the run ids printed, and the number of logs read DISCLOSED. A per-log sample
  # whose sample size is not on the page is a guess wearing a number.
  cat > "$tmp/after-e2e.jsonl" <<'FIX'
{"arm":"AFTER","day":"2026-09-03","wf":"doc-gates.yml","job":"Doc budgets + anchors","run_id":31999,"job_id":420001,"conclusion":"success"}
FIX
  local b_e2e b_ids b_logs
  b_e2e=$(gh() { printf '%s\n' 'main-red-breaker: INHERITED-FROM-MAIN — job failed only on step(s) main already fails: citation guard;'; }
          BREAKER_WORKFLOWS="$tmp/wf" \
          CI_MEASURE_BREAKER_AFTER_FIXTURE="$tmp/after-e2e.jsonl" \
          CI_MEASURE_BREAKER_BEFORE_FIXTURE="$tmp/before-inherited.jsonl" \
          SINCE=2026-09-03 UNTIL=2026-09-03 breaker_mode 2>/dev/null)
  # THE ASSERTION GREPS A FILE. `printf … | grep -q` returns 141 whenever grep
  # matches early enough to SIGPIPE the printf, and under `set -o pipefail` that
  # reads as "no match": b7 failed on roughly one run in three on origin/main
  # while its own FAIL message printed the exact values it was asserting.
  printf '%s\n' "$b_e2e" > "$tmp/b7.out"
  b_ids=$(grep -c '31000099\|31999' "$tmp/b7.out"); b_ids=${b_ids:-0}
  b_logs=$(grep -c '1 job logs read' "$tmp/b7.out"); b_logs=${b_logs:-0}
  if grep -q '^TOTAL' "$tmp/b7.out" \
     && [ "$(printf '%s\n' "$b_e2e" | awk '/^TOTAL/{print $2, $3}')" = "1 1" ] \
     && [ "$b_ids" -ge 2 ] && [ "$b_logs" = "1" ]; then
    pass=$((pass+1)); echo "  ok   b7 the table reports BEFORE 1 / AFTER 1, names both run ids, and discloses '1 job logs read'"
  else
    fail=$((fail+1)); echo "  FAIL b7 totals '$(printf '%s\n' "$b_e2e" | awk '/^TOTAL/{print $2, $3}')' idlines=$b_ids logline=$b_logs — a count with no run ids behind it cannot be walked back, and an undisclosed log budget hides how much of the day was actually read"
  fi


  # b8 — THE ZERO THAT LOOKED LIKE AN ANSWER. This is the live bug caught by the
  # first real run of this mode, promoted to an arm: 642 PR runs in the window,
  # every collector emitting nothing (gh rejected an --arg flag it does not have,
  # 2>/dev/null ate the message), and a clean "BEFORE 0 / AFTER 0" printed with a
  # straight face. A window with runs in it and no jobs examined must REFUSE.
  local b_guard_rc b_guard_out
  b_guard_out=$(printf '%s\n' \
    '{"__pop__":true,"arm":"AFTER","day":"2026-09-03","runs":642}' \
    '{"__pop__":true,"arm":"BEFORE","day":"2026-09-02","runs":504}' \
    '{"__logs__":true,"read":0,"budget":160}' \
    | breaker_report 2026-09-03 2026-09-03 2026-09-02 2026-09-02 2>&1)
  b_guard_rc=$?
  printf '%s\n' "$b_guard_out" > "$tmp/b8.out"
  if [ "$b_guard_rc" != "0" ] && grep -q 'REFUSES' "$tmp/b8.out"; then
    pass=$((pass+1)); echo "  ok   b8 642 sampled PR runs with ZERO jobs examined REFUSES (exit $b_guard_rc) instead of printing a tidy 0/0"
  else
    fail=$((fail+1)); echo "  FAIL b8 exit=$b_guard_rc — a broken collector prints as 'the breaker neutralises nothing', which is the exact false answer this mode exists to avoid"
  fi

  # b9 — AND THE REFUSAL DISCRIMINATES. The same shape with jobs actually
  # examined must still print its table, or b8 would just be "never report".
  local b_ok_rc
  printf '%s\n' \
    '{"__pop__":true,"arm":"AFTER","day":"2026-09-03","runs":642}' \
    '{"__logs__":true,"read":3,"budget":160}' \
    '{"arm":"AFTER","day":"2026-09-03","job":"Doc budgets + anchors","run_id":31999,"verdict":"NONE"}' \
    | breaker_report 2026-09-03 2026-09-03 2026-09-02 2026-09-02 >/dev/null 2>&1
  b_ok_rc=$?
  if [ "$b_ok_rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   b9 a window that WAS read reports normally (exit 0) even when the count is genuinely zero — the guard fires on the instrument, not on the answer"
  else
    fail=$((fail+1)); echo "  FAIL b9 exit=$b_ok_rc — the guard refuses a real measured zero, which would make a working breaker unreportable"
  fi
  echo
  echo "SELFTEST: $pass passed, $fail failed."
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# census — the run COUNT per day, per workflow, per trigger. Unlike compute,
# this IS affordable as a true census: it comes from the paginated list
# endpoint's `total_count`, one call per (workflow, day) or (workflow, event),
# never from per-run job detail. So every number below is MEASURED, not sampled
# and not scaled — which is exactly why it is reported separately from the
# compute table rather than mixed into it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# dormancy_verdict — THE ONLY PLACE A "DORMANT" LABEL MAY BE MINTED, and it
# refuses to mint one it cannot support.
#
# WHAT WENT WRONG. docs/ops/ci-workflow-verdicts.md marked five workflows
# DORMANT — "declared PR-triggered, fired 0 times — stale declaration" — off an
# exact census over 2026-08-30..09-02, FOUR DAYS. Counted over 30 days all five
# had fired, and two had genuinely REFUSED: hundesteder 4 reds / 14 runs, and
# vendored-assets 2 / 6 — the family whose blind spot shipped a stale vendored
# tarball at #16174. Acting on the label would have deleted two working gates.
# The census was not wrong about its four days. It was quoted as a statement
# about the workflow.
#
# THE RULE: zero runs in a window is only evidence of dormancy if the window is
# long enough that a LIVE workflow would have been near-certain to fire in it.
# Take the workflow's observed firing period P from a longer lookback, and
# demand window >= DORMANCY_MULTIPLE x P. Below that the tool REFUSES the
# verdict and says what window it would need — a refusal that teaches beats a
# silent adjustment.
#
# AND NO VERDICT IS EVER PRINTED BARE. Every line carries its window, so a
# DORMANT that IS supported still cannot be quoted without the number that
# supports it.
#
#   dormancy_verdict <wf> <window_days> <pr_in_window> <lookback_days> <pr_in_lookback>
DORMANCY_MULTIPLE="${CI_MEASURE_DORMANCY_MULTIPLE:-3}"

dormancy_verdict() {
  M="$DORMANCY_MULTIPLE" python3 - "$@" <<'DPY'
import os, sys

wf, w_days, w_runs, l_days, l_runs = sys.argv[1:6]
w_days, l_days = float(w_days), float(l_days)
w_runs, l_runs = int(w_runs), int(l_runs)
mult = float(os.environ.get("M", "3"))

if w_runs > 0:
    print(f"{wf:<30} LIVE — {w_runs} pull_request run(s) in the {w_days:g} d window")
    sys.exit(0)

if l_runs == 0:
    print(f"{wf:<30} DORMANT — 0 pull_request runs in the {w_days:g} d window "
          f"AND 0 in the {l_days:g} d lookback")
    sys.exit(0)

period = l_days / l_runs
need = mult * period
if w_days >= need:
    print(f"{wf:<30} DORMANT — 0 runs in the {w_days:g} d window; observed firing period "
          f"{period:.1f} d over {l_days:g} d, so the window is >= {mult:g}x it")
    sys.exit(0)

print(f"{wf:<30} WINDOW-TOO-SHORT — REFUSING to call this dormant. It fired {l_runs} time(s) "
      f"in the {l_days:g} d lookback (about one run per {period:.1f} d); a dormancy verdict "
      f"needs at least {need:.1f} d of window and this one is {w_days:g} d. "
      f"A zero here is a short window, not a dead workflow.")
DPY
}

census() {
  local wfs day ev
  wfs=$(gh api "repos/$REPO/actions/workflows?per_page=100" --jq '.workflows[] | "\(.id)\t\(.name)\t\(.path)"' 2>/dev/null)
  [ -z "$wfs" ] && { echo "census: could not list workflows" >&2; return 1; }

  echo "CI RUN CENSUS — $SINCE .. $UNTIL (MEASURED, not sampled: total_count from the list endpoint)"
  echo
  printf '%-34s%10s%10s%10s%10s\n' "workflow" "total" "pull_req" "push" "schedule"
  local g_total=0 g_pr=0 g_push=0 g_sched=0
  # THE ZERO ROWS ARE NOT DROPPED ANY MORE. `continue` used to make a workflow
  # with no runs in the window VANISH from the table, and a reader who noticed
  # the absence wrote DORMANT next to it. They are collected and adjudicated
  # below, where the window is part of the verdict.
  local dormant_candidates=""
  while IFS=$'\t' read -r id name path; do
    [ -z "$id" ] && continue
    local t pr pu sc
    t=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&per_page=1" --jq '.total_count' 2>/dev/null); t=${t:-0}
    if [ "$t" -eq 0 ]; then
      dormant_candidates="${dormant_candidates}$(basename "$path")"$'\t'"$id"$'\n'
      continue
    fi
    pr=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=pull_request&per_page=1" --jq '.total_count' 2>/dev/null); pr=${pr:-0}
    pu=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=push&per_page=1" --jq '.total_count' 2>/dev/null); pu=${pu:-0}
    sc=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=schedule&per_page=1" --jq '.total_count' 2>/dev/null); sc=${sc:-0}
    printf '%-34s%10s%10s%10s%10s\n' "$(basename "$path")" "$t" "$pr" "$pu" "$sc"
    # A workflow that ran on push but NOT on pull_request in this window is
    # exactly the shape the five refuted DORMANT rows had. It is adjudicated
    # too, on its pull_request count, not waved through because `total` is
    # non-zero.
    [ "$pr" -eq 0 ] && dormant_candidates="${dormant_candidates}$(basename "$path")"$'\t'"$id"$'\n'
    g_total=$((g_total+t)); g_pr=$((g_pr+pr)); g_push=$((g_push+pu)); g_sched=$((g_sched+sc))
  done <<< "$wfs"
  printf '%-34s%10s%10s%10s%10s\n' "TOTAL" "$g_total" "$g_pr" "$g_push" "$g_sched"
  echo
  echo "per-day totals (all workflows):"
  local d="$SINCE"
  while :; do
    local dt
    dt=$(gh api "repos/$REPO/actions/runs?created=$d..$d&per_page=1" --jq '.total_count' 2>/dev/null); dt=${dt:-0}
    printf '  %s  %6s runs\n' "$d" "$dt"
    [ "$d" = "$UNTIL" ] && break
    d=$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=1)).isoformat())" "$d")
    [ "$d" \> "$UNTIL" ] && break
  done

  # THE CONSTANT THIS TABLE CARRIES. Every number above is GitHub's own
  # `total_count`, which counts a phantom queued run exactly like a run that
  # executed. There is no server-side "exclude the undequeuable" filter, so the
  # census cannot subtract them per workflow — it MEASURES them and says so, on
  # the principle that a disclosed constant is a number a reader can correct and
  # an undisclosed one is a number they will quote.
  local queued_rows kept_rows n_all n_keep
  queued_rows=$(gh api "repos/$REPO/actions/runs?status=queued&per_page=100" --paginate \
                  --jq '.workflow_runs[] | {id, status, created_at}' 2>/dev/null)
  n_all=$(printf '%s\n' "$queued_rows" | grep -c . || true)
  kept_rows=$(printf '%s\n' "$queued_rows" | drop_phantom_queued 2>/dev/null)
  n_keep=$(printf '%s\n' "$kept_rows" | grep -c . || true)
  # -------------------------------------------------------------------------
  # DORMANCY ADJUDICATION — see dormancy_verdict above. A zero in this window is
  # adjudicated against a LONGER lookback, and the verdict is refused outright
  # when the window is too short to carry it.
  # -------------------------------------------------------------------------
  local w_days lookback_since l_days
  w_days=$(python3 -c "import datetime,sys;a=datetime.date.fromisoformat(sys.argv[1]);b=datetime.date.fromisoformat(sys.argv[2]);print((b-a).days+1)" "$SINCE" "$UNTIL" 2>/dev/null)
  w_days=${w_days:-0}
  l_days="${CI_MEASURE_DORMANCY_LOOKBACK_DAYS:-90}"
  lookback_since=$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])-datetime.timedelta(days=int(sys.argv[2]))).isoformat())" "$UNTIL" "$l_days" 2>/dev/null)
  echo
  echo "DORMANCY ADJUDICATION — window $SINCE..$UNTIL (${w_days} d), lookback ${lookback_since}..${UNTIL} (${l_days} d)"
  echo "  A workflow with zero runs in the window is NOT called dormant unless the window is at"
  echo "  least ${DORMANCY_MULTIPLE}x its observed firing period. Every verdict below carries its own window;"
  echo "  none of them is quotable bare."
  if [ -z "$(printf '%s' "$dormant_candidates" | tr -d '[:space:]')" ]; then
    echo "  (every workflow fired at least once in the window — nothing to adjudicate)"
  else
    while IFS=$'\t' read -r wname wid; do
      [ -z "$wid" ] && continue
      local lpr
      lpr=$(gh api "repos/$REPO/actions/workflows/$wid/runs?created=$lookback_since..$UNTIL&event=pull_request&per_page=1" --jq '.total_count' 2>/dev/null); lpr=${lpr:-0}
      echo "  $(dormancy_verdict "$wname" "$w_days" 0 "$l_days" "$lpr")"
    done <<< "$dormant_candidates"
  fi

  echo
  echo "queued RIGHT NOW (not inside the window — the queue has no history endpoint):"
  echo "  rows returned: $n_all   PHANTOM (>${PHANTOM_QUEUE_HOURS}h, uncancellable): $((n_all - n_keep))   DEPTH: $n_keep"
  echo "  the totals above are GitHub's total_count and INCLUDE any phantom created inside the window."
  echo "  The compute table and the value audit exclude them."
}

# ---------------------------------------------------------------------------
# value_audit — cost is measured; VALUE is not. This mode asks, per workflow:
# when it went red, did that red mean anything?
#
# THE CLASSIFICATION RULE, stated because a table of percentages without one is
# an opinion with decimal places:
#
#   RERUN-GREEN  a red run and a later GREEN run on the SAME head sha. Nothing
#                about the code changed between them, so the red carried no
#                information. This is a FLAKE and it can NEVER be a catch —
#                selftest arm v1 exists solely to keep it that way.
#   FIXED-LATER  a red run, then green on a LATER head of the same PR. The red
#                MAY have caught something. It is reported as CATCH-CANDIDATE,
#                not as a catch: proving it requires diffing the two heads and
#                asking whether the change touched non-test code or this check's
#                inputs, which is per-workflow knowledge this mode does not have.
#                Overclaiming here would flatter every gate in the repo.
#   NEVER-RED    zero reds in the window. Not automatically useless — a gate can
#                be cheap insurance — but it has demonstrated nothing, so it is
#                the first place to look when deciding what to retire.
#
# WHY THE HONEST BUCKET MATTERS: a "catch rate" that counts rerun-greens is
# exactly backwards, because a flaky check reruns green often and would score
# HIGHEST. The two must never be summed.
# ---------------------------------------------------------------------------
# THE 300-RUN CAP THAT MADE EVERY RATIO IN THE PUBLISHED TABLE UNSUPPORTED.
# This loop used to read `while [ "$page" -le 3 ]` at per_page=100 — a hard 300
# runs per workflow, newest first, with NO notice when the third page came back
# full. Run frequency in this repo spans three orders of magnitude, so the same
# "300 runs" covered 0.51 d for task-lease-renew and the whole 30 d for
# windows-smoke. The direction of the ranking survived that; every row-to-row
# RATIO in the table did not, by up to a factor of 40 (measured
# 2026-09-06, /papers/ci-value-audit-2026-09-06).
#
# TWO CHANGES, and the second is the one that keeps working when the first runs
# out of road:
#   1. Page until the API returns a SHORT page — the requested window, not a
#      fixed three pages. A quiet workflow now costs ONE call, not three.
#   2. When the page ceiling IS reached with a full last page, say so LOUDLY,
#      naming the workflow, the cap, and the calendar span the rows really
#      cover. GitHub's list endpoint stops paginating at 1000 items, so a cap
#      cannot be removed, only disclosed. A cap with no warning turns a
#      denominator into a coincidence.
VALUE_AUDIT_MAX_PAGES="${CI_MEASURE_MAX_PAGES:-10}"   # 10 x 100 = GitHub's own 1000-item list ceiling

# wf_external_inputs — does this workflow READ SOMETHING THAT IS NOT IN THE SHA?
#
# The rerun-green rule ("a later green on the same head sha is a flake, never a
# catch") carries an unstated assumption: THAT THE CHECK'S INPUT IS THE CODE.
# docs/ops/ci-value-audit.md withdrew the FLAKE-DOMINANT verdict for
# pr-task-gate on exactly that ground — its inputs are the PR description and
# the ledger, so an author who fixes a missing `Task:` trailer and re-runs makes
# the rerun BE the fix, on an unchanged sha. That correction reached the prose
# and NOT this classifier, which went on printing the retracted verdict for
# three days (measured 2026-09-06).
#
# So the classifier now reads the assumption instead of assuming it. This is a
# PROPERTY DERIVED FROM THE WORKFLOW FILE, not an allowlist: any workflow that
# gates on PR metadata is caught by the same grep, including ones written after
# this line. On main 2026-09-06 it fires for pr-task-gate.yml, reland-check.yml
# and task-lease-renew.yml, and for nothing else.
#
# THE MARKERS ARE DELIBERATELY NARROW: PR body/title/labels are mutable WITHOUT
# a new commit and are what a human edits to turn the red green. A gate reading
# the task ledger is the same class and is NOT yet detected here — the honest
# limit is stated in docs/ops/ci-value-audit.md rather than papered over with a
# looser grep that would sweep in `gh pr view` used only to find a PR number.
wf_external_inputs() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -ohE 'github\.event\.pull_request\.(body|title|labels)' "$f" 2>/dev/null | sort -u | paste -sd, -
}

value_audit() {
  local wfs plog rc
  # stderr here carries the JSON payload, so the filter's disclosure is routed
  # to a file and printed on STDOUT with the report — see WHERE THE DISCLOSURE
  # GOES in drop_phantom_queued.
  plog="$(mktemp)"
  if [ -n "${CI_MEASURE_FIXTURE:-}" ]; then
    PHANTOM_LOG="$plog" drop_phantom_queued < "$CI_MEASURE_FIXTURE" | classify_runs
    rc=$?
    cat "$plog"; rm -f "$plog"
    return $rc
  fi
  wfs=$(gh api "repos/$REPO/actions/workflows?per_page=100" --jq '.workflows[] | "\(.id)\t\(.path)"' 2>/dev/null)
  [ -z "$wfs" ] && { echo "value-audit: could not list workflows" >&2; return 1; }
  {
    while IFS=$'\t' read -r id path; do
      [ -z "$id" ] && continue
      local base ext page=1 rows n
      base="$(basename "$path")"
      ext="$(wf_external_inputs "$SCRIPT_DIR/../$path")"
      [ -n "$ext" ] && printf '{"__wfmeta__":true,"wf":"%s","ext_inputs":"%s"}\n' "$base" "$ext"
      while [ "$page" -le "$VALUE_AUDIT_MAX_PAGES" ]; do
        rows=$(gh api "repos/$REPO/actions/workflows/$id/runs?event=pull_request&created=>=$SINCE&per_page=100&page=$page" \
          --jq ".workflow_runs[] | {wf: \"$base\", sha: .head_sha, concl: .conclusion, created: .created_at, pr: (.pull_requests[0].number // 0), id: .id, attempt: .run_attempt, status: .status, prior: .previous_attempt_url}" 2>/dev/null)
        # grep -c PRINTS 0 and EXITS 1 on no match; capture the count, never
        # `|| echo 0` (that fires too and makes the capture "0\n0").
        n=$(printf '%s' "$rows" | grep -c . ); n=${n:-0}
        [ "$n" -gt 0 ] && printf '%s\n' "$rows"
        # A SHORT page is the end of the window. A FULL last page at the ceiling
        # is a truncation, and it gets a marker the report cannot swallow.
        [ "$n" -lt 100 ] && break
        if [ "$page" -eq "$VALUE_AUDIT_MAX_PAGES" ]; then
          printf '{"__truncated__":true,"wf":"%s","cap":%d,"since":"%s"}\n' \
            "$base" $(( VALUE_AUDIT_MAX_PAGES * 100 )) "$SINCE"
        fi
        page=$((page + 1))
      done
    done <<< "$wfs"
  } | PHANTOM_LOG="$plog" drop_phantom_queued | enrich_prior | classify_runs
  rc=$?
  cat "$plog"; rm -f "$plog"
  return $rc
}

# enrich_prior — resolve what the PRIOR attempt concluded, for reruns only.
# One API call per rerun-green, and reruns are a small minority of runs, so this
# is affordable where a per-run call would not be. Without it the harness cannot
# tell a rerun of a CANCELLED attempt (no verdict, no flake) from a rerun of a
# FAILED one (a red with no code change, a real flake) — and treating them alike
# inflates the flake rate on exactly the busy days when cancellations cluster.
enrich_prior() {
  while IFS= read -r line; do
    case "$line" in
      *'"attempt":1'*|*'"prior":null'*) printf '%s\n' "$line"; continue ;;
    esac
    local url concl
    url=$(printf '%s' "$line" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("prior") or ""))' 2>/dev/null)
    if [ -n "$url" ]; then
      concl=$(gh api "$url" --jq '.conclusion' 2>/dev/null)
      if [ -n "$concl" ]; then
        # C= goes BEFORE the command: after it, it is argv, os.environ raises, and
        # the un-enriched line falls through silently (v1d guards this).
        printf '%s\n' "$line" | C="$concl" python3 -c 'import json,sys,os;o=json.load(sys.stdin);o["prior_concl"]=os.environ["C"];print(json.dumps(o))' 2>/dev/null && continue
      fi
    fi
    printf '%s\n' "$line"
  done
}

classify_runs() {
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'VPY'
import json, sys, collections, datetime

runs = collections.defaultdict(list)
prior_conclusions = {}
# Two out-of-band marker kinds ride the same stream as the run rows, so a
# FIXTURE exercises exactly the code the live path runs (selftest arms v7/v8).
external_inputs = {}   # wf -> the PR-metadata expression(s) it reads
truncated = {}         # wf -> the run cap it hit
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
    if o.get("__wfmeta__"):
        if o.get("ext_inputs"): external_inputs[o.get("wf")] = o["ext_inputs"]
        continue
    if o.get("__truncated__"):
        truncated[o.get("wf")] = o.get("cap", 0)
        continue
    if "wf" not in o: continue
    runs[o["wf"]].append(o)
    if o.get("prior_concl"): prior_conclusions[o.get("id")] = o["prior_concl"]

rows = []
for wf, rs in runs.items():
    rs.sort(key=lambda r: r.get("created") or "")
    reds = [r for r in rs if r.get("concl") == "failure"]
    by_sha = collections.defaultdict(list)
    for r in rs: by_sha[r.get("sha")].append(r)

    rerun_green = 0
    rerun_after_cancel = 0
    fixed_later = 0
    unresolved = 0
    evidence = collections.defaultdict(list)

    # AN IN-PLACE RERUN IS INVISIBLE AS TWO RUNS. `gh run rerun` re-runs the
    # SAME run id and updates it, so a red-then-green rerun never appears as a
    # second run row — the first pass of this audit reported rerun=0 for EVERY
    # workflow, which is not credible and was the tell. `run_attempt > 1` with
    # a green conclusion is the same event seen correctly: it failed on an
    # earlier attempt and passed on a later one, with no code change between.
    # SPLIT THE RERUN-GREENS BY WHAT THE PRIOR ATTEMPT CONCLUDED. A rerun of a
    # CANCELLED attempt is not evidence of flakiness at all: the first attempt
    # never produced a verdict, so there is no red to explain. Measured by the
    # ci-team second pass: 79 of 230 required-context rerun-greens (34%) were
    # reruns of cancelled attempts, and ALL SEVEN of cloud's were — three of the
    # ids this harness first cited as flakes were one dispatcher-cancellation
    # event. Counting those as flakes overstates every busy day's flake rate,
    # because cancellations cluster exactly when the queue is deep.
    for r in rs:
        if (r.get("attempt") or 1) > 1 and r.get("concl") == "success":
            if prior_conclusions.get(r.get("id")) == "cancelled":
                rerun_after_cancel += 1
                evidence["rerun-after-cancel"].append((r.get("id"), "prior attempt cancelled"))
            else:
                rerun_green += 1
                evidence["rerun-green"].append((r.get("id"), "attempt %s" % r.get("attempt")))

    for red in reds:
        sha = red.get("sha")
        # THE ARM: a later GREEN on the SAME sha is a rerun-green. Never a catch.
        same = [r for r in by_sha[sha]
                if r.get("concl") == "success"
                and (r.get("created") or "") > (red.get("created") or "")]
        if same:
            rerun_green += 1
            evidence["rerun-green"].append((red.get("id"), same[0].get("id")))
            continue
        # a later green on a DIFFERENT sha of the same PR
        pr = red.get("pr")
        later = [r for r in rs
                 if r.get("pr") == pr and r.get("sha") != sha
                 and r.get("concl") == "success"
                 and (r.get("created") or "") > (red.get("created") or "")]
        if later:
            fixed_later += 1
            evidence["fixed-later"].append((red.get("id"), later[0].get("id")))
        else:
            unresolved += 1

    total = len(rs)
    nred = len(reds)
    created = sorted(r.get("created") or "" for r in rs if r.get("created"))
    span_days = None
    if len(created) >= 2:
        try:
            lo = datetime.datetime.fromisoformat(created[0].replace("Z", "+00:00"))
            hi = datetime.datetime.fromisoformat(created[-1].replace("Z", "+00:00"))
            span_days = round((hi - lo).total_seconds() / 86400.0, 2)
        except ValueError:
            span_days = None
    ext = external_inputs.get(wf)
    if nred == 0:
        verdict = "NEVER-RED"
    elif rerun_green > fixed_later and ext:
        # THE VERDICT THIS DOCUMENT WITHDREW, AND THE INSTRUMENT KEPT PRINTING.
        # The rerun-green rule assumes the check's input is the code at the sha.
        # This workflow reads PR metadata, which a human edits WITHOUT a commit,
        # so a same-sha red->green is an author fixing the input — the rerun IS
        # the fix. Calling that a flake is not a near-miss, it is the opposite
        # answer. Selftest arm v7 reds if this branch is removed; v7b proves the
        # branch discriminates rather than blanket-suppressing FLAKE-DOMINANT.
        verdict = "INPUTS-OUTSIDE-SHA"
    elif rerun_green > fixed_later:
        verdict = "FLAKE-DOMINANT"
    elif fixed_later > 0:
        verdict = "CATCH-CANDIDATE"
    else:
        verdict = "RED-UNRESOLVED"
    rows.append({
        "workflow": wf, "runs": total, "reds": nred,
        "rerun_green": rerun_green, "rerun_after_cancel": rerun_after_cancel,
        "catch_candidate": fixed_later,
        "unresolved": unresolved, "verdict": verdict,
        "span_days": span_days,
        "truncated_at": truncated.get(wf),
        "external_inputs": ext,
        "evidence": {k: v[:3] for k, v in evidence.items()},
    })

rows.sort(key=lambda r: (-r["reds"], -r["runs"]))
print("CI VALUE AUDIT — did the red mean anything?")
print("RULE: a later GREEN on the SAME head sha is a RERUN-GREEN and is NEVER a catch —")
print("      BUT ONLY where the check's input IS the code at that sha. A workflow that")
print("      reads PR metadata is verdicted INPUTS-OUTSIDE-SHA, never FLAKE-DOMINANT.")
print("      a later green on a LATER head is a CATCH-CANDIDATE, not a proven catch:")
print("      proving it needs a per-workflow diff test this mode does not do.")
print()

# THE TRUNCATION NOTICE GOES BEFORE THE TABLE, NOT AFTER IT. A reader who quotes
# a ratio off this table has to walk past the sentence saying the rows do not
# share a denominator. `span` is printed for EVERY row, truncated or not, so the
# differing windows are visible even where nothing hit the cap.
trunc = [r for r in rows if r.get("truncated_at")]
if trunc:
    print("!" * 78)
    print(f"!!! TRUNCATED — {len(trunc)} of {len(rows)} workflows hit the per-workflow run cap.")
    print("!!! THE ROWS BELOW DO NOT SHARE A DENOMINATOR. Any row-to-row RATIO taken from")
    print("!!! this table is UNSUPPORTED: a capped row describes its newest N runs, which")
    print("!!! for a busy workflow is a fraction of a day while a quiet one covers the")
    print("!!! whole requested window. Compare per-day rates, or re-run with a shorter")
    print("!!! --since so no row is capped.")
    for r in trunc:
        span = r.get("span_days")
        span_txt = f"{span} d" if span is not None else "unknown span"
        print(f"!!!   {r['workflow']:<30} cap {r['truncated_at']} runs reached; "
              f"these {r['runs']} rows cover {span_txt}")
    print("!" * 78)
    print()

print(f"{'workflow':<34}{'runs':>6}{'reds':>6}{'rerun':>7}{'cand':>6}{'unres':>7}{'span_d':>8}  verdict")
for r in rows:
    span = r.get("span_days")
    span_txt = "?" if span is None else f"{span:g}"
    flag = "  [TRUNCATED]" if r.get("truncated_at") else ""
    print(f"{r['workflow']:<34}{r['runs']:>6}{r['reds']:>6}{r['rerun_green']:>7}"
          f"{r['catch_candidate']:>6}{r['unresolved']:>7}{span_txt:>8}  {r['verdict']}{flag}")
print()
for r in rows:
    if not r["evidence"].get("rerun-green"): continue
    pairs = "; ".join(f"red {a} -> green {b} (same sha)" for a, b in r["evidence"]["rerun-green"])
    if r.get("external_inputs"):
        # NOT flake evidence, and it must not be quotable as such. The same-sha
        # green is the author fixing an input that is not in the sha.
        print(f"NOT FLAKE EVIDENCE {r['workflow']}: reads {r['external_inputs']} — a same-sha "
              f"red->green here is the AUTHOR FIXING THE INPUT, not a flake: {pairs}")
    else:
        print(f"FLAKE EVIDENCE {r['workflow']}: {pairs}")
print()
print(json.dumps({"rows": rows}, indent=2), file=sys.stderr)
VPY
  python3 "$pyf"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

# ---------------------------------------------------------------------------
# --breaker — DID THE MAIN-RED BREAKER NEUTRALISE ANYTHING? (task-3f0fff73fdf57a2d,
# for the parent task-e638b950726fea51 c2.)
#
# THE TWO NUMBERS, and why they are not the same measurement:
#
#   AFTER   PR check-runs of the breaker jobs whose "Decide (main-red breaker …)"
#           step printed INHERITED-FROM-MAIN. This verdict exists ONLY in the job
#           LOG — the job is green either way, so no list endpoint can see it and
#           no `conclusion` field distinguishes it. One log read per job, against
#           a 5,000/hour core budget, so this arm is SAMPLED and every table says
#           how many logs it read. A count with no log budget behind it would be
#           a guess wearing a number.
#
#   BEFORE  PR reds of the SAME jobs, in an equal-length window before the
#           breaker, whose failing step names main's newest completed run at the
#           time already failed on. This is the 631/1,207 step-equality method.
#
# THE BEFORE ARM DOES NOT REIMPLEMENT THAT RULE — it REPLAYS it. Each historical
# red is fed to scripts/main-red-breaker.sh itself through the two hooks the
# script already has (STEP_OUTCOMES/STEP_NAMES, MAIN_RED_BREAKER_FIXTURE), and
# whatever that script says is the answer. A second copy of "ours is a subset of
# main's failed steps" living here would be free to drift from the copy that
# actually gates CI, and then the before/after comparison would be between two
# different rules — which is the one way this table could be confidently wrong.
#
# THE NINE / THE EIGHT. The approval says nine breaker jobs; the workflows on
# main at 6c98c245a declare EIGHT Decide steps (security.yml x4, doc-gates.yml,
# go-format.yml x2, compose-smoke.yml). The list is DERIVED here and printed, so
# the table is right whichever number is right, and a ninth job added tomorrow
# appears without an edit to this script.
# ---------------------------------------------------------------------------

# breaker_jobs — the (workflow file, job name) pairs that run the breaker,
# read out of the workflows themselves. JOB_NAME in the Decide step's env IS the
# rendered check-run name (the breaker matches main's job on it), so this is the
# same string the API returns — no second naming convention to keep in sync.
breaker_jobs() {
  local dir="${BREAKER_WORKFLOWS:-$SCRIPT_DIR/../.github/workflows}"
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'BPY'
import os, re, sys
d = sys.argv[1]
out = []
for fn in sorted(os.listdir(d)):
    if not fn.endswith((".yml", ".yaml")): continue
    lines = open(os.path.join(d, fn), encoding="utf-8", errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        if re.match(r'\s*- name:\s*Decide \(main-red breaker', lines[i]):
            job = wf = ""
            j = i + 1
            while j < len(lines) and not re.match(r'\s*- name:', lines[j]):
                m = re.match(r'\s*JOB_NAME:\s*"(.*)"\s*$', lines[j])
                if m: job = m.group(1)
                m = re.match(r'\s*WORKFLOW_FILE:\s*"?([\w.-]+)"?\s*$', lines[j])
                if m: wf = m.group(1)
                j += 1
            if job and wf: out.append((wf, job))
            i = j; continue
        i += 1
BPY
  # The DERIVATION must never silently return nothing: an empty list would make
  # every count below a truthful-looking zero. Refuse instead.
  cat >> "$pyf" <<'BPY'
if not out:
    print("ci-measure: --breaker derived ZERO breaker jobs from %s — the Decide-step shape changed; refusing to print a table of zeroes" % d, file=sys.stderr)
    raise SystemExit(1)
for wf, job in out:
    print("%s\t%s" % (wf, job))
BPY
  python3 "$pyf" "$dir"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

# breaker_verdict — RAW job log on stdin, the Decide step's verdict on stdout.
# The breaker prints exactly one of two sentence openings and this reads for
# them; anything else is NONE (the job never reached a verdict, or was green).
breaker_verdict() {
  if grep -q 'main-red-breaker: INHERITED-FROM-MAIN' ; then
    echo INHERITED-FROM-MAIN
  else
    echo NONE
  fi
}

# breaker_after_enrich — THE LIVE PATH. RAW job rows in (as the jobs endpoint
# projects them, carrying NO verdict), rows out with "verdict" attached from the
# job's log. This is the arm that has to be driven with gh stubbed: a fixture
# that already carries `verdict` would leave this function unexecuted while every
# count still looked right (the v1c blind spot, and the reason v1d exists).
# BUDGET: one API call per row, capped, and the cap is reported not hidden.
breaker_after_enrich() {
  local budget="${BREAKER_LOG_BUDGET:-160}" read_n=0 line jid log verdict
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    jid=$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("job_id",""))' 2>/dev/null)
    if [ -z "$jid" ] || [ "$read_n" -ge "$budget" ]; then
      printf '%s\n' "$line" | V=UNREAD python3 -c 'import json,sys,os;o=json.load(sys.stdin);o["verdict"]=os.environ["V"];print(json.dumps(o))' 2>/dev/null \
        || printf '%s\n' "$line"
      continue
    fi
    log=$(gh api "repos/$REPO/actions/jobs/$jid/logs" 2>/dev/null)
    read_n=$(( read_n + 1 ))
    verdict=$(printf '%s' "$log" | breaker_verdict)
    # V= goes BEFORE the command — after it, it is argv, os.environ raises, and
    # the un-enriched row falls through silently. (The v1d lesson, verbatim.)
    printf '%s\n' "$line" | V="$verdict" python3 -c 'import json,sys,os;o=json.load(sys.stdin);o["verdict"]=os.environ["V"];print(json.dumps(o))' 2>/dev/null \
      || printf '%s\n' "$line"
  done
  echo "{\"__logs__\":true,\"read\":$read_n,\"budget\":$budget}"
}

# breaker_before_classify — RAW rows in, one "inherited" verdict per historical
# red out, decided by scripts/main-red-breaker.sh ITSELF.
#   {"kind":"pr_red", …,"steps":[{"name":…,"conclusion":…}]}
#   {"kind":"main_jobs","wf":…,"run_id":…,"created":…,"body":{"jobs":[…]}}
# Both shapes are the API's own projections. The classifier pairs each red with
# the NEWEST main_jobs row for the same workflow created at or before it — which
# is what the breaker reads live ("main's newest COMPLETED run").
breaker_before_classify() {
  local tmpd; tmpd="$(mktemp -d)"
  local breaker="${BREAKER_SCRIPT:-$SCRIPT_DIR/main-red-breaker.sh}"
  cat > "$tmpd/in.jsonl"
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'BPY'
import json, sys
mains, reds = [], []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
    (mains if o.get("kind") == "main_jobs" else reds).append(o)
mains.sort(key=lambda m: m.get("created") or "")
for r in reds:
    if r.get("kind") != "pr_red": continue
    cand = [m for m in mains if m.get("wf") == r.get("wf")
            and (m.get("created") or "") <= (r.get("created") or "")]
    m = cand[-1] if cand else None
    failed = [s.get("name") for s in (r.get("steps") or [])
              if s.get("conclusion") == "failure" and s.get("name")]
    print(json.dumps({
        "row": r,
        "outcomes": {("s%d" % i): {"outcome": "failure"} for i, _ in enumerate(failed, 1)},
        "names": {("s%d" % i): n for i, n in enumerate(failed, 1)},
        "main_body": (m or {}).get("body") or {"jobs": []},
        "main_run": (m or {}).get("run_id"),
    }))
BPY
  python3 "$pyf" "$tmpd/in.jsonl" > "$tmpd/paired.jsonl"
  rm -f "$pyf"
  local n=0 pl
  while IFS= read -r pl; do
    [ -z "$pl" ] && continue
    n=$(( n + 1 ))
    printf '%s' "$pl" | python3 -c 'import json,sys;o=json.load(sys.stdin);open(sys.argv[1],"w").write(json.dumps(o["main_body"]))' "$tmpd/main-$n.json"
    local outc nams job wf out
    outc=$(printf '%s' "$pl" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["outcomes"]))')
    nams=$(printf '%s' "$pl" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["names"]))')
    job=$(printf '%s' "$pl"  | python3 -c 'import json,sys;print(json.load(sys.stdin)["row"]["job"])')
    wf=$(printf '%s' "$pl"   | python3 -c 'import json,sys;print(json.load(sys.stdin)["row"]["wf"])')
    # THE REPLAY. The gating script decides; this mode only records what it said.
    out=$(STEP_OUTCOMES="$outc" STEP_NAMES="$nams" JOB_NAME="$job" WORKFLOW_FILE="$wf" \
          GITHUB_EVENT_NAME=pull_request MAIN_RED_BREAKER_FIXTURE="$tmpd/main-$n.json" \
          GITHUB_STEP_SUMMARY=/dev/null bash "$breaker" 2>/dev/null)
    local v; v=$(printf '%s' "$out" | breaker_verdict)
    printf '%s' "$pl" | V="$v" python3 -c 'import json,sys,os;o=json.load(sys.stdin)["row"];o["verdict"]=os.environ["V"];print(json.dumps(o))'
  done < "$tmpd/paired.jsonl"
  rm -rf "$tmpd"
}

# breaker_report — enriched rows (both arms) in, ONE table out: per job, per day,
# BEFORE count and AFTER count, the window boundaries, and the run ids behind
# every count. Run ids are the point: a count nobody can walk back to is not a
# measurement.
breaker_report() {
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'BPY'
import json, sys, collections
a_since, a_until, b_since, b_until = sys.argv[1:5]
counts = collections.defaultdict(lambda: {"BEFORE": [], "AFTER": []})
jobs_seen = []
logs_read = logs_budget = 0
pop = collections.Counter()
examined = collections.Counter()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
    if o.get("__logs__"):
        logs_read += o.get("read", 0); logs_budget = max(logs_budget, o.get("budget", 0)); continue
    if o.get("__pop__"):
        pop[(o["arm"], o["day"])] += o.get("runs", 0); continue
    examined[o.get("arm")] += 1
    if o.get("verdict") != "INHERITED-FROM-MAIN": continue
    counts[(o.get("job"), o.get("day"))][o.get("arm")].append(str(o.get("run_id")))

# THE ZERO THAT LOOKS LIKE AN ANSWER. The first live run of this mode printed a
# tidy "BEFORE 0 / AFTER 0" over 642 sampled PR runs, and the number was not a
# finding — `gh api` had rejected an `--arg` flag it does not have, 2>/dev/null
# ate the message, and every collector emitted nothing. A day with runs in it and
# ZERO rows examined is a broken instrument, never a quiet day, so it refuses.
for arm in ("AFTER", "BEFORE"):
    npop = sum(v for (a, _), v in pop.items() if a == arm)
    if npop and not examined[arm]:
        print("ci-measure: --breaker REFUSES — the %s window holds %d PR runs of the breaker "
              "workflows and ZERO of their jobs came back. That is a collector failure, not a "
              "quiet window; a 0 printed here would read as 'the breaker neutralises nothing'."
              % (arm, npop), file=sys.stderr)
        raise SystemExit(1)
if examined["AFTER"] and not logs_read:
    print("ci-measure: --breaker REFUSES — %d AFTER job(s) were examined and NO job log was read. "
          "The INHERITED-FROM-MAIN verdict exists only in the log, so an AFTER count with zero "
          "log reads behind it is structurally zero." % examined["AFTER"], file=sys.stderr)
    raise SystemExit(1)

print("CI BREAKER MEASUREMENT — how many PR reds the main-red breaker neutralises")
print("AFTER  = a PR check-run whose Decide step printed INHERITED-FROM-MAIN (read from the job LOG).")
print("BEFORE = a PR red of the same job whose failing steps main's newest completed run already failed,")
print("         decided by REPLAYING scripts/main-red-breaker.sh over the historical red (631/1,207 method).")
print()
print(f"AFTER  window {a_since}..{a_until}")
print(f"BEFORE window {b_since}..{b_until}   (same length)")
print(f"AFTER arm is PER-LOG and SAMPLED: {logs_read} job logs read (budget {logs_budget}).")
print("BEFORE arm reads no logs: step conclusions come from the jobs endpoint.")
print()
print(f"{'breaker job':<62}{'day':<12}{'BEFORE':>7}{'AFTER':>7}")
keys = sorted(counts.keys(), key=lambda k: (k[1] or "", k[0] or ""))
tb = ta = 0
for job, day in keys:
    c = counts[(job, day)]
    tb += len(c["BEFORE"]); ta += len(c["AFTER"])
    print(f"{(job or '?')[:60]:<62}{day:<12}{len(c['BEFORE']):>7}{len(c['AFTER']):>7}")
if not keys:
    print("(no INHERITED-FROM-MAIN verdict in either window — see the run-id block for what was sampled)")
print(f"{'TOTAL':<62}{'':<12}{tb:>7}{ta:>7}")
print()
print("RUN IDS BEHIND EACH COUNT")
for job, day in keys:
    c = counts[(job, day)]
    for arm in ("BEFORE", "AFTER"):
        if c[arm]:
            print(f"  {arm:<6} {day} {job[:52]:<54} {','.join(c[arm])}")
if pop:
    print()
    print("SAMPLED FROM (list-endpoint totals, exact):")
    for (arm, day), n in sorted(pop.items()):
        print(f"  {arm:<6} {day}  {n} PR runs of the breaker workflows")
BPY
  python3 "$pyf" "$@"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

# breaker_fetch_after / breaker_fetch_before — the LIVE collectors. Each emits
# only RAW-shaped rows; all judgement happens downstream in the two classifiers
# above, so the fixtures in the selftest are the same lines these produce.
breaker_fetch_after() {
  local d="$1" until="$2" wf job take i
  while :; do
    while IFS=$'\t' read -r wf job; do
      [ -z "$wf" ] && continue
      local total ids rid
      total=$(gh api "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&created=$d&per_page=1" --jq '.total_count' 2>/dev/null) || total=0
      [ -z "$total" ] && total=0
      echo "{\"__pop__\":true,\"arm\":\"AFTER\",\"day\":\"$d\",\"runs\":$total}"
      [ "$total" -eq 0 ] && continue
      take="${BREAKER_SAMPLE:-12}"; [ "$total" -lt "$take" ] && take="$total"
      ids=$(gh api "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&created=$d&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null | head -n "$take")
      for rid in $ids; do
        # `gh api` has NO --arg (it is jq's flag, not gh's) — a job name with a
        # space, a paren or a dash cannot be inlined into --jq safely, so the
        # body comes back whole and REAL jq does the selection. The first live
        # run of this mode printed a clean 0/0 table because gh rejected --arg
        # and 2>/dev/null ate the message; arm b8 now refuses that table.
        gh api "repos/$REPO/actions/runs/$rid/jobs?per_page=100" 2>/dev/null \
          | jq -c --arg j "$job" --arg d "$d" --arg wf "$wf" \
              '.jobs[] | select(.name == $j) | {arm:"AFTER", day:$d, wf:$wf, job:.name, run_id:.run_id, job_id:.id, conclusion:.conclusion}' 2>/dev/null
      done
    done < "$BREAKER_JOBS_TSV"
    [ "$d" = "$until" ] && break
    d=$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=1)).isoformat())" "$d")
    [ "$d" \> "$until" ] && break
  done
}

breaker_fetch_before() {
  local d="$1" until="$2" wf job
  # main's completed push runs, once per workflow for the whole window; the jobs
  # body is fetched only for the runs a red actually pairs with.
  local seen_main="" mrid
  while :; do
    while IFS=$'\t' read -r wf job; do
      [ -z "$wf" ] && continue
      local total ids rid
      total=$(gh api "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&status=failure&created=$d&per_page=1" --jq '.total_count' 2>/dev/null) || total=0
      [ -z "$total" ] && total=0
      echo "{\"__pop__\":true,\"arm\":\"BEFORE\",\"day\":\"$d\",\"runs\":$total}"
      [ "$total" -eq 0 ] && continue
      local take="${BREAKER_SAMPLE:-12}"; [ "$total" -lt "$take" ] && take="$total"
      ids=$(gh api "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&status=failure&created=$d&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null | head -n "$take")
      for rid in $ids; do
        gh api "repos/$REPO/actions/runs/$rid/jobs?per_page=100" 2>/dev/null \
          | jq -c --arg j "$job" --arg d "$d" --arg wf "$wf" \
              '.jobs[] | select(.name == $j and .conclusion == "failure") | {kind:"pr_red", arm:"BEFORE", day:$d, wf:$wf, job:.name, run_id:.run_id, created:.started_at, steps:[.steps[]? | {name, conclusion}]}' 2>/dev/null
      done
      # main's newest completed push run at the START of this day, one per
      # (workflow, day). The breaker reads "newest completed"; replaying against
      # the run that was newest THEN is the faithful reconstruction available
      # from the API, and it is stated rather than assumed.
      case " $seen_main " in *" $wf@$d "*) continue ;; esac
      seen_main="$seen_main $wf@$d"
      mrid=$(gh api "repos/$REPO/actions/workflows/$wf/runs?branch=main&event=push&status=completed&created=<=${d}T23:59:59Z&per_page=1" --jq '.workflow_runs[0].id // empty' 2>/dev/null)
      [ -z "$mrid" ] && continue
      gh api "repos/$REPO/actions/runs/$mrid/jobs?per_page=100" 2>/dev/null \
        | WF="$wf" D="$d" RID="$mrid" python3 -c 'import json,sys,os;print(json.dumps({"kind":"main_jobs","wf":os.environ["WF"],"run_id":int(os.environ["RID"]),"created":os.environ["D"]+"T00:00:00Z","body":json.load(sys.stdin)}))' 2>/dev/null
    done < "$BREAKER_JOBS_TSV"
    [ "$d" = "$until" ] && break
    d=$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=1)).isoformat())" "$d")
    [ "$d" \> "$until" ] && break
  done
}

breaker_mode() {
  local tmpd; tmpd="$(mktemp -d)"
  BREAKER_JOBS_TSV="$tmpd/jobs.tsv"
  breaker_jobs > "$BREAKER_JOBS_TSV" || { rm -rf "$tmpd"; return 1; }
  echo "BREAKER JOBS DERIVED FROM ${BREAKER_WORKFLOWS:-.github/workflows} ($(wc -l < "$BREAKER_JOBS_TSV" | tr -d ' ') jobs, not typed):"
  sed 's/^/  /' "$BREAKER_JOBS_TSV"
  echo

  local a_since a_until b_since b_until
  a_since="$SINCE"; a_until="${UNTIL:-$(date -u +%F)}"
  # The BEFORE window is the SAME LENGTH, ending the day before AFTER starts.
  read -r b_since b_until <<EOF
$(python3 -c '
import datetime, sys
a = datetime.date.fromisoformat(sys.argv[1]); b = datetime.date.fromisoformat(sys.argv[2])
n = (b - a).days + 1
end = a - datetime.timedelta(days=1)
print((end - datetime.timedelta(days=n - 1)).isoformat(), end.isoformat())' "$a_since" "$a_until")
EOF

  {
    if [ -n "${CI_MEASURE_BREAKER_AFTER_FIXTURE:-}" ]; then
      breaker_after_enrich < "$CI_MEASURE_BREAKER_AFTER_FIXTURE"
    else
      breaker_fetch_after "$a_since" "$a_until" > "$tmpd/after.raw"
      grep '"__pop__"' "$tmpd/after.raw" || true
      grep -v '"__pop__"' "$tmpd/after.raw" | breaker_after_enrich
    fi
    if [ -n "${CI_MEASURE_BREAKER_BEFORE_FIXTURE:-}" ]; then
      breaker_before_classify < "$CI_MEASURE_BREAKER_BEFORE_FIXTURE"
    else
      breaker_fetch_before "$b_since" "$b_until" > "$tmpd/before.raw"
      grep '"__pop__"' "$tmpd/before.raw" || true
      grep -v '"__pop__"' "$tmpd/before.raw" | breaker_before_classify
    fi
  } | breaker_report "$a_since" "$a_until" "$b_since" "$b_until"
  local rc=$?
  rm -rf "$tmpd"
  return $rc
}

if [ "$MODE" = value ]; then
  [ -n "$SINCE" ] || { echo "ci-measure: --value-audit needs --since" >&2; usage; }
  value_audit; exit $?
fi

if [ "$MODE" = breaker ]; then
  [ -n "$SINCE" ] || { echo "ci-measure: --breaker needs --since (the AFTER window start)" >&2; usage; }
  breaker_mode; exit $?
fi
if [ "$MODE" = census ]; then
  [ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --census needs --since and --until" >&2; usage; }
  census; exit $?
fi
if [ "$MODE" = selftest ]; then selftest; exit $?; fi
[ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --since and --until are required" >&2; usage; }
fetch | analyze "$SINCE" "$UNTIL" "$JSON" "$CONCURRENCY_LEDGER"
