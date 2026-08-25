#!/usr/bin/env python3

import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "chronicle-paper.py"
SPEC = importlib.util.spec_from_file_location("chronicle_paper", SCRIPT)
chronicle = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = chronicle
SPEC.loader.exec_module(chronicle)


class ChroniclePaperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temp.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test Author")
        self.git("config", "user.email", "test@example.com")
        self.commit("2026-07-31T23:00:00Z", "chore: july close")
        self.commit("2026-08-17T09:00:00Z", "feat(api): add typed exports (#12)")
        self.commit("2026-08-18T10:00:00+02:00", "fix(tui): restore tasks (#13)")
        self.commit("2026-08-23T19:00:00Z", "docs: explain the chronicle")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args, env=None):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=env, text=True)

    def commit(self, timestamp, subject):
        marker = self.repo / "history.txt"
        marker.write_text((marker.read_text() if marker.exists() else "") + subject + "\n")
        self.git("add", "history.txt")
        env = os.environ.copy()
        env["GIT_AUTHOR_DATE"] = timestamp
        env["GIT_COMMITTER_DATE"] = timestamp
        self.git("commit", "-m", subject, env=env)

    def commit_file(self, timestamp, subject, relative_path, content="evidence"):
        target = self.repo / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        self.git("add", relative_path)
        env = os.environ.copy()
        env["GIT_AUTHOR_DATE"] = timestamp
        env["GIT_COMMITTER_DATE"] = timestamp
        self.git("commit", "-m", subject, env=env)

    def run_script(self, *args, check=True):
        return subprocess.run(
            ["python3", str(SCRIPT), *args], cwd=self.repo, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check,
        )

    def read_fixture_events(self):
        previous = pathlib.Path.cwd()
        os.chdir(self.repo)
        try:
            return chronicle.read_events("main")
        finally:
            os.chdir(previous)

    def test_builds_five_native_papers_from_one_calendar_graph(self):
        output = self.run_script(
            "--date", "2026-08-23", "--ref", "main", "--repo", "acme/project",
            "--history-months", "0",
        ).stdout
        payloads = json.loads(output)
        by_slug = {payload["slug"]: payload for payload in payloads}
        self.assertEqual(5, len(by_slug))
        self.assertIn("barkpark-chronicle", by_slug)
        self.assertIn("barkpark-changelog-2026-08-23", by_slug)
        self.assertIn("barkpark-changelog-2026-w34", by_slug)
        self.assertIn("barkpark-changelog-2026-08", by_slug)
        self.assertIn("barkpark-changelog-2026", by_slug)
        week = by_slug["barkpark-changelog-2026-w34"]
        self.assertEqual("changelog.week", week["event_type"])
        self.assertEqual("article", week["style"])
        self.assertEqual("article-wide", by_slug["barkpark-changelog-2026-08"]["style"])
        self.assertEqual("article-wide", by_slug["barkpark-changelog-2026"]["style"])
        month_blocks = {block["id"]: block for block in by_slug["barkpark-changelog-2026-08"]["blocks"]}
        self.assertEqual("lineage", month_blocks["auto:archive-1"]["type"])
        self.assertEqual("expandable", month_blocks["auto:archive-2"]["type"])
        self.assertEqual(["barkpark", "docs"], [tag["tag"] for tag in week["tags"]])
        serialized = json.dumps(week)
        self.assertIn("https://github.com/acme/project/pull/12", serialized)
        self.assertIn("https://github.com/acme/project/pull/13", serialized)
        self.assertIn('"type": "bar-chart"', serialized)
        self.assertIn('"type": "lineage"', serialized)
        self.assertIn('"text": "The week\\u2019s defining work"', serialized)
        self.assertIn('"text": "How this period moved"', serialized)
        self.assertIn('"type": "expandable"', serialized)
        self.assertIn('"type": "paper-links"', serialized)
        self.assertIn("task-components-editable-demo", serialized)
        self.assertIn('"summary": "Technical record and source evidence"', serialized)
        self.assertNotIn('"text": "Why this matters"', serialized)
        week_h1 = next(block for block in week["blocks"] if block["id"] == "auto:title")
        self.assertEqual(week["title"], week_h1["text"])
        self.assertRegex(week_h1["text"], r".* — Week 34$")
        index = by_slug["barkpark-chronicle"]
        serialized_index = json.dumps(index)
        self.assertIn("/papers/barkpark-changelog-2026-w34", serialized_index)
        self.assertIn('"text": "What\\u2019s new in Barkpark"', serialized_index)
        self.assertIn('"text": "Today in Barkpark"', serialized_index)
        self.assertIn('"text": "Choose your view"', serialized_index)
        self.assertIn('"type": "columns"', serialized_index)
        self.assertIn('Read today\\u2019s edition \\u2192', serialized_index)
        self.assertIn('"summary": "Shipping record and source evidence"', serialized_index)
        self.assertNotIn('"type": "action"', serialized_index)
        self.assertNotIn('"id": "auto:featured", "type": "section"', serialized_index)
        self.assertNotIn("source-backed", serialized_index)
        self.assertIn("https://github.com/acme/project/pull/13", serialized_index)

    def test_backfills_active_months_and_builds_a_richer_month_archive(self):
        output = self.run_script(
            "--date", "2026-08-23",
            "--ref", "main",
            "--repo", "acme/project",
            "--history-months", "12",
        ).stdout
        payloads = json.loads(output)
        by_slug = {payload["slug"]: payload for payload in payloads}

        # The current five projections plus July's historical monthly chapter.
        self.assertEqual(6, len(by_slug))
        july = by_slug["barkpark-changelog-2026-07"]
        july_json = json.dumps(july, ensure_ascii=False)
        self.assertIn("July, week by week", july_json)
        self.assertNotIn("August, week by week", july_json)
        self.assertIn("How the period unfolded", july_json)
        self.assertIn("Weekly cadence · July 2026", july_json)
        self.assertIn("Release highlights", july_json)
        self.assertIn('"id": "auto:period-pulse"', july_json)
        self.assertTrue(july["dedup_bypass"])

        index_json = json.dumps(by_slug["barkpark-chronicle"])
        self.assertIn("Release archive", index_json)
        self.assertIn("/papers/barkpark-changelog-2026-07", index_json)
        self.assertIn("/papers/barkpark-changelog-2026-08", index_json)

    def test_historical_build_reads_git_once(self):
        events = self.read_fixture_events()
        with mock.patch.object(chronicle, "read_events", return_value=events) as read_events:
            payloads = chronicle.build(dt.date(2026, 8, 23), "main", "acme/project", 12)
        self.assertEqual(1, read_events.call_count)
        self.assertIn("month:2026-07", payloads)

    def test_full_history_builds_every_calendar_period_and_links_every_paper_from_index(self):
        events = self.read_fixture_events()
        with mock.patch.object(chronicle, "read_events", return_value=events) as read_events:
            payloads = chronicle.build(
                dt.date(2026, 8, 23),
                "main",
                "acme/project",
                full_history=True,
            )

        self.assertEqual(1, read_events.call_count)
        by_slug = {payload["slug"]: payload for payload in payloads.values()}
        # 24 calendar days + four ISO weeks + two months + one year + index.
        self.assertEqual(32, len(by_slug))
        self.assertEqual(len(payloads), len(by_slug))
        self.assertIn("barkpark-changelog-2026-08-01", by_slug)
        self.assertIn("barkpark-changelog-2026-w32", by_slug)
        self.assertIn("barkpark-changelog-2026-w33", by_slug)
        quiet = by_slug["barkpark-changelog-2026-08-01"]
        self.assertIn("A quiet day", quiet["title"])
        self.assertIn("Nothing new shipped", json.dumps(quiet))
        self.assertTrue(
            all(
                payload.get("dedup_bypass") is True
                for slug, payload in by_slug.items()
                if slug != "barkpark-chronicle"
            )
        )

        year_json = json.dumps(by_slug["barkpark-changelog-2026"])
        self.assertIn("The year, month by month", year_json)
        self.assertIn('"slug": "barkpark-changelog-2026-07"', year_json)
        self.assertIn('"slug": "barkpark-changelog-2026-08"', year_json)

        august_json = json.dumps(by_slug["barkpark-changelog-2026-08"])
        self.assertIn("August, week by week", august_json)
        self.assertIn("Open all 23 daily editions", august_json)
        self.assertIn('"source": "/papers/barkpark-changelog-2026-w34"', august_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-17", august_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-23", august_json)

        week_json = json.dumps(by_slug["barkpark-changelog-2026-w34"])
        self.assertIn("/papers/barkpark-changelog-2026-08-17", week_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-18", week_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-23", week_json)

        index_json = json.dumps(by_slug["barkpark-chronicle"])
        for slug in by_slug:
            if slug != "barkpark-chronicle":
                self.assertIn(f"/papers/{slug}", index_json, slug)

    def test_full_history_cli_writes_one_file_per_unique_paper(self):
        output_dir = self.repo / "chronicle"
        self.run_script(
            "--date", "2026-08-23",
            "--ref", "main",
            "--repo", "acme/project",
            "--full-history",
            "--output-dir", str(output_dir),
        )
        self.assertEqual(32, len(list(output_dir.glob("*.json"))))

    def test_changed_visual_evidence_becomes_a_commit_pinned_figure(self):
        self.commit_file(
            "2026-08-24T10:00:00Z",
            "feat(tasks): show claimed work beside ready work (#14)",
            "docs/evidence/tasks-board.png",
        )
        events = self.read_fixture_events()
        event = events[-1]
        self.assertIn("docs/evidence/tasks-board.png", event.paths)
        period = chronicle.periods_for(dt.date(2026, 8, 24))["day"]
        payload = chronicle.period_payload(
            period,
            [event],
            chronicle.periods_for(period.start),
            "acme/project",
        )
        figures = [block for block in payload["blocks"] if block.get("type") == "figure"]
        self.assertEqual(1, len(figures))
        image = figures[0]["child"]
        self.assertEqual("image", image["type"])
        self.assertIn(f"/acme/project/{event.sha}/docs/evidence/tasks-board.png", image["src"])
        self.assertNotIn("tasks-board.png", image["alt"])

    def test_month_composes_restrained_native_visual_evidence(self):
        paths = tuple(
            [
                "docs/evidence/product-overview-light.png",
                "docs/evidence/product-overview-dark.png",
            ]
            + [f"docs/evidence/product-moment-{index}.png" for index in range(1, 10)]
            + [f"docs/evidence/demo-{index}.cast" for index in range(1, 4)]
        )
        event = chronicle.Event(
            dt.datetime(2026, 8, 24, tzinfo=dt.timezone.utc),
            "f" * 40,
            "feat(papers): show the release story with real product evidence (#44)",
            paths,
        )
        period = chronicle.periods_for(dt.date(2026, 8, 24))["month"]
        blocks = chronicle.evidence_blocks(period, [event], "acme/project")
        gallery = next(block for block in blocks if block.get("id") == "auto:evidence-gallery")
        lead = next(block for block in blocks if block.get("id") == "auto:evidence-lead")
        figures = [lead["columns"][1][0]] + gallery["blocks"]
        casts = [block for block in blocks if block.get("type") == "asciicast"]

        self.assertEqual("The month in motion", lead["columns"][0][0]["text"])
        self.assertEqual(4, len(figures))
        self.assertEqual(1, len(casts))
        self.assertEqual("columns", lead["type"])
        self.assertFalse(any(block.get("type") == "figure" for block in blocks))
        self.assertEqual(2, gallery["layout"]["tracks"])
        serialized = json.dumps(blocks)
        self.assertEqual(1, serialized.count("product-overview-"))
        self.assertIn("24 Aug · Papers", figures[0]["caption"])
        self.assertNotIn("Real release evidence", serialized)
        self.assertNotIn("Watch it move", serialized)

    def test_media_selection_is_deterministic_and_diverse_before_repeats(self):
        start = dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc)
        events = [
            chronicle.Event(start, "1" * 40, "feat(tasks): show ready work", (
                "docs/evidence/tasks-overview-light.png",
                "docs/evidence/tasks-overview-dark.png",
                "docs/evidence/tasks-second.png",
            )),
            chronicle.Event(start + dt.timedelta(days=1), "2" * 40, "fix(tasks): restore claimed work", (
                "docs/evidence/tasks-restored.png",
            )),
            chronicle.Event(start + dt.timedelta(days=2), "3" * 40, "feat(papers): improve the reader", (
                "docs/evidence/paper-reader.png",
            )),
        ]

        first = chronicle.artifact_candidates(events)
        second = chronicle.artifact_candidates(events)
        reversed_paths = [events[0].__class__(
            events[0].occurred_at,
            events[0].sha,
            events[0].subject,
            tuple(reversed(events[0].paths)),
        ), *events[1:]]

        self.assertEqual(first, second)
        projection = lambda candidates: [
            (event.sha, path, kind) for event, path, kind in candidates
        ]
        self.assertEqual(projection(first), projection(chronicle.artifact_candidates(reversed_paths)))
        period = chronicle.periods_for(start.date())["month"]
        self.assertEqual(
            json.dumps(chronicle.evidence_blocks(period, events, "acme/project"), sort_keys=True),
            json.dumps(chronicle.evidence_blocks(period, reversed_paths, "acme/project"), sort_keys=True),
        )
        self.assertEqual(1, sum("tasks-overview-" in path for _event, path, _kind in first))
        self.assertEqual(3, len({event.sha for event, _path, _kind in first[:3]}))
        self.assertEqual(
            {"Papers", "Tasks"},
            {chronicle.reader_area(event.area) for event, _path, _kind in first[:2]},
        )

    def test_paper_excellence_document_captures_are_not_release_evidence(self):
        paths = (
            "tooling/paper-excellence/evidence/shots/whole-paper.png",
            "tooling/paper-excellence/rig/baselines/paper.png",
            "tooling/paper-excellence/twin/shots/paper.png",
            "tooling/paper-excellence/evidence/pe-w1-figure-legibility.png",
            "tooling/paper-excellence/evidence/reader-before.png",
            "tooling/paper-excellence/evidence/reader-diff.png",
            "tooling/paper-excellence/evidence/reader-failure.png",
            "tooling/paper-excellence/evidence/reader-probe.png",
            "tooling/paper-excellence/evidence/full.jpeg",
            "tooling/paper-excellence/evidence/light.jpeg",
            "tooling/paper-excellence/evidence/decl-premium.jpeg",
            "tooling/paper-excellence/evidence/cast.jpeg",
        )
        event = chronicle.Event(
            dt.datetime(2026, 8, 12, tzinfo=dt.timezone.utc),
            "a" * 40,
            "feat(papers): refine the paper reader",
            paths,
        )
        period = chronicle.periods_for(event.occurred_at.date())["month"]

        self.assertEqual([], chronicle.artifact_candidates([event]))
        self.assertEqual([], chronicle.evidence_blocks(period, [event], "acme/project"))

        cast_event = chronicle.Event(
            event.occurred_at,
            event.sha,
            event.subject,
            (*paths, "tooling/paper-excellence/twin/payload.json"),
        )
        blocks = chronicle.evidence_blocks(period, [cast_event], "acme/project")
        self.assertFalse(any(block.get("type") == "figure" for block in blocks))
        lead = next(block for block in blocks if block.get("id") == "auto:evidence-lead")
        self.assertEqual("asciicast", lead["type"])
        self.assertEqual(18, lead["rows"])
        self.assertIn("a contributor’s words changed before merge", lead["caption"])
        self.assertEqual("The month in motion", next(block for block in blocks if block.get("id") == "auto:evidence-title")["text"])

    def test_year_media_and_visible_highlights_are_editorially_capped(self):
        start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        events = [
            chronicle.Event(
                start + dt.timedelta(days=index),
                f"{index:040x}",
                f"feat(area-{index}): ship visible change {index}",
                (f"docs/evidence/change-{index}.png", f"docs/evidence/change-{index}.cast"),
            )
            for index in range(12)
        ]
        period = chronicle.periods_for(start.date())["year"]
        blocks = chronicle.evidence_blocks(period, events, "acme/project")
        serialized = json.dumps(blocks)
        self.assertEqual(6, serialized.count('"type": "figure"'))
        self.assertEqual(2, serialized.count('"type": "asciicast"'))
        self.assertFalse(any(block.get("type") == "figure" for block in blocks))
        highlights = chronicle.release_highlights("highlights", events, "acme/project", limit=9)["nodes"]
        self.assertLessEqual(len(highlights), 9)
        self.assertEqual(len(highlights), len({node["title"] for node in highlights}))

    def test_day_and_week_keep_their_compact_story_treatment(self):
        event = chronicle.Event(
            dt.datetime(2026, 8, 24, tzinfo=dt.timezone.utc),
            "e" * 40,
            "feat(tasks): show claimed work",
            ("docs/evidence/task-board.png",),
        )
        periods = chronicle.periods_for(event.occurred_at.date())
        day = chronicle.period_payload(periods["day"], [event], periods, "acme/project")
        week = chronicle.period_payload(periods["week"], [event], periods, "acme/project")

        for payload in (day, week):
            by_id = {block["id"]: block for block in payload["blocks"]}
            self.assertEqual("figure", next(block for block in payload["blocks"] if block.get("type") == "figure")["type"])
            self.assertEqual("section", by_id["auto:work-themes"]["type"])
            self.assertEqual("callout", by_id["auto:progress-assessment"]["type"])
            self.assertIn("auto:progress-title", by_id)
            self.assertIn("auto:dek", by_id)

    def test_long_editions_put_scale_and_release_highlights_on_the_reading_path(self):
        events = self.read_fixture_events()
        archive = chronicle.historical_periods(events, dt.date(2026, 8, 23))
        period = next(item for item in archive["month"] if item.key == "2026-08")
        selected = chronicle.events_in_period(events, period)
        payload = chronicle.period_payload(
            period,
            selected,
            chronicle.periods_for(dt.date(2026, 8, 23)),
            "acme/project",
            events=events,
            archive=archive,
            related_papers=chronicle.load_related_papers(),
        )
        by_id = {block["id"]: block for block in payload["blocks"]}

        self.assertEqual("stats", by_id["auto:period-pulse"]["type"])
        self.assertEqual("lineage", by_id["auto:release-highlights"]["type"])
        self.assertEqual("lineage", by_id["auto:archive-1"]["type"])
        self.assertEqual("August, week by week", by_id["auto:archive-title-1"]["text"])
        self.assertLessEqual(len(by_id["auto:archive-1"]["nodes"]), 5)
        self.assertTrue(all(node["source"].startswith("/papers/barkpark-changelog-2026-w") for node in by_id["auto:archive-1"]["nodes"]))
        self.assertTrue(all("·" in node["overline"] for node in by_id["auto:archive-1"]["nodes"]))
        self.assertEqual("expandable", by_id["auto:archive-2"]["type"])
        self.assertEqual("lineage", by_id["auto:work-themes"]["type"])
        self.assertTrue(all("·" in node["overline"] for node in by_id["auto:work-themes"]["nodes"]))
        self.assertEqual("What changed", by_id["auto:work-title"]["text"])
        self.assertEqual("pullquote", by_id["auto:progress-assessment"]["type"])
        self.assertNotIn("auto:progress-title", by_id)
        self.assertNotIn("auto:dek", by_id)
        self.assertLessEqual(len(by_id["auto:release-highlights"]["nodes"]), 6)
        block_ids = [block["id"] for block in payload["blocks"]]
        if "auto:evidence-lead" in block_ids:
            self.assertLess(block_ids.index("auto:work-themes"), block_ids.index("auto:evidence-lead"))
        technical = by_id["auto:technical-record"]
        self.assertTrue(any(block["id"] == "auto:ledger" for block in technical["children"]))

    def test_no_visual_block_is_invented_when_a_period_has_no_media(self):
        events = self.read_fixture_events()
        period = chronicle.periods_for(dt.date(2026, 8, 18))["day"]
        payload = chronicle.period_payload(
            period,
            chronicle.events_in_period(events, period),
            chronicle.periods_for(period.start),
            "acme/project",
        )
        self.assertFalse(any(block.get("type") in {"figure", "asciicast"} for block in payload["blocks"]))

    def test_related_papers_are_real_refs_with_authored_fallback_copy(self):
        event = chronicle.Event(
            dt.datetime(2026, 8, 24, tzinfo=dt.timezone.utc),
            "c" * 40,
            "feat(tasks): show claimed work on the task board",
        )
        period = chronicle.periods_for(dt.date(2026, 8, 24))["day"]
        block = chronicle.related_paper_block(
            period,
            [event],
            chronicle.load_related_papers(),
        )
        self.assertEqual("paper-links", block["type"])
        self.assertEqual("task-components-editable-demo", block["refs"][0]["slug"])
        self.assertTrue(block["refs"][0]["title"])
        self.assertTrue(block["refs"][0]["reason"])

    def test_chronicle_visual_work_receives_a_specific_reader_headline(self):
        event = chronicle.Event(
            dt.datetime(2026, 8, 25, tzinfo=dt.timezone.utc),
            "a" * 40,
            "feat(chronicle): make long editions visual (#14131)",
        )
        self.assertEqual(
            "Chronicle month and year editions now include visual evidence",
            chronicle.concrete_fallback_headline(event),
        )

    def test_curated_cast_is_attached_only_to_the_commit_that_introduced_it(self):
        event = chronicle.Event(
            dt.datetime(2026, 8, 12, tzinfo=dt.timezone.utc),
            "b" * 40,
            "feat(papers): show the premium paper guide",
            ("tooling/paper-excellence/twin/payload.json",),
        )
        period = chronicle.periods_for(dt.date(2026, 8, 12))["day"]
        blocks = chronicle.evidence_blocks(period, [event], "acme/project")
        casts = [block for block in blocks if block.get("type") == "asciicast"]
        self.assertEqual(1, len(casts))
        self.assertEqual(
            "https://guerrilla.barkpark.cloud/media/files/2026/08/arch-3c4075aa.cast",
            casts[0]["src"],
        )
        self.assertEqual(event.sha[:10], casts[0]["source_ref"])

    def test_utc_boundaries_and_iso_week_are_independent_of_month(self):
        periods = chronicle.periods_for(dt.date(2026, 1, 1))
        self.assertEqual("2026-W01", periods["week"].key)
        self.assertEqual(dt.date(2025, 12, 29), periods["week"].start)
        self.assertEqual(dt.date(2026, 1, 1), periods["month"].start)
        output = self.run_script("--date", "2026-08-18", "--ref", "main", "--only", "day").stdout
        payload = json.loads(output)
        self.assertIn("restore tasks", json.dumps(payload))
        self.assertNotIn("typed exports", json.dumps(payload))

    def test_backdated_family_does_not_leak_later_events_into_the_index(self):
        events = self.read_fixture_events()
        payloads = chronicle.build(
            dt.date(2026, 8, 18), "main", "acme/project", events=events,
        )
        serialized = json.dumps(payloads)
        self.assertIn("restore tasks", serialized)
        self.assertNotIn("explain the chronicle", serialized)

    def test_quiet_periods_receive_distinct_dedup_folios(self):
        first = chronicle.periods_for(dt.date(2026, 8, 24))["week"]
        second = chronicle.periods_for(dt.date(2026, 8, 31))["week"]
        self.assertNotEqual(
            chronicle.edition_folio(first, []),
            chronicle.edition_folio(second, []),
        )

    def test_output_is_deterministic_and_every_generated_block_is_owned(self):
        first = self.run_script("--date", "2026-08-23", "--ref", "main").stdout
        second = self.run_script("--date", "2026-08-23", "--ref", "main").stdout
        self.assertEqual(first, second)
        for payload in json.loads(first):
            self.assertTrue(all(block["id"].startswith("auto:") for block in payload["blocks"]))

    def test_editorial_validation_requires_grounded_sources_and_rejects_claims(self):
        events = self.read_fixture_events()
        period = chronicle.periods_for(dt.date(2026, 8, 23))["week"]
        selected = chronicle.events_in_period(events, period)
        refs = [event.sha[:10] for event in chronicle.representative_events(selected)]
        raw = {
            "theme": "Closing the quiet failure paths",
            "plain_summary": "This week was about making Barkpark easier to trust. Missing work returned to view, and the story of what changed became much clearer.",
            "work_themes": [
                {"title": "Work returns to view", "explanation": "Available work is visible again instead of disappearing without explanation.", "outcome": "People can see what needs their attention.", "source_refs": [refs[0]]},
                {"title": "A clearer project story", "explanation": "Shipped work now has a readable account and a stable place to find it.", "outcome": "Progress is easier to follow and share.", "source_refs": [refs[-1]]},
            ],
            "progress_assessment": "This was a care-and-repair week. The result is a calmer and more trustworthy picture of the work.",
        }
        editorial = chronicle.validate_editorial(raw, period, selected)
        self.assertEqual("ai", editorial["mode"])

        raw["work_themes"][0]["source_refs"] = ["not-a-source"]
        with self.assertRaisesRegex(ValueError, "cite supplied sources"):
            chronicle.validate_editorial(raw, period, selected)

        raw["work_themes"][0]["source_refs"] = [refs[0]]
        raw["progress_assessment"] = "Revenue rose by 20 percent."
        with self.assertRaisesRegex(ValueError, "numeric claims"):
            chronicle.validate_editorial(raw, period, selected)

        raw["progress_assessment"] = "The pagination callback is now easier to retry."
        with self.assertRaisesRegex(ValueError, "implementation jargon"):
            chronicle.validate_editorial(raw, period, selected)

    def test_editorial_validation_rejects_headlines_and_summaries_without_an_argument(self):
        events = self.read_fixture_events()
        period = chronicle.periods_for(dt.date(2026, 8, 23))["week"]
        selected = chronicle.events_in_period(events, period)
        ref = chronicle.representative_events(selected)[0].sha[:10]
        raw = {
            "theme": "Opening up new possibilities",
            "plain_summary": "Task lists returned to view, and Chronicle editions became easier to scan. Readers can now see the work and understand its story.",
            "work_themes": [{
                "title": "Tasks return to view",
                "explanation": "Available work is visible again instead of disappearing.",
                "outcome": "People can see what needs attention.",
                "source_refs": [ref],
            }],
            "progress_assessment": "This was a care-and-repair week with visible results.",
        }
        with self.assertRaisesRegex(ValueError, "name a subject"):
            chronicle.validate_editorial(raw, period, selected)

        raw["theme"] = "Chronicle editions gain distinct identity"
        with self.assertRaisesRegex(ValueError, "name a subject"):
            chronicle.validate_editorial(raw, period, selected)

        raw["theme"] = "Task lists return to the terminal"
        raw["plain_summary"] = "Today's work focused on making task lists easier to find. Readers can now see what needs attention."
        with self.assertRaisesRegex(ValueError, "lead with what changed"):
            chronicle.validate_editorial(raw, period, selected)

    def test_deterministic_editorial_uses_a_concrete_shipped_change_headline(self):
        events = self.read_fixture_events()
        period = chronicle.periods_for(dt.date(2026, 8, 18))["day"]
        editorial = chronicle.deterministic_editorial(
            period,
            chronicle.events_in_period(events, period),
        )
        self.assertEqual("Tasks return to view", editorial["theme"])
        self.assertIn("Tasks return to view", editorial["plain_summary"])
        forbidden = (
            "Opening up new possibilities",
            "Useful progress, carefully made",
            "Making everyday work smoother",
            "Making Barkpark better",
            "A steadier product",
            "More useful ways to work",
        )
        visible_titles = [editorial["theme"], *[item["title"] for item in editorial["work_themes"]]]
        self.assertTrue(all(title not in forbidden for title in visible_titles))

    def test_generated_paper_title_caps_long_source_subjects_at_the_schema_limit(self):
        period = chronicle.periods_for(dt.date(2026, 8, 24))["day"]
        event = chronicle.Event(
            dt.datetime(2026, 8, 24, tzinfo=dt.timezone.utc),
            "a" * 40,
            "feat(surface): " + "specific reader-visible change " * 20,
        )
        payload = chronicle.period_payload(
            period,
            [event],
            chronicle.periods_for(period.start),
            "acme/project",
        )
        self.assertLessEqual(len(payload["title"]), 255)
        self.assertTrue(payload["title"].endswith("— 24 August 2026"))
        self.assertNotIn("specific reader-visible change", payload["title"])

    def test_editorial_generation_falls_back_without_blocking_the_archive(self):
        events = self.read_fixture_events()
        periods = chronicle.periods_for(dt.date(2026, 8, 23))
        with mock.patch.object(chronicle, "request_editorials", side_effect=RuntimeError("offline")):
            editorials = chronicle.generate_current_editorials(events, periods, "anthropic")
        self.assertEqual({}, editorials)
        payloads = chronicle.build(
            dt.date(2026, 8, 23), "main", "acme/project", events=events, editorials=editorials,
        )
        week = payloads["week"]
        self.assertIn("deterministic editorial review", json.dumps(week))

    def test_editorial_packet_samples_the_whole_period_and_deduplicates_prompt_sources(self):
        start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        events = [
            chronicle.Event(start + dt.timedelta(days=index), f"{index:040x}", f"fix(area-{index % 9}): repair path {index}")
            for index in range(100)
        ]
        sampled = chronicle.representative_events(events)
        self.assertLessEqual(len(sampled), 36)
        self.assertEqual(events[0], sampled[0])
        self.assertEqual(events[-1], sampled[-1])
        self.assertGreater(len({event.occurred_at.month for event in sampled}), 3)

        period = chronicle.Period("year", "2026", dt.date(2026, 1, 1), dt.date(2027, 1, 1), "year", "2026")
        packet = chronicle.editorial_source_packet(period, events)
        prompt = chronicle.editorial_prompt([packet, {**packet, "kind": "month"}])
        self.assertEqual(1, prompt.count("repair path 99"))
        self.assertIn('"source_catalog"', prompt)

    def test_model_parser_accepts_fenced_anthropic_text(self):
        response = json.dumps(
            {"content": [{"type": "text", "text": '```json\n{"schema":"ok"}\n```'}]}
        )
        self.assertEqual({"schema": "ok"}, chronicle.parse_model_json(response))

    def test_publish_requires_a_token_before_network_access(self):
        env = os.environ.copy()
        env.pop("BARKPARK_INGEST_TOKEN", None)
        result = subprocess.run(
            ["python3", str(SCRIPT), "--date", "2026-08-23", "--ref", "main", "--publish"],
            cwd=self.repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("requires BARKPARK_INGEST_TOKEN", result.stderr)

    def test_publish_skips_an_unchanged_source_digest(self):
        payload = {"slug": "same", "source_doc": "git:first-parent:day:same"}
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.__exit__.return_value = False
        with mock.patch.object(chronicle.urllib.request, "urlopen", return_value=response) as urlopen:
            with mock.patch.object(chronicle.json, "load", return_value={"result": {"source_doc": payload["source_doc"]}}):
                chronicle.publish([payload], "https://example.test", "secret")
        self.assertEqual(1, urlopen.call_count)

    def test_publish_can_preserve_an_existing_historical_editorial(self):
        payload = {"slug": "old-day", "source_doc": "new-generated-copy"}
        with mock.patch.object(chronicle, "current_source_doc", return_value="human-reviewed-copy"):
            with mock.patch.object(chronicle.urllib.request, "urlopen") as urlopen:
                result = chronicle.publish_one(
                    payload,
                    "https://example.test",
                    "secret",
                    missing_only=True,
                )
        self.assertEqual("preserved /papers/old-day", result)
        urlopen.assert_not_called()

    def test_parallel_publish_keeps_the_chronicle_index_last(self):
        payloads = [
            {"slug": "day-a", "source_doc": "a"},
            {"slug": "barkpark-chronicle", "source_doc": "index"},
            {"slug": "week-a", "source_doc": "b"},
        ]
        completed = []

        def publish_one(payload, _api_url, _token):
            completed.append(payload["slug"])
            return f"published {payload['slug']}"

        with mock.patch.object(chronicle, "publish_one", side_effect=publish_one):
            chronicle.publish(payloads, "https://example.test", "secret", workers=2)

        self.assertEqual("barkpark-chronicle", completed[-1])
        self.assertEqual({"day-a", "week-a"}, set(completed[:-1]))

    def test_publish_error_names_the_failing_paper_and_response(self):
        error = chronicle.urllib.error.HTTPError(
            "https://example.test/ingest",
            409,
            "Conflict",
            {},
            io.BytesIO(b'{"error":"duplicate"}'),
        )
        with mock.patch.object(chronicle, "current_source_doc", return_value=None):
            with mock.patch.object(chronicle.urllib.request, "urlopen", side_effect=error):
                with self.assertRaisesRegex(
                    RuntimeError,
                    r"/papers/day-a: HTTP 409: .*duplicate",
                ):
                    chronicle.publish_one(
                        {"slug": "day-a", "source_doc": "a"},
                        "https://example.test",
                        "secret",
                    )


if __name__ == "__main__":
    unittest.main()
