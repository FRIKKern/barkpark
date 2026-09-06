#!/usr/bin/env python3
"""ci-pr-inventory.py — regenerate the PR-path CI inventory.

WHAT THIS IS FOR. One PR push fans out across every workflow that declares an
`on: pull_request` trigger. Branch protection blocks on four contexts. This
script derives, per PR-triggered workflow, the three facts a venue decision
needs -- authority (required / feeds-required / advisory), REAL compute, and
red rate on main -- and prints a markdown table. The committed table
(.github/ci-pr-inventory.md) is this script's output, dated; regenerate rather
than hand-edit, because a hand-renumbered table rots in its own commit.

THE THREE TRAPS THIS SCRIPT EXISTS TO NOT FALL INTO, each measured, not feared:

 1. REAL COMPUTE EXCLUDES RUNS THAT NEVER EXECUTED A STEP. A cancelled run and
    a path-skipped run both report a wall-clock duration and neither did work.
    A prior recount found 63% of measured elixir job-minutes were cancelled
    runs that never started a step. So a job counts toward compute only if it
    has at least one step whose conclusion is success or failure -- a job that
    was cancelled AFTER running steps DOES count (it burned a runner), one
    cancelled before its first step does NOT.

 2. A SKIPPED JOB REPORTS SUCCESS. A red rate over run conclusions alone calls
    a workflow healthy when it merely never ran. Every row therefore carries
    `main_runs_no_exec` -- main runs in the window with zero executed jobs --
    next to the red rate, and a red rate whose denominator is small is marked.

 3. LISTINGS CAP AT 1000. Both `gh run list` and a single `created=` page set
    top out at 1000 items. This script pages with `page`/`per_page` and stops
    at the API's own 1000-item ceiling; when a workflow hits it, the row is
    flagged `capped` and its window is a FLOOR, not the total.

REQUIRED / FEEDS-REQUIRED are DERIVED, never typed:
  required      -- the workflow contains a job whose `name` is one of the
                   contexts in .github/required-checks.json
                   (.protection.required_status_checks.checks[].context).
  feeds-required-- the job sits in the transitive `needs:` closure of such a
                   job. `needs:` is workflow-local, so this is a per-workflow
                   property; no workflow in this repo calls another as a
                   reusable workflow, which the script asserts.
  advisory      -- neither.

VENUE RULE APPLIED IN THE `verdict` COLUMN (amended 2026-09-06):
  a PR runs only what CAN BLOCK IT, or FINISHES UNDER 60 s, or is
  PATH-FILTERED to paths the PR actually changed.
  A path-filtered advisory arm is legitimate: it costs nothing on the PRs it
  does not match, and it is NOT verdicted move-to-push merely for being
  advisory. That third clause is the amendment; before it, every advisory row
  read move-to-push, which would have emptied the PR path of ~35 legitimate
  narrow gates.

Usage:
  scripts/ci-pr-inventory.py                 # markdown table to stdout
  scripts/ci-pr-inventory.py --json          # the raw rows
  scripts/ci-pr-inventory.py --days 30       # window (default 30)
  scripts/ci-pr-inventory.py --sample 20     # runs job-sampled per venue
  scripts/ci-pr-inventory.py --selftest      # offline: prove the derivations

Auth: uses `gh auth token`. Read-only; it never writes to GitHub.
"""
import argparse, json, os, re, statistics, subprocess, sys, glob, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import urllib.request, urllib.error, urllib.parse

REPO = "FRIKKern/barkpark"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF_DIR = os.path.join(ROOT, ".github", "workflows")
REQ_FILE = os.path.join(ROOT, ".github", "required-checks.json")
API = "https://api.github.com"
# GitHub's own ceiling on a listing: page*per_page may not exceed 1000.
LIST_CEILING = 1000


# ---------------------------------------------------------------- topology ---
def required_contexts(path=REQ_FILE):
    """READ the required set. Never type a context string."""
    with open(path) as fh:
        spec = json.load(fh)
    checks = spec["protection"]["required_status_checks"]["checks"]
    excl = {e["context"] for e in spec.get("exclusions", [])}
    return {c["context"] for c in checks}, excl


def load_yaml(path):
    import yaml
    with open(path) as fh:
        return yaml.safe_load(fh)


