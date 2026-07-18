#!/usr/bin/env python3
"""Minimal bp stand-in used by the B1 scope-fence contract tests."""

import json
import os
import sys
from pathlib import Path


expected = ["-w", "acme", "-p", "tasks", "--json", "cycle", "show", "task-quality-standard-chrono-root-2026-07-18", "task-quality-standard-chrono-wave-3-2026-07-18"]
if sys.argv[1:] != expected:
    print(json.dumps({"expected": expected, "actual": sys.argv[1:]}), file=sys.stderr)
    raise SystemExit(64)

log_path = os.environ.get("B1_FAKE_BP_LOG")
if log_path:
    Path(log_path).write_text(json.dumps(sys.argv[1:], separators=(",", ":")), encoding="utf-8")

payload_path = os.environ.get("B1_FAKE_CYCLE_JSON")
if not payload_path:
    print("B1_FAKE_CYCLE_JSON is required", file=sys.stderr)
    raise SystemExit(65)
sys.stdout.buffer.write(Path(payload_path).read_bytes())
