<!-- doc-tier: cold | canonical-for: legendary-paper-verify-28-evidence | budget: 1800tok -->
# Verify 28 — cross-reader accessibility parity

Verdict: `proven`. Accessibility parity fails across the exact 20-unit inventory in repeatable reader-specific ways; canonical source loss alone cannot explain the failures.

All four published Paper pins and block counts were freshly reproduced: Cloud Console 29 `18768b0a…` / 252, PDS 45 `b992fd8a…` / 227, Cloud Console 28 `49c1534d…` / 237, and PDS 44 `8bbd5d87…` / 99. The canonical census is 815 blocks, 145 headings, 46 tables, 113 authored header cells, 11 genuinely source-headerless tables, 30 callouts, and 388 mark records.

The evaluation matrix covered 20/20 units: four Papers across public, Studio, TUI80, email, and CLI/API, with no overlap or missing unit. Exact denominators:

- canonical revision and block parity: 4/4 pass;
- heading order: 20/20 pass;
- full heading-depth carrier: 12/20 pass and 8/20 partial because terminal H2/H3 distinction is color-only;
- full table accessibility parity: 0/20 pass, 16 fail, 4 machine/human split-partial;
- full callout accessibility parity: 0/20 pass, 16 fail, 4 split-partial;
- language/landmark parity: 8/12 applicable pass and 4/12 fail;
- semantic-mark parity: 0/15 marked units fully pass;
- canonical visible-text parity: 6 pass, 4 partial, 10 fail;
- self-attesting pinned revision identity: 0/20 full pass, 4 CLI/API partial, 16 fail.

Reader-created divergence is direct. Public and email preserve all 113 authored header cells, yet all 92 rendered table instances declare `role="presentation"`; zero headers have `scope` or `headers` associations. Studio drops all 113 legacy `header` cells because it reads only `head`; an otherwise-identical alias probe produced zero legacy cells and one modern cell. TUI and human CLI independently drop the same 113 cells. All 90 HTML callout instances across public, Studio, and email are roleless and unnamed. Email alone drops `lang`, `main`, and `article`. Studio consumes Tab/Shift-Tab at both table-grid edges and removes the primary editable-region focus outline. NoColor terminal output collapses H2/H3, tone, strong, and code distinctions. Machine CLI/API JSON remains exact while the human projection loses headers, distinctions, and visible revision identity.

Fresh terminal renders were width-contained but operationally immense:

| Paper | TUI-equivalent 48 | CLI 80 |
| --- | ---: | ---: |
| Cloud Console 29 | 2,511 lines | 1,440 lines |
| PDS 45 | 2,628 lines | 1,537 lines |
| Cloud Console 28 | 4,128 lines | 2,357 lines |
| PDS 44 | 2,152 lines | 1,305 lines |

None displayed its pinned revision. Width containment therefore does not restore hierarchy, relationships, revision identity, or navigation.

Fresh targeted Go `pdrender` and CLI tests passed, as did table-node checks. That green result is insufficient: the generic table suite covers `head`, not the live `header` vocabulary, while the dual-vocabulary probe exposes the production gap.

Prior public/email captures were reused only after exact current revision, block order, semantic text, and artifact hashes were validated. Public captures preserved exact top-level block-ID order. Email text matched after its expected prepended title except for Cloud Console 29's already-proven malformed-list loss. Fresh pure Studio projections were generated for all four Papers.

Some source debt amplifies the failures—11 tables genuinely lack headers, 14 callouts lack tone, Cloud Console 29 has paragraph-wrapped list items, and mark encodings vary—but it cannot create `role="presentation"`, remove language, swallow grid-edge Tab, or hide human revision identity while machine JSON retains it.

Static markup does not prove exact announcements in every browser and assistive-technology pair. Authenticated hydrated Studio focus/AT evidence remains incomplete for two Papers, and Gmail, Outlook, Apple Mail, VoiceOver, and NVDA were not exercised. Full Mix/editor suites were unavailable because dependencies were absent; pure Node projections and fresh Go tests ran. No deletion or repair-safety conclusion follows.

The verifier inspected the shared Elixir renderers and public/email controllers, Studio conversion/editor/table/callout/focus seams, Go API/renderer/CLI/TUI seams, the relevant survey ledgers, and all four pinned Papers. The repository stayed clean at `82f1b5e79ae0bc4e8189ae1692a652c0529c3e20`; no production or repository mutation occurred.
