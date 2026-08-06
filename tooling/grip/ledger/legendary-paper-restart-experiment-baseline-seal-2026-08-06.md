<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-baseline-seal | budget: 1800tok -->
# Legendary Paper restart — baseline experiment seal

Authority: epic `task-a768c69e659add58`, wave `legendary-paper-reader-upgrade-wave-2026-08-06-restart`, wave revision `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`, inventory digest `227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc`, plan digest `9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45`.

Baseline is sealed at exactly three immutable assignments. It selects no implementation candidate. The deterministic seal verifier passes 15 checks with contract SHA-256 `bb24ce3baee61d76a210b97ebf8ebd9b17ea20ae1cb988ade4daae44907d3bef`.

| Assignment | Typed verdict | Result SHA-256 | Evidence archive SHA-256 |
|---|---|---|---|
| `restart-experiment-01` | canonicalizer passes with known reader risks | `614b3d182e3c0569a613779001147a9aaad899aa90dc3dbfa36545069528194e` | `db61dd8b614014de04fcf028abc8e0ed40129826649342fd66a914b14c8feed3` |
| `restart-experiment-02` | fail with blocked surfaces | `2bcc8b5468273c0ef7987fc1172ac3bc21d98e031ecc06b577d7058a4794e7f1` | `ad48c681b0a98100569e67501a76d994869a1443eb3ee45dcee520887465b13b` |
| `restart-experiment-03` | fail / rework | `b08000d7f84cafa3f0f078e346b50ef8c448d797ff30d3e9612f7c2b338d0b4c` | `04b73f0b0149e2a716bcfc849d30aee5021398ea8eddddb6e6e54e971f453363` |

## Frozen measurements

The oracle preserves 815/815 blocks, 113/113 authored header cells, 1,374/1,374 body cells, and 388/388 marks with zero authored loss and zero invented headers. Human-reader evidence preserves 3,456/3,472 carriers, exact reading order in 24/32 captures, and no page overflow in 18/32 captures. Table and callout semantics pass 0/32. Authenticated Studio is blocked 16/16; real assistive technology and delivered-mail clients are blocked 48/48 each and are not proxy-passed.

Terminal/platform evidence shows 2,018/3,472 authored visibility comparisons, leaving 1,454 missing. Display overflow and control-byte leakage are zero, but one false `not_found` and two silent failures violate hard gates. Related remains isolated in 32/32 captures.

The frozen denominator is four Papers, twenty reader-units, 815 blocks, 113 authored headers, 1,374 body cells, 388 marks, 30 callouts, eleven headerless tables, 381 exact-empty spacers, and eleven CCH29 nested-list items containing 406 words.

## Failure taxonomy

1. legacy PortableDoc dialect and nested-list carrier loss;
2. table, callout, and mark semantic degradation;
3. narrow public/email geometry overflow;
4. unavailable authenticated Studio, real AT, and delivered-mail evidence;
5. TUI discovery, history, navigation, help, and recovery gaps;
6. silent Related failure and invalid-width fallback;
7. method errors misclassified as `not_found`;
8. Accept negotiation and perspective substitution drift;
9. missing revision-bound validators and identity carriers;
10. capability, schema, OpenAPI, help, and pagination disagreement;
11. transport failures without server-joinable request identity.

All hard thresholds remain zero: authored loss, invented intent, schema invalidity, overflow, reading-order failure, silent substitution, false `not_found`, control leakage, silent secondary failure, identity conflation, retry-erased failure, non-idempotence, rollback failure, and proxy passes for missing readers.

## Advance rule

Diverge may begin because baseline round count is exactly three and the shared measurements, taxonomy, thresholds, and hashes are frozen. `restart-experiment-04` must test revision-fenced write-time migration; `restart-experiment-05` a shared read-time compatibility core; and `restart-experiment-06` a versioned canonical projection. Each must be runnable, twice-idempotent, rollback- or quarantine-backed, and emit receipts across all five readers. No candidate may win until Attack and Converge clear every hard threshold.