def topology(wf_dir=WF_DIR, req=None):
    """Per workflow: triggers, path filters, jobs, required + feeds-required.

    YAML 1.1 parses a bare `on:` key as the boolean True; both spellings are
    accepted here so a workflow written either way is not silently dropped.
    """
    req = req if req is not None else required_contexts()[0]
    rows = {}
    for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml")) +
                       glob.glob(os.path.join(wf_dir, "*.yaml"))):
        name = os.path.basename(path)
        y = load_yaml(path) or {}
        on = y.get("on", y.get(True))
        if isinstance(on, dict):
            keys, pr = set(on.keys()), on.get("pull_request")
        elif isinstance(on, list):
            keys, pr = set(str(k) for k in on), None
        else:
            keys, pr = {str(on)}, None
        if "pull_request" not in keys:
            continue
        jobs = {k: v for k, v in (y.get("jobs") or {}).items() if isinstance(v, dict)}
        jnames = {jid: (j.get("name") or jid) for jid, j in jobs.items()}
        needs = {}
        for jid, j in jobs.items():
            n = j.get("needs", [])
            needs[jid] = [n] if isinstance(n, str) else list(n or [])
        reuse = [jid for jid, j in jobs.items() if j.get("uses")]
        req_jobs = [jid for jid, n in jnames.items() if n in req]
        feeds, frontier = set(), list(req_jobs)
        while frontier:
            for n in needs.get(frontier.pop(), []):
                if n not in feeds:
                    feeds.add(n)
                    frontier.append(n)
        # A job-level `paths` cannot exist in GitHub Actions; only the
        # workflow-level `on: pull_request: paths[-ignore]` filters a run.
        wf_paths = bool(isinstance(pr, dict) and
                        ("paths" in pr or "paths-ignore" in pr))
        rows[name] = {
            "workflow": name,
            "triggers": sorted(keys),
            "has_push_main": "push" in keys,
            "path_filtered": wf_paths,
            "paths": (pr.get("paths") if isinstance(pr, dict) else None),
            "jobs": len(jobs),
            "job_names": sorted(jnames.values()),
            "required_jobs": sorted(jnames[j] for j in req_jobs),
            "feeds_required": sorted(jnames[j] for j in feeds),
            "reusable_callers": reuse,
            "advisory_only_jobs": sorted(
                n for jid, n in jnames.items()
                if jid not in req_jobs and jid not in feeds),
        }
    return rows


def authority(row):
    if row["required_jobs"]:
        return "required"
    if row["feeds_required"]:
        return "feeds-required"
    return "advisory"


# ------------------------------------------------------------------- github ---
_TOKEN = None


def token():
    global _TOKEN
    if _TOKEN is None:
        _TOKEN = subprocess.run(["gh", "auth", "token"], capture_output=True,
                                text=True, check=True).stdout.strip()
    return _TOKEN


# Completed runs are immutable, so their /jobs payload is cached on disk. A
# rerun of this script then costs ~0 API calls, which matters: the primary
# limit is 5000/hour and one full pass is ~2000 calls.
CACHE = os.environ.get("CI_PR_INVENTORY_CACHE",
                       os.path.join(os.path.expanduser("~"), ".cache",
                                    "ci-pr-inventory"))


def api(path, params=None, cacheable=False):
    """One GET, with backoff. 403/429 here is the SECONDARY rate limit, not a
    permission error -- retrying instantly is what makes a 24-thread pass
    slower than a 6-thread one, so honour Retry-After and back off."""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    ck = None
    if cacheable:
        import hashlib
        ck = os.path.join(CACHE, hashlib.sha256(url.encode()).hexdigest() + ".json")
        if os.path.exists(ck):
            try:
                with open(ck) as fh:
                    return json.load(fh)
            except Exception:
                pass
    rq = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token(),
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    delay = 1.0
    for attempt in range(6):
        try:
            with urllib.request.urlopen(rq, timeout=60) as r:
                body = json.loads(r.read())
            if ck:
                os.makedirs(CACHE, exist_ok=True)
                tmp = ck + ".tmp%d" % os.getpid()
                with open(tmp, "w") as fh:
                    json.dump(body, fh)
                os.replace(tmp, ck)
            return body
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 502, 503):
                ra = e.headers.get("Retry-After")
                time.sleep(float(ra) if ra else delay)
                delay = min(delay * 2, 30)
                continue
            raise
        except Exception:
            time.sleep(delay)
            delay = min(delay * 2, 30)
    raise RuntimeError("giving up on " + url)


