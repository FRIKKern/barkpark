#!/usr/bin/env python3
"""dispatch-filter-census.py — the POPULATION behind dispatch-filter-staleness-check.sh.

Criterion 0 of task-9419f71d6aafe299: every PR merged in the last N days whose
head commit predates the newest change to a workflow file matching its diff
paths. Driven ONLY through `bash scripts/dispatch-filter-staleness-check.sh
--census [--days N]`; this file is the reader and is not a standalone entry point.

THE PREDICATE, stated once so the number is readable:

    OLD(pr)  the on.pull_request.paths of every workflow on main as of the LAST
             main commit at or before the PR head's committedDate — the filters
             GitHub's dispatcher actually had when that head's event fired.
    NEW(pr)  the same map as of the last main commit at or before mergedAt — the
             filters that govern the merge.
    FLAGGED  some changed path of the PR is selected by NEW and not by OLD.

WHY main's timeline and not `git show <head>:`: a PR head object is often gone
from the clone after a squash merge, and fetching a thousand of them is not a
census, it is a download. main's own history carries every filter state, dated.
The two differ only for a PR that edits a workflow filter ITSELF, and such a PR
is by construction not a victim of its own widening.

LOUDNESS. Anything this reader could not see is counted and printed as its own
class — NO_HEAD_DATE, FILES_TRUNCATED, NO_MAIN_AT_HEAD — and a run with zero
readable PRs exits 2. A zero finding always prints the denominator beside it.
"""
import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("CENSUS_REPO", "FRIKKern/barkpark")
DAYS = int(os.environ.get("CENSUS_DAYS", "30"))
TIP = os.environ.get("CENSUS_TIP", "origin/main")
ROOT = os.environ.get("CENSUS_ROOT", ".")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _rx(pat):
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i:i + 2] == "**":
                out.append(".*"); i += 2; continue
            out.append("[^/]*"); i += 1; continue
        if c == "?":
            out.append("[^/]"); i += 1; continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")


def matches(path, patterns):
    verdict = None
    for p in patterns:
        neg = p.startswith("!")
        body = p[1:] if neg else p
        if _rx(body).match(path):
            verdict = not neg
    if verdict is None:
        return any(p.startswith("!") for p in patterns)
    return verdict


def pr_paths(text):
    import yaml
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        return None
    on = doc.get("on", doc.get(True))   # PyYAML folds a bare `on:` to True
    if on is None:
        return None
    if isinstance(on, str):
        return [] if on == "pull_request" else None
    if isinstance(on, list):
        return [] if "pull_request" in on else None
    if not isinstance(on, dict) or "pull_request" not in on:
        return None
    pr = on.get("pull_request")
    if not isinstance(pr, dict):
        return []
    paths = pr.get("paths")
    return [] if paths is None else [str(p) for p in paths]


# EVERY git call in this file runs under TZ=UTC, and every date it asks for is
# `--date=format-local:...Z`. MEASURED THE HARD WAY 2026-09-13: the first cut of
# this census used `%cI`, which renders the COMMITTER's offset (+02:00 on this
# machine). The timeline was then string-compared against GitHub's `Z`
# timestamps, so "2026-09-12T12:54:49+02:00" <= "2026-09-12T12:26:55Z" is FALSE
# on characters while being TRUE in time. Every widening landed after its own
# merge, nothing could ever be flagged, and the census returned a clean-looking
# 1 finding over 3036 PRs — missing the one specimen the task was filed about.
GIT_ENV = dict(os.environ, TZ="UTC")
UTC_FMT = "--date=format-local:%Y-%m-%dT%H:%M:%SZ"


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args),
                          capture_output=True, text=True, env=GIT_ENV)


def die(msg):
    print("CANNOT READ: " + msg, file=sys.stderr)
    sys.exit(2)


