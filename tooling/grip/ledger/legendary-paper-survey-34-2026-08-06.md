<!-- doc-tier: cold | canonical-for: legendary-paper-survey-34-evidence | budget: 1200tok -->
# Survey 34 — Cloud Console wave 28 / Studio structure

Verdict: `partial`. Studio preserves all 237 block identities and order, but hides every legacy table header and legacy inline mark; editing affected paragraphs would permanently erase their styling.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; source SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- The production canvas projector produces 237 nodes in exact source-ID order: 43 headings, 156 paragraphs, 18 tables, 13 callouts, and seven bullet lists. Missing, duplicate, and reordered nodes are zero; untouched load emits zero operations.
- Forty blocks differ semantically inside Studio: 18 tables lose headers, 16 paragraphs lose marks, five lists normalize ordering metadata, and one callout gains default tone.
- All 18 tables store canonical `header`, while the canvas reads only `head`. Studio therefore hides 57 header cells but retains all table IDs and 155 body rows. A simulated body edit emits `head:[]`; current server fallback preserves the stored legacy header, but Studio remains blind to it.
- Sixteen paragraphs contain 67 legacy string-form marks covering 1,725 characters: 26 strong and 41 code. Studio retains text but displays no styling. Editing one emits plain replacement content and permanently removes its marks.
- All 103 empty paragraphs remain as contentless editable nodes, preserving identity but materially inflating the editor.
- Three lists lose `style:"bullet"`; five gain `ordered:false`. One untoned callout gains `info`; four `warn` callouts remain stored but paint as informational.
- Deployed editor JS/CSS match repository assets exactly: JS SHA-256 `1d58c19fdbff18c7b6ef4cf56eb00a54b90fbaed0b463a72deadfc754affe5a3`; CSS `d9801481125011a34eddd748768e7bdc6a124045e437e859974e90c037e0cb67`.

Authenticated production Studio geometry and caret/focus behavior remain login-gated and unvisited here. Verify should cover `header` alias support, legacy-mark conversion/write fencing, spacer compaction, and tone/list canonicalization. No state mutation occurred.