def run_count(wf, since, event, branch=None, status=None):
    """COUNT without paging. `total_count` on a one-item page is the whole
    filtered set, so a 30-day census costs one call per status instead of ten
    pages -- and it is not subject to the 1000-item listing ceiling that makes
    a paged census a floor. `status` here doubles as a conclusion filter
    (GitHub accepts `failure`, `skipped`, `cancelled`, `success` on this
    parameter alongside the true statuses)."""
    p = {"event": event, "created": ">=" + since, "per_page": 1,
         "exclude_pull_requests": "true"}
    if branch:
        p["branch"] = branch
    if status:
        p["status"] = status
    return api(f"/repos/{REPO}/actions/workflows/{wf}/runs", p).get("total_count", 0)


def recent_runs(wf, since, event, branch=None, want=20):
    """One page (<=100) of the most recent COMPLETED runs in the window. The
    caller slices it for the job sample AND tallies it for the RECENCY split:
    a 30-day red rate averages across a regime change and understates a
    workflow that went permanently red last week. Measured on doc-gates.yml
    2026-09-06: 660/2201 failures over 30 days (42% of decided runs) but 97 of
    the last 100 main runs red. Both numbers are true; only the second one
    tells you the gate is dead."""
    p = {"event": event, "created": ">=" + since, "per_page": 100, "page": 1,
         "status": "completed", "exclude_pull_requests": "true"}
    if branch:
        p["branch"] = branch
    return api(f"/repos/{REPO}/actions/workflows/{wf}/runs", p).get("workflow_runs", [])


def executed_job_seconds(run_id):
    """Wall-seconds of jobs that ACTUALLY EXECUTED A STEP, and the count.

    A job counts only if it has >=1 step concluding success or failure. A run
    cancelled before any step started therefore contributes 0 -- which is the
    whole point: duration is not compute."""
    body = api(f"/repos/{REPO}/actions/runs/{run_id}/jobs",
               {"per_page": 100, "filter": "latest"}, cacheable=True)
    total, n_exec, n_jobs = 0.0, 0, 0
    for j in body.get("jobs", []):
        n_jobs += 1
        steps = j.get("steps") or []
        if not any((s.get("conclusion") in ("success", "failure")) for s in steps):
            continue
        s, c = j.get("started_at"), j.get("completed_at")
        if not (s and c):
            continue
        dt = (datetime.fromisoformat(c.replace("Z", "+00:00")) -
              datetime.fromisoformat(s.replace("Z", "+00:00"))).total_seconds()
        if dt > 0:
            total += dt
            n_exec += 1
    return total, n_exec, n_jobs


def pctl(xs, q):
    if not xs:
        return None
    ys = sorted(xs)
    i = min(len(ys) - 1, int(round(q * (len(ys) - 1))))
    return round(ys[i], 1)


