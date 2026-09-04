#!/usr/bin/env python3
"""A refusal must not read as a count of zero -- and a true zero must survive.

Every refusal in this file is REPLAYED, never invented: the bytes come from
scripts/lib/testdata/bp-refusal-corpus.json, which was captured live against
guerrilla with the exit status recorded beside each body. A hand-written
{"error": ...} fixture would be weaker evidence, because the whole defect is
that the real envelope carries NO `docs` key and so satisfies `or []` silently.

Both arms are asserted, always together:
  ARM 1  the fixed reader RAISES on a replayed refusal
  ARM 2  the SAME reader returns 0 on a genuinely empty {"ok":true,"docs":[]}

A reader that raises on everything has replaced a false zero with a false
alarm, which is not an improvement -- so arm 2 is not optional decoration.
"""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

from bp_read import BpRefused, bp_json, counts, ensure_ok, rows  # noqa: E402

CORPUS = json.loads((HERE / "testdata" / "bp-refusal-corpus.json").read_text())
REFUSALS = {r["name"]: r for r in CORPUS["refusals"]}
EMPTY = CORPUS["genuinely_empty"]


def fake_bp(tmpdir, stdout, exit_code, stderr=""):
    """A `bp` on PATH that replays captured bytes and the captured exit code."""
    bindir = pathlib.Path(tmpdir) / "bin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "bp"
    script.write_text(
        "#!/bin/sh\n"
        "cat <<'BPBODY'\n" + stdout.rstrip("\n") + "\nBPBODY\n"
        + ("printf '%s\\n' " + json.dumps(stderr) + " >&2\n" if stderr else "")
        + f"exit {exit_code}\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}")
    return env


class TheCorpusIsReal(unittest.TestCase):
    """Guards the fixture: if these stop holding, the tests below go vacuous."""

    def test_the_refusals_carry_no_rows_key_at_all(self):
        # This IS the defect. If a refusal ever grew a `docs` key, `or []`
        # would no longer be silent and this whole row would be moot.
        for name, r in REFUSALS.items():
            payload = json.loads(r["stdout"])
            for key in ("docs", "tasks", "children", "rows"):
                self.assertNotIn(key, payload, f"{name} unexpectedly carries {key!r}")

    def test_the_naked_idiom_yields_a_plausible_zero_on_every_refusal(self):
        # The witness. This is the code the row is about, run over the real
        # bytes: it reports ZERO CHILDREN for a call bp refused outright.
        for name, r in REFUSALS.items():
            d = json.loads(r["stdout"])
            naked = d.get("docs") or d.get("tasks") or []     # the defect, verbatim
            self.assertEqual(naked, [], f"{name}")
            self.assertEqual(len(naked), 0)

    def test_every_refusal_carries_all_three_signals(self):
        for name, r in REFUSALS.items():
            d = json.loads(r["stdout"])
            self.assertIs(d.get("ok"), False, name)
            self.assertIn("code", d.get("error", {}), name)
            self.assertNotEqual(r["exit_code"], 0, name)

    def test_the_two_exit_codes_are_the_documented_ones(self):
        self.assertEqual(REFUSALS["usage"]["exit_code"], 2)
        self.assertEqual(REFUSALS["not_found"]["exit_code"], 4)


