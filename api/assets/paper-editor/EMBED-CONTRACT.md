# `<bp-paper-editor>` and `<bp-paper-canvas>` — Embed Contract (v1.7.0)

The normative spec of the editor's host seam. `<bp-paper-editor>` and
`<bp-paper-canvas>` are framework-neutral custom elements: any host (the LiveView
hook, a React `useEffect`, plain JS) drives them through exactly the surfaces
below. This documents what `src/index.js` and `src/canvas/index.js` implement;
`src/contract.js` pins the version.

`BpPaperEditor.CONTRACT_VERSION === "1.7.0"` (also exported as `CONTRACT_VERSION`).

1.1.0 adds the `<bp-paper-canvas>` surface. The `<bp-paper-editor>` surface is
unchanged from 1.0.0. 1.2.0 adds the canvas's toolbar commands, `state()` and
`bp-selection-change`. 1.3.0 adds the canvas's `format-bubble` attribute and
`bp-canvas-link-request`. 1.4.0 adds the `mediaPicker` host callback. 1.5.0 adds the `editBlockObject` host callback. 1.6.0 adds the `insertInline` toolbar command. 1.7.0 adds the `wikilink` toolbar mark (a declared `internalLink`) and `state().wikilink`.

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
| `format-bubble` attribute | `"off"` hides the floating format bubble, for a host that draws its own toolbar (Toolbar commands). Observed: setting or clearing it after mount drops or brings back the bubble. With it off, Mod+K and the link card's Edit fire `bp-canvas-link-request` instead |
| `blocks` property | the run, an array of blocks (a non-array is read as `[]`). Before mount it is stashed; after mount it re-seeds the editor outside undo history, drops any in-flight batch and resets the diff baseline |
| `acknowledgedSaves` property | `true` (strictly) opts into the acknowledged save protocol below. Default `false` |

All eight properties (`blocks`, `acknowledgedSaves` and the six callbacks) may be
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
| `mediaPicker` | `({ kind: "insert" \| "replace", current: { src, alt } \| null }) => { src, alt?, width? } \| null` | an Image insert is the empty image block, and images offer no Select |
| `editBlockObject` | `({ type, title, inline, fields, value, error }) => value \| null` | declared objects are edited in the canvas's own popover |

The menus drop a result that arrives after a newer query or after close. A
`linkPreviewSource` that throws or rejects is ignored. For a `link`, `kind`/`href`
are set; for a `wikilink`, `kind`/`target`/`docId`/`alias` are. A returned `href`
becomes the address `bp-canvas-open-link` reports. `mediaUploader` gets one
`File` per image (`image/*` only); a result with no `src`/`url` (or a throw) marks
the image with the error message instead. `mediaPicker` is the host's own image
dialog (upload or library): an Image insert (slash menu, palette, `insertBlock`)
opens it for the new block, and each image's Select opens it for that image
(the canvas carries `data-media-picker` while one is set, which shows Select). Its
answer becomes the image's `src`, and `alt` / `width` when given; an insert and its
pick are one undo step. The `src` goes through the reader's URL allowlist (`safeUrl`:
http(s), mailto, tel, relative, `#`); one it refuses (`javascript:`, `data:`,
protocol-relative), a blank `src`, `null` or a throw leaves the image as it was.

`editBlockObject` is the host's own editor for an object the field declares (a
block under `blocks.of`, an inline object under `blocks.inline`): set, every insert
and edit of one asks it instead of opening the popover — the slash and palette
pick, Enter or a double-click on a block or chip, and a server refusal of a save.
It gets the kind (`type`, `title`, `inline`, its declared `fields` as declared) and
the current `value` (`{ type }` for a new one; a block's `id` and undeclared keys
included), plus `error` (`{ field, message }`, or `null`) when asked again. Only the
declared fields are taken from the answer (`null`, `undefined` or `""` removes
one); `type`, `id` and undeclared keys stay as stored. A required field left
empty asks again with `{ field, message: "Required" }`, its `value` what the host
answered. `null` or a throw inserts
or changes nothing. The canvas still owns where the object lands and the undo step.

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
| `bp-server-insert` | a `terminal`, `stage`, `image` or `equation` pick, only when the editor or an ancestor carries `data-server-insert` (the host inserts it); without it they insert in the canvas | `{ type, after_id }` |
| `bp-canvas-selection` | the local selection changed, at most once per animation frame | `{ anchor: Point, head: Point }`, or `null` when blurred or none (see Shared carets) |
| `bp-selection-change` | the toolbar state changed, at most once per animation frame | `state()` (see Toolbar commands) |
| `bp-canvas-link-request` | with `format-bubble="off"`: Mod+K on a selection, or Edit on the link card. Cancelable; the host opens its own link input and sets the link with `toggleMark("link", { href })` | `{ href }`, the selection's current link or `null` |

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

### Toolbar commands

