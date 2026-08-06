<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-06 | budget: 1400tok -->
# Restart Survey 06 — email negative capability and evidence strength

Assignment `restart-survey-06` re-attested `cloud-console-hardening-wave-28-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial preview proof; provenance and delivered mail blocked; live reliability contradicted**.

## Direct answer

Successful HTTP preview responses prove complete inline-styled HTML for current Paper content. They do not prove MIME construction, SMTP delivery, inbox placement, clipping, or rendering in Gmail, Outlook, or Apple Mail. The preview lacks revision/provenance carriers and its live availability is currently unreliable.

## Fresh controls

Positive controls across flat, dataset, and scoped routes each returned HTTP 200, 170,149 bytes, and SHA-256 `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`. All three were byte-identical and contained one doctype, one title, 642 inline styles, one 600 px max-width carrier, zero style tags, and zero scripts.

Published source remained stable in 5/5 reads: 130,346 bytes, revision `49c1534d9fb76d0d9adc7b97f25ec471`, 237 blocks, source SHA-256 `34332ee5666902161af9abe4f96c8243374f93f1f143ba567d2d5bc2b51fba8b`. Three unique email/deployment strings appeared 3/3 in source and preview.

Reliability control contradicted a dependable reader: only 2/5 preview reads returned the expected 200/hash; 3/5 returned identical HTTP 500 error pages. Missing-slug controls returned flat 404 and scoped 404, but dataset 500, contradicting universal plain-404 behavior.

Adversarial dataset selection failed closed with two 404s. `?perspective=draft` returned HTTP 200 with the published preview hash, showing that this query cannot select draft content. Encoded `/%2e%2e/email` returned 500 without observed disclosure. A host-poison attempt was intercepted by Caddy and did not exercise controller origin logic.

## Evidence ruling

Proven: successful output is standalone inline-styled HTML; three route forms can return identical bytes; selected source wording survives; invalid datasets fail closed.

Inferred: the preview came from current revision `49c153…`, based on matching content and inspected controller flow. The response contains zero revision token, ETag, Last-Modified, Content-Location, block ID, or even Paper-slug token, so it is not cryptographically or operationally self-identifying. Live task resolution also means preview bytes need not be a pure function of an immutable Paper revision.

Blocked: zero messages were sent and zero inbox/client cells inspected. Gmail, Outlook, Apple Mail, MIME, SMTP headers, spam placement, dark mode, remote images, clipping, and a live ambiguous-source mutation control remain unproven. Renderer phrases such as “Outlook is the contract” and “exact email byte stream” express intent, not delivered-reader evidence.

Contradicted: dependable preview availability and universal missing-content error behavior. Capability/task reads also produced upstream 500s with request IDs `GMkYnPlsnIqYyYwAIFvx`, `GMkYnY05X37AvOoAIFwx`, and `GMkYjc_37m42iAMAIFWx`. No request-correlated server logs were available, so the post-source failure cause remains inference.

## Cycle payload

```json
{"assignment_id":"restart-survey-06","unit":"cloud-console-hardening-wave-28-2026-08-03::email","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"PARTIAL_PREVIEW_PROOF_PROVENANCE_AND_DELIVERED_MAIL_BLOCKED_RELIABILITY_CONTRADICTED","preview_sha256":"cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621","route_identity":"3/3","source_stability":"5/5","preview_stability":"2/5","preview_500":"3/5","missing_slug":{"flat":404,"dataset":500,"scoped":404},"invalid_dataset":"2/2_404","source_content_samples":"3/3","revision_carriers":"0/4","delivered_gmail":0,"delivered_outlook":0,"delivered_apple_mail":0,"classifications":{"proven":4,"inferred":1,"blocked":3,"contradicted":2}}
```
