<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-18 | budget: 1400tok -->
# Restart Survey 18 — CCH29 CLI/API negative capability and evidence strength

Assignment `restart-survey-18` re-attested `cloud-console-hardening-wave-29-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial: exact machine identity and repeatability pass; human rendering loses content, lacks revision identity, mixes mutable Related data, and misclassifies transport failure**.

## Positive controls

Three machine reads were identical: revision `18768b0a14c2eead927181c4a0e37c18`, 252 unique blocks, 431,200 bytes, SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`. `paper view -o json` and `doc get paper -o json` shared canonical block-array SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`.

Five width-80 profile-none renders were identical: exit zero, 126,556 bytes, 1,440 lines, valid UTF-8, zero replacement characters, maximum 80 codepoints, zero over-width lines, SHA-256 `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`. Published, draft, and raw perspectives matched in this sample. ANSI16, ANSI256, and truecolor remained within 80 after stripping ANSI. Widths 7, 20, 79, 80, 81, and 200 respected their codepoint budgets.

## Negative controls and contradictions

Missing Paper across three perspectives returned 3/3 exit 4. Unicode and traversal-like missing IDs did not escape scope. Nine malformed arguments returned exit 2. Explicit width zero silently fell back to width 80. Widths one and two each overflowed once because the literal `Related` heading is seven columns.

A refused local TCP connection returned exit 4 and `not_found`, contradicting the canonical network/timeout exit-1 contract. Human and JSON Paper errors echo newline, tab, or escape bytes from hostile missing IDs; terminal-safe error rendering is contradicted. Paper JSON nests and clips the server error, losing structured hint and request ID that direct `doc get` preserves.

Human output contains neither its slug nor revision. All 35 legacy table headers were absent in rendered probes because the renderer recognizes `head`/`columns`, not top-level `header`. Eleven paragraph-wrapped list items in `w29D015` and `w29D022` lose content; eight fresh unique phrase probes rendered 0/8. Exact machine preservation therefore cannot proxy-pass the human reader.

## Mutable Related boundary

All five human samples included five Related entries. Machine JSON included none. Related is an independent mutable request and intentionally fails open on transport, non-2xx, malformed JSON, or empty data. Current human bytes therefore combine immutable Paper content with an unpinned appendix; stable sampling does not make the complete reader revision-deterministic.

Live 401/403, 429, 500, timeout, malformed/oversized/empty source responses; conditional reads; CJK, bidi, ZWJ, malformed successful UTF-8; and real TTY interaction were unvisited. No tests or mutations ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-18","unit":"cloud-console-hardening-wave-29-2026-08-03::cli_api","verdict":"partial","paper_revision":"18768b0a14c2eead927181c4a0e37c18","machine":{"runs":3,"identical":3,"bytes":431200,"blocks":252,"unique_ids":252,"sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15"},"render80":{"runs":5,"identical":5,"bytes":126556,"lines":1440,"max_codepoints":80,"over80":0,"sha256":"e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83","self_slug":0,"self_revision":0},"negative":{"missing_perspectives":"3/3_rc4","invalid_args":"9/9_rc2","transport_refused":"rc4_not_found","control_byte_echo":true,"width0":"fallback80","width1_2_overflow":"Related"},"semantic_loss":{"table_headers":"35/35 absent","nested_list_items":11,"fresh_unique_phrase_probes":"0/8"},"related":{"live_runs_present":"5/5","entries":5,"machine_json_present":false,"secondary_mutable_read":true,"fail_open":true},"tests_run":0}
```
