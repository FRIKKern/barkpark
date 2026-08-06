<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-13 | budget: 1400tok -->
# Restart Survey 13 — TUI80 provenance and current pin

Assignment `restart-survey-13` re-attested `cloud-console-hardening-wave-28-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current pin reproduced; CLI deterministic in sample; exact interactive identity partial**.

## Direct answer

The Paper is pinned at revision `49c1534d9fb76d0d9adc7b97f25ec471`. Three current-worktree CLI runs and one installed-binary run produced identical 80-column output: 2,357 lines, 191,475 bytes, maximum display width 80, zero overflow, SHA-256 `386de871838459e09144db4d96afeea339c69617fdceb6fa40048dcc435b48b3`.

“TUI80” names three distinct outputs. Plain `bp paper view --width 80` uses an 80-cell body plus a dynamic Related appendix. Standalone interactive Paper TUI uses the same renderer at 80 cells when its pane is 80, but exact fullscreen bytes were not captured. An 80-cell `bp tasks` Paper frame reserves gutter/metadata and caps the Paper measure at 72 cells. Shared renderer does not mean byte-identical product output.

## Reproduction chain

- Source: 237 blocks; canonical blocks SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`; ordered-ID SHA-256 `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`.
- CLI captures: 4/4 exit zero and byte-identical; three current binary, one installed `bp` at commit `f59aaf717`.
- Direct renderer body: 2,337 lines, 190,243 bytes, max width 80, zero overflow, SHA-256 `1c9c12e3c6263dd7824110ca7741875e509feccf8ecd7b6c28c7693118186bec`.
- Direct body exactly equals the first 2,337 CLI lines. The final 20 lines are live Related content.

The CLI fetches the narrow Paper source/revision, decodes blocks, renders through `pdrender`, then independently appends Related. `RenderDoc` bounds each final display line to configured width using ANSI-aware cell measurement. Standalone TUI uses `min(paneWidth,100)` and the same renderer. Task-board frames cap measure at 72, retain source revision in cache identity, and add title, revision metadata, and a driven-task rail.

## Ruling and risk

The Paper body is strongly reproducible from revision plus block hashes. The complete one-shot CLI is only conditionally reproducible because Related is a secondary live query outside the Paper revision. Static code proves standalone TUI renderer/measure selection, not exact live fullscreen identity. Width containment proves no line exceeds 80 cells; it does not prove useful density, semantic completeness, or composition.

Calling an 80-cell task-board frame “TUI80” is misleading because the body is 72 cells. Standalone TUI body omits visible slug/revision identity while the task-board frame supplies it. Interactive standalone and task-board captures, semantic review of all blocks, changing Related identity, and task lifecycle/duplicate status were not visited.

## Cycle payload

```json
{"assignment_id":"restart-survey-13","unit":"cloud-console-hardening-wave-28-2026-08-03::tui80","source":{"rev":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237,"blocks_sha256":"a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09","ids_sha256":"af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff"},"cli":{"samples":4,"current_worktree":3,"installed":1,"exit_0":4,"lines":2357,"bytes":191475,"max_width":80,"overflow":0,"sha256":"386de871838459e09144db4d96afeea339c69617fdceb6fa40048dcc435b48b3"},"renderer_body":{"lines":2337,"bytes":190243,"max_width":80,"overflow":0,"sha256":"1c9c12e3c6263dd7824110ca7741875e509feccf8ecd7b6c28c7693118186bec","equals_cli_prefix":true},"surfaces":{"cli":"80-column body plus dynamic Related appendix","standalone_tui":"80 at paneWidth=80; exact interactive bytes unobserved","taskboard":"72-column paper measure at frameWidth=80 plus metadata and task rail"},"verdict":"current pin reproduced; CLI deterministic in sample; exact interactive identity partial"}
```
