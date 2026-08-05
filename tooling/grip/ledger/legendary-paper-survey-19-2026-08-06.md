<!-- doc-tier: cold | canonical-for: legendary-paper-survey-19-evidence | budget: 1200tok -->
# Survey 19 — PDS wave 45 / Studio structure

Verdict: `found`. Studio preserves all 227 top-level IDs and order on open, but 124 empty paragraphs create editor noise and its projection hides three legacy table headers and drops eight inline strong marks.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; canonical blocks SHA-256 `f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da`; ordered IDs SHA-256 `b12d92a0dc8af7aa2c2515e886037bcedcc57358333bcc0a73bf63a48108be80`.
- Inventory: 166 paragraphs, 33 headings, 12 tables, nine callouts, seven lists; zero missing or duplicate IDs and no malformed accepted-shape blocks.
- 124/227 blocks are empty paragraphs. Authenticated Studio payload, API source, and public wrappers contain the same 227 IDs in the same order; untouched conversion emits zero operations.
- Three tables (`block-10`, `block-32`, `block-79`) use legacy `header`, totaling nine header cells. Public composition accepts `head || header`; Studio imports only `head`, hiding these headers.
- Body edits can emit `rows` and `head` while shallow patching preserves stale `header`, creating ghost dual-key state. Header toggling can later expose the hidden legacy field again.
- Eight paragraphs carry flat text-node marks. Studio’s importer ignores those mark arrays; reconstruction removes all eight, and editing one affected paragraph would replace marked content with unmarked content.
- Complete reconstruction differs for 26 blocks: eight marked paragraphs and three legacy tables are loss risks; nine callouts and six lists undergo apparently semantic-stable default/canonical shape normalization.
- All 33 headings are nonempty with one H1, 23 H2, nine H3, and no level jump.

Persisted edit diffs, header-toggle cycles, browser public-vs-Studio visual/AX comparison, full tests, all historical revisions, and exhaustive linked-task prose remain unvisited. No state mutation occurred.
