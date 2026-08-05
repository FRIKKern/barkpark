<!-- doc-tier: cold | canonical-for: legendary-paper-survey-43-evidence | budget: 1200tok -->
# Survey 43 — Cloud Console wave 28 / CLI/API structure

Verdict: `found`, with one transport/error-classification risk. Current CLI and canonical APIs preserve the complete Paper and its revision history, but broad reads intermittently return server 500s and the Paper viewer can misclassify them as not-found.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; canonical block SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- All 237 block IDs are present and unique, in exact order: 43 headings, 156 paragraphs, 18 tables, 13 callouts, and seven lists.
- Deployed `bp paper view -o json`, `bp doc get`, and filtered `bp doc query` return identical full documents at canonical JSON SHA-256 `72e246bea0648c256b0667436f38a680cd4454743c6b259a99d0678712e8f92a`, including identical blocks and order.
- `bp doc get --fields title,blocks` retains seven system fields plus exact title/blocks and removes other content fields. Query returns the documented count/documents/limit/offset/perspective/total envelope.
- The canonical public source is deliberately narrow: `id`, `title`, `_rev`, and `source:{kind,blocks}`. Its block array is exact.
- History contains 12 newest-first revisions. The latest published revision and its preceding draft both contain the exact current 237 blocks; earlier paired snapshots contain 188, 155, and 47 blocks, followed by four body-only legacy revisions.
- Focused API-client tests pass. CLI tests pass with `CGO_ENABLED=0`; the host CGO compiler rejects option `-E` under the default environment.
- Several broad document reads transiently returned server HTTP 500. `bp paper view` misleadingly surfaced at least one such event as `not_found` / exit 4. A subsequent 20/20 Paper/get sample passed, so frequency and trigger remain unproven.

Verify should add server-error classification tests, distinguish transport failure from absence, exercise all projections against pinned revisions, and prove history replay across block and body-only eras. No state mutation occurred.
