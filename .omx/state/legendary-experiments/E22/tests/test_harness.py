from __future__ import annotations

import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]; SCRIPTS=ROOT/"scripts"; sys.path.insert(0,str(SCRIPTS))
from common import classify_runtime, fixture_ids
from build_blocked import build


class HarnessTest(unittest.TestCase):
    def test_inventory_is_exact(self): self.assertEqual(len(fixture_ids()),36)
    def test_missing_authority_blocks_without_values(self):
        with patch.dict(os.environ,{k:"" for k in ("E22_ISOLATED_BASE_URL","E22_DATABASE_URL","E22_ADMIN_TOKEN")},clear=False):
            r=classify_runtime(120,True); self.assertFalse(r["ready"]); self.assertIn("AUTHORIZED_ISOLATED_RUNTIME_VALUES_UNAVAILABLE",r["reasons"])
    def test_production_is_rejected(self):
        env={"E22_ISOLATED_BASE_URL":"https://api.barkpark.cloud","E22_DATABASE_URL":"postgres://x@prod/production","E22_ADMIN_TOKEN":"secret"}
        with patch.dict(os.environ,env,clear=False):
            r=classify_runtime(120,True); self.assertFalse(r["ready"]); self.assertTrue(any("PRODUCTION" in x for x in r["reasons"]))
    def test_ttl_over_120_rejected(self):
        with self.assertRaises(ValueError): classify_runtime(121,True)
    def test_blocked_build_is_deterministic(self):
        with tempfile.TemporaryDirectory() as a,tempfile.TemporaryDirectory() as b:
            build(Path(a)); build(Path(b))
            af=sorted(p.relative_to(a) for p in Path(a).rglob("*") if p.is_file()); bf=sorted(p.relative_to(b) for p in Path(b).rglob("*") if p.is_file())
            self.assertEqual(af,bf); self.assertEqual(len([p for p in af if str(p).startswith("attempts/")]),108)
            for p in af: self.assertEqual((Path(a)/p).read_bytes(),(Path(b)/p).read_bytes())


if __name__=="__main__": unittest.main()
