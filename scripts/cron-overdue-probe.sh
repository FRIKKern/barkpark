#!/usr/bin/env bash
# cron-overdue-probe.sh — cron silence is invisible; this makes it a red check.
#
# WHAT WAS MEASURED, 2026-09-03 (task-86340d69fc2f36b8, by main and lead-studio-3)
# GitHub Actions cron on a busy repo is best-effort delivery, and on this repo it
# is delivered every 2-5 h or not at all:
#   task-lease-renew   (*/20)  ran ZERO times in 3 h — the claim sweep was dark
#   main-gate-watch    (*/30)  fired 4 times in 12 h, against 24 expected
#   paper-readers      (05:17) did not run at all on 2026-09-03
#   absent-context-census      last ran 04:32Z
# A watch that does not fire reads exactly like a watch with nothing to report.
# That is the whole failure: green by absence.
#
# THE INVARIANT THIS PROBE ENFORCES
#   A CRITICAL-CADENCE workflow has a run newer than 3x its schedule interval.
# Three times, not one: cron delivery is genuinely jittery and a 1x bound would
# red on healthy jitter, which is how a probe gets muted. 3x of */30 is 90
# minutes — well inside the 2-5 h silences actually measured, so the bound is
# loose enough to be quiet and tight enough to have caught every one of them.
#
# AND SILENCE IS NEVER A PASS. A critical workflow with NO run row at all is the
# WORST case, not the absent one: it reds (arm c5). This file exists because
# "nothing came back" was being read as "nothing to say".
#
# CLASSIFICATION, NOT A GLOBAL RULE. A weekly changelog that slips six hours is
# not a defect, and reddening on it would train the fleet to ignore this probe —
# the same mistake absent-context-census.sh made for 93 consecutive runs. Every
# scheduled workflow in the tree therefore carries a CLASS and a dated line
# below, and only `critical` rows are bounded. A scheduled workflow that is NOT
# in the table is a HARD REFUSAL (exit 2), never a silent skip: an unclassified
# workflow is the one nobody has thought about.
#
# THE QUEUED-RUN TRAP, and it is shared with task-82059e31bcccdbd7. "It has a
# run row" is not "it ran". Eight `status: queued` records from 2026-08-07 and
# 2026-08-19 sit in this repo's run list permanently — GitHub answers 409
# "has not been queued yet" to both cancel paths — so a phantom row is evidence
# of nothing and is not accepted as proof of a firing (arm c6).
#
# USAGE
#   bash scripts/cron-overdue-probe.sh                       # live, this repo
#   bash scripts/cron-overdue-probe.sh --runs-file <ndjson> --now <iso>   # hermetic
#   bash scripts/cron-overdue-probe.sh --table <file>        # override the table
#   bash scripts/cron-overdue-probe.sh --selftest            # no network
#
# THE HERMETIC INPUT IS RAW. --runs-file takes the newest run row per workflow
# exactly as the API emits it — {"path": ".github/workflows/x.yml", "status":
# "...", "created_at": "..."} — never a pre-computed age, because a fixture that
# arrives already judged proves only that the harness can read its own answer.
#
# EXIT CODES
#   0 every critical-cadence workflow fired inside its bound
#   1 OVERDUE — at least one critical workflow is silent past 3x its interval
#   2 the table and the tree disagree, a fallback is missing, or usage
#   3 the run list could not be read — UNKNOWN, never reported as fired

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
REPO="${CRON_PROBE_REPO:-FRIKKern/barkpark}"
TABLE_FILE=""
RUNS_FILE=""
NOW_ISO=""
MODE=report
OVERDUE_FACTOR=3

