<!-- doc-tier: human | canonical-for: scaffy-benchmark-payload | budget: 800tok -->
# scaffy/benchmark — the W6 flagship benchmark paper payload

`scaffy-benchmark.json` is the checked-in ingest payload for the paper live at
`/papers/scaffy-benchmark` (D18 reproducibility pattern: the repo carries the
bytes the server serves). Every scoreboard number in it byte-matches
`tooling/scaffy-duels/results/scores.json` — verify with a diff of the first
table block's cells against the `aggregates` map (the W6 completion round ran
exactly that check: 14 rows × 7 fields, exact).

## Re-ingest recipe

Same-slug re-POST is a wholesale upsert (proven in W1/D18 — no dup, rev bumps):

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -sS -X POST https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary @scaffy/benchmark/scaffy-benchmark.json
```

Expect `"ok":true` + the slug. Read back: `bp doc get paper scaffy-benchmark -o json`
(there is no bulldocs GET-single-paper route — D82). Publish wall: the payload
already carries the required `description` + registered distinct-strength
weighted tags (`benchmark` 90 / `scaffy` 70 / `duels` 55 / `measurement` 45 /
`token-efficiency` 30 — all registered by the W6 prereg slice).

## Sources (the paper quotes, never summarizes)

- `tooling/scaffy-duels/results/` — SUMMARY.md, scores.json, per-cell claude-CLI
  envelopes, dirty-arm diffs, boundary_judgment.json, RUNLOG.jsonl.
- `tooling/scaffy-mine/` — the canonical frequency miner (atlas evidence).
- Prereg paper `scaffy-duels-prereg`; wave paper `bp-scaffy-wave6-2026-07-17`;
  charter D63–D73.
