#!/usr/bin/env python3

import importlib.util
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "scripts" / "run_concurrency_benchmark.py"
FIXTURES = Path(__file__).parent / "fixtures"
SPEC = importlib.util.spec_from_file_location("run_concurrency_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def assignment(assignment_id, *, exit_code=0, complete=True, contradiction=False, delay=0.08):
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


def retrieval_record(index):
    assignment_id = MODULE.RETRIEVAL_UNIT_IDS[index - 1]
    return {
        "id": assignment_id,
        "schema_version": MODULE.RETRIEVAL_CORPUS_SCHEMA_VERSION,
        "repo": {"commit": MODULE.RETRIEVAL_REPO_COMMIT},
        "gold_claims": [
            {
                "claim_id": f"C{claim}",
                "text": f"claim {claim}",
                "evidence": [f"S1:L{claim}-L{claim + 1}"],
            }
            for claim in range(1, 4)
        ],
        "sources": [{"source_id": "S1", "path": f"fixture-{index}.txt"}],
    }


def cycle_attribution(index):
    value = json.loads(
        (FIXTURES / "retrieval_cycle_assignment_v1.json").read_text(encoding="utf-8")
    )
    assignment_id = MODULE.RETRIEVAL_UNIT_IDS[index - 1]
    value["assignment_id"] = assignment_id
    value["unit_ids"] = [assignment_id]
    value["cycle_assignment_uuid"] = f"00000000-0000-4000-8000-{index:012d}"
    value["task"]["doc_id"] = f"codex-epic-cycle-w3-survey-{index:02d}"
    value["task"]["worker_id"] = f"codex-epic-cycle-w3-surveyor-{index:02d}"
    return value


def usage_receipt(index):
    value = json.loads(
        (FIXTURES / "retrieval_usage_receipt_v1.json").read_text(encoding="utf-8")
    )
    value["provider_session_id"] = f"session-{index:02d}"
    value["provider_turn_id"] = f"turn-{index:02d}"
    return value


def retrieval_evaluation(index):
    record = retrieval_record(index)
    return {
        "complete": True,
        "witnesses": [
            {
                "claim_id": claim["claim_id"],
                "verdict": "supported",
                "evidence": [claim["evidence"][0]],
            }
            for claim in record["gold_claims"]
        ],
        "attribution": cycle_attribution(index),
        "usage": usage_receipt(index),
    }


def write_retrieval_corpus(root):
    raw = "".join(
        json.dumps(retrieval_record(index), sort_keys=True, separators=(",", ":")) + "\n"
        for index in range(1, 7)
    ).encode("utf-8")
    path = Path(root) / "corpus.jsonl"
    path.write_bytes(raw)
    return path, hashlib.sha256(raw).hexdigest()


def retrieval_manifest(path, digest):
    assignments = []
    for index, assignment_id in enumerate(MODULE.RETRIEVAL_UNIT_IDS, start=1):
        payload = json.dumps(retrieval_evaluation(index), separators=(",", ":"))
        assignments.append(
            {
                "id": assignment_id,
                "argv": [sys.executable, "-c", f"print({payload!r})"],
                "attribution": cycle_attribution(index),
            }
        )
    return {
        "schema_version": MODULE.RETRIEVAL_SCHEMA_VERSION,
        "seed": MODULE.SEED,
        "assignments": assignments,
        "corpus": {
            "path": str(path),
            "sha256": digest,
            "repo_commit": MODULE.RETRIEVAL_REPO_COMMIT,
            "schema_version": MODULE.RETRIEVAL_CORPUS_SCHEMA_VERSION,
            "unit_ids": list(MODULE.RETRIEVAL_UNIT_IDS),
        },
        "cold_reset_argv": [sys.executable, "-c", "pass"],
        "warm_prime_argv": [sys.executable, "-c", "pass"],
        "primary_pane": "%1",
        "tmux_panes": ["%1"],
        "timeout_seconds": 2,
        "environment": {},
    }


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

    def test_v1_plan_golden_bytes_remain_frozen(self):
        source = {
            **manifest(),
            "assignments": [
                {"id": f"a{index}", "argv": ["fixture", f"a{index}"]}
                for index in range(1, 7)
            ],
            "cold_reset_argv": ["fixture", "cold"],
            "warm_prime_argv": ["fixture", "warm"],
        }
        self.assertEqual(
            "e11ca3cea9fd23284e209331c047f947b5ee8719af8df9693e7a8570ec39929b",
            hashlib.sha256(MODULE.canonical_json(MODULE.plan_artifact(source)).encode()).hexdigest(),
        )


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

    def test_v2_admits_only_the_exact_preregistered_corpus_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, digest = write_retrieval_corpus(temporary)
            with mock.patch.object(MODULE, "RETRIEVAL_CORPUS_SHA256", digest):
                source = retrieval_manifest(path, digest)
                normalized = MODULE.validate_manifest(source)
                self.assertEqual(MODULE.RETRIEVAL_SCHEMA_VERSION, normalized["schema_version"])
                path.write_bytes(path.read_bytes() + b" ")
                with self.assertRaisesRegex(MODULE.ProtocolError, "bytes"):
                    MODULE.validate_manifest(source)

    def test_v2_rejects_attribution_scope_task_and_fence_mismatches(self):
        record = retrieval_record(1)
        expected = cycle_attribution(1)
        for path, replacement in (
            (("cycle_assignment_uuid",), "00000000-0000-4000-8000-000000000099"),
            (("wave_id",), "foreign-wave"),
            (("task", "doc_id"), "foreign-task"),
            (("task", "claim_epoch"), 6),
            (("task", "work_digest"), "ffffffffffffffff"),
        ):
            with self.subTest(path=path):
                evaluation = retrieval_evaluation(1)
                target = evaluation["attribution"]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                parsed = MODULE.parse_retrieval_evaluation(
                    json.dumps(evaluation), record, expected
                )
                self.assertEqual("invalid", parsed["vui"]["state"])
                self.assertEqual("invalid", parsed["usage"]["state"])


class RetrievalEvidenceTest(unittest.TestCase):
    def test_vui_scoring_distinguishes_complete_absent_contradictory_and_tampered_evidence(self):
        record = retrieval_record(1)
        complete, contradiction = MODULE.score_vui(record, retrieval_evaluation(1)["witnesses"])
        self.assertEqual(("observed", 3, False), (complete["state"], complete["value"], contradiction))

        absent, contradiction = MODULE.score_vui(record, retrieval_evaluation(1)["witnesses"][:-1])
        self.assertEqual("missing", absent["state"])
        self.assertTrue(contradiction)

        witnesses = retrieval_evaluation(1)["witnesses"]
        witnesses[0]["verdict"] = "contradicted"
        contradicted, contradiction = MODULE.score_vui(record, witnesses)
        self.assertEqual("invalid", contradicted["state"])
        self.assertTrue(contradiction)

        witnesses = retrieval_evaluation(1)["witnesses"]
        witnesses[0]["evidence"] = ["S9:L1-L999"]
        tampered, _ = MODULE.score_vui(record, witnesses)
        self.assertEqual("invalid", tampered["state"])

    def test_usage_receipts_preserve_unsupported_missing_invalid_and_observed(self):
        observed = MODULE.validate_usage_receipt(usage_receipt(1))
        self.assertEqual("observed", observed["state"])
        for state in ("unsupported", "missing", "invalid"):
            self.assertEqual(
                state,
                MODULE.validate_usage_receipt({"state": state, "reason": "fixture"})["state"],
            )
        decreasing = usage_receipt(1)
        decreasing["terminal_tokens"] = 99
        self.assertEqual("invalid", MODULE.validate_usage_receipt(decreasing)["state"])

    def test_semantic_cold_and_warm_postconditions_are_exact(self):
        corpus = {
            "sha256": "a" * 64,
            "unit_ids": list(MODULE.RETRIEVAL_UNIT_IDS),
        }
        cold = {
            "schema_version": MODULE.RETRIEVAL_CONTROL_SCHEMA_VERSION,
            "state": "cold",
            "corpus_sha256": corpus["sha256"],
            "unit_ids": corpus["unit_ids"],
            "cache_entries": 0,
        }
        warm = {
            "schema_version": MODULE.RETRIEVAL_CONTROL_SCHEMA_VERSION,
            "state": "warm",
            "corpus_sha256": corpus["sha256"],
            "unit_ids": corpus["unit_ids"],
            "primed_unit_ids": corpus["unit_ids"],
        }
        self.assertEqual("measured", MODULE.validate_control_proof(json.dumps(cold), "cold", corpus)["kind"])
        self.assertEqual("measured", MODULE.validate_control_proof(json.dumps(warm), "warm", corpus)["kind"])
        cold["cache_entries"] = 1
        with self.assertRaises(MODULE.SafetyError):
            MODULE.validate_control_proof(json.dumps(cold), "cold", corpus)

    def test_end_to_end_v2_assignment_fixture_scores_costs_and_redacts_native_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, digest = write_retrieval_corpus(temporary)
            with mock.patch.object(MODULE, "RETRIEVAL_CORPUS_SHA256", digest):
                source = MODULE.validate_manifest(retrieval_manifest(path, digest))
                result = MODULE.run_assignment_set(
                    source["assignments"],
                    list(MODULE.RETRIEVAL_UNIT_IDS),
                    3,
                    timeout_seconds=2,
                    environment={},
                    corpus=source["corpus"],
                )
        self.assertEqual("observed", result["metrics"]["token_cost"]["state"])
        self.assertEqual(270, result["metrics"]["token_cost"]["value"])
        self.assertEqual("observed", result["metrics"]["verified_unique_information"]["state"])
        self.assertEqual(18, result["metrics"]["verified_unique_information"]["value"])
        self.assertEqual("unsupported", result["metrics"]["context_cost"]["state"])
        self.assertTrue(
            all(item["stdout_tail"].startswith("[REDACTED") for item in result["assignment_results"])
        )

    def test_duplicate_provider_identity_is_invalid_and_secret_bearing_payload_is_not_echoed(self):
        first = {"usage": usage_receipt(1), "complete": True, "contradiction_unsupported": False}
        second = {"usage": usage_receipt(1), "complete": True, "contradiction_unsupported": False}
        MODULE.reject_duplicate_usage_identities([first, second])
        self.assertEqual("invalid", first["usage"]["state"])
        self.assertEqual("invalid", second["usage"]["state"])

        evaluation = retrieval_evaluation(1)
        evaluation["api_token"] = "must-not-survive"
        parsed = MODULE.parse_retrieval_evaluation(
            json.dumps(evaluation), retrieval_record(1), cycle_attribution(1)
        )
        self.assertEqual("invalid", parsed["usage"]["state"])
        self.assertNotIn("must-not-survive", MODULE.canonical_json(parsed))


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

    def test_capacity_lease_enforces_exclusive_one_and_at_most_two(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with MODULE.HeavyCapacityLease(1, root):
                with self.assertRaises(MODULE.SafetyError):
                    with MODULE.HeavyCapacityLease(2, root):
                        pass
            with MODULE.HeavyCapacityLease(2, root) as first:
                with MODULE.HeavyCapacityLease(2, root) as second:
                    self.assertEqual({0, 1}, {first.slot_index, second.slot_index})
                    with self.assertRaises(MODULE.SafetyError):
                        with MODULE.HeavyCapacityLease(2, root):
                            pass

    def test_primary_fence_must_match_admitted_pid_start_identity(self):
        expected = identity(10, "old")
        MODULE.assert_primary_fence(MODULE.PaneSnapshot({"%1": expected}), "%1", expected)
        with self.assertRaisesRegex(MODULE.SafetyError, "fence changed"):
            MODULE.assert_primary_fence(MODULE.PaneSnapshot({"%1": identity(10, "new")}), "%1", expected)


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

    def test_empty_owned_group_has_unknown_rss_instead_of_measured_zero(self):
        linux = MODULE.parse_linux_group_sample([], 77, 100, 4096)
        self.assertEqual((), linux.pids)
        self.assertIsNone(linux.rss_bytes)
        sampler = MODULE.OwnedGroupSampler()

        def sample_once(pgid):
            sampler._stop.set()
            return linux

        sampler._sample = sample_once
        sampler.register(77)
        sampler._loop()
        self.assertIsNone(sampler.peak_rss_bytes)


class ExecutionAndAnalysisTest(unittest.TestCase):
    def test_fast_control_command_is_fenced_before_exec(self):
        result = MODULE.run_control_command(
            [sys.executable, "-c", "pass"],
            dict(os.environ),
            1.0,
            "fixture reset",
        )
        self.assertEqual("passed", result["status"])
        self.assertEqual(result["process_identity"]["pid"], result["pgid"])

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
            {
                "wall",
                "user",
                "system",
                "rss",
                "cpu",
                "sampled_cpu",
                "token_cost",
                "context_cost",
                "verified_unique_information",
            },
            set(result["metrics"]),
        )
        self.assertTrue(all("source" in metric for metric in result["metrics"].values()))
        for name in ("token_cost", "context_cost", "verified_unique_information"):
            self.assertEqual("unsupported", result["metrics"][name]["kind"])
            self.assertIsNone(result["metrics"][name]["value"])
        self.assertTrue(
            all("launch/fence" in item["wall_scope"] for item in result["assignment_results"])
        )

    def test_timeout_is_retained_in_itt_denominator(self):
        assignments = [assignment(f"a{index}", delay=0.08) for index in range(1, 7)]
        assignments[0] = assignment("a1", delay=0.5)
        # Width one isolates the timeout assertion from concurrent process-start
        # fencing cost on slower Darwin CI hosts.
        result = MODULE.run_assignment_set(assignments, [f"a{index}" for index in range(1, 7)], 1, timeout_seconds=0.2, environment={})
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
        self.assertEqual("unsupported", selection["statistically_fastest_width"]["kind"])
        self.assertIsNone(selection["statistically_fastest_width"]["value"])
        self.assertEqual("unsupported", selection["knee_width"]["kind"])
        self.assertIsNone(selection["knee_width"]["value"])
        self.assertIn("not a statistically-fastest or knee estimate", selection["interpretation"])

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
        scope = result["contamination_scope"]
        self.assertIn("host_load1_drift", scope["not_monitored"])
        self.assertEqual("unsupported", scope["not_monitored"]["host_load1_drift"]["kind"])
        self.assertEqual("unsupported", scope["not_monitored"]["memory_available_drift"]["kind"])

    def test_default_controls_report_command_success_without_claiming_semantics(self):
        source = MODULE.validate_manifest(manifest())
        trial = MODULE.plan_artifact(source)["schedule"][0]
        result = MODULE.default_treatment_runner(source, trial, None)
        self.assertEqual("passed", result["cold_reset"]["status"])
        self.assertEqual("unsupported", result["cold_reset"]["semantic_verification"]["kind"])
        self.assertEqual("passed", result["warm_prime"]["status"])
        self.assertEqual("unsupported", result["warm_prime"]["semantic_verification"]["kind"])


if __name__ == "__main__":
    unittest.main()
