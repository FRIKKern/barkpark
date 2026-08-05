<!-- doc-tier: cold | canonical-for: legendary-paper-survey-10-evidence | budget: 1100tok -->
# Survey 10 — wave 29 / Email structure

Verdict: `found`. Production email preserves non-empty top-level order, tables, headings, and callouts, but silently blanks two lists and strips block identity.

- Authority: exact revision `18768b0a14c2eead927181c4a0e37c18`; `/email` HTTP 200, 121,072 bytes, stable SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`.
- Source has 252 blocks and 113 non-empty blocks; email has exactly 113 direct content children in matching semantic tag order. Text matches 111/113 blocks.
- The 139 empty paragraph scaffolds emit no empty `<p>` and create no blank structural slabs.
- All 11 legacy-header tables survive with 11 theads, 35 th, 98 body rows, and 316 td. All four callouts survive expanded.
- `found`: `w29D015` and `w29D022` retain 11 `<li>` shells but lose 2,268 authored characters. Array-wrapped paragraph items bypass normalization and fall through unknown inline rendering (`compose.ex:332,1955`; `inline.ex:146`).
- `partial`: all 252 durable source block IDs are absent from email; order is position/text-proven but not identity-addressable.
- `not_found`: malformed source/output, duplicate IDs, missing table cells, missing callout bodies, visible empty paragraphs, or top-level reordering.

This proves production renderer bytes, not SMTP/provider or recipient-client behavior. Links, images, tasks, embeds, delivery, and external mail clients were unvisited. No mail or state mutation occurred.
