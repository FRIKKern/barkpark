<!-- doc-tier: cold | canonical-for: legendary-paper-survey-33-evidence | budget: 1200tok -->
# Survey 33 — Cloud Console wave 28 / Public semantics

Verdict: `partial`. The deployed public reader preserves all authored block order and visible text, but contradicts table accessibility, flattens every authored strong/code mark, and downgrades four warning callouts.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; 237 source blocks and 237 deployed `data-block-id` wrappers in exact order from `w28b001` through `w28r0049`.
- All 43 headings survive exactly as one H1, 24 H2, and 18 H3. Browser title, H1, canonical URL, OpenGraph/Twitter title, JSON-LD headline, and `html lang=en` preserve document identity.
- All 18 tables retain 57 visible header cells and 155 rows, but every table is emitted with `role="presentation"`. This contradicts genuine data-table structure and can suppress assistive table navigation/header relationships.
- All seven unordered lists and 35 items retain semantic markup, order, and text.
- Source contains 67 string-form mark records: 26 `strong` and 41 `code`. Deployed output contains zero `<strong>` and zero `<code>` elements; words survive as plain text. The shared inline renderer recognizes map-form marks only and passes string marks through unchanged.
- All 13 callout bodies survive. Source tones are six `info`, three `warning`, and four `warn`; deployed classes are ten `info` and three `warning`. The unsupported `warn` alias falls through to `info`, contradicting four cautionary callouts.
- Callout tone is visual-only: no accessible role or severity label accompanies it.
- Source has zero structural links, wikilinks, or task nodes. Thirty-one task-like identifiers remain plain prose; sampled live authority includes moved and missing tasks, which the reader cannot disclose.

Required Verify work: measure corpus prevalence of string marks and `warn`; prove screen-reader impact of presentation-role tables; decide alias/canonicalization compatibility; and distinguish frozen task prose from live task links. Mobile layout, contrast, focus, zoom, print, dynamic updates, email, and TUI remain unvisited. No state mutation occurred.
