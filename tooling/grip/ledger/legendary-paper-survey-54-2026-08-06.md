<!-- doc-tier: cold | canonical-for: legendary-paper-survey-54-evidence | budget: 1200tok -->
# Survey 54 — PDS wave 44 / TUI80 semantics

Verdict: `partial`. Rich ANSI256 and NoColor preserve identical visible bytes, order, lists, callout carriers, and table bodies, but both drop all 12 authored table headers; NoColor also collapses H2/H3 distinction and the terminal exposes no semantic roles or revision stamp.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; canonical block-array SHA-256 `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce` for the captured CLI projection.
- Direct width-80 NoColor artifact: 111,922 bytes/1,305 lines/SHA `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`. ANSI256: 164,198 bytes/1,305 lines/SHA `d21b60298e12f3a17879daf16970118d8e2352095a3177340a7c4367749a3e0b`. Stripping 6,982 ESC bytes from rich output yields the exact NoColor SHA and byte comparison passes.
- Source order is stable; 99 source blocks minus 15 empty paragraphs produce 84 visible groups. All ten lists/85 items retain literal bullets and order. Four callouts retain a repeated `▌` carrier, but no textual Note/Info label or semantic role.
- H1 survives NoColor through uppercase plus an 80-cell rule. H2 and H3 lose their only weight/dim distinction and become textually indistinguishable; no `##`/`###` level carrier exists.
- All five table body grids/54 rows remain. `richblocks.go` reads `head`, while source blocks `b42`, `b66`, and `dbf8` carry `header`; all 12 header cells disappear. Box geometry has no programmatic table/header association.
- The pinned Paper has zero marks, links, wikilinks, task chips, or valuerefs. General NoColor links append href text and task-chip core data survives, but exact-fixture claims are unavailable.
- JSON exposes exact `_rev`; rendered bytes do not. TUI `Doc.Extra` retains it, but `buildPaperContent` does not display it.

Fresh `go test -count=1 ./internal/pdrender` and `CC=clang go test -count=1 ./internal/cli` passed. Checked block/table/inline renderers, decoder, CLI/TUI Paper seams, golden/profile tests, API envelope, and capture command. Verify must repair `header`, add textual H2/H3 and callout carriers, test a screen-reader-friendly linear table alternative and real terminal AT behavior, and expose an immutable revision digest. No state mutation occurred.
