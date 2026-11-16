#!/usr/bin/env python3
"""Render a repo's README News block from its own day pages.

    render.py <repo-dir> --repo OWNER/NAME [--today YYYY-MM-DD] [--days N] [--check] [--links]

A day page is docs/news/YYYY-MM-DD.md carrying one line
    <!-- news-day: {"summary": "...", "groups": [{"label": "...", "text": "...", "prs": [1, 2]}]} -->
(after the doc-tier header where a repo requires one). The README block between
<!-- news:start --> and <!-- news:end --> shows the newest --days FINISHED days that had
merges: dated before --today (default: today) and with at least one group. It never shows
"today so far", so it is never wrong by midday.

--check   write nothing; exit 1 if the README would change.
--links   also check that every local Markdown link in README.md and docs/news/*.md resolves.
Exit 2 on a malformed day page or a README without exactly one marker pair.
"""
import argparse
import datetime
import json
import os
import re
import sys

START, END = "<!-- news:start -->", "<!-- news:end -->"
DAY_FILE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.md$")
META = re.compile(r"^<!-- news-day: (\{.*\}) -->$", re.M)
LINK = re.compile(r"\]\(([^)\s]+)\)")


class Bad(Exception):
    pass


def read_meta(path):
    """The day's metadata, or None when the page has no news-day line."""
    m = META.search(open(path, encoding="utf-8").read())
    if not m:
        return None
    try:
        meta = json.loads(m.group(1))
    except ValueError as e:
        raise Bad(f"{path}: news-day line is not JSON ({e})")
    if not isinstance(meta.get("summary"), str) or not meta["summary"].strip():
        raise Bad(f"{path}: news-day needs a non-empty summary")
    groups = meta.get("groups", [])
    if not isinstance(groups, list) or len(groups) > 3:
        raise Bad(f"{path}: news-day groups must be a list of at most 3")
    for g in groups:
        if not (isinstance(g, dict) and g.get("label") and g.get("text") and g.get("prs")
                and all(isinstance(n, int) for n in g["prs"])):
            raise Bad(f"{path}: each group needs label, text and integer prs")
    return meta


def finished_days(news_dir, today, n_days):
    """[(date, meta, has_page)] newest first: dated before today, with at least one group."""
    days = []
    if os.path.isdir(news_dir):
        for name in sorted(os.listdir(news_dir), reverse=True):
            m = DAY_FILE.match(name)
            if not m or m.group(1) >= today:
                continue
            meta = read_meta(os.path.join(news_dir, name))
            if meta and meta.get("groups"):
                days.append((m.group(1), meta))
            if len(days) == n_days:
                break
    return days


def day_label(d):
    dt = datetime.date.fromisoformat(d)
    return f"{dt:%A} {dt.day} {dt:%B}"


def render_block(owner, repo, days):
    rows = []
    for d, meta in days:
        rows.append(f"**{day_label(d)}.** {meta['summary']} [The full day](docs/news/{d}.md)")
        for g in meta["groups"]:
            links = ", ".join(f"[#{n}](https://github.com/{owner}/{repo}/pull/{n})" for n in g["prs"])
            rows.append(f"- **{g['label']}:** {g['text']} ({links})")
        rows.append("")
    return "\n".join(rows).rstrip()


def apply(readme, block):
    if readme.count(START) != 1 or readme.count(END) != 1 or readme.index(START) > readme.index(END):
        raise Bad(f"README needs exactly one {START} ... {END} pair")
    head, rest = readme.split(START, 1)
    _, tail = rest.split(END, 1)
    return head + START + "\n" + block + ("\n" if block else "") + END + tail


def broken_links(repo_dir):
    files = ["README.md"]
    news = os.path.join(repo_dir, "docs/news")
    if os.path.isdir(news):
        files += [os.path.join("docs/news", f) for f in sorted(os.listdir(news)) if f.endswith(".md")]
    bad = []
    for f in files:
        for target in LINK.findall(open(os.path.join(repo_dir, f), encoding="utf-8").read()):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith("#"):
                continue
            path = os.path.normpath(os.path.join(repo_dir, os.path.dirname(f), target.split("#")[0]))
            if not os.path.exists(path):
                bad.append(f"{f}: {target}")
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("repo_dir")
    ap.add_argument("--repo", required=True, help="OWNER/NAME, for pull request links")
    ap.add_argument("--today", default=datetime.date.today().isoformat())
    ap.add_argument("--days", type=int, default=2)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--links", action="store_true")
    a = ap.parse_args(argv)
    owner, repo = a.repo.split("/", 1)
    readme_path = os.path.join(a.repo_dir, "README.md")
    try:
        days = finished_days(os.path.join(a.repo_dir, "docs/news"), a.today, a.days)
        readme = open(readme_path, encoding="utf-8").read()
        new = apply(readme, render_block(owner, repo, days))
    except Bad as e:
        print(f"render: {e}", file=sys.stderr)
        return 2
    shown = ", ".join(d for d, _ in days) or "none"
    if a.links:
        bad = broken_links(a.repo_dir)
        for b in bad:
            print(f"render: broken link {b}", file=sys.stderr)
        if bad:
            return 2
    if new == readme:
        print(f"render: {repo} README unchanged (days shown: {shown})")
        return 0
    if a.check:
        print(f"render: {repo} README would change (days shown: {shown})")
        return 1
    with open(readme_path, "w", encoding="utf-8") as fh:
        fh.write(new)
    print(f"render: {repo} README written (days shown: {shown})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
