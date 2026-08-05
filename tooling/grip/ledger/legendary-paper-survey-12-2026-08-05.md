<!-- doc-tier: cold | canonical-for: legendary-paper-survey-12-evidence | budget: 1200tok -->
# Survey 12 — wave 29 / Email semantic parity

Verdict: `found`. Most text and heading order survive, but lists, authored marks, table semantics, and callout meaning do not reach parity.

- Authority: exact revision `18768b0a14c2eead927181c4a0e37c18`; 252 blocks; email 121,072 bytes, SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`.
- Eleven paragraph-wrapped list items become empty `<li>`, losing 2,268 characters / 367 whitespace words (3.42% of source text).
- All 313 authored string-mark nodes lose distinction: 200 code / 4,363 characters and 113 strong / 4,145 characters. Email has zero code/strong/b or styled mark spans. String marks fall through the map-mark implementation in `inline.ex`.
- All 11 data tables retain 35 th and 316 td but hard-code `role="presentation"`, with no scope, headers, or header IDs.
- Four callouts retain colored content but have no role, ARIA, or spoken tone label; leading strong marks are also flattened.
- Headings match exactly: one H1, 27 H2, nine H3. 873/884 non-empty text runs survive in order; only the 11 list runs are absent.
- Document accessibility is partial: doctype/title/H1 exist, but `<html>` has no lang, there is no main/article landmark, and no ARIA. `Accept: text/plain` returns 406, so no produced text alternative exists.
- Links/images are unexercised because this Paper contains none.

Client-specific screen-reader impact, MIME generation, Outlook/Gmail/Apple Mail, forced colors, links, unsafe links, images, and alt text remain unvisited. No mail or state mutation occurred.
