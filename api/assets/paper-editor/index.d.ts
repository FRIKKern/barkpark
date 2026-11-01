// Types for @barkpark/paper-editor.
//
// The bundle is an IIFE with no module exports. Loading it (a <script> tag or
// a side-effect `import "@barkpark/paper-editor"`) registers two custom
// elements on `customElements`. These declarations type those elements, their
// attributes, events, globals, public classes and theme tokens. EMBED-CONTRACT.md
// (v1.21.0) is the normative spec for both elements; these types follow
// src/index.js and src/canvas/index.js. src/__contract_truth.test.mjs fails when
// this file, EMBED-CONTRACT.md's surface index and the element classes disagree.

/** A PortableDoc block. The editor reads `id` and `type`; other keys depend on the type. */
export interface PortableDocBlock {
  id: string;
  type: string;
  [key: string]: unknown;
}

/** The frozen patch-block op (src/convert.js). */
export interface PatchBlockOp {
  op: "patch-block";
  id: string;
  patch: Record<string, unknown>;
}

/** One op in a canvas batch (src/canvas/run-convert.js runToOps). */
export type CanvasOp =
  | PatchBlockOp
  | { op: "replace-block"; id: string; block: PortableDocBlock }
  | { op: "insert-after"; afterId: string; block: PortableDocBlock }
  | { op: "append-block"; block: PortableDocBlock }
  | { op: "remove-block"; id: string }
  | { op: "move-block"; id: string; after: string | null };

/** A table structure change (`patch-table-structure`); row and column indexes start at 0. */
export type TableStructureAction =
  | "add-row"
  | "add-column"
  | "add-header"
  | "remove-header"
  | `${"remove" | "up" | "down"}-row:${number}`
  | `${"remove" | "left" | "right"}-column:${number}`;

/** The intent op of `data-editor-mode="card-body"`: the card body paragraph's inline content. */
export interface PatchCardBodyOp {
  op: "patch-card-body";
  id: string;
  content: unknown[];
}
/** The intent op of `data-editor-mode="table"` for typed cells. */
export interface PatchTableCellsOp {
  op: "patch-table-cells";
  id: string;
  shape: unknown;
  cells: Array<{ area: "head" | "body"; row: number; column: number; content: unknown[] }>;
}
/** The intent op of `data-editor-mode="table"` for a row, column or header change. */
export interface PatchTableStructureOp {
  op: "patch-table-structure";
  id: string;
  shape: unknown;
  action: TableStructureAction;
}

// ── <bp-paper-editor> events (EMBED-CONTRACT.md "Outbound") ────────────────

export interface BpReadyDetail {
  blockId: string;
  blockType: string;
  contractVersion: string;
}
export type BpOpDetail = PatchBlockOp | PatchCardBodyOp | PatchTableCellsOp | PatchTableStructureOp;
export interface BpSlashInsertDetail {
  type: string;
  afterId: string;
  fieldName?: string;
  tone?: string;
  collapsible?: true;
  collapsed?: boolean;
}
export interface BpErrorDetail {
  error: string;
  /** The bad `data-block` text. */
  raw?: string;
  /** Card-body and table modes: why the editor stopped taking edits; the draft stays. */
  code?: "card_body_source_unsupported" | "table_source_unsupported" | "table_draft_incompatible";
}
/** Card-body and table modes: a host listener may set `token`; `bp-noop` hands it back when the edit settles to nothing. */
export interface BpLocalChangeDetail {
  token: unknown;
}

export interface BpPaperEditorEventMap extends HTMLElementEventMap {
  "bp-ready": CustomEvent<BpReadyDetail>;
  "bp-op": CustomEvent<BpOpDetail>;
  "bp-slash-insert": CustomEvent<BpSlashInsertDetail>;
  "bp-error": CustomEvent<BpErrorDetail>;
  "bp-local-change": CustomEvent<BpLocalChangeDetail>;
  /** Card-body and table modes: the edit settled to no op; `token` is what the host set on `bp-local-change`. */
  "bp-noop": CustomEvent<{ token: unknown }>;
}

