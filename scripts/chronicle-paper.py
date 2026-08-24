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


RENDERER_VERSION = "chronicle-editorial-14"
EDITORIAL_SCHEMA = "barkpark.chronicle-editorial.v1"
ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
EDITORIAL_MODEL = "claude-sonnet-4-6"
LEDGER_PREVIEW_LIMIT = 24
DEFAULT_HISTORY_MONTHS = 18
DEFAULT_REPO = "FRIKKern/barkpark"
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
    """Return every active day, ISO week, month, and year through ``through``."""
    periods: dict[str, dict[str, Period]] = {
        "day": {},
        "week": {},
        "month": {},
        "year": {},
    }
    for event in events:
        event_day = event.occurred_at.date()
        if event_day > through:
            continue
        for kind, period in periods_for(event_day).items():
            periods[kind][period.key] = period
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
            "theme": f"A quiet {period.kind}, kept visible",
            "standfirst": "No mainline work landed in this interval. The empty edition remains part of the record so silence is not mistaken for missing data.",
            "review": "There is no shipped movement to interpret in this edition. That is a useful fact in its own right, and the surrounding archive provides the longer view.",
            "stories": [],
            "audiences": [
                {"label": "For the team", "text": "The calendar stays complete and honest."},
                {"label": "For stakeholders", "text": "No release claim is being manufactured from an empty interval."},
                {"label": "For readers", "text": "Adjacent editions remain available for the latest substantive progress."},
            ],
            "watchlist": "The next edition should be judged on shipped evidence, not inferred activity.",
            "next_horizon": "The Chronicle will resume its progress review when the mainline record moves again.",
            "mode": "deterministic",
        }

    areas = collections.Counter(event.area for event in selected)
    lead_areas = [area for area, _count in areas.most_common(3)]
    product = [event for event in selected if event.kind in PRODUCT_KINDS]
    candidates = list(reversed(product or selected))
    stories = []
    used_areas: set[str] = set()
    for event in candidates:
        if event.area in used_areas and len(stories) < min(3, len(lead_areas)):
            continue
        effect = {
            "feat": "This expands what Barkpark can do in everyday use.",
            "fix": "This removes a failure path and makes the product more dependable.",
            "perf": "This makes the experience faster or less wasteful under load.",
            "revert": "This restores the safer known behavior while the direction is reconsidered.",
        }.get(event.kind, "This strengthens the operating foundation behind the product.")
        stories.append(
            {
                "title": sentence_case(event.title),
                "narrative": effect,
                "source_refs": [event.sha[:10]],
            }
        )
        used_areas.add(event.area)
        if len(stories) == 3:
            break

    area_phrase = ", ".join(sentence_case(area) for area in lead_areas[:-1])
    if len(lead_areas) > 1:
        area_phrase = f"{area_phrase} and {sentence_case(lead_areas[-1])}"
    else:
        area_phrase = sentence_case(lead_areas[0])
    fix_heavy = sum(event.kind == "fix" for event in selected) >= max(1, len(selected) // 2)
    theme = (
        f"Making {area_phrase} more dependable"
        if fix_heavy
        else f"Moving {area_phrase} forward"
    )
    return {
        "theme": theme,
        "standfirst": signal(period, selected) + " The important story is how those changes reduce friction and strengthen the product's operating footing.",
        "review": (
            "This was a reliability-led edition: the work concentrated on making failure visible, bounded, and recoverable."
            if fix_heavy
            else "This edition combined visible product movement with the supporting work needed to make it hold up in practice."
        ),
        "stories": stories,
        "audiences": [
            {"label": "For the team", "text": "Clearer boundaries and fewer silent failures make the next increment easier to operate."},
            {"label": "For stakeholders", "text": "The period shows progress through shipped, inspectable changes rather than activity alone."},
            {"label": "For readers", "text": "The practical result is a product that behaves more predictably in ordinary and difficult cases."},
        ],
        "watchlist": "Breadth can hide unfinished edges; the source ledger remains the test of what actually shipped.",
        "next_horizon": "The next useful signal is whether this firmer foundation turns into simpler, more confident product use.",
        "mode": "deterministic",
    }


def validate_editorial(raw: Any, period: Period, selected: list[Event]) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("editorial edition must be an object")
    valid_refs = {event.sha[:10] for event in representative_events(selected)}
    stories_raw = raw.get("stories")
    audiences_raw = raw.get("audiences")
    if not isinstance(stories_raw, list) or not 2 <= len(stories_raw) <= 4:
        raise ValueError("editorial edition needs 2–4 progress stories")
    if not isinstance(audiences_raw, list) or len(audiences_raw) != 3:
        raise ValueError("editorial edition needs exactly three audience lenses")
    stories = []
    for story in stories_raw:
        refs = story.get("source_refs") if isinstance(story, dict) else None
        if not isinstance(refs, list) or not refs or not set(refs) <= valid_refs:
            raise ValueError("every progress story must cite supplied sources")
        stories.append(
            {
                "title": clean_editorial_text(story.get("title"), limit=90),
                "narrative": clean_editorial_text(story.get("narrative"), limit=520),
                "source_refs": refs[:3],
            }
        )
    audiences = [
        {
            "label": clean_editorial_text(item.get("label"), limit=32),
            "text": clean_editorial_text(item.get("text"), limit=360),
        }
        for item in audiences_raw
        if isinstance(item, dict)
    ]
    if len(audiences) != 3:
        raise ValueError("invalid audience lens")
    return {
        "theme": clean_editorial_text(raw.get("theme"), limit=80),
        "standfirst": clean_editorial_text(raw.get("standfirst"), limit=520),
        "review": clean_editorial_text(raw.get("review"), limit=800),
        "stories": stories,
        "audiences": audiences,
        "watchlist": clean_editorial_text(raw.get("watchlist"), limit=520),
        "next_horizon": clean_editorial_text(raw.get("next_horizon"), limit=520),
        "mode": "ai",
    }


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
You are the editor of Barkpark Chronicle, a premium product progress publication.
Turn the supplied verified Git evidence into an intelligent review that a project
manager, stakeholder, investor, contributor, and ordinary reader can understand.

Write with calm editorial judgment. Explain the connective story and practical
meaning; do not paraphrase a list of commits. Do not use hype. Do not invent or
imply metrics, customers, revenue, adoption, dates, deadlines, security guarantees,
or future promises. Use no digits anywhere in prose. A watchlist is an honest
uncertainty, not a defect claim. A next horizon is a signal to watch, not a roadmap.
Respect each packet's period status. Never describe an in-progress week, month, or
year as closed, complete, ending, or finished; write “to date” when the distinction matters.

Return only JSON with this exact outer shape, with one edition object for every
kind supplied in the source packets:
{"schema":"barkpark.chronicle-editorial.v1","editions":{"day":{"theme":"","standfirst":"","review":"","stories":[{"title":"","narrative":"","source_refs":["exact supplied ref"]}],"audiences":[{"label":"For the team","text":""},{"label":"For stakeholders","text":""},{"label":"For readers","text":""}],"watchlist":"","next_horizon":""}}}
Each supplied edition needs two to four distinct stories, and every story must cite one to
three exact refs from that edition's supplied sources. Scale the judgment: day is
immediate effect, week is direction, month is durable progress, year is the arc.
Keep the theme under eight words, standfirst under forty-five words, review under
eighty words, each story under fifty-five words, each audience lens under thirty-five
words, and the watchlist and next horizon under forty-five words each.

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
        print(f"chronicle-paper: editorial generation fell back safely: {exc}", file=sys.stderr)
        return {}
    valid: dict[str, dict[str, Any]] = {}
    for kind in active_kinds:
        try:
            valid[kind] = validate_editorial(raw[kind], periods[kind], selected_by_kind[kind])
        except (KeyError, ValueError) as exc:
            print(f"chronicle-paper: {kind} editorial fell back safely: {exc}", file=sys.stderr)
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
        items.append(
            [
                link(period.title, f"/papers/{period.slug}"),
                text(f" · {count:,} verified mainline changes"),
            ]
        )
    return {"id": block_id, "type": "list", "ordered": False, "items": items}


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
                    "body": [{"type": "paragraph", "content": [text(story["narrative"])]}],
                    "action": [
                        {
                            "type": "action",
                            "label": "See the shipped work" if len(sources) > 1 else "View source",
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


def editorial_audience_section(block_id: str, audiences: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "id": block_id,
        "type": "section",
        "layout": {"mode": "grid", "tracks": 1},
        "blocks": [
            {
                "id": f"{block_id}:card-{index + 1}",
                "type": "card",
                "tone": ("info", "ok", "info")[index],
                "slots": {
                    "title": [{"type": "heading", "level": 3, "text": item["label"]}],
                    "body": [{"type": "paragraph", "content": [text(item["text"])]}],
                },
            }
            for index, item in enumerate(audiences)
        ],
    }


def child_archive_blocks(
    period: Period,
    selected: list[Event],
    events: list[Event],
    archive: dict[str, list[Period]],
) -> list[dict[str, Any]]:
    sections: list[tuple[str, str, list[Period]]] = []
    if period.kind == "year":
        children = [child for child in archive["month"] if period.start <= child.start < period.end]
        sections.append(("Monthly chapters", "Every active month in this annual volume.", children))
    elif period.kind == "month":
        week_keys = {periods_for(event.occurred_at.date())["week"].key for event in selected}
        weeks = [child for child in archive["week"] if child.key in week_keys]
        days = [child for child in archive["day"] if period.start <= child.start < period.end]
        sections.extend(
            [
                ("Weekly dispatches", "ISO-week views touching this month, including boundary weeks.", weeks),
                ("Daily shiplogs", "Every active mainline day in this monthly chapter.", days),
            ]
        )
    elif period.kind == "week":
        days = [child for child in archive["day"] if period.start <= child.start < period.end]
        sections.append(("Daily shiplogs", "Every active mainline day in this weekly dispatch.", days))

    blocks: list[dict[str, Any]] = []
    for index, (title_value, description, children) in enumerate(sections):
        if not children:
            continue
        suffix = str(index + 1)
        blocks.extend(
            [
                {"id": f"auto:divider-archive-{suffix}", "type": "divider"},
                heading(f"auto:archive-title-{suffix}", 2, title_value),
                paragraph(f"auto:archive-dek-{suffix}", description),
                archive_list(f"auto:archive-{suffix}", children, events),
            ]
        )
    return blocks


def period_payload(
    period: Period,
    selected: list[Event],
    periods: dict[str, Period],
    repo: str,
    *,
    events: list[Event] | None = None,
    archive: dict[str, list[Period]] | None = None,
    editorial: dict[str, Any] | None = None,
) -> dict[str, Any]:
    editorial = editorial or deterministic_editorial(period, selected)
    product = [event for event in selected if event.kind in PRODUCT_KINDS]
    areas = collections.Counter(event.area for event in selected)
    folio_parts = edition_folio(period, selected).split("-")
    display_titles = {
        "day": (
            f"{editorial['theme']} — {period.start.strftime('%d %B %Y').lstrip('0')} · Edition "
            f"{period.start.timetuple().tm_yday:03d}-{folio_parts[0]}-{folio_parts[1]}"
        ),
        "week": (
            f"{editorial['theme']} — Week {period.key.split('-W')[-1]} · {period.start.strftime('%d %b')}–"
            f"{(period.end - dt.timedelta(days=1)).strftime('%d %b %Y')} · Dispatch "
            f"w{period.start.isocalendar()[1]:03d}-{folio_parts[0]}-{folio_parts[1]}"
        ),
        "month": (
            f"{editorial['theme']} — {period.title} · Volume {period.start.month:03d}-{folio_parts[0]}-{folio_parts[1]}"
        ),
        "year": f"{editorial['theme']} — Barkpark in {period.title} · Annual {period.title}-{folio_parts[0]}-{folio_parts[1]}",
    }
    date_range = f"{period.start.strftime('%d %b')}–{(period.end - dt.timedelta(days=1)).strftime('%d %b %Y')}"
    through_date = selected[-1].occurred_at.date() if selected else min(
        dt.datetime.now(dt.timezone.utc).date(), period.end - dt.timedelta(days=1)
    )
    profile = collections.Counter(event.kind for event in selected)
    dominant_kind = profile.most_common(1)[0][0] if profile else "quiet"
    area_limit = 6 if period.kind == "month" else 3
    sequence_limit = 10 if period.kind == "month" else 5
    ledger_limit = 40 if period.kind == "month" else LEDGER_PREVIEW_LIMIT
    blocks: list[dict[str, Any]] = navigation_blocks(periods, period.kind)
    blocks.extend(
        [
            {"id": "auto:identity", "type": "eyebrow", "text": f"BARKPARK CHRONICLE · {period.kind.upper()} · {period.key}"},
            heading("auto:title", 1, display_titles[period.kind]),
            {"id": "auto:ingress", "type": "ingress", "content": [text(editorial["standfirst"])]},
            paragraph("auto:dek", "A plain-language review of what moved, why it matters, and what the evidence suggests watching next."),
            {"id": "auto:byline", "type": "byline", "items": [date_range, "Source-grounded review", f"Through {through_date.strftime('%d %B %Y').lstrip('0')}" ]},
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
            {"id": "auto:divider-review", "type": "divider"},
            heading("auto:review-title", 2, f"The {period.kind} in review"),
            {
                "id": "auto:review",
                "type": "callout",
                "tone": "info",
                "title": "Editorial read",
                "content": [text(editorial["review"])],
            },
            heading("auto:progress-title", 2, "What moved forward"),
            paragraph("auto:progress-dek", "The most consequential threads in the period, translated from implementation into practical progress."),
            editorial_story_section("auto:progress-stories", editorial["stories"], selected, repo)
            if editorial["stories"]
            else paragraph("auto:progress-stories", "No shipped movement to review in this interval."),
            heading("auto:audience-title", 2, "Why this matters"),
            paragraph("auto:audience-dek", "The same progress, viewed from the people planning, backing, and using the product."),
            editorial_audience_section("auto:audiences", editorial["audiences"]),
            {
                "id": "auto:watchlist",
                "type": "callout",
                "tone": "warn",
                "title": "What we’re watching",
                "content": [text(editorial["watchlist"])],
            },
            heading("auto:horizon-title", 2, "The next horizon"),
            paragraph("auto:horizon", editorial["next_horizon"]),
            {"id": "auto:divider-shape", "type": "divider"},
            heading("auto:shape-title", 2, "The evidence behind the story"),
            paragraph("auto:shape-dek", "The programmatic record keeps the editorial review honest: what shipped, where it landed, and how the period was distributed."),
            change_profile("auto:change-profile", selected, f"Updates by category · {period.key}"),
            area_cards("auto:areas", selected, repo, limit=area_limit),
            {"id": "auto:divider-sequence", "type": "divider"},
            heading("auto:sequence-title", 2, "Latest updates"),
            paragraph("auto:sequence-dek", f"The {min(sequence_limit, len(selected))} newest changes in this edition, with source links."),
            event_lineage("auto:sequence", selected, repo, limit=sequence_limit),
            {"id": "auto:divider-ledger", "type": "divider"},
            heading("auto:ledger-title", 2, "Complete release log"),
        ]
    )
    if period.kind == "month":
        product_signals = [event for event in selected if event.kind in PRODUCT_KINDS]
        insertion = blocks.index(next(block for block in blocks if block["id"] == "auto:divider-sequence"))
        blocks[insertion:insertion] = [
            {"id": "auto:divider-cadence", "type": "divider"},
            heading("auto:cadence-title", 2, "How the month unfolded"),
            paragraph("auto:cadence-dek", "A week-by-week view of the month, useful for spotting shipping bursts and quieter stretches."),
            weekly_activity("auto:weekly-cadence", selected, period),
            heading("auto:product-title", 2, "Product updates"),
            paragraph("auto:product-dek", "The newest features, fixes, performance improvements, and restorations from this month."),
            event_lineage("auto:product-signals", product_signals, repo, limit=8),
        ]
    if events is not None and archive is not None:
        insertion = blocks.index(next(block for block in blocks if block["id"] == "auto:divider-ledger"))
        blocks[insertion:insertion] = child_archive_blocks(period, selected, events, archive)
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
                f"Generated from first-parent Git history for {period.start.isoformat()} through {(period.end - dt.timedelta(days=1)).isoformat()} UTC · {editorial['mode']} editorial review · renderer {RENDERER_VERSION} · digest {digest(selected)}.",
            ),
        ]
    )
    payload = {
        "_id": period.slug,
        "slug": period.slug,
        "title": display_titles[period.kind],
        "description": f"A source-grounded review of Barkpark progress in {period.title}, with reader impact, watchpoints, and the complete release record.",
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
    day_editorial = editorials.get("day") or deterministic_editorial(periods["day"], current_day)
    edition_cards = []
    edition_copy = {
        "day": (
            "Latest release",
            latest_day,
            f"{latest_day.title} · {sentence_case(latest.title) if latest else 'No release yet'}",
            "Read the latest notes",
        ),
        "week": (
            "This week",
            periods["week"],
            f"Week {periods['week'].key.split('-W')[-1]} · {len(current_week):,} updates so far",
            "Open the weekly roundup",
        ),
        "month": (
            f"{periods['month'].title.split()[0]} roundup",
            periods["month"],
            "Highlights, release mix, and every source-backed change this month",
            "Explore the month",
        ),
        "year": (
            f"{periods['year'].key} archive",
            periods["year"],
            "The complete year in releases, organized month by month",
            "Browse the year",
        ),
    }
    for kind in ("day", "week", "month", "year"):
        title_value, period, copy, label = edition_copy[kind]
        edition_cards.append(
            {
                "title": title_value,
                "text": copy,
                "href": f"/papers/{period.slug}",
                "label": label,
                "tone": "ok" if kind == "day" else "info",
            }
        )
    all_digest = digest(events)
    lead = day_editorial["standfirst"]
    monthly = collections.Counter(event.occurred_at.month for event in current_year)
    first_active_month = min(monthly) if monthly else periods["month"].start.month
    month_bars = [
        {"label": dt.date(periods["year"].start.year, month, 1).strftime("%b"), "value": monthly[month]}
        for month in range(first_active_month, periods["month"].start.month + 1)
    ]
    archive_cards = []
    for month in reversed(month_archive):
        selected = events_in_period(events, month)
        month_product = sum(event.kind in PRODUCT_KINDS for event in selected)
        month_areas = collections.Counter(event.area for event in selected)
        lead_area = month_areas.most_common(1)[0][0] if month_areas else "quiet"
        archive_cards.append(
            {
                "title": month.title,
                "text": (
                    f"{month_product:,} product {'update' if month_product == 1 else 'updates'} across "
                    f"{len(month_areas):,} {'area' if len(month_areas) == 1 else 'areas'} · "
                    f"{len(selected):,} source-backed {'change' if len(selected) == 1 else 'changes'}"
                ),
                "href": f"/papers/{month.slug}",
                "label": f"Read {month.title}",
                "tone": "info",
            }
        )
    latest_card = [
        {
            "title": day_editorial["theme"],
            "text": (
                f"Today’s editorial review · latest source: {sentence_case(latest.title)}"
                if latest
                else "No release has been recorded yet."
            ),
            "href": f"/papers/{latest_day.slug}",
            "label": "Read the release",
            "tone": "ok",
        }
    ]
    blocks = [
        {"id": "auto:masthead", "type": "eyebrow", "text": f"BARKPARK CHANGELOG · {periods['year'].key} · UPDATED CONTINUOUSLY"},
        heading("auto:title", 1, "What’s new in Barkpark"),
        {"id": "auto:ingress", "type": "ingress", "content": [text(lead)]},
        paragraph("auto:dek", "Follow the latest release, catch up on a week, or explore the complete archive. Every note is generated from shipped work and linked to its source."),
        {"id": "auto:byline", "type": "byline", "items": [f"Updated {periods['day'].title}", "Verified release history", "Day · week · month · year"]},
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
        {
            "id": "auto:today-review",
            "type": "callout",
            "tone": "info",
            "title": "Today in review",
            "content": [text(day_editorial["review"])],
        },
        {"id": "auto:divider-featured", "type": "divider"},
        heading("auto:featured-title", 2, "Latest release"),
        paragraph("auto:featured-dek", "The newest shipped change, with the full daily edition one click away."),
        linked_card_section("auto:featured", latest_card, tracks=1),
        {"id": "auto:divider-editions", "type": "divider"},
        heading("auto:editions-title", 2, "Browse the changelog"),
        paragraph("auto:editions-dek", "Choose the level of detail that fits the moment—from one release day to the whole year."),
        linked_card_section("auto:periods", edition_cards, tracks=2),
        {"id": "auto:divider-archive", "type": "divider"},
        heading("auto:archive-title", 2, "Release archive"),
        paragraph("auto:archive-dek", "Every monthly roundup, newest first. Open any edition for highlights, categories, and the complete release log."),
        linked_card_section("auto:month-archive", archive_cards, tracks=2),
        {"id": "auto:divider-motion", "type": "divider"},
        heading("auto:motion-title", 2, "Shipping activity"),
        paragraph("auto:motion-dek", f"A month-by-month view of {periods['year'].key}. Volume shows cadence, not quality."),
        {"id": "auto:motion", "type": "bar-chart", "title": "Updates by month", "bars": month_bars, "values": True},
        heading("auto:areas-title", 2, "Product areas improved"),
        area_cards("auto:areas", current_year, repo, limit=4),
        {"id": "auto:divider-latest", "type": "divider"},
        heading("auto:latest-title", 2, "Recently shipped"),
        paragraph("auto:latest-dek", "The five newest changes, linked directly to the pull request or commit behind each release."),
        event_lineage("auto:latest", events, repo),
    ]
    blocks.extend(
        [
            {"id": "auto:divider-provenance", "type": "divider"},
            paragraph("auto:provenance", f"Verified from {len(events):,} first-parent mainline changes · renderer {RENDERER_VERSION} · source digest {all_digest} · every edition has a stable Paper URL."),
        ]
    )
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
) -> dict[str, dict[str, Any]]:
    events = events_through(events if events is not None else read_events(ref), day)
    editorials = editorials or {}
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
            editorial=editorials.get(kind),
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
            )
    payloads["index"] = index_payload(periods, events, repo, month_archive, editorials)
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


def publish_one(payload: dict[str, Any], api_url: str, token: str) -> str:
    try:
        endpoint = api_url.rstrip("/") + "/v1/plugins/bulldocs/papers"
        if current_source_doc(api_url, payload["slug"]) == payload["source_doc"]:
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
) -> None:
    ordered = list(payloads)
    indexes = [payload for payload in ordered if payload["slug"] == "barkpark-chronicle"]
    editions = [payload for payload in ordered if payload["slug"] != "barkpark-chronicle"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(publish_one, payload, api_url, token) for payload in editions]
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
    parser.add_argument("--publish", action="store_true")
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
        editorials = (
            generate_current_editorials(events, periods, args.editorial_provider)
            if args.editorial_provider != "off"
            else {}
        )
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
            publish(selected, args.api_url, token, args.publish_workers)
    except (RuntimeError, subprocess.CalledProcessError, urllib.error.URLError) as exc:
        print(f"chronicle-paper: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
