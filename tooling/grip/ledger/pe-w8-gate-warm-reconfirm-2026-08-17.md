# pe-w8 gate-warm-reconfirm re-derivation (2026-08-17)

Warm M4/M5 reconfirm of the paper-excellence render gate on the ignition host,
against the live guide `/papers/paper-authoring-excellence`. Proves the grading
instrument is green on THIS host inside the ignition window (D50 grade-side-void
guard: a break discovered at grade time voids the grade).

## Frozen inputs pinned at run time
- RUBRIC.md blob sha (origin/main): `1280afc52f55d8705a6cf35d30cb70474339cb2c`
- live guide `_rev`: `cf91fcffedc49235024f7b6352fe53b1` (updatedAt 2026-08-17T17:16:22Z)
- bp binary: commit `a653550420`, build 2026-08-17T08:42:54Z
- repo HEAD: `a6535504204df39850cb1d08316b5ffb25eb983b`

## Re-derive (verbatim; SCRATCH = session scratchpad, NOT the rig dir)
```
FIX=$SCRATCH/live-fixtures ; mkdir -p "$FIX"
bp doc get paper paper-authoring-excellence -o json | FIXTURE_DIR="$FIX" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
if not d.get("blocks"): sys.exit("no blocks")
out = {"_id": d["_id"], "title": d["title"], "style": d.get("style"),
       "source_rev": d["_rev"], "blocks": d["blocks"]}
open(os.path.join(os.environ["FIXTURE_DIR"], d["_id"]+".json"),"w").write(
    json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True)+"\n")'
SHOT_WIDTHS="1920,1280,768" bash tooling/paper-excellence/rig/gate.sh \
    "$FIX/paper-authoring-excellence.json" "$SCRATCH/rig-out" ; echo exit=$?
```

## Verdict this run
- exit code: `0` (PASS)
- fixture: 30 blocks, style `article`, source_rev cf91fcff
- prose column: 660px (width-independent) → prose CPL **71.7** at all three widths — inside band [55,75]
- evidence band: 1240 / 1040 / 688 px at 1920 / 1280 / 768 (3 breakout components, max-width honest, ≠ none)
- doc overflow: **0px** at every gated width (≤4px floor)
- 6 full-page shots (2x), 174 content assertions, 3 off-host requests blocked (hermetic)

## Caveats
- CPL is HOST-SCOPED per RUBRIC line ~116; 71.7 is measured on THIS host and sits
  inside the band with margin — geometry verdict holds regardless of host load
  (column px, band px, overflow px are width/CSS-derived, not load-sensitive).
- 360px arm intentionally NOT run (advisory; the exemplar itself fails it by 31px).
