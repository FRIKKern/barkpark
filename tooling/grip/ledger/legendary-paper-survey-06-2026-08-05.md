# Legendary Paper survey 06 — Studio semantic/accessibility parity

## Verdict

**found** — Studio receives all 252 pinned blocks in exact source order and opening the default canvas emits zero block operations, but its editable projection is not semantically equivalent to the pinned Paper. It hides 35 table-header cells, blanks two list blocks containing 2,268 characters, drops 313 inline mark annotations from the editing model, and communicates non-collapsible callout tone through colour only.

Assignment: `survey-06`  
Unit: `cloud-console-hardening-wave-29-2026-08-03::studio`  
Pinned Paper revision: `18768b0a14c2eead927181c4a0e37c18`  
Lens: semantic/accessibility parity  
Audit date: 2026-08-05

## Exact sample and evidence boundary

- Sample: 1 revision-pinned Paper, 1 Studio reader, all 252 source blocks.
- Source: `bp -s guerrilla paper view ... -o json`; `_rev=18768b0a14c2eead927181c4a0e37c18`, 252 blocks; command-output SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`.
- Source types: 187 paragraphs, 37 headings, 13 lists, 11 tables, 4 callouts.
- Projection proof: the production JS converter was run directly over the exact source using `runToTiptap`, `docToBlocks`, and `runToOps` from `api/assets/paper-editor/src/canvas/run-convert.js`.
- Authenticated live Studio was **not accessible** from this worker. The canonical scoped URL redirects to `/login?...`; `bp auth me` reports that the available service token is not a user session. No browser DOM, accessibility-tree, keyboard, or screen-reader claim is made.
- The repository's existing LiveView proof explicitly stops at deterministic HTML/LiveView and does not claim browser geometry or JavaScript execution (`api/test/barkpark_web/live/studio/studio_live_portable_doc_accessibility_proof_test.exs:4-15`). This survey keeps the same evidence boundary.

## Facts

### Source order and no-write-on-open are preserved (`not_found` for loss)

- The exact source id sequence survives the Studio converter: 252 projected top-level nodes, zero missing ids, zero extra ids, and exact id order.
- The default Studio surface opens block-backed Papers directly as the editor and passes the stored block list to `paper_block_editor` (`components.ex:93-111`, `components.ex:252-267`).
- This Paper's five block kinds are canvas-eligible, so it becomes one canvas run whose `data-canvas-blocks` payload is the server's ordered block list (`paper_editor.ex:146-174`, `paper_editor.ex:242-268`).
- `runToOps(source, runToTiptap(source))` returned zero operations. Merely opening the editor is therefore op-free at the deterministic converter boundary despite normalization differences.
- The Studio shell is a named `main` landmark (`aria-label="Editing Cloud Console Hardening — wave 29 strategy"` by the component contract) and becomes `inert` while the metadata destination covers it (`components.ex:212-240`).

### Every table header disappears from the Studio canvas (`found`, critical)

- The pinned source has 11 tables, all encoded with the legacy-but-supported `header` key: 35 header cells, 98 body rows, 316 body cells.
- The public renderer deliberately accepts `head` and falls back to `header` (`api/lib/barkpark/portable_doc/render/compose.ex:643-648`). Studio's converter reads only `block.head` (`run-convert.js:1669-1689`).
- Exact projection result: all 11 `bpTable` nodes contain body rows but no `bpTableHeaderCell`; 35 source header cells are absent from the Studio editing surface.
- Studio's table DOM can be semantic when header nodes exist (`th` versus `td`; `table-node.js:381-414`), but this Paper never reaches that branch. The visible first row is presented as ordinary data, contradicting the source and the public reader.
- Table edit chrome can toggle a new header (`table-node.js:313-344`), but it cannot reveal the existing `header` value. A user is invited to reconstruct or overwrite a header Studio falsely represents as absent.

### Two source lists are blank in Studio (`found`, critical)

- `w29D015`: 5 unordered items, 1,431 characters.
- `w29D022`: 6 unordered items, 837 characters.
- Total: 11 items and 2,268 characters project to empty list items.
- Each source item is `[{type:"paragraph", content:[...]}]`. `listItemToInlineArray` treats any array as already canonical, then `inlineToTiptapNodes` does not recognize `paragraph` and only recurses through `children`, not `content` (`convert.js:27-136`, `convert.js:148-172`).
- This matches survey-03's public-reader text-loss sample, so the failure is cross-reader rather than Studio-only.

### Inline emphasis/code meaning is absent and edits are lossy (`found`, high)

- The source has 313 string marks across 54 blocks: 200 `code`, 113 `strong`; affected blocks are 32 paragraphs, 7 lists, all 11 tables, and all 4 callouts.
- The Studio inline converter recognizes nested portable nodes (`type:"code"`, `type:"strong"`) but its `text` clause ignores a text node's `marks` array (`convert.js:29-54`). All marked text therefore enters ProseMirror as unmarked text.
- Untouched open is protected by the zero-op comparison, but an edit to an affected block writes from the flattened model:
  - simulated one-character edit to paragraph `w29s002` produced one `patch-block` with zero marks, removing the source `strong` mark;
  - simulated one-character edit to table `w29s012` produced a coarse whole-table `{rows, head}` patch with zero marks, while the source table contains 31 marks.
- This is hidden write-loss: the editor neither shows the marks nor warns that editing the block will remove them.

### Callout tone remains colour-only (`found`, medium)

- The four source callouts are `warning`, `info`, `warning`, and `note`; none is collapsible and none has a title.
- Studio renders non-collapsible callouts as generic `div` elements with no role or accessible tone label (`callout-node.js:292-307`). Tone is bound entirely through a CSS class, and unknown `note` maps to `info` (`callout-node.js:95-103`, `callout-node.js:310-335`).
- Inference: readers who cannot perceive colour cannot recover warning/info/note intent; `note` is also visually contradicted as `info`. This matches the public-reader defect from survey-03.

### Accessibility/order proof is partial, not complete (`partial`)

- Deterministic proof establishes exact 252-block source order before DOM mount and a named `main` landmark.
- Table chrome inserts two buttons before each table and three after it in DOM order (`table-node.js:273-344`). They have visible text/title but no explicit grouping or relation to a named table. Whether this produces an understandable screen-reader/keyboard sequence requires a live accessibility-tree capture.
- The actual production DOM, focus order, selection behavior, and assistive-technology announcements remain unproved because authenticated Studio was inaccessible.

## Commands and captures

```text
bp -s guerrilla paper view cloud-console-hardening-wave-29-2026-08-03 -o json
bp -s guerrilla task get task-a768c69e659add58 -o json
bp -s guerrilla paper view legendary-paper-reader-upgrade-sweep-2026-08-03 -o json
bp -s guerrilla auth me -o json
curl -sS -L .../w/default/p/default/d/production/studio/paper/cloud-console-hardening-wave-29-2026-08-03
jq: revision/type/list/table/mark counts and exact source samples
node --input-type=module: runToTiptap/docToBlocks/runToOps over the exact CLI source
shasum -a 256 over the CLI JSON stream
rg + sed/nl: Studio component, converter, table, callout, and proof-test anchors
```

## Coverage ledger

| Item checked | Checked for | Result |
|---|---|---|
| Paper `cloud-console-hardening-wave-29-2026-08-03`, rev `18768...` | exact source revision, all 252 block shapes/order, headers, marks, malformed lists | **found** — exact revision; projection losses above |
| Scoped production Studio URL | authenticated real render | **partial** — route exists but redirects this worker to login; no user session |
| `api/lib/barkpark_web/live/studio/studio_live/components.ex` | source-to-editor handoff, editor default, landmarks/inertness | **found** |
| `api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex` | run partition, exact block payload, edit shell/status | **found** |
| `api/lib/barkpark_web/live/studio/studio_live/paper_canvas.ex` | canvas eligibility/order boundary | **found** — all five sampled kinds are canvas-eligible |
| `api/assets/paper-editor/src/convert.js` | prose/list/mark projection | **found** — nested-paragraph lists and string marks unsupported |
| `api/assets/paper-editor/src/canvas/run-convert.js` | complete run projection, table aliases, no-op and edit ops | **found** — `header` unsupported; zero-op open; lossy edited patches |
| `api/assets/paper-editor/src/canvas/table-node.js` | table semantics, editing controls, DOM order | **found** — semantic nodes exist but missing source headers never create them |
| `api/assets/paper-editor/src/canvas/callout-node.js` | tone semantics and accessible representation | **found** — generic colour-only div; `note` becomes info class |
| `api/lib/barkpark/portable_doc/render/compose.ex` | canonical reader tolerance for table-header alias | **found** — renderer accepts `header`; Studio converter diverges |
| `api/test/barkpark_web/live/studio/studio_live_portable_doc_accessibility_proof_test.exs` | existing deterministic accessibility coverage and its limits | **partial** — synthetic canonical shapes only; explicitly no browser/JS claim |
| Survey-03 report | cross-reader comparison | **found** — same list, marks, and callout losses; public preserves legacy table headers but marks table presentational |
| Campaign task `task-a768c69e659add58` | scope/criterion/current wave | **found** — in progress; criterion 1 is the 20-surface audit; current pulse dispatches Studio 4-6 |
| Campaign Paper `legendary-paper-reader-upgrade-sweep-2026-08-03` | current campaign identity and inventory context | **found** — current revision `421a25256c0d84cbd0bf6832f6d30a8f`, 30 blocks |
| Other tasks/Papers/readers | duplicate/prevalence search | **not_found / unvisited** — outside survey-06's bounded unit |

## Risks and targeted proof required

1. Capture the authenticated production Studio DOM and browser accessibility tree for this exact revision. Verify heading/list/table reading order, all five table-control stops per table, the named editing landmark, and inspector inertness.
2. Add the public renderer's `header` fallback to the canvas table projector, then assert all 35 header cells become `bpTableHeaderCell`/`th` without creating an operation on open.
3. Add real-source regression fixtures for list items shaped as `[{type:"paragraph", content:[...]}]` and string marks. Prove exact visible text and mark-preserving edits, not only canonical synthetic shapes.
4. Fence edits until mark parity exists. The most dangerous paths are coarse table edits (whole grid re-emitted) and the two blank lists (hidden source text can be overwritten from an empty editor).
5. Define a non-colour callout-tone contract and preserve `note` distinctly or normalize it explicitly at ingestion with recorded evidence.

## Unvisited ranges

- No authenticated production Studio DOM, screenshot, browser accessibility tree, screen reader, keyboard traversal, or CSS contrast run.
- No mutation, save, Paper/task update, production write, or test-pass claim.
- No other Paper revision or public/TUI80/email/CLI/API unit beyond survey-03 comparison evidence.
- No exhaustive duplicate-task search outside the campaign root.
