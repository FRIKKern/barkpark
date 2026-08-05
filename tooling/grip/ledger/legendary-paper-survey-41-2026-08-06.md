<!-- doc-tier: cold | canonical-for: legendary-paper-survey-41-evidence | budget: 1200tok -->
# Survey 41 — Cloud Console wave 28 / email reader

Verdict: `partial`. Desktop prose is readable inside a 600-pixel card, but one table already overflows at desktop width and the table-heavy Paper becomes severely horizontally clipped on phone widths.

- Authority: deployed deterministic email bytes are 170,149 bytes at SHA-256 `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`; an immediate repeat is byte-identical.
- Deterministic Chromium at 1024×900 reports a 648-pixel outer card / 600-pixel content region and a 38,309-pixel-tall document. Seventeen tables fit the card; one reaches 854.94 pixels and creates 43 pixels of document overflow.
- At 390×844, the card shrinks to 366/318 pixels while the document reaches 56,986 pixels tall and 891 pixels wide: 501 pixels of horizontal overflow. Fifteen of 18 tables cross the viewport; only about 41.4% of the widest table is visible from its left edge.
- At 320×568, the card is 296/248 pixels, the document is 64,233 pixels tall and still 891 pixels wide, with 571 pixels of overflow. Seventeen of 18 tables cross the viewport and only about 33.2% of the widest is visible.
- At 600×900, the document is 891×42,662 pixels with 291 pixels of horizontal overflow; six tables exceed content and four exceed the viewport.
- Tables use `overflow:visible`; the artifact contains zero horizontal-scroll wrappers, zero responsive media rules, and no viewport meta tag.
- All headings and 134 substantive card children survive, with zero blank paragraphs. There are no authored links in this Paper, so link readability remains unexercised.
- The response contains the exact title in `<title>` and the authored H1, but no slug or revision identity. The controller exposes exact HTML bytes a backend should send; this survey did not prove an actual multipart email delivery path.

Verify should add responsive table containment/stacking at 320/390 pixels, cap the desktop-wide table, prove real mail-client behavior, and include visible revision/source identity without bloating the reading surface. No state mutation occurred.
