<!-- doc-tier: human | canonical-for: portabledoc-conformance | budget: 1100tok -->
# PortableDoc conformance

```
goldens/blocks/<type>.golden.json ──► runner renders `input` ──► normalise both ──► row
                                          (one per renderer)                        │
conformance/<renderer>.json ◄── { renderer, compare, pack_stamp, ran_at_sha, rows } ◄┘
```

| Renderer | Report | Runner | Compare | CI |
|---|---|---|---|---|
| Elixir reader | `elixir.json` | `api/lib/mix/tasks/barkpark.portable_doc.conformance.ex` | dom | Elixir gate (`conformance_test.exs`) |
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

## `dom`: the normalised shape

Both the golden's `expectedHtml` and the renderer's output go through the same
projection. JS: `conformance.mjs` `shapeOf` over any DOM (jsdom, happy-dom).
Elixir: `Conformance.shape/1` over LazyHTML. They agree on all 80 goldens.

- An element is `{tag, classes, attrs, style, children}`. `tag` is lower case.
  `classes` is a sorted set. `attrs` is every attribute, `data-*` included,
  except `class`, `style`, `href`, `src`, `srcset`, `poster`, `id`, and
  `width`/`height` on media tags (img, video, audio, iframe, source, embed,
  canvas, object). `style` is the inline style parsed to property → value.
  Attribute and style values have whitespace runs squashed.
- Text: adjacent text nodes merge, whitespace runs squash to one space, the ends
  trim, and empty text drops. Comments drop.
- Children compare in order. Any difference in tag, class set, attribute, style
  value, text or child count is a `diff` line.

What the runners unwrap before projecting:

- React: the `.bp-paper-surface` document wrapper.
- Editor canvas: a fleet atom (`[data-bp-fleet-id]`) is the canvas frame around
  host-painted reader HTML, so the runner paints its hole with
  `goldens/fragments.json[type]`, as the host does, and compares what it shows.
  It strips editor plumbing: `contenteditable`, `draggable`, `spellcheck`,
  `tabindex`, `data-bp-id`, `data-bp-type`, `data-test-id`, classes starting
  `ProseMirror` or `bp-canvas-`, and `.ProseMirror-trailingBreak`,
  `.ProseMirror-separator`, `.ProseMirror-gapcursor`,
  `.bp-paper-contextual-controls`. Everything else counts.

## `text`: renderers with no DOM

The TUI, its WASM blob and React Native draw no tags, so they compare words:
every word of the golden's `shape` text leaves, in order, must appear in the
render's text, in order. A word is a whitespace-separated run, lower-cased, with
non-letter, non-digit characters trimmed from both ends; a word of only
punctuation drops. The golden's text includes content the reader hides with CSS
(inactive tabs), so a renderer that omits it reads as `fail`.

## Not here yet

R1.6 part 2 adds the look-alike renderers in their own repos (Barkever
`Blocks.tsx`, barkpark-studio `PortableDocView.tsx`, next-starter
`portable-doc.tsx`). They import `conformance.mjs` from the synced pack.
