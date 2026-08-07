# cch wave 39 — VERIFY (ledger truth): re-derivation recipes, 2026-08-07T00:46Z

Every integer below has the command that re-derives it. Nothing here is inherited.
Read head at time of writing: `origin/main` = `f4194c51f3294b0880cd11ce83a8f4894c02c99f`.

## 1. The live denominator: 465 children, 165 live

```
bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys;from collections import Counter;d=json.load(sys.stdin);print(d['child_count'],Counter(c['lifecycle_status'] for c in d['children']))"
```

Output 2026-08-07T00:44Z:
`465 Counter({'done': 253, 'open': 165, 'cancelled': 46, 'considering': 1})`

LIVE = open(165) + considering(1) = 166 by the seal predicate's own definition (charter D249);
165 if `open || in_progress` only. There are ZERO `in_progress` rows.

## 2. The seven live `drafts.*` shadow rows, and the 5/2 split

```
bp task get cloud-console-hardening-epic -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); ch=d['children']
pub={c['doc_id']:c for c in ch if not c['doc_id'].startswith('drafts.')}
for c in sorted(ch,key=lambda x:x['doc_id']):
    if not c['doc_id'].startswith('drafts.'): continue
    tw=pub.get(c['doc_id'][7:])
    print(c['lifecycle_status'], c.get('criteria_progress'), c['doc_id'], '|| TWIN:', (tw['lifecycle_status']+' '+str(tw.get('criteria_progress'))) if tw else 'NONE')"
```

12 `drafts.*` rows exist; 5 are cancelled, 7 are live. The 7 split two ways:

FIVE PHANTOMS — published twin already `done` at full or near-full criteria. Dispose with
`bp doc discard-draft` (charter D250: publish-then-cancel is REFUSED by `criteria_regression`),
and per D190 a discard buys NO Law-0 row-shrink credit:

| draft row | its own met/total | published twin |
|---|---|---|
| `drafts.cch-w31-s4-followup-retire-status0-branches` | 9/10 | done 10/10 |
| `drafts.cch-w32-r2-notifications-withhold-branches` | 8/9 | done 9/9 |
| `drafts.cch-w34-s3-disclosure-survives-delivery` | 3/9 | done 8/9 |
| `drafts.cch-w35-s4-forbidden-evidence-beats-the-global-slug` | 11/14 | done 14/14 |
| `drafts.cch-w36-s3-me-cache-has-an-unknown-state` | 7/12 | done 12/12 |

TWO GENUINE ORPHANS — no published twin exists at all, so real content is invisible:

| draft row | met/total | note |
|---|---|---|
| `drafts.cch-w37-s1-invalid-precedence-details-win` | 9/10 | already rowed as `cch-w38-bl-w37-s1-successor-is-an-unpublished-draft` |
| `drafts.cch-w37-bl-roster-collapse-three-paid-rows` | 0/4 | UNROWED elsewhere; a ledger-hygiene action stranded as a draft |

## 3. Drafts are invisible to search — the mechanism, not the anecdote

```
bp search query "billing owner" -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['facets']['status'])"
```
→ `[{'count': 1220, 'label': 'published'}]` — the index carries a single status facet and it is
`published`. A `status=draft` row cannot be returned by any query.

## 4. `bp search` and task slugs

```
bp search query "cch-w38-bl-adopt-canonical-authority-predicate" -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['count']);[print(' ',x['type'],x['id']) for x in d['documents']]"
```
→ `3` : `paper cch-wave-38-2026-08-07`, `paper cch-wave-39-2026-08-07`,
`task cch-w38-bl-unknown-authority-has-no-recovery-seam`.
The task WITH THAT EXACT SLUG is not among them — slugs are not an indexed field; the hits are
papers that mention the slug in prose. Searching a slug is not a test of existence; `bp task get` is.

CORRECTION TO A CIRCULATING CLAIM: `bp search "<terms>"` without the `query` sub-verb does NOT
exit 2. It prints `note: search has one verb — running barkpark search query` and runs the search.
`bp search "billing owner" >/dev/null; echo $?` → `0`.

## 5. The strategy/digest line numbers, re-derived on f4194c51

```
git show origin/main:cloud/priv/static/app.js > /tmp/main_app.js
grep -n 'meCache && (meCache.role === "owner" || meCache.role === "admin")' /tmp/main_app.js
grep -n 'billingIsOwner\|function meState\|Only the team owner can manage billing' /tmp/main_app.js
```

