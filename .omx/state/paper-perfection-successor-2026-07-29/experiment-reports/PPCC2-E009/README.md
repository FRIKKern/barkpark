# PPCC2-E009 Round 3 attack

`attack_legacy.py` personally attacks all three Round 2 candidates across the
exact nine immutable fixtures. It runs 648 candidate/case checks and 189
selected five-surface projections without mutating production or repository
source.

Canonical terminal result: `report.json`.

Reproduce from the repository worktree:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  .omx/state/paper-perfection-successor-2026-07-29/experiment-reports/PPCC2-E009/attack_legacy.py
```

Large generated renders, binaries, and per-command logs remain assignment-local
and ignored. Their hashes, output excerpts, case records, and surface results
are preserved in `attack-evidence.json`, `attack-trace.ndjson`, and
`report.json`.
