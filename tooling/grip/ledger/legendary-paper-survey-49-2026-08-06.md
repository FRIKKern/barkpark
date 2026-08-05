<!-- doc-tier: cold | canonical-for: legendary-paper-survey-49-evidence | budget: 1200tok -->
# Survey 49 — PDS wave 44 / Studio structure

Verdict: `partial`. Studio receives all 99 source blocks as one ordered canvas run, but provides no generated outline for 32 headings, retains 15 empty editable paragraphs, and lacks a pinned full-scale regression.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`.
- Inventory: 99 unique IDs in exact order, comprising 32 headings (1/24/7), 48 paragraphs, five tables, ten lists, and four callouts; first ID `b1`, last `dbf34`; no heading-level skip.
- All five block types are canvas-eligible, so the partition contract produces one 99-block run. Its JSON seed is 76,024 bytes. `runToTiptap` maps the array one-for-one in order and the hook assigns that exact seed to one Web Component editor.
- Table conversion preserves body-row order and optional headers only when the current `head` key is present. Lists and callouts remain inside the same run. Existing fixtures cover smaller headed/headerless tables and ordered callout carriage, not this Paper-scale run.
- Studio retains Structure and Papers panes, a 300px metadata/relations inspector, and an Open standalone action. No generated heading outline, TOC, section rail, or jump control was found. Dormant `.bp-toc` styling does not synthesize navigation.
- Fifteen exact-empty paragraphs become real empty ProseMirror paragraph nodes, unlike the public reader where they emit no visible element. They likely create blank edit stops and excess vertical rhythm.
- Malformed seed JSON is caught without a visible recovery notice, risking a silent empty canvas.
- No exact 99-block/76KB Studio fixture, long-document latency proof, authenticated browser keyboard pass, or task named `pds-wave-44-2026-08-03::studio` was found.

Checked `paper_canvas.ex`, Studio `components.ex`, `paper_editor.ex`, `root.html.heex`, canvas `run-convert.js`/`index.js`/`table-node.js`, relevant Studio and editor tests, and the exact live Paper JSON. Targeted tests could not execute because this isolated worktree lacks Mix and `@tiptap/core` dependencies; no test pass is claimed. Verify must prove exact mounted ID order, latency, empty-node behavior, table usability beside the inspector, inspector selection/scroll preservation, outline value, and visible seed-failure recovery. No state mutation occurred.
