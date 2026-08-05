<!-- doc-tier: cold | canonical-for: legendary-paper-survey-45-evidence | budget: 1200tok -->
# Survey 45 — Cloud Console wave 28 / CLI/API semantics

Verdict: `partial`. Machine JSON preserves the complete Paper dialect, but human CLI loses table semantics, projections are inconsistent, and error/revision/field-selection ergonomics are incomplete.

- Authority: pinned source and `bp paper view -o json` have byte-equivalent normalized block arrays at SHA-256 `697b972c…`, preserving 237/237 unique ordered IDs.
- JSON retains 43 headings, all 18 top-level `header` tables with 57 headers / 155 rows, 67 string marks (strong ×26, code ×41), seven lists / 35 items, and all 13 distinct callouts including `warn` and `warning`.
- Human CLI shares the table-header omission proven by the TUI/reader survey; machine JSON retains the data while rendered text drops its labels.
- Source contains zero structural link, wikilink, or task nodes. Its 31 task-like identifiers remain prose, so no live task lifecycle semantics can appear.
- `bp paper view -o json` returns a broad PaperDoc including blocks and derived HTML caches. Canonical `/source` returns narrow `{id,title,_rev,source:{kind,blocks}}`; the source client validates the union fail-closed, while broad CLI JSON intentionally bypasses that projection.
- `bp paper view` does not support `--fields`. History/revision are separate generic document commands using history UUIDs; the Paper viewer exposes no simple history or `_rev` selector.
- `bp doc history --limit 1|2|5|10` returns all 12 revisions each time. History records expose UUIDs but not the document `_rev`, and revision content cannot directly map the two identifiers.
- The public Paper schema declares seven metadata fields but omits the actual body vocabulary: blocks, IDs, marks, headings, lists, callout tones, and table/header shapes are undiscoverable to schema-driven clients.
- Missing-Paper CLI JSON double-wraps a clipped upstream JSON string inside `error.message`; raw source 404 is plain text. The composite unit ID is not a stored task.
- Published/drafts/raw probes currently resolve the same revision. One raw probe transiently returned an HTML 500 and an immediate repeat returned 200; this is recorded as a non-reproduced reliability risk.

Targeted API client tests pass. The default internal CLI build hit host CGO option `-E`, but the complete package passes with `CGO_ENABLED=0`. Verify should align human/machine table semantics, add field projection and simple revision selection, preserve typed upstream errors, standardize source errors, fix history limits and revision mapping, expose the PortableDoc schema, and probe perspective reliability. No state mutation occurred.