/** The attributes `<bp-paper-editor>` reads. */
export interface BpPaperEditorAttributes {
  /** A JSON string of the block. */
  "data-block"?: string;
  /** Only `"false"` mounts read-only. Observed. */
  editable?: string;
  /** Read at connect. Absent: `"block"`, one paragraph, heading or list sending `patch-block`. */
  "data-editor-mode"?: "block" | "card-body" | "table";
}

/** One PortableDoc block per element. Inbound: the `data-block` attribute or the `block` property. */
export interface BpPaperEditorElement extends HTMLElement {
  /** In table mode, the table projection the server sends. */
  block: PortableDocBlock;
  /** The `[[` menu, as on the canvas. */
  wikilinkSource: ((query: string) => MaybePromise<WikilinkSuggestion[]>) | null | undefined;
  /** The `#` menu, as on the canvas. */
  tagSource: ((query: string) => MaybePromise<string[]>) | null | undefined;
  /** Send the debounced op now; true when it sent one. */
  flushPendingChanges(): boolean;
  /** A debounced op, or a table structure change that has not settled. */
  hasPendingChanges(): boolean;
  /** The user's "use latest": drop the debounce and any draft, take `block`. False in table mode for another id. */
  resolveConflictWithServerBlock(block: PortableDocBlock): boolean;
  /** Table mode: the server's table projection, with the request it answers. */
  applyTableProjection(value: PortableDocBlock, metadata?: { requestId?: string | null; rev?: unknown }): boolean;
  /** Table mode: bind the host's request id to the structure op in flight. */
  trackTableMutation(op: PatchTableStructureOp, requestId: string): boolean;
  /** Table mode: the save result of that request. */
  tableMutationResult(op: PatchTableStructureOp, saved: boolean, result: { request_id?: string | null }): boolean;
  /** Table mode: settles true when a structure change lands, false when it is dropped; null when none is pending. */
  waitForTableSettlement(): Promise<boolean> | null;
  addEventListener<K extends keyof BpPaperEditorEventMap>(
    type: K,
    listener: (this: BpPaperEditorElement, ev: BpPaperEditorEventMap[K]) => unknown,
    options?: boolean | AddEventListenerOptions,
  ): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
  removeEventListener<K extends keyof BpPaperEditorEventMap>(
    type: K,
    listener: (this: BpPaperEditorElement, ev: BpPaperEditorEventMap[K]) => unknown,
    options?: boolean | EventListenerOptions,
  ): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

// ── <bp-paper-canvas> ──────────────────────────────────────────────────────

export interface BpCanvasReadyDetail {
  blockCount: number;
}
/** The statics both element classes carry: `customElements.get("bp-paper-canvas").EDITOR_VERSION`. */
export interface BpPaperBuildInfo {
  /** This contract's version, as EMBED-CONTRACT.md's title. */
  readonly CONTRACT_VERSION: string;
  /** Since 1.21.0: the npm package version (package.json `version`, today "1.0.0"); not bumped per contract release. */
  readonly EDITOR_VERSION: string;
  /** Since 1.21.0: 12 hex of the sha-256 over esbuild's version and the bundle's input files; null unbuilt. Build options are not hashed: `build` and `build:dev` give the same sha. */
  readonly BUILD_SHA: string | null;
}
export interface BpPaperEditorConstructor extends BpPaperBuildInfo {
  new (): BpPaperEditorElement;
  readonly prototype: BpPaperEditorElement;
}
export interface BpPaperCanvasConstructor extends BpPaperBuildInfo {
  new (): BpPaperCanvasElement;
  readonly prototype: BpPaperCanvasElement;
}

export interface BpCanvasOpsDetail {
  ops: CanvasOp[];
  /** Present when the host set `acknowledgedSaves = true`. Pass it back to acknowledgeOps. */
  seq?: number;
  /** Present when the batch overlaps a deferred server snapshot. */
  conflictBlocks?: PortableDocBlock[];
}
export interface BpCanvasOpenLinkDetail {
  kind: "link" | "wikilink";
  href: string | null;
  target: string | null;
  docId: string | null;
  alias: string | null;
}
/** 1.15.0: a click on a document link. */
export interface BpCanvasWikilinkClickDetail {
  docId: string | null;
  target: string | null;
  alias: string | null;
  metaKey: boolean;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
}
/** 1.15.0, liveRemote: a server block held against the author's unsaved typing; null when the server removed it. */
export interface BpCanvasRemoteHeldDetail {
  blockId: string;
  remote: PortableDocBlock | null;
}
export interface BpCanvasMountFailedDetail {
  stage: "create" | "seed";
  message: string;
  blockIds: string[];
}
export interface BpCanvasNodeFailedDetail {
  blockId: string | null;
  /** The field type that failed (field-image or field-reference). */
  type: string;
  message: string;
}
export interface BpSaveMasterDetail {
  block_id: string;
}
export interface BpMasterInsertDetail {
  master_id: string;
  after_id: string | null;
  mode?: "linked";
}
export interface BpServerInsertDetail {
  type: string;
  after_id: string | null;
}

export interface BpPaperCanvasEventMap extends HTMLElementEventMap {
  /** Once, after a successful mount. */
  "bp-ready": CustomEvent<BpCanvasReadyDetail>;
  /** A debounced batch of edits. */
  "bp-canvas-ops": CustomEvent<BpCanvasOpsDetail>;
  /** An emit whose edits diffed to zero ops. No detail. */
  "bp-noop": CustomEvent<null>;
  /** Cancelable. Call preventDefault() to handle the link yourself; otherwise a plain link opens in a new window. */
  "bp-canvas-open-link": CustomEvent<BpCanvasOpenLinkDetail>;
  "bp-canvas-mount-failed": CustomEvent<BpCanvasMountFailedDetail>;
  "bp-canvas-node-failed": CustomEvent<BpCanvasNodeFailedDetail>;
  "bp-save-master": CustomEvent<BpSaveMasterDetail>;
  "bp-master-insert": CustomEvent<BpMasterInsertDetail>;
  "bp-server-insert": CustomEvent<BpServerInsertDetail>;
  /** The local selection, one per animation frame when it changes; null when blurred or none. */
  "bp-canvas-selection": CustomEvent<CanvasSelection | null>;
  /** The toolbar state, one per animation frame when it changes; detail equals state(). */
  "bp-selection-change": CustomEvent<ToolbarState>;
  /** 1.10.0: the history's depths changed (a new step, an undo or redo, the history cleared). Fired at once. */
  "bp-canvas-history": CustomEvent<{ kind: "step" | "undo" | "redo" | "clear"; count: number; undo: number; redo: number }>;
  /** With format-bubble="off": Mod+K or the link card's Edit. Cancelable; detail.href is the current link or null. */
  "bp-canvas-link-request": CustomEvent<{ href: string | null }>;
  /** An edit moved or dropped a comment range; detail equals commentRanges(). One per animation frame. */
  "bp-canvas-comment-ranges": CustomEvent<LiveCommentRange[]>;
  /** A click inside a comment range; id is the innermost one. */
  "bp-canvas-comment-click": CustomEvent<{ id: string }>;
  /** 1.15.0: a click on a document link. Cancelable: preventDefault() also prevents the click's default. */
  "bp-canvas-wikilink-click": CustomEvent<BpCanvasWikilinkClickDetail>;
  /** 1.15.0, with liveRemote: a server block the canvas did not apply over unsaved typing. Once per block and version. */
  "bp-canvas-remote-held": CustomEvent<BpCanvasRemoteHeldDetail>;
}

/** Events a host or a host-supplied piece dispatches into the canvas. */
export interface BpPaperInboundEventMap {
  /** On a paint hole (`[data-bp-fleet-id] [data-bp-fleet-body]`), cancelable. A node that paints itself cancels it; otherwise the host sets the hole's HTML. */
  "bp-fleet-paint": CustomEvent<{ html: string; sourceBlock?: PortableDocBlock }>;
  /** From a host picker element (`bp-media-picker`, `bp-reference-picker`), bubbling: its new value. */
  "bp-change": CustomEvent<{ value: unknown }>;
}

/** The attributes `<bp-paper-canvas>` reads on itself. */
export interface BpPaperCanvasAttributes {
  /** Only `"false"` mounts read-only. Observed. */
  editable?: string;
  /** `"off"` hides the format bubble. Observed. */
  "format-bubble"?: "off";
  /** Present: images and declared object blocks are cards. */
  "block-cards"?: "";
  /** `"off"`: only `[[` opens the document menu. */
  "mention-trigger"?: "off";
  /** The type's Expectation, `{fieldName: max | null}`, as JSON. */
  "data-field-caps"?: string;
  /** A field's block declaration (`blocks`) as JSON: edits outside it are refused. */
  "data-vocabulary"?: string;
  /** A paper's constraint declarations as JSON: removes and moves that break them are refused. */
  "data-constraints"?: string;
  /** `"true"`: the block after this run is locked, so the run cannot grow at its end. */
  "data-locked-tail"?: "true";
  /** Picker scope: the dataset the pickers search. */
  "data-dataset"?: string;
  /** Picker scope: the token the media picker uploads with. */
  "data-token"?: string;
  /** Picker scope: the API path prefix the pickers fetch under. */
  "data-scope-prefix"?: string;
  /** `"false"`: pickers keep the current value and offer no browser. */
  "data-picker-browse"?: "false" | "true";
  /** The media picker's `data-strings`. */
  "data-media-strings"?: string;
  /** The reference picker's `data-strings`. */
  "data-reference-strings"?: string;
}

/** Attributes the canvas reads on an ancestor (or, for the carriers, anywhere in its root). */
export interface BpPaperAncestorAttributes {
  /** JSON map from the canvas's English words to the host's. */
  "data-strings"?: string;
  /** Present: terminal, stage, image and equation picks emit `bp-server-insert`. */
  "data-server-insert"?: "";
  /** `"document"` or `"figure"`: the container the run sits in. */
  "data-paper-container-kind"?: string;
  /** On a `.bp-paper-editor` root: the document key resume focus checks. */
  "data-paper-doc-key"?: string;
  /** A carrier element: the paper's masters, `[{ id, title, tier, block_type }]`, as JSON. */
  "data-paper-masters"?: string;
  /** A carrier element: the expected fields, `[{ name, type?, label?, max? }]`, as JSON. */
  "data-expected-fields"?: string;
  /** On the element or an ancestor (`<html>` in most hosts): the stylesheet's dark or light theme. */
  "data-theme"?: "dark" | "light";
  /** On an ancestor: the accent family the stylesheet paints with. */
  "data-bp-theme"?: "iris" | "fjord" | "evergreen" | "ember" | "charple";
  /** On an ancestor: `"legacy"` keeps the reader's legacy palette, so embeds get no `.bp-paper-surface` island. */
  "data-paper-palette"?: "article" | "legacy";
  /** On a `.bp-paper-edit-field`: its field name; the slash menu counts the field blocks on screen by it. */
  "data-field-name"?: string;
}

/** Attributes the canvas writes for a host to read or select. */
export interface BpPaperDomAttributes {
  /** On each top-level block's DOM: its id. */
  "data-bp-id": string;
  /** On a locked block's DOM: its template role (`title`, …). */
  "data-bp-role": string;
  /** On a document link's span. */
  "data-wikilink": "";
  /** On a document link's span: its stored words. */
  target: string;
  /** On a document link's span: its document id. */
  docid: string;
  /** On a document link's span: its alias. */
  alias: string;
  /** On a document link's span: its target is gone (1.17.0). */
  "data-missing": "";
  /** On the canvas while `mediaPicker` is set. */
  "data-media-picker": "";
  /** On the canvas after `bp-canvas-mount-failed`. */
  "data-mount-failed": "true";
  /** On a comment range's span. */
  "data-comment-id": string;
  /** On a paint hole's node: the block id. */
  "data-bp-fleet-id": string;
  /** The paint hole itself. */
  "data-bp-fleet-body": "";
}

/** Classes the contract names. Every other class inside the elements is internal. */
export type BpPaperPublicClass =
  | "bp-remote-caret"
  | "bp-remote-caret__label"
  | "bp-remote-selection"
  | "bp-comment-range"
  | "bp-comment-range--active"
  | "bp-canvas-mount-failed";

/** Host classes the canvas reads: a `.bp-paper-editor` root (resume focus, masters, `data-paper-doc-key`) and `.bp-paper-edit-field` (with `data-field-name`). */
export type BpPaperHostClass = "bp-paper-editor" | "bp-paper-edit-field";

/** CSS custom properties a host sets to theme the editor's stylesheet. */
export type BpPaperThemeToken =
  | "--paper-accent"
  | "--paper-accent-soft"
  | "--paper-bg"
  | "--paper-bg-deep"
  | "--paper-chrome-bg"
  | "--paper-chrome-border"
  | "--paper-danger"
  | "--paper-edit-hover"
  | "--paper-font-mono"
  | "--paper-font-sans"
  | "--paper-font-serif"
  | "--paper-font-ui"
  | "--paper-ink"
  | "--paper-ink-faint"
  | "--paper-ink-faint-line"
  | "--paper-ink-soft"
  | "--paper-reading-accent"
  | "--paper-rule"
  | "--paper-rule-soft"
  | "--paper-picker-accent"
  | "--paper-picker-accent-soft"
  | "--paper-picker-bg"
  | "--paper-picker-chrome-bg"
  | "--paper-picker-chrome-border"
  | "--paper-picker-ink"
  | "--paper-picker-ink-faint"
  | "--paper-picker-ink-soft"
  | "--paper-picker-rule"
  | "--paper-picker-rule-soft"
  | "--paper-picker-shadow"
  | "--bp-air-callout"
  | "--bp-air-code"
  | "--bp-air-table"
  | "--bp-body-lh"
  | "--bp-body-size"
  | "--bp-body-tracking"
  | "--bp-code-pad"
  | "--bp-code-radius"
  | "--bp-code-size"
  | "--bp-codeblock-lh"
  | "--bp-codeblock-margin"
  | "--bp-codeblock-pad"
  | "--bp-codeblock-radius"
  | "--bp-codeblock-size"
  | "--bp-cols"
  | "--bp-evidence-band"
  | "--bp-evidence-band-max"
  | "--bp-evidence-fill"
  | "--bp-evidence-gutter"
  | "--bp-evidence-pull"
  | "--bp-evidence-width"
  | "--bp-h1-size"
  | "--bp-h2-lh"
  | "--bp-h2-size"
  | "--bp-h2-tracking"
  | "--bp-h2-weight"
  | "--bp-h3-lh"
  | "--bp-h3-size"
  | "--bp-heading-weight"
  | "--bp-img-radius"
  | "--bp-li-gap"
  | "--bp-list-indent"
  | "--bp-para-margin-top"
  | "--bp-pre-radius"
  | "--bp-remote-color"
  | "--bp-rule-hairline"
  | "--bp-section-beat"
  | "--bp-section-gap"
  | "--bp-section-rule"
  | "--bp-shadow-hsl"
  | "--bp-table-centre"
  | "--bp-tone-danger-bg"
  | "--bp-tone-danger-fg"
  | "--bp-tone-info-bg"
  | "--bp-tone-info-fg"
  | "--bp-tone-neutral-bg"
  | "--bp-tone-neutral-fg"
  | "--bp-tone-success-bg"
  | "--bp-tone-success-fg"
  | "--bp-tone-warning-bg"
  | "--bp-tone-warning-fg";

/** A picker element the host defines; the canvas creates it for `field-image`, `field-reference`, card media and embeds. */
export interface BpHostPickerElement extends HTMLElement {
  /** The picked value; the canvas sets it and reads it back. */
  value: string;
  /** `bp-media-picker`: open the asset browser; false when none is wired. */
  openBrowser?(): boolean;
  /** `bp-media-picker`: open the file dialog. */
  openFileDialog?(): void;
}

/** The Mermaid runtime the host supplies as `window.BarkparkPaperMermaid`. */
export interface BarkparkPaperMermaidRuntime {
  /** Render the diagrams inside `this.el`. */
  runMermaid(this: { el: Element }): void;
}

/** A mark a toolbar toggles (portable-doc names). */
export type ToolbarMark = "strong" | "em" | "code" | "underline" | "strike" | "highlight" | "link" | "wikilink";
export type ToolbarBlockStyle = "normal" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "blockquote";
export type ToolbarList = "bullet" | "number";
export type ToolbarCommand = "toggleMark" | "setBlockStyle" | "toggleList" | "insertBlock" | "insertInline" | "undo" | "redo";
export interface ToolbarCommandArgs {
  mark?: ToolbarMark;
  href?: string;
  /** `wikilink`: the document to link to (its published id), and the label kept as `target`. */
  docId?: string;
  target?: string;
  style?: ToolbarBlockStyle;
  kind?: ToolbarList;
  type?: string;
  attrs?: { level?: number };
}
/** What a toolbar shows as pressed. */
export interface ToolbarState {
  marks: ToolbarMark[];
  blockStyle: ToolbarBlockStyle | null;
  list: ToolbarList | null;
  link: { href: string } | null;
  wikilink: { target: string; docId: string | null } | null;
  selection: { empty: boolean; inBlockType: string | null };
}

/** A caret address. path only below the id-bearing block ("items[2]", "rows[1].cells[0]"); offset in UTF-16 units. */
export interface CanvasPoint {
  blockId: string;
  path?: string;
  offset: number;
}
export interface CanvasSelection {
  anchor: CanvasPoint;
  head: CanvasPoint;
}
export interface RemoteSelection extends CanvasSelection {
  id: string;
  name: string;
  /** CSS color; anything but plain color syntax falls back to grey. */
  color: string;
}
/** A comment on a span of text; active marks the host's open thread. */
export interface CommentRange extends CanvasSelection {
  id: string;
  active?: boolean;
}
/** A comment range as mapped through edits, with the text it spans. */
export interface LiveCommentRange extends CanvasSelection {
  id: string;
  text: string;
}

export interface WikilinkSuggestion {
  title: string;
  id: string;
  type: string;
}
/** What linkPreviewSource receives. A link sets href; a wikilink sets target, docId and alias. */
export interface LinkPreviewRequest {
  kind: "link" | "wikilink";
  href?: string;
  target?: string;
  docId?: string | null;
  alias?: string | null;
}
export interface LinkPreview {
  title?: string;
  excerpt?: string;
  href?: string;
  /** 1.9.0, a wikilink's: replaces the card's [[target]] line ("" hides it). */
  subtitle?: string;
  /** 1.9.0, a wikilink's: the document's type, beside the title. */
  badge?: string;
  /** 1.17.0, a wikilink's: true says the target is gone. Open hides and the link's `span[data-wikilink]` carries `data-missing`. */
  missing?: boolean;
}
/** 1.17.0: what wikilinkResolve answers for a document id. A title paints un-aliased links; null keeps their words. */
export type WikilinkResolution = { title?: string; missing?: boolean } | null;
export type MediaUploadResult = string | { src?: string; url?: string; alt?: string };
type MaybePromise<T> = T | Promise<T>;
export interface FindState {
  query: string;
  count: number;
  /** -1 when no match is active. */
  index: number;
  /** Absent before mount. */
  caseSensitive?: boolean;
}
/** Before mount findNext/findPrev return `{ count: 0, index: -1 }`. */
export type FindStepState = FindState | { count: number; index: number };
export interface ServerEchoMeta {
  /** "own" or "own-stale" mark the canvas's own echo; anything else is foreign. */
  mode?: string | null;
  requestId?: string | null;
}
export type RecoverySnapshot =
  | { mode: "rich"; blocks: PortableDocBlock[] }
  | { mode: "rich"; raw_editor_document?: unknown; serialization_error: string }
  | { mode: "markdown"; raw_source: string; blocks: PortableDocBlock[] }
  | { mode: "markdown"; raw_source: string; serialization_error: string };

/** A whole paper in one ProseMirror document. `editable="false"` mounts read-only. */
export interface BpPaperCanvasElement extends HTMLElement {
  /** Set: seed the run. Read: the saved baseline (the run last seeded, acknowledged or applied), not the live document; `recoverySnapshot()` reads that. */
  blocks: PortableDocBlock[];
  /** true: one batch in flight at a time, each `bp-canvas-ops` carries `seq`, and the host must acknowledge it. */
  acknowledgedSaves: boolean;
  /** 1.15.0. true: applyServerBlocks applies server blocks while the author edits, keeping blocks with unsaved typing. */
  liveRemote: boolean;
  /** 1.20.0. true: flushPendingChanges() in source mode commits the Markdown and keeps source mode open; a server apply reaches a textarea with no unsaved text. */
  flushKeepsSource: boolean;
  wikilinkSource: ((query: string) => MaybePromise<WikilinkSuggestion[]>) | null | undefined;
  tagSource: ((query: string) => MaybePromise<string[]>) | null | undefined;
  linkPreviewSource:
    | ((info: LinkPreviewRequest) => MaybePromise<LinkPreview | null>)
    | null
    | undefined;
  /** 1.17.0. A document's current title, painted on its un-aliased links without writing the body; refreshWikilinks() asks again. */
  wikilinkResolve: ((docId: string) => MaybePromise<WikilinkResolution>) | null | undefined;
  mediaUploader: ((file: File) => MaybePromise<MediaUploadResult>) | null | undefined;
  /** The host's image dialog: an Image insert and an image's Select open it. */
  mediaPicker:
    | ((request: { kind: "insert" | "replace"; current: { src: string; alt: string | null } | null }) => MaybePromise<{ src: string; alt?: string; width?: number } | null>)
    | null
    | undefined;
  /** The host's editor for a declared block or inline object, instead of the popover. */
  editBlockObject:
    | ((request: {
        type: string;
        title: string;
        inline: boolean;
        fields: Array<{ name: string; title?: string; type?: string; [key: string]: unknown }>;
        value: { type: string; [key: string]: unknown };
        error: { field: string | null; message: string } | null;
      }) => MaybePromise<Record<string, unknown> | null>)
    | null
    | undefined;

