#!/usr/bin/env bash
# breaker-verdict-census-2026-09-20.sh — the derivation behind
# breaker-before-after-2026-09-20.md (task-33682262f429d104 c2 + c3).
#
# WHAT IT DOES, AND WHY IT IS NOT `ci-measure.sh --breaker`.
# ci-measure.sh's breaker_verdict() is TWO-valued — INHERITED-FROM-MAIN, else
# NONE — and breaker_report() drops every non-INHERITED row. So the three-way
# split criterion 3 asks for (INHERITED / OWNERSHIP-UNDETERMINED / this-PR's-own)
# is STRUCTURALLY ZERO in that instrument at every window: OWNERSHIP-UNDETERMINED
# reads back as the same NONE a green job gets. This script therefore reads the
# SAME job logs ci-measure reads and greps the FIVE sentence openings that
# scripts/main-red-breaker.sh's say() actually emits:
#     main-red-breaker: INHERITED-FROM-MAIN —      (neutralised, exit 0)
#     main-red-breaker: OWNERSHIP-UNDETERMINED —   (honest cannot-tell, exit 1)
#     main-red-breaker: FAIL —                     (this PR's own, exit 1)
#     main-red-breaker: RUNNER-LOCAL —             (the host's, neither)
#     main-red-breaker: no gate step failed in     (green, no verdict reached)
# Verified against main-red-breaker.sh lines 330/362/463/757-759/1138/1245/1417/475.
#
# POPULATION is EXACT (the list endpoint's own total_count). The verdict split is
# SAMPLED and every number it produces is labelled ESTIMATED.
#
# USAGE   bash scripts/measurements/breaker-verdict-census-2026-09-20.sh <outdir> [runs_per_window]
# REQUIRES  gh (authenticated), python3, jq. Budget: ~1 core call per sampled run
#           + 1 per breaker job log. 50 runs/window ≈ 300 calls of a 5000/h budget.
set -uo pipefail
REPO="${CI_MEASURE_REPO:-FRIKKern/barkpark}"
OUT="${1:?usage: $0 <outdir> [runs_per_window]}"; N="${2:-50}"
mkdir -p "$OUT"

# The three windows. Boundaries are COMMIT TIMESTAMPS, quoted in the packet.
#   W1 BEFORE      pre-9cc549964 (2026-09-06T00:21:33Z), breaker at 8527591cf
#   W2 BETWEEN     9cc549964 .. ad80d3bce (2026-09-06T19:43:20Z)  PARTIAL DAY
#   W3 AFTER       first 3 FULL days post-ad80d3bce with NO further breaker commit
WINDOWS='W1|2026-09-04T00:00:00Z|2026-09-05T23:59:59Z|8527591cf
W2|2026-09-06T00:21:33Z|2026-09-06T19:43:20Z|e96934ec0
W3|2026-09-09T00:00:00Z|2026-09-11T23:59:59Z|e5ef630bc'

