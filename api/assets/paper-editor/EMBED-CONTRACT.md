# `<bp-paper-editor>` and `<bp-paper-canvas>` — Embed Contract (v1.1.0)

The normative spec of the editor's host seam. `<bp-paper-editor>` and
`<bp-paper-canvas>` are framework-neutral custom elements: any host (the LiveView
hook, a React `useEffect`, plain JS) drives them through exactly the surfaces
below. This documents what `src/index.js` and `src/canvas/index.js` implement;
`src/contract.js` pins the version.

`BpPaperEditor.CONTRACT_VERSION === "1.1.0"` (also exported as `CONTRACT_VERSION`).

1.1.0 adds the `<bp-paper-canvas>` surface. The `<bp-paper-editor>` surface is
unchanged from 1.0.0.

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
| `bp-slash-insert` | slash-menu pick | `{ type, afterId, fieldName? }` |
| `bp-slash-insert` | `> [!type]` callout shorthand | `{ type: "callout", afterId, tone, collapsible: true, collapsed }` |
| `bp-error` | bad `data-block` JSON | `{ error, raw }` |

`fieldName` is present only when the slash-menu item is field-bound; callout inserts carry `tone` (normalised tone string), `collapsible` (always `true`), and `collapsed` (boolean, `true` when the modifier is `-`).

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

## `<bp-paper-canvas>`

One custom element, `bp-paper-canvas`, registered by the same bundle. It edits a
**run** of portable-doc blocks (a whole paper, or a slice of one) in one TipTap
instance. Barkdown and Studio mount it.

```html
<bp-paper-canvas editable="true"></bp-paper-canvas>
<script>
  const canvas = document.querySelector("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = paper.blocks;
</script>
```

### Inbound (host → canvas)

| Channel | Shape |
|---|---|
| `editable` attribute | default editable; only the literal string `"false"` mounts read-only. Observed: a later change calls `setEditable`. A run that failed to mount stays read-only whatever it says |
| `blocks` property | the run, an array of blocks (a non-array is read as `[]`). Before mount it is stashed; after mount it re-seeds the editor outside undo history, drops any in-flight batch and resets the diff baseline |
| `acknowledgedSaves` property | `true` (strictly) opts into the acknowledged save protocol below. Default `false` |

All six properties (`blocks`, `acknowledgedSaves` and the four callbacks) may be
set before the element upgrades; `connectedCallback` reclaims them through the setters.

### Host callbacks

Optional properties. Each may return its value or a Promise of it; unset (or
`null`) means the feature stays off.

| Property | Signature | Unset |
|---|---|---|
| `wikilinkSource` | `(query) => [{ title, id, type }]` | the `[[` menu never opens |
| `tagSource` | `(query) => [name, ...]` (strings) | the `#` menu never opens |
| `linkPreviewSource` | `({ kind, href, target, docId, alias }) => { title?, excerpt?, href? } \| null` | the hover card shows the address only |
| `mediaUploader` | `(file) => url \| { src?, url?, alt? }` | a pasted or dropped image shows `no media uploader is connected` |

The menus drop a result that arrives after a newer query or after close. A
`linkPreviewSource` that throws or rejects is ignored. For a `link`, `kind`/`href`
are set; for a `wikilink`, `kind`/`target`/`docId`/`alias` are. A returned `href`
becomes the address `bp-canvas-open-link` reports. `mediaUploader` gets one
`File` per image (`image/*` only); a result with no `src`/`url` (or a throw) marks
the image with the error message instead.

### Outbound (canvas → host)

All events are `bubbles: true, composed: true`. Detail shapes:

| Event | When | `detail` |
|---|---|---|
| `bp-ready` | once, after a successful mount (not on mount failure) | `{ blockCount }` |
| `bp-canvas-ops` | on debounced edit (300ms; held while an IME composes), or a flush/resend | `{ ops, seq?, conflictBlocks? }` |
| `bp-noop` | an emit whose edits diff to zero ops | none |
| `bp-canvas-open-link` | the hover card's Open, **cancelable** | `{ kind: "link"\|"wikilink", href, target, docId, alias }` (each `string \| null`) |
| `bp-canvas-mount-failed` | the run could not be painted | `{ stage: "create"\|"seed", message, blockIds }` |
| `bp-canvas-node-failed` | a picker field (`field-image`, `field-reference`) could not be built | `{ blockId \| null, type, message }` |
| `bp-save-master` | block menu "Save as master" (Studio masters carrier only) | `{ block_id }` |
| `bp-master-insert` | a Masters pick from the slash menu | `{ master_id, after_id, mode?: "linked" }` |
| `bp-server-insert` | a `terminal` or `stage` pick (the host inserts it) | `{ type, after_id }` |

