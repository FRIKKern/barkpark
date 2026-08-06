<!-- doc-tier: cold | canonical-for: legendary-paper-survey-57-evidence | budget: 1200tok -->
# Survey 57 — PDS wave 44 / email semantics

Verdict: `partial`. The exact deployed artifact preserves semantic headings, lists, source order, and header text, but hides all five real data tables from accessibility semantics and lacks language, landmark, callout labels, plain-text delivery, and revision binding.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; deployed HTML is 98,335 bytes, SHA `c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645`, HTTP 200 `text/html; charset=utf-8`; `xmllint --html --noout` passes.
- Exact DOM: 1 H1/24 H2/7 H3, ten UL/85 LI, five tables/five TBODY/three THEAD/12 TH/203 TD, four callouts, and 84 visible top-level children in source order. Body-text SHA `2e1ffea4b22612db81c6c07e45201c7159603d6228fcc6e3483a4ef53d07f737`; heading-sequence SHA `637717468482652b3e43fccca68a7be3643885ff3372440af8482edb5c6b401b`.
- All five tables contain genuine data, while layout uses divs. Nevertheless every table is hardcoded `role="presentation"`; zero tables retain a data-table role. Twelve headers have no `scope`/id and cells have no `headers`. Two tables are authored headerless.
- Four non-collapsible callouts are unlabeled roleless styled divs with no visible Info/Note carrier. Distinction is visual only.
- Standalone HTML has a correct escaped title, doctype, charset, and inline-only styling. It lacks `html[lang]`, main/article/landmark grouping, ARIA beyond the adverse table roles, element IDs, and revision metadata.
- Fixture has no images or links, so alt/link behavior is not exercised. Ordinary DOM order is exact; accessibility behavior inside presentational tables remains client-dependent.
- Repository search found no Paper sender producing multipart HTML plus `text_body`; the route is HTML-only and no actual Paper mail-delivery integration was found.
- HTML/headers contain neither `_rev`, slug, ETag, nor artifact digest, so bytes cannot independently prove the pinned revision.

Checked deployed bytes/headers, exact source, email controllers/finalizer, render/composition/walker, related tests, and existing notifier conventions. Mix tests could not start because dependencies are absent. Verify must remove presentation roles from data tables, add scoped headers, resolve headerless tables, label callouts, add language/article grouping, locate/build multipart delivery, stamp immutable provenance, and capture real Outlook/Gmail/Apple Mail plus AT evidence. No state mutation occurred.
