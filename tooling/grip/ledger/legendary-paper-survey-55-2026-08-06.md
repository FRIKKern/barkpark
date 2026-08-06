<!-- doc-tier: cold | canonical-for: legendary-paper-survey-55-evidence | budget: 1200tok -->
# Survey 55 — PDS wave 44 / email structure

Verdict: `found`, with diagnostic and local-test gaps. The live email preserves every authored structural text leaf in order, all headings/lists/tables/callouts, and the legacy table headers; empty spacers compact away.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; canonical JSON SHA `4923e1b72da37c384eb5c7b80ba15a08c9998fde560db0095d349a27457f96d`; blocks SHA `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`.
- Live email artifact: 98,335 bytes, minified standalone document, deterministic SHA `c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645` across three successful requests.
- Exact accounting: 99 source blocks become 84 visible structures; 15 empty paragraphs intentionally emit nothing. Email contains 1 H1, 24 H2, seven H3, 33 paragraphs, ten UL/85 LI, five tables, three THEAD/12 TH, 54 body rows/203 TD, and four expanded callouts.
- A sequential scan found all 369 authored text leaves in source order with zero misses. The renderer maps blocks without reordering.
- Email correctly supports legacy top-level `header`: composition falls back from `head` to `header`, normalizes it to the table head, and emits `<thead>/<th>`. Blocks `b42`, `b66`, and `dbf8` retain 4+3+5 headers; headerless `b117`/`b133` stay body-only.
- All 99 IDs remain unique in source, but email emits no `id` or `data-block-id` markers, preventing block-level diagnostics and anchored deep links.
- Initial live probes included transient HTTP 500s and a capabilities timeout; an explicit later probe returned 12/12 HTTP 200 and all successful body hashes matched. Cause is unproven and treated as operational risk.

Targeted Mix tests could not start because isolated dependencies are absent; no pass is claimed. Checked exact live bytes, all source blocks, renderer composition/walker/controller, email goldens and endpoint tests. Verify must add a list-valued legacy-header fixture, rerun tests in a complete checkout, decide stable block markers, correlate transient request failures, and capture real-client visual proof. No state mutation occurred.
