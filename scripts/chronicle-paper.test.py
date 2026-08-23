#!/usr/bin/env python3

import datetime as dt
import importlib.util
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

    def test_builds_five_native_papers_from_one_calendar_graph(self):
        output = self.run_script("--date", "2026-08-23", "--ref", "main", "--repo", "acme/project").stdout
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
        index = by_slug["barkpark-chronicle"]
        self.assertIn("/papers/barkpark-changelog-2026-w34", json.dumps(index))

    def test_utc_boundaries_and_iso_week_are_independent_of_month(self):
        periods = chronicle.periods_for(dt.date(2026, 1, 1))
        self.assertEqual("2026-W01", periods["week"].key)
        self.assertEqual(dt.date(2025, 12, 29), periods["week"].start)
        self.assertEqual(dt.date(2026, 1, 1), periods["month"].start)
        output = self.run_script("--date", "2026-08-18", "--ref", "main", "--only", "day").stdout
        payload = json.loads(output)
        self.assertIn("restore tasks", json.dumps(payload))
        self.assertNotIn("typed exports", json.dumps(payload))

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


if __name__ == "__main__":
    unittest.main()