# The breaker job list is DERIVED from the workflows AS THEY WERE in each window,
# never typed: the set grew from 8 to 10 between W1 and W2 (required-checks-drift
# gained two), so a single typed list would misattribute the growth.
derive_jobs() { # $1 = sha, $2 = scratch dir
  local sha="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
  git archive "$sha" .github/workflows | tar -x -C "$d" --strip-components=2
  python3 - "$d" <<'PY'
import os, re, sys
d = sys.argv[1]
for fn in sorted(os.listdir(d)):
    if not fn.endswith((".yml", ".yaml")): continue
    lines = open(os.path.join(d, fn), encoding="utf-8", errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        if re.match(r'\s*- name:\s*Decide \(main-red breaker', lines[i]):
            job = wf = ""; j = i + 1
            while j < len(lines) and not re.match(r'\s*- name:', lines[j]):
                m = re.match(r'\s*JOB_NAME:\s*"(.*)"\s*$', lines[j])
                if m: job = m.group(1)
                m = re.match(r'\s*WORKFLOW_FILE:\s*"?([\w.-]+)"?\s*$', lines[j])
                if m: wf = m.group(1)
                j += 1
            if job and wf: print("%s\t%s" % (wf, job))
            i = j; continue
        i += 1
PY
}

: > "$OUT/runs.tsv"; : > "$OUT/verdicts.tsv"; : > "$OUT/population.tsv"
printf 'window\tworkflow\tjob\n' > "$OUT/jobs.tsv"

printf '%s\n' "$WINDOWS" | while IFS='|' read -r win since until sha; do
  [ -z "$win" ] && continue
  derive_jobs "$sha" "$OUT/wf-$win" > "$OUT/jobs-$win.tsv"
  awk -v w="$win" -F'\t' '{print w"\t"$1"\t"$2}' "$OUT/jobs-$win.tsv" >> "$OUT/jobs.tsv"
  cut -f1 "$OUT/jobs-$win.tsv" | sort -u > "$OUT/wfs-$win.txt"

  while read -r wf; do
    # EXACT population: the list endpoint's own total_count for this window.
    tot=$(gh api "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&created=$since..$until&per_page=1" --jq '.total_count' 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\n' "$win" "$wf" "$since" "$until" "${tot:-ERR}" >> "$OUT/population.tsv"
    # The run ids themselves, capped at the API's 1000-item ceiling.
    gh api --paginate "repos/$REPO/actions/workflows/$wf/runs?event=pull_request&created=$since..$until&per_page=100" \
      --jq '.workflow_runs[] | [.id, .created_at, .conclusion] | @tsv' 2>/dev/null \
      | awk -v w="$win" -v f="$wf" -F'\t' '{print w"\t"f"\t"$1"\t"$2"\t"$3}' >> "$OUT/runs.tsv"
  done < "$OUT/wfs-$win.txt"
done

# SYSTEMATIC sample (evenly spaced across each window's run list), never the
# first N: runs cluster by hour, so a head-of-list slice is a time-of-day slice.
python3 - "$OUT" "$N" <<'PY' > "$OUT/sample.tsv"
import sys, collections
out, n = sys.argv[1], int(sys.argv[2])
by = collections.defaultdict(list)
for line in open(out + "/runs.tsv"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4: by[p[0]].append(p)
for win, rows in by.items():
    rows.sort(key=lambda r: r[3])
    k = max(1, len(rows) // n) if len(rows) > n else 1
    for r in rows[::k][:n]: print("\t".join(r))
PY

# THE VERDICT READ. One jobs call per sampled run, one log call per breaker job.
while IFS=$'\t' read -r win wf run_id created concl; do
  [ -z "$run_id" ] && continue
  jobs_json=$(gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" 2>/dev/null)
  [ -z "$jobs_json" ] && { printf '%s\t%s\t%s\t-\t-\tJOBS-UNREADABLE\n' "$win" "$wf" "$run_id" >> "$OUT/verdicts.tsv"; continue; }
  while IFS=$'\t' read -r jid jname jconcl; do
    [ -z "$jid" ] && continue
    # Literal-tab key, built explicitly so an editor cannot collapse it silently.
    key=$(printf '%s\t%s' "$wf" "$jname")
    grep -qxF "$key" "$OUT/jobs-$win.tsv" || continue
    # RETRY, and do not trust a SHORT body. A job whose log does not exist --
    # a SKIPPED job, or a transient failure -- gets a ~215-byte BlobNotFound XML
    # document on STDOUT, not an empty string, so `[ -z "$log" ]` lets it through
    # and it lands in NO-BREAKER-OUTPUT as if the job had run and said nothing.
    # That is how two real THIS-PRS-OWN verdicts were lost on the first census
    # pass. The error is ONE-DIRECTIONAL (a verdict needs its sentence literally
    # present), so every classification below can only ever be understated.
    log=""
    for _try in 1 2 3; do
      log=$(gh api "repos/$REPO/actions/jobs/$jid/logs" 2>/dev/null)
      [ "${#log}" -gt 1000 ] && break
      sleep 2
    done
    if   [ "${#log}" -le 1000 ];                                         then v=NO-LOG
    elif printf '%s' "$log" | grep -qF 'main-red-breaker: INHERITED-FROM-MAIN';    then v=INHERITED-FROM-MAIN
    elif printf '%s' "$log" | grep -qF 'main-red-breaker: OWNERSHIP-UNDETERMINED'; then v=OWNERSHIP-UNDETERMINED
    elif printf '%s' "$log" | grep -qF 'main-red-breaker: RUNNER-LOCAL';           then v=RUNNER-LOCAL
    elif printf '%s' "$log" | grep -qF 'main-red-breaker: FAIL';                   then v=THIS-PRS-OWN
    elif printf '%s' "$log" | grep -qF 'main-red-breaker: no gate step failed';    then v=GREEN-NO-VERDICT
    else v=NO-BREAKER-OUTPUT; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$win" "$wf" "$run_id" "$jid" "$jname" "$jconcl" "$v" >> "$OUT/verdicts.tsv"
  done < <(printf '%s' "$jobs_json" | python3 -c 'import json,sys
try: o=json.load(sys.stdin)
except Exception: raise SystemExit(0)
for j in o.get("jobs",[]): print("%s\t%s\t%s"%(j.get("id"),j.get("name"),j.get("conclusion")))')
done < "$OUT/sample.tsv"

echo "wrote: $OUT/{population,runs,sample,verdicts,jobs}.tsv"
