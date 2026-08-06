<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-24 | budget: 1400tok -->
# Restart Survey 24 — CCH29 public negative capability and evidence strength

Assignment `restart-survey-24` re-attested `cloud-console-hardening-wave-29-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial, high confidence: current article repeatable after request-token normalization; immutable HTTP identity, semantics, narrow UX, error taxonomy, and real AT remain failed or unproven**.

## Repeatability and provenance

Five raw GETs produced five hashes because CSRF, LiveView session/static tokens, root ID, CSP nonce, and cookie vary. After normalizing only those request-scoped values, all five responses matched at 279,506 bytes, SHA-256 `8176babfef10a191d6bf12811b6bb3fe1ff75ee18d05c60f00053ac65b968a70`. Extracted articles also matched 5/5 at 106,114 bytes, SHA-256 `77543f031ead9883d18473abfeb57320eebbce2ef430827b40bdf09bdf44f0ea`.

No ETag, Last-Modified, Age, cache-hit marker, or visible exact revision exists. Conditional requests return full 200. `data-rev="0"` reads a content field, not `_rev`. Normalized repeatability is strong current evidence, not durable provenance.

Width, viewport, theme, perspective, share, arbitrary/duplicate/extreme, Unicode, and NUL query controls all returned the same normalized document. They are ignored, so query equality is not viewport proof.

## Negative taxonomy and semantic evidence

HTML and wildcard Accept return 200. XHTML, JSON, and text Accept return 406 JSON mislabeled `internal_error`. Malformed UTF-8 query returns 400 with the same label and no request ID. Missing-route shapes inconsistently return generic HTML or structured JSON. OPTIONS and TRACE return 404 `not_found`, not 405. Malformed `%ZZ` returns 400 text under HTTP/1.1 but closes HTTP/2 without an application envelope.

All 252 IDs retain source order, but 11 list items are blank, losing 2,268 characters/406 tokens. All 313 source string marks flatten without code/strong/b semantics. Eleven data tables are presentational with no scope/caption. Four callouts have no role or accessible label.

Prior exact-revision Chromium evidence shows all 11 tables scrolling at 390 pixels and fixed Email/TUI controls obscuring content at sampled scroll positions. Fresh 320-pixel/zoom/AX and real AT work remain targeted Verify scope. DOM semantics prove structural defects, not exact VoiceOver/NVDA behavior. No mutations or tests ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-24","unit":"cloud-console-hardening-wave-29-2026-08-03::public","verdict":"partial","confidence":"high","authority":{"wave":"8a94f6db-1be6-4bbf-ba49-7f3aeed0e737","paper_rev":"18768b0a14c2eead927181c4a0e37c18"},"repeatability":{"raw":"unstable_request_tokens","normalized_html":"5/5 identical","article":"5/5 identical","etag":false,"visible_rev":"0"},"negative_controls":{"accept_taxonomy":"fail","method_taxonomy":"fail","malformed_input_taxonomy":"fail","http2_percent_escape":"targeted proof required"},"dom":{"blank_items":11,"lost_chars":2268,"flattened_marks":313,"presentation_tables":11,"callouts_without_semantics":4},"geometry":{"chromium_390":"obstruction and 11/11 table scroll","viewport_320":"targeted fresh proof required"},"accessibility":{"dom_proxy":"checked","browser_ax":"unvisited","real_at":"unvisited"}}
```
