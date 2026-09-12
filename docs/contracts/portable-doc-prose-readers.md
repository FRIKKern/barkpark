<!-- doc-tier: agent | canonical-for: portable-doc-prose-readers | budget: 500tok -->
# Prose carrier precedence in terminal readers

Go's shared CLI/TUI and browser Wasm reader follow the HTML Paper composer's
existing heading/paragraph source contract. Rendering does not mutate source
fields or migrate saved documents.

| Block | Primary | Fallback when primary array is empty or absent |
|---|---|---|
| Heading | Nonempty `content` inline array | String, number or boolean `text`; maps/lists are blank |
| Paragraph | Nonempty `content` inline array | String `text` only; other scalars are blank |

A nonempty primary array wins even if its rendered words are empty. A stale
fallback must not resurrect cleared primary prose. Paragraph JSON-looking text
stays literal: list-specific decoding is not applied to paragraphs.

`internal/pdrender/blocks.go` owns these reads; `stringishAttr` supplies the
heading scalar boundary and the existing inline renderer preserves marks and
sanitizes control characters. `prose_carriers_test.go` checks source immutability,
fallback precedence and the color-stripping law across terminal widths.

HTML reference: `api/lib/barkpark/portable_doc/render/compose.ex` heading and
paragraph clauses. The Wasm entry `cmd/pdrender-wasm` uses the same Go registry.
