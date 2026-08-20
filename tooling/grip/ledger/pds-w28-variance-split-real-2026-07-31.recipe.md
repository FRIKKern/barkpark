# pds-w28-variance-split-real — the variance classifier over the REAL PDS reason corpus

Subject: PDS wave 28, slice-2 sizing. Grip's 58.5%/1.65% variance rates were measured
over grip's OWN ledger authors. This row measures them over the live PDS
`disposition_reason` corpus instead. Observed 2026-07-31.

## Corpus derivation

    curl -s -H "Authorization: Bearer $BP_TOKEN" \
      "https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=500&offset=$OFF&order=_createdAt:asc"

Seven pages (limit 1000 x2, then 500 x5 after two HTTP 500 `internal_error`
responses at offset 2000/2500 — retried, second attempt 200). Corpus 4022 rows.
Closure over `parent_id` from `task-2ac1f95237c4a8e5` = 357, escaped 0.
Live (lifecycle_status not in done/cancelled/canceled) = 190. Adjudicated = 172.
Non-empty `disposition_reason` = 172.

## Facts, each with its rerun

| claim | value | rerun |
|---|---|---|
| grip census exports the classifier | FAMILY, classifyFamily, classifyOutcome, pipelineSegments, segmentHead, segmentTokens | `node -e 'import("./tooling/grip/census.mjs").then(m=>console.log(Object.keys(m).filter(k=>/class\|family\|segment/i.test(k))))'` |
| rows carrying >=1 backtick span | 81 / 172 | see extractor below |
| rows carrying >=1 command-SHAPED span | 54 / 172 | see extractor below |
| rows with >=1 screen-ADMITTED command | 35 / 172 | `screenCommand` over the extracted spans |
| family split (63 commands) | MATCHER 26 / QUERY-LISTER 19 / PREDICATE 9 / CONTENT-FETCH 5 / UNKNOWN 4 | `classifyFamily` |
| pipe-masked, rc-swallowing tail | 5 / 16 multi-segment | tail head in {sed,head,tail,wc,awk,...} |
| loose vs head-scoped polarised flag | 10 vs 10, leak 0 | regex over whole string vs tail-segment option tokens |
| derived level over admitted commands | L3 32 / L2 26 / L6 5 | `deriveLevel` |
| row-level best level | L3 24 rows / L2 13 rows | `deriveLevel` folded per row |
| executed outcome (39 admitted) | ANSWERED 11, ABSENT 17, PRESENT 5, EMPTY-SET 2, PATH-GONE 3, RAN-AND-FAILED 1 | `classifyOutcome` |
| naive `rc===0` predicate would pass | 18 / 39 (46.2%) | count rc!==0 over the same run |

## The polarity proof (why a pipe-masked rerun cannot fail)

    git show origin/main:api/lib/barkpark/content/NO_SUCH_FILE.ex | sed -n '1,3p'; echo $?
    # fatal: path ... does not exist in 'origin/main'
    # 0

Five PDS reasons carry exactly that shape.

## A grip screen defect this corpus surfaced

    git grep -ln 'gate_task_publish' origin/main -- api/test
    # -> screenCommand: {ok:false, reason:"write shape: filesystem mutation"}
    # -> actually runs read-only, rc 0, one path

`screen.mjs:1296` is `/\b(mkdir|touch|chmod|chown|chgrp|ln)\s/`. `\b` matches
between `-` and `l` in `-ln`, so every `grep -ln` / `git grep -ln` is refused as
a symlink write. 1 of 63 PDS commands, and `-ln` is a standard idiom.
