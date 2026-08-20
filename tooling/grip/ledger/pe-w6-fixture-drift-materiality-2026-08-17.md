# pe-w6 fixture-drift materiality — _rev drift is metadata-only, blocks byte-identical

Verdict (2026-08-17): the fixtures-vs-live `_rev` drift the digest flagged is **metadata-only**.
For both sampled rig fixtures the committed block array is **byte-identical** to the live
paper's blocks (order included), and title + style match. No `fetch-fixtures` refresh is
needed; the single display-scale re-baseline slot does **not** have to absorb a fixture
refresh. The wish's "fixtures on origin/main match live" is TRUE in the sense that matters
(rendered content), even though `source_rev != live _rev` for every fixture.

| fixture | fixture source_rev | live _rev | blocks | verdict |
|---|---|---|---|---|
| eight-minute-erasure | 9e2998c841e4fb21f5401b9d7de0b62c | cd1c32c74ae5454a80c690ca366b06ff | 46/46 identical | IDENTICAL-BLOCKS |
| portabledoc-showcase | ba2b7e477aaec671ecbd0c7065b72c22 | d2bcb5aa03786e3f5db7f2f6b6af8453 | 106/106 identical | IDENTICAL-BLOCKS |

Note: live `_updatedAt` is 2026-08-17 for both (a same-day republish/metadata touch bumped
`_rev` without changing block content) — which is exactly why `_rev` drifts while blocks do not.

## Re-derive

```bash
cd /Volumes/SATECHI/github/barkpark
for s in eight-minute-erasure portabledoc-showcase; do
  git show origin/main:tooling/paper-excellence/rig/fixtures/$s.json > /tmp/fix.json
  bp doc get paper $s -o json > /tmp/live.json
  python3 - "$s" <<'PY'
import json,sys
s=sys.argv[1]
fx=json.load(open('/tmp/fix.json')); lv=json.load(open('/tmp/live.json'))
c=lambda a:[json.dumps(b,sort_keys=True,ensure_ascii=False) for b in a['blocks']]
print(s, 'IDENTICAL-BLOCKS' if c(fx)==c(lv) else 'DIFFERS',
      '| rev_drift=', fx['source_rev']!=lv['_rev'])
PY
done
```

Expect: `eight-minute-erasure IDENTICAL-BLOCKS | rev_drift= True` and
`portabledoc-showcase IDENTICAL-BLOCKS | rev_drift= True`.
