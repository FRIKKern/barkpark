#!/usr/bin/env python3
"""Contract and adversarial tests for the repository-owned B1 exporter."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "export_cyclefleet_b1.py"
FIXTURES = HERE / "fixtures"
LIVE = FIXTURES / "task-quality-cycle-show.json"
GOOD_B1 = FIXTURES / "task-quality-b1.json"
FOREIGN_B1 = FIXTURES / "foreign-legendary-quality-takeover-b1.json"
FAKE_BP = FIXTURES / "fake_bp.py"
EPIC_VALIDATOR = HERE.parents[1] / ".codex" / "skills" / "epic-cycle" / "scripts" / "validate_epic_cycle.py"

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PROJECT_ID = "22222222-2222-4222-8222-222222222222"
EPIC_ID = "task-quality-standard-chrono-root-2026-07-18"
WAVE_ID = "task-quality-standard-chrono-wave-3-2026-07-18"
REVISION = "33333333-3333-4333-8333-333333333333"
INVENTORY = "a" * 64
PLAN = "b" * 64

spec = importlib.util.spec_from_file_location("b1_scope_fence", SCRIPT)
assert spec and spec.loader
b1_scope_fence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b1_scope_fence)

validator_spec = importlib.util.spec_from_file_location("scope_fence_epic_validator", EPIC_VALIDATOR)
assert validator_spec and validator_spec.loader
epic_validator = importlib.util.module_from_spec(validator_spec)
validator_spec.loader.exec_module(epic_validator)
epic_validator.CYCLE_PHASE = "legendary"
epic_validator.FLEET_SPECS = {
    "survey": ("epic-surveyor", 60),
    "verify": ("epic-verifier", 30),
    "experiment": ("legendary-experimenter", 15),
    "build": ("legendary-builder", 15),
    "review": ("code-reviewer", 15),
}


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()


def sha(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


class ScopeFenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.log = self.root / "bp-argv.json"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def command(self, output: Path) -> list[str]:
        return [
            sys.executable,
            str(SCRIPT),
            "--workspace", "acme",
            "--project", "tasks",
            "--workspace-id", WORKSPACE_ID,
            "--project-id", PROJECT_ID,
            "--epic-id", EPIC_ID,
            "--wave-id", WAVE_ID,
            "--wave-revision", REVISION,
            "--inventory-digest", INVENTORY,
            "--plan-digest", PLAN,
            "--output", str(output),
            "--bp", str(FAKE_BP),
        ]

    def run_export(self, output: Path, live: Path = LIVE, command: list[str] | None = None) -> subprocess.CompletedProcess[bytes]:
        environment = os.environ.copy()
        environment["B1_FAKE_CYCLE_JSON"] = str(live)
        environment["B1_FAKE_BP_LOG"] = str(self.log)
        return subprocess.run(command or self.command(output), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=False)

    def assert_untouched(self, output: Path, before: bytes = b"sentinel") -> None:
        self.assertEqual(output.read_bytes(), before)
        self.assertEqual(list(output.parent.glob(f".{output.name}.*.tmp")), [])

    def live_variant(self, mutate) -> Path:
        payload = json.loads(LIVE.read_text(encoding="utf-8"))
        mutate(payload)
        path = self.root / f"live-{len(list(self.root.glob('live-*.json')))}.json"
        path.write_bytes(canonical(payload))
        return path

    def test_exports_direct_deterministic_benchmark(self) -> None:
        first = self.root / "first.json"
        second = self.root / "second.json"
        completed = self.run_export(first)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        completed = self.run_export(second)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(first.read_bytes(), GOOD_B1.read_bytes())
        self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), "64d5cbfc106ced39ae15e209e81a454a79ebea0565e054f7a49827eb3eda4016")

        expected_argv = ["-w", "acme", "-p", "tasks", "--json", "cycle", "show", EPIC_ID, WAVE_ID]
        self.assertEqual(json.loads(self.log.read_text(encoding="utf-8")), expected_argv)
        document = json.loads(first.read_bytes())
        self.assertEqual(document["format"], "barkpark-epic-benchmark-v1")
        self.assertNotIn("benchmark", document)
        self.assertEqual(set(document["experiment"]), {"workspace_id", "epic_id", "wave_id", "experiment_id", "phase", "protocol_version"})
        self.assertEqual(document["experiment"]["epic_id"], EPIC_ID)

        fleet = json.loads(LIVE.read_text(encoding="utf-8"))["fleet"]
        manifest = document["manifest"]
        self.assertEqual(manifest["fleet_contract"], {"version": 1, "paper_fleet_digest": sha(fleet)})
        fence = manifest["cycle_scope_fence"]
        self.assertEqual(set(fence), {
            "version", "workspace_id", "project_id", "epic_id", "wave_id", "wave_revision",
            "inventory_digest", "plan_digest", "reconciliation_digest", "fleet_digest", "receipt_digest",
        })
        self.assertEqual(fence["version"], "b1-scope-fence-v1")
        self.assertEqual(fence["project_id"], PROJECT_ID)
        self.assertEqual(fence["inventory_digest"], INVENTORY)
        self.assertEqual(fence["plan_digest"], PLAN)
        self.assertEqual(fence["fleet_digest"], sha(fleet))
        self.assertEqual(fence["receipt_digest"], sha({key: value for key, value in fence.items() if key != "receipt_digest"}))

        self.assertEqual(len(document["attempts"]), 5)
        attempt = document["attempts"][0]
        self.assertEqual(attempt["provenance"]["wave_revision"], REVISION)
        self.assertEqual(attempt["provenance"]["scope_receipt_digest"], fence["receipt_digest"])
        self.assertEqual(attempt["payload"]["fleet_assignment"], {
            "phase": "survey",
            "assignment_id": "survey-01",
            "agent_type": "epic-surveyor",
            "evidence": "paper://survey-01",
            "model_reasoning_effort": "medium",
        })
        b1_scope_fence.validate_benchmark(document, {
            "workspace_id": WORKSPACE_ID,
            "project_id": PROJECT_ID,
            "epic_id": EPIC_ID,
            "wave_id": WAVE_ID,
            "wave_revision": REVISION,
            "inventory_digest": INVENTORY,
            "plan_digest": PLAN,
        })

    def test_golden_reconciles_with_epic_validator_in_legendary_mode(self) -> None:
        cycle = json.loads(LIVE.read_text(encoding="utf-8"))
        ledger = json.loads(GOOD_B1.read_text(encoding="utf-8"))
        paper = {"blocks": [{"type": "callout", "title": "Agent fleet", "fleet": cycle["fleet"]}]}
        errors = epic_validator.validate_ledger(ledger, paper, EPIC_ID, WAVE_ID)
        self.assertEqual(errors, [])

    def test_preserved_foreign_legacy_is_canonical_but_rejected_for_expected_scope(self) -> None:
        raw = FOREIGN_B1.read_bytes()
        self.assertEqual(len(raw), 124_072)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), "1dae810c0492f0eda77c8981b795884f145e4a9cd177f3d85df0ddcc0f922d2f")
        legacy = json.loads(raw)
        self.assertEqual(raw, canonical(legacy))
        b1_scope_fence.validate_benchmark(legacy)
        expected = {
            "workspace_id": WORKSPACE_ID,
            "project_id": PROJECT_ID,
            "epic_id": EPIC_ID,
            "wave_id": WAVE_ID,
            "wave_revision": REVISION,
            "inventory_digest": INVENTORY,
            "plan_digest": PLAN,
        }
        with self.assertRaisesRegex(b1_scope_fence.FenceError, "B1 experiment epic_id mismatch"):
            b1_scope_fence.validate_benchmark(legacy, expected)

    def test_live_scope_and_digest_drift_fail_closed(self) -> None:
        cases = {
            "authority kind drift": lambda value: value["authority"].__setitem__("kind", "barkpark_paper_projection"),
            "profile drift": lambda value: value["cycle_ledger"].__setitem__("profile", "epic"),
            "foreign epic": lambda value: value["authority"].__setitem__("epic_id", "foreign-epic"),
            "wrong wave": lambda value: value["authority"].__setitem__("wave_id", "wrong-wave"),
            "stale revision": lambda value: value["authority"].__setitem__("wave_revision", "44444444-4444-4444-8444-444444444444"),
            "cross project": lambda value: value["authority"].__setitem__("project_id", "55555555-5555-4555-8555-555555555555"),
            "authority workspace drift": lambda value: value["authority"].__setitem__("workspace_id", "77777777-7777-4777-8777-777777777777"),
            "inventory drift": lambda value: value["cycle_ledger"].__setitem__("inventory_digest", "d" * 64),
            "plan drift": lambda value: value["cycle_ledger"].__setitem__("plan_digest", "e" * 64),
            "selector drift": lambda value: value["authority"]["connection"]["project"].__setitem__("slug", "other"),
            "ledger scope drift": lambda value: value["cycle_ledger"]["scope"].__setitem__("workspace_id", "66666666-6666-4666-8666-666666666666"),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                output = self.root / f"{label.replace(' ', '-')}.json"
                output.write_bytes(b"sentinel")
                completed = self.run_export(output, live=self.live_variant(mutate))
                self.assertEqual(completed.returncode, 2)
                self.assert_untouched(output)

    def test_partial_configuration_fails_before_bp_and_preserves_output(self) -> None:
        output = self.root / "partial.json"
        output.write_bytes(b"sentinel")
        command = self.command(output)
        index = command.index("--plan-digest")
        del command[index:index + 2]
        completed = self.run_export(output, command=command)
        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.log.exists())
        self.assert_untouched(output)

    def test_bp_failure_is_fail_closed(self) -> None:
        output = self.root / "bp-failed.json"
        output.write_bytes(b"sentinel")
        command = self.command(output)
        command[command.index(str(FAKE_BP))] = str(self.root / "missing-bp")
        completed = self.run_export(output, command=command)
        self.assertEqual(completed.returncode, 2)
        self.assert_untouched(output)


if __name__ == "__main__":
    unittest.main()
