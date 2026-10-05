// Types for @barkpark/paper-editor.
//
// The bundle is an IIFE with no module exports. Loading it (a <script> tag or
// a side-effect `import "@barkpark/paper-editor"`) registers two custom
// elements on `customElements`. These declarations type those elements, their
// events and the window flag. EMBED-CONTRACT.md (v1.1.0) is the normative spec
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
  wikilinkSource: ((query: string) => MaybePromise<WikilinkSuggestion[]>) | null | undefined;
  tagSource: ((query: string) => MaybePromise<string[]>) | null | undefined;
  linkPreviewSource:
    | ((info: LinkPreviewRequest) => MaybePromise<LinkPreview | null>)
    | null
    | undefined;
  mediaUploader: ((file: File) => MaybePromise<MediaUploadResult>) | null | undefined;

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
  focusFirstBodyBlock(): boolean;
  toggleSourceMode(): void;
  findSet(query: string, opts?: { caseSensitive?: boolean }): FindState;
  findNext(): FindStepState;
  findPrev(): FindStepState;
  findClear(): void;
  findState(): FindState;
  replaceCurrent(text: string): FindState;
  replaceAll(text: string): FindState & { replaced: number };

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
