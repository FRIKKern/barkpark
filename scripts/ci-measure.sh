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
#   bash scripts/ci-measure.sh --selftest                          # fixtures, no network
#   CI_MEASURE_FIXTURE=<file> bash scripts/ci-measure.sh --since … --until …
#
# EXIT CODES
#   0 ok · 1 a measurement refused (see the message) · 2 usage · 70 selftest died early
set -uo pipefail

REPO="${CI_MEASURE_REPO:-FRIKKern/barkpark}"

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
census() {
  local wfs day ev
  wfs=$(gh api "repos/$REPO/actions/workflows?per_page=100" --jq '.workflows[] | "\(.id)\t\(.name)\t\(.path)"' 2>/dev/null)
  [ -z "$wfs" ] && { echo "census: could not list workflows" >&2; return 1; }

  echo "CI RUN CENSUS — $SINCE .. $UNTIL (MEASURED, not sampled: total_count from the list endpoint)"
  echo
  printf '%-34s%10s%10s%10s%10s\n' "workflow" "total" "pull_req" "push" "schedule"
  local g_total=0 g_pr=0 g_push=0 g_sched=0
  while IFS=$'\t' read -r id name path; do
    [ -z "$id" ] && continue
    local t pr pu sc
    t=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&per_page=1" --jq '.total_count' 2>/dev/null); t=${t:-0}
    [ "$t" -eq 0 ] && continue
    pr=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=pull_request&per_page=1" --jq '.total_count' 2>/dev/null); pr=${pr:-0}
    pu=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=push&per_page=1" --jq '.total_count' 2>/dev/null); pu=${pu:-0}
    sc=$(gh api "repos/$REPO/actions/workflows/$id/runs?created=$SINCE..$UNTIL&event=schedule&per_page=1" --jq '.total_count' 2>/dev/null); sc=${sc:-0}
    printf '%-34s%10s%10s%10s%10s\n' "$(basename "$path")" "$t" "$pr" "$pu" "$sc"
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
      local page=1
      while [ "$page" -le 3 ]; do
        gh api "repos/$REPO/actions/workflows/$id/runs?event=pull_request&created=>=$SINCE&per_page=100&page=$page" \
          --jq ".workflow_runs[] | {wf: \"$(basename "$path")\", sha: .head_sha, concl: .conclusion, created: .created_at, pr: (.pull_requests[0].number // 0), id: .id, attempt: .run_attempt, status: .status, prior: .previous_attempt_url}" 2>/dev/null
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
import json, sys, collections

runs = collections.defaultdict(list)
prior_conclusions = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
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
    if nred == 0:
        verdict = "NEVER-RED"
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
        "evidence": {k: v[:3] for k, v in evidence.items()},
    })

rows.sort(key=lambda r: (-r["reds"], -r["runs"]))
print("CI VALUE AUDIT — did the red mean anything?")
print("RULE: a later GREEN on the SAME head sha is a RERUN-GREEN and is NEVER a catch.")
print("      a later green on a LATER head is a CATCH-CANDIDATE, not a proven catch:")
print("      proving it needs a per-workflow diff test this mode does not do.")
print()
print(f"{'workflow':<34}{'runs':>6}{'reds':>6}{'rerun':>7}{'cand':>6}{'unres':>7}  verdict")
for r in rows:
    print(f"{r['workflow']:<34}{r['runs']:>6}{r['reds']:>6}{r['rerun_green']:>7}"
          f"{r['catch_candidate']:>6}{r['unresolved']:>7}  {r['verdict']}")
print()
for r in rows:
    if r["evidence"].get("rerun-green"):
        pairs = "; ".join(f"red {a} -> green {b} (same sha)" for a, b in r["evidence"]["rerun-green"])
        print(f"FLAKE EVIDENCE {r['workflow']}: {pairs}")
print()
print(json.dumps({"rows": rows}, indent=2), file=sys.stderr)
VPY
  python3 "$pyf"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

if [ "$MODE" = value ]; then
  [ -n "$SINCE" ] || { echo "ci-measure: --value-audit needs --since" >&2; usage; }
  value_audit; exit $?
fi

if [ "$MODE" = census ]; then
  [ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --census needs --since and --until" >&2; usage; }
  census; exit $?
fi
if [ "$MODE" = selftest ]; then selftest; exit $?; fi
[ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --since and --until are required" >&2; usage; }
fetch | analyze "$SINCE" "$UNTIL" "$JSON" "$CONCURRENCY_LEDGER"
