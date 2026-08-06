<!-- doc-tier: cold | canonical-for: legendary-paper-verify-12-evidence | budget: 1900tok -->
# Verify 12 — NoColor TUI semantics, identity, history, and focus

Verdict: `refuted`. NoColor preserves all heading text, strong task-chip grammar, selection glyphs, focus ownership, and scrolling cues, but collapses heading depth, legacy table-header roles, callout tones, strong/code emphasis, 406 nested-list words, block identity, Paper history, and hover state.

| Paper | NoColor lines | NoColor SHA-256 |
| --- | ---: | --- |
| Cloud Console wave 29 | 1,440 | `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83` |
| Cloud Console wave 28 | 2,357 | `baa96ee0db0f27fbafebf6388fe7845982fdec2291c504478791d843880c96e4` |
| PDS wave 45 | 1,537 | `1c9c67b7f7fba9459a81c60ac12ba432ef110126323d5293c4d4c3fa99940746` |
| PDS wave 44 | 1,305 | `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076` |

- All repeated renders reproduce their hashes and contain zero ESC bytes.
- All 145 heading texts remain visible. H1 retains uppercase/rule treatment, but 98 H2 and 43 H3 lines are structurally identical without color: 141 authored depth distinctions disappear.
- Thirty-five legacy-header tables contain 113 cells; the renderer never reads top-level `header`. Thirty-nine labels disappear entirely, while others occur only coincidentally in body/prose text.
- All 388 mark records across 10,394 characters retain text but lose strong/code distinction. All 30 callouts use the same NoColor bar without a tone label or glyph; `warn` and `note` also fall through to info under ANSI.
- Eleven Wave 29 paragraph-map list items lose all 406 words. None of their full text appears.
- All 815 block IDs are decoded but not projected. Standalone output exposes no slug or authoritative `_rev`; task-board FramePaper positively exposes `slug · rev` but still omits block IDs.

The canonical task-wikilink fixture is a strong positive result. Its golden `eaa2f3e869fb27dac2256500fa56ec9ddfe8c030a1bb2e9998066830c967339a` retains lifecycle glyph/text, priority, criteria progress, title, selected rail marker, and driven-task grouping without color. In-body chips are display-only, and their cache key omits task state, so status/criteria can remain stale until Paper revision or width changes; the live rail does not share that staleness.

Paper history is absent:

- Main TUI Paper mode shadows generic history; `?` shows only Paper scrolling/Studio guidance and `H` is a no-op.
- Task board reading has no `H`/`?` branch; its footer advertises movement, open/back, space-scroll, and mouse only.
- Standalone `--revision-id` is release/Wave identity, not document-history replay; a real history UUID demands an epic release tuple. `doc history` separately returns history normally.

Focus/scroll positives: wheel over right preview focuses it; `j` then scrolls it; pushed frames free-scroll one line; above/below cues survive; boundaries settle; divider-side spacing encodes focused pane; grabbed divider changes `↔` to `↔↔`; hover debounce guards pass. Refutation: row hover and divider rest-versus-hover are color-only, so NoColor cannot distinguish them.

Targeted `pdrender`, `taskboard`, and `cmd/barkpark` tests pass. ANSI-stripped output equals NoColor for three Papers; Wave 29 differs because styled table content changes wrapping, corroborating verify-10. No file, task, Paper, or server mutation occurred.
