#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/e21-replay.XXXXXX")"
trap 'trash "$TMP" 2>/dev/null || true' EXIT

python3 -m py_compile "$ROOT"/scripts/*.py
python3 "$ROOT/scripts/build.py" --out "$TMP/pass-1"
python3 "$ROOT/scripts/build.py" --out "$TMP/pass-2"
python3 - "$TMP/pass-1" "$TMP/pass-2" "$ROOT" <<'PY'
import hashlib, json, pathlib, sys

first, second, root = map(pathlib.Path, sys.argv[1:])
files = [
    "adversarial-accounting.json",
    "cell-reconciliation.json",
    "gate-matrix.json",
    "input-manifest.json",
    "result.json",
    "rollback-quarantine.json",
]

def hashes(base):
    return {name: hashlib.sha256((base / name).read_bytes()).hexdigest() for name in files}

pass_1 = hashes(first)
pass_2 = hashes(second)
if pass_1 != pass_2:
    raise SystemExit("E21 REPLAY FAIL: deterministic artifact hashes differ")
(root / "replay-hashes.json").write_text(json.dumps({
    "schema_version": "legendary-e21-replay-hashes/v1",
    "replays": 2,
    "byte_stable": True,
    "pass_1": pass_1,
    "pass_2": pass_2,
}, sort_keys=True, separators=(",", ":")) + "\n")
print("E21 REPLAY PASS passes=2 byte_stable=true files=6")
PY
python3 "$ROOT/scripts/build.py" --out "$ROOT"
python3 "$ROOT/scripts/verify.py"