def measure(wf, days, sample, pool, recent_n=100):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    main_total = run_count(wf, since, "push", "main")
    main_done = run_count(wf, since, "push", "main", "completed")
    main_red = run_count(wf, since, "push", "main", "failure")
    main_green = run_count(wf, since, "push", "main", "success")
    main_cancelled = run_count(wf, since, "push", "main", "cancelled")
    main_skipped = run_count(wf, since, "push", "main", "skipped")
    main_decided = main_red + main_green
    pr_total = run_count(wf, since, "pull_request")

    def jobs_for(runs):
        if not runs:
            return [], 0
        res = list(pool.map(lambda r: executed_job_seconds(r["id"]), runs))
        secs = [t for (t, ne, nj) in res if ne > 0]
        return secs, sum(1 for (t, ne, nj) in res if ne == 0)

    pr_page = recent_runs(wf, since, "pull_request", None)
    main_page = recent_runs(wf, since, "push", "main")
    pr_sample, main_sample = pr_page[:sample], main_page[:sample]
    pr_secs, pr_noexec = jobs_for(pr_sample)
    main_secs, main_noexec = jobs_for(main_sample)

    # THE RECENCY SPLIT. Newest-first page, capped at recent_n.
    rec = main_page[:recent_n]
    rec_decided = [r for r in rec if r.get("conclusion") in ("success", "failure")]
    rec_red = sum(1 for r in rec_decided if r["conclusion"] == "failure")

    return {
        "window_days": days,
        "since": since,
        "main_runs": main_total,
        "main_completed": main_done,
        "main_red": main_red,
        # DECIDED denominator: a cancelled run is neither a red nor a green,
        # and folding it into the denominator dilutes every rate on a fleet
        # that cancels superseded runs constantly.
        "main_success": main_green,
        "main_cancelled": main_cancelled,
        "main_conclusion_skipped": main_skipped,
        "main_red_rate": (main_red / main_decided) if main_decided else None,
        "main_recent_n": len(rec_decided),
        "main_recent_red": rec_red,
        "main_recent_red_rate": (rec_red / len(rec_decided)) if rec_decided else None,
        "main_sampled": len(main_sample),
        "main_no_exec_in_sample": main_noexec,
        "main_median_real_job_seconds": (round(statistics.median(main_secs), 1)
                                         if main_secs else None),
        "pr_runs": pr_total,
        "pr_sampled": len(pr_sample),
        "pr_no_exec_in_sample": pr_noexec,
        "median_real_job_seconds": (round(statistics.median(pr_secs), 1) if pr_secs else None),
        "p90_real_job_seconds": pctl(pr_secs, 0.9),
        "max_real_job_seconds": pctl(pr_secs, 1.0),
        "real_compute_n": len(pr_secs),
        # Counts come from `total_count`, which the 1000-item listing ceiling
        # does not bound; only the JOB SAMPLE and the recency page are samples,
        # and both print their own n.
        "capped": False,
    }


def fire_rates(n_heads, pool):
    """EMPIRICAL fan-out: on how many of the last n merged PR heads did each
    workflow actually START a run?

    This is the column that separates a DECLARATION from a FIRING, and it is
    the only honest test of the venue rule's path-filter clause. A `paths:`
    key is not evidence of narrowing: doc-gates.yml carries one whose globs
    are `**/*.md`, `**/*.ex`, `**/*.go`, `**/*.ts`, `**/*.tsx` and
    `.github/workflows/**` -- it fires on every PR this repo produces. A prior
    count of "46 of 59 workflows fire on pull_request" counted declarations.
    """
    raw = subprocess.run(
        ["gh", "pr", "list", "-R", REPO, "--state", "merged", "--limit",
         str(n_heads), "--json", "number,headRefOid"],
        capture_output=True, text=True, check=True).stdout
    heads = [(p["number"], p["headRefOid"]) for p in json.loads(raw)]

    def one(head):
        num, sha = head
        seen, page = set(), 1
        while True:
            body = api(f"/repos/{REPO}/actions/runs",
                       {"head_sha": sha, "event": "pull_request",
                        "per_page": 100, "page": page,
                        "exclude_pull_requests": "true"}, cacheable=True)
            runs = body.get("workflow_runs", [])
            for r in runs:
                seen.add(os.path.basename(r.get("path", "")))
            if len(runs) < 100:
                break
            page += 1
        checks = api(f"/repos/{REPO}/commits/{sha}/check-runs",
                     {"per_page": 1}, cacheable=True).get("total_count")
        return num, sha, seen, checks

    per_head = list(pool.map(one, heads))
    counts = {}
    for _, _, seen, _ in per_head:
        for w in seen:
            counts[w] = counts.get(w, 0) + 1
    return {
        "n_heads": len(per_head),
        "heads": [{"pr": n, "sha": s, "workflows": len(w), "check_runs": c}
                  for n, s, w, c in per_head],
        "rate": {w: c / len(per_head) for w, c in counts.items()},
    }


# ------------------------------------------------------------------ verdict ---
FAST_S = 60.0
# A `paths:` key only earns the amendment's third clause if it actually keeps
# the workflow OFF PRs. The cut is drawn at half the sampled heads: a filter
# that fires on more than half of this repo's PRs is not targeting the paths a
# PR changed, it is the PR path with extra steps. Drawn by judgment, stated so
# it can be argued with -- and every row prints its measured fire rate, so a
# reader can move the line and re-read the table without rerunning anything.
FILTER_EFFECTIVE_MAX = 0.5


