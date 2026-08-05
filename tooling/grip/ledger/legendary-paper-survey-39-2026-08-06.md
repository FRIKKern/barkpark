<!-- doc-tier: cold | canonical-for: legendary-paper-survey-39-evidence | budget: 1200tok -->
# Survey 39 — Cloud Console wave 28 / TUI80 semantics

Verdict: `partial`. Core prose and lists survive, but table semantics disappear, several hierarchy/severity cues depend only on color, and long task IDs become unreliable copy/search targets.

- Authority: `cloud-console-hardening-wave-28-2026-08-03@49c1534d9fb76d0d9adc7b97f25ec471`; all 237 source IDs are unique and ordered.
- The 18 tables retain 155 body rows but lose all 57 header cells. Existing tests cover `head` and row-wrapper vocabulary, not the Paper's top-level `header` form.
- Four callouts use tone `warn`; the theme recognizes `warning`, so color TUI maps these to default informational styling. Source also contains five explicit `info`, three `warning`, and one default-info callout. Under NoColor, all 13 tones collapse because severity is expressed only through color; bars and body text remain.
- H2 ×24 and H3 ×18 differ only by foreground color and therefore collapse to the same NoColor hierarchy. H1 retains uppercase text and a rule.
- The inline renderer recognizes all 67 string marks (26 strong, 41 code) in color mode, but both mark classes are styling-only and collapse under NoColor.
- All seven lists and 35 items render with literal bullets. The source contains 31 task-like IDs; at width 80, 17 split at hyphens and no longer remain contiguous copy/search tokens, while 14 remain contiguous.
- The main TUI Paper branch returns the rendered body with a 20-cell title breadcrumb but no visible Paper ID or revision. The taskboard Paper frame can show title, slug, and revision; its full 77-cell identity line fits at width 80.

Targeted pdrender and taskboard tests pass. The `cmd/barkpark` package could not be built locally because CGO rejected option `-E`, so no complete-suite claim is made. Verify should repair and test `header` alias handling, normalize or recognize `warn`, add non-color hierarchy/severity cues, and protect machine-like identifiers from destructive wrapping where practical. No state mutation occurred.
