<!-- doc-tier: cold | canonical-for: legendary-paper-survey-40-evidence | budget: 1200tok -->
# Survey 40 — Cloud Console wave 28 / email structure

Verdict: `partial`. The deployed email projection preserves every substantive block and correctly normalizes legacy table headers, but drops all legacy string-form inline marks and normalizes four warning callouts to info.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; source SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- The deployed `/papers/<slug>/email` response is HTTP 200, 170,149 bytes, SHA-256 `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`, with a doctype and inline email skin but no `<style>` element.
- Source-to-live normalized text partitioning proves all 134 substantive blocks survive in exact source order with no missing, extra, or reordered text. The remaining 103 source blocks are empty paragraphs and correctly emit no markup.
- Exact output structure is 43 headings (H1 ×1, H2 ×24, H3 ×18), 53 paragraphs, 18 tables, 18 header/body groups, 173 rows, 57 `<th>`, 466 `<td>`, seven unordered lists/35 items, and 13 callouts.
- Unlike TUI and Studio, email correctly accepts the source's top-level `header` vocabulary and emits all 18 header bands / 57 cells.
- Sixteen paragraphs carry 67 legacy string marks spanning 1,725 characters: 26 strong and 41 code. Email's Elixir inline composer recognizes map-form marks only, so output contains zero `<strong>` and zero `<code>` while preserving the words.
- Four `tone:"warn"` callouts and one absent tone normalize to info; three `warning` callouts retain warning treatment.

Verify should add pinned-corpus block-order proof, string-mark compatibility tests, and `warn` alias coverage while retaining empty-paragraph suppression and legacy table-header support. No state mutation occurred.