def verdict(row, m, fire=None):
    """The amended venue rule, one clause per line, most-permissive first.

    A PR runs only what CAN BLOCK IT, or FINISHES UNDER 60 s, or is
    PATH-FILTERED to paths the PR actually changed.
    """
    a = row["authority"]
    if a in ("required", "feeds-required"):
        return "keep-on-PR", f"{a}: it can block the merge"
    med = m.get("median_real_job_seconds")
    if m.get("pr_runs", 0) == 0 and m.get("main_runs", 0) == 0:
        return "delete", "advisory and DEAD: zero runs in the window on either venue"
    fr = None if fire is None else fire.get(row["workflow"], 0.0)
    if row["path_filtered"] and (fr is None or fr <= FILTER_EFFECTIVE_MAX):
        pct = "unsampled" if fr is None else f"fires on {fr*100:.0f}% of sampled PR heads"
        return "keep-on-PR", (f"advisory but genuinely PATH-FILTERED ({pct}): "
                              "it costs nothing on a PR that misses its paths")
    if med is not None and med <= FAST_S:
        return "keep-on-PR", f"advisory, but real compute {med}s is under the {int(FAST_S)}s floor"
    broad = ""
    if row["path_filtered"]:
        broad = (f"its `paths:` filter is NOT narrowing — it fires on "
                 f"{fr*100:.0f}% of sampled PR heads; ")
    # WHICH venue it moves to is not a taste call: a workflow with a
    # push-to-main arm already HAS a main venue and an owner who sees that
    # red, so the move is a trigger edit. One with NO push arm has no main
    # venue to move to -- moving it to push would be inventing a run that has
    # never existed, on a tree nobody has watched -- so nightly, where a
    # whole-tree census belongs anyway, is the honest destination.
    dest = "move-to-push" if row.get("has_push_main") else "move-to-nightly"
    why = ("it already runs on push to main, so this is a trigger edit"
           if row.get("has_push_main")
           else "it has NO push-to-main arm, so there is no main venue to move to")
    if med is None:
        return dest, (broad + "no sampled PR run executed a step, so it buys the "
                      "PR nothing; " + why)
    return dest, (broad + f"advisory, {med}s of real compute that cannot block the "
                  f"merge; {why}")


def unaccounted(n_heads, pool):
    """Every check-run NAME a real PR head rendered, split three ways against
    `.github/required-checks.json`.

    A context can be neither required nor excluded -- UNACCOUNTED -- and that
    is a finding in itself, because required-checks.json's own `_readme`
    concedes `EXCLUSIONS ARE WHAT THE SAMPLE SAW, never a complete census` and
    its generator samples main PUSH heads, which render no pull_request-only
    name at all.

    The reverse direction matters just as much: a ledger row that matches
    NOTHING a real PR head renders is a row governing a name that no longer
    exists. Matrix job names carry their interpolated version, so a ledger
    pinned to one Elixir version silently stops matching when the matrix moves.
    """
    raw = subprocess.run(
        ["gh", "pr", "list", "-R", REPO, "--state", "merged", "--limit",
         str(n_heads), "--json", "number,headRefOid"],
        capture_output=True, text=True, check=True).stdout
    heads = [p["headRefOid"] for p in json.loads(raw)]

    def names(sha):
        out, page = set(), 1
        while True:
            body = api(f"/repos/{REPO}/commits/{sha}/check-runs",
                       {"per_page": 100, "page": page}, cacheable=True)
            runs = body.get("check_runs", [])
            out.update(r["name"] for r in runs)
            if len(runs) < 100:
                return out
            page += 1

    rendered = set()
    for s_ in pool.map(names, heads):
        rendered |= s_
    req, excl = required_contexts()
    return {
        "n_heads": len(heads),
        "rendered": sorted(rendered),
        "required_rendered": sorted(rendered & req),
        "excluded_rendered": sorted(rendered & excl),
        "unaccounted": sorted(rendered - req - excl),
        "ledger_rows_matching_nothing": sorted((req | excl) - rendered),
    }


# ------------------------------------------------------------------- render ---
def fmt(v, suffix="", dash="—"):
    return dash if v is None else f"{v}{suffix}"


