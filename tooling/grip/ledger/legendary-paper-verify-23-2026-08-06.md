<!-- doc-tier: cold | canonical-for: legendary-paper-verify-23-evidence | budget: 1800tok -->
# Verify 23 — exact-empty spacer removal preservation

Verdict: `proven`, with expected structural changes. Removing only canonical exact-empty top-level paragraphs preserves every authored semantic block and semantic-text hash across all four pinned Papers. Public article HTML, email HTML, and width-80 Go/TUI output are byte-identical. Studio and CLI/API expose the intended deletion structurally but preserve every surviving block exactly.

| Paper | Before → after | Removed |
| --- | ---: | ---: |
| Cloud Console wave 29 | 252 → 113 | 139 |
| PDS wave 45 | 227 → 103 | 124 |
| Cloud Console wave 28 | 237 → 134 | 103 |
| PDS wave 44 | 99 → 84 | 15 |

Every removed block had exactly keys `content`, `id`, and `type`, with type `paragraph` and `content: []`. None carried extra scalar or semantic fields. Ordered surviving `{id,type,content,text,value}` hashes matched the transformed arrays for all four; independent ordered nonblank text/value hashes were unchanged. Applying the transform a second time produced byte-identical JSON.

Five-reader evidence:

- Public: production Elixir article rendering is byte-identical at 87,106 / 87,006 / 123,645 / 75,443 bytes. LiveView would remove one keyed empty wrapper per deleted block, but no CSS gives those wrappers spacing.
- Studio: production `runToTiptap` compacts 252→113, 227→103, 237→134, and 99→84 nodes; every surviving projection is equal and deterministic. The only removed editor nodes are empty caret/focus stops.
- TUI80/direct Go: production renderer is byte-identical at 1,421 / 1,523 / 2,337 / 1,285 lines. Targeted paragraph tests pass.
- Email: production Elixir email rendering is byte-identical at 120,746 / 118,961 / 169,740 / 97,939 bytes.
- CLI/API: production `PaperSource.DocumentJSON` preserves each input object exactly. Transformed hashes and block counts differ only because the 381 spacer records are intentionally absent.

No authored text, nonempty block, nested content, or extra metadata was found among removed nodes. Full authenticated browser caret interaction was not driven; Studio preservation is established through its production projection. The isolated Elixir runner used an OTP-json-backed local shim because API dependencies/build artifacts were absent; every exercised corpus path completed.

The verifier used temporary artifacts only and trashed them afterward. No publish, API mutation, task mutation, or repository edit occurred. Concurrent leader work added Verify 22 while this assignment ran; the verifier did not touch it. Evidence is pinned to `6a32db719b6427b490884053763aba63b36f1d7a`.
