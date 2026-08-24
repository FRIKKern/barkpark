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
        self.assertEqual(["barkpark", "docs"], [tag["tag"] for tag in week["tags"]])
        serialized = json.dumps(week)
        self.assertIn("https://github.com/acme/project/pull/12", serialized)
        self.assertIn("https://github.com/acme/project/pull/13", serialized)
        self.assertIn('"type": "bar-chart"', serialized)
        self.assertIn('"type": "lineage"', serialized)
        self.assertIn("folio", week["title"])
        week_h1 = next(block for block in week["blocks"] if block["id"] == "auto:title")
        self.assertEqual("Week 34: what shipped", week_h1["text"])
        self.assertNotIn("folio", week_h1["text"])
        index = by_slug["barkpark-chronicle"]
        serialized_index = json.dumps(index)
        self.assertIn("/papers/barkpark-changelog-2026-w34", serialized_index)
        self.assertIn('"text": "What\\u2019s new in Barkpark"', serialized_index)
        self.assertIn('"text": "Browse the changelog"', serialized_index)
        self.assertIn('"type": "action"', serialized_index)
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
        self.assertIn("How the month unfolded", july_json)
        self.assertIn("Weekly cadence · July 2026", july_json)
        self.assertIn("Product updates", july_json)
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

    def test_full_history_builds_every_active_period_and_hierarchical_links(self):
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
        self.assertEqual(10, len(by_slug))
        self.assertEqual(len(payloads), len(by_slug))
        self.assertEqual(
            {
                "barkpark-chronicle",
                "barkpark-changelog-2026",
                "barkpark-changelog-2026-07",
                "barkpark-changelog-2026-08",
                "barkpark-changelog-2026-w31",
                "barkpark-changelog-2026-w34",
                "barkpark-changelog-2026-07-31",
                "barkpark-changelog-2026-08-17",
                "barkpark-changelog-2026-08-18",
                "barkpark-changelog-2026-08-23",
            },
            set(by_slug),
        )
        self.assertTrue(
            all(
                payload.get("dedup_bypass") is True
                for slug, payload in by_slug.items()
                if slug != "barkpark-chronicle"
            )
        )

        year_json = json.dumps(by_slug["barkpark-changelog-2026"])
        self.assertIn("Monthly chapters", year_json)
        self.assertIn("/papers/barkpark-changelog-2026-07", year_json)
        self.assertIn("/papers/barkpark-changelog-2026-08", year_json)

        august_json = json.dumps(by_slug["barkpark-changelog-2026-08"])
        self.assertIn("Weekly dispatches", august_json)
        self.assertIn("Daily shiplogs", august_json)
        self.assertIn("/papers/barkpark-changelog-2026-w34", august_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-17", august_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-23", august_json)

        week_json = json.dumps(by_slug["barkpark-changelog-2026-w34"])
        self.assertIn("/papers/barkpark-changelog-2026-08-17", week_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-18", week_json)
        self.assertIn("/papers/barkpark-changelog-2026-08-23", week_json)

    def test_full_history_cli_writes_one_file_per_unique_paper(self):
        output_dir = self.repo / "chronicle"
        self.run_script(
            "--date", "2026-08-23",
            "--ref", "main",
            "--repo", "acme/project",
            "--full-history",
            "--output-dir", str(output_dir),
        )
        self.assertEqual(10, len(list(output_dir.glob("*.json"))))

    def test_utc_boundaries_and_iso_week_are_independent_of_month(self):
        periods = chronicle.periods_for(dt.date(2026, 1, 1))
        self.assertEqual("2026-W01", periods["week"].key)
        self.assertEqual(dt.date(2025, 12, 29), periods["week"].start)
        self.assertEqual(dt.date(2026, 1, 1), periods["month"].start)
        output = self.run_script("--date", "2026-08-18", "--ref", "main", "--only", "day").stdout
        payload = json.loads(output)
        self.assertIn("restore tasks", json.dumps(payload))
        self.assertNotIn("typed exports", json.dumps(payload))

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
