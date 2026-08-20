# W21 — ledger duplicate finish: re-derivation recipes

Verifier lane `ledger-duplicate-finish`, wave 21. Every number below is re-derivable by the
command beside it. No bp mutation was made; nothing here was stamped.

## 0. Set the token once

```
TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
```

## 1. The two denominators, and why they differ by 3

```
curl -sf -G -H "Authorization: Bearer $TOK" \
  'https://guerrilla.barkpark.cloud/v1/data/query/production/task' \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
  --data-urlencode 'limit=500' \
| python3 -c "import json,sys,collections;d=json.load(sys.stdin)['result'];print(d['count'],dict(collections.Counter(x['lifecycle_status'] for x in d['documents'])))"
```
→ `258 {'open': 92, 'done': 139, 'cancelled': 26, 'considering': 1}`  → residue **93**

```
bp task get cloud-console-hardening-epic -o json \
| python3 -c "import json,sys,collections;d=json.load(sys.stdin);print(d['child_count'],dict(collections.Counter(c['lifecycle_status'] for c in d['children'])))"
```
→ `261 {'open': 93, 'done': 139, 'cancelled': 28, 'considering': 1}`

The 3-row gap is `drafts.*`, which the production query cannot see:

```
bp task get cloud-console-hardening-epic -o json \
| python3 -c "import json,sys;print([c['doc_id'] for c in json.load(sys.stdin)['children'] if c['doc_id'].startswith('drafts.')])"
```
→ `drafts.cch-bl-floor-is-blind-and-uncalled`,
  `drafts.cch-bl-required-checks-floor-blind-uncalled`,
  `drafts.cch-w19-s1-guard-loses-in-ci`

Charter **D105** and **D190** already rule these are duplicates, never rows, and that the
disposal verb is `bp doc discard-draft` — never close, never cancel.
Quote the production numbers (258 / 92+1 = 93). Never `bp task get`'s 261/94.

## 2. The verb, settled by test and by code

```
bp doc discard-draft --help
bp doc discard-draft task cch-w19-s1-guard-loses-in-ci --dry-run
```
→ takes the BARE published id and emits
`{"mutations":[{"discardDraft":{"id":"cch-w19-s1-guard-loses-in-ci","type":"task"}}]}`
to `POST /v1/data/mutate/production`.

```
git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '605,640p'
```
`do_discard_draft/4` resolves `DraftId.draft_id(published_doc_id)`, rev-fenced-deletes that row,
and returns `{:error, :not_found}` when absent. It does **not** require a published twin and
does **not** publish. So a `drafts.*` row can always be discarded; publish-then-cancel is never
required and actively harmful — it would MINT a published cancelled row where none exists.

Publishing `drafts.cch-w19-s1-guard-loses-in-ci` is additionally **structurally refused**:

```
git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '336,345p'   # criteria_regression gate
for I in drafts.cch-w19-s1-guard-loses-in-ci cch-w19-s1-guard-loses-in-ci; do
  curl -s -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/v1/data/doc/production/task/$I" \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['result'];print(d['_id'],d['lifecycle_status'],[i for i,c in enumerate(d['acceptance_criteria']) if c.get('met')])"
done
```
→ draft met `[0,1,3,4]`, published met `[0,1,3,4,5,6,7]`. Draft ⊂ published: **zero unique
content to migrate**, and publishing would clear three met flags → refused at lifecycle.ex:339.

The two cancelled drafts are fully subsumed by the published survivor
`cch-bl-floor-blind-to-readme-and-uncalled` (criteria 0/1/3/4 Jaccard ≈ 1.00; the survivor's
criterion 2 is a strict superset carrying an appended `WAVE-12 RECONCILIATION` note). Neither has
a published twin — they are absent from the production roster — so discard removes them outright.

## 3. The collapse graph — the cheapest downward lever, and it is not duplicates

Every live row named inside an **unmet** MERGE-GATED criterion of a slice whose PR already merged:

