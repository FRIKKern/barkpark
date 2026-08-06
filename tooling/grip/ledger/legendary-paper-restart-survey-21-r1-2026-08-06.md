<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-21-r1 | budget: 1400tok -->
# Restart Survey 21-r1 — CCH29 email negative capability and evidence strength

Corrected assignment `restart-survey-21-r1` replaces the pre-work snapshot typo in `restart-survey-21` and re-attests `cloud-console-hardening-wave-29-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **HTTP preview repeatable; semantic, error-taxonomy, cache-provenance, geometry, MIME, delivery, and client evidence remain failed or unproven**.

## Positive controls

Five sequential preview GETs for Paper revision `18768b0a14c2eead927181c4a0e37c18` were byte-identical: HTTP 200, 121,072 bytes, valid UTF-8, zero replacements, SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`. Gzip decoded to the same bytes.

This is snapshot repeatability, not revision identity. Cache policy requires revalidation, but the response has no ETag, Last-Modified, or revision carrier. Synthetic conditional requests returned the full 200 body.

## Ignored controls and geometry

Every tested query was ignored byte-for-byte: widths 320, 390, negative, huge, and nonnumeric; duplicate width; container/viewport; theme; drafts/raw perspective; unknown keys; Unicode; and NUL query value. There is no HTTP width contract. Query equality proves controls are ignored, not that narrow layout passes.

Existing 390-pixel browser evidence remains adverse: 648-pixel scroll width, 258 pixels of overflow, and 7/11 tables wider than the viewport. A fresh 320-pixel browser cell was not captured.

## Semantic loss

The live output contains 67 list items; positions 39–49 are blank, losing 11 items and 2,268 authored characters. None of 252 block IDs survives. Source contains 200 code and 113 strong string marks; output has zero code/strong/b elements because only map-shaped marks receive semantic rendering. All 11 tables use `role=presentation`; 35 header and 316 data cells survive, but no scope/header associations exist. The document lacks `lang`, `main`, and `article`.

## Negative taxonomy

Unknown valid and Unicode slugs return a bare nine-byte 404 without Content-Type. Empty slug uses different generic 404 HTML. Invalid UTF-8/NUL path produces generic 400 HTML. Invalid UTF-8 query returns 400 JSON mislabeled `internal_error`. Unsupported Accept returns correct 406 but the same incorrect error code; text/plain supplies no text alternative. OPTIONS and TRACE return document `not_found` rather than method-not-allowed. Malformed `%ZZ` yields a 400 text response under HTTP/1.1 but an HTTP/2 protocol close. A 4,096-character missing slug safely returns 404.

## Delivery boundary

Repository call-site search found the preview route but no Paper MIME/delivery backend. The endpoint proves no multipart construction, transfer encoding, SMTP, inbox receipt, provider rewriting, client layout, dark mode, image behavior, or assistive-reader outcome. Gmail, Outlook, and Apple Mail remain unvisited. No mutations or tests ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-21-r1","unit":"cloud-console-hardening-wave-29-2026-08-03::email","verdict":"found","paper_rev":"18768b0a14c2eead927181c4a0e37c18","wave_revision":"8a94f6db-1be6-4bbf-ba49-7f3aeed0e737","http_preview":{"status":200,"bytes":121072,"sha256":"dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331","repeatable":"5/5","utf8":true,"etag":false,"last_modified":false},"findings":["11 blank list items; 2268 authored chars lost","313 string marks lose semantics","252 block ids absent","11 presentation tables lack header associations","width/query controls ignored","400/406 mislabeled internal_error","OPTIONS/TRACE mislabeled not_found","no revision-bound cache validator","no Paper MIME/delivery backend found"],"delivery_proof":{"http_preview":true,"mime":false,"smtp":false,"gmail":false,"outlook":false,"apple_mail":false}}
```
