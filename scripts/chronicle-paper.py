#!/usr/bin/env python3
"""Build Barkpark Chronicle day/week/month/year/index Paper payloads from Git."""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
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


RENDERER_VERSION = "chronicle-editorial-17"
EDITORIAL_SCHEMA = "barkpark.chronicle-editorial.v2"
ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
EDITORIAL_MODEL = "claude-sonnet-4-6"
LEDGER_PREVIEW_LIMIT = 24
DEFAULT_HISTORY_MONTHS = 18
DEFAULT_REPO = "FRIKKern/barkpark"
RELATED_PAPERS_PATH = pathlib.Path(__file__).resolve().parent.parent / "changelog" / "related-papers.json"
CONVENTIONAL = re.compile(
    r"^(?P<kind>feat|fix|perf|revert|docs|test|ci|build|chore|refactor|style)"
    r"(?:\((?P<scope>[^)]+)\))?(?:!)?:\s*(?P<title>.+)$",
    re.IGNORECASE,
)
PR_SUFFIX = re.compile(r"\s*\(#(?P<number>[0-9]+)\)$")
PRODUCT_KINDS = {"feat", "fix", "perf", "revert"}
EDITORIAL_KINDS = ("day", "week", "month", "year")
FORBIDDEN_EDITORIAL_CLAIMS = re.compile(
    r"\b(revenue|arr|mrr|profit)\b",
    re.IGNORECASE,
)
FORBIDDEN_MAIN_PATH_LANGUAGE = re.compile(
    r"\b(?:api|cli|sse|ets|pagination|allowlists?|callbacks?|schemas?|request ids?|"
    r"read paths?|rollout latches?|retry(?:ability| mechanics?)?|manifests?|corpus|"
    r"endpoints?|protocols?|mainline|source packets?|deduplicat\w*|diagnostics?|"
    r"source-backed|evidence-backed|verified records?|codebases?|deploy(?:ment|ments|ed|ing)?|"
    r"rollbacks?)\b|--|[a-z]+_[a-z]+|/[a-z0-9]",
    re.IGNORECASE,
)
FORBIDDEN_VAGUE_HEADLINE = re.compile(
    r"^(?:opening|making|building|improving|polishing)\b|"
    r"^(?:useful progress|steady progress|a steadier product|more useful ways to work|"
    r"moving things forward|small changes, big impact|under the hood)\b|"
    r"\b(?:gains?|gets?|receives?|finds?) (?:a )?(?:distinct identity|clearer experience|"
    r"better experience|fresh look|new look)$",
    re.IGNORECASE,
)
FORBIDDEN_VAGUE_SUMMARY_OPENING = re.compile(
    r"^(?:this|today['’]s|the (?:day|week|month|year|period))\s+"
    r"(?:work\s+)?(?:was|focused|mixed|centered)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Event:
    occurred_at: dt.datetime
    sha: str
    subject: str
    paths: tuple[str, ...] = ()

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
        [
            "git", "log", "--first-parent", "--name-only", "-z",
            "--format=%x1e%cI%x1f%H%x1f%s", ref,
        ],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    events: list[Event] = []
    for record in raw.split(b"\x1e"):
        if not record:
            continue
        parts = record.split(b"\0")
        header = parts[0].decode("utf-8", errors="replace")
        stamp, sha, subject = header.split("\x1f", 2)
        paths = tuple(
            value.decode("utf-8", errors="replace").lstrip("\n")
            for value in parts[1:]
            if value.strip(b"\n")
        )
        occurred_at = dt.datetime.fromisoformat(stamp).astimezone(dt.timezone.utc)
        events.append(Event(occurred_at, sha, subject, paths))
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


def month_period(day: dt.date) -> Period:
    month_start = day.replace(day=1)
    return Period(
        "month",
        f"{day.year}-{day.month:02d}",
        month_start,
        month_end(month_start),
        f"barkpark-changelog-{day.year}-{day.month:02d}",
        day.strftime("%B %Y"),
    )


def historical_months(events: list[Event], through: dt.date, limit: int) -> list[Period]:
    """Return active calendar months, oldest first, bounded without rescanning Git."""
    keys = sorted(
        {
            (event.occurred_at.year, event.occurred_at.month)
            for event in events
            if event.occurred_at.date() <= through
        }
    )
    if limit > 0:
        keys = keys[-limit:]
    return [month_period(dt.date(year, month, 1)) for year, month in keys]


def historical_periods(events: list[Event], through: dt.date) -> dict[str, list[Period]]:
    """Return every calendar day and containing period through ``through``."""
    periods: dict[str, dict[str, Period]] = {
        "day": {},
        "week": {},
        "month": {},
        "year": {},
    }
    eligible_days = [event.occurred_at.date() for event in events if event.occurred_at.date() <= through]
    first_day = min(eligible_days, default=through)
    cursor = first_day
    while cursor <= through:
        for kind, period in periods_for(cursor).items():
            periods[kind][period.key] = period
        cursor += dt.timedelta(days=1)
    return {
        kind: [by_key[key] for key in sorted(by_key)]
        for kind, by_key in periods.items()
    }


def events_in_period(events: Iterable[Event], period: Period) -> list[Event]:
    return [event for event in events if period.start <= event.occurred_at.date() < period.end]


def events_through(events: Iterable[Event], day: dt.date) -> list[Event]:
    return [event for event in events if event.occurred_at.date() <= day]


def event_url(event: Event, repo: str) -> str:
    if event.pr_number:
        return f"https://github.com/{repo}/pull/{event.pr_number}"
    return f"https://github.com/{repo}/commit/{event.sha}"


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
CAST_EXTENSIONS = {".cast"}
MEDIA_LIMITS = {
    "day": (1, 1),
    "week": (3, 1),
    "month": (8, 2),
    "year": (12, 3),
}
CURATED_CASTS_BY_PATH = {
    "tooling/paper-excellence/twin/payload.json": (
        "https://guerrilla.barkpark.cloud/media/files/2026/08/arch-3c4075aa.cast",
        "https://guerrilla.barkpark.cloud/media/files/2026/08/race-97b047b6.cast",
    ),
}


def artifact_url(event: Event, path: str, repo: str) -> str:
    if path.startswith(("https://", "http://", "/")):
        return path
    encoded = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
    return f"https://raw.githubusercontent.com/{repo}/{event.sha}/{encoded}"


def artifact_candidates(selected: list[Event]) -> list[tuple[Event, str, str]]:
    """Return real media changed by this period, strongest reader evidence first."""
    ranked: list[tuple[int, dt.datetime, Event, str, str]] = []
    seen: set[str] = set()
    for event in reversed(selected):
        paths = list(event.paths)
        for changed_path in event.paths:
            paths.extend(CURATED_CASTS_BY_PATH.get(changed_path, ()))
        for path in paths:
            extension = pathlib.PurePosixPath(path).suffix.lower()
            kind = "image" if extension in IMAGE_EXTENSIONS else "asciicast" if extension in CAST_EXTENSIONS else None
            if kind is None:
                continue
            lowered = path.lower()
            if any(part in lowered for part in ("node_modules/", "vendor/", "fixtures/")):
                continue
            identity = re.sub(
                r"(?:_{1,2}|-)(?:dark|light|mobile|desktop|360|768|1280|1440|1920|2x)",
                "",
                lowered,
            )
            if identity in seen:
                continue
            seen.add(identity)
            score = 0
            if any(part in lowered for part in ("docs/evidence/", "evidence/shots/", "design/")):
                score += 8
            if any(word in lowered for word in ("after", "final", "complete", "hero", "overview")):
                score += 4
            if any(word in lowered for word in ("baseline", "diff", "failure", "thumbnail")):
                score -= 5
            ranked.append((score, event.occurred_at, event, path, kind))
    ranked.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [(event, path, kind) for _score, _stamp, event, path, kind in ranked]


def evidence_blocks(period: Period, selected: list[Event], repo: str) -> list[dict[str, Any]]:
    image_limit, cast_limit = MEDIA_LIMITS[period.kind]
    images = 0
    casts = 0
    evidence: list[dict[str, Any]] = []
    for event, path, kind in artifact_candidates(selected):
        if kind == "image" and images >= image_limit:
            continue
        if kind == "asciicast" and casts >= cast_limit:
            continue
        headline = concrete_fallback_headline(event)
        source = artifact_url(event, path, repo)
        number = images + casts + 1
        caption = (
            f"{event.occurred_at.strftime('%d %b')} · {reader_area(event.area)} — "
            f"{headline}. Real release evidence from the change that shipped it."
        )
        if kind == "image":
            images += 1
            evidence.append({
                "id": f"auto:evidence-{number}",
                "type": "figure",
                "caption": caption,
                "source_ref": event.sha[:10],
                "child": {
                    "type": "image",
                    "src": source,
                    "alt": f"Barkpark showing the result: {headline.lower()}",
                },
            })
        else:
            casts += 1
            evidence.append({
                "id": f"auto:evidence-{number}",
                "type": "asciicast",
                "src": source,
                "caption": caption,
                "poster": "npt:0:08",
                "source_ref": event.sha[:10],
            })
        if images >= image_limit and casts >= cast_limit:
            break
    if not evidence:
        return []

    titles = {
        "day": ("See the change", "One real product moment from today’s release."),
        "week": ("The week in pictures", "Real product moments chosen from the changes that landed this week."),
        "month": ("A month you can see", "A visual tour through the product moments that made this month distinct."),
        "year": ("The year in pictures", "A visual record of the product changing across the year."),
    }
    title_value, dek = titles[period.kind]
    blocks: list[dict[str, Any]] = [
        {"id": "auto:divider-evidence", "type": "divider"},
        heading("auto:evidence-title", 2, title_value),
        paragraph("auto:evidence-dek", dek),
    ]
    figures = [block for block in evidence if block["type"] == "figure"]
    casts = [block for block in evidence if block["type"] == "asciicast"]
    if figures:
        blocks.append(figures[0])
        if len(figures) > 1:
            blocks.append({
                "id": "auto:evidence-gallery",
                "type": "section",
                "layout": {"mode": "grid", "tracks": 2},
                "blocks": figures[1:],
            })
    if casts:
        if period.kind in {"month", "year"}:
            blocks.append(heading("auto:evidence-casts-title", 3, "Watch it move"))
        blocks.extend(casts)
    return blocks


def digest(events: Iterable[Event]) -> str:
    material = "\n".join(event.sha for event in events)
    return hashlib.sha256(f"{RENDERER_VERSION}\n{material}".encode()).hexdigest()[:16]


def editorial_digest(editorial: dict[str, Any]) -> str:
    material = json.dumps(editorial, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(material.encode()).hexdigest()[:12]


def edition_folio(period: Period, events: Iterable[Event]) -> str:
    material = f"{period.kind}\n{period.key}\n{digest(events)}"
    value = hashlib.sha256(material.encode()).hexdigest()[:16]
    return "-".join(value[index:index + 4] for index in range(0, 16, 4))


def signal(period: Period, selected: list[Event]) -> str:
    if not selected:
        return f"A quiet {period.kind}: no product updates shipped during this edition."
    product = sum(event.kind in PRODUCT_KINDS for event in selected)
    areas = collections.Counter(event.area for event in selected)
    area_count = len(areas)
    release_noun = "update" if product == 1 else "updates"
    area_noun = "area" if area_count == 1 else "areas"
    return f"Barkpark shipped {product:,} product {release_noun} across {area_count:,} {area_noun}."


def sentence_case(value: str) -> str:
    return value[:1].upper() + value[1:] if value else value


def reader_area(value: str) -> str:
    """Fold implementation scopes into a small, honest reader-facing product map."""
    area = value.lower()
    families = (
        (("task", "board", "dispatch", "fleet"), "Tasks"),
        (("paper", "bulldoc", "portable", "render", "chronicle", "changelog"), "Papers"),
        (("studio", "structure", "desk", "editor"), "Studio"),
        (("cloud", "site", "deploy", "release"), "Barkpark Cloud"),
        (("tui", "cli", "terminal", "command"), "Terminal"),
        (("chat", "assistant", "model", "provider"), "Chat"),
        (("media", "image", "asset", "video"), "Media"),
        (("auth", "access", "session", "member", "team"), "Access"),
        (("search", "find", "query", "graph"), "Search"),
        (("email", "notification", "webhook", "connector"), "Connections"),
        (("mobile", "web", "reader", "frontend"), "Reader"),
        (("api", "sdk", "data", "schema", "content"), "Platform"),
        (("docs", "test", "ci", "build", "foundation", "repo"), "Foundations"),
    )
    return next((label for needles, label in families if any(needle in area for needle in needles)), "Product foundations")


def edition_display_title(theme: str, suffix: str, limit: int = 255) -> str:
    """Fit generated edition titles to the persisted Paper title contract."""
    separator = " — "
    available = limit - len(separator) - len(suffix)
    if len(theme) > available:
        boundary = theme.rfind(" ", 0, available - 1)
        theme = theme[: boundary if boundary > available // 2 else available - 1].rstrip(" ,;:—-") + "…"
    return f"{theme}{separator}{suffix}"


def clean_editorial_text(value: Any, *, limit: int) -> str:
    if not isinstance(value, str):
        raise ValueError("editorial text must be a string")
    cleaned = " ".join(value.split()).strip()
    if not cleaned:
        raise ValueError("editorial text cannot be empty")
    if len(cleaned) > limit:
        sentence_end = max(cleaned.rfind(mark, 0, limit) for mark in (".", "!", "?"))
        word_end = cleaned.rfind(" ", 0, limit)
        boundary = sentence_end + 1 if sentence_end >= limit // 2 else word_end
        cleaned = cleaned[: boundary if boundary > 0 else limit - 1].rstrip(" ,;:—-")
        if cleaned[-1] not in ".!?":
            cleaned += "."
    if any(character.isdigit() for character in cleaned):
        raise ValueError("editorial prose cannot introduce numeric claims")
    if FORBIDDEN_EDITORIAL_CLAIMS.search(cleaned):
        raise ValueError("editorial prose contains a claim outside the source packet")
    return cleaned


def representative_events(selected: list[Event], limit: int = 36) -> list[Event]:
    """Keep the packet bounded while covering time, product movement, and areas."""
    if len(selected) <= limit:
        return selected
    chosen: dict[str, Event] = {}

    def add_evenly(candidates: list[Event], count: int) -> None:
        if not candidates or count < 1:
            return
        if len(candidates) <= count:
            indexes = range(len(candidates))
        else:
            indexes = sorted({
                round(index * (len(candidates) - 1) / (count - 1))
                for index in range(count)
            })
        for index in indexes:
            chosen[candidates[index].sha] = candidates[index]

    product = [event for event in selected if event.kind in PRODUCT_KINDS]
    add_evenly(product, 14)
    add_evenly(selected, 12)
    for area, _count in collections.Counter(event.area for event in selected).most_common(8):
        event = next(item for item in reversed(selected) if item.area == area)
        chosen[event.sha] = event
    for event in reversed(selected[-8:]):
        chosen[event.sha] = event
    if len(chosen) > limit:
        addable = sorted(chosen.values(), key=lambda event: event.occurred_at)
        chosen = {}
        add_evenly(addable, limit)
    return sorted(chosen.values(), key=lambda event: event.occurred_at)


def editorial_source_packet(period: Period, selected: list[Event]) -> dict[str, Any]:
    areas = collections.Counter(event.area for event in selected)
    kinds = collections.Counter(event.kind for event in selected)
    return {
        "edition_id": f"{period.kind}:{period.key}",
        "kind": period.kind,
        "key": period.key,
        "label": period.title,
        "facts": {
            "mainline_changes": len(selected),
            "product_changes": sum(event.kind in PRODUCT_KINDS for event in selected),
            "areas_touched": len(areas),
            "leading_areas": [area for area, _count in areas.most_common(8)],
            "change_kinds": dict(kinds.most_common()),
            "record_through": selected[-1].occurred_at.date().isoformat() if selected else None,
            "period_status": (
                "complete"
                if dt.datetime.now(dt.timezone.utc).date() >= period.end
                else "in_progress"
            ),
        },
        "sources": [
            {
                "ref": event.sha[:10],
                "kind": event.kind,
                "area": event.area,
                "title": event.title,
            }
            for event in representative_events(selected)
        ],
    }


def deterministic_editorial(period: Period, selected: list[Event]) -> dict[str, Any]:
    """A source-only editorial fallback with the same reader contract as AI copy."""
    if not selected:
        return {
            "theme": f"A quiet {period.kind}",
            "plain_summary": "Nothing new shipped in this period. We keep quiet editions visible so an empty page is never mistaken for a missing one.",
            "work_themes": [],
            "progress_assessment": "This was a pause, not a progress claim. The surrounding editions carry the latest substantive work.",
            "mode": "deterministic",
        }

    fix_heavy = sum(event.kind == "fix" for event in selected) >= max(1, len(selected) // 2)
    feature_heavy = sum(event.kind == "feat" for event in selected) > sum(event.kind == "fix" for event in selected)
    clusters = [
        ("Errors and awkward states were made easier to understand and recover from.", "Less guesswork when something needs attention.", ("error", "fail", "status", "refus", "invalid")),
        ("Work focused on returning the full picture instead of something partial or misleading.", "People can trust that what they see is the whole story.", ("page", "trunc", "partial", "complete", "result", "list")),
        ("Access rules and sensitive paths were tightened without adding friction to ordinary use.", "The product is more dependable around who can see and do what.", ("access", "auth", "token", "member", "permission", "security")),
        ("The less visible edges received the care they need to hold up during real use.", "Everyday work should feel calmer and more predictable.", ("bound", "limit", "buffer", "recover", "retry", "reliab")),
        ("New capabilities were added and connected to the rest of the product.", "There is more that people can accomplish without leaving Barkpark.", ("add", "introduc", "support", "enable", "create")),
    ]
    remaining = list(reversed(selected))
    work_themes = []
    for explanation, outcome, needles in clusters:
        matches = [event for event in remaining if any(needle in event.title.lower() for needle in needles)]
        if not matches:
            continue
        story_title = concrete_fallback_headline(matches[0])
        if any(item["title"] == story_title for item in work_themes):
            continue
        work_themes.append({
            "title": story_title,
            "explanation": explanation,
            "outcome": outcome,
            "source_refs": [event.sha[:10] for event in matches[:3]],
        })
        matched_shas = {event.sha for event in matches}
        remaining = [event for event in remaining if event.sha not in matched_shas]
        if len(work_themes) == 3:
            break
    if not work_themes:
        representative = next(
            (event for event in reversed(selected) if event.kind in PRODUCT_KINDS),
            selected[-1],
        )
        work_themes.append({
            "title": concrete_fallback_headline(representative),
            "explanation": "This period was spent improving the product and tidying the rough edges around it.",
            "outcome": "The result is a more capable, more dependable place to work.",
            "source_refs": [event.sha[:10] for event in reversed(selected[-3:])],
        })
    latest_product = next(
        (event for event in reversed(selected) if event.kind in PRODUCT_KINDS),
        selected[-1],
    )
    theme = concrete_fallback_headline(latest_product)
    latest_changes = []
    for event in reversed(selected):
        if event.kind not in PRODUCT_KINDS:
            continue
        headline = concrete_fallback_headline(event)
        if headline not in latest_changes:
            latest_changes.append(headline)
        if len(latest_changes) == 3:
            break
    if not latest_changes:
        for event in reversed(selected[-3:]):
            headline = concrete_fallback_headline(event)
            if headline not in latest_changes:
                latest_changes.append(headline)
    change_list = "; ".join(latest_changes)
    if feature_heavy:
        summary = f"{change_list}. Those visible additions led the period, alongside the finishing work needed to make them dependable."
        assessment = f"{theme} was the clearest step forward. Supporting work helped it hold up in everyday use."
    elif fix_heavy:
        summary = f"{change_list}. Care and repair led the period, making confusing moments clearer and results easier to trust."
        assessment = f"{theme} was the defining repair. It leaves the surrounding work calmer and more dependable."
    else:
        summary = f"{change_list}. New capability and repair work moved together instead of telling two separate stories."
        assessment = f"{theme} best captures the period. The rest of the work helped that change feel complete rather than isolated."
    return {
        "theme": theme,
        "plain_summary": summary,
        "work_themes": work_themes,
        "progress_assessment": assessment,
        "mode": "deterministic",
    }


def concrete_fallback_headline(event: Event) -> str:
    """Prefer a precise shipped-change headline when editorial synthesis is unavailable."""
    title_value = event.title.lower()
    if any(word in title_value for word in ("chronicle", "changelog", "journal", "edition")):
        if "index" in title_value:
            return "Chronicle index becomes easier to browse"
        if any(word in title_value for word in ("reader", "review", "write-up")):
            return "Chronicle editions lead with the story"
        if any(word in title_value for word in ("publish", "archive", "backfill")):
            return "Chronicle archive stays current"
        return "Chronicle editions become easier to tell apart"
    if "task" in title_value and any(word in title_value for word in ("restore", "list", "view", "visible")):
        return "Tasks return to view"
    if "task" in title_value and any(word in title_value for word in ("claim", "ready", "board", "queue")):
        return "Task boards show who is working on what"
    if "typed export" in title_value:
        return "Barkpark data travels safely into more tools"
    if "paper" in title_value and any(word in title_value for word in ("overflow", "narrow", "mobile", "width")):
        return "Papers now fit smaller screens"
    if any(word in title_value for word in ("pagination", "truncat", "complete result")):
        return "Lists now show the full picture"
    area_headline = product_area_headline(event.area, title_value)
    if area_headline is not None:
        return area_headline
    candidate = source_headline_candidate(event.title)
    if candidate is not None:
        return candidate
    if any(word in title_value for word in ("error", "fail", "refusal", "diagnosis")):
        return "Failures now explain what happened"
    if any(word in title_value for word in ("access", "auth", "token", "permission")):
        return "Access rules close unsafe paths"
    if any(word in title_value for word in ("deploy", "rollout", "release gate")):
        return "Release checks catch failed rollouts"
    if event.kind == "docs" and "chronicle" in title_value:
        return "Chronicle gets a readable guide"
    surface = {
        "tui": "The terminal",
        "cli": "The terminal",
        "tasks": "Tasks",
        "task": "Tasks",
        "papers": "Papers",
        "paper": "Papers",
        "studio": "Studio",
        "media": "Media",
        "cloud": "Barkpark Cloud",
        "auth": "Sign-in",
        "web": "The web reader",
        "mobile": "The mobile workspace",
    }.get(event.area.lower(), "Barkpark")
    if event.kind == "fix":
        return f"{surface} handles a previously broken path"
    if event.kind == "perf":
        return f"{surface} responds more quickly"
    if event.kind == "feat":
        return f"{surface} supports a new everyday action"
    if event.kind in {"docs", "test", "ci", "build", "chore", "refactor", "style"}:
        return f"{surface} becomes easier to understand and maintain"
    return f"{surface} records a concrete product change"


def product_area_headline(area: str, title_value: str) -> str | None:
    area = area.lower()
    if area in {"paper", "papers", "paper-excellence", "portabledoc", "portable-doc", "pds", "render", "bulldocs"}:
        if any(word in title_value for word in ("edit", "author", "canvas")):
            return "Papers become easier to edit"
        if any(word in title_value for word in ("email", "tui", "terminal", "parity", "render")):
            return "Papers keep their shape wherever they are read"
        if any(word in title_value for word in ("image", "video", "media", "cast", "figure")):
            return "Papers bring visual proof into the story"
        if any(word in title_value for word in ("link", "reference", "backlink", "mention")):
            return "Paper links carry useful context"
        if any(word in title_value for word in ("reader", "layout", "spacing", "type", "font", "sheet", "edge")):
            return "Papers read more like finished publications"
        return "Papers tell richer stories with less visual noise"
    if area in {"cloud", "cloud-console", "console", "site-deploy", "deploy-reliability"}:
        if any(word in title_value for word in ("deploy", "release", "rollout")):
            return "Barkpark Cloud makes releases easier to trust"
        return "Barkpark Cloud makes site status easier to understand"
    if area in {"studio", "structure", "desk"}:
        if "chat" in title_value:
            return "Studio chat gets closer to the work"
        return "Studio makes projects easier to navigate"
    if area in {"cli", "tui", "terminal"}:
        if "task" in title_value:
            return "The terminal keeps task work visible"
        return "The terminal explains everyday work more clearly"
    if area in {"task", "tasks", "taskboard", "taskboard-drive"}:
        return "Task boards make ownership and progress visible"
    if area in {"workflow", "workflows", "epic", "epic-cycle", "harness", "runtime"}:
        return "Long-running work becomes easier to start and follow"
    if area in {"errors", "error", "recovery", "sync", "listen"}:
        return "Failures explain what happened and how to recover"
    if area in {"auth", "access", "sessions"}:
        return "Sign-in and access rules become easier to trust"
    return None


def source_headline_candidate(value: str) -> str | None:
    """Keep a source title's useful subject while translating its implementation terms."""
    cleaned = value
    replacements = (
        (r"\bTUI\b|\bCLI\b", "terminal"),
        (r"\bAPI\b", "connections"),
        (r"\bSSE\b|\bWebSockets?\b|\bPubSub\b", "live updates"),
        (r"\bschemas?\b", "content structure"),
        (r"\bpagination\b|\bpaginate[sd]?\b", "complete listing"),
        (r"\brender(?:er|ing|ed)?\b", "display"),
        (r"\bdeploy(?:ment|ments|ed|ing)?\b", "release"),
        (r"\bauth(?:entication)?\b", "access"),
        (r"\bcallbacks?\b", "responses"),
        (r"\brequest IDs?\b", "request details"),
        (r"\bretr(?:y|ies|ied|ying)\b", "recovery"),
        (r"\bmainline\b", "shipped"),
        (r"\bmanifest\b", "capability list"),
    )
    for pattern, replacement in replacements:
        cleaned = re.sub(pattern, replacement, cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"`[^`]+`", "", cleaned)
    cleaned = re.sub(r"\([^)]*(?:D|W|PR|#)\s*\d+[^)]*\)", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\b(?:D|W)\d+(?:[-–]\w+)*\b", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"--[a-z][a-z-]*", "", cleaned)
    cleaned = cleaned.replace("_", " ")
    cleaned = " ".join(cleaned.split()).strip(" -—:;,.")
    if not 12 <= len(cleaned) <= 88:
        return None
    if any(character.isdigit() for character in cleaned):
        return None
    candidate = sentence_case(cleaned)
    implementation_language = re.compile(
        r"\b(?:deep[- ]investigation|launch clause|chokepoint|dialect|tripwire|runbook|"
        r"scriptpath|derived host|token budget|fixture|payload|worktree|codepath|callsite)\b",
        re.IGNORECASE,
    )
    if implementation_language.search(candidate):
        return None
    if FORBIDDEN_MAIN_PATH_LANGUAGE.search(candidate) or FORBIDDEN_VAGUE_HEADLINE.search(candidate):
        return None
    return candidate


def validate_editorial(raw: Any, period: Period, selected: list[Event]) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("editorial edition must be an object")
    valid_refs = {event.sha[:10] for event in representative_events(selected)}
    themes_raw = raw.get("work_themes")
    if not isinstance(themes_raw, list) or not 1 <= len(themes_raw) <= 3:
        raise ValueError("editorial edition needs one to three work themes")
    work_themes = []
    for theme in themes_raw:
        refs = theme.get("source_refs") if isinstance(theme, dict) else None
        if not isinstance(refs, list) or not refs or not set(refs) <= valid_refs:
            raise ValueError("every work theme must cite supplied sources")
        title_value = clean_editorial_text(theme.get("title"), limit=64)
        if FORBIDDEN_VAGUE_HEADLINE.search(title_value):
            raise ValueError("editorial headline must name a subject and a concrete change")
        work_themes.append(
            {
                "title": title_value,
                "explanation": clean_editorial_text(theme.get("explanation"), limit=300),
                "outcome": clean_editorial_text(theme.get("outcome"), limit=180),
                "source_refs": refs[:3],
            }
        )
    theme = clean_editorial_text(raw.get("theme"), limit=80)
    plain_summary = clean_editorial_text(raw.get("plain_summary"), limit=360)
    if FORBIDDEN_VAGUE_HEADLINE.search(theme):
        raise ValueError("editorial headline must name a subject and a concrete change")
    if FORBIDDEN_VAGUE_SUMMARY_OPENING.search(plain_summary):
        raise ValueError("editorial summary must lead with what changed")
    result = {
        "theme": theme,
        "plain_summary": plain_summary,
        "work_themes": work_themes,
        "progress_assessment": clean_editorial_text(raw.get("progress_assessment"), limit=300),
        "mode": "ai",
    }
    visible_copy = " ".join([
        result["theme"], result["plain_summary"], result["progress_assessment"],
        *[f"{item['title']} {item['explanation']} {item['outcome']}" for item in work_themes],
    ])
    if FORBIDDEN_MAIN_PATH_LANGUAGE.search(visible_copy):
        raise ValueError("editorial prose contains implementation jargon")
    return result


def editorial_prompt(packets: list[dict[str, Any]]) -> str:
    source_catalog: dict[str, dict[str, str]] = {}
    compact_packets = []
    for packet in packets:
        compact = {key: value for key, value in packet.items() if key != "sources"}
        compact["source_refs"] = [source["ref"] for source in packet["sources"]]
        compact_packets.append(compact)
        for source in packet["sources"]:
            source_catalog[source["ref"]] = source
    evidence = {"periods": compact_packets, "source_catalog": source_catalog}
    return """
You are the editor of Barkpark Chronicle, a premium, friendly product journal.
Turn the supplied verified evidence into the simplest truthful answer to one
question: “What did Barkpark work on?” Write for an intelligent friend who does
not work in software.

Write with warm, light editorial judgment and confident restraint. Group the work
into concrete product movements; do not paraphrase a list of commits. One gentle turn of phrase
is welcome, but never force a joke. Do not use hype. Do not invent or
imply metrics, customers, revenue, adoption, dates, deadlines, security guarantees,
or future promises. Use no digits anywhere in prose. Never name internal components,
code paths, endpoints, protocols, fields, flags, error codes, implementation
mechanics, or repeat repository wording. Avoid software jargon including pagination,
allowlists, callbacks, schemas, request IDs, read paths, rollout latches, and retries.
Translate those details into outcomes such as clearer errors, more complete results,
safer access, or easier everyday use. The verification system is the invisible
backbone, not a subject to celebrate in the visible story. Do not use phrases such
as source-backed, evidence-backed, verified records, deduplicated, diagnostics,
codebase, deployment, or rollback.
Do not create separate audience viewpoints.
Respect each packet's period status. Never describe an in-progress week, month, or
year as closed, complete, ending, or finished; write “to date” when the distinction matters.

The `theme` is a NEWS HEADLINE, not a mood or a decorative slogan. It must begin
with the product, surface, or capability that changed, then state the change or
reader-visible result. A reader must learn something factual from the headline
alone. Never begin a headline with Opening, Making, Building, Improving, or
Polishing. Never write “Opening new possibilities,” “Useful progress,” “Making
work smoother,” “Building momentum,” “A steadier product,” or any equivalent.
Bad: “Opening up new possibilities.” Good: “Chronicle editions get unique titles
and fact-checked reviews.” Bad: “Making work smoother.” Good: “Task lists return to the terminal.”
Bad: “Useful progress.” Good: “Paper links now show live project context.”
Apply the same subject-plus-change rule to every work-theme title.

The first sentence of `plain_summary` must name the most important actual changes.
Do not begin with “This period was about,” “Today’s work focused on,” or another
sentence that describes the act of working instead of its result. The second
sentence explains what a reader can now see, do, or trust that they could not before.

Return only JSON with this exact outer shape, with one edition object for every
`edition_id` supplied in the source packets:
{"schema":"barkpark.chronicle-editorial.v2","editions":{"day:YYYY-MM-DD":{"theme":"","plain_summary":"","work_themes":[{"title":"","explanation":"","outcome":"","source_refs":["exact supplied ref"]}],"progress_assessment":""}}}
Each supplied edition needs one to three distinct work themes, and every theme must
cite one to three exact refs from that edition's supplied sources. The plain summary
must answer the reader's question in two or three short sentences. The progress
assessment must say honestly whether this was feature work, care-and-repair work,
balanced work, or a quiet period. Scale the judgment: day is immediate effect, week
is direction, month is durable progress, year is the arc. Longer periods still get no
more than three themes. Keep the theme under twelve words and use the extra room
for facts, never decoration. Keep the summary under fifty words,
each explanation under thirty-five words, each outcome under twenty words, and the
assessment under forty words.

Verified source packets:
""".strip() + "\n" + json.dumps(evidence, ensure_ascii=False, separators=(",", ":"))


def parse_model_json(raw: str) -> dict[str, Any]:
    outer = json.loads(raw)
    if isinstance(outer, dict) and isinstance(outer.get("result"), str):
        raw = outer["result"].strip()
        return parse_json_text(raw)
    content = outer.get("content") if isinstance(outer, dict) else None
    if isinstance(content, list):
        raw = next(
            (item.get("text", "") for item in content if item.get("type") == "text"),
            "",
        )
        return parse_json_text(raw)
    if not isinstance(outer, dict):
        raise ValueError("model response was not an object")
    return outer


def parse_json_text(raw: str) -> dict[str, Any]:
    raw = raw.strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)```", raw, re.DOTALL)
    if fenced:
        raw = fenced.group(1).strip()
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError("editorial JSON must be an object")
    return parsed


def request_editorials(packets: list[dict[str, Any]], provider: str) -> dict[str, Any]:
    prompt = editorial_prompt(packets)
    if provider == "claude":
        raw = subprocess.run(
            [
                "claude", "-p", prompt, "--model", "sonnet", "--output-format", "json",
                "--max-turns", "1", "--no-session-persistence", "--strict-mcp-config",
                "--system-prompt", "Return only the requested grounded JSON. Do not use tools.",
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            timeout=300,
        ).stdout
    elif provider == "anthropic":
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise RuntimeError("Anthropic editorial generation requires ANTHROPIC_API_KEY")
        body = {
            "model": os.environ.get("CHRONICLE_EDITORIAL_MODEL", EDITORIAL_MODEL),
            "max_tokens": 5000,
            "system": "Return only the requested grounded JSON.",
            "messages": [{"role": "user", "content": prompt}],
        }
        request = urllib.request.Request(
            ANTHROPIC_ENDPOINT,
            data=json.dumps(body).encode(),
            headers={
                "x-api-key": key,
                "anthropic-version": ANTHROPIC_VERSION,
                "content-type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=180) as response:
            raw = response.read().decode("utf-8")
    else:
        raise RuntimeError(f"unknown editorial provider: {provider}")
    parsed = parse_model_json(raw)
    if parsed.get("schema") != EDITORIAL_SCHEMA or not isinstance(parsed.get("editions"), dict):
        raise RuntimeError("editorial response does not match the Chronicle schema")
    return parsed["editions"]


def generate_current_editorials(
    events: list[Event], periods: dict[str, Period], provider: str
) -> dict[str, dict[str, Any]]:
    selected_by_kind = {
        kind: events_in_period(events, periods[kind])
        for kind in EDITORIAL_KINDS
    }
    active_kinds = [kind for kind in EDITORIAL_KINDS if selected_by_kind[kind]]
    if not active_kinds:
        return {}
    packets = [editorial_source_packet(periods[kind], selected_by_kind[kind]) for kind in active_kinds]
    try:
        raw = request_editorials(packets, provider)
    except (KeyError, ValueError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError) as exc:
        print(
            f"chronicle-paper: editorial generation fell back safely ({type(exc).__name__})",
            file=sys.stderr,
        )
        return {}
    valid: dict[str, dict[str, Any]] = {}
    for kind in active_kinds:
        try:
            edition_id = f"{kind}:{periods[kind].key}"
            valid[kind] = validate_editorial(
                raw.get(edition_id, raw.get(kind)),
                periods[kind],
                selected_by_kind[kind],
            )
        except (KeyError, ValueError) as exc:
            print(f"chronicle-paper: {kind} editorial fell back safely: {exc}", file=sys.stderr)
    return valid


def generate_archive_editorials(
    events: list[Event], archive: dict[str, list[Period]], provider: str, batch_size: int = 8
) -> dict[str, dict[str, Any]]:
    """Write the complete active archive in bounded batches; quiet editions stay factual."""
    valid: dict[str, dict[str, Any]] = {}
    # Same-scale periods do not overlap, which keeps source references unambiguous.
    for kind in EDITORIAL_KINDS:
        editions = [
            (period, events_in_period(events, period))
            for period in archive[kind]
        ]
        editions = [(period, selected) for period, selected in editions if selected]
        for offset in range(0, len(editions), batch_size):
            batch = editions[offset:offset + batch_size]
            packets = [editorial_source_packet(period, selected) for period, selected in batch]
            try:
                raw = request_editorials(packets, provider)
            except (KeyError, ValueError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError) as exc:
                print(
                    f"chronicle-paper: archive editorial batch fell back safely ({type(exc).__name__})",
                    file=sys.stderr,
                )
                continue
            for period, selected in batch:
                edition_id = f"{period.kind}:{period.key}"
                try:
                    valid[edition_id] = validate_editorial(raw[edition_id], period, selected)
                except (KeyError, ValueError) as exc:
                    print(f"chronicle-paper: {edition_id} editorial fell back safely: {exc}", file=sys.stderr)
    return valid


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
                "text": f"{count:,} {'change' if count == 1 else 'changes'} · latest: {latest.title}",
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


def release_highlights(block_id: str, selected: list[Event], repo: str, limit: int) -> dict[str, Any]:
    """A reader-facing release trail with product language and exact provenance."""
    candidates = [event for event in selected if event.kind in PRODUCT_KINDS] or selected
    nodes = [
        {
            "overline": f"{event.occurred_at.strftime('%d %b')} · {reader_area(event.area)}",
            "title": concrete_fallback_headline(event),
            "body": "Open the shipped change and its source record.",
            "source": event_url(event, repo),
        }
        for event in reversed(candidates[-limit:])
    ]
    return {"id": block_id, "type": "lineage", "nodes": nodes}


def weekly_activity(block_id: str, selected: list[Event], period: Period) -> dict[str, Any]:
    counts: collections.Counter[dt.date] = collections.Counter()
    cursor = period.start
    while cursor < period.end:
        counts[cursor] = 0
        cursor += dt.timedelta(days=7)
    for event in selected:
        bucket = period.start + dt.timedelta(days=((event.occurred_at.date() - period.start).days // 7) * 7)
        counts[bucket] += 1
    return {
        "id": block_id,
        "type": "bar-chart",
        "title": f"Weekly cadence · {period.title}",
        "bars": [
            {"label": f"{start.strftime('%d %b')}", "value": count}
            for start, count in sorted(counts.items())
        ],
        "values": True,
    }


def monthly_activity(block_id: str, selected: list[Event], period: Period) -> dict[str, Any]:
    counts: collections.Counter[str] = collections.Counter()
    for month in range(1, 13):
        counts[dt.date(period.start.year, month, 1).strftime("%b")] = 0
    for event in selected:
        counts[event.occurred_at.strftime("%b")] += 1
    return {
        "id": block_id,
        "type": "bar-chart",
        "title": f"Monthly cadence · {period.title}",
        "bars": [{"label": label, "value": value} for label, value in counts.items()],
        "values": True,
    }


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


def archive_list(block_id: str, periods: list[Period], events: list[Event]) -> dict[str, Any]:
    items = []
    for period in periods:
        count = len(events_in_period(events, period))
        note = "quiet edition" if count == 0 else f"{count:,} change" if count == 1 else f"{count:,} changes"
        items.append([link(period.title, f"/papers/{period.slug}"), text(f" · {note}")])
    return {"id": block_id, "type": "list", "ordered": False, "items": items}


def archive_chapter_cards(block_id: str, periods: list[Period], events: list[Event]) -> dict[str, Any]:
    items = []
    for period in periods:
        selected = events_in_period(events, period)
        if selected:
            latest = selected[-1]
            count = f"{len(selected):,} {'change' if len(selected) == 1 else 'changes'}"
            description = f"{count}. Latest movement: {concrete_fallback_headline(latest)}."
        else:
            description = "A quiet chapter with no recorded release activity."
        items.append({
            "title": period.title,
            "text": description,
            "href": f"/papers/{period.slug}",
            "label": "Open this chapter",
        })
    return linked_card_section(block_id, items, tracks=2)


def index_archive_list(block_id: str, periods: list[Period]) -> dict[str, Any]:
    """A reader-facing monthly contents list; implementation evidence stays collapsed."""
    items = [
        [link(period.title, f"/papers/{period.slug}")]
        for period in reversed(periods)
    ]
    return {"id": block_id, "type": "list", "ordered": False, "items": items}


def complete_archive_blocks(
    archive: dict[str, list[Period]],
    events: list[Event],
) -> list[dict[str, Any]]:
    """One calm front door to every generated edition, grouped by month."""
    children: list[dict[str, Any]] = [
        paragraph(
            "auto:complete-intro",
            "Open any day, week, month, or year. Quiet days remain here too, so gaps mean rest—not missing history.",
        ),
        heading("auto:complete-years-title", 3, "Years"),
        archive_list("auto:complete-years", list(reversed(archive["year"])), events),
    ]
    for month in reversed(archive["month"]):
        suffix = month.key
        weeks = [week for week in archive["week"] if week.start < month.end and week.end > month.start]
        days = [day for day in archive["day"] if month.start <= day.start < month.end]
        children.extend([
            heading(f"auto:complete-{suffix}-title", 3, month.title),
            paragraph(
                f"auto:complete-{suffix}-month",
                [text("Month · "), link("Read the monthly edition", f"/papers/{month.slug}")],
            ),
            heading(f"auto:complete-{suffix}-weeks-title", 4, "Weeks"),
            archive_list(f"auto:complete-{suffix}-weeks", weeks, events),
            heading(f"auto:complete-{suffix}-days-title", 4, "Days"),
            archive_list(f"auto:complete-{suffix}-days", days, events),
        ])
    return [{
        "id": "auto:complete-archive",
        "type": "expandable",
        "summary": "Browse every edition",
        "children": children,
    }]


def edition_columns(periods: dict[str, Period], latest_day: Period, current_week: list[Event]) -> dict[str, Any]:
    """Borderless journal navigation: two balanced columns, four clear reading jobs."""
    week_number = periods["week"].key.split("-W")[-1]
    entries = [
        (
            "Day",
            "The closest look at what changed most recently.",
            "Read the latest day →",
            latest_day.slug,
        ),
        (
            "Week",
            f"Week {week_number}, with {len(current_week):,} updates gathered into one direction.",
            "Read this week →",
            periods["week"].slug,
        ),
        (
            "Month",
            f"The larger themes taking shape across {periods['month'].title}.",
            "Read the month →",
            periods["month"].slug,
        ),
        (
            "Year",
            f"The full arc of {periods['year'].key}, organized into monthly chapters.",
            "Explore the year →",
            periods["year"].slug,
        ),
    ]
    columns = []
    for column_index in range(2):
        children = []
        for title_value, description, label, slug in entries[column_index * 2:(column_index + 1) * 2]:
            children.extend(
                [
                    {"type": "heading", "level": 3, "text": title_value},
                    {"type": "paragraph", "content": [text(description)]},
                    {"type": "paragraph", "content": [link(label, f"/papers/{slug}")]},
                ]
            )
        columns.append(children)
    return {"id": "auto:periods", "type": "columns", "columns": columns}


def linked_card_section(
    block_id: str,
    items: list[dict[str, str]],
    *,
    tracks: int = 2,
) -> dict[str, Any]:
    tones = ("info", "ok", "warn")
    cards = []
    for index, item in enumerate(items):
        cards.append(
            {
                "id": f"{block_id}:card-{index + 1}",
                "type": "card",
                "tone": item.get("tone", tones[index % len(tones)]),
                "slots": {
                    "title": [
                        {"type": "heading", "level": 3, "text": item["title"]},
                    ],
                    "body": [
                        {"type": "paragraph", "content": [text(item["text"])]},
                    ],
                    "action": [
                        {
                            "type": "action",
                            "label": item.get("label", "Read release notes"),
                            "href": item["href"],
                        }
                    ],
                },
            }
        )
    return {
        "id": block_id,
        "type": "section",
        "layout": {"mode": "grid", "tracks": tracks},
        "blocks": cards,
    }


def load_related_papers(path: pathlib.Path = RELATED_PAPERS_PATH) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot load related Paper catalog {path}: {exc}") from exc
    if not isinstance(value, list):
        raise RuntimeError(f"related Paper catalog must be a list: {path}")
    return value


def related_paper_block(
    period: Period,
    selected: list[Event],
    catalog: list[dict[str, Any]],
    *,
    block_id: str = "auto:related-papers",
) -> dict[str, Any] | None:
    if not selected:
        return None
    haystack = " ".join(
        " ".join([event.area, event.title, *event.paths])
        for event in selected
    ).lower()
    ranked = []
    for index, item in enumerate(catalog):
        keywords = [str(keyword).lower() for keyword in item.get("keywords", [])]
        score = sum(haystack.count(keyword) for keyword in keywords)
        if score:
            ranked.append((score, -index, item))
    ranked.sort(reverse=True, key=lambda item: (item[0], item[1]))
    limit = {"day": 2, "week": 3, "month": 4, "year": 6}[period.kind]
    refs = [
        {
            "slug": item["slug"],
            "title": item.get("title", item["slug"]),
            "description": item.get("reason", "A related Barkpark Paper."),
            "reason": item.get("reason"),
        }
        for _score, _index, item in ranked[:limit]
    ]
    if not refs:
        return None
    return {
        "id": block_id,
        "type": "paper-links",
        "title": "Worth opening next",
        "description": "A few real Papers that add useful context to this edition.",
        "refs": refs,
    }


def editorial_story_section(
    block_id: str,
    stories: list[dict[str, Any]],
    selected: list[Event],
    repo: str,
) -> dict[str, Any]:
    by_ref = {event.sha[:10]: event for event in selected}
    cards = []
    for index, story in enumerate(stories):
        sources = [by_ref[ref] for ref in story["source_refs"] if ref in by_ref]
        primary = sources[0]
        cards.append(
            {
                "id": f"{block_id}:card-{index + 1}",
                "type": "card",
                "tone": "ok" if primary.kind == "feat" else "info",
                "slots": {
                    "title": [{"type": "heading", "level": 3, "text": story["title"]}],
                    "body": [{
                        "type": "paragraph",
                        "content": [text(f"{story['explanation']} {story['outcome']}")],
                    }],
                    "action": [
                        {
                            "type": "action",
                            "label": "See what shipped",
                            "href": event_url(primary, repo),
                        }
                    ],
                },
            }
        )
    return {
        "id": block_id,
        "type": "section",
        "layout": {"mode": "grid", "tracks": 1},
        "blocks": cards,
    }


def child_archive_blocks(
    period: Period,
    selected: list[Event],
    events: list[Event],
    archive: dict[str, list[Period]],
) -> list[dict[str, Any]]:
    if period.kind == "year":
        children = [child for child in archive["month"] if period.start <= child.start < period.end]
        if not children:
            return []
        return [
            {"id": "auto:divider-archive-1", "type": "divider"},
            heading("auto:archive-title-1", 2, "The year, chapter by chapter"),
            paragraph("auto:archive-dek-1", "Open any month for its full story, visual evidence, and daily record."),
            archive_chapter_cards("auto:archive-1", children, events),
        ]
    elif period.kind == "month":
        weeks = [child for child in archive["week"] if child.start < period.end and child.end > period.start]
        days = [child for child in archive["day"] if period.start <= child.start < period.end]
        blocks: list[dict[str, Any]] = []
        if weeks:
            blocks.extend([
                {"id": "auto:divider-archive-1", "type": "divider"},
                heading("auto:archive-title-1", 2, "The month, week by week"),
                paragraph("auto:archive-dek-1", "Each weekly chapter gives the work room to breathe, including boundary weeks."),
                archive_chapter_cards("auto:archive-1", weeks, events),
            ])
        if days:
            blocks.extend([
                heading("auto:archive-title-2", 2, "Browse every day"),
                {
                    "id": "auto:archive-2",
                    "type": "expandable",
                    "summary": f"Open all {len(days)} daily editions",
                    "children": [archive_list("auto:archive-days", days, events)],
                },
            ])
        return blocks
    elif period.kind == "week":
        days = [child for child in archive["day"] if period.start <= child.start < period.end]
        if days:
            return [
                {"id": "auto:divider-archive-1", "type": "divider"},
                heading("auto:archive-title-1", 2, "Daily editions"),
                paragraph("auto:archive-dek-1", "Every calendar day in this weekly dispatch."),
                archive_list("auto:archive-1", days, events),
            ]
    return []


def period_payload(
    period: Period,
    selected: list[Event],
    periods: dict[str, Period],
    repo: str,
    *,
    events: list[Event] | None = None,
    archive: dict[str, list[Period]] | None = None,
    editorial: dict[str, Any] | None = None,
    related_papers: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    editorial = editorial or deterministic_editorial(period, selected)
    product = [event for event in selected if event.kind in PRODUCT_KINDS]
    areas = collections.Counter(event.area for event in selected)
    reader_areas = {reader_area(event.area) for event in selected}
    suffixes = {
        "day": period.start.strftime("%d %B %Y").lstrip("0"),
        "week": f"Week {period.key.split('-W')[-1]}",
        "month": period.title,
        "year": f"Barkpark in {period.title}",
    }
    display_titles = {
        kind: edition_display_title(editorial["theme"], suffix)
        for kind, suffix in suffixes.items()
    }
    date_range = f"{period.start.strftime('%d %b')}–{(period.end - dt.timedelta(days=1)).strftime('%d %b %Y')}"
    through_date = selected[-1].occurred_at.date() if selected else min(
        dt.datetime.now(dt.timezone.utc).date(), period.end - dt.timedelta(days=1)
    )
    profile = collections.Counter(event.kind for event in selected)
    dominant_kind = profile.most_common(1)[0][0] if profile else "quiet"
    area_limit = 8 if period.kind == "year" else 6 if period.kind == "month" else 3
    sequence_limit = 14 if period.kind == "year" else 10 if period.kind == "month" else 5
    ledger_limit = 60 if period.kind == "year" else 40 if period.kind == "month" else LEDGER_PREVIEW_LIMIT
    active_days = len({event.occurred_at.date() for event in selected})
    active_months = len({event.occurred_at.strftime("%Y-%m") for event in selected})
    unit_value = active_months if period.kind == "year" else active_days
    unit_label = "active months" if period.kind == "year" else "active days"
    deks = {
        "day": "A clear account of the day comes first. The detailed source record is tucked neatly underneath.",
        "week": "The week’s story, visible product moments, and release trail come first. The complete source record remains underneath.",
        "month": "A full editorial review of the month: what changed, how the product looked, and where the work gathered momentum.",
        "year": "Barkpark’s annual record: the defining work, the product in motion, and every monthly chapter behind it.",
    }
    work_titles = {
        "day": "What we worked on",
        "week": "The week’s defining work",
        "month": "The month’s defining work",
        "year": "The year’s defining work",
    }
    blocks: list[dict[str, Any]] = navigation_blocks(periods, period.kind)
    blocks.extend([
        {"id": "auto:identity", "type": "eyebrow", "text": f"BARKPARK CHRONICLE · {period.kind.upper()} · {period.key}"},
        heading("auto:title", 1, display_titles[period.kind]),
        {"id": "auto:ingress", "type": "ingress", "content": [text(editorial["plain_summary"])]},
        paragraph("auto:dek", deks[period.kind]),
        {"id": "auto:byline", "type": "byline", "items": [date_range, f"Through {through_date.strftime('%d %B %Y').lstrip('0')}"]},
    ])
    if selected and period.kind in {"week", "month", "year"}:
        blocks.append({
            "id": "auto:period-pulse",
            "type": "stats",
            "items": [
                {"value": str(len(selected)), "label": "shipped changes"},
                {"value": str(len(product)), "label": "product updates"},
                {"value": str(unit_value), "label": unit_label},
                {"value": str(len(reader_areas)), "label": "product areas"},
            ],
        })
    blocks.extend(evidence_blocks(period, selected, repo))
    blocks.extend([
        {"id": "auto:divider-work", "type": "divider"},
        heading("auto:work-title", 2, work_titles[period.kind]),
        editorial_story_section("auto:work-themes", editorial["work_themes"], selected, repo)
        if editorial["work_themes"]
        else paragraph("auto:work-themes", "No new work landed in this interval."),
        heading("auto:progress-title", 2, "How this period moved"),
        {
            "id": "auto:progress-assessment",
            "type": "callout",
            "tone": "info",
            "title": "The short version",
            "content": [text(editorial["progress_assessment"])],
        },
    ])
    if selected and period.kind in {"month", "year"}:
        blocks.extend([
            {"id": "auto:divider-highlights", "type": "divider"},
            heading("auto:highlights-title", 2, "Release highlights"),
            paragraph("auto:highlights-dek", "The product-facing changes that best show the period moving, each linked to its source."),
            release_highlights(
                "auto:release-highlights",
                selected,
                repo,
                limit=18 if period.kind == "year" else 12,
            ),
        ])
    related = related_paper_block(period, selected, related_papers or [])
    if related is not None:
        blocks.append(related)
    if events is not None and archive is not None:
        blocks.extend(child_archive_blocks(period, selected, events, archive))
    blocks.append({"id": "auto:divider-record", "type": "divider"})
    technical_record: list[dict[str, Any]] = [
        paragraph("auto:record-intro", "The detailed record behind this edition: counts, categories, source links, and the complete release trail."),
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
        heading("auto:shape-title", 2, "Release shape"),
        change_profile("auto:change-profile", selected, f"Updates by category · {period.key}"),
        area_cards("auto:areas", selected, repo, limit=area_limit),
        heading("auto:sequence-title", 2, "Latest updates"),
        event_lineage("auto:sequence", selected, repo, limit=sequence_limit),
    ]
    if period.kind in {"month", "year"}:
        technical_record.extend([
            heading("auto:cadence-title", 2, "How the period unfolded"),
            monthly_activity("auto:monthly-cadence", selected, period)
            if period.kind == "year"
            else weekly_activity("auto:weekly-cadence", selected, period),
        ])
    technical_record.append(heading("auto:ledger-title", 2, "Complete release log"))
    if selected:
        items = []
        for event in reversed(selected[-ledger_limit:]):
            items.append(
                [
                    text(event.occurred_at.strftime("%d %b %H:%M UTC"), marks=["code"]),
                    text(" · "),
                    link(event.title, event_url(event, repo)),
                    text(f" · {event.area}"),
                ]
            )
        technical_record.append({"id": "auto:ledger", "type": "list", "ordered": False, "items": items})
        omitted = len(selected) - len(items)
        label = f"Open the complete source ledger ({len(selected):,} changes)"
        suffix = f"; {omitted:,} earlier changes are omitted from this reading view." if omitted else "."
        technical_record.append(paragraph("auto:ledger-source", [link(label, ledger_url(period, repo)), text(suffix)]))
    else:
        technical_record.append(paragraph("auto:ledger", "No release activity was inferred or backfilled for this period."))
    technical_record.append(paragraph(
        "auto:provenance",
        f"Generated from first-parent Git history for {period.start.isoformat()} through {(period.end - dt.timedelta(days=1)).isoformat()} UTC · edition {edition_folio(period, selected)} · {editorial['mode']} editorial review · renderer {RENDERER_VERSION} · digest {digest(selected)}.",
    ))
    blocks.append({
        "id": "auto:technical-record",
        "type": "expandable",
        "summary": "Technical record and source evidence",
        "children": technical_record,
    })
    payload = {
        "_id": period.slug,
        "slug": period.slug,
        "title": display_titles[period.kind],
        "description": f"A clear, source-grounded account of what Barkpark worked on in {period.title}.",
        "style": "article",
        "event_type": f"changelog.{period.kind}",
        "source_doc": f"git:first-parent:{period.kind}:{period.key}:{digest(selected)}:{editorial_digest(editorial)}",
        "tags": [
            {"tag": "barkpark", "strength": 100, "rationale": "Canonical Barkpark product history."},
            {"tag": "docs", "strength": 85, "rationale": "A durable, source-linked project record."},
        ],
        "blocks": blocks,
    }
    if period.kind in {"day", "week", "month", "year"}:
        # Chronicle editions intentionally share an editorial series shape.
        # The calendar key and source digest prove distinct source intervals;
        # this persisted flag records the deliberate series-level exemption.
        payload["dedup_bypass"] = True
    return payload


def index_payload(
    periods: dict[str, Period],
    events: list[Event],
    repo: str,
    month_archive: list[Period],
    editorials: dict[str, dict[str, Any]] | None = None,
    archive: dict[str, list[Period]] | None = None,
    related_papers: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    editorials = editorials or {}
    latest = events[-1] if events else None
    current_year = events_in_period(events, periods["year"])
    current_week = events_in_period(events, periods["week"])
    product = [event for event in current_year if event.kind in PRODUCT_KINDS]
    areas = collections.Counter(event.area for event in current_year)
    active_days = {event.occurred_at.date() for event in current_year}
    active_weeks = {event.occurred_at.date().isocalendar()[:2] for event in current_year}
    latest_day = periods_for(latest.occurred_at.date())["day"] if latest else periods["day"]
    current_day = events_in_period(events, periods["day"])
    latest_selected = events_in_period(events, latest_day)
    day_editorial = (
        editorials.get(f"day:{latest_day.key}", editorials.get("day"))
        if latest_day.key == periods["day"].key
        else editorials.get(f"day:{latest_day.key}")
    ) or deterministic_editorial(latest_day, latest_selected)
    all_digest = digest(events)
    monthly = collections.Counter(event.occurred_at.month for event in current_year)
    first_active_month = min(monthly) if monthly else periods["month"].start.month
    month_bars = [
        {"label": dt.date(periods["year"].start.year, month, 1).strftime("%b"), "value": monthly[month]}
        for month in range(first_active_month, periods["month"].start.month + 1)
    ]
    blocks = [
        {"id": "auto:masthead", "type": "eyebrow", "text": f"BARKPARK CHRONICLE · {periods['year'].key}"},
        heading("auto:title", 1, "What’s new in Barkpark"),
        {"id": "auto:ingress", "type": "ingress", "content": [text("A clear, human account of what we’ve been building—fresh enough for today, useful enough to keep.")]},
        paragraph("auto:dek", "Start with the newest story, then step back to see the week, month, or year. The technical receipts are always there when you want them."),
        {"id": "auto:byline", "type": "byline", "items": [f"Updated {periods['day'].title}", "Day · week · month · year"]},
        heading("auto:featured-title", 2, "Today in Barkpark"),
        {"id": "auto:featured-label", "type": "eyebrow", "text": f"LATEST DAILY EDITION · {latest_day.title.upper()}"},
        heading("auto:featured-theme", 3, day_editorial["theme"]),
        paragraph("auto:featured-summary", day_editorial["plain_summary"]),
        paragraph("auto:featured-link", [link("Read today’s edition →", f"/papers/{latest_day.slug}")]),
    ]
    interesting = related_paper_block(
        periods["month"],
        events_in_period(events, periods["month"]),
        related_papers or [],
        block_id="auto:interesting-papers",
    )
    if interesting is not None:
        interesting["title"] = "Interesting Papers right now"
        interesting["description"] = "Deeper reads connected to the work moving through Barkpark this month."
        blocks.append(interesting)
    blocks.extend([
        heading("auto:editions-title", 2, "Choose your view"),
        paragraph("auto:editions-dek", "A quick daily note, a weekly direction, a monthly review, or the whole story so far."),
        edition_columns(periods, latest_day, current_week),
        heading("auto:archive-title", 2, "Release archive"),
        paragraph("auto:archive-dek", "Monthly chapters, newest first. Each one tells the story before showing the record."),
        index_archive_list("auto:month-archive", month_archive),
    ])
    if archive is not None:
        blocks.extend(complete_archive_blocks(archive, events))
    blocks.append({
        "id": "auto:shipping-record",
        "type": "expandable",
        "summary": "Shipping record and source evidence",
        "children": [
            paragraph("auto:record-intro", "The live record behind this journal: release volume, active areas, and direct links to the newest shipped work."),
            {
                "id": "auto:pulse",
                "type": "stats",
                "items": [
                    {"value": f"{len(current_year):,}", "label": "updates shipped"},
                    {"value": f"{len(product):,}", "label": "product improvements"},
                    {"value": str(len(active_days)), "label": "shipping days"},
                    {"value": str(len(active_weeks)), "label": "weekly editions"},
                ],
            },
            heading("auto:motion-title", 2, "Shipping activity"),
            paragraph("auto:motion-dek", f"A month-by-month view of {periods['year'].key}. Volume shows cadence, not quality."),
            {"id": "auto:motion", "type": "bar-chart", "title": "Updates by month", "bars": month_bars, "values": True},
            heading("auto:areas-title", 2, "Product areas improved"),
            area_cards("auto:areas", current_year, repo, limit=4),
            heading("auto:latest-title", 2, "Recently shipped"),
            paragraph("auto:latest-dek", "The five newest changes, linked directly to the pull request or commit behind each release."),
            event_lineage("auto:latest", events, repo),
            paragraph("auto:provenance", f"Verified from {len(events):,} first-parent mainline changes · renderer {RENDERER_VERSION} · source digest {all_digest} · every edition has a stable Paper URL."),
        ],
    })
    return {
        "_id": "barkpark-chronicle",
        "slug": "barkpark-chronicle",
        "title": "What’s new in Barkpark",
        "description": "Premium, source-linked Barkpark release notes across day, week, month, and year editions.",
        "style": "article",
        "event_type": "changelog.index",
        "source_doc": f"git:first-parent:index:{all_digest}:{editorial_digest(day_editorial)}:editorial",
        "tags": [
            {"tag": "barkpark", "strength": 100, "rationale": "Canonical Barkpark product history."},
            {"tag": "docs", "strength": 90, "rationale": "The permanent front door to the project journal."},
        ],
        "blocks": blocks,
    }


def build(
    day: dt.date,
    ref: str,
    repo: str,
    history_months: int = 0,
    full_history: bool = False,
    *,
    events: list[Event] | None = None,
    editorials: dict[str, dict[str, Any]] | None = None,
    related_papers: list[dict[str, Any]] | None = None,
) -> dict[str, dict[str, Any]]:
    events = events_through(events if events is not None else read_events(ref), day)
    editorials = editorials or {}
    related_papers = load_related_papers() if related_papers is None else related_papers
    periods = periods_for(day)
    complete_archive = historical_periods(events, day)
    month_archive = (
        complete_archive["month"]
        if full_history
        else historical_months(events, day, history_months or DEFAULT_HISTORY_MONTHS)
    )
    payloads = {
        kind: period_payload(
            period,
            events_in_period(events, period),
            periods,
            repo,
            events=events,
            archive=complete_archive if full_history else None,
            editorial=editorials.get(f"{kind}:{period.key}", editorials.get(kind)),
            related_papers=related_papers,
        )
        for kind, period in periods.items()
    }
    archive_kinds = (
        ("day", "week", "month", "year")
        if full_history
        else (("month",) if history_months else ())
    )
    for kind in archive_kinds:
        for historical in complete_archive[kind] if full_history else month_archive:
            if historical.key == periods[kind].key:
                continue
            selected = events_in_period(events, historical)
            anchor = selected[0].occurred_at.date() if selected else historical.start
            context = periods_for(anchor)
            payloads[f"{kind}:{historical.key}"] = period_payload(
                historical,
                selected,
                context,
                repo,
                events=events,
                archive=complete_archive if full_history else None,
                editorial=editorials.get(f"{kind}:{historical.key}"),
                related_papers=related_papers,
            )
    payloads["index"] = index_payload(
        periods,
        events,
        repo,
        month_archive,
        editorials,
        complete_archive if full_history else None,
        related_papers,
    )
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


def publish_one(
    payload: dict[str, Any], api_url: str, token: str, *, missing_only: bool = False
) -> str:
    try:
        endpoint = api_url.rstrip("/") + "/v1/plugins/bulldocs/papers"
        current = current_source_doc(api_url, payload["slug"])
        if missing_only and current is not None:
            return f"preserved /papers/{payload['slug']}"
        if current == payload["source_doc"]:
            return f"unchanged /papers/{payload['slug']}"
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(payload, separators=(",", ":")).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            receipt = json.load(response)
        return f"published {receipt['liveview_path']} rev {receipt['rev']}"
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(
            f"/papers/{payload['slug']}: HTTP {exc.code}: {detail}"
        ) from exc


def publish(
    payloads: Iterable[dict[str, Any]],
    api_url: str,
    token: str,
    workers: int = 6,
    update_slugs: set[str] | None = None,
) -> None:
    ordered = list(payloads)
    indexes = [payload for payload in ordered if payload["slug"] == "barkpark-chronicle"]
    editions = [payload for payload in ordered if payload["slug"] != "barkpark-chronicle"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        if update_slugs is None:
            futures = [executor.submit(publish_one, payload, api_url, token) for payload in editions]
        else:
            futures = [
                executor.submit(
                    publish_one,
                    payload,
                    api_url,
                    token,
                    missing_only=payload["slug"] not in update_slugs,
                )
                for payload in editions
            ]
        for future in concurrent.futures.as_completed(futures):
            print(future.result(), file=sys.stderr)
    for payload in indexes:
        print(publish_one(payload, api_url, token), file=sys.stderr)


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
    parser.add_argument(
        "--history-months",
        type=int,
        default=DEFAULT_HISTORY_MONTHS,
        metavar="N",
        help=f"also emit the newest N active monthly chapters (default {DEFAULT_HISTORY_MONTHS}; zero disables backfill)",
    )
    parser.add_argument(
        "--full-history",
        action="store_true",
        help="emit every active day, ISO week, month, and year Paper",
    )
    parser.add_argument("--output-dir", type=pathlib.Path)
    parser.add_argument(
        "--editorial-provider",
        choices=("off", "anthropic", "claude"),
        default="off",
        help="add one AI editorial pass to the current day/week/month/year family",
    )
    parser.add_argument(
        "--editorial-all",
        action="store_true",
        help="with --full-history, write every active historical edition in bounded editorial batches",
    )
    parser.add_argument("--publish", action="store_true")
    parser.add_argument(
        "--preserve-history",
        action="store_true",
        help="publish missing historical editions while updating only the current family and index",
    )
    parser.add_argument(
        "--publish-workers",
        type=int,
        default=6,
        metavar="N",
        help="bounded concurrent edition publishes; the Chronicle index is always last (default 6)",
    )
    parser.add_argument("--api-url", default=os.environ.get("BARKPARK_API_URL") or "https://guerrilla.barkpark.cloud")
    args = parser.parse_args()
    try:
        if args.history_months < 0:
            raise RuntimeError("--history-months must be zero or greater")
        if args.publish_workers < 1:
            raise RuntimeError("--publish-workers must be one or greater")
        events = events_through(read_events(args.ref), args.date)
        periods = periods_for(args.date)
        if args.editorial_all and not args.full_history:
            raise RuntimeError("--editorial-all requires --full-history")
        if args.editorial_all and args.editorial_provider == "off":
            raise RuntimeError("--editorial-all requires --editorial-provider")
        if args.editorial_all:
            editorials = generate_archive_editorials(
                events,
                historical_periods(events, args.date),
                args.editorial_provider,
            )
        elif args.editorial_provider != "off":
            editorials = generate_current_editorials(events, periods, args.editorial_provider)
        else:
            editorials = {}
        payloads = build(
            args.date,
            args.ref,
            args.repo,
            args.history_months,
            args.full_history,
            events=events,
            editorials=editorials,
        )
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
            update_slugs = None
            if args.preserve_history:
                update_slugs = {period.slug for period in periods.values()}
                update_slugs.add("barkpark-chronicle")
            publish(selected, args.api_url, token, args.publish_workers, update_slugs)
    except (RuntimeError, subprocess.CalledProcessError, urllib.error.URLError) as exc:
        print(f"chronicle-paper: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
