<!-- doc-tier: cold | canonical-for: legendary-paper-survey-11-evidence | budget: 1100tok -->
# Survey 11 — wave 29 / Email visual behavior

Verdict: `found`. Desktop is readable but extremely long; 390px rendering has severe horizontal overflow and two visually blank lists.

- Authority: exact revision `18768b0a14c2eead927181c4a0e37c18`; email SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`.
- Desktop 1024×813: 28,659px / about 35.3 screens, 10,001 words, no horizontal overflow.
- Mobile 390×844: 47,592px / about 56.4 screens; scrollWidth 648 versus clientWidth 390, a 258px overflow. 295 elements cross their layout width and 7/11 tables exceed the viewport.
- Table widths reach 612.2px; paired captures prove `CLAIM`/`COMMAND` cannot be seen together with `RESULT`, forcing sideways panning to reconstruct a row. Mobile tables consume 19,419px (40.8% of the document).
- Eleven empty list items form two unexplained blank regions: five rows / 157.3px and six rows / 189.8px, 347.1px combined. Source empty paragraph spacers produce zero empty `<p>`.
- Hierarchy is present (1 H1, 27 H2, 9 H3), but prose/tables use dense browser Times while lists use airier Iowan/Palatino styling. H1 wraps cleanly.
- `not_found`: desktop overflow, heading-order loss, empty paragraphs, or blank deserts beyond the two malformed lists.

Captures: `/private/tmp/legendary-paper-survey-11-email-1024x900.png`, `...email-emulated-390x844.png`, and paired first-table left/right captures. Gmail, Outlook, Apple Mail, 320px, dark mode, zoom, print, and screen readers were unvisited. No mail or state mutation occurred.