# ── THE CLASSIFICATION TABLE ────────────────────────────────────────────────
# file|class|interval-minutes|dated note
#
# class:
#   critical  silence is a hole in a safety net. Bounded at OVERDUE_FACTOR x the
#             interval, and required to carry a trigger fallback (see
#             check_fallbacks) so cron is not its only way to fire.
#   periodic  an audit whose whole point is the sweep, not the minute. Lag is
#             accepted; listed so the tree is fully accounted for.
#   report    a digest. A day late is a day late.
#
# Every line was written on 2026-09-03 against the 16 workflows carrying a
# `schedule:` trigger on origin/main that day. The task that ordered this work
# said 14; the tree had 16 (task-lease-renew gained its push arm in #15757 and
# is counted here as critical-with-fallback).
DEFAULT_TABLE='absent-context-census.yml|periodic|360|2026-09-03: 6 h absence audit. Its own harness (absent-context-census.test.sh §7) asserts this workflow is SCHEDULE-ONLY, so a push arm is forbidden here by a committed test; a 6 h sweep tolerates a 6 h lag by construction.
breakglass-watch.yml|critical|30|2026-09-03: watches whether branch protection was broken open. Carries push: branches [main] — cron silence cannot hide an unrestored breakglass across a merge.
chronicle-paper.yml|report|1440|2026-09-03: nightly narrative digest. A late chronicle is a late chronicle.
codebase-intel.yml|report|10080|2026-09-03: weekly intelligence sweep. Weekly cadence, weekly tolerance.
cron-overdue-probe.yml|critical|60|2026-09-03: this probe itself. Hourly, and it carries push: branches [main] — a silence watch delivered only by the mechanism it watches is a smoke detector wired to the fire. It appeared in this table because its own table/tree check REFUSED the first live run that did not classify it.
crown-reconcile.yml|periodic|360|2026-09-03: 6 h reconciliation sweep; carries push: branches [main] already.
elixir-nightly.yml|report|1440|2026-09-03: the long Elixir suite, nightly. Its reds are found the next morning either way.
main-gate-watch.yml|critical|30|2026-09-03: the second scream on main tip verdicts. push-refused:scripts/main-gate-watch.test.sh — a push arm was MEASURED harmful (wave 60 D721: 2 of 2 push runs red on tip 026c5b1d78 while main was green, because ~15 s after a merge no check-run row exists yet) and a committed test reds if one comes back. Its fallback is THIS probe: a workflow that may not carry a trigger fallback must at least be watched for silence.
paper-readers.yml|report|1440|2026-09-03: daily paper-reader digest; did not run at all on 09-03, which is the tolerated case for a report.
renew-mail-cert.yml|report|43200|2026-09-03: monthly certificate renewal. 3x a month is a 90-day bound, which is not a useful alarm — the certificate expiry is the alarm, and it is watched where it lands, not here.
required-checks-drift.yml|periodic|1440|2026-09-03: daily drift audit of the required set; carries push: branches [main] already.
scaffy-catalog-drift.yml|report|1440|2026-09-03: daily catalog drift digest; carries push: branches [main].
search-starter-smoke.yml|report|1440|2026-09-03: daily starter smoke; carries push: branches [main].
stale-verdict-watch.yml|critical|30|2026-09-03: watches PRs asserting a green main has moved past. Carries push: branches [main].
studio-journey-smoke.yml|report|1440|2026-09-03: daily Studio journey smoke; carries push: branches [main].
task-lease-renew.yml|critical|20|2026-09-03: the claim sweep. Ran ZERO times in 3 h on 09-03; push: branches [main] was added in #15757 and is present.
weekly-changelog.yml|report|10080|2026-09-03: weekly changelog digest.'

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --table)      TABLE_FILE="$2"; shift 2 ;;
    --runs-file)  RUNS_FILE="$2"; shift 2 ;;
    --now)        NOW_ISO="$2"; shift 2 ;;
    --workflows)  WORKFLOWS_DIR="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --factor)     OVERDUE_FACTOR="$2"; shift 2 ;;
    --selftest)   MODE=selftest; shift ;;
    -h|--help)    usage ;;
    *) echo "cron-overdue-probe: unknown argument '$1'" >&2; usage ;;
  esac
done

table() {
  if [ -n "$TABLE_FILE" ]; then cat "$TABLE_FILE"; else printf '%s\n' "$DEFAULT_TABLE"; fi
}

