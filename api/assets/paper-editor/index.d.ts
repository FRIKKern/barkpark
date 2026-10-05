// Types for @barkpark/paper-editor.
//
// The bundle is an IIFE with no module exports. Loading it (a <script> tag or
// a side-effect `import "@barkpark/paper-editor"`) registers two custom
// elements on `customElements`. These declarations type those elements, their
// events and the window flag. EMBED-CONTRACT.md is the normative spec for
// <bp-paper-editor>; the <bp-paper-canvas> surface below is what
// src/canvas/index.js implements today and is not yet versioned by the contract.

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

/** One op in a canvas batch. patch-block is the stable shape; other ops carry `op` plus their fields. */
export type CanvasOp = PatchBlockOp | { op: string; [key: string]: unknown };

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

export interface BpCanvasOpsDetail {
  ops: CanvasOp[];
  /** Present when the host set `acknowledgedSaves = true`. Pass it back to acknowledgeOps. */
  seq?: number;
  conflictBlocks?: PortableDocBlock[];
}
export interface BpCanvasOpenLinkDetail {
  kind: "link" | "wikilink";
  href?: string;
  target?: string;
  docId?: string;
}
export interface BpCanvasMountFailedDetail {
  stage: string;
  message: string;
  blockIds: string[];
}
export interface BpCanvasNodeFailedDetail {
  blockId: string | null;
  type: string;
  message: string;
  [key: string]: unknown;
}

export interface BpPaperCanvasEventMap extends HTMLElementEventMap {
  /** A debounced batch of edits. */
  "bp-canvas-ops": CustomEvent<BpCanvasOpsDetail>;
  /** Cancelable. Call preventDefault() to handle the link yourself; otherwise a plain link opens in a new window. */
  "bp-canvas-open-link": CustomEvent<BpCanvasOpenLinkDetail>;
  "bp-canvas-mount-failed": CustomEvent<BpCanvasMountFailedDetail>;
  "bp-canvas-node-failed": CustomEvent<BpCanvasNodeFailedDetail>;
}

export interface WikilinkSuggestion {
  title: string;
  id: string;
  type: string;
}
export interface LinkPreview {
  title?: string;
  excerpt?: string;
  href?: string;
}
export type MediaUploadResult = string | { src?: string; url?: string; alt?: string };
export interface FindState {
  query: string;
  count: number;
  index: number;
}

/** A whole paper in one ProseMirror document. `editable="false"` mounts read-only. */
export interface BpPaperCanvasElement extends HTMLElement {
  blocks: PortableDocBlock[];
  /** true: one batch in flight at a time, each `bp-canvas-ops` carries `seq`, and the host must acknowledge it. */
  acknowledgedSaves: boolean;
  wikilinkSource: ((query: string) => Promise<WikilinkSuggestion[]>) | null | undefined;
  tagSource: ((query: string) => Promise<string[]>) | null | undefined;
  linkPreviewSource:
    | ((info: BpCanvasOpenLinkDetail) => Promise<LinkPreview | null>)
    | null
    | undefined;
  mediaUploader: ((file: File) => Promise<MediaUploadResult>) | null | undefined;

  acknowledgeOps(seq: number, saved: boolean): boolean;
  discardInflightOps(seq: number): boolean;
  resendPendingOps(): boolean;
  identifyOpsRequest(seq: number, requestId: string, previousRequestId?: string | null): boolean;
  flushPendingChanges(): boolean;
  hasPendingChanges(): boolean;
  applyServerBlocks(blocks: PortableDocBlock[], echoMeta?: unknown): unknown;
  applyServerBlocksIfIdle(blocks: PortableDocBlock[]): unknown;
  resolveConflictWithServerBlocks(blocks: PortableDocBlock[]): unknown;
  focusBlock(id: string): unknown;
  focusFirstBodyBlock(): unknown;
  toggleSourceMode(): unknown;
  findSet(query: string, opts?: Record<string, unknown>): FindState;
  findNext(): FindState;
  findPrev(): FindState;
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
