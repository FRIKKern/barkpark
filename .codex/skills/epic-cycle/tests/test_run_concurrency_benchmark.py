#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "run_concurrency_benchmark.py"
SPEC = importlib.util.spec_from_file_location("run_concurrency_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def assignment(assignment_id, *, exit_code=0, complete=True, contradiction=False, delay=0.03):
    payload = json.dumps(
        {"complete": complete, "contradiction_unsupported": contradiction},
        separators=(",", ":"),
    )
    code = f"import time; time.sleep({delay}); print({payload!r}); raise SystemExit({exit_code})"
    return {"id": assignment_id, "argv": [sys.executable, "-c", code]}


def manifest():
    return {
        "schema_version": MODULE.SCHEMA_VERSION,
        "seed": MODULE.SEED,
        "assignments": [assignment(f"a{index}") for index in range(1, 7)],
        "cold_reset_argv": [sys.executable, "-c", "pass"],
        "warm_prime_argv": [sys.executable, "-c", "pass"],
        "primary_pane": "%1",
        "tmux_panes": ["%1", "%2"],
        "timeout_seconds": 2,
        "environment": {"EPIC_FIXTURE": "1"},
    }


def identity(pid, token="1"):
    return MODULE.ProcessIdentity(pid, token, "Linux", "fixture")


def healthy_signals(**changes):
    values = {
        "pane": "%1",
        "pane_identity": identity(10),
        "cpu_count": 8,
        "load1": 1.0,
        "memory_available_bytes": 8 * 1024**3,
        "process_groups_supported": True,
        "platform": "Linux",
        "sources": {},
    }
    values.update(changes)
    return MODULE.HostSignals(**values)


class ScheduleTest(unittest.TestCase):
    def test_complete_williams_cycle_is_all_pair_balanced(self):
        rows = MODULE.complete_williams_rows()
        MODULE.validate_williams_cycle(rows)
        pairs = [(left, right) for row in rows for left, right in zip(row, row[1:])]
        self.assertEqual(12, len(pairs))
        self.assertEqual(12, len(set(pairs)))

    def test_schedule_is_frozen_deterministic_and_balanced_at_every_look(self):
        ids = [f"a{index}" for index in range(1, 7)]
        first = MODULE.build_schedule(ids)
        second = MODULE.build_schedule(ids)
        self.assertEqual(first, second)
        self.assertEqual(16, len(first))
        for look in MODULE.FIXED_LOOKS:
            self.assertEqual(list(MODULE.TREATMENTS), sorted(item["width"] for item in first if item["look"] == look))
        for item in first:
            self.assertEqual(set(ids), set(item["assignment_order"]))
            self.assertTrue(item["cold_reset"])
            self.assertTrue(item["warm_prime"])

    def test_schedule_rejects_any_other_seed_or_work_size(self):
        with self.assertRaisesRegex(MODULE.ProtocolError, "frozen"):
            MODULE.build_schedule([f"a{index}" for index in range(6)], seed=1)
        with self.assertRaisesRegex(MODULE.ProtocolError, "exactly six"):
            MODULE.build_schedule(["a", "b"])

    def test_plan_replay_rejects_mutation(self):
        source = manifest()
        plan = MODULE.plan_artifact(source)
        MODULE.verify_replay(plan, source)
        plan["schedule"][0]["width"] = 6
        with self.assertRaisesRegex(MODULE.ProtocolError, "plan_digest"):
            MODULE.verify_replay(plan, source)


class ManifestTest(unittest.TestCase):
    def test_manifest_requires_the_exact_narrow_shape(self):
        value = manifest()
        normalized = MODULE.validate_manifest(value)
        self.assertEqual(6, len(normalized["assignments"]))
        value["generic_interceptor"] = True
        with self.assertRaisesRegex(MODULE.ProtocolError, "unsupported manifest fields"):
            MODULE.validate_manifest(value)

    def test_manifest_rejects_missing_control_steps_and_duplicate_work(self):
        value = manifest()
        value["cold_reset_argv"] = []
        with self.assertRaisesRegex(MODULE.ProtocolError, "cold reset"):
            MODULE.validate_manifest(value)
        value = manifest()
        value["assignments"][1]["id"] = value["assignments"][0]["id"]
        with self.assertRaisesRegex(MODULE.ProtocolError, "unique"):
            MODULE.validate_manifest(value)

    def test_cli_plan_is_safe_and_does_not_run_commands(self):
        value = manifest()
        value["assignments"][0]["argv"] = ["this-command-must-not-run"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config.json"
            output = root / "plan.json"
            config.write_text(json.dumps(value), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "plan", "--config", str(config), "--output", str(output)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(16, len(json.loads(output.read_text(encoding="utf-8"))["schedule"]))


class IdentityAndAdmissionTest(unittest.TestCase):
    def test_tmux_pid_resolution_requires_live_matching_pane(self):
        self.assertEqual(4321, MODULE.resolve_tmux_pane_pid("%7", lambda argv: "%7\t4321\t0\n"))
        with self.assertRaises(MODULE.SafetyError):
            MODULE.resolve_tmux_pane_pid("%7", lambda argv: "%7\t4321\t1\n")
        with self.assertRaises(MODULE.SafetyError):
            MODULE.resolve_tmux_pane_pid("%7", lambda argv: "%8\t4321\t0\n")

    def test_linux_identity_parser_handles_spaces_and_parentheses_in_comm(self):
        # fields 3..52, with starttime (field 22) frozen at 999.
        rest = ["S"] + [str(index) for index in range(4, 53)]
        rest[19] = "999"
        record = "123 (worker name (fixture)) " + " ".join(rest)
        result = MODULE.read_process_identity(123, system="Linux", read_text=lambda path: record)
        self.assertEqual("999", result.start_token)
        self.assertEqual("/proc/<pid>/stat field 22", result.source)

    def test_darwin_identity_normalizes_start_text(self):
        result = MODULE.read_process_identity(
            55,
            system="Darwin",
            run_text=lambda argv: " Wed   Jul 15 01:00:00 2026 \n",
        )
        self.assertEqual("Wed Jul 15 01:00:00 2026", result.start_token)

    def test_pid_reuse_fence_detects_changed_start_token(self):
        original = identity(99, "old")
        self.assertFalse(
            MODULE.identity_is_live(
                original,
                read_identity=lambda pid, system=None: MODULE.ProcessIdentity(pid, "new", system, "fixture"),
            )
        )

    def test_default_capacity_one_is_healthy_and_capacity_two_is_explicit(self):
        one = MODULE.admit_heavy_run(healthy_signals())
        self.assertTrue(one.admitted)
        self.assertEqual(1, one.heavy_capacity)
        denied = MODULE.admit_heavy_run(healthy_signals(), 2)
        self.assertFalse(denied.admitted)
        self.assertTrue(any("explicit" in reason for reason in denied.reasons))
        two = MODULE.admit_heavy_run(healthy_signals(), 2, capacity_two_explicit=True)
        self.assertTrue(two.admitted)

    def test_missing_identity_or_required_safety_signal_denies(self):
        for changes in (
            {"pane_identity": None},
            {"cpu_count": None},
            {"load1": None},
            {"memory_available_bytes": None},
            {"process_groups_supported": False},
        ):
            with self.subTest(changes=changes):
                self.assertFalse(MODULE.admit_heavy_run(healthy_signals(**changes)).admitted)

    def test_capacity_two_denies_unhealthy_host(self):
        decision = MODULE.admit_heavy_run(
            healthy_signals(cpu_count=2, load1=2.0, memory_available_bytes=1024**3),
            2,
            capacity_two_explicit=True,
        )
        self.assertFalse(decision.admitted)
        self.assertGreaterEqual(len(decision.reasons), 3)


class MetricsAndSamplerTest(unittest.TestCase):
    def test_typed_unknown_metrics_are_not_zero(self):
        unknown = MODULE.null_metric("bytes", "fixture", "group", "not observed")
        unsupported = MODULE.unsupported_metric("percent", "fixture", "group", "not supported")
        self.assertEqual({"null", "unsupported"}, {unknown["kind"], unsupported["kind"]})
        self.assertIsNone(unknown["value"])
        self.assertIsNone(unsupported["value"])
        with self.assertRaises(MODULE.ProtocolError):
            MODULE.typed_metric("unsupported", value=0, unit="x", source="x", scope="x")

    def test_linux_group_fixture_is_scoped_to_owned_pgid(self):
        def stat(pid, pgid, utime, stime, rss):
            fields = ["S", "1", str(pgid)] + ["0"] * 8 + [str(utime), str(stime)] + ["0"] * 8 + [str(rss)]
            return f"{pid} (fixture) " + " ".join(fields)

        sample = MODULE.parse_linux_group_sample(
            [stat(10, 77, 100, 50, 4), stat(11, 77, 20, 10, 2), stat(12, 88, 900, 900, 99)],
            77,
            100,
            4096,
        )
        self.assertEqual((10, 11), sample.pids)
        self.assertAlmostEqual(1.2, sample.user_seconds)
        self.assertAlmostEqual(0.6, sample.system_seconds)
        self.assertEqual(6 * 4096, sample.rss_bytes)


class ExecutionAndAnalysisTest(unittest.TestCase):
    def test_fifo_dispatch_retains_crashes_and_metric_provenance(self):
        assignments = [assignment(f"a{index}") for index in range(1, 7)]
        assignments[1] = assignment("a2", exit_code=9, complete=False)
        order = ["a3", "a1", "a2", "a6", "a4", "a5"]
        result = MODULE.run_assignment_set(assignments, order, 2, timeout_seconds=2, environment={})
        self.assertEqual(order, result["dispatch_sequence"])
        self.assertEqual(order, [item["assignment_id"] for item in result["assignment_results"]])
        self.assertEqual(6, len(result["assignment_results"]))
        crashed = next(item for item in result["assignment_results"] if item["assignment_id"] == "a2")
        self.assertEqual("failure", crashed["status"])
        self.assertFalse(crashed["complete"])
        self.assertEqual(
            {"wall", "user", "system", "rss", "cpu", "sampled_cpu"},
            set(result["metrics"]),
        )
        self.assertTrue(all("source" in metric for metric in result["metrics"].values()))

    def test_timeout_is_retained_in_itt_denominator(self):
        assignments = [assignment(f"a{index}", delay=0.02) for index in range(1, 7)]
        assignments[0] = assignment("a1", delay=0.3)
        result = MODULE.run_assignment_set(assignments, [f"a{index}" for index in range(1, 7)], 3, timeout_seconds=0.08, environment={})
        self.assertEqual(6, len(result["assignment_results"]))
        self.assertEqual("timeout", result["assignment_results"][0]["status"])
        rates = MODULE._trial_rates(result)
        self.assertAlmostEqual(100 / 6, rates["failure_timeout_pp"])

    def test_all_pairs_uses_frozen_margins_and_highest_eligible_width(self):
        aggregates = {
            1: {"trial_count": 4, "completeness_pp": 100, "contradiction_unsupported_pp": 0, "failure_timeout_pp": 0},
            2: {"trial_count": 4, "completeness_pp": 98, "contradiction_unsupported_pp": 1, "failure_timeout_pp": 1},
            3: {"trial_count": 4, "completeness_pp": 96, "contradiction_unsupported_pp": 2, "failure_timeout_pp": 5},
            6: {"trial_count": 4, "completeness_pp": 94, "contradiction_unsupported_pp": 2, "failure_timeout_pp": 5},
        }
        selection = MODULE.select_width_all_pairs(aggregates)
        self.assertEqual(3, selection["selected_width"])
        self.assertNotIn(6, selection["eligible_widths"])
        self.assertEqual(-5.0, selection["margins_pp"]["completeness"])

    def test_contaminated_original_is_retained_and_clean_sensitivity_rerun_used(self):
        source = MODULE.validate_manifest(manifest())
        admission = MODULE.admit_heavy_run(healthy_signals())
        primary = identity(10)
        ambient_old = identity(20, "old")
        ambient_new = identity(20, "new")
        calls = {"count": 0}

        def snapshotter(panes):
            call = calls["count"]
            calls["count"] += 1
            ambient = ambient_old if call == 0 else ambient_new
            return MODULE.PaneSnapshot({"%1": primary, "%2": ambient})

        def treatment_runner(_manifest, trial, sensitivity_of):
            results = [
                {
                    "assignment_id": f"a{index}",
                    "status": "success",
                    "complete": True,
                    "contradiction_unsupported": False,
                }
                for index in range(1, 7)
            ]
            return {
                "cold_reset": {"status": "passed"},
                "warm_prime": {"status": "passed"},
                "assignment_results": results,
                "metrics": {},
            }

        result = MODULE.execute_protocol(source, admission, treatment_runner=treatment_runner, snapshotter=snapshotter)
        self.assertEqual(16, len(result["original_trials"]))
        self.assertTrue(result["original_trials"][0]["contaminated"])
        self.assertEqual(1, len(result["sensitivity_reruns"]))
        self.assertFalse(result["sensitivity_reruns"][0]["contaminated"])
        self.assertEqual(4, len(result["fixed_look_results"]))
        self.assertTrue(result["fixed_look_results"][-1]["decision_binding"])
        for look in result["fixed_look_results"]:
            self.assertTrue(all(values["trial_count"] == look["look"] for values in look["aggregates"].values()))


if __name__ == "__main__":
    unittest.main()
