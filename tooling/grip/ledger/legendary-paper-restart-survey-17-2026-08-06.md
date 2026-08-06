<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-17 | budget: 1400tok -->
# Restart Survey 17 — CCH29 CLI/API live regression and frozen gates

Assignment `restart-survey-17` re-attested `cloud-console-hardening-wave-29-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged pinned artifact; no live regression; spacer and source-negotiation failures remain**.

## Direct answer

The live Paper remains at revision `18768b0a14c2eead927181c4a0e37c18`. Three CLI/API replays reproduced the frozen raw SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15` over 431,200 bytes. Its 252 unique blocks retain canonical block SHA-256 `46ed01f7416f064f950cee3b00f1a59da00cd0cef523b2a6e4cf1e7cee4b1a50` and ordered-ID SHA-256 `8943464821b46ac73b10ef923b3d0e782fed23bda4a36d28b58c7de9b3afc3c5`.

The fresh census exactly matches Round 1: 37 headings, 11 tables, 35 legacy header cells, 316 body cells, 313 marks, four callouts, 11 paragraph-wrapped list items containing 406 words, and 139 exact-empty spacers. Canonical accounting, revision pins, machine text/list preservation, source table/mark/callout shape, and the no-alias-conflict control remain passes. The 139 spacers keep spacer migration failed.

## Contract probes

The Paper source route still has inverted negotiation. `Accept: text/html` returned JSON with status 200, 109,924 bytes, exact revision, and SHA-256 `d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9`. Explicit `application/json` and `text/plain` returned stable 406 typed envelopes with `internal_error` and request IDs. Contract provenance therefore remains failed. A missing-Paper CLI control returned exit 4 with `not_found` and a request ID, matching the frozen behavior class.

Browser geometry, terminal geometry, navigation, Studio, assistive technology, and mail clients were not exercised by this machine CLI/API cell and receive no proxy pass. Source-shape retention does not prove semantic presentation in human readers.

## Facts, inference, and residual risk

Fact: all measured revision, count, ordering, and canonical hashes equal the frozen baseline. Fact: source negotiation and spacer counts remain defective. Inference: the pinned CLI/API artifact did not drift; adjacent readers may still fail independently. No code suite was run, and no server or repository state was mutated.

Two task references embedded in the Paper were resolved: `task-1daff7bc1bf46ceb` and `task-79aa75e4be7a0067`. The textual token `task-gate` is not a durable task ID.

## Cycle payload

```json
{"assignment_id":"restart-survey-17","unit":"cloud-console-hardening-wave-29-2026-08-03::cli_api","revision":"18768b0a14c2eead927181c4a0e37c18","verdict":"unchanged_no_live_regression","raw_bytes":431200,"raw_sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15","canonical_blocks_sha256":"46ed01f7416f064f950cee3b00f1a59da00cd0cef523b2a6e4cf1e7cee4b1a50","blocks":"252/252","body_cells":316,"nested_list_words":"406/406","spacers":139,"source_html":{"status":200,"bytes":109924,"sha256":"d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9"},"source_json":{"status":406,"error_code":"internal_error"},"source_text":{"status":406,"error_code":"internal_error"},"typed_missing_cli":{"exit":4,"not_found":true,"request_id":true},"unchanged_failures":["spacer-migration","contract-provenance"]}
```