class ArmOneRefusalsRaise(unittest.TestCase):
    def test_ensure_ok_raises_on_each_replayed_refusal(self):
        for name, r in REFUSALS.items():
            with self.subTest(name):
                with self.assertRaises(BpRefused) as caught:
                    ensure_ok(json.loads(r["stdout"]), exit_code=r["exit_code"],
                              argv=r["command"].split())
                self.assertEqual(caught.exception.code,
                                 json.loads(r["stdout"])["error"]["code"])

    def test_rows_raises_rather_than_returning_the_empty_list(self):
        for name, r in REFUSALS.items():
            with self.subTest(name):
                with self.assertRaises(BpRefused):
                    rows(json.loads(r["stdout"]), "docs", "tasks")

    def test_bp_json_raises_end_to_end_against_a_replaying_bp(self):
        for name, r in REFUSALS.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                env = fake_bp(tmp, r["stdout"], r["exit_code"])
                old = os.environ["PATH"]
                os.environ["PATH"] = env["PATH"]
                try:
                    with self.assertRaises(BpRefused) as caught:
                        bp_json(r["command"].split())
                finally:
                    os.environ["PATH"] = old
                self.assertEqual(caught.exception.exit_code, r["exit_code"])

    def test_an_ok_false_envelope_at_exit_zero_still_raises(self):
        # The exit status alone is not enough: the sibling producer row
        # (spd-bl-bp-search-exits-zero-while-failing) is exactly this shape.
        with self.assertRaises(BpRefused):
            ensure_ok(json.loads(REFUSALS["usage"]["stdout"]), exit_code=0)

    def test_a_nonzero_exit_with_a_healthy_looking_body_still_raises(self):
        with self.assertRaises(BpRefused):
            ensure_ok({"ok": True, "docs": []}, exit_code=2)


class ArmTwoATrueZeroSurvives(unittest.TestCase):
    def test_a_genuinely_empty_result_reads_as_zero_without_raising(self):
        payload = ensure_ok(json.loads(EMPTY["stdout"]), exit_code=EMPTY["exit_code"])
        self.assertEqual(rows(payload, "docs", "tasks"), [])
        self.assertEqual(counts(payload, "docs", "tasks"), 0)

    def test_the_same_reader_end_to_end_returns_zero_on_an_empty_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = fake_bp(tmp, EMPTY["stdout"], EMPTY["exit_code"])
            old = os.environ["PATH"]
            os.environ["PATH"] = env["PATH"]
            try:
                d = bp_json(["bp", "task", "ls", "-o", "json"])
            finally:
                os.environ["PATH"] = old
        self.assertEqual(counts(d, "docs", "tasks"), 0)

    def test_a_populated_result_still_counts(self):
        d = ensure_ok({"ok": True, "docs": [{"_id": "a"}, {"_id": "b"}]}, exit_code=0)
        self.assertEqual(counts(d, "docs", "tasks"), 2)

    def test_the_tasks_key_fallback_still_works(self):
        d = ensure_ok({"ok": True, "tasks": [{"_id": "a"}]}, exit_code=0)
        self.assertEqual(counts(d, "docs", "tasks"), 1)


class TheShellHalf(unittest.TestCase):
    """c3: the bp-into-a-pipe invocation pattern, and bp-read.sh's answer."""

    def _run(self, stdout, exit_code, snippet, stderr=""):
        with tempfile.TemporaryDirectory() as tmp:
            env = fake_bp(tmp, stdout, exit_code, stderr=stderr)
            return subprocess.run(["bash", "-c", snippet], env=env,
                                  capture_output=True, text=True, cwd=str(REPO))

    NAKED = (
        # The pattern, verbatim, as it appears in the tree today.
        "bp task ls -o json 2>/dev/null "
        "| python3 -c 'import sys,json;print(len(json.load(sys.stdin).get(\"docs\") or []))' "
        "2>/dev/null"
    )
    FIXED = (
        '. scripts/lib/bp-read.sh\n'
        'body="$(bp_json task ls -o json)" || exit $?\n'
        'printf "%s" "$body" | python3 -c '
        "'import sys,json;print(len(json.load(sys.stdin)[\"docs\"]))'"
    )

    def test_the_naked_pipe_prints_zero_on_a_refusal(self):
        # Documents the hole: exit 0, stdout "0", nothing on stderr.
        r = self._run(REFUSALS["usage"]["stdout"], 2, self.NAKED,
                      stderr="this line is thrown away by 2>/dev/null")
        self.assertEqual(r.stdout.strip(), "0")
        self.assertEqual(r.returncode, 0)

    def test_bp_read_sh_refuses_and_names_the_code(self):
        for name, ref in REFUSALS.items():
            with self.subTest(name):
                r = self._run(ref["stdout"], ref["exit_code"], self.FIXED)
                self.assertEqual(r.returncode, ref["exit_code"])
                self.assertNotEqual(r.stdout.strip(), "0")
                self.assertIn(json.loads(ref["stdout"])["error"]["code"], r.stderr)
                self.assertIn("REFUSED", r.stderr)

    def test_bp_read_sh_still_prints_zero_for_a_true_empty(self):
        r = self._run(EMPTY["stdout"], EMPTY["exit_code"], self.FIXED)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "0")

    def test_bp_read_sh_catches_an_error_envelope_at_exit_zero(self):
        r = self._run(REFUSALS["not_found"]["stdout"], 0, self.FIXED)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ERROR envelope", r.stderr)


