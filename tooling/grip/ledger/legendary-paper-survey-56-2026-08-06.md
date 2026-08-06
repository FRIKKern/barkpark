<!-- doc-tier: cold | canonical-for: legendary-paper-survey-56-evidence | budget: 1200tok -->
# Survey 56 — PDS wave 44 / email reader

Verdict: `partial`. The exact email is structurally complete and respectable on desktop, but every table overflows mobile, typography is inconsistent, the message is excessively long, and Outlook/client safety is unproven.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; live dataset email returned 200/98,335 bytes and rendered exact 99-block content.
- Chromium geometry without added CSS: at 1440×900 the card is 648/600px and 25,474px tall with zero overflow (28.3 screens). At 390×844 it is 366/318px but document width is 611px, overflow 221px, height 41,961px (49.7 screens). At 320×568 it is 296/248px, still 611px wide, overflow 291px, height 51,586px (90.8 screens).
- All 32 headings, 33 non-empty paragraphs, four callouts, five tables, and 12 table headers survive. The H1 is 294px tall at 320px; the first normal H2 starts at y=1,490, over 2.6 screens down.
- All 5/5 tables overflow at both mobile widths. Intrinsic widths are 480, 575, 410, 539, and 549px. There is no local scroll wrapper, containment, stacked fallback, word-break rule, or safe mobile alternative; clients that clip the message can make right columns unreachable.
- All five genuine data tables carry `role="presentation"`. They retain THEAD/TH visually but accessibility semantics conflict.
- Headings/lists use an authored serif stack and spacious line height; all 33 paragraphs and callout prose inherit default Times/normal line height because the card sets no base typography, producing dense inconsistent rhythm.
- The artifact uses doctype/title/inline CSS and no scripts, stylesheets, classes, flex/grid, external assets, or fixed positioning. It lacks viewport metadata, MSO shell, HTML width attributes, and real Outlook/Gmail proof.
- The 9,561-word linear message has zero links, TOC, details, task chips, compact summary, or Read full Paper escape.

Evidence includes three-viewport Chromium geometry/screenshots and inspection of email controller, wrapper, composer, walker, and tests. Targeted Mix tests could not start because dependencies are absent. Verify must choose stacked/labelled mobile tables, remove presentation roles from data tables, establish base typography, decide summary-plus-link delivery for long Papers, and test the exact 98KB artifact in Gmail, Outlook, Apple Mail, dark mode, and client clipping. No state mutation occurred.
