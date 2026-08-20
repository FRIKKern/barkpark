# Legendary Experiment Round 6 — immutable E19–E21 plan

Round 6 is a recovery wave for the real-reader capability blocks recorded by
E17 and preserved by E18. E16's lossless semantic-tree candidate remains the
only candidate under test; this plan does not select it, deploy it to
production, or authorize a pilot.

The canonical machine-readable contract is `assignments.json`. It contains
exactly three sequential assignments:

1. **E19** — deploy the candidate in an isolated environment and collect
   candidate-provenance captures from authenticated Studio, the public reader,
   and CLI/API.
2. **E20** — use E19's same immutable deployment to collect real TUI evidence
   and delivered real-client email evidence, including narrow-width behavior.
3. **E21** — seal fixture identities before scoring, reconcile all 180 real
   reader cells, replay evidence twice, prove adversarial and
   rollback/quarantine coverage, and fail closed on winner/pilot authorization.

## Hard invariants

- The E03 fixture manifest, thresholds, and failure taxonomy are never weakened.
- The candidate is isolated from production; production mutation is forbidden.
- Source-only renders, URL reflection, synthetic screenshots, API responses used
  as reader substitutes, email endpoint HTML, and proxy renders never count as
  real-reader captures.
- Every accepted capture must bind the E16 candidate id, candidate digest,
  deployment id, fixture id, surface, command/session metadata, and artifact
  SHA-256.
- E19, E20, and E21 execute in order. A failed or blocked predecessor prevents
  its successor from starting.
- Only E21 may emit a winner or pilot decision, and it must emit both as false
  unless every frozen hard gate passes.

## Validation

Validate the planning artifact without executing experiments:

```bash
python3 - <<'PY'
import hashlib, json, pathlib
p = pathlib.Path('.omx/state/legendary-experiments/round-06-plan/assignments.json')
d = json.loads(p.read_text())
assert d['assignment_ids'] == ['E19', 'E20', 'E21']
assert [a['id'] for a in d['assignments']] == d['assignment_ids']
assert len(d['assignments']) == 3
assert d['assignments'][0]['depends_on'] == []
assert d['assignments'][1]['depends_on'] == ['E19']
assert d['assignments'][2]['depends_on'] == ['E19', 'E20']
assert all(a['immutable'] and a['commands'] and a['acceptance_thresholds'] for a in d['assignments'])
print('ROUND 6 PLAN PASS', hashlib.sha256(p.read_bytes()).hexdigest())
PY
```

After dispatch, do not edit this directory. Each experiment writes only to its
own `.omx/state/legendary-experiments/E19`, `E20`, or `E21` directory.