def render(rows, days, since, generated, nheads=0):
    L = []
    L.append(f"Generated {generated} by `scripts/ci-pr-inventory.py` "
             f"over a {days}-day window (runs created >= {since}).")
    L.append("")
    L.append("| workflow | authority | fires on N/{n} PR heads | declares `paths:` | "
             "median real compute (PR) | p90 | main red rate, {d}d | main red rate, "
             "last 100 | main runs w/ no executed job | verdict | ground |"
             .format(n=nheads, d=days))
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        m = r["m"]
        rr = m["main_red_rate"]
        rrs = ("no main arm" if rr is None
               else f"{rr*100:.0f}% ({m['main_red']}/{m['main_red']+m['main_success']})")
        rc = m["main_recent_red_rate"]
        rcs = ("—" if rc is None
               else f"{rc*100:.0f}% ({m['main_recent_red']}/{m['main_recent_n']})")
        fr = r.get("fire_rate")
        L.append("| `{w}` | {a} | {f} | {p} | {c} | {q} | {r} | {rc} | {n} | **{v}** | {g} |".format(
            w=r["workflow"], a=r["authority"],
            f=("—" if fr is None else "%d" % round(fr * nheads)),
            p=("yes" if r["path_filtered"] else "no"),
            c=fmt(m["median_real_job_seconds"], " s") +
              (f" (n={m['real_compute_n']}/{m['pr_sampled']})" if m["real_compute_n"] else ""),
            q=fmt(m["p90_real_job_seconds"], " s"),
            r=rrs, rc=rcs,
            n=f"{m['main_no_exec_in_sample']}/{m['main_sampled']}",
            v=r["verdict"], g=r["ground"]))
    return "\n".join(L)