def main():
    since = subprocess.run(
        ["python3", "-c",
         "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)"
         "-datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%d'))", str(DAYS)],
        capture_output=True, text=True).stdout.strip()
    if not since:
        die("could not compute the census window")

    # ── 1. main's filter timeline. One parse of the world, then deltas. ──────
    log = git("log", "--reverse", UTC_FMT, "--format=%H\t%cd", TIP,
              "--since=" + since, "--", ".github/workflows")
    if log.returncode != 0:
        die("git log over .github/workflows failed: " + log.stderr.strip())
    tl_commits = [l.split("\t") for l in log.stdout.splitlines() if "\t" in l]
    if not tl_commits:
        die("ZERO commits touched .github/workflows in the window — the timeline "
            "is empty, so no widening could ever be detected. That is not a clean run.")

    base = git("rev-list", "-1", "--before=" + since, TIP).stdout.strip()
    if not base:
        base = tl_commits[0][0] + "^"

    def filters_at(sha):
        ls = git("ls-tree", "-r", "--name-only", sha, "--", ".github/workflows")
        out = {}
        for f in ls.stdout.splitlines():
            if not f.endswith((".yml", ".yaml")):
                continue
            blob = git("show", sha + ":" + f)
            if blob.returncode != 0:
                continue
            try:
                p = pr_paths(blob.stdout)
            except Exception:
                p = None
            if p:
                out[os.path.basename(f)] = p
        return out

    state = filters_at(base)
    if not state:
        die("ZERO path-filtered workflows at the window's base commit (%s). The "
            "parser saw nothing — check the PyYAML bare-`on:`-is-True trap." % base[:9])
    timeline = [(git("log", "-1", UTC_FMT, "--format=%cd", base).stdout.strip(), dict(state))]
    for sha, ts in tl_commits:
        changed = git("show", "--name-only", "--format=", sha, "--",
                      ".github/workflows").stdout.splitlines()
        for f in changed:
            if not f.endswith((".yml", ".yaml")):
                continue
            name = os.path.basename(f)
            blob = git("show", sha + ":" + f)
            if blob.returncode != 0:
                state.pop(name, None)
                continue
            try:
                p = pr_paths(blob.stdout)
            except Exception:
                p = None
            if p:
                state[name] = p
            else:
                state.pop(name, None)
        timeline.append((ts, dict(state)))

    bad = [ts for ts, _ in timeline if not (ts or "").endswith("Z")]
    if bad:
        die("the main filter timeline carries %d NON-UTC timestamps (e.g. %s). "
            "GitHub's PR timestamps are UTC `Z`; a string comparison across two "
            "offsets silently answers FALSE for every widening and this census "
            "would report a clean window it never measured." % (len(bad), bad[0]))

    def state_at(iso):
        chosen = timeline[0][1]
        for ts, st in timeline:
            if ts and ts <= iso:
                chosen = st
            else:
                break
        return chosen

    # ── 2. the merged PRs, with head date and changed files, in one query. ──
    q = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 50, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes { ... on PullRequest {
          number mergedAt
          commits(last: 1) { nodes { commit { oid committedDate } } }
          files(first: 100) { totalCount nodes { path } }
        } }
      }
    }"""
    # GitHub's search API returns AT MOST 1000 results per query, and says so
    # nowhere in the payload — a 30-day window holding 3036 merged PRs came back
    # as a tidy 1000 and the known specimen (#17933) was simply not in it. So the
    # window is SHARDED ONE DAY AT A TIME, and any shard whose issueCount reaches
    # the cap is a loud refusal rather than a quiet undercount.
    import datetime
    start = datetime.date.fromisoformat(since)
    today = datetime.datetime.now(datetime.timezone.utc).date()
    days = []
    d = start
    while d <= today:
        days.append(d.isoformat())
        d += datetime.timedelta(days=1)

    prs, seen, shard_counts = [], set(), []
    for day in days:
        search = "repo:%s is:pr is:merged merged:%s" % (REPO, day)
        after, count = None, None
        while True:
            cmd = ["gh", "api", "graphql", "-f", "query=" + q, "-F", "q=" + search]
            if after:
                cmd += ["-F", "after=" + after]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                die("gh api graphql failed for shard %s: %s" % (day, r.stderr.strip()[:300]))
            d2 = json.loads(r.stdout)["data"]["search"]
            if count is None:
                count = d2["issueCount"]
                if count >= 1000:
                    die("shard %s reports %d merged PRs — at or over GitHub search's "
                        "1000-result cap. This census would UNDERCOUNT silently. "
                        "Shard finer than one day before trusting any number."
                        % (day, count))
            for node in d2["nodes"]:
                if node.get("number") not in seen:
                    seen.add(node.get("number"))
                    prs.append(node)
            if not d2["pageInfo"]["hasNextPage"]:
                break
            after = d2["pageInfo"]["endCursor"]
        shard_counts.append((day, count))

    total_claimed = sum(c for _, c in shard_counts)
    if len(prs) != total_claimed:
        print("# WARNING: shards claimed %d PRs, %d distinct nodes were read"
              % (total_claimed, len(prs)), file=sys.stderr)

    if not prs:
        die("the census window holds ZERO merged PRs — it measured nothing")

    flagged, unreadable, truncated, clean = [], [], 0, 0
    for pr in prs:
        n = pr.get("number")
        merged_at = pr.get("mergedAt")
        cn = (pr.get("commits") or {}).get("nodes") or []
        if not cn or not merged_at:
            unreadable.append((n, "NO_HEAD_DATE"))
            continue
        head_oid = cn[0]["commit"]["oid"]
        head_date = cn[0]["commit"]["committedDate"]
        files = [f["path"] for f in (pr.get("files") or {}).get("nodes", [])]
        total = (pr.get("files") or {}).get("totalCount", len(files))
        if total > len(files):
            truncated += 1
        if not files:
            unreadable.append((n, "NO_FILES"))
            continue
        old = state_at(head_date)
        new = state_at(merged_at)
        hits = []
        for wf, newp in new.items():
            oldp = old.get(wf)
            for p in files:
                if matches(p, newp) and not (oldp and matches(p, oldp)):
                    hits.append((wf, p, "absent at head" if oldp is None else "filter widened"))
        if hits:
            flagged.append((n, head_oid, head_date, merged_at, hits))
        else:
            clean += 1

    print("# COMMAND: bash scripts/dispatch-filter-staleness-check.sh --census --days %d" % DAYS)
    print("# window: merged:>=%s  repo=%s  tip=%s" % (since, REPO, TIP))
    print("# main filter timeline: %d states from %d workflow-touching commits" %
          (len(timeline), len(tl_commits)))
    print("# merged PRs read: %d across %d daily shards (shards claimed %d)"
          % (len(prs), len(shard_counts), total_claimed))
    for n, oid, hd, md, hits in sorted(flagged):
        print("FLAGGED #%d head=%s pushed=%s merged=%s" % (n, oid[:9], hd, md))
        for wf, p, why in sorted(set(hits)):
            print("    %s (%s) newly matches %s" % (wf, why, p))
    for n, why in unreadable:
        print("UNREADABLE #%s %s" % (n, why))
    print("# POPULATION: %d flagged / %d read (%d clean, %d unreadable, %d with >100 files "
          "whose file list was truncated by the API)" %
          (len(flagged), len(prs), clean, len(unreadable), truncated))
    return 0


if __name__ == "__main__":
    sys.exit(main())
