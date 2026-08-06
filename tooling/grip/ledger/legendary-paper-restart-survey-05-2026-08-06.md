<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-05 | budget: 1400tok -->
# Restart Survey 05 — email live regression and frozen gates

Assignment `restart-survey-05` re-attested `cloud-console-hardening-wave-28-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged email-preview failures, no new deterministic regression, no improvement; delivered mail blocked**.

## Direct answer

The current HTTP email preview is byte-identical to the frozen E02 baseline at published revision `49c1534d9fb76d0d9adc7b97f25ec471`. Authored wording survives, but phone geometry, semantics, identity, navigation, and provenance still fail. The preview is not delivered Gmail, Outlook, or Apple Mail and grants no proxy pass to those readers.

## Fresh sample and identity

- One revision-pinned Paper, one raw HTTP preview, and two fresh headless-Chrome cells at 320 and 390 CSS px.
- Source: 237 unique blocks; 134 nonempty blocks; 103 exact-empty spacers; 43 headings; 18 tables with 57 authored headers; seven flat lists with 35 items; 13 callouts; 67 marks.
- Preview SHA-256: `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`, byte-identical to E02.
- All 16,358 source tokens survive in order and all 134 nonempty block token sequences are present.
- Three browser navigation attempts produced one transient HTTP 500 followed by two successful final cells.
- Delivered-mail cells: 0/6; the required denominator is two widths across Gmail, Outlook, and Apple Mail.

## Gate disposition

Canonical content identity and token preservation are positive controls, not full reader passes. The preview exposes 0/237 block-ID carriers and no revision, ETag, or immutable reader-revision carrier. All 18 tables are presentational; 57 visible headers have zero scoped-header carriers and zero captions. The output has zero semantic strong/code/em carriers for 67 marks and zero semantic or accessible-tone carriers for 13 callouts. It has no link, button, nav region, tabbable, history, paging, or structured task relation.

Both browser cells fail geometry: requested 320 renders at approximately 1046 CSS px with a 980 px client body; requested 390 renders at approximately 1045 px with the same 980 px client body. Both overflow horizontally. They also expose no `main`, `article`, language, block identity, revision identity, semantic mark, or semantic callout carrier.

The 103 exact-empty source spacers do not become empty preview paragraphs, but no identity/accounting map proves migration. Nested-list losslessness, headerless-table intent, alias conflict, and terminal geometry are not applicable to this unit. Real-reader capability is blocked.

## Facts, inference, and residual scope

Facts are the current hash, DOM counts, token/order comparisons, two final geometry cells, and one transient 500 above. Byte equality plus repeated measurements support the inference that the reader format has not changed. That does not prove delivered-mail fidelity, semantic equivalence, or reliability. Gmail, Outlook, Apple Mail, MIME source, spam filtering, remote images, assistive technology, Studio, and other reader surfaces were not visited.

## Cycle payload

```json
{"assignment_id":"restart-survey-05","unit":"cloud-console-hardening-wave-28-2026-08-03::email","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"UNCHANGED_EMAIL_PREVIEW_FAILURES_DELIVERED_MAIL_BLOCKED","preview_sha256":"cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621","baseline_byte_identical":true,"browser_cells":2,"geometry_pass":"0/2","authored_token_sequence":"16358/16358","nonempty_block_token_presence":"134/134","block_identity_carriers":"0/237","revision_carriers":"0/2","semantic_tables":"0/18","scoped_headers":"0/57","semantic_marks":"0/67","semantic_callouts":"0/13","accounted_spacers":"0/103","structured_navigation_targets":0,"transient_500_attempts":1,"delivered_mail_cells":"0/6","classifications":{"regression":0,"unchanged_failure":9,"improvement":0,"blocked":1,"not_applicable_or_control":5}}
```
