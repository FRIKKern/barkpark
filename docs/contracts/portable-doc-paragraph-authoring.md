<!-- doc-tier: agent | canonical-for: portable-doc-paragraph-authoring | budget: 700tok -->
# Paragraph authoring carriers

The inline editor matches the Paper reader: nonempty `content` arrays take
precedence; otherwise a nonempty string `text` is shown. Unsupported scalar
content and non-string text values do not become invented visible prose.

No-op projection retains the original presence and values of `content`/`text`.
Plain edits to text-backed paragraphs retain `text`; rich edits use `content`.
Content-backed paragraphs retain their inline representation. Clearing primary
content also clears a stale string fallback so erased prose cannot reappear.
Unchanged inline source fields are retained exactly; unrelated block metadata
and IDs remain outside the emitted field patch.

`bpParagraphSource` is editor-only history state, never rendered into HTML or
imported from pasted HTML. Native splits may retain the text carrier while the
canvas assigns the new block its own identity. This introduces no document
migration, new dependency, nested-list support or hard-break support.

Tests: `src/__paragraph_carriers.test.mjs` and
`src/canvas/__paragraph_carriers.test.mjs` under `api/assets/paper-editor`, run
by `npm test`; browser checks verify public/Studio typing, save/reload and
desktop/mobile View/Edit geometry.

Code: `api/assets/paper-editor/src/convert.js`, `paragraph-source.js`,
`index.js` and `canvas/index.js`. Related: [heading authoring](portable-doc-heading-authoring.md).
