// Types for @barkpark/paper-editor.
//
// The bundle is an IIFE with no module exports. Loading it (a <script> tag or
// a side-effect `import "@barkpark/paper-editor"`) registers two custom
// elements on `customElements`. These declarations type those elements, their
// events and the window flag. EMBED-CONTRACT.md (v1.15.0) is the normative spec
// for both elements; these types follow src/index.js and src/canvas/index.js.

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

// ── <bp-paper-editor> events (EMBED-CONTRACT.md "Outbound") ────────────────

export interface BpReadyDetail {
  blockId: string;
  blockType: string;
  contractVersion: string;
}
export type BpOpDetail = PatchBlockOp;
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
  raw?: string;
}

export interface BpPaperEditorEventMap extends HTMLElementEventMap {
  "bp-ready": CustomEvent<BpReadyDetail>;
  "bp-op": CustomEvent<BpOpDetail>;
  "bp-slash-insert": CustomEvent<BpSlashInsertDetail>;
  "bp-error": CustomEvent<BpErrorDetail>;
}

/** One PortableDoc block per element. Inbound: the `data-block` attribute or the `block` property. */
export interface BpPaperEditorElement extends HTMLElement {
  block: PortableDocBlock;
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
}
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
  blocks: PortableDocBlock[];
  /** true: one batch in flight at a time, each `bp-canvas-ops` carries `seq`, and the host must acknowledge it. */
  acknowledgedSaves: boolean;
  /** 1.15.0. true: applyServerBlocks applies server blocks while the author edits, keeping blocks with unsaved typing. */
  liveRemote: boolean;
  wikilinkSource: ((query: string) => MaybePromise<WikilinkSuggestion[]>) | null | undefined;
  tagSource: ((query: string) => MaybePromise<string[]>) | null | undefined;
  linkPreviewSource:
    | ((info: LinkPreviewRequest) => MaybePromise<LinkPreview | null>)
    | null
    | undefined;
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
  discardInflightOps(seq: number): boolean;
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
  toggleSourceMode(): void;
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
    /** Set to true before the first element mounts to stop the bundle appending <link href="/assets/bp-paper-editor.css">. */
    BP_PAPER_EDITOR_NO_INJECT?: boolean;
  }
}
