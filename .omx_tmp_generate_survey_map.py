#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path

INVENTORY_PATH = Path(
    "/Volumes/SATECHI/github/barkpark/.omx/state/"
    "legendary-frozen-manifests/2026-07-16-wave-2/inventory.json"
)
SUMMARY_PATH = INVENTORY_PATH.with_name("summary.json")
OUTPUT_PATH = Path(
    "/Volumes/SATECHI/github/barkpark/.omx/handoff/"
    "legendary-wave2-survey-map.json"
)
EXPECTED_SHA256 = "218c8eb84ab1b5888695e0d6be0981ef2f22c111f2dcd5ead54d9deb11e50e64"
SURFACES = ["Studio", "TUI", "email", "public", "CLI/API"]


def ranges(count, parts):
    base, remainder = divmod(count, parts)
    cursor = 1
    result = []
    for index in range(parts):
        size = base + (1 if index < remainder else 0)
        result.append((cursor, cursor + size - 1))
        cursor += size
    assert cursor == count + 1
    return result


def sample_ordinals(start, end):
    span = end - start
    return [
        start,
        start + span // 4,
        start + span // 2,
        start + (3 * span) // 4,
        end,
    ]


raw = INVENTORY_PATH.read_bytes()
actual_sha256 = hashlib.sha256(raw).hexdigest()
if actual_sha256 != EXPECTED_SHA256:
    raise SystemExit(
        f"inventory digest mismatch: expected {EXPECTED_SHA256}, got {actual_sha256}"
    )

inventory = json.loads(raw)
summary = json.loads(SUMMARY_PATH.read_text())
papers = [unit for unit in inventory if unit["class"] == "paper"]
tasks = [unit for unit in inventory if unit["class"] == "task"]
assert len(inventory) == 1946
assert len(papers) == 262
assert len(tasks) == 1684
assert len({unit["unit_id"] for unit in inventory}) == 1946

paper_ranges = ranges(len(papers), 10)
task_ranges = ranges(len(tasks), 50)
paper_cursor = 0
task_cursor = 0
assignment_number = 0
waves = []

for wave_number in range(1, 21):
    wave_assignments = []
    lane_classes = ["paper", "task", "task"] if wave_number <= 10 else ["task"] * 3
    for slot, unit_class in enumerate(lane_classes, start=1):
        assignment_number += 1
        if unit_class == "paper":
            class_start, class_end = paper_ranges[paper_cursor]
            class_units = papers
            paper_cursor += 1
            global_start, global_end = class_start, class_end
            class_focus = [
                "Check canonical PortableDoc structure and authored-content preservation.",
                "Rate heading order, labels, reading order, narrow-width behavior, and semantic output.",
            ]
        else:
            class_start, class_end = task_ranges[task_cursor]
            class_units = tasks
            task_cursor += 1
            global_start, global_end = class_start + len(papers), class_end + len(papers)
            class_focus = [
                "Check outcome, lifecycle, parent/project/phase, exact criteria, runnable gate, and evidence or blocker.",
                "Reconcile claim epoch, dependencies, close reason, code authority, Paper linkage, and live status.",
            ]

        sample_positions = sample_ordinals(class_start, class_end)
        sample_units = [class_units[position - 1] for position in sample_positions]
        primary_surface = SURFACES[(assignment_number - 1) % len(SURFACES)]

        wave_assignments.append(
            {
                "assignment_id": f"survey-{assignment_number:03d}",
                "agent_type": "epic-surveyor",
                "effort": "medium",
                "wave": wave_number,
                "slot": slot,
                "inventory_class": unit_class,
                "ownership": {
                    "class_ordinal_start": class_start,
                    "class_ordinal_end": class_end,
                    "global_ordinal_start": global_start,
                    "global_ordinal_end": global_end,
                    "unit_count": class_end - class_start + 1,
                    "first_unit_id": class_units[class_start - 1]["unit_id"],
                    "last_unit_id": class_units[class_end - 1]["unit_id"],
                },
                "surface_plan": {
                    "primary_surface": primary_surface,
                    "full_range_instruction": (
                        f"Inspect and score all {class_end - class_start + 1} owned "
                        f"{unit_class} units on {primary_surface}; also read each revision "
                        "through CLI/API as the canonical comparison source."
                    ),
                    "all_surface_sample_size": 5,
                    "all_surface_sample_ordinals": sample_positions,
                    "all_surface_sample_unit_ids": [
                        unit["unit_id"] for unit in sample_units
                    ],
                    "all_surface_sample_instruction": (
                        "For each named sample unit, compare the same frozen revision on "
                        "Studio, TUI, email, public, and CLI/API; record non-empty semantic "
                        "equivalence, structure/reading order, clipping or overflow, and verdict."
                    ),
                },
                "class_focus": class_focus,
                "comparison_instruction": (
                    "Name the three highest-scoring and three lowest-scoring owned units "
                    "(or every unit if fewer than three), explain the measurable differences, "
                    "and extract repair rules that can be applied to the rest of the inventory."
                ),
                "required_result": {
                    "owned_units_checked": class_end - class_start + 1,
                    "scored_units_required": class_end - class_start + 1,
                    "all_surface_samples_required": 5,
                    "result_buckets": ["found", "not_found", "partial"],
                    "required_fields": [
                        "direct_answer",
                        "checked_unit_ids_and_revisions",
                        "score_and_verdict_per_unit",
                        "found_not_found_partial_counts",
                        "best_examples",
                        "repair_candidates",
                        "all_surface_sample_evidence",
                        "risks",
                        "unvisited_ranges",
                        "durable_evidence_path",
                    ],
                    "completion_rule": (
                        "found + not_found + partial must equal owned_units_checked; "
                        "unvisited_ranges must be empty or name every missed ordinal explicitly."
                    ),
                },
            }
        )
    waves.append({"wave": wave_number, "width": 3, "assignments": wave_assignments})

