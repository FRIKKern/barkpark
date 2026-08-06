<!-- doc-tier: cold | canonical-for: legendary-paper-verify-17-evidence | budget: 1600tok -->
# Verify 17 — canonical table headers in the Go CLI

Verdict: `proven` that the Go CLI ignores canonical top-level `header`; `conditional` that accepting it restores every full label. Schema fallback restores all 113 header cells at width 200, while existing table sizing truncates some labels at narrower widths.

| Width | Full normalized labels visible |
| ---: | ---: |
| 200 | 113/113 |
| 120 | 111/113 |
| 80 | 109/113 |
| 40 | 71/113 |

- The four pinned Papers contain 46 tables. Thirty-five use top-level `header`, totaling 113 cells and 83 unique labels; eleven are genuinely headerless.
- For every table at widths 40/80/120/200, production output is byte-identical after deleting `header`, proving all 113 cells are ignored.
- Normalizing `header` into `head` changes exactly those 35 tables; the 11 headerless tables remain unchanged.
- Remaining layout truncations include `Surface` → `SURFA` and `Gate re-run on the final state` → `GATE RE-RUN ON THE FINAL`.
- Decode preserves top-level attributes, but `tableRenderer` reads `head`, columns, or row-header shapes and never `header`. The Elixir HTML renderer already implements nonempty `head`, otherwise `header`, precedence.
- Existing Go tests cover `head`, columns, and row headers, but not canonical top-level `header`.

An isolated 32-render probe covered widths 20/40/80/120 and all four profiles. It proves nonempty `head` wins when both keys exist, empty `head` can fall back to normalized `header`, order remains `Zulu, Alpha, Mu`, profiles preserve ANSI-stripped content, and no line exceeds its requested width. `go test -count=1 ./internal/pdrender` passes.

Fixing the schema fallback resolves header data loss. Guaranteeing full narrow-width labels is a separate table-layout policy problem and must be scored in Experiment rather than hidden inside the compatibility repair. No repository, Paper, task, or server mutation occurred at clean commit `36422119ca11`.
