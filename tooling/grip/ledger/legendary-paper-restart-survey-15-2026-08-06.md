<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-15 | budget: 1400tok -->
# Restart Survey 15 — TUI80 negative capability and evidence strength

Assignment `restart-survey-15` re-attested `cloud-console-hardening-wave-28-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial: exact CLI rendering and errors proven; interactive behavior unexercised; history, headers, help, and extreme width contradicted**.

## Direct answer

Five fresh plain width-80 renders were identical: revision `49c1534d9fb76d0d9adc7b97f25ec471`, 237 blocks, 191,474 captured bytes, 2,357 lines, SHA-256 `4bb8c9275aa7ad733f87dbe8296b4b070fe4ac770558d6f15f5887d4f3fe2637`, valid UTF-8, maximum 80 codepoints, and zero lines above 80. Two ANSI16/dark runs were also identical and stripped to max 80. No real interactive TTY was exercised.

## Positive and negative controls

Width matrix: 20, 79, 80, and 81 each respected its bound. Width 1 failed: literal unwrapped appendix heading `Related` produced one seven-column line. Width 0 silently fell back to default 80 rather than rejecting explicit zero.

Missing Papers under published, drafts, and raw returned 3/3 exit 4 with valid UTF-8 missing behavior. A Unicode missing slug was echoed intact; a traversal-like slug returned exit 4 without escape. Negative/nonnumeric width, invalid perspective, and invalid profile returned 4/4 exit 2. Machine JSON returned exact ID, revision, and 237 blocks. Rendered text contains neither slug nor revision.

Core Unicode survives: checkmark, em dash, curly quotes, and zero replacement characters. These controls prove deterministic stream behavior in the sample, not viewport state, resizing, or input handling.

## Contradictions

- All authored table headers preserved: contradicted. Five unique source header samples were absent; prior census reports 0/57 because source uses top-level `header` while renderer recognizes `head`, `columns`, or header-marked first row.
- Durable rendered identity: contradicted; slug/revision occurrences are zero.
- Paper revision history navigation: contradicted; the Paper input branch consumes unmatched keys before generic `H` handling.
- Accepted widths are strict upper bounds: contradicted at width 1 by `Related`.
- Help documents paging: contradicted; Space/PageUp/PageDown work statically but are omitted from Paper help, and no numeric position/progress is shown.
- Explicit zero width is invalid: contradicted; it becomes fallback 80.
- Mouse/wheel capability: not found in the TUI command package.

## Blocked and residual scope

No live interactive session proved focus ownership, key delivery, viewport offsets, resize, wheel, scroll persistence, or help-modal behavior. No mutable fixture tested CJK width, combining sequences, ZWJ emoji, bidi, malformed UTF-8, or forced decoder errors. No tests were run. Related is a fail-open live secondary read; failure was not forced.

The capture-byte/hash difference versus Survey 13 reflects capture boundary/newline normalization; both independently agree on 2,357 lines, width 80, zero overflow, and deterministic repeated output.

## Cycle payload

```json
{"assignment_id":"restart-survey-15","unit":"cloud-console-hardening-wave-28-2026-08-03::tui80","verdict":"partial","paper_revision":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237,"width80":{"runs":5,"identical":5,"rc":0,"bytes":191474,"lines":2357,"sha256":"4bb8c9275aa7ad733f87dbe8296b4b070fe4ac770558d6f15f5887d4f3fe2637","max_codepoints":80,"over80":0,"utf8_valid":true,"replacement_chars":0},"ansi16":{"runs":2,"identical":2,"visible_max":80,"visible_over80":0},"missing_perspectives":"3/3 rc4","invalid_controls":"4/4 rc2","width0":"accepted_as_fallback80","width1":{"max":7,"overflow_lines":1,"offender":"Related"},"rendered_identity":{"slug_occurrences":0,"revision_occurrences":0},"header_samples":"0/5 rendered; prior census 0/57","paper_history":false,"interactive_tty_runs":0,"tests_run":0}
```
