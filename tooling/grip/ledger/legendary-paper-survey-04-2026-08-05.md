<!-- doc-tier: cold | canonical-for: legendary-paper-survey-04-evidence | budget: 1200tok -->
# Survey 04 — Cloud Console Hardening wave 29 / Studio structure

Verdict: `partial`. The pinned source and deterministic Studio projection are fully checked; an authenticated deployed Studio browser session was unavailable because the scoped route redirected to login and the service token is not a user session.

## Exact coverage

- Paper: `cloud-console-hardening-wave-29-2026-08-03` at revision `18768b0a14c2eead927181c4a0e37c18`.
- Sample: 1 Paper, 1 assigned Studio projection, all 252 top-level blocks.
- Source: 37 headings, 187 paragraphs, 13 lists, 11 tables, 4 callouts; zero invalid or duplicate ids/types.
- Deterministic `runToTiptap` projection: 252 nodes in exact source id/order; no opaque nodes.
- Empty structure: 139 exact empty paragraphs, all retained as editable empty ProseMirror paragraphs. `paper_structure.py` classifies 139 safe and 0 quarantined; digest `d5d13bff70fd7d5598d0b56e5873fdcee2ec4ed815a8cde9cab91ff19ae22c20`.
- Outline/density: no early ingress; 252 total blocks, 113 meaningful blocks, 37 headings, 10,365 primary-visible words.

## Findings

- `found` — 139 source empty-paragraph scaffolds are faithfully exposed in Studio.
- `found` — all 11 source tables carry legacy `header` with 35 cells and no canonical `head`.
- `found` — Studio `tableBlockToNode` reads only `head`, so the projection contains 11 tables but zero header rows. This is source-contract drift plus a Studio compatibility/visibility defect; the header content must be normalized, not invented or deleted.
- `not_found` — block loss or reordering: 0/252.
- `not_found` — invalid block objects/types/ids, duplicate ids, empty headings/lists/callouts.
- `partial` — authenticated deployed Studio painted geometry, narrow layout, and interaction behavior remain unobserved.

## Reproduction anchors

- Studio Paper selection and full block handoff: `api/lib/barkpark_web/live/studio/studio_live/components.ex:89-111,252-267`.
- Canvas eligibility and one-run partition: `api/lib/barkpark_web/live/studio/studio_live/paper_canvas.ex:305-384`.
- Exact node/id projection: `api/assets/paper-editor/src/canvas/run-convert.js:630-672`.
- Legacy table incompatibility: `api/assets/paper-editor/src/canvas/run-convert.js:1669-1695`.
- Empty paragraph conversion: `api/assets/paper-editor/src/convert.js:379-384`.
- Canonical table tests passed; the parity test could not run because `@tiptap/core` is absent. Existing tests contain no legacy-`header` fixture.

## Risks and unvisited ranges

Builders must preserve the 35 existing header cells while normalizing `header → head`. Empty-paragraph removal remains revision-fenced and cross-reader gated. Unvisited: authenticated live Studio DOM/screenshots, phone geometry, editing/saving production, historical revisions, other readers, and the other three campaign Papers. No production, Paper, or task mutation was performed.