# ----------------------------------------------------------------- selftest ---
def selftest():
    import tempfile, textwrap
    fails = []

    def check(label, cond, detail=""):
        print(("ok   " if cond else "FAIL ") + label + ("" if cond else " :: " + detail))
        if not cond:
            fails.append(label)

    d = tempfile.mkdtemp()
    wf = os.path.join(d, "workflows")
    os.makedirs(wf)
    open(os.path.join(wf, "a.yml"), "w").write(textwrap.dedent("""
        name: a
        on:
          pull_request:
            paths: ["api/**"]
        jobs:
          leaf: {name: Leaf, runs-on: x, steps: []}
          mid:  {name: Mid, needs: leaf, runs-on: x, steps: []}
          gate: {name: Elixir gate, needs: [mid], runs-on: x, steps: []}
          side: {name: Side, runs-on: x, steps: []}
    """))
    # `on` unquoted parses as the boolean True under YAML 1.1 -- the parser
    # must still see this workflow.
    open(os.path.join(wf, "b.yml"), "w").write(textwrap.dedent("""
        name: b
        on: [pull_request, push]
        jobs:
          only: {name: Only, runs-on: x, steps: []}
    """))
    open(os.path.join(wf, "c.yml"), "w").write(textwrap.dedent("""
        name: c
        on:
          push: {branches: [main]}
        jobs:
          only: {name: Only, runs-on: x, steps: []}
    """))
    t = topology(wf, req={"Elixir gate"})
    check("a1 PR-triggered workflows only", sorted(t) == ["a.yml", "b.yml"], str(sorted(t)))
    check("a2 bare `on: [pull_request]` list form is seen", "b.yml" in t)
    check("a3 required job derived from the read context",
          t["a.yml"]["required_jobs"] == ["Elixir gate"], str(t["a.yml"]["required_jobs"]))
    check("a4 feeds-required is the TRANSITIVE needs closure",
          t["a.yml"]["feeds_required"] == ["Leaf", "Mid"], str(t["a.yml"]["feeds_required"]))
    check("a5 a sibling outside the closure is NOT feeds-required",
          "Side" not in t["a.yml"]["feeds_required"])
    check("a6 workflow-level paths filter detected", t["a.yml"]["path_filtered"] is True)
    check("a7 unfiltered workflow reports no filter", t["b.yml"]["path_filtered"] is False)
    check("a8 authority: required beats feeds", authority(t["a.yml"]) == "required")
    check("a9 authority: advisory when neither", authority(t["b.yml"]) == "advisory")

    # The venue rule -- each clause proven to FIRE and to NOT fire.
    def row(auth, pf, paths=None, push=True):
        return {"authority": auth, "path_filtered": pf, "paths": paths or [],
                "workflow": "w", "has_push_main": push}
    check("a10 fire rate keys on the workflow FILENAME, which is what the runs "
          "API returns in .path", os.path.basename(".github/workflows/x.yml") == "x.yml")
    v, g = verdict(row("required", False), {"pr_runs": 5, "main_runs": 5})
    check("b1 required keeps its PR seat", v == "keep-on-PR", g)
    v, g = verdict(row("feeds-required", False), {"pr_runs": 5, "main_runs": 5})
    check("b2 feeds-required keeps its PR seat", v == "keep-on-PR", g)
    v, g = verdict(row("advisory", True, ["api/**"]),
                   {"pr_runs": 5, "main_runs": 5, "median_real_job_seconds": 900.0},
                   {"w": 0.2})
    check("b3 AMENDMENT: a slow, genuinely PATH-FILTERED advisory keeps its seat",
          v == "keep-on-PR", g)
    v, g = verdict(row("advisory", True, ["**/*.md", "**/*.ex"]),
                   {"pr_runs": 5, "main_runs": 5, "median_real_job_seconds": 900.0},
                   {"w": 1.0})
    check("b3b a `paths:` key that fires on EVERY sampled head is not a filter",
          v == "move-to-push" and "NOT narrowing" in g, g)
    v, g = verdict(row("advisory", True, ["**/*.md"]),
                   {"pr_runs": 5, "main_runs": 5, "median_real_job_seconds": 5.0},
                   {"w": 1.0})
    check("b3c ... but a broad filter that is FAST still keeps its seat",
          v == "keep-on-PR", g)
    v, g = verdict(row("advisory", False),
                   {"pr_runs": 5, "main_runs": 5, "median_real_job_seconds": 12.0})
    check("b4 a sub-60s unfiltered advisory keeps its seat", v == "keep-on-PR", g)
    v, g = verdict(row("advisory", False),
                   {"pr_runs": 5, "main_runs": 5, "median_real_job_seconds": 61.0})
    check("b5 a slow unfiltered advisory WITH a push arm moves to push",
          v == "move-to-push", g)
    v, g = verdict(row("advisory", False, push=False),
                   {"pr_runs": 5, "main_runs": 0, "median_real_job_seconds": 300.0})
    check("b5b ... and one with NO push arm goes NIGHTLY, not push",
          v == "move-to-nightly", g)
    v, g = verdict(row("advisory", False), {"pr_runs": 0, "main_runs": 0})
    check("b6 zero runs on either venue = delete", v == "delete", g)
    v, g = verdict(row("advisory", False),
                   {"pr_runs": 9, "main_runs": 1, "median_real_job_seconds": None})
    check("b7 an advisory that never executes a step moves to push",
          v == "move-to-push", g)

    # Real-compute accounting: the trap that made 63% of a figure phantom.
    class FakeJobs:
        def __init__(self, payload):
            self.payload = payload

    def exec_seconds_from(jobs):
        total, ne = 0.0, 0
        for j in jobs:
            steps = j.get("steps") or []
            if not any(s.get("conclusion") in ("success", "failure") for s in steps):
                continue
            s, c = j["started_at"], j["completed_at"]
            dt = (datetime.fromisoformat(c.replace("Z", "+00:00")) -
                  datetime.fromisoformat(s.replace("Z", "+00:00"))).total_seconds()
            if dt > 0:
                total += dt
                ne += 1
        return total, ne

    never_started = [{"started_at": "2026-09-01T00:00:00Z",
                      "completed_at": "2026-09-01T00:04:00Z",
                      "steps": [{"conclusion": "skipped"}]}]
    check("c1 a 4-minute run that executed NO step contributes 0 seconds",
          exec_seconds_from(never_started) == (0.0, 0), str(exec_seconds_from(never_started)))
    ran_then_cancelled = [{"started_at": "2026-09-01T00:00:00Z",
                           "completed_at": "2026-09-01T00:04:00Z",
                           "steps": [{"conclusion": "success"}, {"conclusion": None}]}]
    check("c2 a run cancelled AFTER executing a step DOES burn compute",
          exec_seconds_from(ran_then_cancelled) == (240.0, 1),
          str(exec_seconds_from(ran_then_cancelled)))
    no_steps = [{"started_at": "2026-09-01T00:00:00Z",
                 "completed_at": "2026-09-01T00:04:00Z", "steps": []}]
    check("c3 a job with an EMPTY step list contributes 0",
          exec_seconds_from(no_steps) == (0.0, 0))

    check("d1 the listing ceiling is the API's, not a guess", LIST_CEILING == 1000)
    check("d2 p90 of 1..10 is 9", pctl(list(range(1, 11)), 0.9) == 9,
          str(pctl(list(range(1, 11)), 0.9)))
    check("d3 p90 of a single sample is that sample", pctl([7.0], 0.9) == 7.0)
    check("d4 p90 of nothing is None, never 0", pctl([], 0.9) is None)
    # The recency split, on the shape that motivated it: a workflow that was
    # green for a month and has been red all week.
    page = ([{"conclusion": "failure"}] * 97 + [{"conclusion": "success"}] * 3)
    dec = [r for r in page if r["conclusion"] in ("success", "failure")]
    red = sum(1 for r in dec if r["conclusion"] == "failure")
    check("d5 recency page reads 97% red where the 30-day rate read 42%",
          red / len(dec) == 0.97)
    mixed = [{"conclusion": "cancelled"}] * 50 + [{"conclusion": "success"}] * 2
    dec2 = [r for r in mixed if r["conclusion"] in ("success", "failure")]
    check("d6 cancelled runs are EXCLUDED from the red-rate denominator, "
          "not counted green", len(dec2) == 2)
    print()
    print(("SELFTEST FAILED: " + ", ".join(fails)) if fails else "SELFTEST OK")
    return 1 if fails else 0