# Portable across GNU date (CI) and BSD date (stock macOS), same two-form probe
# scripts/absent-context-census.sh uses.
iso_to_epoch() { # <iso8601-Z>
  local iso="$1" e
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  e="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  return 1
}

now_epoch() {
  if [ -n "$NOW_ISO" ]; then iso_to_epoch "$NOW_ISO"; else date -u +%s; fi
}

# Workflow files in the tree that carry a `schedule:` trigger, one basename per
# line. Comments are stripped first: a file that ARGUES about schedules in prose
# (main-gate-watch.yml argues about push:) must not be matched on its prose.
scheduled_files() {
  local f
  for f in "$WORKFLOWS_DIR"/*.yml; do
    [ -f "$f" ] || continue
    if sed 's/#.*//' "$f" | grep -qE '^[[:space:]]{2}schedule:[[:space:]]*$'; then
      basename "$f"
    fi
  done | sort
}

# ── 1. the table and the tree must agree ────────────────────────────────────
# A scheduled workflow nobody classified is the one nobody thought about, and
# defaulting it either way is a decision made by silence. Refuse instead.
check_table() {
  local rc=0 tree tbl only_tree only_tbl
  tree="$(scheduled_files)"
  tbl="$(table | cut -d'|' -f1 | sort)"
  only_tree="$(comm -23 <(printf '%s\n' "$tree") <(printf '%s\n' "$tbl"))"
  only_tbl="$(comm -13 <(printf '%s\n' "$tree") <(printf '%s\n' "$tbl"))"
  if [ -n "$only_tree" ]; then
    echo "REFUSED: scheduled workflow(s) carry no classification line:" >&2
    printf '  %s\n' $only_tree >&2
    echo "  Add a line to the table in $(basename "$0") — class, interval, and a DATED note." >&2
    rc=2
  fi
  if [ -n "$only_tbl" ]; then
    echo "REFUSED: the table classifies workflow(s) that carry no schedule: trigger:" >&2
    printf '  %s\n' $only_tbl >&2
    rc=2
  fi
  return $rc
}

# ── 2. every critical cadence carries a trigger fallback ────────────────────
# push: branches [main] is the fallback: a merge fires the workflow whatever cron
# is doing. The ONE escape hatch is a workflow whose push arm was measured
# HARMFUL — and it is not a note in this file, it is a COMMITTED TEST that reds
# when a push: trigger comes back. `push-refused:<path>` is honoured only when
# that file exists and actually carries the refusal, so the hatch cannot be
# pasted onto a workflow that has not earned it.
check_fallbacks() {
  local rc=0 line file class note wf guard
  while IFS='|' read -r file class _interval note; do
    [ -n "$file" ] || continue
    [ "$class" = "critical" ] || continue
    wf="$WORKFLOWS_DIR/$file"
    if [ ! -f "$wf" ]; then echo "REFUSED: $file is classified critical and does not exist" >&2; rc=2; continue; fi
    if sed 's/#.*//' "$wf" | grep -qE '^[[:space:]]{2}push:[[:space:]]*$'; then
      echo "  ok   $file (critical, every ${_interval}m) carries a push: trigger — cron is not its only way to fire"
      continue
    fi
    guard="$(printf '%s' "$note" | sed -n 's/.*push-refused:\([^ ]*\).*/\1/p')"
    if [ -n "$guard" ] && [ -f "$REPO_ROOT/$guard" ] && grep -q 'THERE MUST BE NO push:' "$REPO_ROOT/$guard"; then
      echo "  ok   $file (critical, every ${_interval}m) has NO push arm and may not have one — $guard reds if it comes back; this probe is its fallback"
      continue
    fi
    echo "REFUSED: $file is classified critical, carries no push: trigger, and names no committed guard that forbids one." >&2
    echo "         Add \`push: branches: [main]\`, or name a guard file with \`push-refused:<path>\` that carries the literal refusal." >&2
    rc=2
  done <<EOF
$(table)
EOF
  return $rc
}

