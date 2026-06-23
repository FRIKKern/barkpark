# `<bp-paper-editor>` — Embed Contract (v1.0.0)

The normative spec of the editor's host seam. `<bp-paper-editor>` is a
framework-neutral custom element: any host (the LiveView hook, a React
`useEffect`, plain JS) drives it through exactly the surfaces below. This
documents what `src/index.js` implements; `src/contract.js` pins the version.

`BpPaperEditor.CONTRACT_VERSION === "1.0.0"` (also exported as `CONTRACT_VERSION`).

## The element

One custom element, `bp-paper-editor`, registered by the bundle. It edits **one**
portable-doc block (paragraph / heading / list) in its own TipTap instance. The
host mounts one element per block.

```html
<script src="/assets/bp-paper-editor.bundle.js" defer></script>
<link rel="stylesheet" href="/assets/bp-paper-editor.css" />  <!-- or rely on self-inject -->
<bp-paper-editor data-block='{"id":"b1","type":"paragraph","content":[...]}'></bp-paper-editor>
```

## Inbound (host → editor)

Provide the block one of two equivalent ways:

| Channel | Shape |
|---|---|
| `data-block` attribute | a JSON string of the portable-doc block |
| `el.block` JS property | the block object (`el.block = {...}`) — also re-contents a mounted editor |

A malformed `data-block` JSON does **not** block the editor — it falls back to an
empty paragraph and emits `bp-error` (below).

## Outbound (editor → host)

All events are `bubbles: true, composed: true` (cross Shadow DOM). Detail shapes:

| Event | When | `detail` |
|---|---|---|
| `bp-ready` | once, at end of mount | `{ blockId, blockType, contractVersion }` |
| `bp-op` | on debounced edit (300ms) | `{ op: "patch-block", id, patch }` |
| `bp-slash-insert` | slash-menu / `> [!type]` insert | `{ type, afterId, fieldName? }` |
| `bp-error` | bad `data-block` JSON | `{ error, raw }` |

`bp-op` `patch` by block type (the frozen patch-block shape — `convert.js`):
- paragraph → `{ content: [inline...] }`
- heading → `{ text, level: 1|2|3 }`
- list → `{ ordered, items: [[inline...], ...] }`

## Styling

The bundle **self-injects** `bp-paper-editor.css` once (id-guarded `<link>`), so a
bare embedder needs only the script tag. Hosts that already ship the rules (Studio
inlines `.bp-paper-surface` CSS) set `window.BP_PAPER_EDITOR_NO_INJECT = true`
before the bundle to opt out and avoid doubled rules. The stylesheet ships a
`:root, :host` fallback for all `--paper-*` tokens (light default; dark via
`[data-theme="dark"]`), so it renders styled with no host theme.

## Invariants

`convert.js` is pure and frozen; the patch-block op shape is stable; one TipTap
`Editor` per element; events are additive (a host may ignore any it doesn't use).
