<!-- doc-tier: cold | canonical-for: wbqs-c1-survey-satisfiability-rederivation | budget: 600tok -->

# WBQS epic — criterion C1 "surveys filed as published bp tasks" satisfiability

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier re-derivation recipe (wild-bulk-quality-sweep-2026-07-16-epic, reconcile wave 2026-08-18).

## Claim

Criterion 0 (C1) — "All three domain leads deliver coverage-accounted survey
reports filed **as published bp tasks** under this epic" — is EMPIRICALLY
UNSATISFIABLE as worded. Zero of the 48 children are survey-shaped; the surveys
live inside the cycle paper, not as child tasks, and no separate survey paper is
filed under this epic/wave.

## Re-derive: the 48 children + survey grep

```bash
python3 - <<'EOF'
import json,urllib.request
S="https://guerrilla.barkpark.cloud"; T="<bp_admin token from ~/.config/barkpark/config>"
epic="wild-bulk-quality-sweep-2026-07-16-epic"
kids=[]; off=0
while True:
    req=urllib.request.Request(f"{S}/v1/data/query/production/task?limit=100&offset={off}",
                               headers={"Authorization":f"Bearer {T}"})
    docs=json.load(urllib.request.urlopen(req))['result']['documents']
    if not docs: break
    kids+=[r for r in docs if r.get('parent_id')==epic]
    off+=100
    if len(docs)<100: break
from collections import Counter
print(len(kids), dict(Counter(r.get('lifecycle_status') for r in kids)))
print("survey-in-any-field:", [r['_publishedId'] for r in kids if 'survey' in json.dumps(r).lower()])
EOF
```

Expected: `48 {'done': 44, 'open': 3, 'cancelled': 1}` and `survey-in-any-field: []`.

## Re-derive: no separate survey paper under this wave

```bash
bp search query "wild-bulk-quality-sweep-2026-07-16 survey"
# Only two docs carry the wild-bulk-quality-sweep-2026-07-16 name:
#   the epic task, and this reconcile-wave paper (2026-08-18).
# The task-quality-survey-wave-* papers are a DIFFERENT epic (task-quality, 2026-07-18).
```

## Where the surveys actually live (C4/C5 met evidence)

```bash
bp paper view wild-bulk-quality-sweep-2026-07-16 | head -6
# Editorial status references "frozen Survey PPCC2-S060"; paper body describes
# "30-60 surveyors" and closes with dual debriefs: workflow "Grade: B+" then
# "DEBRIEF — MERGED AND SEALED (LEAD CLOSE, 2026-07-16 EVENING)".
```

## Ruling for Decide

Do NOT fabricate C1. Reword to "captured in the cycle paper
wild-bulk-quality-sweep-2026-07-16" (met), OR leave it honestly unmet. The
wild-bulk-cycle workflow never files surveys as child tasks — they are folded
into the single cycle paper. C1-as-worded cannot be truthfully stamped met.
