#!/usr/bin/env python3
"""Exact E10 builder gate. It must fail closed while no winner exists."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expect-blocked", action="store_true")
    args = parser.parse_args()
    result = json.loads((ROOT / "result.json").read_text())
    verdict = result["verdict"]
    blocked = (
        verdict["winner_selected"] is False
        and verdict["action"] == "REWORK"
        and verdict["quality"] == "BLOCKED"
        and result["counts"]["winners"] == 0
        and result["counts"]["thresholds_blocked_or_failed"] > 0
    )
    if blocked and args.expect_blocked:
        print("E10 EXPECTED BLOCK CONFIRMED")
        return 0
    if blocked:
        print("E10 BUILDER GATE BLOCKED")
        return 42
    if args.expect_blocked:
        print("E10 EXPECTED BLOCK MISSING")
        return 1
    print("E10 BUILDER GATE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
