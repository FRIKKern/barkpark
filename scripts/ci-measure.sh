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

fetch() {
  if [ -n "${CI_MEASURE_FIXTURE:-}" ]; then cat "$CI_MEASURE_FIXTURE"; return; fi
  local d="$SINCE"
  while :; do
    local day_total=0 day_got=0 h
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
        local rid
        rid=$(gh api "repos/$REPO/actions/runs?created=$lo..$hi&per_page=100&page=$page" \
                --jq ".workflow_runs[$idx].id" 2>/dev/null)
        if [ -n "$rid" ] && [ "$rid" != "null" ]; then
          day_got=$(( day_got + 1 ))
          gh api "repos/$REPO/actions/runs/$rid/jobs?per_page=100" \
            --jq '.jobs[] | {name, workflow_name, run_id, conclusion, started_at, completed_at, steps: [.steps[]? | {started_at, completed_at}]}' \
            2>/dev/null
        fi
        i=$(( i + 1 ))
      done
    done
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
}

if [ "$MODE" = census ]; then
  [ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --census needs --since and --until" >&2; usage; }
  census; exit $?
fi
if [ "$MODE" = selftest ]; then selftest; exit $?; fi
[ -n "$SINCE" ] && [ -n "$UNTIL" ] || { echo "ci-measure: --since and --until are required" >&2; usage; }
fetch | analyze "$SINCE" "$UNTIL" "$JSON" "$CONCURRENCY_LEDGER"
