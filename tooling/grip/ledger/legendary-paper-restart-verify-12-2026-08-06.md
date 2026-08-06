<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-12 | budget: 2000tok -->
# Restart Verify 12 — Studio converter round trip

Assignment `restart-verify-12` tested exact `runToTiptap → docToBlocks/runToOps` fidelity across all 815 frozen blocks. Verdict: **refuted, high confidence**.

All top-level IDs/order survive and untouched `runToOps` is empty for 4/4 Papers, but all four deep-equality gates fail: 672 blocks reconstruct exactly and 143 change. CCH28 changes 40/237, CCH29 60/252, PDS44 17/99, and PDS45 26/227. Repeating the probe produced the identical run hash twice.

The reconstruction drops all 388 stored marks across 78 blocks and 10,394 marked characters, all 113 legacy header cells across 35 tables, and all eleven CCH29 paragraph-wrapped nested-list items (2,268 characters/406 words). Thirty-two list blocks also differ through `style`/`ordered` normalization. Explicit callout tones survive converter projection 16/16, including `warn`, `warning`, and `note`, but all fourteen tone-absent callouts materialize `tone:"info"`, so byte equality still fails.

| Paper | Blocks | Exact | Changed | Deep equal |
|---|---:|---:|---:|---:|
| CCH28 | 237 | 197 | 40 | no |
| CCH29 | 252 | 192 | 60 | no |
| PDS44 | 99 | 82 | 17 | no |
| PDS45 | 227 | 201 | 26 | no |

Root causes are direct. `convert.js` imports text without its marks; paragraph-wrapped list items carry `content` while the fallback traverses only `children`; `run-convert.js` imports canonical `head` but not live legacy `header`. Empty `runToOps` is not losslessness proof because its comparison reprojects the previous source through the same lossy adapter.

Focused canonical tests passed 36 cases across table, callout shorthand/parity, and canvas slots. Three broader editor tests could not start because local `@tiptap/core` is absent; no dependency was installed. This result proves converter JSON behavior, not connected editor validation, transactions, shallow-merge persistence, save, or reconnect behavior.

After evidence collection the isolated worktree directory disappeared externally; the committed branch remained intact and the leader recreated the clean worktree at the same commit before recording this result. No verifier temporary files or uncommitted evidence were lost.

## Cycle payload

```json
{"assignment_id":"restart-verify-12","cycle_uuid":"37ba4e86-6a25-491a-9323-da9e67a49cb0","verdict":"refuted","confidence":"high","fixtures":4,"blocks":815,"deep_equal":"0/4","exact_blocks":672,"changed_blocks":143,"ids_order_exact":"4/4","runToOps_empty":"4/4","marks":"0/388 reconstructed","legacy_headers":"0/113 reconstructed","cch29_nested_items":"0/11 text-bearing","cch29_nested_words":"0/406","explicit_callout_tones":"16/16 converter-preserved","absent_tones_materialized_info":"14/14","focused_tests":{"pass":36,"dependency_blocked":3},"mutations":0}
```