| fact | line on f4194c51 | strategy said | digest said |
|---|---|---|---|
| four verbatim two-valued role reads | 2353, 3492, 3920, 6020 | 2352/3491/3919/6019 | 2353/3492/3920/6020 ✓ |
| `billingIsOwner()` definition | 13319 | 13318 | 13327 ✗ |
| `if (!billingIsOwner())` branch | 13378 | — | 13386 ✗ |
| `'Only the team owner can manage billing.'` in the Manage section | 13443 | — | 13451 ✗ |
| `function meState()` | 13851 | 13850 | 13851 ✓ |

The digest's billing triple is off by exactly 8 on the very head it names. Re-derive at build time.

## 6. Merge horizon at 00:45Z

```
for p in 9917 9918 9919 9920 9921 9922 9955 9956; do gh pr view $p --json number,state,mergedAt,mergeStateStatus -q '"#\(.number) \(.state) merged=\(.mergedAt) \(.mergeStateStatus)"'; done
```
→ `#9917 OPEN BLOCKED` · `#9918 OPEN BLOCKED` · `#9919 MERGED 2026-08-07T00:33:39Z` ·
`#9920 OPEN BLOCKED` · `#9921 MERGED 2026-08-07T00:15:00Z` · `#9922 OPEN CLEAN` ·
`#9955 OPEN BLOCKED` · `#9956 OPEN DIRTY`.

`#9922` is the only unmerged PR in the band that is mergeable RIGHT NOW.

## 7. Free Law-0 repayment already payable (merge gates discharged)

```
for t in cch-w37-s3-scope-stops-naming-a-team-it-did-not-consult cch-w37-s5-the-sweep-stops-passing-on-what-it-did-not-see cch-w38-s3-spec-gate-packet-and-roster-disposition; do bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print([ (i+1,x['criterion'][:60]) for i,x in enumerate(d['content']['acceptance_criteria']) if not x['met']])"; done
```
- `cch-w37-s3` 8/9 — sole unmet is `MERGE-GATED … merged to main`; #9919 MERGED. CLOSABLE.
- `cch-w37-s5` 9/10 — sole unmet is `MERGE-GATED … merged to main`; #9921 MERGED. CLOSABLE.
- `cch-w38-s3` 11/11 — carries NO merge gate by design ("NO PULL REQUEST"). CLOSABLE.
  Its ledger artifact IS on main: `git show origin/main:tooling/grip/ledger/cch-w38-s3-spec-gate-packet-rederivation-2026-08-07.md` succeeds.
  BUT its claim is LAPSED: `claim.worker` is `null`, `epoch` 8, `expired_at` 2026-08-07T00:35:01Z.
  Close needs a CURRENT claim → `bp task claim … ` first (charter D250: claim, not release).

## 8. `cch-w37-bl-register-spec-gate-human-gate` criterion 7 — stamped by this verifier

Satisfied in fact and unstamped. Both superseded rows read `cancelled` (updated 2026-08-06T23:33Z,
by `cch-w38-s3` criterion 5):

```
for t in cch-w35-bl-register-spec-gate-as-fifth-context cch-w36-bl-register-spec-gate-after-census-green; do bp task get $t -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['lifecycle_status'])"; done
```
→ `cancelled` / `cancelled`.

Stamped via claim → `bp task stamp … --criterion 6 --met` → `release`. Read back: `c7 met= True`,
row back at `lifecycle=open`, claim released. Row now 1/7.
Criterion 1 (the non-vacuous sweep) became SATISFIABLE at 00:15Z when #9921 merged — the packet's
stated refusal condition is discharged.

## 9. The criteria-less rows are THREE, not two — `cch-w31-bl-two-rows-invisible` is stale

That row names `cch-w24-bl-word-break-alias-has-no-ruling` and
`cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width`; BOTH now report 0/5. The rows with
`criteria_progress: null` today are a different, larger set:

```
bp task get cloud-console-hardening-epic -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['children']:
    if c['lifecycle_status'] in ('open','in_progress') and c.get('criteria_progress') is None: print(c['doc_id'])"
```
→ `cch-bl-protection-claim-paraphrase-escape`, `cch-w37-bl-require-primary-team-fn-names-still-lie`,
`task-ed706f4e1c616f89`.
