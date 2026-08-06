<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-27 | budget: 2100tok -->
# Restart Verify 27 — cross-reader semantic canonicalization

Assignment `restart-verify-27` built one deterministic semantic canonicalizer and attempted 20 source/public/email/CLI/Studio captures across four frozen Papers. Verdict: **refuted with a Studio authentication boundary**. The available readers lose the same eleven authored CCH29 list items in both public and email output.

| Measure | Observed |
|---|---:|
| Captures attempted | 20/20 |
| Available Paper captures | 16/20 |
| Studio login-boundary captures | 4/20 |
| Source nonempty carriers | 2,068 |
| Available carrier checks | 8,272 |
| Preserved / missing | 8,250 / 22 |
| Heading order exact | 16/16 |
| Table-body order exact | 16/16 |
| List order exact | 14/16 |
| Source/CLI semantic equality | 8/8 |
| Public/email semantic equality | 6/8 |

The 22 missing carrier checks are exactly eleven paragraph-wrapped list items from CCH29 on each of two readers. Public and email diverge only for that Paper; all other available semantic cells match the canonical source. Frozen revisions and all 815 source blocks matched 4/4.

The canonicalization boundary performs NFC normalization, HTML entity decoding, and Unicode-whitespace collapse. It preserves case, punctuation, authored characters, and heading/list/table order. It explicitly excludes JSON envelope and request/session bytes, HTML presentation markup, credentials, and empty non-text blocks. Raw captures and semantic digests remain separate; every mismatch is localized in the mismatch manifest.

Studio was not substituted. All four attempts ended at `/login` with zero canvas carriers using the documented token/session path, so those cells are recorded as unavailable authentication boundaries and carry raw/redacted hashes but no false Paper semantic digest. Authenticated Studio semantics therefore remain unmeasured. Email is the HTTP preview rather than delivered MIME or real mail clients.

The deterministic aggregate digest reproduced twice as `019394003e9796ea777975b593f93cc207181a67592105ac1a39d72d95108734`. Saved-token occurrences were zero. Only read operations ran; HEAD stayed `903b0ebc012dbdc17820042637412a84c2db8dbe` and tracked diff remained clean.

Evidence root is `/private/tmp/bp-restart-verify27.uPfCan`. Canonicalizer SHA-256 is `a1eb1bfaa72bfbcc7a0fd5ef8ce0958cd21ccad4633a6ea7d971ae730190758d`; semantic report SHA-256 is `042bba2ea73dbe2b990aa1d94f64c81785a001a8a8ed00272915bc7cc0b11a70`; cell matrix SHA-256 is `3815711b29cfec77cdc57fa620b27baf8b06be9d76f95c8e872d3538d418525f`; mismatch manifest SHA-256 is `dbf7aea86c67ad72f0954664e642e65b1a8fd83579102b94e1cab2c9d2d31a51`; exclusion manifest SHA-256 is `059b828b15e0867cf7b5a370de61ee4bb17cec4e594e0e7d80e95f12e17dccaa`; raw-capture manifest SHA-256 is `76964527103e9edac848dff3766fa29a91182b71e8143f61d90120f88b93e08d`.

## Cycle payload

```json
{"assignment_id":"restart-verify-27","assignment_uuid":"5152f840-8dfc-4545-ab65-80a41920c065","verdict":"refuted_with_studio_auth_boundary","captures":{"attempted":20,"available":16,"studio_unavailable":4},"carriers":{"source":2068,"checks":8272,"preserved":8250,"missing":22},"order":{"headings":"16/16","lists":"14/16","table_body":"16/16"},"equality":{"source_cli":"8/8","public_email":"6/8"},"failure":{"paper":"CCH29","public_missing":11,"email_missing":11},"mutations":0,"canonicalizer_sha256":"a1eb1bfaa72bfbcc7a0fd5ef8ce0958cd21ccad4633a6ea7d971ae730190758d"}
```
