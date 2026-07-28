# Re-derivation recipe — segment-wise vs full-prefix render equality (v2-segment-vs-prefix-property)

Wave: `barkpark-tasks-mobile-wave-2026-07-28`. Baseline: `origin/main` @ `c69cc0b1ee0b9ea546daf4bfc56e36d86f94dbe9`.

Question: is `Enum.flat_map(segments, &FromMarkdown.blocks/1)` structurally equal to
`FromMarkdown.blocks(full_prefix)`, where segments are split at the chat_live
stable boundaries (`api/lib/barkpark_web/live/studio/chat_live.ex:5905` +
`balanced_fences?/1` :5921)?

Answer: **NO — 11 of 23 corpus docs diverge**, including a realistic assistant
reply. Naive append-only (k=0) shows a midstream pop on 12 of 17 docs.
Holding back the LAST block of each prefix render (k=1) rescues 15 of 17; only
**link reference definitions** survive as an unbounded-distance popper.
A LOCAL O(window) construction equals global k=1 on 16 of 17 (the exception is
an HTML-block artifact that emits a phantom empty paragraph).
Affordability: the window never closes inside a long LOOSE LIST, so the
quadratic survives on exactly that shape (2907ms -> 2451ms, 1.19x) while the
paragraph shape wins 51x (1574ms -> 31ms).

## Re-run

Probes are ephemeral scratch scripts; recreate them from this recipe.

```
cd /Volumes/SATECHI/github/barkpark/api
CC=/usr/bin/clang MIX_ENV=dev mix run --no-start <probe.exs>
```

Probe skeleton (all four probes share this boundary replication):

```elixir
alias Barkpark.PortableDoc.FromMarkdown
balanced? = fn p -> rem(length(:binary.matches(p, "```")), 2) == 0 end
boundaries = fn text ->
  :binary.matches(text, "\n\n")
  |> Enum.map(fn {pos, len} -> pos + len end)
  |> Enum.filter(fn b -> balanced?.(binary_part(text, 0, b)) end)
  |> Kernel.++([byte_size(text)]) |> Enum.uniq()
end
```

- probe 1 — for each doc: compare `flat_map(segments, blocks)` vs `blocks(full)`.
- probe 2/3 — simulate an append-only committer holding back the last `k` blocks
  of each prefix render; flag any already-committed block that later CHANGES
  (`MIDSTREAM-POP`) and any settle mismatch (`SETTLE-POP`). Run k=0 and k=1.
- probe 4 — LOCAL construction: parse only `text[off..b]`, commit all but the
  last block, slide `off` to the last balanced split whose remainder parses to
  exactly that last block. Compare against global k=1.
- probe 5 — `:timer.tc` the full-prefix-per-boundary loop vs the local-window
  loop over a 200-item loose ordered list and 200 separate paragraphs.

## Divergent classes (probe 1)

link-ref-def, link-ref-def-before, loose-ordered-list, loose-unordered-list,
ordered-start-5, tilde-fence, indented-code, nested-list, list-then-para-lazy,
html-block, realistic-reply.

Clean: setext-heading, setext-h2, lazy-continuation, tight-ordered-list,
gfm-table, consecutive-blockquotes, blockquote-multi-para, fenced-code,
hr-vs-setext, footnote, headings-and-prose, mermaid-fence.

## Cross-check against the chat-TUI charter

`.claude/workflows/bp-chat-tui-charter.md` D76 restricts mid-stream rich output
to ATX headings, flat lists, generic code fences and markup-free paragraphs.
Every one of those is in my CLEAN set; every divergent class is outside it. So
D76's whitelist is the empirically correct shape, and the claim that a full
converter on the wire DISSOLVES the whitelist is refuted — a full converter
carries MORE cross-block state, not less.
