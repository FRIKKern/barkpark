<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-49 | budget: 1400tok -->
# Restart Survey 49 — PDS45 email provenance/current pin

Assignment `restart-survey-49` re-attested `pds-wave-45-2026-08-03::email` at revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **live preview is stable and text-complete, but mutable, semantically lossy, and unable to identify its Paper revision**.

Document, source, and newest immutable history revision `4afe0099-26af-40eb-8943-f6935c16c29d` contain the same 227-block array, compact SHA `f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da`.

Seven successful scoped/public/public-dataset preview reads were byte-identical: HTTP 200, 119,290 bytes, SHA `3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900`, valid UTF-8. Scoped-dataset route returns 404 because scoped routing exposes only the non-dataset form.

Projection is text-complete: 536/536 authored fragments and 64,151 characters survive; 33/33 headings retain outline SHA `3dec79d4…bb92`; seven lists/44 items, nine callouts, and 12 tables survive. All 124 exact-empty paragraphs compact away, leaving 42 nonempty paragraphs. Residual loss: strong `0/8`; 12/12 tables `role=presentation`; nine headers have no scope/caption; semantic callouts `0/9`; zero block IDs, slug/revision carriers, `lang`, main/article, or viewport metadata.

Theme and title injection are live dependencies outside the Paper pin. Task/link resolvers run but are dormant because this fixture has no task/link nodes. No ETag, Last-Modified, Content-Disposition, or revision validator exists.

This is HTTP HTML, not MIME: no From/To/Subject/Message-ID/MIME-Version, multipart/transfer encoding, sender invocation, provider receipt, or delivered-client artifact was found. Gmail, Outlook, Apple Mail, dark mode, images, and AT remain unvisited. No state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-49","unit":"pds-wave-45-2026-08-03::email","verdict":"found","confidence":"high","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","blocks":{"count":227,"sha256":"f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da","document_source_revision_equal":true},"preview":{"successful_samples":7,"status":200,"bytes":119290,"sha256":"3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900","stable":true,"revision_carrier":false},"projection":{"text_fragments":"536/536","missing_chars":0,"outline":"33/33","lists":"44/44","empty_spacers_removed":124,"strong_marks":"0/8","presentation_tables":"12/12","semantic_callouts":"0/9"},"routes":{"scoped":200,"public":200,"public_dataset":200,"scoped_dataset":404},"delivery":{"http_preview":true,"mime":false,"smtp":false,"provider_receipt":false,"clients_unvisited":["gmail","outlook","apple_mail"]},"mutations":0}
```