```
python3 - <<'EOF'
import json,os,re,urllib.request,collections
tok=json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token']
def q(p):
    u='https://guerrilla.barkpark.cloud/v1/data/query/production/task?filter%5Bparent_id%5D='+p+'&limit=500'
    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers={'Authorization':'Bearer '+tok})))['result']['documents']
docs=q('cloud-console-hardening-epic')+q('cch-instruments-epic')
LIVE={d['_id'] for d in docs if d['lifecycle_status'] in ('open','considering','in_progress')}
ID=re.compile(r'(?:cch|cchi|gr)[a-z0-9-]{8,}|task-[0-9a-f]{16}')
tot=set()
for d in docs:
    if d['_id'] not in LIVE: continue
    for j,c in enumerate(d.get('acceptance_criteria') or []):
        t=c.get('criterion','')
        if c.get('met') or not re.search(r'MERGE-GATED|lead closes|LEAD closes|lead then',t): continue
        refs={r for r in ID.findall(t) if r in LIVE and r!=d['_id']}
        if refs: print(d['_id'],'c%d'%j,'->',sorted(refs)); tot|=refs
print('DISTINCT:',len(tot))
EOF
```
→ **14 distinct live rows** already scheduled for close/cancel by an unmet stamp.
Add the 8 slice rows holding those stamps (`cch-w19-s1/s2/s4`, `cch-w20-s3/s6/s7/s8`, and
`cch-w20-s9` once #8987 lands) and the ceiling of pure-stamp subtraction is **~22 of 93**.

Merge state proving the gates are payable:
```
for N in 8928 8945 8946 8984 8985 8986 8987 8988; do
  gh api repos/FRIKKern/barkpark/pulls/$N -q '.number|tostring+" "+.state+" merged="+(.merged|tostring)+" "+((.merge_commit_sha//"-")[0:9])'
done
```
→ 8945 `87e8726c4`, 8946 `367e19810`, 8984 `405f6ebae`, 8985 `3c6d1540a`, 8986 `c25466dac`,
  8988 `99ea46c1b` all merged; **8987 open** (it is the s9 attention-name-column PR, not s8);
  8928 closed unmerged **by design** (cch-w19-s1 criterion 6 demands exactly that).
`cch-w19-s1`'s ledger artefact is on main:
`git ls-tree -r --name-only origin/main tooling/grip/ledger/ | grep guard-mutation`
→ `tooling/grip/ledger/cch-w19-guard-mutation-proof-2026-08-01.md`

## 4. Five duplicate clusters NOT covered by any existing merge-gate — migrate, then cancel

Order is load-bearing: **migrate first, always**.

| Survivor | Cancel | Migrate into the survivor before cancelling |
|---|---|---|
| `cchi-w18-bl-e11-scan-set-third-blind-spot-baseline` (4) | `cch-w17-bl-e11-scan-set-app-css-and-shoot-sh` (6) | its criteria **1** (app.css:5225 claims :2270 covers `.detail-rail`, which it does not), **2** (E11 failure text needs a CSS-side arm naming a selector, not a JS function), **4** (behavioural inertness). Its 0 and 3 are already inside the survivor's criterion 1. |
| `cchi-w20-bl-modal-oracle-runs-nowhere` (3) | `cch-w13-bl-overflow-guard-and-modal-oracle-ungated` (3) **and** `task-0b23fb7452aa457a` (0 criteria) | from cch-w13-bl: criterion **0** (refusal vs defect exit codes distinguishable, mutation-proven both directions) and **2** (no new required context, `.github/required-checks.json` untouched). Its criterion 1 is already PAID by `cch-w15-bl-overflow-guard-unwired` (done 6/6). `task-0b23fb7452aa457a` carries zero criteria — nothing to migrate. Net −2. |
| `cchi-w18-bl-seal-predicate-header-asserts-absent-wiring` (3) | `cch-w12-bl-seal-predicate-header-comment-stale` (3) | all three — the stale RUNG sentence is a second false claim in the same header, one file, one edit. |
| `gr-blk-cssom-parity-harden` (3) | `gr-backlog-cssom-parity-count-skew` (**1/4 met**) | criteria **1** (Set-vs-multiset ruled or closed in writing), **2** (duplicate-selector census corrected to 6, the six named), **3** (invariant confirmed on a second Chrome / CI runner) — **and the evidence of its one MET criterion**, or the stamp is destroyed. |
| `cch-w12-bl-redact-env-secrets-opt-in-on-3-of-24` (5) | `gr-backlog-console-redaction-allowlist` (3) | criterion **1** (`internal/builder/console.go` twin gets the same treatment). Its 0 and 2 are subsumed. |

Net from this table: **−5 live rows** (−6 counting `task-0b23fb7452aa457a`).

### Checked and REFUTED as duplicates — do not collapse
- `cchi-w20-bl-breakpoint-sweep-fonts-blind` vs `task-d862cf7f8e1108c1` — different files
  (`breakpoint-sweep.mjs` vs `overflow-guard.mjs`). The two halves of D218, not a pair.
- `cch-w16-s7-citation-anchors-e11-widening` criterion **7** ("app.css is EXPLICITLY OUT" of the
  scan set) **contradicts** `cchi-w18-bl-…-baseline` criterion 0 and `cch-w17-bl-…` criterion 0
  ("app.css is IN"). That is an unadjudicated contradiction, not a duplicate. Rule it in writing.
- `cch-w16-bl-trial-chip-truncated-on-every-phone`, `cch-w16-bl-theme-picker-select-clipped-at-320`,
  `task-9fcf92e7a02fa5b8` — real triplets, but already scheduled by `cch-w19-s2` c10 (#8945 merged).

## 5. Six live rows carry ZERO acceptance criteria — unclaimable by construction

```
python3 - <<'EOF'   # same fetch as §3, then:
z=[d for d in docs if d['lifecycle_status'] in ('open','considering') and not (d.get('acceptance_criteria') or [])]
print(len(z)); [print(' ',d['_id']) for d in z]
EOF
```
→ `task-0b23fb7452aa457a`, `cch-bl-cloudflare-identity-echo-no-surface`,
  `cch-w14-bl-sweep-navwall-pin-removal`, `task-5acf9b5ad30f9a74`,
  `task-4a591a26279e7d24`, `task-9b3778f52ca05984`.
Zero live rows sit at FULL criteria — there is **no** stale-open residue this wave.

## 6. Method note — what a title/slug sweep cannot see

Titles and slugs found the four `cch-w19-s*` ↔ `cch-w20-s*` slug twins. They did **not** find any
of §4: those five clusters only surface on shared **rare file:symbol** tokens across bodies. A
pure criterion-text Jaccard sweep (648 non-boilerplate criteria, 74 doc-pairs over 0.45) surfaced
**zero** new clusters — every hit was shared slice boilerplate (`ALL LOCAL GATES rc=0`,
`THE LEG CAN LOSE`, `BASELINE ABSTENTION IS MACHINE-PROVEN`). Criteria text is where this epic's
duplicates were *expected* to hide; measured, they hide in the **files/symbols** field instead.
