<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-30 | budget: 1400tok -->
# Restart Survey 30 — CCH29 TUI80 negative capability and evidence strength

Assignment `restart-survey-30` re-attested `cloud-console-hardening-wave-29-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial, high confidence: bounded deterministic rendering is proven; semantic completeness, intrinsic revision identity, error taxonomy, target discoverability, and interactive target behavior are contradicted or unproven**.

## Direct answer

Three fresh width-80 renders were byte-identical: 126,556 bytes, 1,440 lines, maximum 80 display cells, zero overflow, SHA-256 `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`, and zero visible slug, revision, or block IDs. Direct rendering stayed cell-bounded at widths 1/2/5/10/19/20/40/60/80/100, but tiny widths were unusable: width 1 produced 80,346 lines and width 19 was taller than width 10. The actual TUI rejects frames below 16×5.

Semantic completeness is false. Eleven paragraph-wrapped list items become bare bullets, losing 2,268 characters and 406 words (`0/11` exact items). Eleven tables carry 35 cells under legacy `header`; the renderer recognizes `head`, so no authored header band is structural. Source contains 313 marks; 35 marked header cells disappear. Another 139 empty paragraphs are omitted. At width 80, 704 table-border lines consume 49% of the stream despite missing header semantics.

Malformed legacy structures are silently degraded. Non-object blocks and per-block decode failures are skipped; unknown inline leaves render nothing. Unknown block types alone receive a visible fallback box. A whole-tree TUI decode failure clears Paper blocks and falls back to generic fields without a Paper-specific error.

## Negative controls

Missing Paper returned rc4; invalid perspective and negative width rc2; incomplete release pins rc2; a complete tuple with malformed revision rc4; a complete but wrong candidate/revision rc4/404; refused TCP rc4. The CLI maps every source-read failure into the `not_found` exit family, contradicting useful error taxonomy even though the release client strongly validates the full tuple. No valid six-pin immutable release tuple was available, so revision identity is after-the-fact correlation only.

Two fresh 80×24 TUI launches loaded 39 schemas. Exact-slug search returned five unrelated hits; title search returned a capped `20+`; the target was not distinguishable or opened. One unrelated Paper opened and showed the scroll footer. Thus exact-target viewport offsets, resizing, focus retention, and delivered key behavior remain unproven. Static code provides arrows/j/k, Ctrl-D/U, PageUp/PageDown, Space, g/G, back, help, quit, and selector, but the footer omits Space/PageUp/PageDown. Paper mode consumes unmatched keys before generic `H`, so history is unreachable. No mouse option, scrollbar, position, percentage, outline, or section jump exists.

The TUI cannot prove visible bytes' immutable revision, release candidate provenance, table-header associations, block anchors, decode failure versus empty Paper, tone without color, task/backlink reachability, authorization scope, or mouse/wheel/assistive behavior. Fresh tests were not run in this lens. Scratch captures were moved to Trash; repository and Barkpark state were not mutated.

## Cycle payload

```json
{"assignment_id":"restart-survey-30","unit":"cloud-console-hardening-wave-29-2026-08-03::tui80","verdict":"partial_high_confidence","paper":{"revision":"18768b0a14c2eead927181c4a0e37c18","blocks":252,"source_sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15"},"render80":{"runs":"3/3 identical","bytes":126556,"lines":1440,"max_cells":80,"overflow":0,"sha256":"e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83","visible_identity":false},"semantic_loss":{"blank_list_items":11,"lost_chars":2268,"lost_words":406,"tables":11,"header_cells":35,"rendered_header_bands":0,"empty_paragraphs":139,"marks":313},"negative_controls":{"missing":"rc4","invalid_args":"rc2","malformed_complete_pin":"rc4_not_found_family","wrong_candidate":"rc4_404","transport_refused":"rc4_not_found_family"},"interactive":{"sessions":2,"terminal":"80x24","schemas":39,"target_opened":false,"slug_search":"5 unrelated","title_search":"20+ capped","mouse":false,"history":false,"scroll_progress":false},"tests_run":0,"mutations":0}
```
