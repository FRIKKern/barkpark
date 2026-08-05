<!-- doc-tier: cold | canonical-for: legendary-paper-survey-36-evidence | budget: 1200tok -->
# Survey 36 — Cloud Console wave 28 / Studio semantics

Verdict: `partial`. Studio retains all block text/order but omits 57 table headers and 67 marks, localizes mark write-loss to edited paragraphs, and presents keyboard/focus accessibility risks.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; source-to-canvas projection preserves 237/237 unique IDs, types, and order.
- All 43 headings, seven lists/35 items, 13 callout bodies, 155 table body rows/466 cells, and 31 task-like prose strings survive.
- Studio reads `head`, not source `header`; all 18 tables therefore omit 57/57 header cells and expose only `<td>` cells. Native table semantics exist when headers are present, but this Paper receives none.
- String-form `marks:["strong"|"code"]` are ignored: 67/67 marks across 16 paragraphs flatten, comprising 26 strong and 41 code records.
- Exact untouched projection emits zero operations. Editing an affected paragraph emits a whole-content patch without marks, making loss permanent. Editing a table emits rows plus `head:[]`; shallow merge retains legacy `header`, creating dual-key state while Studio remains blind.
- Four `warn` callouts paint as info; one absent tone projects as info. Five lists normalize `ordered:false`, three also lose `style:"bullet"`.
- Positive labels include `main aria-label="Editing <title>"`, labelled formatting buttons with pressed state, labelled Markdown source textarea, and visible native table buttons.
- Table Tab/Shift-Tab handlers consume keys at both grid edges, creating code-level keyboard-trap risk. Main contenteditable focus outline is removed with no replacement found. Callout severity remains visual-only.
- Targeted tests passed: table, callout parity, and canvas slots. The one-surface test did not run because local `@tiptap/core` was unavailable; no accessibility pass is claimed.

Authenticated browser/AT proof is still required for focus trapping, screen-reader table relationships, caret behavior, and deployed disposable-save behavior. No state mutation occurred.