  acknowledgeOps(seq: number, saved: boolean): boolean;
  /** `refusal.reason` reopens the field dialog of the inline object that batch saved, with the reason on its field. */
  discardInflightOps(seq: number, refusal?: { reason?: string } | null): boolean;
  /** Whether the in-flight batch `seq` can be resent unchanged on the newer `serverBlocks`. */
  rebaseSafe(seq: number, serverBlocks: PortableDocBlock[]): boolean;
  /** Whether everything this canvas holds (in flight and unsent) can ride on the newer `serverBlocks`. */
  localEditsRebaseSafe(serverBlocks: PortableDocBlock[]): boolean;
  /** Before the page goes inert or moves: remember that the author was typing here. True when armed. */
  captureResumeFocus(): boolean;
  /** After: put the caret back if nothing else took focus meanwhile. True when restored. */
  restoreResumeFocus(): boolean;
  resendPendingOps(): boolean;
  identifyOpsRequest(seq: number, requestId: string, previousRequestId?: string | null): boolean;
  flushPendingChanges(): boolean;
  hasPendingChanges(): boolean;
  applyServerBlocks(blocks: PortableDocBlock[], echoMeta?: ServerEchoMeta | null): void;
  /** true when applied now; false when the canvas is not idle. */
  applyServerBlocksIfIdle(blocks: PortableDocBlock[]): boolean;
  resolveConflictWithServerBlocks(blocks: PortableDocBlock[]): void;
  recoverySnapshot(): RecoverySnapshot;
  focusBlock(id: string): boolean;
  /** 1.12.0: select the top-level image or object block card `id`, as a click on it does. */
  selectBlock(id: string): boolean;
  focusFirstBodyBlock(): boolean;
  /** 1.17.0. Ask wikilinkResolve again for every document link (after a rename or a delete). */
  refreshWikilinks(): void;
  toggleSourceMode(): void;
  /** true while the Markdown source textarea owns input (1.20.0). */
  readonly sourceMode: boolean;
  findSet(query: string, opts?: { caseSensitive?: boolean }): FindState;
  findNext(): FindStepState;
  findPrev(): FindStepState;
  findClear(): void;
  findState(): FindState;
  replaceCurrent(text: string): FindState;
  replaceAll(text: string): FindState & { replaced: number };
  /** Replace the remote carets (decorations only; [] clears). */
  setRemoteSelections(list: RemoteSelection[]): void;
  /** Replace the comment ranges (decorations that follow edits; [] clears). */
  setCommentRanges(list: CommentRange[]): void;
  /** The live comment ranges in document order; a range whose text is gone is absent. */
  commentRanges(): LiveCommentRange[];
  /** The ids of the comment ranges the selection overlaps. */
  commentsInSelection(): string[];
  /** Toolbar commands on the current selection: true when applied. */
  run(command: ToolbarCommand, args?: ToolbarCommandArgs): boolean;
  toggleMark(mark: ToolbarMark, attrs?: { href?: string; docId?: string; target?: string }): boolean;
  setBlockStyle(style: ToolbarBlockStyle): boolean;
  toggleList(kind: ToolbarList): boolean;
  insertBlock(type: string, attrs?: { level?: number }): boolean;
  /** A declared inline object at the caret; its field editor opens first. */
  insertInline(type: string): boolean;
  /** 1.10.0: one step of the canvas's own history, as Mod+Z / Shift+Mod+Z in it. */
  undo(): boolean;
  redo(): boolean;
  /** Whether the command would apply here, without applying it. */
  can(command: ToolbarCommand, args?: ToolbarCommandArgs): boolean;
  state(): ToolbarState;

  addEventListener<K extends keyof BpPaperCanvasEventMap>(
    type: K,
    listener: (this: BpPaperCanvasElement, ev: BpPaperCanvasEventMap[K]) => unknown,
    options?: boolean | AddEventListenerOptions,
  ): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
  removeEventListener<K extends keyof BpPaperCanvasEventMap>(
    type: K,
    listener: (this: BpPaperCanvasElement, ev: BpPaperCanvasEventMap[K]) => unknown,
    options?: boolean | EventListenerOptions,
  ): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare global {
  interface HTMLElementTagNameMap {
    "bp-paper-editor": BpPaperEditorElement;
    "bp-paper-canvas": BpPaperCanvasElement;
  }
  interface Window {
    /** Set to true before the first element mounts to stop the bundle appending <link id="bp-paper-editor-styles" href="/assets/bp-paper-editor.css">. */
    BP_PAPER_EDITOR_NO_INJECT?: boolean;
    /** Host-supplied: the diagram node calls its runMermaid to render a preview. */
    BarkparkPaperMermaid?: BarkparkPaperMermaidRuntime;
  }
}