`ops` is a non-empty array of: `patch-block { id, patch }`, `replace-block { id,
block }`, `insert-after { afterId, block }`, `append-block { block }`,
`remove-block { id }`, `move-block { id, after }` (`after` is `null` for the
head). `seq` is present only with `acknowledgedSaves`. `conflictBlocks` is present
when the batch overlaps a server snapshot the canvas deferred (see
`applyServerBlocks`). `after_id` is the nearest block the server already holds,
or `null`.

`bp-canvas-open-link`: if no listener calls `preventDefault()` and `kind` is
`link`, the canvas opens `href` in a new window (`noopener,noreferrer`). A
wikilink has no default.

`bp-canvas-mount-failed`: the editor is hidden, the run is painted read-only in a
`.bp-canvas-mount-failed` fallback, the element gets `data-mount-failed="true"`,
and it stays read-only. `blockIds` are the ids of the run it could not open.

`bp-canvas-node-failed` is dispatched from inside the canvas and reaches it by
bubbling; that one field is painted read-only and the rest of the run edits.

### Acknowledged saves

With `acknowledgedSaves = true`, one batch is in flight at a time. Each
`bp-canvas-ops` carries `seq` (a per-element counter starting at 1). Edits made
while a batch is in flight stay in the editor and go out after it settles. The
three methods taking `seq` return `false` and do nothing when `seq` is not the
in-flight batch.

| Method | Effect | Returns |
|---|---|---|
| `acknowledgeOps(seq, saved)` | `saved === true`: advance the baseline to the batch's snapshot and emit any queued edits. Anything else: keep the batch in flight for a byte-identical retry | `true` only when `saved === true` was applied |
| `discardInflightOps(seq)` | drop the batch without advancing the baseline; the next diff carries the refused change. Queued edits emit now | `true` when dropped |
| `resendPendingOps()` | nothing in flight: re-diff the live document against the saved baseline and emit. Never resends discarded ops verbatim | `true` when a batch was emitted |
| `identifyOpsRequest(seq, requestId, previousRequestId = null)` | bind the host's request id to the in-flight batch, for matching its echo. Rebinding to a different id requires `previousRequestId` to name the current one | `true` when bound |

Without `acknowledgedSaves` the canvas emits fire-and-forget batches and relies
on `applyServerBlocks` echoes to advance its baseline.

### Sync methods

| Method | Effect | Returns |
|---|---|---|
| `applyServerBlocks(blocks, echoMeta?)` | apply confirmed server blocks. Deferred while the author is focused or composing; recognised as the canvas's own echo when it matches the in-flight or acknowledged snapshot. `echoMeta`: `{ mode?: "own"\|"own-stale", requestId? }` | nothing |
| `applyServerBlocksIfIdle(blocks)` | apply now only if nothing is focused, composing, in source mode or pending. Throws `TypeError` on a non-array when it would apply | `true` when applied |
| `resolveConflictWithServerBlocks(blocks)` | the user's "use latest": drop pending and in-flight state and take `blocks` | nothing |
| `flushPendingChanges()` | commit node-view inputs and any debounced edit (or leave source mode) now | `true` when it emitted a batch |
| `hasPendingChanges()` | debounced, in-flight, queued, unsaved source text or a pending note | boolean |
| `recoverySnapshot()` | the live document for a reconnect halt | `{ mode: "rich"\|"markdown", blocks?, raw_source?, raw_editor_document?, serialization_error? }` |
| `focusBlock(id)` | place the caret in the top-level block `id`; an id not yet in the run is retried on the next external apply within 5s | `true` when placed |
| `focusFirstBodyBlock()` | caret into the first unlocked block (editable only) | `true` when placed |
| `toggleSourceMode()` | switch between rich text and Markdown source (editable only; refused inside a Figure) | nothing |

### Find and replace

The host draws the bar; the canvas finds and highlights. `state` is `{ query,
count, index, caseSensitive }` (`index` is `-1` with no active match). Before
mount `findSet`/`findState` return `{ query: "", count: 0, index: -1 }` and
`findNext`/`findPrev` return `{ count: 0, index: -1 }`.

| Method | Returns |
|---|---|
| `findSet(query, { caseSensitive = false }?)` | `state`; the match nearest the caret becomes active and is selected |
| `findNext()` / `findPrev()` | `state`, active match moved by one (wraps) |
| `findState()` | `state` |
| `findClear()` | nothing |
| `replaceCurrent(text)` | `state` after replacing the active match (read-only: unchanged `state`) |
| `replaceAll(text)` | `{ replaced, ...state }`, one transaction (read-only: `replaced: 0`) |

## Invariants

`convert.js` is pure and frozen; the patch-block op shape is stable; one TipTap
`Editor` per element; events are additive (a host may ignore any it doesn't use).
