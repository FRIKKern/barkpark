<!-- doc-tier: human | canonical-for: portabledoc-conformance | budget: 1600tok -->
# PortableDoc conformance

```
goldens/blocks/<type>.golden.json ──► runner renders `input` ──► normalise both ──► row
                                          (one per renderer)                        │
conformance/<renderer>.json ◄── { renderer, compare, pack_stamp, ran_at_sha, rows } ◄┘
```

| Renderer | Report | Runner | Compare | CI |
|---|---|---|---|---|
| Elixir reader (reference) | `elixir.json` | `api/lib/mix/tasks/barkpark.portable_doc.conformance.ex` | dom | Elixir gate (`conformance_test.exs`) |
| Editor canvas (read = edit) | `editor-canvas.json` | `api/assets/paper-editor/src/__conformance.mjs` | dom | paper-editor |
| `@barkpark/react` | `react.json` | `js/packages/react/tests/conformance.test.tsx` | dom | js-tests |
| Go pdrender (TUI) | `pdrender.json` | `internal/pdrender/conformance_test.go` | text | go-tests |
| pdrender WASM blob | `pdrender-wasm.json` | `cmd/pdrender-wasm/conformance.mjs` | text | pdrender-wasm |
| Mobile (React Native) | `mobile.json` | `apps/mobile/__tests__/conformance.test.tsx` | text | mobile |

## Run

Every runner checks by default: it renders the pack and fails if any row, the
renderer, the compare mode or `pack_stamp` differs from the committed report.

| Env | Effect |
|---|---|
| `CONFORMANCE_WRITE=1` | write `conformance/<renderer>.json` instead of checking it |
| `CONFORMANCE_STRICT=1` | also fail on any row that is not `pass` |

Red rows are fine: a report measures drift, it does not fix it. A runner fails
only when it could not run honestly: no pack, a pack with zero cases, a stale
report, or strict mode.

## The report

- `pack_stamp`: sha256 of `goldens/stamp.json`. The Elixir gate fails when any
  report's stamp is not the pack's, so a pack change reruns every runner.
- `ran_at_sha`: `git rev-parse HEAD` when the runner wrote the report; the commit
  that carries the report is its child.
- `rows`: one per `blocks/*.golden.json`, in file order, never fewer.
  `missing` means the renderer has no renderer for the type (it would fall back
  to its unknown-block degrade). `fail` carries up to 12 `diff` lines.
  `unchecked` (text compare only) means the golden has no words, so a text
  compare cannot tell a right render from an empty one. It is never a pass.
- `via: "host-paint"` (canvas only): the canvas did not render this type; it
  let the host paint the reader HTML into the fleet hole. A pass there proves the
  frame, not a canvas renderer.
- `reference: true` (Elixir only): the goldens are this renderer's output
  (`gen_pd_parity`, `render_block(input, %{style: :article})`), so 80/80 is by
  construction. The row checks the normaliser and the pack, not the reader.

## `dom`: the normalised shape

Both the golden's `expectedHtml` and the renderer's output go through the same
projection. JS: `conformance.mjs` `shapeOf` over any DOM (jsdom, happy-dom).
Elixir: `Conformance.shape/1` over LazyHTML. They agree on all 80 goldens.
One parser gap: happy-dom (the React runner) keeps a newline right after
`<pre>` that the HTML parser drops; no golden starts a `pre` with one.

- An element is `{tag, classes, attrs, style, children}`. `tag` is lower case.
  `classes` is a sorted set. `attrs` is every other attribute, URLs, ids and
  `data-*` included: every value in the pack is fixed, so none is skipped.
  `style` is the inline style parsed to property → value. Attribute and style
  values have whitespace runs squashed.
- Text: adjacent text nodes merge and comments drop. Whitespace runs squash to
  one space; only the first and last text of an element's children trim, so the
  space between inline siblings counts (`a<b>b</b>c` ≠ `a <b>b</b> c`). Empty
  text drops. Inside `pre` and `textarea` text is kept exactly as written.
- Children compare in order. Any difference in tag, class set, attribute, style
  value, text or child count is a `diff` line.

What the runners unwrap before projecting:

- React: the `.bp-paper-surface` document wrapper. Rows render with the opt-in
  `fieldBlocks` and `embedBlocks()`, as a host that wants them would.
- Editor canvas: a fleet atom (`[data-bp-fleet-id]`) is a frame with a hole
  (`[data-bp-fleet-body]`). The runner paints it as the host does: it fires the
  cancelable `bp-fleet-paint` event with `{html: fragments.json[type],
  sourceBlock}`. If the canvas cancels it, the canvas has mounted its own inline
  editor there, and that is what is compared. If not, the runner sets the HTML
  and marks the row `via: "host-paint"`. The frame is then unwrapped.
- The canvas strips only plumbing that changes neither what is shown nor what
  is announced: `contenteditable`, `draggable`, `spellcheck`, `tabindex`,
  `data-bp-id`, `data-bp-type`, `data-test-id`, classes starting `ProseMirror`
  or `bp-canvas-`, and `.ProseMirror-trailingBreak`, `.ProseMirror-separator`,
  `.ProseMirror-gapcursor`, `.bp-paper-contextual-controls`. Inline editors'
  `role="textbox"`, `aria-label` and extra wrappers count: a screen reader
  announces them and the reader has none, so read ≠ edit there.

## `text`: renderers with no DOM

The TUI, its WASM blob and React Native draw no tags, so they compare words:
every word of the golden's `shape` text leaves, in order, must appear in the
render's text, in order. A word is a whitespace-separated run, lower-cased, with
non-letter, non-digit characters trimmed from both ends; a word of only
punctuation drops. The golden's text includes content the reader hides with CSS
(inactive tabs), so a renderer that omits it reads as `fail`. A golden with no
words (divider, image, video) reads `unchecked`.

A `text` pass proves the words are there in order. It does not check structure,
links or URLs, styling, heading level, accessibility roles, or extra and
repeated words.

## Not here yet

R1.6 part 2 adds the look-alike renderers in their own repos (Barkever
`Blocks.tsx`, barkpark-studio `PortableDocView.tsx`, next-starter
`portable-doc.tsx`). They import `conformance.mjs` from the synced pack.
