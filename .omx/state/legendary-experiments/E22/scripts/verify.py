#!/usr/bin/env python3
from __future__ import annotations

import argparse, json, tempfile
from pathlib import Path
from build_blocked import build
from common import CANDIDATE_DIGEST, ENV_NAMES, ROOT, SURFACES, assert_no_secret_values, physical_hash, require


NAMES=("deployment-manifest.json","session-manifest.json","provenance-manifest.json","capture-index.json","rollback.json","result.json")


def validate(root: Path) -> dict:
    pre=json.loads((ROOT/"preflight.json").read_text()); index=json.loads((root/"capture-index.json").read_text()); rollback=json.loads((root/"rollback.json").read_text()); result=json.loads((root/"result.json").read_text())
    require(pre["input_gate_passed"] is True,"frozen input drift")
    require(index["attempt_count"]==len(index["rows"])==108,"exact 108 cells")
    require(len({(r["fixture_id"],r["surface"]) for r in index["rows"]})==108,"duplicate cells")
    require({r["surface"] for r in index["rows"]}==set(SURFACES),"surface drift")
    require(len({r["fixture_id"] for r in index["rows"]})==36,"fixture drift")
    require(rollback["fixture_records_removed_or_untouched"]==36 and rollback["rollback_coverage_percent"]==100,"rollback 36/36")
    require(rollback["zero_residual_records"] is True and rollback["production_mutations"]==0,"teardown boundary")
    if result["verdict"]["quality"]=="BLOCKED":
        require(pre["deployment_authorized"] is False,"authorized runtime cannot use blocked result")
        require(index["accepted_capture_count"]==0 and index["blocked_cells"]==108,"blocked reconciliation")
        for row in index["rows"]:
            require(physical_hash(root/row["path"])==row["attempt_sha256"],"attempt hash drift")
            attempt=json.loads((root/row["path"]).read_text())
            require(attempt["candidate_digest"]==CANDIDATE_DIGEST and attempt["accepted_capture"] is False,"blocked attempt provenance")
            require(attempt["proxy_derived"] is False and attempt["silent_blank"] is False and attempt["explicit_error"],"blocked attempt honesty")
    else:
        require(result["verdict"]["quality"]=="PASS" and index["accepted_capture_count"]==108,"PASS requires all captures")
    assert_no_secret_values([p for p in root.rglob("*") if p.is_file()])
    return result


def main() -> None:
    p=argparse.ArgumentParser(); p.add_argument("--require-cells",type=int,required=True); p.add_argument("--require-provenance",action="store_true",required=True); p.add_argument("--replays",type=int,required=True); a=p.parse_args()
    require(a.require_cells==108 and a.replays==2,"immutable verifier arguments")
    result=validate(ROOT)
    if result["verdict"]["quality"]=="BLOCKED":
        with tempfile.TemporaryDirectory(prefix="e22-replay-") as tmp:
            first,second=Path(tmp)/"first",Path(tmp)/"second"; build(first); build(second)
            validate(first); validate(second)
            for name in NAMES: require((first/name).read_bytes()==(second/name).read_bytes()==(ROOT/name).read_bytes(),f"replay drift {name}")
            for row in json.loads((ROOT/"capture-index.json").read_text())["rows"]: require((first/row["path"]).read_bytes()==(second/row["path"]).read_bytes()==(ROOT/row["path"]).read_bytes(),f"replay drift {row['path']}")
    print(f"E22 REPLAY PASS verdict={result['verdict']['quality']} captures={result['counts']['accepted_captures']} attempts=108 rollback=36/36 replays=2")


if __name__=="__main__": main()
