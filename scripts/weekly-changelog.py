#!/usr/bin/env python3
"""Render one completed ISO week's user-facing changes from main's first parent."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from dataclasses import dataclass


CONVENTIONAL = re.compile(
    r"^(?P<kind>feat|fix|perf|revert|docs|test|ci|build|chore|refactor)"
    r"(?:\((?P<scope>[^)]+)\))?(?:!)?:\s*(?P<title>.+)$",
    re.IGNORECASE,
)
PR_SUFFIX = re.compile(r"\s*\(#(?P<number>[0-9]+)\)$")
USER_FACING = {
    "feat": "Added",
    "fix": "Fixed",
    "perf": "Performance",
    "revert": "Reverted",
}


@dataclass(frozen=True)
class Change:
    timestamp: int
    sha: str
    subject: str


def parse_week(value: str) -> dt.date:
    try:
        week = dt.date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("week must be YYYY-MM-DD") from exc
    if week.weekday() != 0:
        raise argparse.ArgumentTypeError("week must be an ISO-week Monday")
    return week


def epoch(day: dt.date) -> int:
    return int(dt.datetime.combine(day, dt.time(), dt.timezone.utc).timestamp())


def first_parent(ref: str) -> list[Change]:
    raw = subprocess.run(
        ["git", "log", "--first-parent", "-z", "--format=%ct%x1f%H%x1f%s", ref],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    changes: list[Change] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        timestamp, sha, subject = record.decode("utf-8", errors="replace").split("\x1f", 2)
        changes.append(Change(int(timestamp), sha, subject))
    return changes


def week_changes(ref: str, week: dt.date) -> tuple[list[Change], str | None, str | None]:
    start = epoch(week)
    end = epoch(week + dt.timedelta(days=7))
    history = first_parent(ref)
    selected = [change for change in history if start <= change.timestamp < end]
    head = next((change.sha for change in history if change.timestamp < end), None)
    base = next((change.sha for change in history if change.timestamp < start), None)
    return list(reversed(selected)), base, head


def bullet(change: Change, repo: str) -> str:
    match = CONVENTIONAL.match(change.subject)
    title = match.group("title") if match else change.subject
    scope = match.group("scope") if match else None
    pr = PR_SUFFIX.search(title)
    if pr:
        title = PR_SUFFIX.sub("", title)
        number = pr.group("number")
        link = f"[#{number}](https://github.com/{repo}/pull/{number})"
    else:
        link = f"[`{change.sha[:10]}`](https://github.com/{repo}/commit/{change.sha})"
    prefix = f"**{scope}:** " if scope else ""
    return f"- {prefix}{title} ({link})"


def render(ref: str, repo: str, week: dt.date) -> tuple[str, str]:
    changes, base, head = week_changes(ref, week)
    if not head:
        raise RuntimeError(f"no commit exists on {ref} before the end of {week.isoformat()}")

    end = week + dt.timedelta(days=6)
    lines = [
        f"# Week of {week.isoformat()}",
        "",
        f"Changes merged to `main` from {week.isoformat()} through {end.isoformat()} (UTC).",
        "",
    ]
    if base:
        lines.append(f"[Compare the week](https://github.com/{repo}/compare/{base}...{head})")
        lines.append("")

    grouped: dict[str, list[Change]] = {heading: [] for heading in USER_FACING.values()}
    maintenance = 0
    for change in changes:
        match = CONVENTIONAL.match(change.subject)
        kind = match.group("kind").lower() if match else "other"
        heading = USER_FACING.get(kind)
        if heading:
            grouped[heading].append(change)
        else:
            maintenance += 1

    visible = sum(len(items) for items in grouped.values())
    if visible == 0:
        lines.extend(["No user-facing changes landed this week.", ""])
    else:
        for heading, items in grouped.items():
            if not items:
                continue
            lines.extend([f"## {heading}", ""])
            lines.extend(bullet(change, repo) for change in items)
            lines.append("")

    if maintenance:
        noun = "change" if maintenance == 1 else "changes"
        lines.extend(
            [
                "## Internal work",
                "",
                f"{maintenance} documentation, test, CI, refactor, build, or maintenance {noun} also merged.",
                "",
            ]
        )
    lines.append(
        "Package-specific release notes remain in each package's `CHANGELOG.md`."
    )
    return "\n".join(lines) + "\n", head


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--week", required=True, type=parse_week, help="ISO-week Monday")
    parser.add_argument("--ref", default="origin/main", help="git ref to read")
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "FRIKKern/barkpark"),
        help="GitHub owner/repository used for links",
    )
    parser.add_argument("--head-only", action="store_true", help="print the week's final SHA")
    args = parser.parse_args()
    try:
        notes, head = render(args.ref, args.repo, args.week)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"weekly-changelog: {exc}", file=sys.stderr)
        return 1
    print(head if args.head_only else notes, end="\n" if args.head_only else "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
