<!-- doc-tier: human | canonical-for: paper-editor-package | budget: 1800tok -->
# @barkpark/paper-editor

The Barkpark paper editor as a prebuilt bundle. Loading it registers two custom elements that work in any page or framework. `<bp-paper-canvas>` edits a whole paper in one document. `<bp-paper-editor>` edits one PortableDoc block. Barkpark Studio and the `/papers` reader load the same bytes from `api/priv/static/assets`.

[EMBED-CONTRACT.md](EMBED-CONTRACT.md) is the normative spec for `<bp-paper-editor>`. This README summarizes it. When they disagree, the contract wins.

## Install

```sh
npm install @barkpark/paper-editor
```

The package has no runtime dependencies. TipTap, ProseMirror, highlight.js and lowlight are bundled into `dist/bp-paper-editor.bundle.js`.

## Load it

With tags, serve the files from `node_modules/@barkpark/paper-editor/dist/` and link them.

```html
<link id="bp-paper-editor-styles" rel="stylesheet" href="/vendor/bp-paper-editor.css" />
<script src="/vendor/bp-paper-editor.bundle.js" defer></script>
```

With a bundler, import the script for its side effect and the stylesheet as a file.

```js
import "@barkpark/paper-editor";
import "@barkpark/paper-editor/style.css";
```

A bundled stylesheet has no `id`, so also set `window.BP_PAPER_EDITOR_NO_INJECT = true` before the first element mounts. The next section explains why.

| Export | File | Needed |
|---|---|---|
| `.` or `./bundle` | `dist/bp-paper-editor.bundle.js` | Yes. An IIFE that defines both elements. It has no module exports. |
| `./style.css` | `dist/bp-paper-editor.css` | Yes. Editor and paper-surface rules plus default tokens. |
| `./shell.css` | `dist/bp-paper-editor-shell.css` | For the slash menu, command palette and format bubble skins, and Studio's block chrome. |
| `./mermaid` | `dist/bp-paper-mermaid.js` | For `diagram` blocks. Defines `window.BarkparkPaperMermaid`. It renders with `window.mermaid`, which your page loads. |
| `./contract` | `dist/contract.js` | Optional. An ES module with `CONTRACT_VERSION` and `DEBOUNCE_MS`. No DOM access. |

Types for both elements, their events and the window flag are in `index.d.ts`.

## Stop the bundle injecting its stylesheet

When the first element mounts, the bundle appends `<link id="bp-paper-editor-styles" rel="stylesheet" href="/assets/bp-paper-editor.css">` to the page. That path is where Barkpark serves the file. Your page has three options.

- Serve `bp-paper-editor.css` at `/assets/bp-paper-editor.css`.
- Load the stylesheet yourself with `id="bp-paper-editor-styles"` on the `<link>`. The bundle sees the id and adds nothing.
- Set the flag before the first element mounts. The bundle reads it at mount time. Barkdown and Studio do this.

```html
<script>window.BP_PAPER_EDITOR_NO_INJECT = true;</script>
```

## One block with `<bp-paper-editor>`

Give the block as the `data-block` attribute (a JSON string) or the `block` property (an object). Setting `block` on a mounted element replaces its content.

```html
<bp-paper-editor data-block='{"id":"b1","type":"paragraph","content":[]}'></bp-paper-editor>
```

The element reports back through these events. Every event bubbles and is composed.

| Event | When | `detail` |
|---|---|---|
| `bp-ready` | Once, after mount | `{ blockId, blockType, contractVersion }` |
| `bp-op` | 300 ms after the last edit | `{ op: "patch-block", id, patch }` |
| `bp-slash-insert` | A slash-menu pick or a `> [!type]` callout | `{ type, afterId, fieldName?, tone?, collapsible?, collapsed? }` |
| `bp-error` | `data-block` is not valid JSON | `{ error, raw }` |

## A whole paper with `<bp-paper-canvas>`

This is the element Barkdown and Studio use. EMBED-CONTRACT.md specifies its surface from contract 1.1.0 on.

```js
const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute("editable", "true");
canvas.acknowledgedSaves = true;
canvas.blocks = paper.blocks;
canvas.addEventListener("bp-canvas-ops", async (e) => {
  const { ops, seq } = e.detail;
  const saved = await save(ops);
  canvas.acknowledgeOps(seq, saved);
});
host.appendChild(canvas);
```

The host sets the `editable` attribute and the `blocks` property. It can also set four async callbacks. `wikilinkSource(query)` and `tagSource(query)` fill the wikilink and tag menus, which stay closed without them. `linkPreviewSource(info)` fills the link hover card, which shows only the address without it. `mediaUploader(file)` uploads a pasted or dropped image and returns its URL. Without it the image shows an upload error.

`bp-canvas-ops` carries a batch of edits. With `acknowledgedSaves = true` one batch is in flight at a time, and the host answers with `acknowledgeOps(seq, saved)` or `discardInflightOps(seq)`. `bp-canvas-open-link` is cancelable. `bp-canvas-mount-failed` and `bp-canvas-node-failed` report content the canvas could only show read-only.

A host that syncs with a server uses `applyServerBlocks`, `resolveConflictWithServerBlocks`, `flushPendingChanges`, `hasPendingChanges` and `resendPendingOps`. Find and replace uses `findSet`, `findNext`, `findPrev`, `replaceCurrent` and `replaceAll`.

## Theming

`bp-paper-editor.css` declares every token on `:root, :host` at its light value, so the editor renders styled with no host theme. Set `data-theme="dark"` on the `<html>` element for the dark values. Override these tokens on any ancestor to restyle the editor.

- Colours: `--paper-bg`, `--paper-bg-deep`, `--paper-ink`, `--paper-ink-soft`, `--paper-ink-faint`, `--paper-accent`, `--paper-accent-soft`, `--paper-reading-accent`, `--paper-rule`, `--paper-chrome-bg`, `--paper-chrome-border`, `--paper-edit-hover`.
- Fonts: `--paper-font-serif`, `--paper-font-mono`.
- Reading scale: the `--tok-reading-*` and `--bp-*` sizes, line heights and spacing.
- Callout tones: `--bp-tone-{info,success,warning,danger,neutral}-{bg,fg}`.

## Versions

The package major version equals the major of `CONTRACT_VERSION`. A breaking change to the embed contract raises both. Minor and patch releases ship editor changes that keep the contract. `package.json` records the contract version under `barkpark.contractVersion`, and `npm run pack:check` fails when the two disagree.

## Licence

Apache-2.0. The bundle includes 45 third-party packages. Their licence texts are in `THIRD-PARTY-NOTICES.txt`, and `third-party-notices.json` lists each one with the SHA-256 of every notice file. `npm run notices` regenerates both from the locked install.

## Release

Run these from this directory after `npm ci`.

```sh
npm test
npm run pack:check   # builds, checks notices, packs, and inspects the tarball
npm publish          # needs publish rights to the @barkpark scope
```

`prepack` runs `npm run build`, checks the notices, and copies the built files into `dist/`.
