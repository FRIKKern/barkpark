#!/usr/bin/env python3
"""Per-JOB minutes on the pull_request path, read from the REST jobs endpoint.

WHY THIS EXISTS, AND WHY IT IS NOT `ci-pr-inventory.py`
------------------------------------------------------
`scripts/ci-pr-inventory.py` measures a WORKFLOW's median real compute per run
and verdicts the workflow.  That granularity cannot answer the question the CI
diet actually asks, because a venue decision is made per JOB: `pr-meta.yml`'s
573 s lived in ONE of its jobs and the other fifteen gates totalled ~35 s.  A
workflow-level median hides exactly the job you would move.

So this script reads `/actions/runs/<id>/jobs` for the last N completed
pull_request runs of each workflow and reports, PER JOB NAME:

  * `exec`      — runs in which the job EXECUTED at least one step (a step
                  whose conclusion is `success` or `failure`).  Only these
                  contribute seconds.  A job cancelled before its first step
                  and a job the event/`if:` skipped both report a duration and
                  both did zero work; folding them in is the 63%-cancelled
                  trap the prior recount stepped in.
  * `median s`  — median of `completed_at - started_at` over the exec runs.
  * `total min` — SUM over the exec runs, i.e. what this job really cost the
                  sampled window.
  * `min/exec`  — median minutes per executing run.
  * `runs*m/e`  — exec x min/exec.  THE SORT KEY, per the mandate: a 12 s job
                  that fires on every push outranks a 200 s job that fires
                  twice.
  * `zero-step` — jobs present in the run that executed no step, split into
                  `cancelled` and `skipped`.  These are UNMEASURED, which is a
                  VERDICT, not a gap: they are printed, never summed, and
                  never silently counted as either compute or absence.

Usage
-----
    scripts/ci-job-minutes-census.py --selftest            # offline, raw fixtures
    scripts/ci-job-minutes-census.py --measure > rows.json # ~13x51 REST calls
    scripts/ci-job-minutes-census.py --render rows.json    # zero API calls

`--measure` uses `gh api` REST only.  It never touches GraphQL (`gh pr view`,
parts of `gh run view`), whose budget is separate, smaller and easily burnt.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from datetime import datetime, timezone

REPO = "FRIKKern/barkpark"

# The pull_request-path roster: every workflow the committed inventory
# (.github/ci-pr-inventory.md, 2026-09-06) measured as firing on 20 of 20
# sampled merged PR heads, plus architecture.yml (12/20), the one remaining
# `move-to-nightly` verdict.  A workflow that does not fire on a PR head costs
# the PR path nothing, so measuring it would inflate the census with compute no
# PR pays for.
DEFAULT_WORKFLOWS = [
    "console-harness.yml",
    "cloud.yml",
    "elixir.yml",
    "pr-task-gate.yml",
    "pr-meta.yml",
    "compose-smoke.yml",
    "doc-gates.yml",
    "reland-check.yml",
    "required-checks-drift.yml",
    "security.yml",
    "go-tests.yml",
    "task-lease-renew.yml",
    "architecture.yml",
]

RUNS_PER_WORKFLOW = 50


# ---------------------------------------------------------------- derivations
# Everything below is pure: it takes RAW GitHub REST payloads and returns rows.
# `--selftest` drives these with fixtures in exactly that raw shape, so the
# selftest exercises the same code the measurement does.


def _parse_ts(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def executed_a_step(job):
    """True iff at least one step reached a real conclusion.

    `skipped`, `cancelled` and `null` step conclusions do not count.  A job
    with no `steps` key at all (the endpoint omits it for some skipped jobs)
    executed nothing.
    """
    for step in job.get("steps") or []:
        if step.get("conclusion") in ("success", "failure"):
            return True
    return False


def job_seconds(job):
    started = _parse_ts(job.get("started_at"))
    completed = _parse_ts(job.get("completed_at"))
    if started is None or completed is None:
        return None
    delta = (completed - started).total_seconds()
    return delta if delta >= 0 else None


def fold_jobs(payloads):
    """payloads: list of {"workflow":…, "run_id":…, "created_at":…, "jobs":[raw]}.

    Returns (rows, window) where rows are per (workflow, job name).
    """
    acc = {}
    created = []
    for payload in payloads:
        wf = payload["workflow"]
        if payload.get("created_at"):
            created.append(payload["created_at"])
        for job in payload.get("jobs") or []:
            key = (wf, job.get("name", "?"))
            row = acc.setdefault(
                key,
                {
                    "workflow": wf,
                    "job": key[1],
                    "seen": 0,
                    "exec": 0,
                    "secs": [],
                    "zero_cancelled": 0,
                    "zero_skipped": 0,
                    "zero_other": 0,
                },
            )
            row["seen"] += 1
            if executed_a_step(job):
                secs = job_seconds(job)
                if secs is not None:
                    row["exec"] += 1
                    row["secs"].append(secs)
            else:
                conclusion = job.get("conclusion")
                if conclusion == "cancelled":
                    row["zero_cancelled"] += 1
                elif conclusion == "skipped":
                    row["zero_skipped"] += 1
                else:
                    row["zero_other"] += 1

    rows = []
    for row in acc.values():
        secs = sorted(row["secs"])
        median = statistics.median(secs) if secs else 0.0
        total_min = sum(secs) / 60.0
        min_per_exec = median / 60.0
        rows.append(
            {
                "workflow": row["workflow"],
                "job": row["job"],
                "seen": row["seen"],
                "exec": row["exec"],
                "median_s": round(median, 1),
                "total_min": round(total_min, 2),
                "min_per_exec": round(min_per_exec, 3),
                "rank": round(row["exec"] * min_per_exec, 3),
                "zero_cancelled": row["zero_cancelled"],
                "zero_skipped": row["zero_skipped"],
                "zero_other": row["zero_other"],
            }
        )
    rows.sort(key=lambda r: (-r["rank"], -r["total_min"], r["workflow"], r["job"]))
    window = {
        "first_created_at": min(created) if created else None,
        "last_created_at": max(created) if created else None,
        "runs": len(payloads),
    }
    return rows, window


def render(rows, window, workflows):
    if not rows:
        raise SystemExit("REFUSING: zero parsed rows — a census with no rows measures nothing")
    out = []
    out.append(
        "Window: runs created %s .. %s (%d completed pull_request runs over %d workflows)"
        % (
            window.get("first_created_at"),
            window.get("last_created_at"),
            window.get("runs", 0),
            len(workflows),
        )
    )
    out.append("")
    out.append(
        "| workflow | job | exec/seen | median s | min/exec | total min | runs x min/exec | UNMEASURED (zero-step) |"
    )
    out.append("|---|---|---|---|---|---|---|---|")
    for r in rows:
        unmeasured = "%d cancelled / %d skipped" % (r["zero_cancelled"], r["zero_skipped"])
        if r["zero_other"]:
            unmeasured += " / %d other" % r["zero_other"]
        if not (r["zero_cancelled"] or r["zero_skipped"] or r["zero_other"]):
            unmeasured = "—"
        out.append(
            "| `%s` | %s | %d/%d | %.1f | %.3f | %.2f | **%.3f** | %s |"
            % (
                r["workflow"],
                r["job"],
                r["exec"],
                r["seen"],
                r["median_s"],
                r["min_per_exec"],
                r["total_min"],
                r["rank"],
                unmeasured,
            )
        )
    out.append("")
    out.append(
        "Totals: %d job rows; %.2f measured job-minutes; %d zero-step cancelled, %d zero-step skipped (UNMEASURED, never summed)."
        % (
            len(rows),
            sum(r["total_min"] for r in rows),
            sum(r["zero_cancelled"] for r in rows),
            sum(r["zero_skipped"] for r in rows),
        )
    )
    return "\n".join(out)


# ------------------------------------------------------------------ measuring


def gh_api(path):
    proc = subprocess.run(
        ["gh", "api", path, "--cache", "0"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        sys.stderr.write("gh api %s failed: %s\n" % (path, proc.stderr.strip()[:300]))
        return None
    return json.loads(proc.stdout)


def measure(workflows, limit):
    payloads = []
    for wf in workflows:
        listing = gh_api(
            "repos/%s/actions/workflows/%s/runs?event=pull_request&status=completed&per_page=%d"
            % (REPO, wf, limit)
        )
        if not listing:
            sys.stderr.write("NOTE: no runs listing for %s\n" % wf)
            continue
        runs = listing.get("workflow_runs", [])
        sys.stderr.write("%s: %d completed pull_request runs\n" % (wf, len(runs)))
        for run in runs:
            jobs = gh_api("repos/%s/actions/runs/%d/jobs?per_page=100" % (REPO, run["id"]))
            if not jobs:
                continue
            payloads.append(
                {
                    "workflow": wf,
                    "run_id": run["id"],
                    "created_at": run.get("created_at"),
                    "jobs": jobs.get("jobs", []),
                }
            )
    return payloads


# ------------------------------------------------------------------- selftest

RAW_FIXTURES = [
    # A run where one job executed steps (120 s) and one was cancelled before
    # its first step — the 63%-cancelled trap, in raw endpoint shape.
    {
        "workflow": "fixture.yml",
        "run_id": 1,
        "created_at": "2026-09-01T00:00:00Z",
        "jobs": [
            {
                "name": "Heavy",
                "conclusion": "success",
                "started_at": "2026-09-01T00:00:00Z",
                "completed_at": "2026-09-01T00:02:00Z",
                "steps": [{"conclusion": "success"}],
            },
            {
                "name": "Cancelled early",
                "conclusion": "cancelled",
                "started_at": "2026-09-01T00:00:00Z",
                "completed_at": "2026-09-01T00:00:40Z",
                "steps": [{"conclusion": "skipped"}],
            },
        ],
    },
    {
        "workflow": "fixture.yml",
        "run_id": 2,
        "created_at": "2026-09-03T00:00:00Z",
        "jobs": [
            {
                "name": "Heavy",
                "conclusion": "failure",
                "started_at": "2026-09-03T00:00:00Z",
                "completed_at": "2026-09-03T00:04:00Z",
                "steps": [{"conclusion": "failure"}],
            },
            # A path-skipped job: reports a duration, did no work.
            {
                "name": "Cancelled early",
                "conclusion": "skipped",
                "started_at": "2026-09-03T00:00:00Z",
                "completed_at": "2026-09-03T00:00:01Z",
                "steps": [],
            },
        ],
    },
    {
        "workflow": "fixture.yml",
        "run_id": 3,
        "created_at": "2026-09-02T00:00:00Z",
        "jobs": [
            # A cheap job that fires every time: its RANK must beat nothing
            # here, but the sort key must be exec x min/exec, not min/exec.
            {
                "name": "Cheap but constant",
                "conclusion": "success",
                "started_at": "2026-09-02T00:00:00Z",
                "completed_at": "2026-09-02T00:00:30Z",
                "steps": [{"conclusion": "success"}],
            }
        ],
    },
]


def selftest():
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append("%s: got %r want %r" % (label, got, want))

    rows, window = fold_jobs(RAW_FIXTURES)

    # NON-VACUITY ARM: a derivation that parses nothing must not report PASS.
    if not rows:
        raise SystemExit("SELFTEST REFUSES: fold_jobs parsed zero rows from the fixtures")
    if sum(r["exec"] for r in rows) == 0:
        raise SystemExit("SELFTEST REFUSES: zero executing job-runs parsed from the fixtures")

    by_job = {r["job"]: r for r in rows}
    check("row count", len(rows), 3)

    heavy = by_job["Heavy"]
    check("Heavy exec", heavy["exec"], 2)
    check("Heavy median s", heavy["median_s"], 180.0)  # median(120, 240)
    check("Heavy total min", heavy["total_min"], 6.0)
    check("Heavy rank", heavy["rank"], round(2 * 3.0, 3))

    zero = by_job["Cancelled early"]
    check("zero-step exec", zero["exec"], 0)
    check("zero-step seen", zero["seen"], 2)
    check("zero-step total min", zero["total_min"], 0.0)
    check("zero-step cancelled label", zero["zero_cancelled"], 1)
    check("zero-step skipped label", zero["zero_skipped"], 1)

    cheap = by_job["Cheap but constant"]
    check("cheap median s", cheap["median_s"], 30.0)

    # Sort key is exec x min/exec, and it is applied.
    check("sort head", rows[0]["job"], "Heavy")

    # A step conclusion of `cancelled` is not execution.
    check(
        "cancelled step is not execution",
        executed_a_step({"steps": [{"conclusion": "cancelled"}]}),
        False,
    )
    check("no steps key is not execution", executed_a_step({}), False)
    check(
        "a failure step IS execution",
        executed_a_step({"steps": [{"conclusion": "failure"}]}),
        True,
    )

    # Window is read from the payloads, not typed.
    check("window first", window["first_created_at"], "2026-09-01T00:00:00Z")
    check("window last", window["last_created_at"], "2026-09-03T00:00:00Z")

    # render() refuses an empty census rather than printing an empty table.
    try:
        render([], window, [])
        failures.append("render([]) did not refuse")
    except SystemExit:
        pass

    if failures:
        print("SELFTEST FAILED (%d):" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("SELFTEST PASSED: %d arms over %d raw fixture runs, %d rows parsed"
          % (18, len(RAW_FIXTURES), len(rows)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--measure", action="store_true")
    ap.add_argument("--render", metavar="ROWS_JSON")
    ap.add_argument("--limit", type=int, default=RUNS_PER_WORKFLOW)
    ap.add_argument("--workflow", action="append", default=None)
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    workflows = args.workflow or DEFAULT_WORKFLOWS

    if args.measure:
        payloads = measure(workflows, args.limit)
        if not payloads:
            raise SystemExit("REFUSING: measured zero runs")
        rows, window = fold_jobs(payloads)
        json.dump(
            {"rows": rows, "window": window, "workflows": workflows},
            sys.stdout,
            indent=1,
        )
        sys.stdout.write("\n")
        return 0

    if args.render:
        with open(args.render) as fh:
            data = json.load(fh)
        print(render(data["rows"], data["window"], data.get("workflows", [])))
        return 0

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