# ── 3. the overdue read ─────────────────────────────────────────────────────
# Newest run per workflow. A queued run older than 24 h is NOT evidence of a
# firing — see THE QUEUED-RUN TRAP above.
read_runs() {
  if [ -n "$RUNS_FILE" ]; then cat "$RUNS_FILE"; return $?; fi
  local file out grc rc=0
  while IFS='|' read -r file _class _interval _note; do
    [ -n "$file" ] || continue
    out="$(gh api "repos/$REPO/actions/workflows/$file/runs?per_page=5" \
             --jq ".workflow_runs[] | {path: \"$file\", status: .status, created_at: .created_at}" 2>&1)"; grc=$?
    if [ "$grc" -ne 0 ]; then
      # A 404 IS AN ANSWER, and the opposite of a read fault: GitHub has no such
      # workflow, so it has certainly not fired. Passing that through as zero
      # rows lets a critical workflow reach the "NO run row" scream instead of
      # hiding behind a repo-wide UNKNOWN. Anything else — 403, a rate limit, a
      # transport error — is genuinely unreadable and must not be scored.
      if grep -qE 'HTTP 404|Not Found' <<<"$out"; then continue; fi
      echo "  read failed for $file: $(printf '%s' "$out" | head -1)" >&2
      rc=3
      continue
    fi
    printf '%s\n' "$out"
  done <<EOF
$(table)
EOF
  return $rc
}

check_overdue() {
  local now rows rc=0 file class interval note newest age bound
  now="$(now_epoch)" || { echo "cron-overdue-probe: --now is not an ISO-8601 Z timestamp" >&2; return 2; }
  rows="$(read_runs)" || { echo "UNKNOWN: the run list could not be read — that is not 'it fired'." >&2; return 3; }
  while IFS='|' read -r file class interval note; do
    [ -n "$file" ] || continue
    [ "$class" = "critical" ] || continue
    # The newest run that is EVIDENCE of a firing: any status except a queued
    # row older than 24 h (1440 minutes).
    newest="$(printf '%s\n' "$rows" | grep -F "\"$file\"" | python3 -c '
import json, sys, datetime
now = float(sys.argv[1])
best = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
    ts = o.get("created_at")
    try:
        e = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        continue
    if o.get("status") == "queued" and (now - e) > 1440 * 60:
        continue
    if best is None or e > best: best = e
print(int(best) if best is not None else "")
' "$now" 2>/dev/null)"
    bound=$(( interval * OVERDUE_FACTOR ))
    if [ -z "$newest" ]; then
      # THE ONE EXEMPTION, and it is not a judgement call: the workflow that is
      # EXECUTING RIGHT NOW has fired by definition. GitHub indexes a run into
      # the list endpoint a moment after it starts, so on the very first push
      # that creates this file the probe can read zero rows for itself and
      # scream about a workflow that is, at that instant, running the scream.
      # GITHUB_WORKFLOW_REF is set only by Actions and names the executing file
      # (owner/repo/.github/workflows/<file>@ref), so this cannot be claimed by
      # any other row.
      if [ -n "${GITHUB_WORKFLOW_REF:-}" ] \
         && [ "$(basename "${GITHUB_WORKFLOW_REF%%@*}")" = "$file" ]; then
        echo "  ok   $file (critical, every ${interval}m): no row in the list yet — THIS run is the firing (GITHUB_WORKFLOW_REF)"
        continue
      fi
      echo "OVERDUE  $file (critical, every ${interval}m): NO run row is evidence of a firing at all. Silence is not a pass." >&2
      rc=1
      continue
    fi
    age=$(( (now - newest) / 60 ))
    [ "$age" -lt 0 ] && age=0
    if [ "$age" -gt "$bound" ]; then
      echo "OVERDUE  $file (critical, every ${interval}m): newest run is ${age}m old, bound is ${OVERDUE_FACTOR}x = ${bound}m." >&2
      rc=1
    else
      echo "  ok   $file (critical, every ${interval}m): newest run ${age}m old, inside the ${bound}m bound"
    fi
  done <<EOF
$(table)
EOF
  return $rc
}

