<!-- doc-tier: agent | canonical-for: portable-doc-heading-authoring | budget: 700tok -->
# Heading authoring carriers

The inline editor uses the same precedence as the Paper reader: a nonempty
`content` inline array wins; otherwise `text` is displayed. String, numeric and
boolean text values display as text; null and unsupported objects display empty.

An untouched heading retains its original `content` and `text` fields, including
inactive fallbacks and scalar types. Editing content-backed headings updates
`content`; editing plain text updates `text`. Rich formatting uses an inline
array rather than flattening marks into a plain string. Clearing primary content
also clears a visible scalar fallback so old text cannot reappear.

The editor's `bpHeadingSource` attribute carries source fields through history.
It is not rendered into HTML or accepted from pasted HTML. Native splits may
retain the text carrier; block IDs and unrelated metadata remain outside it.
The existing heading-level policy and hard-break guard are unchanged.

Tests: `src/__heading_carriers.test.mjs` and
`src/canvas/__heading_carriers.test.mjs` under `api/assets/paper-editor`, included
in `npm test`. Browser verification checks actual title visibility, following
block geometry and saved data across public and Studio View/Edit.

Code: `api/assets/paper-editor/src/convert.js`, `heading-source.js`, `index.js`
and `canvas/index.js`.
