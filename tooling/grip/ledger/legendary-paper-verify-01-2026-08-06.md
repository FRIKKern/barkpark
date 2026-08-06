<!-- doc-tier: cold | canonical-for: legendary-paper-verify-01-evidence | budget: 1400tok -->
# Verify 01 — exact-empty paragraph scaffolds

Verdict: `proven`. All 381 surveyed spacer paragraphs are exact-empty scaffolds. Removing precisely those blocks preserves every ordered nonempty block byte-for-byte under canonical JSON and preserves an independently extracted semantic-text sequence/hash for each pinned Paper.

| Paper | Before | Empty | After | Findings digest |
| --- | ---: | ---: | ---: | --- |
| Cloud Console wave 29 | 252 | 139 | 113 | `d5d13bff70fd7d5598d0b56e5873fdcee2ec4ed815a8cde9cab91ff19ae22c20` |
| PDS wave 45 | 227 | 124 | 103 | `f08092328594c4dd1038c7b1366adb491f83184fe2c36a07b7bae4a134ef2d59` |
| Cloud Console wave 28 | 237 | 103 | 134 | `8355804809dc92a08cf48657157b3089fbb578c7ec9c9eade42a359fa7572d6c` |
| PDS wave 44 | 99 | 15 | 84 | `2a1e09defc85e84ec54ac4556f729cee1e94156bd50569796efd5ad4dc0fae3c` |

- `scripts/paper_structure.py --summary-only` reproduced those counts exactly with zero quarantined findings.
- Every removed block has only `content,id,type`, `type:"paragraph"`, empty/missing content, and no semantic text. There are no whitespace-only near matches and `removed_with_semantic_text=0`.
- Independent before/after ordered-nonempty-block SHAs are identical per Paper: wave 29 `27f071ef…adc1f`, PDS 45 `f54748ac…2862a`, wave 28 `f4fcdd0a…6f191`, PDS 44 `b616daf5…77ae1`.
- Independent semantic-text SHAs are likewise identical: wave 29 `f521ccac…e9ec5`, PDS 45 `b3b215ee…7dc9`, wave 28 `c41ae3c4…13a25`, PDS 44 `e6706c1d…7f565`.
- Three repeated live reads per Paper retained the pinned revision, block count, empty count, and full canonical block hash.

Fact: deletion is source-semantically inert for all four Papers and therefore for source structure inherited by all 20 reader units. Inference: the blocks can be revision-fenced away without authored-content loss. Carried risk: deleting IDs changes structural identity, Studio editor focus stops, keyed public wrappers, and potentially reader rhythm; verify-23 must prove cross-reader visual and interaction parity before Build. Checked the structure tool, all four live Papers, campaign/Survey ledgers, and the verification plan. No state or repository mutation occurred.
