<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# cch-w77 V7 — roster split + five-core-lie spot-check (re-derivation recipe)

Verifier lane [V7-roster-split-and-core-lies]. All commands run from repo root, epic JSON cached first.

## 0. Cache the epic roster (denominator source)

    bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
    python3 -c "import json,collections;d=json.load(open('/tmp/epic.json'));print(collections.Counter(c['lifecycle_status'] for c in d['children']))"
    # -> {'done':429,'open':430,'cancelled':77,'in_progress':1,'considering':1}  total 938

## 1. Survivor is in_progress 3/4, NOT the wish's 'OPEN 0/4'

    python3 -c "import json;d=json.load(open('/tmp/epic.json'));print([(c['doc_id'],c['lifecycle_status'],c['criteria_progress']) for c in d['children'] if c['lifecycle_status']=='in_progress'])"
    # -> ('cch-w74-password-change-401-conflation','in_progress',{'met':3,'total':4})

## 2. Denominator ranges (method: lexical predicate over open titles)

Dump open titles: filter children lifecycle_status=='open' -> 430 rows.
Strict claim/reality predicate (honest|lie|lying|accus|census|seal|redact|scrub|secret|172.18|verbatim|narrat|over-stamp|unread|reader owed|divergence|false|asserts|stops (asserting|accusing|telling|promising)|curated copy|identity echo) vs GUI/layout predicate (px|320..900|phone|tablet|overflow|nowrap|breakpoint|viewport|scroll|ellipsis|truncat|pill|modal|palette|spill|clip|footer|width|centring|gzip|reflow|min-content|word-break|fit-content):

- STRICT honesty-only: 76 ; GUI-only: 34 ; both: 4 ; neither: 316
- Broad honesty token list (adds label|told|refus|no surface|says nothing): honesty-only 119, neither 249.

Split is LEXICALLY INCONCLUSIVE at the honesty/other boundary (76->131 depending on token set) because this epic's own cch-* follow-ups drifted into UI-polish vocabulary. But top-line shape is robust: console-honesty residue ~76-131 (ALL follow-ups/tripwires, no core lie); inherited GUI-remake FEATURE/OPS/infra backlog ~300-350 (the 316 'neither' bucket + 34 GUI-only). Hard-signal floor for inherited: 3 explicit FEATURE:, 3 OPS/HUMAN GATE, 12 gr-* prefix, 14 CLI/SPA-parity.

## 3. Five chartered core lies — NONE in open 430; all resolved in done/in_progress

Charter opening (charter md lines 12-14,23) names them. grep open titles: no exact core-lie row (near-matches are follow-ups/other endpoints). Fix rows:

    for s in cch-w1-peer-ip-pin gr-blk-console-refetch-storm gr-blk-sse-token-in-query cch-w74-password-change-401-conflation; do bp task get $s -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['lifecycle_status'],d['criteria_progress'])"; done

- 172.18.0.1 session label -> cch-w1-peer-ip-pin DONE 7/7 (mutation-proven: pre-fix left {172,18,0,1})
- single-user rate limiter -> SAME peer-ip-pin (charter D5: peer IP IS the rate-limit bucket; pin stops all-users-as-one)
- token-in-URL log -> gr-blk-sse-token-in-query DONE 3/3 (+ cch-bl-oauth-token-header-redesign done 2/4)
- 40 requests shown as 5 -> gr-blk-console-refetch-storm DONE, close_override on SHA 481d6f231 (#5308) ancestor of origin/main; landed 40->12 [8,1,1,1,1]; criteria left 0/3 deliberately because literal '5' is unachievable by design (honest evidence-close, not fake-done)
- password-vs-session (401) -> cch-w74 in_progress 3/4 (survivor; merge-gated criterion held for lead)
