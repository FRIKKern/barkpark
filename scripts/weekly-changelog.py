#!/usr/bin/env python3
"""Render one editorial Barkpark Weekly edition from main's first parent."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
EDITORIAL_PATH = ROOT / "changelog" / "editorial.json"
JOURNAL_EPOCH = dt.date(2026, 4, 6)
CONVENTIONAL = re.compile(
    r"^(?P<kind>feat|fix|perf|revert|docs|test|ci|build|chore|refactor|style)"
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

    @property
    def match(self) -> re.Match[str] | None:
        return CONVENTIONAL.match(self.subject)

    @property
    def kind(self) -> str:
        match = self.match
        return match.group("kind").lower() if match else "other"

    @property
    def scope(self) -> str | None:
        match = self.match
        return match.group("scope") if match else None

    @property
    def title(self) -> str:
        match = self.match
        value = match.group("title") if match else self.subject
        return PR_SUFFIX.sub("", value)

    @property
    def pr_number(self) -> str | None:
        match = PR_SUFFIX.search(self.subject)
        return match.group("number") if match else None


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


def load_editorial() -> dict[str, dict[str, Any]]:
    with EDITORIAL_PATH.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise RuntimeError("editorial catalog must be a JSON object")
    return value


def change_link(change: Change, repo: str) -> str:
    if change.pr_number:
        return f"https://github.com/{repo}/pull/{change.pr_number}"
    return f"https://github.com/{repo}/commit/{change.sha}"


def linked_title(change: Change, repo: str) -> str:
    return f"[{change.title}]({change_link(change, repo)})"


def bullet(change: Change, repo: str) -> str:
    prefix = f"**{change.scope}:** " if change.scope else ""
    return f"- {prefix}{linked_title(change, repo)}"


def human_range(week: dt.date) -> str:
    end = week + dt.timedelta(days=6)
    if week.year == end.year and week.month == end.month:
        return f"{week.day}–{end.day} {week.strftime('%B %Y')}"
    if week.year == end.year:
        return f"{week.strftime('%-d %B')}–{end.strftime('%-d %B %Y')}"
    return f"{week.strftime('%-d %B %Y')}–{end.strftime('%-d %B %Y')}"


def fallback_editorial(week: dt.date, changes: list[Change]) -> dict[str, Any]:
    edition = ((week - JOURNAL_EPOCH).days // 7) + 1
    visible = [change for change in changes if change.kind in USER_FACING]
    scopes = collections.Counter(change.scope for change in visible if change.scope)
    leaders = [scope for scope, _ in scopes.most_common(3)]
    if len(leaders) > 1:
        subject = ", ".join(leaders[:-1]) + f" & {leaders[-1]}"
    elif leaders:
        subject = leaders[0]
    else:
        subject = "Barkpark"
    featured = visible[:3]
    featured_shas = {change.sha for change in featured}
    for change in changes:
        if len(featured) == 3:
            break
        if change.sha not in featured_shas:
            featured.append(change)
            featured_shas.add(change.sha)
    if not featured:
        return {
            "edition": edition,
            "kicker": "Quiet week",
            "title": "A pause on main",
            "dek": "No mainline changes landed during this completed ISO week.",
            "opener": "Barkpark's release ledger was quiet this week. The edition remains in the journal so the weekly record stays continuous and explicit.",
            "highlights": [],
            "closing": "A quiet ledger is still a useful fact: no release activity has been inferred or backfilled where none occurred.",
        }
    return {
        "edition": edition,
        "kicker": "Weekly edition",
        "title": f"{subject} moved forward",
        "dek": "The week's most useful additions, repairs, and operational improvements—curated from Barkpark's mainline history.",
        "opener": "This edition follows the changes that most directly altered how Barkpark is used, read, operated, or extended. The release pulse and compare trail preserve the complete record behind the highlights.",
        "highlights": [
            {
                "title": change.title,
                "summary": f"A notable {USER_FACING.get(change.kind, 'mainline').lower()} change in {change.scope or 'the platform'}.",
                "changes": [change.sha[:10]],
            }
            for change in featured
        ],
        "closing": "Every weekly edition is a map, not a substitute for the terrain; the compare trail below remains the authoritative release ledger.",
    }


def resolve_highlights(
    editorial: dict[str, Any], changes: list[Change], week: dt.date
) -> tuple[list[dict[str, Any]], set[str]]:
    resolved: list[dict[str, Any]] = []
    featured: set[str] = set()
    for highlight in editorial.get("highlights", []):
        selected: list[Change] = []
        for prefix in highlight.get("changes", []):
            matches = [change for change in changes if change.sha.startswith(prefix)]
            if len(matches) != 1:
                raise RuntimeError(
                    f"editorial {week.isoformat()} change {prefix!r} matched {len(matches)} commits"
                )
            selected.append(matches[0])
            featured.add(matches[0].sha)
        resolved.append({**highlight, "resolved_changes": selected})
    return resolved, featured


def issue_title(week: dt.date, editorial: dict[str, Any]) -> str:
    edition = editorial.get("edition")
    prefix = f"Barkpark Weekly {int(edition):02d}" if edition is not None else "Barkpark Weekly"
    return f"{prefix} · {editorial['title']} · {week.isoformat()}"


def render(ref: str, repo: str, week: dt.date) -> str:
    changes, base, head = week_changes(ref, week)
    if not head:
        raise RuntimeError(f"no commit exists on {ref} before the end of {week.isoformat()}")

    catalog = load_editorial()
    editorial = catalog.get(week.isoformat()) or fallback_editorial(week, changes)
    highlights, featured = resolve_highlights(editorial, changes, week)
    compare_url = (
        f"https://github.com/{repo}/compare/{base}...{head}"
        if base
        else f"https://github.com/{repo}/commits/{head}"
    )

    visible = [change for change in changes if change.kind in USER_FACING]
    internal_count = len(changes) - len(visible)
    scopes = collections.Counter(change.scope for change in visible if change.scope)
    leading_areas = " · ".join(scope for scope, _ in scopes.most_common(4)) or "foundation"
    edition = editorial.get("edition")
    edition_label = f"{int(edition):02d}" if edition is not None else week.isoformat()
    visible_noun = "commit" if len(visible) == 1 else "commits"

    lines = [
        f"# Barkpark Weekly {edition_label}",
        "",
        f"**{human_range(week)}** · {editorial['kicker']}",
        "",
        f"## {editorial['title']}",
        "",
        f"> {editorial['dek']}",
        "",
        editorial["opener"],
        "",
        (
            f"**Release pulse:** {len(changes):,} mainline changes · "
            f"{len(visible):,} feature/fix/performance/revert {visible_noun} · "
            f"{internal_count:,} foundation and maintenance changes · **Leading areas:** {leading_areas}"
        ),
        "",
        f"[Explore the complete week →]({compare_url})",
        "",
        "---",
        "",
        "## Three things worth knowing" if len(highlights) == 3 else "## What mattered this week",
        "",
    ]

    for index, highlight in enumerate(highlights, 1):
        lines.extend(
            [
                f"### {index:02d} / {highlight['title']}",
                "",
                highlight["summary"],
                "",
            ]
        )
        selected = highlight["resolved_changes"]
        if selected:
            lines.extend(bullet(change, repo) for change in selected)
            lines.append("")

    remainder = [change for change in visible if change.sha not in featured]
    if remainder:
        lines.extend(["## Elsewhere in Barkpark", ""])
        shown = 0
        for kind, heading in USER_FACING.items():
            items = [change for change in remainder if change.kind == kind][:4]
            if not items:
                continue
            lines.extend([f"**{heading}**", ""])
            lines.extend(bullet(change, repo) for change in items)
            lines.append("")
            shown += len(items)
        omitted = len(remainder) - shown
        if omitted > 0:
            noun = "change" if omitted == 1 else "changes"
            lines.extend(
                [
                    f"{omitted:,} more product-facing {noun} are preserved in the "
                    f"[complete compare trail]({compare_url}).",
                    "",
                ]
            )

    lines.extend(
        [
            "## The week in perspective",
            "",
            editorial["closing"],
            "",
            "---",
            "",
            f"**The ledger:** [Every mainline change from {human_range(week)}]({compare_url})",
            "",
            "Package-specific release notes remain beside each package in `js/packages/*/CHANGELOG.md`.",
        ]
    )
    return "\n".join(lines) + "\n"


def validate_editorial(ref: str) -> list[str]:
    catalog = load_editorial()
    errors: list[str] = []
    weeks = [parse_week(value) for value in sorted(catalog)]
    if weeks:
        expected = []
        cursor = weeks[0]
        while cursor <= weeks[-1]:
            expected.append(cursor)
            cursor += dt.timedelta(days=7)
        missing = sorted(set(expected) - set(weeks))
        if missing:
            errors.append("missing editorial weeks: " + ", ".join(map(str, missing)))

    for index, week in enumerate(weeks, 1):
        editorial = catalog[week.isoformat()]
        if editorial.get("edition") != index:
            errors.append(
                f"{week}: edition must be {index}, got {editorial.get('edition')!r}"
            )
        for field in ("kicker", "title", "dek", "opener", "closing"):
            if not isinstance(editorial.get(field), str) or not editorial[field].strip():
                errors.append(f"{week}: missing non-empty {field}")
        for field, minimum in (("dek", 70), ("opener", 180), ("closing", 100)):
            value = editorial.get(field, "")
            if isinstance(value, str) and len(value) < minimum:
                errors.append(f"{week}: {field} is too thin ({len(value)} < {minimum} chars)")
        if len(editorial.get("highlights", [])) != 3:
            errors.append(f"{week}: exactly three highlights are required")
        prefixes: list[str] = []
        for highlight_index, highlight in enumerate(editorial.get("highlights", []), 1):
            if not isinstance(highlight.get("title"), str) or not highlight["title"].strip():
                errors.append(f"{week}: highlight {highlight_index} needs a title")
            summary = highlight.get("summary", "")
            if not isinstance(summary, str) or len(summary) < 80:
                errors.append(f"{week}: highlight {highlight_index} summary is too thin")
            change_prefixes = highlight.get("changes", [])
            if not isinstance(change_prefixes, list) or not 1 <= len(change_prefixes) <= 3:
                errors.append(f"{week}: highlight {highlight_index} needs 1–3 changes")
            prefixes.extend(change_prefixes)
        if len(prefixes) != len(set(prefixes)):
            errors.append(f"{week}: a featured change appears more than once")
        changes, _, _ = week_changes(ref, week)
        try:
            resolve_highlights(editorial, changes, week)
        except RuntimeError as exc:
            errors.append(str(exc))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--week", type=parse_week, help="ISO-week Monday")
    parser.add_argument("--ref", default="origin/main", help="git ref to read")
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "FRIKKern/barkpark"),
        help="GitHub owner/repository used for links",
    )
    parser.add_argument("--title-only", action="store_true", help="print the issue title")
    parser.add_argument(
        "--list-editorial-weeks", action="store_true", help="print curated week starts"
    )
    parser.add_argument(
        "--validate-editorial", action="store_true", help="validate the curated catalog"
    )
    args = parser.parse_args()

    try:
        if args.list_editorial_weeks:
            print("\n".join(sorted(load_editorial())))
            return 0
        if args.validate_editorial:
            errors = validate_editorial(args.ref)
            if errors:
                for error in errors:
                    print(f"weekly-changelog: {error}", file=sys.stderr)
                return 1
            print(f"Validated {len(load_editorial())} editorial weeks.")
            return 0
        if args.week is None:
            parser.error("--week is required unless listing or validating editorial")
        changes, _, _ = week_changes(args.ref, args.week)
        editorial = load_editorial().get(args.week.isoformat()) or fallback_editorial(
            args.week, changes
        )
        if args.title_only:
            print(issue_title(args.week, editorial))
        else:
            print(render(args.ref, args.repo, args.week), end="")
    except (RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"weekly-changelog: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
