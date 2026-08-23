#!/usr/bin/env python3
"""Build Barkpark Chronicle day/week/month/year/index Paper payloads from Git."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable


RENDERER_VERSION = "chronicle-mvp-2"
LEDGER_PREVIEW_LIMIT = 24
DEFAULT_REPO = "FRIKKern/barkpark"
CONVENTIONAL = re.compile(
    r"^(?P<kind>feat|fix|perf|revert|docs|test|ci|build|chore|refactor|style)"
    r"(?:\((?P<scope>[^)]+)\))?(?:!)?:\s*(?P<title>.+)$",
    re.IGNORECASE,
)
PR_SUFFIX = re.compile(r"\s*\(#(?P<number>[0-9]+)\)$")
PRODUCT_KINDS = {"feat", "fix", "perf", "revert"}


@dataclass(frozen=True)
class Event:
    occurred_at: dt.datetime
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
    def area(self) -> str:
        match = self.match
        return (match.group("scope") if match else None) or "foundation"

    @property
    def title(self) -> str:
        match = self.match
        title = match.group("title") if match else self.subject
        return PR_SUFFIX.sub("", title)

    @property
    def pr_number(self) -> str | None:
        match = PR_SUFFIX.search(self.subject)
        return match.group("number") if match else None


@dataclass(frozen=True)
class Period:
    kind: str
    key: str
    start: dt.date
    end: dt.date
    slug: str
    title: str


def text(value: str, *, marks: list[str] | None = None) -> dict[str, Any]:
    node: dict[str, Any] = {"type": "text", "value": value}
    if marks:
        node["marks"] = marks
    return node


def paragraph(block_id: str, content: str | list[dict[str, Any]]) -> dict[str, Any]:
    nodes = [text(content)] if isinstance(content, str) else content
    return {"id": block_id, "type": "paragraph", "content": nodes}


def link(label: str, href: str) -> dict[str, Any]:
    return {"type": "link", "href": href, "children": [text(label)]}


def heading(block_id: str, level: int, value: str) -> dict[str, Any]:
    return {"id": block_id, "type": "heading", "level": level, "text": value}


def read_events(ref: str) -> list[Event]:
    raw = subprocess.run(
        ["git", "log", "--first-parent", "-z", "--format=%cI%x1f%H%x1f%s", ref],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    events: list[Event] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        stamp, sha, subject = record.decode("utf-8", errors="replace").split("\x1f", 2)
        occurred_at = dt.datetime.fromisoformat(stamp).astimezone(dt.timezone.utc)
        events.append(Event(occurred_at, sha, subject))
    return list(reversed(events))


def month_end(day: dt.date) -> dt.date:
    if day.month == 12:
        return dt.date(day.year + 1, 1, 1)
    return dt.date(day.year, day.month + 1, 1)


def periods_for(day: dt.date) -> dict[str, Period]:
    monday = day - dt.timedelta(days=day.weekday())
    iso_year, iso_week, _ = day.isocalendar()
    month_start = day.replace(day=1)
    return {
        "day": Period(
            "day",
            day.isoformat(),
            day,
            day + dt.timedelta(days=1),
            f"barkpark-changelog-{day.isoformat()}",
            day.strftime("%d %B %Y").lstrip("0"),
        ),
        "week": Period(
            "week",
            f"{iso_year}-W{iso_week:02d}",
            monday,
            monday + dt.timedelta(days=7),
            f"barkpark-changelog-{iso_year}-w{iso_week:02d}",
            f"Week {iso_week}, {iso_year}",
        ),
        "month": Period(
            "month",
            f"{day.year}-{day.month:02d}",
            month_start,
            month_end(month_start),
            f"barkpark-changelog-{day.year}-{day.month:02d}",
            day.strftime("%B %Y"),
        ),
        "year": Period(
            "year",
            str(day.year),
            dt.date(day.year, 1, 1),
            dt.date(day.year + 1, 1, 1),
            f"barkpark-changelog-{day.year}",
            str(day.year),
        ),
    }


def events_in_period(events: Iterable[Event], period: Period) -> list[Event]:
    return [event for event in events if period.start <= event.occurred_at.date() < period.end]


def event_url(event: Event, repo: str) -> str:
    if event.pr_number:
        return f"https://github.com/{repo}/pull/{event.pr_number}"
    return f"https://github.com/{repo}/commit/{event.sha}"


def digest(events: Iterable[Event]) -> str:
    material = "\n".join(event.sha for event in events)
    return hashlib.sha256(f"{RENDERER_VERSION}\n{material}".encode()).hexdigest()[:16]


def signal(period: Period, selected: list[Event]) -> str:
    if not selected:
        return f"Quiet {period.kind}: no first-parent changes landed on main."
    product = sum(event.kind in PRODUCT_KINDS for event in selected)
    areas = collections.Counter(event.area for event in selected)
    lead = areas.most_common(1)[0][0]
    noun = "change" if len(selected) == 1 else "changes"
    return f"{len(selected):,} mainline {noun}, {product:,} product-facing; {lead} led the period."


def sentence_case(value: str) -> str:
    return value[:1].upper() + value[1:] if value else value


def percentage(part: int, whole: int) -> str:
    return f"{round(part * 100 / whole):d}%" if whole else "0%"


def change_profile(block_id: str, selected: list[Event], caption: str) -> dict[str, Any]:
    counts = collections.Counter(event.kind for event in selected)
    order = ("feat", "fix", "perf", "docs", "refactor", "test", "ci", "chore", "other")
    bars = [
        {"label": kind, "value": counts[kind]}
        for kind in order
        if counts[kind]
    ][:7]
    return {
        "id": block_id,
        "type": "bar-chart",
        "title": caption,
        "bars": bars or [{"label": "quiet", "value": 0}],
        "values": True,
    }


def area_cards(block_id: str, selected: list[Event], repo: str, limit: int = 3) -> dict[str, Any]:
    counts = collections.Counter(event.area for event in selected)
    items = []
    for area, count in counts.most_common(limit):
        latest = next(event for event in reversed(selected) if event.area == area)
        items.append(
            {
                "title": sentence_case(area),
                "text": f"{count:,} changes · latest: {latest.title}",
                "href": event_url(latest, repo),
            }
        )
    if not items:
        items.append({"title": "Quiet period", "text": "No mainline area recorded a change."})
    return {"id": block_id, "type": "cards", "items": items}


def event_lineage(block_id: str, selected: list[Event], repo: str, limit: int = 5) -> dict[str, Any]:
    nodes = [
        {
            "overline": event.occurred_at.strftime("%d %b · %H:%M UTC"),
            "title": event.title,
            "body": f"{event.area} · {event.kind}",
            "source": event_url(event, repo),
        }
        for event in reversed(selected[-limit:])
    ]
    if not nodes:
        nodes.append({"overline": "No mainline activity", "title": "A quiet interval", "body": "The verified ledger contains no changes for this period."})
    return {"id": block_id, "type": "lineage", "nodes": nodes}


def ledger_url(period: Period, repo: str) -> str:
    return (
        f"https://github.com/{repo}/commits/main"
        f"?since={period.start.isoformat()}T00%3A00%3A00Z"
        f"&until={period.end.isoformat()}T00%3A00%3A00Z"
    )


def navigation_blocks(periods: dict[str, Period], active: str) -> list[dict[str, Any]]:
    ordered = [periods[kind] for kind in ("year", "month", "week", "day")]
    nodes: list[dict[str, Any]] = [link("Chronicle", "/papers/barkpark-chronicle")]
    for period in ordered:
        nodes.append(text(" / "))
        label = period.key if period.kind != "day" else period.start.strftime("%d %b")
        nodes.append(text(label, marks=["strong"]) if period.kind == active else link(label, f"/papers/{period.slug}"))
    return [paragraph("auto:period-nav", nodes)]


def period_payload(period: Period, selected: list[Event], periods: dict[str, Period], repo: str) -> dict[str, Any]:
    product = [event for event in selected if event.kind in PRODUCT_KINDS]
    areas = collections.Counter(event.area for event in selected)
    public_titles = {
        "day": f"Daily shiplog report · {period.start.strftime('%A')}, {period.title}",
        "week": f"Week {period.key.split('-W')[-1]} dispatch · {period.start.strftime('%d %b')}–{(period.end - dt.timedelta(days=1)).strftime('%d %b %Y')}",
        "month": f"Monthly product change ledger · {period.title}",
        "year": f"Annual product record · {period.title}",
    }
    date_range = f"{period.start.strftime('%d %b')}–{(period.end - dt.timedelta(days=1)).strftime('%d %b %Y')}"
    profile = collections.Counter(event.kind for event in selected)
    dominant_kind = profile.most_common(1)[0][0] if profile else "quiet"
    blocks: list[dict[str, Any]] = navigation_blocks(periods, period.kind)
    blocks.extend(
        [
            {"id": "auto:identity", "type": "eyebrow", "text": f"BARKPARK CHRONICLE · {period.kind.upper()} · {period.key}"},
            heading("auto:title", 1, public_titles[period.kind]),
            {"id": "auto:ingress", "type": "ingress", "content": [text(signal(period, selected))]},
            {"id": "auto:byline", "type": "byline", "items": [date_range, "Verified mainline record", f"Edition {digest(selected)[:8]}" ]},
            {
                "id": "auto:release-pulse",
                "type": "stats",
                "items": [
                    {"value": str(len(selected)), "label": "mainline changes"},
                    {"value": percentage(len(product), len(selected)), "label": "product-facing share"},
                    {"value": str(len(areas)), "label": "areas touched"},
                    {"value": dominant_kind, "label": "dominant change kind"},
                ],
            },
            {"id": "auto:divider-shape", "type": "divider"},
            heading("auto:shape-title", 2, "The shape of the work"),
            paragraph("auto:shape-dek", "A derived view of how the period moved: change kinds first, then the product areas carrying the most mainline activity."),
            change_profile("auto:change-profile", selected, f"Change profile · {period.key}"),
            area_cards("auto:areas", selected, repo),
            {"id": "auto:divider-sequence", "type": "divider"},
            heading("auto:sequence-title", 2, "The sequence"),
            paragraph("auto:sequence-dek", "The five freshest mainline signals, read newest first."),
            event_lineage("auto:sequence", selected, repo),
            {"id": "auto:divider-ledger", "type": "divider"},
            heading("auto:ledger-title", 2, "Source ledger"),
        ]
    )
    if selected:
        items = []
        for event in reversed(selected[-LEDGER_PREVIEW_LIMIT:]):
            items.append(
                [
                    text(event.occurred_at.strftime("%d %b %H:%M UTC"), marks=["code"]),
                    text(" · "),
                    link(event.title, event_url(event, repo)),
                    text(f" · {event.area}"),
                ]
            )
        blocks.append({"id": "auto:ledger", "type": "list", "ordered": False, "items": items})
        omitted = len(selected) - len(items)
        label = f"Open the complete source ledger ({len(selected):,} changes)"
        suffix = f"; {omitted:,} earlier changes are omitted from this reading view." if omitted else "."
        blocks.append(paragraph("auto:ledger-source", [link(label, ledger_url(period, repo)), text(suffix)]))
    else:
        blocks.append(paragraph("auto:ledger", "No release activity was inferred or backfilled for this period."))
    blocks.extend(
        [
            {"id": "auto:divider-provenance", "type": "divider"},
            paragraph(
                "auto:provenance",
                f"Generated from first-parent Git history for {period.start.isoformat()} through {(period.end - dt.timedelta(days=1)).isoformat()} UTC · renderer {RENDERER_VERSION} · digest {digest(selected)}.",
            ),
        ]
    )
    return {
        "_id": period.slug,
        "slug": period.slug,
        "title": public_titles[period.kind],
        "description": f"The verified Barkpark {period.kind} record for {period.key}, projected from first-parent mainline history.",
        "style": "article",
        "event_type": f"changelog.{period.kind}",
        "source_doc": f"git:first-parent:{period.kind}:{period.key}:{digest(selected)}",
        "tags": [
            {"tag": "barkpark", "strength": 100, "rationale": "Canonical Barkpark product history."},
            {"tag": "docs", "strength": 85, "rationale": "A durable, source-linked project record."},
        ],
        "blocks": blocks,
    }


def index_payload(periods: dict[str, Period], events: list[Event], repo: str) -> dict[str, Any]:
    latest = events[-1] if events else None
    current_year = events_in_period(events, periods["year"])
    current_week = events_in_period(events, periods["week"])
    product = [event for event in current_year if event.kind in PRODUCT_KINDS]
    areas = collections.Counter(event.area for event in current_year)
    cards = []
    edition_names = {
        "day": "Today’s shiplog",
        "week": "The weekly dispatch",
        "month": "The August chapter",
        "year": "The 2026 annual volume",
    }
    for kind in ("day", "week", "month", "year"):
        period = periods[kind]
        count = len(events_in_period(events, period))
        cards.append(
            {
                "title": edition_names[kind],
                "text": f"{period.title} · {count:,} verified mainline changes",
                "href": f"/papers/{period.slug}",
            }
        )
    all_digest = digest(events)
    lead = f"Latest: {sentence_case(latest.title)}." if latest else "The journal opens quietly."
    monthly = collections.Counter(event.occurred_at.month for event in current_year)
    first_active_month = min(monthly) if monthly else periods["month"].start.month
    month_bars = [
        {"label": dt.date(periods["year"].start.year, month, 1).strftime("%b"), "value": monthly[month]}
        for month in range(first_active_month, periods["month"].start.month + 1)
    ]
    blocks = [
        {"id": "auto:masthead", "type": "eyebrow", "text": f"BARKPARK CHRONICLE · VOLUME {periods['year'].key} · LIVING PRODUCT JOURNAL"},
        heading("auto:title", 1, "Barkpark Chronicle"),
        {"id": "auto:ingress", "type": "ingress", "content": [text(lead)]},
        paragraph("auto:dek", "The evolving field journal of Barkpark: one verified history, edited into daily shiplogs, weekly dispatches, monthly chapters, and an annual volume."),
        {"id": "auto:byline", "type": "byline", "items": [periods["day"].title, "Built from first-parent Git history", f"Edition {all_digest[:8]}"]},
        {
            "id": "auto:pulse",
            "type": "stats",
            "items": [
                {"value": f"{len(current_year):,}", "label": "changes in 2026"},
                {"value": percentage(len(product), len(current_year)), "label": "product-facing share"},
                {"value": str(len(areas)), "label": "active product areas"},
                {"value": f"{len(current_week):,}", "label": "changes this week"},
            ],
        },
        {"id": "auto:divider-editions", "type": "divider"},
        heading("auto:editions-title", 2, "Read the current editions"),
        paragraph("auto:editions-dek", "Four lenses on the same source ledger. Start close to the work, then widen the frame."),
        {"id": "auto:periods", "type": "cards", "items": cards},
        {"id": "auto:divider-motion", "type": "divider"},
        heading("auto:motion-title", 2, "The year in motion"),
        paragraph("auto:motion-dek", f"Monthly mainline activity across {periods['year'].key}. The shape is evidence, not a release score: a busy month is not automatically a better month."),
        {"id": "auto:motion", "type": "bar-chart", "title": "Mainline changes by month", "bars": month_bars, "values": True},
        heading("auto:areas-title", 2, "Where the work gathered"),
        area_cards("auto:areas", current_year, repo, limit=4),
        {"id": "auto:divider-latest", "type": "divider"},
        heading("auto:latest-title", 2, "Fresh signals"),
        paragraph("auto:latest-dek", "The five most recent first-parent changes on main, linked back to their source."),
        event_lineage("auto:latest", events, repo),
    ]
    blocks.extend(
        [
            {"id": "auto:divider-provenance", "type": "divider"},
            paragraph("auto:provenance", f"Verified from {len(events):,} first-parent mainline changes · renderer {RENDERER_VERSION} · source digest {all_digest} · all edition links are stable Paper URLs."),
        ]
    )
    return {
        "_id": "barkpark-chronicle",
        "slug": "barkpark-chronicle",
        "title": "Barkpark Chronicle",
        "description": "Barkpark's living, source-linked changelog across day, ISO week, month, and year Papers.",
        "style": "article",
        "event_type": "changelog.index",
        "source_doc": f"git:first-parent:index:{all_digest}",
        "tags": [
            {"tag": "barkpark", "strength": 100, "rationale": "Canonical Barkpark product history."},
            {"tag": "docs", "strength": 90, "rationale": "The permanent front door to the project journal."},
        ],
        "blocks": blocks,
    }


def build(day: dt.date, ref: str, repo: str) -> dict[str, dict[str, Any]]:
    events = read_events(ref)
    periods = periods_for(day)
    payloads = {
        kind: period_payload(period, events_in_period(events, period), periods, repo)
        for kind, period in periods.items()
    }
    payloads["index"] = index_payload(periods, events, repo)
    return payloads


def current_source_doc(api_url: str, slug: str) -> str | None:
    path = "/v1/data/doc/production/paper/" + urllib.parse.quote(slug, safe="")
    try:
        with urllib.request.urlopen(api_url.rstrip("/") + path, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    result = body.get("result") if isinstance(body, dict) else None
    return result.get("source_doc") if isinstance(result, dict) else None


def publish(payloads: Iterable[dict[str, Any]], api_url: str, token: str) -> None:
    endpoint = api_url.rstrip("/") + "/v1/plugins/bulldocs/papers"
    for payload in payloads:
        if current_source_doc(api_url, payload["slug"]) == payload["source_doc"]:
            print(f"unchanged /papers/{payload['slug']}", file=sys.stderr)
            continue
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(payload, separators=(",", ":")).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            receipt = json.load(response)
        print(f"published {receipt['liveview_path']} rev {receipt['rev']}", file=sys.stderr)


def parse_date(value: str) -> dt.date:
    try:
        return dt.date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("date must be YYYY-MM-DD") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", type=parse_date, default=dt.datetime.now(dt.timezone.utc).date())
    parser.add_argument("--ref", default="origin/main")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPO))
    parser.add_argument("--only", choices=("index", "day", "week", "month", "year", "all"), default="all")
    parser.add_argument("--output-dir", type=pathlib.Path)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--api-url", default=os.environ.get("BARKPARK_API_URL") or "https://guerrilla.barkpark.cloud")
    args = parser.parse_args()
    try:
        payloads = build(args.date, args.ref, args.repo)
        selected = payloads.values() if args.only == "all" else [payloads[args.only]]
        selected = list(selected)
        if args.output_dir:
            args.output_dir.mkdir(parents=True, exist_ok=True)
            for payload in selected:
                target = args.output_dir / f"{payload['slug']}.json"
                target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
                print(target)
        elif not args.publish:
            json.dump(selected if args.only == "all" else selected[0], sys.stdout, indent=2)
            print()
        if args.publish:
            token = os.environ.get("BARKPARK_INGEST_TOKEN")
            if not token:
                raise RuntimeError("--publish requires BARKPARK_INGEST_TOKEN")
            publish(selected, args.api_url, token)
    except (RuntimeError, subprocess.CalledProcessError, urllib.error.URLError) as exc:
        print(f"chronicle-paper: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