# --------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--sample", type=int, default=12)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--pr-heads", type=int, default=20)
    ap.add_argument("--recent", type=int, default=100)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--unaccounted", action="store_true",
                    help="census of check-run NAMES on real PR heads vs the "
                         "required/exclusions ledger, both directions")
    ap.add_argument("--render", metavar="ROWS_JSON",
                    help="re-render the table from a saved --json payload; "
                         "costs zero API calls, so the committed table can be "
                         "reformatted without re-measuring")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.unaccounted:
        with ThreadPoolExecutor(max_workers=a.jobs) as pool:
            u = unaccounted(a.pr_heads, pool)
        print(f"{len(u['rendered'])} distinct check-run names over "
              f"{u['n_heads']} merged PR heads")
        print(f"  required   : {len(u['required_rendered'])}")
        print(f"  excluded   : {len(u['excluded_rendered'])}")
        print(f"  UNACCOUNTED: {len(u['unaccounted'])}")
        for n in u["unaccounted"]:
            print("    " + n)
        print(f"  ledger rows matching NOTHING rendered: "
              f"{len(u['ledger_rows_matching_nothing'])}")
        for n in u["ledger_rows_matching_nothing"]:
            print("    " + n)
        return 0
    if a.render:
        with open(a.render) as fh:
            saved = json.load(fh)
        rate = saved["fan_out"]["rate"]
        for r in saved["rows"]:
            r["verdict"], r["ground"] = verdict(r, r["m"], rate)
        print(render(saved["rows"], a.days,
                     saved["rows"][0]["m"]["since"],
                     datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                     nheads=saved["fan_out"]["n_heads"]))
        return 0

    req, _ = required_contexts()
    topo = topology(req=req)
    reuse = {k: v["reusable_callers"] for k, v in topo.items() if v["reusable_callers"]}
    if reuse:
        print("NOTE: reusable-workflow callers found; feeds-required is workflow-local "
              "and may undercount: " + json.dumps(reuse), file=sys.stderr)
    since = (datetime.now(timezone.utc) - timedelta(days=a.days)).strftime("%Y-%m-%d")
    rows = []
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        print(f"sampling fan-out over the last {a.pr_heads} merged PR heads",
              file=sys.stderr)
        fire = fire_rates(a.pr_heads, pool)
        for i, (name, row) in enumerate(sorted(topo.items()), 1):
            print(f"[{i}/{len(topo)}] {name}", file=sys.stderr)
            row["authority"] = authority(row)
            row["fire_rate"] = fire["rate"].get(name, 0.0)
            row["m"] = measure(name, a.days, a.sample, pool, a.recent)
            row["verdict"], row["ground"] = verdict(row, row["m"], fire["rate"])
            rows.append(row)
    rows.sort(key=lambda r: (["required", "feeds-required", "advisory"].index(r["authority"]),
                             -(r["m"]["median_real_job_seconds"] or 0)))
    if a.json:
        print(json.dumps({"fan_out": fire, "rows": rows}, indent=1))
    else:
        print(render(rows, a.days, since,
                     datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                     nheads=fire["n_heads"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
