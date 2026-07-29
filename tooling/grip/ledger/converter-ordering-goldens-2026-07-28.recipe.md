# Recipe — converter ordering: which goldens move when FromMarkdown gains `language` / `start`

Derived 2026-07-28 against origin/main `ab396959c` (worktree clean at that SHA).
Rows: `bl-frommarkdown-fence-language`, `mob-rt-bl-list-start`.

## 1. Earmark's own behaviour (decides whether `start` can move any golden)

```
cd api && CC=clang mix run --no-start - <<'EOF'
{:ok, a, _} = EarmarkParser.as_ast("5. five\n6. six\n"); IO.inspect(a)
{:ok, b, _} = EarmarkParser.as_ast("1. one\n2. two\n"); IO.inspect(b)
{:ok, c, _} = EarmarkParser.as_ast("```elixir\nx = 1\n```\n"); IO.inspect(c)
{:ok, d, _} = EarmarkParser.as_ast("```\nx = 1\n```\n"); IO.inspect(d)
EOF
```

Expect: `ol` carries `[{"start","5"}]` only when the list does NOT start at 1;
`code` carries `[{"class","elixir"}]` only when the fence is tagged.

## 2. Mutation probe — patched converter vs the committed golden

Script (scratchpad, never committed): read
`api/lib/barkpark/portable_doc/from_markdown.ex`, rename the module to
`Probe.FMLang`, replace the fence `case` catch-all with
`lang -> [Map.put(code_block(source), "language", lang)]` (keep `"" ->` on the
old arm) and the list clause with a `Map.put(base, "start", ...)` when the `ol`
carries a `start` attr; `Code.compile_string/2`; then rebuild
`Mix.Tasks.Barkpark.Chat.GenGoldenTranscript.build/0`'s variant map with
`Probe.FMLang.blocks/1` and `diff` the pretty JSON against
`api/test/support/fixtures/chat_golden_transcript.json`.

Expect exactly ONE added line (`"language": "elixir"`, +32 bytes,
8124 → 8156) in variant `rich_markdown`, and NO change to `projection`.

## 3. What forces the regen

`api/test/barkpark/chat_golden_transcript_parity_test.exs:54` asserts
`decode!(@api_path) == GenGoldenTranscript.build()` and `:74` asserts
`FromMarkdown.blocks(v["markdown"]) == v["blocks"]` — the converter change
fails the suite until `mix barkpark.chat.gen_golden_transcript` is re-run
(2 byte-equal mirrors: api fixture + `internal/pdrender/testdata/`).

## 4. Live-frame coupling (the crown)

`api/lib/barkpark/studio_chat/stream_segments.ex:200` injects
`&FromMarkdown.blocks/1` as the stream converter and the frame type (`:171`)
carries `blocks: [map()]` verbatim, so a language-tagged fence in a live turn
changes the bytes of an `event: stable` frame. Independently,
`.github/workflows/deploy.yml` fires on `api/**` — merging the converter
redeploys the content instance and severs any in-flight capture.
