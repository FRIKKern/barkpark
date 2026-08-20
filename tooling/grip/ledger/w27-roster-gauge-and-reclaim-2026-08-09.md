# w27 — the seal roster's 3 invisible rows, and the 26-row reclaim partition (2026-08-09)

Re-derivation recipes. Every number below is reproducible from these commands alone.

## A. The 3-row gauge gap (177 vs 174) — and BOTH numbers are wrong

```sh
bp task get task-fb4fb869490b4213 -o json > /tmp/v12a.json
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  -H "Authorization: Bearer $TOK" \
  --data-urlencode 'filter[parent_id]=task-fb4fb869490b4213' \
  --data-urlencode 'limit=500' > /tmp/v12b.json
python3 - <<'EOF'
import json
a=json.load(open('/tmp/v12a.json'))
A={c['doc_id'] for c in a['children']}
B={d['_id'] for d in json.load(open('/tmp/v12b.json'))['result']['documents']}
print('child_count',a['child_count'],'roster',len(A),'query',len(B))
print('DROPPED', sorted(A-B))
print('distinct', len({x.replace('drafts.','') for x in A}))
EOF
```

Output 2026-08-09T~08:05Z: `child_count 177 roster 177 query 174`, DROPPED =
`drafts.dr-w24-s3-custom-host-cannot-steal-a-url`,
`drafts.dr-w24-s5-the-rulings-become-readable`,
`drafts.dr-w26-hg-gyldendal-operator-packet-corrected`; distinct 175.

Two of the three are DRAFT TWINS of rows already in the query (`dr-w24-s3`,
`dr-w24-s5` both appear published too) — so 177 DOUBLE-COUNTS them. One,
`drafts.dr-w26-hg-gyldendal-operator-packet-corrected` (open, 0/5, the corrected
cross-tenant-credential HUMAN GATE), exists ONLY as a draft and is therefore
invisible to the seal instrument.

The twins also DIVERGE: published `dr-w24-s5` reads 8/9, its draft reads 7/9.

## B. Which read the seal actually uses

```sh
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | sed -n '426,436p'
```
`ROSTER_PAGE_LIMIT = 500`; `fetchRoster` is `filter[parent_id]` + `limit` →
the 174 read. Not truncation (174 « 500): the production dataset simply
excludes `drafts.*`. Same mechanism already ruled in the SIBLING charter:
`git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'drafts.\* twins'`
(D249). Unrecorded in this epic's charter.

## C. The 26 open rows named in merged origin/main commits

```sh
git log origin/main --format='%s%n%b' -n 4000 > /tmp/v12log.txt
python3 - <<'EOF'
import json
a=json.load(open('/tmp/v12a.json'))['children']; log=open('/tmp/v12log.txt').read()
seen=set()
for c in a:
    d=c['doc_id'].replace('drafts.','')
    if c['lifecycle_status']=='open' and d not in seen and d in log:
        seen.add(d); print(d, c['criteria_progress'])
EOF
# then, per row:  bp task get <id> -o json | python3 -c "import json,sys;\
#   [print('-',x['criterion'][:200]) for x in json.load(sys.stdin)['doc']['content']['acceptance_criteria'] if not x['met']]"
```
26 rows. NOTE: criteria live at `.doc.content.acceptance_criteria`; reading
`.doc.acceptance_criteria` returns nothing on every row (the comforting-zero trap).

Partition (11 + 2 + 5 + 8 = 26):

- **PURE MECHANICAL (11)** — sole unmet is a bare merge criterion, merge is on main:
  `dr-w18-s1`, `dr-w19-s3`, `dr-w19-s4`, `dr-w19-s5`, `dr-w20-s1`, `dr-w20-s4`,
  `dr-w22-s4`, `dr-w23-s5`, `dr-w25-s1`, `dr-w25-s4`, `dr-w25-s5`.
- **MECHANICAL + ONE ACT (2)** — `dr-w22-s1` (also: close #10019 as superseded),
  `dr-w22-s2` (also: quote the interpolated `Test (Elixir 1.18.1 / OTP 27.0)` check run).
- **COMPOUND MERGE — a post-merge LIVE re-read nobody has run (5)**:
  `dr-w21-s2` (live `SELECT … FROM barkparks` after one sweep), `dr-w21-s6` (2 unmet:
  BEFORE reading + post-merge `bp cloud deployments -o table`), `dr-w22-s3`
  (telemetry re-read), `dr-w24-s2` (post-merge `bp cloud status` — blocked on the
  operator's stale `bp`), `dr-w26-s6` — whose criterion is UNSATISFIABLE AS WRITTEN:
  ```sh
  git grep -c publish_clock origin/main            # 8 files, so "returns nothing" is FALSE
  git grep -l publish_clock origin/main -- cloud/lib internal api/lib cloud/priv  # rc 1 = no code hits
  ```
  The deletion is complete in CODE; the residual hits are the charter, the census
  test that must NAME what it forbids, and ledgers. A guard that cannot survive
  its own success, living inside an acceptance criterion.
- **GENUINE OUTSTANDING PROOF (8)**: `dr-terminal-record-prune-tie-order`
  (test IS on main, `api/test/barkpark/sites/deploy_runner_test.exs:1996`;
  direction-inversion mutation reds it, the literal collapse mutation cannot red
  on APFS — needs a Linux CI run, not new code), `dr-w13-s6`, `dr-w18-s3`,
  `dr-w19-s7`, `dr-w20-refusal-backoff-depth-derived` (3 unmet), `dr-w20-s2`,
  `dr-w20-s3`, `dr-w24-followup-diverged-is-not-ranked` (0/2 — needs a charter
  decision first; the only row here that is real unbuilt work).

Four of the eight are "the PR BODY states X" on an ALREADY-MERGED PR — still
editable on GitHub, so they are prose acts, not build acts.

## D. D456 is not a phantom — it is stranded

```sh
grep -n "^### D456" .claude/workflows/bp-deploy-reliability-charter.md   # 8170, local working copy
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -c "D456"   # 0
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n "^### D4" | tail -1  # D446
```
D447+ live only in the unmerged wave-26 charter (PR #11027, still OPEN). Citing
D456 to a builder who reads origin/main manufactures a not_found.
