<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-19 | budget: 1400tok -->
# Restart Survey 19 — CCH29 email provenance and current pin

Assignment `restart-survey-19` re-attested `cloud-console-hardening-wave-29-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current HTTP preview body and source alignment proven; immutable revision binding and delivered mail unproven**.

## Direct answer

The Paper is pinned at revision `18768b0a14c2eead927181c4a0e37c18`. Three machine document reads, three dataset source reads, and one flat source read were stable. Full-document and source representations agree on all 252 blocks with canonical SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`.

Three flat email bodies and one dataset-route body were identical: 121,072 bytes, SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`. Flat and dataset routes are equivalent, and the body exactly matches the Aug 5 baseline. It contains the Paper title, all 37 authored headings, and 11 tables.

## Provenance boundary

The preview is a transformed projection, not a block serialization: the source has 187 paragraph blocks while HTML has 48 paragraphs; none of 252 block IDs survives into the DOM. The body contains neither slug nor revision, and the response supplies no ETag or Last-Modified. Cache policy is `max-age=0, private, must-revalidate`.

Three bodies were stable, while complete response headers differed because CSP nonces and request IDs are regenerated. Theme is read live, task resolution is part of the general render path, and canonical link origin comes from runtime configuration. This fixture has zero task-like nodes, so task resolution is dormant here, but revision alone does not pin every external input.

Interleaved source and preview stability strongly ties the observed body to the current published Paper during capture. It does not create an immutable revision-to-email mapping.

## Preview is not delivered mail

The route documents the bytes a backend should send, but bounded repository search found no Paper-specific invocation that fetches and delivers this preview. The HTTP response has no From, To, Subject, Message-ID, MIME-Version, transfer encoding, provider receipt, or inbox artifact. HTTP preview is proven; SMTP/provider delivery and Gmail, Outlook, and Apple Mail rendering are not found or unvisited and receive no proxy pass.

No mutations ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-19","unit":"cloud-console-hardening-wave-29-2026-08-03::email","paper":{"rev":"18768b0a14c2eead927181c4a0e37c18","blocks":252,"document_sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15","source_sha256":"d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9","blocks_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21"},"email":{"samples":4,"bytes":121072,"sha256":"dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331","flat_equals_dataset":true,"stable_body":true,"self_pins_revision":false,"etag":false,"last_modified":false,"cache_control":"max-age=0, private, must-revalidate","source_headings":37,"email_headings":37,"source_tables":11,"email_tables":11,"source_block_ids":252,"email_block_ids":0},"dynamic_boundaries":{"task_resolution":"dormant for fixture","workspace_theme":"active","canonical_origin":"active","response_headers":"per-request nonce and request id"},"delivery":{"http_preview":"found","paper_sender":"not_found","delivered_message":"not_found","client_render":"unvisited"},"verdict":"current HTTP preview body and source alignment proven; immutable revision binding and delivered mail unproven"}
```