assert assignment_number == 60
assert paper_cursor == 10
assert task_cursor == 50

all_assignments = [
    assignment for wave in waves for assignment in wave["assignments"]
]
primary_distribution = {
    surface: sum(
        assignment["surface_plan"]["primary_surface"] == surface
        for assignment in all_assignments
    )
    for surface in SURFACES
}

artifact = {
    "schema_version": "legendary-survey-map-v1",
    "wave_id": "legendary-paper-task-quality-takeover-wave-2-2026-07-16",
    "phase": "survey",
    "profile": "legendary",
    "read_only": True,
    "production_mutations_allowed": False,
    "source": {
        "strategy_handoff": (
            "/Volumes/SATECHI/github/barkpark/.omx/handoff/"
            "legendary-wave2-strategy-authoring.md"
        ),
        "inventory_path": str(INVENTORY_PATH),
        "summary_path": str(SUMMARY_PATH),
        "frozen_at": summary["frozen_at"],
        "inventory_sha256": actual_sha256,
        "unit_definition": (
            "one revision-pinned published Barkpark document identified by "
            "paper:<document_id> or task:<document_id>"
        ),
    },
    "inventory": {
        "papers": len(papers),
        "tasks": len(tasks),
        "total": len(inventory),
        "unique_class_prefixed_unit_ids": len(
            {unit["unit_id"] for unit in inventory}
        ),
        "cross_class_source_id_collisions": summary["cross_class_collisions"],
    },
    "execution": {
        "agent_type": "epic-surveyor",
        "effort": "medium",
        "assignment_count": 60,
        "wave_count": 20,
        "concurrency_width": 3,
        "waves_run_sequentially": True,
        "failure_threshold": 0,
    },
    "ownership_model": {
        "ordering": (
            "Use the frozen inventory order. Class ordinals are one-based within "
            "paper or task; global ordinals are one-based across the full inventory."
        ),
        "paper_partition": "10 contiguous, class-pure ranges covering paper ordinals 1-262 once",
        "task_partition": "50 contiguous, class-pure ranges covering task ordinals 1-1684 once",
        "overlap_allowed": False,
        "unowned_units_allowed": False,
    },
    "quality_rating": {
        "score_range": "0-100 integer",
        "hard_gate_rule": (
            "Any failed hard gate must be named; a unit with an unresolved hard-gate "
            "failure cannot receive gold or strong."
        ),
        "verdicts": [
            {"verdict": "gold", "min": 90, "max": 100},
            {"verdict": "strong", "min": 75, "max": 89},
            {"verdict": "serviceable", "min": 60, "max": 74},
            {"verdict": "repair", "min": 30, "max": 59},
            {"verdict": "quarantine", "min": 0, "max": 29},
        ],
        "comparison_rule": (
            "Compare lower-scoring units to the assignment's highest-scoring examples "
            "using the same rubric dimensions and name the observable differences."
        ),
    },
    "shared_surface_requirements": {
        "target_surfaces": SURFACES,
        "Studio": [
            "non-empty authored content",
            "canonical structure and heading/label order",
            "no narrow-width clipping",
        ],
        "TUI": [
            "non-empty semantic equivalent",
            "stable reading order and labels",
            "no terminal-width clipping",
        ],
        "email": [
            "non-empty semantic equivalent",
            "safe linear reading order",
            "no overflow or missing essential fields",
        ],
        "public": [
            "non-empty published semantic equivalent",
            "valid headings and accessible reading order",
            "no narrow-width clipping",
        ],
        "CLI/API": [
            "frozen document_id and document_rev match",
            "canonical fields and authored content are present",
            "rerun returns an idempotent equivalent result",
        ],
    },
    "coverage_summary": {
        "paper_assignments": 10,
        "task_assignments": 50,
        "owned_paper_units": 262,
        "owned_task_units": 1684,
        "owned_total_units": 1946,
        "primary_surface_assignments": primary_distribution,
        "all_surface_sample_units": 60 * 5,
        "all_surface_sample_units_are_unique": True,
    },
    "waves": waves,
}

OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
OUTPUT_PATH.write_text(json.dumps(artifact, indent=2) + "\n")
print(OUTPUT_PATH)
