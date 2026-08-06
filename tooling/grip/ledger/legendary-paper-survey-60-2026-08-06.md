<!-- doc-tier: cold | canonical-for: legendary-paper-survey-60-evidence | budget: 1200tok -->
# Survey 60 — PDS wave 44 / CLI-API semantics

Verdict: `partial`. Machine source is exact and the human CLI preserves headings, paragraphs, lists, table bodies, and callouts, but drops all 12 authored table-header cells and cannot prove immutable release provenance from the supplied assignment.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; 99 unique blocks: 32 headings, 48 paragraphs including 15 empty scaffolds, ten lists/85 items, five tables/54 body rows, and four callouts.
- `bp paper view -o json` is 328,256 bytes, SHA `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`. Public source is 76,255 bytes, SHA `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`. Their canonical block arrays match at SHA `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`.
- NoColor width-80 output is 1,305 lines/111,922 bytes, SHA `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`. ANSI-stripped rich output is byte-identical.
- Three tables store 12 nonempty cells in `header`; the Go renderer reads only `head`, so every authored header cell disappears while body grids remain. This is direct source-to-render loss.
- All blocks use canonical heading/paragraph/list/table/callout types. No marks, links, wikilinks, task nodes, or value references occur. Callouts omit tone/title/collapsible and use defaults.
- Public source intentionally projects only `id,title,_rev,source`. Raw CLI JSON retains the compatibility document envelope. Document `_rev` and history UUID are distinct identifiers.
- Source contracts for history, revisions, immutable release reads, and capture exist. Release reads verify exact Wave/candidate pins, headers, digest, ETag, and payload identity; capture records binary, deployment, parser, source, geometry, theme, and profile provenance.
- The supplied assignment lacked release-gate URL, Wave revision, candidate, role, and deployment digest, so candidate-bound provenance could not be executed. Current `_rev` proves current-state identity only.
- Live history/schema probes were inconsistent: this run saw router 404s for history, `/api/schemas` 500, and capabilities timeout, while another final survey later obtained history successfully. The inconsistency itself requires deployment/availability verification.
- OpenAPI advertises history/revision/schema routes but not public/immutable Paper source GETs or a discriminated PortableDoc block union. Seeded Paper schema is metadata-only and omits `table.header`.
- Missing-source and router errors do not share the canonical structured envelope. MCP exposes raw Paper JSON but not the PortableDoc schema.

Fresh `CC=clang go test -count=1 ./internal/apiclient ./internal/pdrender ./internal/cli ./cmd/barkpark` passed. Checked API/CLI/source/history/release/capture/MCP implementations, schemas/OpenAPI, render decoders, aliases, and pinned artifacts. No mutation occurred. Verify must prove deployed route identity, add `header` compatibility with a 12-cell golden, define `_rev`/history UUID mapping, publish source/schema contracts, normalize errors, and run a real candidate-bound capture.
