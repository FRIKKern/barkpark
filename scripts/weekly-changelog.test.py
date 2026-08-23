#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "weekly-changelog.py"
WORKFLOW = ROOT / ".github" / "workflows" / "weekly-changelog.yml"


class WeeklyChangelogTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temp.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test Author")
        self.git("config", "user.email", "test@example.com")
        self.commit("2026-08-16T12:00:00Z", "chore: before the week")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.commit("2026-08-17T09:00:00Z", "feat(api): add typed exports (#12)")
        self.commit("2026-08-18T09:00:00Z", "fix: recover stale sessions (#13)")
        self.commit("2026-08-19T09:00:00Z", "docs: explain exports")
        self.commit("2026-08-20T09:00:00Z", "unconventional maintenance")
        self.week_head = self.git("rev-parse", "HEAD").strip()
        self.commit("2026-08-24T00:00:00Z", "feat: next week (#14)")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args, env=None):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, env=env, text=True, stderr=subprocess.STDOUT
        )

    def commit(self, timestamp, subject):
        marker = self.repo / "history.txt"
        marker.write_text(marker.read_text() + subject + "\n" if marker.exists() else subject + "\n")
        self.git("add", "history.txt")
        env = os.environ.copy()
        env["GIT_AUTHOR_DATE"] = timestamp
        env["GIT_COMMITTER_DATE"] = timestamp
        self.git("commit", "-m", subject, env=env)

    def run_script(self, *args, check=True):
        return subprocess.run(
            ["python3", str(SCRIPT), *args],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_renders_only_the_requested_week_and_groups_user_facing_changes(self):
        output = self.run_script(
            "--week", "2026-08-17", "--ref", "main", "--repo", "acme/project"
        ).stdout
        self.assertIn("# Barkpark Weekly 20", output)
        self.assertIn(f"compare/{self.base}...{self.week_head}", output)
        self.assertIn("## api moved forward", output)
        self.assertIn("## Three things worth knowing", output)
        self.assertIn("**Release pulse:** 4 mainline changes", output)
        self.assertIn("[add typed exports](https://github.com/acme/project/pull/12)", output)
        self.assertIn("[recover stale sessions](https://github.com/acme/project/pull/13)", output)
        self.assertIn("## The week in perspective", output)
        self.assertNotIn("next week", output)

    def test_renders_a_stable_editorial_issue_title(self):
        output = self.run_script(
            "--week", "2026-08-17", "--ref", "main", "--title-only"
        ).stdout.strip()
        self.assertEqual("Barkpark Weekly 20 · api moved forward · 2026-08-17", output)

    def test_rejects_a_non_monday(self):
        result = self.run_script("--week", "2026-08-18", "--ref", "main", check=False)
        self.assertEqual(2, result.returncode)
        self.assertIn("ISO-week Monday", result.stderr)

    def test_workflow_is_scheduled_idempotent_and_keeps_changelog_out_of_open_work(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('cron: "17 6 * * 1"', workflow)
        self.assertIn("issues: write", workflow)
        self.assertIn("backfill_all", workflow)
        self.assertIn("--list-editorial-weeks", workflow)
        self.assertIn('gh issue list --state all', workflow)
        self.assertIn('gh issue edit "$number"', workflow)
        self.assertIn('gh issue create --title "$title"', workflow)
        self.assertIn("-f state=closed -f state_reason=completed", workflow)
        self.assertNotIn("gh release", workflow)


class EditorialCatalogTest(unittest.TestCase):
    def test_catalog_covers_every_completed_week_and_resolves_to_its_ledger(self):
        catalog_path = ROOT / "changelog" / "editorial.json"
        catalog = json.loads(catalog_path.read_text())
        self.assertEqual(19, len(catalog))
        self.assertEqual("2026-04-06", min(catalog))
        self.assertEqual("2026-08-10", max(catalog))

        validation = subprocess.run(
            ["python3", str(SCRIPT), "--validate-editorial", "--ref", "HEAD"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertIn("Validated 19 editorial weeks.", validation.stdout)

    def test_every_curated_edition_fits_the_github_issue_surface(self):
        weeks = subprocess.check_output(
            ["python3", str(SCRIPT), "--list-editorial-weeks"],
            cwd=ROOT,
            text=True,
        ).splitlines()
        for week in weeks:
            body = subprocess.check_output(
                ["python3", str(SCRIPT), "--week", week, "--ref", "HEAD"],
                cwd=ROOT,
                text=True,
            )
            title = subprocess.check_output(
                [
                    "python3",
                    str(SCRIPT),
                    "--week",
                    week,
                    "--ref",
                    "HEAD",
                    "--title-only",
                ],
                cwd=ROOT,
                text=True,
            ).strip()
            self.assertLess(len(body), 65_536, week)
            self.assertLessEqual(len(title), 256, week)
            self.assertIn("## Three things worth knowing", body)
            self.assertIn("## The week in perspective", body)


if __name__ == "__main__":
    unittest.main()