For a host that draws its own toolbar (a field's chrome). Each command acts on
the current selection (the one on screen: `run`, `can` and `state` first read a DOM
selection change the browser has not yet reported, so a press right after
Shift+Arrow covers the whole selection) and returns `true` when it applied; unmounted or read-only
it returns `false` and does nothing. Each runs the transaction the canvas's own
surfaces run (the format bubble, the block menu's Turn into, the palette's
Insert), so a press is one undo step and the same ops on the wire. Commands
less than 500 ms apart group into one undo step, as typing does. Such a host usually sets
`format-bubble="off"` (Inbound) and answers `bp-canvas-link-request` with its own link input.

| Method | Effect |
|---|---|
| `toggleMark(mark, { href }?)` | `mark`: `strong`, `em`, `code`, `underline`, `strike`, `highlight`, `link`, `wikilink`. `wikilink` takes `{ docId, target? }`: a link to that document over the selection (`docId` must be a document id — letters, digits, `.`, `_`, `-`, `:` — or the command is `false`; the server refuses anything else in a field's write path) (`target` defaults to the id; the canvas's own picks put the document's title there), and without a `docId` it clears the document link in place. A field admits it when it declares `link`'s sibling `internalLink` (Sanity's link to a document), which portable-doc stores as this `wikilink`. Resolution reads only the rendering document's dataset and workspace, so a `docId` from elsewhere renders as an unresolved link. `link` with an `href` sets the link over the selection's link range; without one it clears the link there. Only the reader's allowlist links (`http`, `https`, `mailto`, `tel`, a relative or in-document address, `#`): anything else (`javascript:`, `data:`, a protocol-relative `//`) returns `false`, `can()` is `false`, and the format bubble's link row refuses it the same way |
| `setBlockStyle(style)` | `normal`, `h1`–`h6`, `blockquote`. A quote keeps the block's id and text; in a field canvas it is the quote kind the field admits (its pullquote when `blockquote` maps there), as `> ` makes |
| `toggleList(kind)` | `bullet` or `number`. Off a list: makes one. In a list of the other kind: converts it, keeping the list's id. In a list of that kind: lifts the item out |
| `insertBlock(type, { level }?)` | any type the canvas's slash menu offers here (narrowed to the field's vocabulary). Inserts after the caret's block, an empty paragraph is replaced; a declared object block opens its fields first, a type the host builds on the server emits `bp-server-insert` |
| `insertInline(type)` | a declared inline object (the field's `blocks.inline`), at the caret, as the slash pick does: its field editor opens first (the popover, or the host's `editBlockObject`) and its answer puts the object in; a cancel inserts nothing. `true` when the editor opened. Only inside text the field writes in (not a code block) |
| `run(command, args?)` | the same, by name: `toggleMark` `{ mark, href? }`, `setBlockStyle` `{ style }`, `toggleList` `{ kind }`, `insertBlock` `{ type, attrs? }`, `insertInline` `{ type }`. An unknown command is `false` |
| `can(command, args?)` | whether `run(command, args)` would apply now, without applying it. `false` for what the field's vocabulary forbids (its veto would drop the edit) |
| `state()` | the active state, below |

`state()` is `{ marks, blockStyle, list, link, wikilink, selection }`:

- `marks`: the active marks, by the names above.
- `blockStyle`: the caret's textblock (`normal`, `h1`–`h6`, `blockquote`), or `null` in another block.
- `list`: `bullet` or `number` when the caret is in such a list, else `null`.
- `link`: `{ href }` when the selection is in a link, else `null`.
- `wikilink`: `{ target, docId }` when the selection is in a document link, else `null`.
- `selection`: `{ empty, inBlockType }`; `inBlockType` is the portable-doc type of the top-level block, or `null`.

Before mount it is `{ marks: [], blockStyle: null, list: null, link: null,
wikilink: null, selection: { empty: true, inBlockType: null } }`.

`bp-selection-change` (bubbles, composed) fires when that state changes (a
selection move, a stored mark, a block turned into a heading), at most once per
animation frame. Its `detail` equals `state()`.

### Shared carets

`Point` is `{ blockId, path?, offset }`. `blockId` is the innermost block with a
server id (the id ops use). `path` is present only below it, one `name[i]` per
level: `items[i]` (list item), `rows[i]` then `cells[i]` (table, head row
included), `steps[i]` / `tabs[i]`, `children[i]` otherwise; a list item's own
text adds no segment. `offset` counts UTF-16 units of that node's text, an
inline atom or hard break counting as one.

| Method | Effect | Returns |
|---|---|---|
| `setRemoteSelections(list)` | replace the remote set: `[{ id, name, color, anchor: Point, head: Point }]`. Each draws a caret bar with a `name` label in `color`, plus a translucent range when `anchor` ≠ `head`. `[]` clears; set before mount, it waits for the editor | nothing |

Remote selections are decorations: no ops, no history entry, and the local
caret never moves. They map through local typing and `applyServerBlocks`; an
end whose block was replaced is found again by its Point, and an entry with an
end whose block or path is gone is dropped silently. `color` is plain CSS color
syntax (anything else is grey); `name` is text. Classes: `.bp-remote-caret`,
`.bp-remote-caret__label`, `.bp-remote-selection`, colored by
`--bp-remote-color`.

A host relays both halves through editor presence: post the event's `detail`
as `selection` on `POST …/presence/:dataset/focus`, and hand the other
sessions' entries to `setRemoteSelections` (`docs/api/presence.md`).

### Recipe: an HTTP host

A host outside Phoenix (barkpark-studio, any SPA) saves the canvas over HTTP with
the events and methods above. It adds no surface, so the contract version is
unchanged. The canvas emits ops in the server's DocPatchOp shape (`{ op:
"patch-block", id, patch }` …), and two routes take them as they are:

| Route | Body | Success |
|---|---|---|
| `POST <scope>/v1/data/doc/:ds/:type/:id/ops` | `{ ops, ifRev }` | `{ result: { results, rev } }` |
| `POST <scope>/v1/data/doc/:ds/:type/:id/fields/:field/ops` | `{ ops, ifRev }` | `{ result: { field, blocks, rev } }` |

Both need a write token and `ifRev` (the document's `_rev`). Both apply the batch
whole or not at all. A stale `ifRev` answers `412 precondition_failed` with
`error.details.actual`, the current rev. The server compares `ifRev` under a
per-document lock held until the batch commits, so of two batches fenced on the
same rev one lands and the other gets that 412, never a 422. Read the starting `blocks` and `_rev`
with `GET <scope>/v1/data/doc/:ds/:type/:id?perspective=raw`; a document's blocks
are `result.blocks`, a field's are `result[field]`. Seed `canvas.blocks` from
that read and nothing else: a non-paper document's blocks are projected from its
fields (ids such as `synth-body-p-3`), and an op naming any other id answers
`422 invalid_op`.

The host turns on `acknowledgedSaves`, so one batch is in flight at a time and
edits made meanwhile wait. The answer's `rev` becomes the next `ifRev`. On a 412
the batch is still in flight, so the host resends it as is, fenced on
`details.actual`. Block ops are id-keyed, so the author's blocks land on the
other writer's state, and everything else that writer did is kept.

An HTTP answer is not an echo, and the canvas waits for one: a batch
acknowledged without an echo stays on its awaiting list, and later
`applyServerBlocks` snapshots queue behind it. So after each save, while the
batch is still in flight, the host reads the document and hands its blocks back
as the canvas's own echo, correlated by request id. That closes the save and
brings in any other writer's blocks without touching the author's edit. Then it
acknowledges. If that read fails the save still stands: `result.rev` is the
fence. Any other refusal discards the batch. The edit stays on screen and goes
out with the next batch.

<!-- http-host:begin -->
```js
function connectCanvasOverHttp(canvas, { opsUrl, readUrl, readBlocks, rev, headers = {}, onError = () => {} }) {
  let ifRev = rev;
  let requests = 0;
  canvas.acknowledgedSaves = true;
  const send = (url, init = {}) =>
    fetch(url, { credentials: "same-origin", ...init, headers: { "content-type": "application/json", ...headers } });
  const post = (ops) => send(opsUrl, { method: "POST", body: JSON.stringify({ ops, ifRev }) });
  const read = async () => {
    const res = await send(readUrl).catch(() => null);
    return res && res.ok ? (await res.json()).result : null;
  };

  const onOps = async (event) => {
    const { ops, seq } = event.detail;
    const requestId = `http-${++requests}`;
    canvas.identifyOpsRequest(seq, requestId);
    try {
      let res = await post(ops);
      for (let tries = 0; res.status === 412 && tries < 3; tries++) {
        ifRev = (await res.json()).error.details.actual; // another writer moved it: fence on their rev
        res = await post(ops); // still in flight, so resend the same batch
      }
      if (!res.ok) throw new Error(`ops refused: ${res.status}`);
      ifRev = (await res.json()).result.rev;
    } catch (error) {
      canvas.discardInflightOps(seq); // the edit stays on screen and goes out with the next batch
      onError(error);
      return;
    }
    // The saved document is the canvas's own echo. Read it before acknowledging,
    // so no newer edit can race the read.
    const doc = await read();
    if (doc) {
      ifRev = doc._rev;
      canvas.applyServerBlocks(readBlocks(doc), { mode: "own", requestId });
    }
    canvas.acknowledgeOps(seq, true);
  };
  canvas.addEventListener("bp-canvas-ops", onOps);
  return () => canvas.removeEventListener("bp-canvas-ops", onOps);
}
```
<!-- http-host:end -->

`src/__canvas_http_host.test.mjs` runs this block against the real canvas.

## Invariants

`convert.js` is pure and frozen; the patch-block op shape is stable; one TipTap
`Editor` per element; events are additive (a host may ignore any it doesn't use).
