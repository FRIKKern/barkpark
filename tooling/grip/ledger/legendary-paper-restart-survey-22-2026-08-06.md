<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-22 | budget: 1400tok -->
# Restart Survey 22 — CCH29 public provenance and current pin

Assignment `restart-survey-22` re-attested `cloud-console-hardening-wave-29-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current authored DOM identity and route parity proven; immutable reader revision self-identification absent**.

## Direct answer

The Paper remains pinned at revision `18768b0a14c2eead927181c4a0e37c18`. Three full-document and three narrow-source reads were stable and their 252-block arrays exactly matched, canonical SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`.

Three flat and three dataset public renders returned 200. Whole-page bytes varied with CSP nonce, request ID, CSRF/LiveView material, and route URL, but each dead-render article subtree was identical: 106,121 bytes, SHA-256 `7e6f2e335735dc168ed6ffacf57ec475561bb977a541ad9935df64ba5be79411`. All 252 nonblank unique block IDs matched source order.

Connected Chromium 1.59.1 confirmed route parity: both articles were 110,264 bytes with SHA-256 `d7ec7ae35e94ed413c439b81b54f41c37cc221c0e513ca7caddf5065d8a81800`; visible text was 65,009 bytes with SHA-256 `d25afda6268115b75f16d1da34a6fa2c0b5877f8e67528f0ba3f3ac9fd38996b`. There were zero console errors or horizontal overflow at 1440 pixels.

## Revision boundary

The slug is visible, but the exact document revision appears zero times. `data-rev="0"` is a LiveView content stream counter, not `_rev`. Page and narrow source use private must-revalidate caching but no ETag/Last-Modified; a conditional request with the exact revision returns 200. The generic document API exposes ETag equal to `_rev` and returns 304 for the same condition.

Thus current source order, public block order, connected DOM text, and flat/dataset parity are reproducible. The public reader cannot independently identify the immutable revision. Per-load references, task/value resolution, backlinks, theme, and adjacent rails may also change outside stored Paper bytes.

Historical revision rendering, mobile behavior, and assistive readers were outside this provenance lens. No mutations ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-22","unit":"cloud-console-hardening-wave-29-2026-08-03::public","paper":{"rev":"18768b0a14c2eead927181c4a0e37c18","blocks":252,"document_sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15","source_sha256":"d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9","blocks_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21"},"dead_render":{"samples":6,"http_200":6,"article_bytes":106121,"article_sha256":"7e6f2e335735dc168ed6ffacf57ec475561bb977a541ad9935df64ba5be79411","block_count":252,"source_order_equal":true,"whole_page_stable":false},"browser":{"routes":2,"article_bytes":110264,"article_sha256":"d7ec7ae35e94ed413c439b81b54f41c37cc221c0e513ca7caddf5065d8a81800","text_sha256":"d25afda6268115b75f16d1da34a6fa2c0b5877f8e67528f0ba3f3ac9fd38996b","console_errors":0,"slug_visible":true,"document_rev_visible":false,"data_rev":"0"},"validators":{"page":false,"source":false,"document_api_etag_equals_rev":true},"verdict":"current authored DOM identity and route parity proven; immutable revision self-identification absent"}
```
