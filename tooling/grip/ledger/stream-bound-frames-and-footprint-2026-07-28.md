# Re-derivation recipe — streaming bound: frame count, footprint, frame-size ceiling

Wave: barkpark-tasks-mobile-wave-2026-07-28 · verifier lane v10-bound-and-frames
Anchor: `origin/main` a1583aed597a383ccfafe4de33514d4d55c70f32

## What was measured

1. Boundary advances (= `event: stable` frame count) for a realistic 1 MiB
   assistant reply vs the adversarial `"a\n\n"` shape, at five delta sizes.
2. Server footprint of `state.text` + `stable_html`, and the client-side sum of
   per-segment block JSON, at 4/16/64/256/1024 KiB turns.
3. Whether the cap's terminal signal can ride as a field on the last `stable`
   frame (it cannot: the worst shapes emit zero stable frames).
4. Whether ONE segment at the current 1 MiB cap exceeds the Go SSE scanner's
   `1<<20` line ceiling (`internal/apiclient/listen.go:156`). It does.

## Recipe

```sh
# corpus: real repo markdown, tiled to 1 MiB
cd /Volumes/SATECHI/github/barkpark
cat docs/*.md docs/*/*.md > "$SCRATCH/corpus.md"     # 583_218 B on this anchor

# probes live beside the corpus; boundary logic is copied VERBATIM from
# chat_live.ex stable_boundary/1 + balanced_fences?/1 + advance_streaming/2
cd api
CC=/usr/bin/clang MIX_ENV=dev mix run --no-start "$SCRATCH/probe_bound.exs"     # (a) advances, (b) footprint
CC=/usr/bin/clang MIX_ENV=dev mix run --no-start "$SCRATCH/probe_frames.exs"    # per-frame size distribution
CC=/usr/bin/clang MIX_ENV=dev mix run --no-start "$SCRATCH/probe_terminal.exs"  # terminal signal + Go line ceiling
```

Probe sources (scratchpad, not committed):
`probe_bound.exs`, `probe_frames.exs`, `probe_terminal.exs`.
`probe_bound.exs` self-checks its fast advance formula against the literal
per-delta simulation on 8 KiB samples (must print MATCH on all six rows) — the
literal simulation is O(n²) and does not finish at 1 MiB, which is itself the
quadratic this wave removes.

## Headline numbers (re-derive with the above)

| axis | realistic (repo md) | realistic (LLM shape) | adversarial `a\n\n` |
|---|---|---|---|
| advances @ 1 MiB, 40 B deltas | 3 742 | 9 397 | 26 215 |
| advances @ 1 MiB, 1 B deltas | 4 160 | 10 441 | 349 525 |
| advances per KiB | 4.06 | 10.2 | 341 |

Footprint of a 1 MiB turn: `text` 1 048 576 B + `stable_html` 1 185 870 B +
on-heap 2 648 B = **2 354 954 B resident (2.25× the cap)**; client segment JSON
sum **2 203 964 B (2.1×)**. On-heap is 2 648 B — `max_heap_size` cannot see any
of it (refc binaries are off-heap).

Frame sizes, realistic 1 MiB: p50 308 B, p95 1 822 B, max 10 382 B, sum
2 203 964 B. One closed fence = one segment: at the current 1 MiB cap a single
segment encodes to 1 077 745 B (plain code) / 1 189 046 B (quote-heavy) —
both over Go's 1 MiB line ceiling.
