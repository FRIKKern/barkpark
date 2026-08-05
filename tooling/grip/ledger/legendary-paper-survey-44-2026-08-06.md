<!-- doc-tier: cold | canonical-for: legendary-paper-survey-44-evidence | budget: 1200tok -->
# Survey 44 — Cloud Console wave 28 / CLI reader

Verdict: `partial`. The one-shot CLI stream is width-safe and complete, but loses all table headers, becomes enormous at narrow widths, and provides no pager, outline, progress, or section navigation.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; 237 blocks.
- Plain render line counts at widths 20/40/60/80/120 are 13,108 / 5,222 / 3,199 / 2,357 / 1,547. ANSI-aware width checks find zero overflow and exact requested maximum widths.
- Table lines dominate 79.65% / 73.86% / 70.06% / 67.44% / 62.83% of the Paper body across those widths. The renderer emits 133 single visual separators and no blank desert.
- Warm width-80 rendering has a three-run median of 1.45 seconds. Raw JSON has a median of 0.27 seconds and returns 558,569 bytes on one line.
- All 18 source tables lose their 57 top-level `header` cells because CLI shares the TUI renderer's `head`-only table vocabulary.
- `bp paper view` is a one-shot stream with no pager, progress, TOC, outline, section selector, or heading jump. The separate interactive TUI has scrolling keys; it is not the same reader surface.
- Related appends five Papers and zero tasks, capped at five, with no backlink markers.
- Missing-document JSON exits 4 with a structured envelope; incomplete release pins exit 2 clearly. `--width 0` silently falls back to 80, while width 1 is accepted and expands to 58,632 lines.
- The composite CycleFleet unit ID is not a stored task and correctly returns structured `not_found`.

Verify should add a `header` compatibility fixture, reject nonsensical widths, expose progress/outline/section navigation, teach external paging, and preserve the lossless stream as a composable default. No state mutation occurred.
