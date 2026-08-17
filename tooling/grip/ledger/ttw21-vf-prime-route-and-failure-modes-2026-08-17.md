<!-- doc-tier: cold | canonical-for: ttw21-vf-prime-route-and-failure-modes | budget: 800tok -->

# ttw21 verify: prime counts + lifecycle_status failure modes (guerrilla, 2026-08-17)

Re-derivation recipes for the D115 required-vs-best-effort ruling.

## TOK

    TOK=$(python3 -c "import json;print(json.load(open('/Users/pelle/.config/barkpark/config.json'))['token'])")

## Fact 1 — prime counts map + in_progress collapse delta = 0 today

    curl -s -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/v1/tasks/prime?limit=100" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('counts:',d['counts']);print('prime.in_progress len:',len(d['in_progress']))"
    curl -s -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/v1/tasks?lifecycle_status=in_progress&limit=1000" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);docs=d['docs'];print('third-fetch len:',len(docs),'unique doc_id:',len(set(x['doc_id'] for x in docs)))"

Expected: counts.in_progress == prime.in_progress len == third-fetch len == unique doc_id == 15. Collapse delta 0.
Full counts: {blocked:6, cancelled:339, considering:168, done:3325, in_progress:15, open:2972}.

## Fact 2 — failure modes: server 200s on EVERY bad param; bad value → 200-EMPTY, never 400

    for u in '/v1/tasks?lifecycle_status=bogus&limit=5' '/v1/tasks?lifecycle_status=&limit=5' \
             '/v1/tasks?lifecycle_status=IN_PROGRESS&limit=5' '/v1/tasks?lifecycle_status=in_progress%20&limit=5' \
             '/v1/tasks?lifecycle_status=in_progress&limit=abc' '/v1/tasks?limit=1000'; do
      echo "== $u"; curl -s -w '\nHTTP:%{http_code}\n' -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud$u" | head -c 120; echo; done

Expected: bogus/empty/IN_PROGRESS(wrong case)/trailing-space → HTTP 200 {"ok":true,"docs":[]}.
limit=abc → HTTP 200 with docs. limit=1000 (no filter) → HTTP 200, 1000 docs. NO 400 anywhere.

## Ruling input

- REQUIRED third fetch is SAFE from the #11875 false-offline seam: server returns 200 even on a bad param, so the both-required guard never paints offline over a healthy corpus.
- The real residual risk (present under BOTH contracts): a param DRIFT (case, trailing space, rename) returns 200-EMPTY → silent in_progress undercount, indistinguishable from a genuine zero.
- Mitigation the data supports: source the in-flight/denominator number from prime.counts.in_progress (authoritative, already fetched) and use the third fetch purely for doc_id union row-rescue, so a drift degrades to "no extra rows rescued" not "count wrong."