class TheAppliedSites(unittest.TestCase):
    """The rule is applied WHERE IT IS USED, not merely written down.

    Each case extracts the real function out of the real file in the tree,
    puts a `bp` on PATH that replays the captured refusal, and asserts the
    function REFUSES instead of printing a plausible empty answer. Extracting
    from the file (rather than restating the snippet) is what keeps these from
    going vacuous if someone reverts the call site.
    """

    def _extract(self, path, name):
        text = (REPO / path).read_text()
        start = text.index(f"{name}(){{")
        end = text.index("\n}\n", start) + len("\n}\n")
        body = text[start:end]
        self.assertIn("bp_json", body,
                      f"{path}:{name}() no longer goes through bp_json — the fix was reverted")
        return body

    def _drive(self, path, name, snippet, stdout, exit_code):
        func = self._extract(path, name)
        with tempfile.TemporaryDirectory() as tmp:
            env = fake_bp(tmp, stdout, exit_code)
            script = (
                'set -u\n'
                f'cd {REPO}\n'
                '. scripts/lib/bp-read.sh\n'
                + func + "\n" + snippet
            )
            return subprocess.run(["bash", "-c", script], env=env,
                                  capture_output=True, text=True, cwd=str(REPO))

    def test_fleet_run_field_refuses_instead_of_printing_an_empty_field(self):
        ref = REFUSALS["usage"]
        r = self._drive(
            "tooling/fleet/fleet-run.sh", "field",
            'out="$(field task-3f1fe755ed53738e holder)"; rc=$?; '
            'echo "OUT=[$out] RC=$rc"',
            ref["stdout"], ref["exit_code"])
        self.assertIn("RC=2", r.stdout, r.stderr)
        self.assertIn("usage", r.stderr)
        self.assertIn("NOT an empty field", r.stderr)

    def test_fleet_run_field_still_reads_a_real_row(self):
        # The negative arm at the APPLIED site: a healthy read still answers.
        ok = json.dumps({"ok": True, "doc": {
            "lifecycle_status": "open",
            "claim": {"worker": "w25", "epoch": 3},
            "content": {"acceptance_criteria": [], "brief": {"blocks": []}},
        }}) + "\n"
        r = self._drive(
            "tooling/fleet/fleet-run.sh", "field",
            'out="$(field task-x holder)"; rc=$?; echo "OUT=[$out] RC=$rc"',
            ok, 0)
        self.assertIn("OUT=[w25] RC=0", r.stdout, r.stderr)

    def test_the_naked_pipe_pattern_is_gone_from_the_files_we_fixed(self):
        # The invocation pattern, named: `bp ... | parser` with stderr binned.
        import re
        pattern = re.compile(r"^\s*bp\s+[^\n|]*2>/dev/null\s*\\?\s*\|", re.M)
        for path in ("tooling/fleet/fleet-run.sh",
                     "scripts/merge-gate-autostamp-liveness.sh"):
            text = (REPO / path).read_text()
            self.assertEqual(pattern.findall(text), [],
                             f"{path} still pipes bp straight into a parser")

    def test_merge_gate_liveness_sources_the_helper(self):
        text = (REPO / "scripts/merge-gate-autostamp-liveness.sh").read_text()
        self.assertIn("lib/bp-read.sh", text)
        self.assertIn("NOT counted as un-autostamped", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
