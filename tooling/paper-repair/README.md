<!-- doc-tier: human -->

# paper-repair — make ProseMirror-bodied papers readable again

A paper whose `body` is a stored ProseMirror/TipTap document (`{type:"doc",…}`)
matches none of the four shapes `PortableDoc.Projection.read_blocks/1` accepts,
and if it also has no `body_html` the reader answers **422 on every surface** —
web reader and `bp paper view` alike. It is not a reader outage: papers that
carry a top-level `blocks` array serve 200 on the same code path in the same
minute.

The repair is a **data write**, not a server change: give the paper the
top-level `blocks` array its reader wants. Those papers store no `body_html`, so
`cache_provenance/4` short-circuits to `:coherent` and the blocks are served.

```bash
# report only (default) — reads nothing but the paper, writes nothing
node tooling/paper-repair/repair-paper-blocks.mjs <slug> [<slug>…]

# write: patch + publish through `bp doc mutate`, then read the field back from
# the published perspective and curl the reader
node tooling/paper-repair/repair-paper-blocks.mjs <slug> --apply
```

Re-running a repaired slug is a **verify**: read-only, and it still fails (exit
1) if the stored blocks stop matching the body or the reader stops answering 200.

## What it refuses, and why that matters

| Case | Behaviour |
|---|---|
| paper carries `body_html` (the *html_only* population) | **REFUSE, even with `--apply`.** Those papers render today through the HTML fallback. Give one a `blocks` array and the reader stops falling back and runs `cache_provenance/4` — stored HTML vs a fresh render, no `body_html_sv` stamp — which classifies `:divergent`, a hard 422. A blanket backfill breaks working papers. |
| paper already has a top-level `blocks` list | verify instead of write |
| `body` is not a ProseMirror doc | skip |
| converted text ≠ source text | **abort before writing** |

## The trap in the conversion

`compose.ex:357`: *"The callout FLATTENS its single-paragraph body slot to
INLINE"*. The PortableDoc callout body is ONE inline slot, so a blockquote (or a
stored `callout` node) with N paragraphs mapped naively to one callout silently
drops paragraphs 2..N. Here the extras **spill into sibling `paragraph` blocks**.
`prosemirrorDocToBlocks(body, {spillCallouts:false})` reproduces the lossy
mapping on purpose, and the CLI runs it alongside the real one so every run
reports what the naive path would have cost (e.g.
`deploy-reliability-wave-24-2026-08-08`: 410 characters across 9 paragraphs).

The inline half is **not** reinvented: `prosemirror-to-blocks.mjs` imports
`tiptapInlineToPd` from the shipped editor converter
(`api/assets/paper-editor/src/convert.js`). Only the block half is new, plus two
normalisations the stored corpus needs — unwrapping `text`-inside-`text` nodes,
and mapping the PortableDoc mark spellings `strong`/`em` onto TipTap's
`bold`/`italic` so emphasis is not dropped as an unknown mark.

## Fidelity is the gate

Every run compares the whitespace-normalised plain text of the source document
with that of the converted blocks — the **strings**, not just their lengths —
and refuses to write on any mismatch.