selftest() {
  local tmp pass=0 fail=0 out rc
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local NOW=2026-09-03T12:00:00Z

  # c1 — the table describes THIS tree. Non-vacuous: a table matching an empty
  # tree would pass a set comparison trivially.
  local n_tree
  n_tree="$(scheduled_files | grep -c . || true)"
  if check_table >/dev/null 2>&1 && [ "$n_tree" -ge 10 ]; then
    pass=$((pass+1)); echo "  ok   c1 all $n_tree scheduled workflow(s) in .github/workflows carry a classification line, and none is classified that has no schedule"
  else
    fail=$((fail+1)); echo "  FAIL c1 the table and the tree disagree ($n_tree scheduled files found)"; check_table
  fi

  # c1b — and that comparison can LOSE: a table missing one row must refuse.
  table | grep -v '^main-gate-watch.yml' > "$tmp/short-table"
  if ! TABLE_FILE="$tmp/short-table" check_table >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   c1b a table with main-gate-watch.yml deleted REFUSES — c1 is a question that can fail"
  else
    fail=$((fail+1)); echo "  FAIL c1b a table missing a scheduled workflow was accepted"
  fi

  # c2 — a critical workflow that fired 20 minutes ago is fine. RAW rows.
  cat > "$tmp/fresh.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "in_progress", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/fresh.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c2 every critical workflow with a run in the last 20m passes — the probe is quiet when cron is healthy"
  else
    fail=$((fail+1)); echo "  FAIL c2 a healthy fixture reddened (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c3 — THE MUTATION THIS PROBE EXISTS FOR: fake a 6 h gap on main-gate-watch
  # (*/30, bound 90m) and nothing else. One field moves; the verdict must move
  # with it, and it must NAME the workflow.
  sed 's|"main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"|"main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T06:00:00Z"|' \
    "$tmp/fresh.ndjson" > "$tmp/gap6h.ndjson"
  if [ "$(grep -c '2026-09-03T06:00:00Z' "$tmp/gap6h.ndjson")" = "1" ] \
     && ! diff -q "$tmp/fresh.ndjson" "$tmp/gap6h.ndjson" >/dev/null; then
    pass=$((pass+1)); echo "  ok   c3a the 6 h gap MUTATION applied — exactly one row moved from 11:40Z to 06:00Z"
  else
    fail=$((fail+1)); echo "  FAIL c3a the mutation did not apply — c3b below would be proving nothing"
  fi
  out="$(RUNS_FILE="$tmp/gap6h.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out" && grep -q '360m old' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c3b a 6 h gap on a */30 workflow REDS at exit 1, naming it: $(grep -o 'OVERDUE  main-gate-watch.yml.*' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c3b a 6 h gap did not red (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c3c — and the FACTOR is doing the work, not the timestamp. The identical
  # 6 h-gap fixture under a factor wide enough to cover it must pass.
  out="$(RUNS_FILE="$tmp/gap6h.ndjson" NOW_ISO="$NOW" OVERDUE_FACTOR=100 check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c3c …and the SAME 6 h gap passes at factor 100 — the 3x bound is the discriminator, not a pinned date"
  else
    fail=$((fail+1)); echo "  FAIL c3c the 6 h gap still red at factor 100 (rc=$rc) — something other than the bound is deciding"
  fi

  # c4 — CLASS discriminates. A 30-day gap on a report-class workflow is not a
  # finding: a probe that reds on everything is a probe nobody reads.
  cat > "$tmp/report-gap.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
{"path": "weekly-changelog.yml", "status": "completed", "created_at": "2026-08-04T11:40:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/report-gap.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c4 a 30-day gap on a REPORT-class workflow is not a finding — the class does the discriminating"
  else
    fail=$((fail+1)); echo "  FAIL c4 a report-class gap reddened the probe (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c5 — SILENCE IS THE WORST CASE. No row at all for a critical workflow reds.
  grep -v 'task-lease-renew' "$tmp/fresh.ndjson" > "$tmp/missing.ndjson"
  out="$(RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'NO run row' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c5 a critical workflow with NO run row at all reds — absence is never read as health"
  else
    fail=$((fail+1)); echo "  FAIL c5 a missing workflow was treated as fired (rc=$rc)"
  fi

  # c5b — THE EXEMPTION, both directions. The executing workflow has fired by
  # definition; nothing else may claim that. c5 above is the same fixture with
  # the env unset, so the pair proves the env is doing the work.
  out="$(GITHUB_WORKFLOW_REF="FRIKKern/barkpark/.github/workflows/task-lease-renew.yml@refs/heads/main" \
         RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'THIS run is the firing' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c5b …and the workflow that is EXECUTING is exempt from its own missing row — the same fixture c5 reds on"
  else
    fail=$((fail+1)); echo "  FAIL c5b the executing workflow was still called overdue (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  out="$(GITHUB_WORKFLOW_REF="FRIKKern/barkpark/.github/workflows/some-other.yml@refs/heads/main" \
         RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ]; then
    pass=$((pass+1)); echo "  ok   c5c …and a DIFFERENT executing workflow cannot claim the exemption — it names one file, not any file"
  else
    fail=$((fail+1)); echo "  FAIL c5c the exemption was claimed by an unrelated workflow (rc=$rc)"
  fi

  # c6 — A PHANTOM QUEUED ROW IS NOT A FIRING (task-82059e31bcccdbd7). The row
  # exists, is 27 days old, and status queued: GitHub will not dequeue it and
  # refuses both cancel paths. Accepting it as evidence would make this probe
  # permanently green on exactly the workflow that stopped running.
  cat > "$tmp/phantom.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "queued", "created_at": "2026-08-07T09:08:43Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/phantom.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'main-gate-watch.yml' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c6 a 27-day-old QUEUED row is not accepted as a firing — the run list has a row and the workflow is still dark"
  else
    fail=$((fail+1)); echo "  FAIL c6 a phantom queued row was read as a firing (rc=$rc) — the probe would be green on a dead workflow"
  fi

  # c7 — every critical cadence carries a fallback, checked against the REAL tree.
  out="$(check_fallbacks 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c7 every critical-cadence workflow carries push: branches [main], or a committed guard that forbids one"
  else
    fail=$((fail+1)); echo "  FAIL c7 a critical workflow has no fallback:"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c7b — the escape hatch cannot be pasted. A critical row naming a guard file
  # that does not carry the refusal must be REFUSED.
  table | sed 's|^main-gate-watch.yml|main-gate-watch.yml|; s|push-refused:scripts/main-gate-watch.test.sh|push-refused:scripts/ci-measure.sh|' > "$tmp/bad-guard"
  if ! TABLE_FILE="$tmp/bad-guard" check_fallbacks >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   c7b naming a guard file that does not carry the refusal is REFUSED — the exemption cannot be copy-pasted onto another workflow"
  else
    fail=$((fail+1)); echo "  FAIL c7b a bogus push-refused: guard was accepted"
  fi

  echo
  echo "SELFTEST: $pass passed, $fail failed."
  [ "$fail" -eq 0 ]
}

if [ "$MODE" = selftest ]; then selftest; exit $?; fi

echo "cron-overdue-probe — repo $REPO, bound ${OVERDUE_FACTOR}x the schedule interval"
echo
check_table || exit 2
check_fallbacks || exit 2
echo
check_overdue
RC=$?
echo
case "$RC" in
  0) echo "VERDICT  cron: every critical-cadence workflow fired inside ${OVERDUE_FACTOR}x its interval" ;;
  1) echo "VERDICT  cron: SCREAM — a critical-cadence workflow is silent past ${OVERDUE_FACTOR}x its interval (named above). GitHub cron is best-effort; the remedy is the workflow's push/dispatch fallback, not a retry." ;;
  3) echo "VERDICT  cron: UNKNOWN — the run list could not be read. Not a pass." ;;
esac
exit $RC
