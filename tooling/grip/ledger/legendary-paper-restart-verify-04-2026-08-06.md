<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-04 | budget: 1800tok -->
# Restart Verify 04 — public authored-text preservation

Assignment `restart-verify-04` tested exact public block order and codepoint-preserving survival of every nonempty authored fragment. Verdict: **refuted, high confidence**.

Fresh CLI, source, and public reads matched all four frozen revisions/counts. The canonical boundary required source `.blocks` to equal the CLI block array, recursively collected nonempty `text`/`value` strings through ordered content/item/header/head/row/block/slot arrays, and matched each fragment codepoint-exact and sequentially within its public `data-block-id` wrapper. HTML entities were decoded; whitespace was neither folded nor fuzzily matched.

Public preserves 815/815 unique blocks in exact order, but only 2,571/2,582 authored fragments and 283,455/285,723 characters. CCH28 passes 793/793 fragments, PDS44 369/369, and PDS45 536/536. CCH29 passes 873/884: blocks `w29D015` and `w29D022` lose eleven array-wrapped paragraph items totaling 2,268 characters. Their public output is five and six repetitions of an empty `<li><span></span></li>`. Repeating CCH29 three times changed request-scoped page bytes but retained the same article hash and empty wrappers 3/3.

| Paper | Blocks ordered | Fragments | Characters | Passing blocks |
|---|---:|---:|---:|---:|
| CCH28 | 237/237 | 793/793 | 93,818/93,818 | 237/237 |
| CCH29 | 252/252 | 873/884 | 63,984/66,252 | 250/252 |
| PDS44 | 99/99 | 369/369 | 61,492/61,492 | 99/99 |
| PDS45 | 227/227 | 536/536 | 64,161/64,161 | 227/227 |

The likely code seam is bounded: `compose.ex` normalizes scalar/map list items but passes a list input through, then sends the resulting paragraph map to the inline composer, yielding an empty span. Existing composition tests cover scalar and inline-node arrays but not array-wrapped paragraph items; a related drift test already documents empty items. This inference is not needed for the verdict.

Public lacks an intrinsic immutable revision binding, so the source/public capture is not atomic. Exact 815-ID alignment plus three repeated stable article failures makes the current counterexample decisive. Connected browser behavior, accessibility, historical revisions, and other readers remain outside this assignment.

## Cycle payload

```json
{"assignment_id":"restart-verify-04","cycle_uuid":"6a1411b7-8bb2-4804-b37d-d8ec05772508","verdict":"refuted","samples":{"source":"4/4_200","public":"6/6_200","repeated_failure":"3/3"},"projection":{"blocks":"815/815","ordered_papers":"4/4","unique_ids":"815/815"},"preservation":{"fragments":"2571/2582","characters":"283455/285723","passing_blocks":"813/815","lost_fragments":11,"lost_characters":2268},"failures":{"paper":"CCH29","blocks":["w29D015","w29D022"],"article_sha256":"9a8587e8b82d32194cd218caa1aa8f386bc9fbecb1dde2113dfaf073e2416c87"},"canonical_source_public_atomic":false,"mutations":0}
```
