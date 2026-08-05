<!-- doc-tier: cold | canonical-for: legendary-paper-survey-51-evidence | budget: 1200tok -->
# Survey 51 — PDS wave 44 / Studio semantics

Verdict: `partial`. Studio View preserves semantic heading/list order but suppresses data-table semantics; the default editable canvas uses stronger native tables, yet its hydrated accessibility tree, focus visibility, tab sequence, and immutable revision identity remain unproven.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; 99 blocks: 32 headings (1/24/7), 48 paragraphs including 15 empty, five tables, ten unordered lists/85 items, and four untoned callouts.
- Studio View iterates source blocks inside one `<article>` and byte-reuses the canonical article renderer. Deterministic tests prove native H1/H2/H3 order and list semantics, but explicitly exclude browser geometry and client JS.
- All five View tables render as `<table role="presentation">`. Three retain 12 native `<th>` cells and two are headerless, but none has `scope`/`headers`; the presentation role may remove table navigation entirely from accessibility APIs.
- All four non-collapsible callouts render as roleless informational `<div>` elements without a note/status/alert role or accessible group label.
- Default canvas receives one ordered 99-block JSON run in a named `main` landmark. Its table node uses native table/th/td elements and visible row/column/header buttons, but puts header and body rows in one `tbody`, has no explicit header associations, consumes Enter inside cells, and implements custom Tab/Shift-Tab movement.
- Editor CSS removes focus outlines from contenteditable/ProseMirror focus without an equivalent replacement found for the main editing region. Atom controls have their own focus-visible ring, so browser proof is required before calling this a failure.
- Inspector code uses a named aside, inert covered content, Escape dismissal, and trigger-focus return; save feedback is a polite status. Actual hydrated reading order, heading rotor/list exposure, tab traversal, focus retention, and AT table behavior were not proven.
- Studio `data-rev` is numeric stream/content revision, not the top-level 32-hex Paper `_rev`; the DOM cannot independently prove the pinned immutable revision.

Checked Studio components, canvas partition/editor, mount/shared Paper state, canonical walker, accessibility proof tests, table/callout nodes, parity fixtures, and editor CSS. Node/Mix tests could not start because isolated dependencies are absent; no pass is claimed. Verify requires authenticated DOM/AX proof for all five tables, 32 headings, ten lists, four callouts, ProseMirror focus, table escape, inspector focus, and an explicit immutable revision stamp. No state mutation occurred.
