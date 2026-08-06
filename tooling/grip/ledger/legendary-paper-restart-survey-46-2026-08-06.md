<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-46 | budget: 1400tok -->
# Restart Survey 46 — PDS45 CLI/API provenance/current pin

Assignment `restart-survey-46` re-attested `pds-wave-45-2026-08-03::cli_api` at revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **current document, canonical source, query, and newest immutable history snapshot carry the same exact 227-block payload; no drift found**.

Three machine Paper reads were byte-identical: 392,184 bytes, SHA-256 `5894db69f3d9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7`, 227/227 unique IDs, `.blocks == .body.blocks`. Three scoped source reads were identical: 91,515 bytes, SHA `e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8`, source kind `blocks`, exact document block array.

Named block serializations: compact JSON without LF hashes to `f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da`; compact JSON plus LF hashes to `5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673`.

History returns ten revisions. Newest immutable revision `4afe0099-26af-40eb-8943-f6935c16c29d` (publish at `2026-08-03T17:17:44.688992Z`) contains 227 blocks byte-equal to current canonical blocks. History progresses coherently `86 → 123 → 182 → 227`, though history UUID and document `_rev` remain distinct identities.

Query returned exactly one matching row with the same revision/blocks; `bp doc get` matched machine Paper JSON. Direct draft ID returned 404; bare published/raw/drafts perspectives converged to published content. Independent raw header capture was unavailable because curl is absent. Human rendering, semantic loss, and adversarial controls belong to the adjacent lenses. No tests or mutations are claimed here.

## Cycle payload

```json
{"assignment_id":"restart-survey-46","unit":"pds-wave-45-2026-08-03::cli_api","verdict":"found","confidence":"high","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","document":{"samples":3,"bytes":392184,"sha256":"5894db69f3d9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7","blocks":227},"source":{"samples":3,"bytes":91515,"sha256":"e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8","kind":"blocks"},"canonical_blocks":{"compact_no_lf":"f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da","compact_lf":"5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673"},"history":{"count":10,"newest_id":"4afe0099-26af-40eb-8943-f6935c16c29d","current_equal":true},"drift":"none_found","http_headers":"partial","mutations":0,"tests_run":0}
```
