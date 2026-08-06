<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-21 | budget: 2100tok -->
# Restart Verify 21 — CLI/API content and revision parity

Assignment `restart-verify-21` ran a frozen 96-cell matrix over four Papers, eight read surfaces, and three rounds. Verdict: **refuted as an identity conjunction; exact ordered content passes 96/96**.

The surfaces were CLI get/query, flat/scoped document, flat/scoped public source, and flat/scoped newest-history detail. All 96 cells succeeded with exact document ID and exact ordered block IDs, types, and scalar content. Current document/source surfaces carry the frozen document `_rev` in 72/72 cells. Newest-history detail carries exact content in 24/24 but provides a history UUID and no document `_rev`, so the pinned-revision carrier passes 0/24 and identity-domain separation passes 24/24.

| Measure | Observed |
|---|---:|
| Logical matrix successes | 96/96 |
| Exact ordered content/ID | 96/96 |
| Current frozen `_rev` | 72/72 |
| History content exact | 24/24 |
| History document-`_rev` carrier | 0/24 |
| History UUID kept separate | 24/24 |

The 120 total GET/read attempts include 24 preparatory newest-history list reads. The frozen run has zero failed attempts, retries, or 5xx. Earlier smoke transients occurred before the denominator was frozen and are retained outside, not counted as matrix retries.

Canonicalization boundaries remain separate. Raw means exact body bytes plus separate headers. Envelope means `{document_id, document_rev, title, blocks, history_uuid}` while keeping identity domains distinct. Semantic means only the exact ordered block array. Raw document envelopes vary solely in request timing `ms`; deleting only that request-scoped value collapses three reads per Paper without masking any content difference.

Content equality proves that newest history stores the same snapshot content, not that its UUID equals or joins to the mutable document revision. Treating the history UUID as `_rev` would falsely conflate identity domains. The scope covers published/admin reads, not drafts, older history, or weaker principals.

Evidence root is `/private/tmp/bp-restart-verify21.4FESCE`. Matrix SHA-256 is `476f9491336b8ec248c2bd73bac260d835c52eba1180987cc342761190609602`; equality CSV SHA-256 is `25edc5a3bfc0a5cba91a8442732283beac9c49c99876fd0bc726e5c78ab98714`; manifest SHA-256 is `800181118a4c5b69b01843b0880396f6b0ee463d3468ea3da3fd1f793aff372a`. Saved-token scan found zero occurrences. Mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-21","cycle_assignment_uuid":"0364a833-56a0-45af-9a66-28147b0c0376","verdict":"refuted","cells":{"successful":96,"planned":96,"content_order_exact":96,"id_exact":96},"identity":{"current_pinned_revision":"72/72","history_content_exact":"24/24","history_pinned_revision_carrier":"0/24","history_uuid_separate":"24/24"},"attempts":120,"failed_attempts":0,"mutations":0,"manifest_sha256":"800181118a4c5b69b01843b0880396f6b0ee463d3468ea3da3fd1f793aff372a"}
```
