// canvas/index.js — Phase-4 Stage S1: <bp-paper-canvas>, the CONTINUOUS-CANVAS
// engine over ONE prose run.
//
// Where <bp-paper-editor> (../index.js) mounts ONE TipTap instance PER BLOCK and
// emits a patch-block op for that one block, <bp-paper-canvas> mounts ONE TipTap
// instance over a CONTIGUOUS run of PROSE blocks (paragraph | heading | list —
// non-prose blocks are run boundaries handled in S2/S3, so a run never contains
// them). This is what proves the Obsidian continuous feel: cross-block caret,
// multi-block selection, Enter-split, Backspace-merge — ALL in ONE ProseMirror
// document, which StarterKit's keymaps give us FOR FREE (doc content is block+,
// so paragraph/heading/list as siblings is native and Enter/Backspace at block
// edges split/merge without any custom code).
//
// PROJECTOR + OP-MAPPER are S0's PURE, TESTED functions, used VERBATIM:
//   runToTiptap(blocks) -> { type:"doc", content:[node…] }   (mount content)
//   runToOps(prevBlocks, editor.getJSON()) -> ordered op array (the diff)
// We do NOT reinvent the diff. The ONE thing the canvas must add on top of S0 is
// the BpAttrs extension (./bp-attrs.js): runToTiptap stamps attrs:{bpId,bpType}
// on each top-level node, but ProseMirror DROPS unknown node attrs on the
// setContent->getJSON round-trip unless the node type declares them. BpAttrs
// declares bpId/bpType on the block nodes so editor.getJSON() preserves the ids
// runToOps keys by. Without it, runToOps mis-diffs everything as new.
//
// S1 SCOPE (tight): cross-block editing + split/merge + op-emission +
// FormatBubble. EXPLICITLY OUT (later stages, clean seams left below): the slash
// menu, the [[ wikilink + # tag autocompletes, and non-prose node-views.
//
// ADDITIVE: this is the SECOND custom element in the same bundle. ../index.js
// gains exactly one line — `import "./canvas/index.js";` — so this registers.
// The shipped <bp-paper-editor> behavior is byte-unchanged.

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Link from "@tiptap/extension-link";
import Placeholder from "@tiptap/extension-placeholder";
import Typography from "@tiptap/extension-typography";
// ProseMirror selection constructors — used by the slash direct-insert to place the
// caret naturally after the swap (TextSelection INTO a prose/callout body;
// NodeSelection ONTO a divider/code/diagram/field atom). @tiptap/pm re-exports the
// PM core modules, so this is the canonical TipTap-vanilla import (no extra dep).
import { TextSelection, NodeSelection, Plugin } from "@tiptap/pm/state";
import { Extension } from "@tiptap/core";

// PURE S0 projector + op-mapper — used verbatim (do NOT reinvent the diff).
// reconcileServerEcho (S4a): the PURE own-echo reconciler — treats a live
// bpId:null node as a wildcard matching the server-minted id at that index, so a
// NEW-block echo (Enter-split / paste / typed paragraph) is recognized as an own
// echo and yields the id-writebacks that make the next diff incremental.
// docToBlocks (P5 source-mode): the LIVE-doc → blocks projection — the SAME node→
// block path runToOps diffs against internally (classify + nextNodeToBlock). Source
// mode derives its baseline from the LIVE doc (getJSON), NOT the echo-confirmed,
// LAGGING this._blocks, so the markdown reflects the user's just-typed edits.
import {
  runToTiptap,
  runToOps,
  reconcileServerEcho,
  docToBlocks,
} from "./run-convert.js";
// The attr-preservation extension — the make-or-break of S1 (see ./bp-attrs.js).
import { BpAttrs } from "./bp-attrs.js";
// S3: the divider as a canvas ATOM node — the first non-prose block to live
// INSIDE the canvas document (so a prose run can CONTAIN dividers). A leaf with
// no edit UI; PM's atom selection + Backspace-delete come free. See ./divider-node.js.
import { Divider } from "./divider-node.js";
// S3.2: the callout as a canvas CONTENT node — the first non-prose block with an
// EDITABLE body to live INSIDE the canvas document (so a prose run can CONTAIN
// callouts, body and all). A node-view renders the tone-framed chrome + fold
// toggle around a contentDOM body hole. See ./callout-node.js.
import { Callout } from "./callout-node.js";
// STEP 4: the card WIDGET as a canvas node (bpCard) — a slots-native block whose
// body slot is an editable inline contentDOM, with title (an attr island) + tone/
// media/action (present-only attrs) as chrome. Its node-view carries the reader's
// own bp-card/__t/__d classes so the reader cascade paints it for free (the callout
// precedent). See ./card-node.js.
import { Card } from "./card-node.js";
// The notes-grid split: the singular `note` WIDGET as a canvas CONTENT node — a
// callout SUPERSET whose body is an editable inline contentDOM, with label + lead as
// non-PM <input> islands (all three fields editable, P2). Its node-view uses
// `bp-canvas-note*` chrome ONLY (the DELIBERATE non-class-share; reader parity is
// proven by compose byte-identity, not shared classes). See ./note-node.js.
import { Note } from "./note-node.js";
// The stage WIDGET as a canvas node (bpStage) — the editable per-node twin of ONE
// legacy `pipeline` node. A control-atom: five scalars (kind/title/detail text +
// files/source chrome) ride node.attrs, edited by native controls. See ./stage-node.js.
import { Stage } from "./stage-node.js";
// S3.3: the code block as a canvas ATTR-ATOM node — an atom (no PM-managed body,
// like the divider) whose code TEXT rides in the `value` attr and is edited by a
// NON-PM <textarea> island (stopEvent/ignoreMutation so PM never sees its
// keystrokes). UNLIKE the divider it carries a mutable value/lang and CAN emit a
// patch-block. The node is named `bpCode` to avoid the StarterKit inline `code`
// MARK; StarterKit's `codeBlock` NODE is disabled below so only this node owns
// <pre>. See ./code-node.js.
import { Code } from "./code-node.js";
// S3.4: the diagram block as a canvas ATTR-ATOM node — MIRRORS the S3.3 code node
// (an atom whose body text rides in an attr, edited by a non-PM <textarea> island)
// with two field differences: the body is `source` (the Mermaid text, not `value`)
// and there is an extra optional `caption` (where code had `lang`). The node is
// named `bpDiagram`; UNLIKE code/divider there is NO StarterKit collision (StarterKit
// ships no `diagram` node), so NO StarterKit node is disabled for it. See
// ./diagram-node.js.
import { Diagram } from "./diagram-node.js";
// S3.5: the 7 native-control field-* blocks as a canvas CONTROL-ATOM node — the
// FOURTH node-view variant. A SINGLE `bpField` node serves all 7 native field types
// (string/slug/text/boolean/select/datetime/color), discriminated by bpType; the
// value is edited by a NATIVE control (input/textarea/checkbox/select/datetime-local
// /color) wrapped in a stopEvent/ignoreMutation island, and COERCED by field type
// exactly like the per-block BarkparkFieldBlockBridge. field-image/field-reference
// (pickers) stay run boundaries (bpOpaque). See ./field-node.js.
import { Field } from "./field-node.js";
// editable-action: the CTA `action` block as a canvas CONTROL-ATOM node — a LEAF
// (href/label/priority) edited by native controls in a stopEvent/ignoreMutation island,
// byte-modelled on field-node.js's native branch. Its node-view renders the reader's own
// bp-button anchor byte-identically as a live preview. ONE bpType ("action"), no
// StarterKit collision. See ./action-node.js.
import { Action } from "./action-node.js";
// S3.6: the sheet + embed blocks as canvas READ-ONLY ATOM nodes — the FIFTH (and LAST
// S3) node-view variant. Both are REFERENCES, NOT editable text: a sheet is edited in
// its own surface (its cached snapshot renders read-only); an embed transcludes at
// VIEW render (walk.ex). So in the canvas they are read-only atoms that carry the WHOLE
// block verbatim on `bpBlock` (the bpOpaque verbatim-carry, made canvas-eligible) and
// NEVER emit a value/content patch — they render a read-only chip (sheet summary /
// embed reference) with contentEditable false, are selectable so Backspace deletes the
// atom → remove-block, and DO participate in structural ops. See ./embed-node.js.
import { Sheet, Embed, Fleet } from "./embed-node.js";
import { Figure } from "./figure-node.js";
// live-data task-list: the EDITABLE-QUERY + server-painted-ROWS atom (`bpTaskList`).
import { TaskList } from "./task-list-node.js";
// article-chrome roles: the eyebrow / byline / ingress / pullquote blocks as PLAIN
// canvas PROSE nodes (NO node-view — chrome-free, the reader emits one styled
// element with a bp-role-* class). Each renders `["p", {class:"bp-role-*"}, 0]` so
// PM derives the contentDOM from the content hole; getJSON round-trips the styled
// element + bpId/bpType, and run-convert.js maps the block ⇄ node. See ./role-nodes.js.
import { Eyebrow, Byline, Ingress, Pullquote } from "./role-nodes.js";
// editable table: the `table` block as FOUR hand-rolled NESTED nodes (bpTable >
// bpTableRow > bpTableHeaderCell|bpTableCell), NOT @tiptap/extension-table. Cell bodies
// are PM `inline*` holes reusing the shared inline serializer (marks round-trip); the
// bpTable node-view paints the reader <table> + add/remove row/col chrome around a
// <tbody> contentDOM. run-convert.js maps the block ⇄ node tree. NO StarterKit collision
// (StarterKit ships no table/tr/td/th node). See ./table-node.js.
import {
  BpTable,
  BpTableRow,
  BpTableCell,
  BpTableHeaderCell,
} from "./table-node.js";
// S10: the columns CONTAINER nodes — the FIRST canvas node whose interior is a
// nested block tree. bpColumns (grid wrapper, content "bpColumn+") > bpColumn
// (one column, content = prose+divider+bpColumnAtom, container-in-container
// FORBIDDEN) > bpColumnAtom (verbatim read-only carrier for any non-first-class
// child). bpColumns/bpColumn are DOM-free (renderHTML content holes); bpColumnAtom's
// node-view references `document` lazily. run-convert.js maps the block ⇄ nodes and
// diffs the whole `columns` array coarsely. See ./columns-node.js.
import { Columns, Column, ColumnAtom } from "./columns-node.js";
// The section CONTAINER node — a top-level `section` block projects to this editable
// bpSection (a nested block+ body wrapped by two rules + an editable title chrome).
// A nested (depth>=1) section stays a verbatim bpOpaque carry (V1 forbid-nesting).
// See ./section-node.js.
import { Section } from "./section-node.js";
// The MOUNTABLE bpOpaque carry — the schema twin of run-convert.js's opaque
// projection. Needed so a bpSection body can hold a NON-canvas child (a nested
// section, or a composite/codelist/localizedText) as a read-only verbatim carry
// instead of PM lifting it out of the section. See ./opaque-node.js.
import { Opaque } from "./opaque-node.js";
// The terminal CONTAINER nodes (bpTerminal > body children + bpTerminalAtom). A
// terminal block ⇄ a bpTerminal node: a SINGLE editable body wrapped in reader chrome
// (title bar + optional live badge + optional footer); any non-first-class body child
// rides a read-only bpTerminalAtom. bpTerminal's node-view references `document` lazily
// (imports DOM-free). No StarterKit collision. See ./terminal-node.js.
import { Terminal, TerminalAtom } from "./terminal-node.js";
// Reused verbatim from the shipped editor (imported, never copied).
import { FormatBubble } from "../format-bubble.js";
// P4 autocomplete port: the caret-anchored `[[`/`#` popup (WikilinkMenu, reused
// for BOTH triggers via a row adapter) + the PURE, DOM-free trigger detectors and
// replace-range mappers. All shipped + browser-verified in the per-block editor;
// the canvas REUSES them verbatim — only the WC-side wiring is ported below.
import { WikilinkMenu } from "../wikilink-menu.js";
import {
  parseOpenWikilink,
  wikilinkReplaceRange,
  parseOpenTag,
  tagReplaceRange,
} from "../wikilink-trigger.js";
// P4 S-slash: the SAME caret-anchored "/" insert popup the per-block editor uses
// (slash-menu.js), REUSED verbatim — only the WC-side wiring differs. SLASH_ITEMS
// is the per-block menu's item list, imported INTACT (never edited): the canvas
// filters it to CANVAS_SLASH_TYPES (the insertable-into-a-run set) via an allowlist
// so the per-block menu's items stay untouched. UNLIKE the per-block editor (which,
// on a pick, wipes the origin block + dispatches `bp-slash-insert` for the SERVER's
// default_block/2 to build), the canvas inserts the default NODE DIRECTLY into the
// ProseMirror doc — so runToOps emits an insert-after carrying the reconstructed
// block and the S4a echo stamps the server id. See _maybeSlash / _chooseSlash below.
import { SlashMenu, SLASH_ITEMS } from "../slash-menu.js";
// The DOM-free tone normalizer (note→info, warn→warning, error→danger, …) shared
// with the per-block `> [!type]` callout shorthand. Reused VERBATIM so the canvas
// shorthand maps tones identically. See _maybeCalloutShorthand below.
import { normalizeTone } from "../tone.js";
// The PURE, DOM-free slash-insert core (split out so it unit-tests in plain Node —
// canvas/index.js itself can't, being a custom element). CANVAS_SLASH_TYPES is the
// insertable-type allowlist; canvasDefaultBlock mirrors default_block/2; slashTypeToNode
// builds the per-type default NODE via runToTiptap (so it round-trips byte-identically);
// CANVAS_SLASH_TEXTABLE_NODES marks which inserted nodes take an into-body caret.
import {
  CANVAS_SLASH_TYPES,
  canvasDefaultBlock,
  slashTypeToNode,
  CANVAS_SLASH_TEXTABLE_NODES,
  slashTriggerAllowsParent,
  CANVAS_COMPOUND_INSERTS,
} from "./slash-insert.js";
// P5 command palette: the Obsidian Cmd-P analog — a fuzzy, keyboard-triggered (Mod-p)
// launcher over editor COMMANDS (NOT a typed "/" trigger). CommandPalette is a THIN
// subclass of SlashMenu (reuses its render/keyboard/positioning DOM + CSS, only re-
// parameterized: eyebrow / footer / fuzzy filter / centered position). The registry is
// a static { id, label, group, run } array — Insert commands REUSE the slash insert
// seam (insertSlashTypeAtSelection, factored from _chooseSlash → default_block parity),
// Format commands toggle the canvas StarterKit marks, Turn-into commands set the block.
// Canvas-only; <bp-paper-editor> (src/index.js) is byte-unchanged. See _onKeyDown
// (Mod-p trigger + mutual exclusion) and _openPalette / _choosePaletteCommand below.
import {
  CommandPalette,
  buildCommandRegistry,
  insertSlashTypeAtSelection,
  insertCompoundAtSelection,
} from "./command-palette.js";
// P5 MARKDOWN SOURCE-MODE: the merged, PURE, dependency-free blocks⇄markdown
// converter (../markdown.js). The "source mode" toggle swaps the rich ProseMirror
// editor for a Markdown <textarea> (the Obsidian source-mode analog): on ENTER we
// serialize the run to markdown (blocksToMarkdown), on EXIT we parse the edited
// markdown back (markdownToBlocks) and update the editor so the existing _emitOps
// diff path emits exactly the user's source-mode edits. Canvas-only; this import is
// what pulls markdown.js INTO the committed bundle for the first time (it was
// previously test-only). <bp-paper-editor> (src/index.js) is byte-unchanged.
import { blocksToMarkdown, markdownToBlocks } from "../markdown.js";
// The PURE id-realigner + deep-cloner for the exit-source diff (split into its own
// module so it unit-tests in plain Node — canvas/index.js itself calls
// customElements.define at load and can't be imported DOM-free). On EXIT we parse the
// edited markdown (markdownToBlocks → fresh minted ids), then realign those ids onto
// the source baseline so a surviving block keeps its id and runToOps emits a PATCH
// (not remove+insert) for an in-place edit. See ./source-realign.js.
import {
  realignBlockIds,
  clampLockedPrefix,
  deepCloneBlocks,
} from "./source-realign.js";
// pdd-t2: the PURE doctrine template-lock veto predicate — wired into the editor's
// filterTransaction below so a locked mandated block (title @0 / featured @1) can
// never be deleted or moved live (the FELT half of the server backstop). Split into
// its own DOM-free module so it unit-tests in plain Node (this file can't be
// imported DOM-free — it calls customElements.define at load).
import { transactionVetoesLock } from "./locks.js";
// pdd-t20c: the PURE constraint-vocabulary veto — the calm lock veto GENERALIZED to
// cardinality (a remove dropping a required/min-N kind below its floor) + relative
// order (a move misplacing a positioned kind against its before/after relation).
// Wired into the SAME filterTransaction plugin below, reading the JSON declarations
// LIVE off the host's data-constraints (twin of data-locked-tail). DOM-free so it
// unit-tests in plain Node like locks.js.
import { transactionVetoesConstraints, parseConstraints } from "./constraints.js";
import {
  parseVocabulary,
  transactionVetoesVocabulary,
  slashItemsForVocabulary,
} from "./vocabulary.js";
// Internal-link marks — schema registration only, so the canvas holds existing
// wikilink/blockref/tag inline marks through a setContent->getJSON round-trip
// (identical role to ../index.js). The [[ / # autocomplete UI lands on top of
// these marks in P4: a pick inserts a wikilink/tag MARK, which runToOps emits as
// a patch-block for that block (the existing prose patch path).
import { Wikilink, Blockref, Tag, Valueref } from "../marks.js";
import { DEBOUNCE_MS, PLACEHOLDER } from "../contract.js";

// One-shot, id-guarded self-inject of the standalone stylesheet — IDENTICAL
// contract to ../index.js:ensureStyles (same <link>, same id-guard, same
// BP_PAPER_EDITOR_NO_INJECT opt-out). Both elements share the one stylesheet, so
// the id guard means whichever mounts first injects it and the other no-ops.
function ensureStyles() {
  if (typeof window !== "undefined" && window.BP_PAPER_EDITOR_NO_INJECT) return;
  if (typeof document === "undefined") return;
  if (document.getElementById("bp-paper-editor-styles")) return;
  const link = document.createElement("link");
  link.id = "bp-paper-editor-styles";
  link.rel = "stylesheet";
  link.href = "/assets/bp-paper-editor.css";
  (document.head || document.documentElement).appendChild(link);
}

// Strip null-valued bpId/bpType from NON-top-level nodes before the diff.
//
// Why this exists: BpAttrs declares bpId/bpType GLOBALLY on the `paragraph`
// type (addGlobalAttributes targets by node TYPE, not position — it cannot say
// "top-level paragraphs only"). So the paragraph nested INSIDE a list item also
// gains the attrs, and ProseMirror serializes them as { bpId:null, bpType:null }
// in getJSON(). But runToTiptap's projection of a `list` block (via convert.js
// blockToTiptap) emits those inner paragraphs with NO attrs key. runToOps'
// proseNodeChanged compares node.content via stableProseKey, so the phantom
// { bpId:null, bpType:null } on a nested paragraph (a PRESENCE difference —
// runToTiptap omits the key entirely) makes the list look changed. This is
// ORTHOGONAL to the marked-text key-ORDER difference, which stableProseKey now
// handles itself via canonical (sorted-key) comparison; here we only close the
// attr-presence gap.
//
// Fix: at depth > 0 (anything not a direct child of the doc), drop a bpId/bpType
// that is null so the nested nodes match runToTiptap's projection.
// TOP-LEVEL nodes are left untouched — there a null bpId is MEANINGFUL: it marks
// a freshly-typed/split block runToOps must mint an id for. We only ever strip
// the phantom nested ones. This keeps S0's runToOps used verbatim, with a doc
// shaped exactly the way it was tested against.
function normalizeCanvasDoc(doc) {
  const stripNested = (node) => {
    if (node && node.attrs) {
      const a = node.attrs;
      if (
        a.bpId == null &&
        a.bpType == null &&
        a.locked == null &&
        a.role == null &&
        hasOnlyBpKeys(a)
      ) {
        // The node gained ONLY the (null) bp stamp — drop the whole attrs bag so
        // it matches an unstamped projection node.
        delete node.attrs;
      } else {
        if (a.bpId == null) delete a.bpId;
        if (a.bpType == null) delete a.bpType;
        // pdd-t2: BpAttrs declares locked/role GLOBALLY on `paragraph`, so the
        // paragraph nested inside a list item also gains them as { locked:null,
        // role:null } in getJSON — but runToTiptap's list projection emits those
        // inner paragraphs with NO such keys. Strip the null phantoms so a list's
        // getJSON re-projection matches (else the list looks changed every
        // keystroke — the SAME presence-gap the bpId/bpType strip closes). Locks
        // are top-level only, so a nested null is always a phantom.
        if (a.locked == null) delete a.locked;
        if (a.role == null) delete a.role;
      }
    }
    if (node && node.content) node.content.forEach(stripNested);
  };
  // Walk only the SUBTREES of each top-level node — never the top-level nodes
  // themselves (their null bpId is the new-block signal runToOps needs).
  (doc.content || []).forEach((top) => {
    (top.content || []).forEach(stripNested);
  });

  // ── DEDUP top-level bpIds: an Enter-SPLIT clones the origin block's attrs ──
  //
  // ProseMirror's splitBlock (the Enter keymap) copies the source node's attrs
  // into the new half — INCLUDING bpId. So a split yields TWO top-level nodes
  // carrying the SAME bpId. runToOps assumes each surviving prev id appears at
  // most once (it keys edits by id); a duplicate makes it emit a self-move and
  // conflicting patches for that id. The split block is genuinely NEW, so the
  // SECOND-and-later occurrence of any bpId must read as new: null its bpId so
  // runToOps mints a fresh id — exactly S0's "split → insert-after(minted id)"
  // path. The FIRST occurrence keeps the id (it's the surviving origin block).
  const seen = new Set();
  (doc.content || []).forEach((top) => {
    const id = top.attrs && top.attrs.bpId;
    if (id == null) return;
    if (seen.has(id)) {
      // A clone of an already-seen id — strip its stamp so it diffs as NEW.
      top.attrs = { ...top.attrs, bpId: null };
    } else {
      seen.add(id);
    }
  });

  return doc;
}

// True when an attrs bag carries nothing but the bp stamp keys (so deleting them
// would leave it empty). Guards against nuking a node that also has real attrs
// (e.g. a heading's level — though headings are top-level and never walked here).
function hasOnlyBpKeys(attrs) {
  return Object.keys(attrs).every(
    (k) => k === "bpId" || k === "bpType" || k === "locked" || k === "role",
  );
}

// The canvas slash menu's item list = SLASH_ITEMS narrowed to the insertable set.
// Computed ONCE at module load (SLASH_ITEMS is a static array; CANVAS_SLASH_TYPES is
// the allowlist from ./slash-insert.js). SlashMenu reads EXPECTED-group items fresh
// from the DOM on every open() on top of this base, so a bound-field pick still works
// — and an EXPECTED item whose type is NOT canvas-insertable (field-image /
// field-reference / composite) is filtered the same way at _chooseSlash (a defensive
// guard: such a pick is a no-op rather than a bad insert). Filtering via this
// allowlist (NOT by editing SLASH_ITEMS) keeps the per-block menu's items byte-intact.
// …plus the CANVAS-ONLY compound starters (CANVAS_COMPOUND_INSERTS): each becomes a
// "Starters" row carrying a `compound` marker _chooseSlash branches on. They are NOT
// added to SLASH_ITEMS itself — the per-block menu dispatches bp-slash-insert to the
// SERVER (default_block/2), which has no compound path; the canvas inserts the whole
// pre-composed subtree client-side (insertCompoundAtSelection). `type` mirrors the
// kind only for the row's dataset/filter haystack — it is NOT a portable-doc type,
// and _chooseSlash's CANVAS_SLASH_TYPES guard would no-op it defensively anyway.
const CANVAS_SLASH_ITEMS = [
  ...SLASH_ITEMS.filter((it) => CANVAS_SLASH_TYPES.has(it.type)),
  ...CANVAS_COMPOUND_INSERTS.map((c) => ({
    group: "Starters",
    type: c.kind,
    compound: c.kind,
    label: c.label,
    hint: c.hint,
    desc: c.desc,
  })),
];

class BpPaperCanvas extends HTMLElement {
  static get observedAttributes() {
    return ["editable"];
  }

  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._bubble = null; // FormatBubble instance (selection format toolbar)
    this._debounceTimer = null;
    // The RUN this canvas mounted — an array of prose blocks. This is the
    // "prev" runToOps diffs the live doc against. As of S4a this baseline is
    // ECHO-ADVANCED: after the server applies a batch it echoes the confirmed
    // blocks back via applyServerBlocks(), which resets this._blocks so the
    // NEXT diff is INCREMENTAL (bounded op size over a long session) rather than
    // cumulative-from-mount. See applyServerBlocks below.
    this._blocks = [];
    // Save bridge state. Only one canvas batch is emitted at a time. New edits
    // made before its acknowledgement remain live and are diffed immediately
    // after success from the acknowledged after-snapshot.
    this._inflightOps = null;
    this._awaitingOwnEchoes = [];
    this._dirtyWhileInflight = false;
    this._opsSeq = 0;
    this._acknowledgedSaves = false;
    this._editable = true;
    // S4a: a queued external-edit echo deferred because the editor was FOCUSED
    // or composing (IME) when it arrived — applied on blur / compositionend so a
    // confirmed external edit never yanks the caret mid-edit. null when none
    // pending; otherwise the confirmed blocks array to setContent on release.
    this._pendingServerBlocks = null;
    // Bound listeners for the deferred-apply release (added only while a
    // server echo is queued; removed once applied). Kept as fields so the
    // exact same function identity is removed.
    this._onComposeEnd = null;
    this._onBlurFlush = null;
    // P4 `[[` wikilink autocomplete — ported VERBATIM from ../index.js. Studio-
    // only by construction: gated on `this._editable` (read-mode never runs
    // onUpdate) AND on an injected `this._wikilinkSource` (unset → never opens).
    // The block-local trigger (parseOpenWikilink against $from.parent.textContent
    // + parentOffset) is FRAME-CORRECT in the multi-block canvas doc: a `[[` typed
    // in ANY run block opens the popup against THAT block's text. A pick inserts a
    // wikilink mark, so runToOps emits a patch-block for that one block.
    this._wikilink = null; // WikilinkMenu instance (lazy, created on first trigger)
    this._wlSeq = 0; // monotonic open/query counter — stale async-result guard
    this._wikilinkSource = null; // injected async (query) => [{ title, id, type }]
    this._wlRange = null; // { from, to } PM range to replace on the current pick
    // P4 `#` tag autocomplete — the `#` analogue, REUSING WikilinkMenu via a
    // { title, id, type } adapter. Independent seq/range so the two popups never
    // cross-contaminate. Same Studio-only gating as the wikilink popup.
    this._tag = null; // WikilinkMenu instance reused for tags (lazy)
    this._tagSeq = 0; // monotonic open/query counter — stale async-result guard
    this._tagSource = null; // injected async (query) => [ "design", "obsidian", … ]
    this._tagRange = null; // { from, to } PM range to replace on the current pick
    // P4 S-slash: the "/" insert popup (lazy, created on first trigger). UNLIKE the
    // wikilink/tag popups it needs no injected source — the item list is the static
    // CANVAS_SLASH_ITEMS (SLASH_ITEMS filtered to the insertable set) + EXPECTED-group
    // items SlashMenu reads fresh from the DOM. Gated on `this._editable` only (read
    // mode never runs onUpdate). On a pick it inserts the default NODE directly (no
    // bp-slash-insert). The callout `> [!type]` shorthand shares _maybeSlash's
    // predicate but is mutually exclusive ('>' vs '/') and inserts a callout node too.
    this._slash = null; // SlashMenu instance (lazy)
    // P5 command palette — the Cmd-P launcher (lazy, created on first Mod-p). UNLIKE
    // the slash/[[ /# popups it is NOT text-triggered: it opens on the keyboard
    // shortcut and filters the WHOLE static command registry by a fuzzy match. Gated
    // on `this._editable` (read mode runs no commands). Mutually exclusive with the
    // three text-triggered popups (see _onKeyDown: Mod-p no-ops when any is open). On
    // a pick it runs the command's run(editor), closes, and refocuses the editor; the
    // command then emits the normal bp-canvas-ops via the onUpdate path.
    this._palette = null; // CommandPalette instance (lazy)
    // P5 MARKDOWN SOURCE-MODE — the Obsidian "source mode" analog. "rich" = the
    // ProseMirror editor (this._mount) is live; "source" = the rich editor is
    // hidden and a Markdown <textarea> (this._sourceEl) owns input. The toggle
    // (Mod-Shift-m or the "Toggle Markdown source" palette command) flips between
    // them. Both never co-exist; the textarea owns ALL input while in source mode,
    // so the [[ / # / slash / palette / format-bubble seams no-op there.
    this._mode = "rich"; // "rich" | "source"
    this._sourceEl = null; // the <textarea class="bp-canvas-source"> (source mode only)
    // The blocks the source markdown was serialized FROM (a deep clone captured on
    // ENTER). On EXIT the markdown is parsed back to blocks whose ids are REALIGNED
    // against this baseline so a surviving block keeps its id → runToOps emits a
    // PATCH (not remove+insert) for an in-place text edit. The NO-EDIT exit short-
    // circuits before any of this (md unchanged → restore untouched, ZERO ops).
    this._sourceBaselineBlocks = null;
    // The exact markdown shown on ENTER (blocksToMarkdown of the baseline). The
    // NO-EDIT guard compares the textarea value against THIS string verbatim: equal
    // → the toggle is provably op-free (no re-parse, no setContent, no caret churn).
    this._sourceOriginalMd = "";
    // Bound listener for the textarea's own Mod-Shift-m (toggle BACK to rich) +
    // Escape — kept as a field so the exact identity is removed on cleanup.
    this._onSourceKeyDown = null;
  }

  connectedCallback() {
    if (this._editor) return; // double-mount guard

    ensureStyles();

    // Upgrade-safe property reclaim: a host may set `el.blocks = [...]` (or, for
    // P4, `el.wikilinkSource = …` / `el.tagSource = …`) BEFORE the custom-element
    // definition upgrades this node; that assignment lands as a plain own-property
    // shadowing the prototype accessor. Delete + re-assign so it flows back through
    // the real setter. Mirrors ../index.js.
    this._upgradeProperty("blocks");
    this._upgradeProperty("acknowledgedSaves");
    this._upgradeProperty("wikilinkSource");
    this._upgradeProperty("tagSource");

    // Default true; only the literal string "false" disables editing. Mount-time
    // read is authoritative — attributeChangedCallback handles later toggles.
    this._editable = this.getAttribute("editable") !== "false";

    // The contenteditable element the WC owns. TipTap mounts onto it. Same body
    // class as ../index.js so the shared stylesheet styles the canvas identically.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);

    // ONE Editor over the WHOLE run. Mirrors ../index.js's Editor config; the
    // KEY differences: (1) content is runToTiptap(this._blocks) — MANY top-level
    // blocks, not blockToTiptap of one; StarterKit's doc is block+, so the
    // siblings are native and cross-block caret/selection/split/merge come free.
    // (2) BpAttrs is in the extension list so getJSON() preserves bpId/bpType.
    // pdd-t14: lexical handle for the lock-veto plugin below — `this` (the WC
    // host) is not reachable from inside Extension.create's plugin factory.
    const host = this;

    this._editor = new Editor({
      element: this._mount,
      editable: this._editable,
      extensions: [
        // pdd-t2/t14: the doctrine template-lock veto as a REAL ProseMirror
        // plugin. `filterTransaction` is a PLUGIN-spec option — as an
        // editorProps entry it is silently ignored by the view (found live in
        // the browser polish pass: Enter in the locked title split the doc).
        // Returning false drops the whole tx: no local mutation, no op, no
        // flash — the calm no-op the doctrine demands. Content edits inside a
        // locked block pass; papers without locked blocks are untouched (D3).
        // data-locked-tail is read LIVE off the host so hook/upgrade ordering
        // can never race Editor construction.
        Extension.create({
          name: "bpLockVeto",
          addProseMirrorPlugins: () => [
            new Plugin({
              filterTransaction: (tr, state) =>
                // Programmatic applies (initial seed via the blocks setter,
                // foreign-echo setContent, ghost-slot materialization via
                // _programmaticApply) legitimately grow/replace the doc — the veto
                // guards USER edits only (found live: the plugin vetoed its own
                // initial content seed on locked-tail runs). pdd-t20c: the
                // constraint veto rides the SAME exemption + the SAME plugin,
                // reading declarations LIVE off data-constraints.
                host._programmaticApply === true ||
                (!transactionVetoesLock(
                  tr,
                  state,
                  host.getAttribute("data-locked-tail") === "true",
                ) &&
                  !transactionVetoesConstraints(
                    tr,
                    state,
                    parseConstraints(host.getAttribute("data-constraints")),
                  ) &&
                  // Gyldendal parity E1: a FIELD canvas carries the field's declared
                  // vocabulary on data-vocabulary (twin of data-constraints). A user
                  // edit that would introduce an out-of-vocabulary node / heading
                  // level / list kind / mark is a calm no-op; the server refuses the
                  // same by name. Absent attribute → nothing vetoed (paper canvas
                  // byte-unchanged).
                  !transactionVetoesVocabulary(
                    tr,
                    state,
                    parseVocabulary(host.getAttribute("data-vocabulary")),
                  )),
            }),
          ],
        }),
        StarterKit.configure({
          // Same as ../index.js: heading levels 1–3, lists, history on.
          heading: { levels: [1, 2, 3] },
          // Disable StarterKit's built-in horizontalRule so ONLY the canvas
          // `divider` node owns the <hr> parse rule + insert command. Otherwise
          // two nodes claim <hr> (ambiguous on paste/setContent) and
          // setHorizontalRule would insert a `horizontalRule` that runToOps —
          // which only knows `divider` as a canvas atom — mis-diffs as a paragraph.
          horizontalRule: false,
          // S3.3: disable StarterKit's built-in codeBlock NODE (name:'codeBlock',
          // parses <pre> with preserveWhitespace:'full') so ONLY the canvas
          // `bpCode` node owns the <pre> parse rule. Same lesson as horizontalRule:
          // two nodes claiming <pre> is ambiguous on paste/setContent, and
          // setCodeBlock would insert a `codeBlock` runToOps — which knows `code`
          // (the bpCode node) as a canvas attr-atom — mis-diffs as unknown. NOTE we
          // do NOT disable the inline `code` MARK (extension-code, parses <code>) —
          // the canvas KEEPS it so inline-code round-trips (convert.js inline path).
          codeBlock: false,
        }),
        // Link mark — same config as ../index.js so existing `link` inline nodes
        // render/edit and the format bubble's link button works.
        Link.configure({ openOnClick: false, autolink: false }),
        // Empty-block ghost text — same contract as ../index.js. includeChildren
        // :false so one placeholder shows on the focused top-level textblock only.
        Placeholder.configure({
          includeChildren: false,
          showOnlyWhenEditable: true,
          placeholder: ({ node }) => {
            if (node.type.name === "heading") {
              return PLACEHOLDER.heading(node.attrs && node.attrs.level);
            }
            return PLACEHOLDER.paragraph;
          },
        }),
        // Smart typography — parity with ../index.js. A prose run holds no code
        // block, so nothing to exclude.
        Typography,
        // Internal-link marks — schema registration only (see import note). This
        // keeps existing inline wikilink/blockref/tag marks round-tripping; the
        // [[ / # autocomplete UI is OUT of S1.
        Wikilink,
        Blockref,
        Tag,
        Valueref,
        // THE make-or-break: declares bpId/bpType on the block nodes so the run's
        // ids survive the setContent->getJSON round-trip runToOps depends on.
        BpAttrs,
        // S3: the divider atom node — a non-prose leaf living INSIDE the canvas
        // document. Registers the `divider` node type (toDOM <hr>, bpId/bpType
        // attrs) so runToTiptap's { type:"divider" } node mounts as an atom and
        // getJSON() round-trips it (instead of dropping it as an unknown node).
        Divider,
        // S3.2: the callout content node + its node-view. Registers the `callout`
        // node type (content:"inline*", tone/title/collapsible/collapsed data-*
        // attrs, a NodeView rendering tone-framed chrome around a contentDOM body)
        // so runToTiptap's { type:"callout", content:[…] } node mounts with an
        // editable body that JOINS the run, and getJSON() round-trips body+chrome.
        Callout,
        // STEP 4: the card WIDGET node + its node-view. Registers the `bpCard` node
        // type (content:"inline*" body, title/tone/media/action data-* attrs, a
        // NodeView painting the reader's bp-card chrome around a contentDOM body) so
        // runToTiptap's { type:"bpCard", content:[…] } node mounts with an editable
        // body that JOINS the run, and getJSON() round-trips body+chrome.
        Card,
        // The notes-grid split: the `note` WIDGET node + its node-view. Registers the
        // `note` node type (content:"inline*" body, label/lead data-* attrs, a NodeView
        // with two <input> islands around a contentDOM body) so runToTiptap's
        // { type:"note", content:[…] } node mounts with an editable body that JOINS the
        // run + label/lead islands, and getJSON() round-trips body+label+lead.
        Note,
        // The stage WIDGET node + its node-view. Registers the `bpStage` node (atom,
        // attrs kind/title/detail/files/source via data-*, a NodeView rendering a cell of
        // native inputs + a source toggle in a stopEvent/ignoreMutation island so PM never
        // turns a keystroke into a transaction) so runToTiptap's { type:"bpStage",
        // attrs:{…} } node mounts as an editable pipeline-node twin whose scalars round-
        // trip through getJSON() and emit a patch-block on edit. ONE bpType; NO StarterKit
        // collision. bpStage parses ONLY its own <div data-bp-type='stage'>. See
        // ./stage-node.js.
        Stage,
        // S3.3: the code attr-atom node + its node-view. Registers the `bpCode`
        // node type (atom, attrs value/lang via data-*, a NodeView rendering a
        // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation
        // so PM never turns code keystrokes into transactions) so runToTiptap's
        // { type:"bpCode", attrs:{value,lang?} } node mounts as an editable code
        // block whose value/lang round-trip through getJSON(). StarterKit's
        // codeBlock is disabled above so only this node owns <pre>.
        Code,
        // S3.4: the diagram attr-atom node + its node-view. Registers the `bpDiagram`
        // node type (atom, attrs source/caption via data-*, a NodeView rendering a
        // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation so
        // PM never turns Mermaid-source keystrokes into transactions) so runToTiptap's
        // { type:"bpDiagram", attrs:{source,caption?} } node mounts as an editable
        // diagram block whose source/caption round-trip through getJSON(). MIRRORS the
        // code node; UNLIKE code there is no StarterKit node to disable (StarterKit
        // ships no `diagram` node), and bpDiagram parses ONLY its own
        // <pre data-bp-type='diagram'> (it does NOT claim the bare <pre> the code node
        // already owns).
        Diagram,
        // S3.5 + run-splitter tail: the field CONTROL-ATOM node + its node-view.
        // Registers the SINGLE `bpField` node type serving ALL 9 field-* kinds — the 7
        // NATIVE controls (field-string / field-slug / field-text / field-boolean /
        // field-select / field-datetime / field-color), edited by a NATIVE control
        // (input / textarea / checkbox / select / datetime-local / color), PLUS the 2
        // PICKER fields (field-image → bp-media-picker, field-reference →
        // bp-reference-picker), edited by the EXISTING client-side picker WC. Both
        // variants are atoms whose VALUE rides an attr and whose edit surface is wrapped
        // in a stopEvent/ignoreMutation island so PM never turns its keystrokes / toggles
        // / selections / picker-fetches into transactions. On change the value is COERCED
        // exactly like the per-block BarkparkFieldBlockBridge — native: boolean →
        // control.checked, else control.value; picker: identity on the bp-change
        // detail.value — so a canvas field edit persists IDENTICALLY to the per-block
        // path. The pickers are CLIENT-SIDE (no LiveView / pushEvent dependency), so they
        // mount inside the node-view exactly like a native control. bpField parses ONLY
        // its own <div data-bp-type='field'>. Only the nested-structure fields
        // (composite / arrayOf / codelist / localizedText / section) remain bpOpaque.
        Field,
        // editable-action: the CTA `action` CONTROL-ATOM node + its node-view. Registers
        // the `bpAction` node (atom, attrs href/label/priority via data-*, a NodeView
        // rendering a live bp-button preview + label/href/priority native controls in a
        // stopEvent/ignoreMutation island so PM never turns a keystroke/select into a
        // transaction) so runToTiptap's { type:"bpAction", attrs:{href,label,priority} }
        // node mounts as an editable CTA whose attrs round-trip through getJSON() and
        // emit a COARSE patch-block on edit. ONE bpType; NO StarterKit collision. bpAction
        // parses ONLY its own <div data-bp-type='action'>. See ./action-node.js.
        Action,
        // S3.6: the sheet + embed READ-ONLY ATOM nodes + their node-views. Registers
        // the `bpSheet` and `bpEmbed` node types (atom, NO edit surface; the WHOLE
        // block rides the bpBlock attr via data-bp-block, a NodeView rendering a
        // read-only chip — the sheet summary "Sheet · <ref> · NxM"; the embed
        // reference "↪ <target>" — with contentEditable false + stopEvent/
        // ignoreMutation so PM never turns a click into a transaction) so runToTiptap's
        // { type:"bpSheet"|"bpEmbed", attrs:{bpBlock} } node mounts as a read-only
        // reference that round-trips the block VERBATIM through getJSON() and emits ZERO
        // value/content ops. UNLIKE bpField, nothing is edited; they carry the whole
        // block, not just a value. Each parses ONLY its own <div data-bp-type='sheet'>
        // / <div data-bp-type='embed'>. After S3.6 sheet/embed no longer split a run —
        // only field-image/field-reference (pickers) remain boundaries.
        Sheet,
        Embed,
        // pdd-t8 (fleet-in-canvas): the component-fleet SERVER-PAINTED read-only
        // atom. Registers the SINGLE `bpFleet` node (atom, NO edit surface; the
        // WHOLE block rides the bpBlock attr via data-bp-block) for EVERY fleet kind
        // (tasks / task-board / roadmap / cards / pipeline / notes / status-legend /
        // form / asciicast / …, discriminated by bpType). Its node-view paints an
        // empty `.bp-paper-surface` hole keyed by data-bp-fleet-id; the Studio hook
        // (root.html.heex `bp:block-html`) injects the reader's OWN server-rendered
        // HTML into that hole (rule 3 / D8 — one producer, byte for byte), with a
        // loading chip until it arrives. Structurally identical to Sheet/Embed: emits
        // ZERO value/content ops, participates only in structural ops. bpFleet parses
        // ONLY its own <div data-bp-fleet='true'>.
        Fleet,
        // editable-figure: the SERVER-PAINTED read-only-child + editable-caption ATOM
        // (`bpFigure`). Registers the single node so runToTiptap's { type:"bpFigure",
        // attrs:{caption, bpChild} } mounts as a reader <figure> whose CHILD paint hole
        // (data-bp-fleet-id/body, reusing the shipped bp:block-html hook — ZERO hook
        // change) is filled server-side with the child's OWN reader HTML, and whose
        // <figcaption> input is the SOLE edit affordance (patch-block{caption}).
        // Structurally an atom (holds no PM children → cannot nest another canvas node
        // by construction). Parses ONLY its own <figure data-bp-type='figure'>. See
        // ./figure-node.js.
        Figure,
        // live-data task-list: the EDITABLE-QUERY + server-painted-ROWS atom
        // (`bpTaskList`). Registers the single node so runToTiptap's { type:"bpTaskList",
        // attrs:{query, title, config} } mounts as a widget whose ROWS paint hole
        // (data-bp-fleet-id/body, reusing the shipped bp:block-html hook — ZERO hook
        // change) is filled server-side with the reader's OWN resolved-rows HTML
        // (query → TaskResolver.preview → apply_preview → render_block), and whose
        // query/title <input> islands are the edit affordance (patch-block{query}).
        // MOUNTS ONLY for a query-carrying task-list; a snapshot-only task-list falls
        // through to the read-only bpFleet atom (the additive discriminant). Parses
        // ONLY its own <div data-bp-tasklist='true'>. See ./task-list-node.js.
        TaskList,
        // Article-chrome ROLE prose nodes (eyebrow / byline / ingress / pullquote).
        // Registers the four node types so runToTiptap's { type:"eyebrow"|… } nodes
        // mount as styled prose (a `<p class="bp-role-*">` matching the reader) and
        // getJSON() round-trips them (an unregistered type is dropped by PM). Each
        // parses ONLY its own <p data-bp-type='<role>'> so paragraph keeps the bare
        // <p>; eyebrow/byline are plain-string surfaces (content:"text*", marks:""),
        // ingress/pullquote inline surfaces (content:"inline*"). NO node-view — no
        // chrome to paint. See ./role-nodes.js.
        Eyebrow,
        Byline,
        Ingress,
        Pullquote,
        // editable table: the four nested nodes (bpTable > bpTableRow >
        // bpTableHeaderCell|bpTableCell). Registers the container + row/cell types so
        // runToTiptap's { type:"bpTable", content:[rows…] } tree mounts with editable
        // inline cell bodies that JOIN the run, and getJSON() round-trips the grid.
        // The bpTable node-view paints the reader <table> + row/col chrome around a
        // <tbody> contentDOM; rows/cells are plain nodes (renderHTML content holes, no
        // node-view). NO StarterKit node is disabled (no table/tr/td/th collision).
        BpTable,
        BpTableRow,
        BpTableCell,
        BpTableHeaderCell,
        // S10: the columns CONTAINER nodes (bpColumns > bpColumn+ > child). Registers
        // the three node types so runToTiptap's { type:"bpColumns", content:[bpColumn…] }
        // node mounts as an editable grid whose columns hold real editable prose/divider
        // (any non-first-class child rides a read-only bpColumnAtom), and getJSON()
        // round-trips the whole nested tree. bpColumns' `--bp-cols:N` + the reader's
        // .bp-cols grid CSS (ancestor .bp-paper-surface cascade) paint the layout; NO
        // StarterKit collision. Order after the role nodes; the doc's block+ accepts
        // bpColumns (group:"block"), never a bare bpColumn/bpColumnAtom. See
        // ./columns-node.js.
        Columns,
        Column,
        ColumnAtom,
        // The section CONTAINER node + its node-view. Registers `bpSection`
        // (content: the canvas child roster MINUS bpSection PLUS bpOpaque; a NodeView
        // rendering two `bp-hr` rules + an editable bold title around a contentDOM
        // block+ body) so a top-level section block mounts as an editable container
        // whose nested children JOIN the doc and round-trip through getJSON. isolating
        // seals the boundary (Backspace/select-all stay inside); the content
        // expression FORBIDS bpSection-in-bpSection (v1 no-nested-container). See
        // ./section-node.js.
        Section,
        // The mountable bpOpaque verbatim carry. Registers `bpOpaque` (atom, bpBlock
        // whole-block attr, a read-only chip) so run-convert's opaque projection —
        // a section's non-canvas child (nested section / composite / codelist / …) —
        // MOUNTS as a read-only carry inside a bpSection body instead of being lifted
        // out by PM. See ./opaque-node.js.
        Opaque,
        // The terminal CONTAINER nodes (bpTerminal > body children + bpTerminalAtom).
        // Registers the container + verbatim-carrier atom so runToTiptap's
        // { type:"bpTerminal", content:[child…] } node mounts as an editable body wrapped
        // in reader-shaped chrome (title bar / live badge / footer), and getJSON()
        // round-trips the whole nested tree. bp-term* reader classes + paper-surface.css
        // (ancestor .bp-paper-surface cascade) paint the frame; NO StarterKit collision.
        // The doc's block+ accepts bpTerminal (group:"block"), never a bare bpTerminalAtom.
        // See ./terminal-node.js.
        Terminal,
        TerminalAtom,
      ],
      content: runToTiptap(this._blocks),
      editorProps: {
        // P4: while a `[[` / `#` / `/` popup is open it OWNS the navigation keys
        // (↑/↓/Enter/Tab/Esc) — _onKeyDown returns true so ProseMirror does not also
        // act on them (Enter must PICK the active item, NOT split the doc, while a
        // menu is open). When ALL popups are closed every keystroke falls through to
        // TipTap unchanged, so cross-block caret / split / merge are untouched.
        handleKeyDown: (_view, event) => this._onKeyDown(event),
        // pdd-t2: the doctrine template-lock veto. Reject any transaction that
        // deletes or moves a locked mandated block (returning false from
        // filterTransaction drops the whole tx). Content edits inside a locked
        // block pass. Additive: no-op on papers without locked blocks (D3).
        // data-locked-tail (stamped by the BarkparkPaperCanvas hook when the
        // block AFTER this run in the full document is locked — e.g. the
        // featured image right after the title run) additionally vetoes any
        // run GROWTH, since a new node here would displace that locked
        // follower. Read live off the attribute so hook/upgrade ordering can
        // never race the Editor construction.
      },
      onUpdate: () => {
        this._scheduleEmit();
        // P4 mutual-exclusion chain (ported from ../index.js's onUpdate ~174-193):
        // callout shorthand FIRST → wikilink → tag → slash. AT MOST ONE fires per
        // mutation. The callout `> [!type]` shorthand runs first and short-circuits
        // the rest when it consumes the update (it REPLACES the paragraph with a
        // bpCallout node rather than opening a popup); its leading '>' is already
        // disjoint from '[[' / '#' / '/', but the explicit `consumed` gate makes the
        // contract code-enforced. When NOT consumed, the three popups chain by
        // priority: wikilink, then tag, then slash — whichever opens forces the
        // others shut so a stale popup never lingers (triggers disjoint by leading
        // token "[[" vs "#" vs "/", but the gate makes the single-popup invariant
        // code-enforced rather than incidental).
        const consumed = this._maybeCalloutShorthand();
        if (!consumed) {
          if (this._maybeWikilink()) {
            this._closeTag();
            this._closeSlash();
          } else if (this._maybeTag()) {
            this._closeSlash();
          } else {
            this._maybeSlash();
          }
        }
        if (this._bubble) this._bubble.update();
      },
      // Selection-only changes (drag-select, shift-arrow, cross-block click)
      // don't fire onUpdate — drive the format bubble from selectionUpdate too.
      // This is what makes the bubble track a MULTI-BLOCK selection.
      onSelectionUpdate: () => {
        if (this._bubble) this._bubble.update();
      },
      onBlur: () => { if (this._bubble) this._bubble.update(); },
      onFocus: () => { if (this._bubble) this._bubble.update(); },
    });

    // Selection format toolbar — REUSED verbatim from ../format-bubble.js. It is
    // agnostic to how many blocks the editor holds: it floats on any non-empty
    // text selection, including one spanning multiple blocks. Skipped in read
    // mode; every consumer is `if (this._bubble)` guarded.
    if (this._editable) {
      this._bubble = new FormatBubble({ editor: this._editor });
    }

    // Lifecycle: one-shot bubbling/composed signal a host hook can await —
    // mirrors ../index.js's bp-ready.
    this.dispatchEvent(
      new CustomEvent("bp-ready", {
        detail: { blockCount: this._blocks.length },
        bubbles: true,
        composed: true,
      }),
    );
  }

  attributeChangedCallback(name, _old, val) {
    if (name === "editable") {
      this._editable = val !== "false";
      if (this._editor) this._editor.setEditable(this._editable);
    }
  }

  disconnectedCallback() {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    // S4a: drop any queued external-edit echo + its release listeners.
    this._clearPendingServerBlocks();
    // P4: destroy both autocomplete popups (each owns a document.body element +
    // document-level pointer/keydown listeners — see WikilinkMenu.destroy()).
    if (this._wikilink) {
      this._wikilink.destroy();
      this._wikilink = null;
    }
    if (this._tag) {
      this._tag.destroy();
      this._tag = null;
    }
    // P4 S-slash: destroy the slash popup (owns a document.body element + document-
    // level pointer/keydown listeners — see SlashMenu.destroy()).
    if (this._slash) {
      this._slash.destroy();
      this._slash = null;
    }
    // P5: destroy the command palette (a SlashMenu subclass — owns a document.body
    // element + document-level pointer/keydown listeners + its own query <input>).
    if (this._palette) {
      this._palette.destroy();
      this._palette = null;
    }
    if (this._bubble) {
      this._bubble.destroy();
      this._bubble = null;
    }
    // P5 source-mode: tear down the markdown textarea + its keydown listener if the
    // element disconnects while in source mode (so neither the node nor the listener
    // leaks). Reset the mode bookkeeping; the editor.destroy() below frees the rest.
    this._teardownSourceEl();
    this._sourceBaselineBlocks = null;
    this._sourceOriginalMd = "";
    this._mode = "rich";
    if (this._editor) {
      this._editor.destroy();
      this._editor = null;
    }
  }

  // Synchronously commit any user input that is still local to the Web Component.
  // Hosts call this before replacing edit mode with reader mode, then wait for the
  // resulting bp-canvas-ops acknowledgement before pushing the mode toggle.
  //
  // Returns true only when this call dispatched a non-empty operation batch. The
  // pending debounce/source state is consumed before dispatch, so an immediate
  // repeated call is a no-op even while the server echo is still in flight.
  flushPendingChanges() {
    if (!this._editor || !this._editable) return false;

    if (this._mode === "source") {
      return this._exitSourceMode();
    }

    // Node-view controls (code, captions, field inputs, and component editors)
    // debounce their own attributes before they reach ProseMirror. Commit those
    // islands first; their transactions schedule the canvas batch below.
    this.querySelectorAll("[data-bp-type]").forEach((node) => {
      node.dispatchEvent(new CustomEvent("bp-flush-node"));
    });

    if (!this._debounceTimer) return false;
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    return this._emitOps();
  }

  // Synchronous host seam for navigation / beforeunload guards. A debounced
  // transaction is unsaved before bp-canvas-ops exists; source-mode text and
  // edits queued behind an acknowledgement must also survive an attempted exit.
  hasPendingChanges() {
    const sourceChanged =
      this._mode === "source" && this._sourceEl &&
      this._sourceEl.value !== this._sourceOriginalMd;
    return Boolean(
      sourceChanged || this._debounceTimer || this._inflightOps ||
      this._dirtyWhileInflight
    );
  }

  // Explicit conflict resolution seam. Normal echoes never erase newer local
  // edits; this path is reserved for the user's deliberate "Use latest" action.
  resolveConflictWithServerBlocks(blocks) {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    this._inflightOps = null;
    this._dirtyWhileInflight = false;
    this._awaitingOwnEchoes = [];
    this._clearPendingServerBlocks();
    const next = Array.isArray(blocks) ? blocks : [];
    this._blocks = deepCloneBlocks(next);
    if (!this._editor) return;
    this._programmaticApply = true;
    try {
      this._applyExternalContent(next);
    } finally {
      this._programmaticApply = false;
    }
  }

  _scheduleEmit() {
    if (!this._editable) return; // read mode emits no ops
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      this._debounceTimer = null;
      this._emitOps();
    }, DEBOUNCE_MS);
  }

  // Diff the live doc against the current baseline run and, if anything changed,
  // emit the ordered op array S0 produces. The diff is runToOps VERBATIM — the
  // canvas is a thin shell over S0's PURE projector/op-mapper.
  //
  // `_blocks` advances when the bridge acknowledges the one in-flight batch, so
  // the next dispatch is incremental even if its server echo arrives later.
  _emitOps() {
    if (!this._editor) return false;
    const nextDoc = normalizeCanvasDoc(this._editor.getJSON());
    const nextBlocks = docToBlocks(nextDoc);
    const stableDoc = runToTiptap(nextBlocks);

    // runToOps mints ids for null-id nodes. Materialize those ids in the live
    // document before another edit can diff, otherwise each cumulative diff
    // invents a different id for the same inserted paragraph.
    this._stampMaterializedIds(stableDoc);
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }

    if (this._inflightOps) {
      this._dirtyWhileInflight = true;
      return false;
    }

    const ops = runToOps(this._blocks, stableDoc, { preserveNewIds: true });
    return this._dispatchOps(ops, nextBlocks);
  }

  // Dispatch one op array for the LiveView hook to fold and retain its after-state
  // until the hook acknowledges the exact sequence. A zero-length array is a no-op.
  _dispatchOps(ops, nextBlocks = null) {
    if (!ops || !ops.length) return false;
    const seq = this._acknowledgedSaves ? ++this._opsSeq : undefined;
    if (this._acknowledgedSaves) {
      this._inflightOps = {
        seq,
        ops,
        afterBlocks: deepCloneBlocks(nextBlocks || this._blocks),
        echoSeen: false,
      };
    }
    this.dispatchEvent(
      new CustomEvent("bp-canvas-ops", {
        detail: seq == null ? { ops } : { ops, seq },
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  }

  // Called by the LiveView bridge after the exact `paper-ops` request settles.
  // Failure retains the batch so the bridge can retry it byte-for-byte. Success
  // advances the local baseline and releases any edits made while it was pending.
  acknowledgeOps(seq, saved) {
    if (!this._acknowledgedSaves) return false;
    const current = this._inflightOps;
    if (!current || current.seq !== seq) return false;
    if (saved !== true) return false;

    this._blocks = deepCloneBlocks(current.afterBlocks);
    if (!current.echoSeen) {
      this._awaitingOwnEchoes.push(deepCloneBlocks(current.afterBlocks));
    }
    this._inflightOps = null;
    const dirty = this._dirtyWhileInflight;
    this._dirtyWhileInflight = false;
    if (dirty) this._emitOps();
    return true;
  }

  // ── P4 autocomplete: keyboard routing + caret rect ─────────────────────────
  //
  // Keyboard handler installed via editorProps.handleKeyDown. Only ACTS when a
  // popup is open; otherwise returns false so TipTap handles the key (so Enter
  // still splits a block, ArrowUp still moves the caret, etc.). The three popups
  // (wikilink / tag / slash) are mutually exclusive — at most one branch ever owns
  // the keystroke. Ported from ../index.js:_onKeyDown (all three branches).
  _onKeyDown(event) {
    // P5 MARKDOWN SOURCE-MODE — Mod-Shift-m (Cmd-Shift-M on mac / Ctrl-Shift-M
    // elsewhere) ENTERS source mode from the rich editor. Detected FIRST, before the
    // palette/popup branches: it is a deliberately FREE combo (Mod-p = palette, Mod-b
    // = bold, Mod-i = italic, Mod-Shift-m collides with nothing in StarterKit or the
    // canvas). Only when editable. preventDefault + return true so ProseMirror does
    // not also act on the key. The toggle-BACK (source → rich) is handled by the
    // textarea's own keydown listener (_onSourceKeyDown), since while in source mode
    // ProseMirror's handleKeyDown never fires (the textarea owns input).
    if (
      this._editable &&
      (event.metaKey || event.ctrlKey) &&
      event.shiftKey &&
      !event.altKey &&
      (event.key === "m" || event.key === "M")
    ) {
      event.preventDefault();
      this.toggleSourceMode();
      return true;
    }

    // P5 command palette — Mod-p (Cmd-P on mac / Ctrl-P elsewhere) OPENS the palette.
    // Detected here, BEFORE the popup-routing branches, so the mutual-exclusion guard
    // can see whether any text-triggered popup is open. NOT shift (Cmd-Shift-P stays
    // free). Only when editable, and only when NO other popup ([[ / # / slash) is open
    // — if one is, Mod-p no-ops (mutual exclusion). On open we preventDefault (so the
    // browser's own Ctrl-P print / Cmd-P does not fire) and return true (ProseMirror
    // does not also act on the key).
    if (
      this._editable &&
      (event.metaKey || event.ctrlKey) &&
      !event.shiftKey &&
      !event.altKey &&
      (event.key === "p" || event.key === "P")
    ) {
      const anyPopupOpen =
        (this._wikilink && this._wikilink.isOpen()) ||
        (this._tag && this._tag.isOpen()) ||
        (this._slash && this._slash.isOpen());
      // If the palette is ALREADY open, Mod-p closes it (toggle); else open it — but
      // never co-open alongside a text-triggered popup.
      if (this._palette && this._palette.isOpen()) {
        event.preventDefault();
        this._dismissPalette();
        return true;
      }
      if (!anyPopupOpen) {
        event.preventDefault();
        this._openPalette();
        return true;
      }
      // A text-triggered popup owns the moment — no-op (do NOT co-open). Still
      // preventDefault + return true so the browser's Ctrl-P print never fires and
      // ProseMirror does not act on the key; the open popup keeps its keystroke.
      event.preventDefault();
      return true;
    }

    // While the palette is open it OWNS the nav keys (↑/↓/Enter/Tab/Esc) — same
    // contract as the three text-triggered popups. Checked first among the routing
    // branches; it is mutually exclusive with them (only one popup ever open).
    if (this._palette && this._palette.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._palette.move(1);
          return true;
        case "ArrowUp":
          this._palette.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._palette.choose();
          return true;
        case "Escape":
          this._dismissPalette();
          return true;
        default:
          return false;
      }
    }

    if (this._wikilink && this._wikilink.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._wikilink.move(1);
          return true;
        case "ArrowUp":
          this._wikilink.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._wikilink.choose();
          return true;
        case "Escape":
          this._dismissWikilink();
          return true;
        default:
          return false;
      }
    }

    // `#` tag menu owns the nav keys while open — same contract as the wikilink
    // branch above. The two are mutually exclusive (only one ever open), so the
    // order here is immaterial, but tag follows wikilink for symmetry.
    if (this._tag && this._tag.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._tag.move(1);
          return true;
        case "ArrowUp":
          this._tag.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._tag.choose();
          return true;
        case "Escape":
          this._dismissTag();
          return true;
        default:
          return false;
      }
    }

    // `/` slash menu owns the nav keys while open — same contract. Mutually
    // exclusive with the two autocompletes (only one ever open), so order is
    // immaterial; slash follows tag for symmetry with onUpdate's chain. Enter must
    // pick the active item (NOT split the doc) while the menu is open.
    if (this._slash && this._slash.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._slash.move(1);
          return true;
        case "ArrowUp":
          this._slash.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._slash.choose();
          return true;
        case "Escape":
          this._dismissSlash();
          return true;
        default:
          return false;
      }
    }

    return false;
  }

  // The DOMRect of the current caret, used to position the popup at the cursor.
  // Ported from ../index.js:_caretRect (the canvas had no such helper — added
  // here for the popups). Falls back to the mount rect if coordsAtPos throws.
  _caretRect() {
    try {
      const { from } = this._editor.state.selection;
      const coords = this._editor.view.coordsAtPos(from);
      return {
        left: coords.left,
        top: coords.top,
        bottom: coords.bottom,
      };
    } catch (_e) {
      const r = this._mount.getBoundingClientRect();
      return { left: r.left, top: r.top, bottom: r.bottom };
    }
  }

  // ── P4 `[[` wikilink autocomplete ──────────────────────────────────────────
  //
  // Obsidian-parity inline page-link picker, ported VERBATIM from ../index.js.
  // Studio-only by construction: gated on `this._editable` (read-mode never runs
  // onUpdate) AND on an injected `this._wikilinkSource` (unset → never opens). On
  // each onUpdate we re-run the PURE parseOpenWikilink seam against the BLOCK-LOCAL
  // text + caret offset of the current run block; an open trigger opens/refreshes
  // the menu at the caret and fires the async source. On a pick we replace the
  // typed "[[query" span with the chosen title carrying a `wikilink` mark — which,
  // in the canvas, makes runToOps emit a patch-block for THAT block (the existing
  // prose patch path). Returns true iff the menu is (now) open, so onUpdate can
  // force the tag popup shut (mutual exclusion).
  _maybeWikilink() {
    if (!this._editable || !this._wikilinkSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame. In the canvas
    // doc `$from.parent` is the CURRENT run block's textblock (a paragraph —
    // including the one nested inside a list item), so its `textContent` pairs
    // exactly with `parentOffset`. Using getText() here would join EVERY block in
    // the run with "\n\n" and desync from the block-local offset — so a `[[` typed
    // in the 2nd-or-later block would never open. parseOpenWikilink's contract is
    // block-local text. This is what makes the trigger frame-correct in the
    // multi-block canvas exactly as it is in the per-block editor.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenWikilink(blockLocalText, caretOffset);
    if (!hit) {
      this._closeWikilink();
      return false;
    }

    // Open (or refresh, as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT position
    // (selection.from), not the block-local offset hit carries.
    this._openWikilink(this._caretRect(), hit.query);
    this._wlRange = wikilinkReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD: each open/keystroke bumps _wlSeq; a
    // resolved batch is dropped unless it is still the latest request AND the menu
    // is still open — so an out-of-order or post-close response is ignored.
    const seq = ++this._wlSeq;
    Promise.resolve(this._wikilinkSource(hit.query))
      .then((list) => {
        if (seq !== this._wlSeq || !this._wikilink || !this._wikilink.isOpen()) {
          return;
        }
        this._wikilink.setResults(Array.isArray(list) ? list : []);
      })
      .catch(() => {});
    return true;
  }

  _openWikilink(rect, query = "") {
    if (!this._wikilink) {
      this._wikilink = new WikilinkMenu({
        onChoose: (c) => this._chooseWikilink(c),
        onDismiss: () => this._dismissWikilink(),
      });
    }
    this._wikilink.open(rect, query);
  }

  _closeWikilink() {
    if (this._wikilink && this._wikilink.isOpen()) this._wikilink.close();
  }

  // User picked a candidate: replace the typed "[[query" span with the chosen
  // title carrying a `wikilink` mark { target: title, docId: id }, plus a trailing
  // UNMARKED space so typing continues OUTSIDE the link (the mark is
  // inclusive:false, but the space guarantees it across browsers). The pinned
  // `docId` is the picked paper's EXACT id. The marked-text insertion mutates the
  // run block → runToOps emits a patch-block for that block. _wlRange was captured
  // in _maybeWikilink at the moment the menu opened/refreshed.
  _chooseWikilink(candidate) {
    const range = this._wlRange;
    if (!range) {
      this._closeWikilink();
      return;
    }
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: candidate.title,
          marks: [{ type: "wikilink", attrs: { target: candidate.title, docId: candidate.id } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeWikilink();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "[[query" in place —
  // the user may want to keep editing it. Mirrors ../index.js:_dismissWikilink.
  _dismissWikilink() {
    this._closeWikilink();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async page
  // search: `el.wikilinkSource = (query) => Promise<[{ title, id, type }]>`. Unset
  // → _maybeWikilink early-returns, so the popup NEVER opens (graceful no-op for
  // the harness without a source and the read-mode web embed). Mirrors ../index.js.
  set wikilinkSource(fn) {
    this._wikilinkSource = fn;
  }

  get wikilinkSource() {
    return this._wikilinkSource;
  }

  // ── P4 `#` tag autocomplete ────────────────────────────────────────────────
  //
  // Obsidian-parity inline tag picker — the `#` analogue of the `[[` wikilink
  // popup, sharing the WikilinkMenu DOM via a thin adapter. Ported VERBATIM from
  // ../index.js. Studio-only by construction: gated on `this._editable` AND on an
  // injected `this._tagSource` (unset → never opens). On each onUpdate we re-run
  // the PURE parseOpenTag seam (block-local text + caret offset); an open trigger
  // opens/refreshes the menu at the caret and fires the async source. The string[]
  // of tag names is mapped to WikilinkMenu's { title, id, type } row shape —
  // "#"+name as the visible title, the bare name as the id we map back on pick. On
  // a pick we replace the typed "#query" span with "#"+name carrying a `tag` mark
  // { name } → runToOps emits a patch-block for that block. Returns true iff the
  // menu is (now) open.
  _maybeTag() {
    if (!this._editable || !this._tagSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame — identical
    // rationale to _maybeWikilink: `$from.parent.textContent` pairs exactly with
    // `parentOffset`, so a `#` typed in the 2nd-or-later run block still opens.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenTag(blockLocalText, caretOffset);
    if (!hit) {
      this._closeTag();
      return false;
    }

    // Open (or refresh as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT position
    // (selection.from), not the block-local offset hit carries.
    this._openTag(this._caretRect(), hit.query);
    this._tagRange = tagReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD (own _tagSeq, independent of _wlSeq): each
    // open/keystroke bumps the counter; a resolved batch is dropped unless it is
    // still the latest request AND the menu is still open. The source returns a
    // string[] of tag NAMES; adapt each to WikilinkMenu's row shape here.
    const seq = ++this._tagSeq;
    Promise.resolve(this._tagSource(hit.query))
      .then((list) => {
        if (seq !== this._tagSeq || !this._tag || !this._tag.isOpen()) {
          return;
        }
        const rows = (Array.isArray(list) ? list : []).map((name) => ({
          title: "#" + name,
          id: name,
          type: "tag",
        }));
        this._tag.setResults(rows);
      })
      .catch(() => {});
    return true;
  }

  _openTag(rect, query = "") {
    if (!this._tag) {
      this._tag = new WikilinkMenu({
        onChoose: (c) => this._chooseTag(c),
        onDismiss: () => this._dismissTag(),
      });
    }
    this._tag.open(rect, query);
  }

  _closeTag() {
    if (this._tag && this._tag.isOpen()) this._tag.close();
  }

  // User picked a tag: replace the typed "#query" span with "#"+name carrying a
  // `tag` mark { name }, plus a trailing UNMARKED space so typing continues
  // OUTSIDE the tag (mark is inclusive:false; the space guarantees it across
  // browsers). The candidate is a WikilinkMenu row whose `id` is the bare tag
  // name; map it back here. The marked-text insertion mutates the run block →
  // runToOps emits a patch-block for that block. _tagRange was captured in
  // _maybeTag when the menu opened/refreshed. Mirrors _chooseWikilink.
  _chooseTag(candidate) {
    const range = this._tagRange;
    if (!range) {
      this._closeTag();
      return;
    }
    const name = candidate && candidate.id != null ? candidate.id : "";
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: "#" + name,
          marks: [{ type: "tag", attrs: { name } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeTag();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "#query" in place —
  // the user may want to keep editing it. Mirrors _dismissWikilink.
  _dismissTag() {
    this._closeTag();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async tag search:
  // `el.tagSource = (query) => Promise<string[]>`. Unset → _maybeTag early-returns,
  // so the popup NEVER opens (graceful no-op for the harness without a source and
  // the read-mode web embed). Mirrors wikilinkSource exactly.
  set tagSource(fn) {
    this._tagSource = fn;
  }

  get tagSource() {
    return this._tagSource;
  }

  // ── P4 `/` slash menu (canvas DIRECT-INSERT variant) ───────────────────────
  //
  // The per-block editor's _maybeSlash (../index.js ~327), adapted for the canvas.
  // SAME trigger rule — the menu opens when the CURRENT run block's text STARTS
  // with "/" and the caret sits at the end of it (the user typed "/" at the start
  // of an otherwise-empty line and may keep typing a query like "/head"). The
  // substring after "/" is the live filter query.
  //
  // KEY DIFFERENCE from the per-block editor: the trigger is BLOCK-LOCAL, not
  // whole-editor. The per-block editor hosts ONE block so getText() == that block's
  // text; the canvas hosts MANY, so getText() would join every run block with
  // "\n\n" and a "/" typed in the 2nd-or-later block would never open the menu.
  // We read `$from.parent.textContent` + `parentOffset` (the same block-local frame
  // _maybeWikilink / _maybeTag use), so a "/" opens the menu against THAT block.
  //
  // On a pick the canvas inserts the default NODE directly (see _chooseSlash) — it
  // does NOT dispatch bp-slash-insert (that is the per-block path, where the SERVER
  // builds the block). Text that does NOT start with "/" (a slash mid-prose), a
  // multi-block selection, or a non-collapsed selection all keep the menu closed.
  _maybeSlash() {
    if (!this._editable) return; // read mode: no slash menu
    if (!this._editor) return;

    const { selection } = this._editor.state;

    // Caret only — never on a range selection.
    if (!selection.empty) {
      this._closeSlash();
      return;
    }

    // Block-LOCAL text + offset (multi-block-doc-correct — see header). The block
    // is the current run block's textblock; a "/" only triggers when it is the
    // ENTIRE block text (text[0] === "/") and the caret is at its end.
    const $from = selection.$from;
    // TOP-LEVEL-PROSE-only guard: the caret must sit in a paragraph/heading that is a
    // DIRECT child of the doc — the only place a slash insert can replace the block
    // with a top-level node. depth === 1 alone is NOT enough: a CALLOUT BODY
    // (callout-node.js group:"block", content:"inline*") is ALSO a depth-1 top-level
    // node, so a "/head"+Enter typed INSIDE a callout body would pass a depth-only
    // guard and _chooseSlash's start=$pos.before(depth)/end=$pos.after(depth) would
    // span the WHOLE callout → replaceWith destroys the enclosing callout (chrome +
    // body). Requiring parent.type.name ∈ {paragraph, heading} excludes the callout
    // body (and any future inline-content node-view), and also keeps rejecting a
    // paragraph nested in a list item (depth 3). See slashTriggerAllowsParent.
    if (!slashTriggerAllowsParent($from.depth, $from.parent.type.name)) {
      this._closeSlash();
      return;
    }
    const blockText = $from.parent.textContent;
    const startsSlash = blockText.length > 0 && blockText[0] === "/";
    const atEnd = $from.parentOffset === blockText.length;
    const triggered = startsSlash && atEnd && !blockText.includes("\n");

    if (triggered) {
      this._openSlash(blockText.slice(1)); // query = everything after the leading "/"
    } else {
      this._closeSlash();
    }
  }

  // ── callout authoring shorthand (`> [!type]`) ──────────────────────────────
  //
  // Ported from ../index.js:_maybeCalloutShorthand (~358). Obsidian-style gesture:
  // when the user types `> [!note] `, `> [!warn]- `, or `> [!info]+ ` at the start
  // of an otherwise-empty run block, REPLACE that paragraph with a bpCallout node of
  // the matched tone (collapsed when the modifier is "-"). UNLIKE the per-block
  // editor (which wipes the origin block + dispatches bp-slash-insert for the SERVER
  // to build the callout), the canvas REPLACES the paragraph node in place with the
  // callout node — so runToOps emits ONE insert-after (the new callout) + the remove
  // of the origin para, and the S4a echo stamps the server id.
  //
  // Mutually exclusive with _maybeSlash by leading token ('>' vs '/') AND by the
  // explicit `consumed` gate in onUpdate. Returns true iff it consumed the update.
  //
  // Predicate parity with _maybeSlash: caret collapsed, caret at end, single line —
  // all evaluated BLOCK-LOCALLY (the multi-block canvas frame), so it never fires
  // mid-prose or across blocks. The trailing space in the regex commits the gesture.
  _maybeCalloutShorthand() {
    if (!this._editable) return false; // read mode: no shorthand
    if (!this._editor) return false;

    const { selection } = this._editor.state;

    // Caret only — never on a range selection.
    if (!selection.empty) return false;

    // Block-LOCAL text + offset (multi-block-doc-correct). The gesture only fires
    // when `> [!type] ` is the ENTIRE block text and the caret is at its end.
    const $from = selection.$from;
    // TOP-LEVEL-PROSE-only guard (same rationale as _maybeSlash): the `> [!type]`
    // gesture REPLACES the whole enclosing textblock (start=$pos.before(depth)/
    // end=$pos.after(depth)) with a top-level callout node, so it must only fire in a
    // paragraph/heading that is a DIRECT child of the doc. depth === 1 alone is NOT
    // enough — a CALLOUT BODY is also a depth-1 top-level node, so a `> [!warning] `
    // typed INSIDE a callout body would otherwise span + destroy the enclosing
    // callout. Requiring parent.type.name ∈ {paragraph, heading} excludes the callout
    // body, and still rejects a paragraph nested in a list item. See
    // slashTriggerAllowsParent.
    if (!slashTriggerAllowsParent($from.depth, $from.parent.type.name)) return false;
    const blockText = $from.parent.textContent;
    const atEnd = $from.parentOffset === blockText.length;
    if (!atEnd || blockText.includes("\n")) return false;

    // ^>\s*\[!(\w+)\]([+-]?)\s$ — identical to the per-block editor. The trailing \s
    // (the committing space) + the no-newline guard above mean \s only matches that
    // space here.
    const m = /^>\s*\[!(\w+)\]([+-]?)\s$/.exec(blockText);
    if (!m) return false;

    const tone = normalizeTone(m[1]);
    const collapsed = m[2] === "-";

    // Build the default callout BLOCK (default_block("callout") shape) + the matched
    // tone, then carry collapsible/collapsed so the foldable gesture round-trips.
    // (calloutBlockToNode threads collapsible/collapsed only when === true, mirroring
    // the per-block bp-slash-insert which sends collapsible:true + collapsed.)
    const block = canvasDefaultBlock("callout");
    block.tone = tone;
    block.collapsible = true;
    block.collapsed = collapsed;
    const node = runToTiptap([block]).content[0];

    // REPLACE the whole current block (the just-typed `> [!type] ` paragraph) with
    // the callout node. selectParentNode targets the textblock; replaceSelectionWith
    // swaps the node. The new callout carries bpId:null → runToOps mints an id and
    // emits the structural ops; the origin para is gone (no stray trigger text).
    const { state, view } = this._editor;
    const $pos = state.selection.$from;
    const start = $pos.before($pos.depth);
    const end = $pos.after($pos.depth);
    const calloutNode = state.schema.nodeFromJSON(node);
    let tr = state.tr.replaceWith(start, end, calloutNode);
    // Place the caret INTO the new callout body (it is a textable content node),
    // mirroring the slash path so the user keeps typing the callout text — not left
    // stranded before the swapped node. Best-effort: the swap already landed.
    try {
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(start + 1)));
    } catch (_e) {
      // Selection placement is best-effort; the replace itself already landed.
    }
    view.dispatch(tr);
    this._editor.commands.focus();
    return true;
  }

  _openSlash(query = "") {
    if (!this._slash) {
      this._slash = new SlashMenu({
        // CANVAS_SLASH_ITEMS = SLASH_ITEMS filtered to the insertable set (the
        // per-block menu's SLASH_ITEMS is imported INTACT; the allowlist narrows
        // here, never edits it). SlashMenu still prepends EXPECTED-group items it
        // reads fresh from the DOM on each open.
        // Gyldendal parity E1: a FIELD canvas offers only its declared
        // vocabulary (data-vocabulary); a paper canvas (no attribute) keeps the
        // full insertable set.
        items: slashItemsForVocabulary(
          CANVAS_SLASH_ITEMS,
          parseVocabulary(this.getAttribute("data-vocabulary")),
        ),
        onChoose: (item) => this._chooseSlash(item),
        onDismiss: () => this._dismissSlash(),
      });
    }
    // Anchor the popup to the live caret rectangle. open() handles both the first
    // open and a re-open with a new filter query (as the user types).
    this._slash.open(this._caretRect(), query);
  }

  _closeSlash() {
    if (this._slash && this._slash.isOpen()) this._slash.close();
  }

  // User picked an item: REPLACE the just-typed "/query" block with the default
  // NODE for the picked type, inserted DIRECTLY into the doc (the canvas direct-
  // insert path — it does NOT dispatch bp-slash-insert). The replaced block was an
  // empty "/query" paragraph; we swap it for slashTypeToNode(item.type), which
  // carries bpId:null so runToOps mints a fresh id and emits ONE insert-after (the
  // new block) + the remove of the origin para. The S4a echo then stamps the server
  // id back. After the swap the caret lands inside the new block's body (prose /
  // callout) or selects the atom (divider/code/diagram/field), mirroring a natural
  // authoring flow.
  //
  // DEFENSIVE: an EXPECTED-group pick (or any item) whose type is NOT canvas-
  // insertable is a no-op — CANVAS_SLASH_TYPES is the same allowlist that built the
  // base menu, so a non-insertable EXPECTED field never produces a bad insert.
  _chooseSlash(item) {
    this._closeSlash();
    // A COMPOUND starter row (the Starters group): insert the whole pre-composed
    // subtree through the shared landing seam — same guard, same caret rules as a
    // single-node pick, but the carried node is a container + seeded children.
    if (item && item.compound) {
      insertCompoundAtSelection(this._editor, item.compound);
      return;
    }
    if (!item || !CANVAS_SLASH_TYPES.has(item.type)) {
      // Non-insertable (e.g. an EXPECTED field-image/field-reference): leave the
      // "/query" text in place and refocus, exactly like a dismiss.
      this._editor.commands.focus();
      return;
    }

    // REPLACE the just-typed "/query" block with the default node for the picked
    // type, via the SHARED slash-insert seam (insertSlashTypeAtSelection in command-
    // palette.js) — the SAME code path the P5 command palette's Insert commands use,
    // so a slash pick and an Insert command produce byte-identical blocks. By
    // construction the caret here ALWAYS sits in a top-level-prose block (_maybeSlash
    // gates open on slashTriggerAllowsParent), so the seam's replace branch fires —
    // identical behavior to the pre-refactor in-place replaceWith. EXPECTED-group
    // items carry a `fieldName` binding (threaded through so a bound-field insert
    // round-trips). Caret placement (into-body vs atom-select) is handled by the seam.
    insertSlashTypeAtSelection(this._editor, item.type, item.fieldName);
  }

  // Esc / outside-click: close the menu but LEAVE the typed "/" in place — the user
  // may want to keep typing a real slash. Mirrors ../index.js:_dismissSlash.
  _dismissSlash() {
    this._closeSlash();
    this._editor.commands.focus();
  }

  // ── P5 command palette (Cmd-P) ─────────────────────────────────────────────
  //
  // The Obsidian Cmd-P analog. Opened on Mod-p (see _onKeyDown), it floats a
  // centered modal over the editor listing the WHOLE command registry, fuzzy-
  // filtered by what the user types into its query input. UNLIKE the slash/[[ /#
  // popups it consumes NO doc text — it is keyboard-triggered. On a pick it runs the
  // command's run(editor), closes, and refocuses; the command then emits the normal
  // bp-canvas-ops via the onUpdate path (insert → insert-after; format → patch-block).
  _openPalette() {
    if (!this._editable || !this._editor) return;
    // The View-group "Toggle Markdown source" command calls back into the WC's
    // toggle (the canvas owns the rich⇄source swap, not the editor) — the SAME method
    // Mod-Shift-m calls, so both triggers are identical.
    const registryOpts = { onToggleSource: () => this.toggleSourceMode() };
    if (!this._palette) {
      this._palette = new CommandPalette({
        commands: buildCommandRegistry(this._editor, registryOpts),
        onChoose: (cmd) => this._choosePaletteCommand(cmd),
        onDismiss: () => this._dismissPalette(),
      });
    } else {
      // Rebuild the registry against the LIVE editor on each open so command
      // availability (e.g. underline only if registered) reflects the current state.
      this._palette.setCommands(buildCommandRegistry(this._editor, registryOpts));
    }
    // The rect is ignored by CommandPalette._position (centered modal); pass the
    // caret rect anyway for API symmetry with the slash popup. Empty initial query.
    this._palette.open(this._caretRect(), "");
  }

  _closePalette() {
    if (this._palette && this._palette.isOpen()) this._palette.close();
  }

  // User picked a command: close the palette, refocus the editor, then run the
  // command. run() acts on the current selection/block via the editor chain (format/
  // turn-into) or inserts a default node (Insert, via the shared slash seam), each of
  // which mutates the doc → onUpdate → debounced bp-canvas-ops. Refocus BEFORE run so
  // chain().focus() lands on the editor selection the user left (the palette input
  // never held a ProseMirror selection).
  _choosePaletteCommand(cmd) {
    this._closePalette();
    this._editor.commands.focus();
    if (cmd && typeof cmd.run === "function") {
      try {
        cmd.run(this._editor);
      } catch (_e) {
        // A command failure must not wedge the palette/editor — it is already closed
        // and refocused; swallow so a bad command is a no-op, not a crash.
      }
    }
  }

  // Esc / outside-click / Mod-p-toggle: close the palette and refocus the editor. No
  // doc text to preserve (the palette consumed none).
  _dismissPalette() {
    this._closePalette();
    this._editor.commands.focus();
  }

  // ── P5 MARKDOWN SOURCE-MODE (Mod-Shift-m / palette "Toggle Markdown source") ──
  //
  // The Obsidian "source mode" analog: swap the rich ProseMirror editor for a plain
  // Markdown <textarea> and back. The SAME toggle method is bound to both triggers
  // (the keyboard shortcut in _onKeyDown and the palette command in
  // buildCommandRegistry → run()), so they are guaranteed identical.
  //
  //   rich → source : serialize the run to markdown (blocksToMarkdown of the diff
  //                   baseline this._blocks — the echo-advanced confirmed run), stash
  //                   the original md + a deep clone of those baseline blocks, hide
  //                   the rich editor, close any open popup, show a focused textarea.
  //   source → rich : read the textarea. If the markdown is UNCHANGED (=== the stashed
  //                   original) restore the rich editor UNTOUCHED — NO re-parse, NO
  //                   setContent, ZERO ops (a no-op toggle never perturbs the doc or
  //                   the diff baseline). If EDITED, parse it back (markdownToBlocks),
  //                   REALIGN the parsed blocks' ids against the baseline (so a
  //                   surviving block keeps its id and a single in-place edit emits ONE
  //                   patch-block, not remove+insert), then setContent → onUpdate →
  //                   the existing _emitOps path diffs this._blocks → the new doc and
  //                   emits the bp-canvas-ops for exactly the user's source-mode edits.
  toggleSourceMode() {
    if (!this._editor || !this._editable) return;
    if (this._mode === "rich") this._enterSourceMode();
    else this._exitSourceMode();
  }

  // ENTER source mode. Capture the baseline (the live diff baseline this._blocks)
  // and its markdown, hide the rich editor + close any popup, mount a focused
  // textarea sized to its content. Idempotent: a second enter while already in
  // source mode is a no-op.
  _enterSourceMode() {
    if (this._mode === "source" || !this._editor || !this._mount) return;

    // Commit both node-view inputs and the outer batch before capturing source.
    // Otherwise an immediate source toggle serializes stale code/caption attrs.
    this.flushPendingChanges();

    // Close any open popup — in source mode the textarea owns input, so a lingering
    // [[ / # / slash / palette popup would float over a now-hidden editor.
    this._closeWikilink();
    this._closeTag();
    this._closeSlash();
    this._closePalette();

    // THE BASELINE — derived from the LIVE doc (L0), NOT this._blocks (C).
    //
    //   C  = this._blocks  — the ECHO-CONFIRMED baseline. It advances ASYNC, only when
    //        the server echoes bp:canvas-update → applyServerBlocks. After the user
    //        types, C LAGS the live doc by ~300ms + network until the echo lands.
    //   L0 = the LIVE doc projected back to blocks — docToBlocks(normalizeCanvasDoc(
    //        getJSON())), the SAME projection _emitOps diffs against. It includes the
    //        user's just-typed, not-yet-confirmed edits.
    //
    // Capturing from C would show STALE markdown (missing the just-typed edits) and,
    // on an edited exit, a setContent built from C would DELETE those edits. So the
    // baseline + textarea MUST come from L0. We deep-clone L0 so a later parse +
    // realign never mutates it.
    const liveDoc = normalizeCanvasDoc(this._editor.getJSON());
    const L0 = docToBlocks(liveDoc);
    this._sourceBaselineBlocks = deepCloneBlocks(L0);
    const md0 = blocksToMarkdown(this._sourceBaselineBlocks);
    this._sourceOriginalMd = md0;

    // The textarea — monospace, full-width, themed by the --paper-* tokens (styled
    // in root.html.heex next to .bp-cmd-*). Mount it as a sibling of the rich body
    // inside the WC so the same surface tokens cascade in.
    const ta = document.createElement("textarea");
    ta.className = "bp-canvas-source";
    ta.value = md0;
    ta.setAttribute("aria-label", "Markdown source");
    ta.spellcheck = false;
    ta.autocapitalize = "off";
    ta.autocomplete = "off";
    ta.setAttribute("autocorrect", "off");
    // The textarea owns its own toggle-back (Mod-Shift-m) + Escape, since the rich
    // editor's handleKeyDown does NOT fire while source mode is up.
    this._onSourceKeyDown = (e) => {
      if (
        (e.metaKey || e.ctrlKey) &&
        e.shiftKey &&
        !e.altKey &&
        (e.key === "m" || e.key === "M")
      ) {
        e.preventDefault();
        this.toggleSourceMode();
        return;
      }
      if (e.key === "Escape" || e.key === "Esc") {
        e.preventDefault();
        this.toggleSourceMode();
      }
    };
    ta.addEventListener("keydown", this._onSourceKeyDown);
    // Auto-grow to the content on input so the source never scrolls internally.
    ta.addEventListener("input", () => this._sizeSourceTextarea());

    // Hide the rich editor (kept mounted so its state survives a no-op toggle) and
    // show the textarea in its place.
    this._mount.style.display = "none";
    this.appendChild(ta);
    this._sourceEl = ta;
    this._mode = "source";

    // Size + focus after attach (offsetHeight/scrollHeight need layout).
    this._sizeSourceTextarea();
    try {
      ta.focus();
      // Caret at the start, no selection — Obsidian lands the cursor at doc top.
      ta.setSelectionRange(0, 0);
    } catch (_e) {
      // focus is best-effort (e.g. a detached test env).
    }
    // The editor just lost focus to the textarea — drive the format bubble's own
    // hide path (update() hides when !view.hasFocus()) so no stale bubble lingers
    // over the now-hidden editor.
    if (this._bubble) this._bubble.update();
  }

  // EXIT source mode → back to the rich editor.
  //   NO EDIT  (textarea value === the stashed original md): restore the rich editor
  //            UNTOUCHED — no re-parse, no setContent, ZERO ops. The diff baseline and
  //            caret are exactly as they were before entering.
  //   EDITED   : parse the markdown back to blocks (L1), REALIGN ids against the LIVE
  //            baseline (L0) so surviving blocks keep their ids, then:
  //              (1) apply L1 to the editor via setContent(runToTiptap(L1), FALSE) —
  //                  the `false` means NO auto-emit (so onUpdate → _emitOps does NOT
  //                  fire and re-diff from this._blocks/C); and
  //              (2) dispatch ONLY the source-mode diff = runToOps(L0, L1) ourselves.
  //            This is the crux: the pre-source edits (L0−C) are ALREADY in flight
  //            (emitted on enter / by the debounce). Re-running _emitOps would diff
  //            from C and re-emit L0−C as DUPLICATE structural ops (a re-emitted
  //            insert-after for an already-inserted id can double-insert). By diffing
  //            L0→L1 explicitly and suppressing the auto-emit, only the GENUINE source
  //            edits go out. this._blocks (C) is left alone; the echoes (pre-source +
  //            source) advance it normally on their own clock.
  // Either way the textarea + its listener are torn down and the rich editor reshown.
  _exitSourceMode() {
    let emitted = false;
    if (this._mode === "source" && this._sourceEl) {
      const md = this._sourceEl.value;
      const edited = md !== this._sourceOriginalMd;

      // Tear down the textarea + listener and reveal the rich editor FIRST so the
      // setContent (edited path) and the refocus land on the visible editor.
      this._teardownSourceEl();
      if (this._mount) this._mount.style.display = "";
      this._mode = "rich";

      if (edited) {
        // L1 = the blocks after the user edited the markdown: parse it (fresh minted
        // ids) then REALIGN against L0 (the live-doc baseline) so a surviving block
        // keeps its id → runToOps emits a PATCH (not remove+insert) for an in-place
        // edit. L0 = this._sourceBaselineBlocks (captured from the LIVE doc on enter).
        const L0 = this._sourceBaselineBlocks;
        // Realign parsed ids onto the baseline, then CLAMP the locked template
        // prefix (D4's felt half for source mode): a source-mode DELETE / MOVE /
        // retype of the locked title is reconstructed away so the client view
        // can't diverge from the server (which vetoes the same op with
        // {:locked_block, id, op}) — while a same-type CONTENT edit (a retitle)
        // rides through as the patch-block the server accepts, exactly like a
        // rich-mode retitle (locks are placement locks, not content locks).
        // Additive — a template-free run is returned untouched, so a lock-free
        // paper stays byte-identical (D3).
        const L1 = clampLockedPrefix(
          L0,
          realignBlockIds(L0, markdownToBlocks(md)),
        );
        // ONE projection of L1, used for BOTH the editor content and the emitted diff,
        // so the rich editor and the ops it sends are derived from the exact same doc.
        const L1Doc = runToTiptap(L1);

        // (1) Apply L1 to the editor WITHOUT auto-emit (setContent second arg = false).
        // The rich editor now shows L1; onUpdate does NOT fire, so _emitOps never runs
        // and never re-diffs from C. addToHistory:false so the source-mode reflow is
        // not a separate undo step on top of the user's own edits.
        this._editor
          .chain()
          .setContent(L1Doc, false)
          .command(({ tr }) => {
            tr.setMeta("addToHistory", false);
            return true;
          })
          .run();

        // (2) Feed the new live document through the normal one-in-flight path.
        // If an earlier rich batch is pending, source changes wait behind it and
        // are diffed from that batch's acknowledged after-state.
        // Use the normal one-in-flight path. If a rich batch is still pending,
        // this marks the source result dirty and emits its incremental delta only
        // after that earlier batch is acknowledged.
        emitted = this._emitOps();
      }
      // else NO EDIT: the rich editor was never touched — the live doc, the diff
      // baseline, and the caret are exactly as they were. ZERO ops by construction.

      this._sourceBaselineBlocks = null;
      this._sourceOriginalMd = "";
      try {
        this._editor.commands.focus();
      } catch (_e) {
        // focus is best-effort.
      }

      // MAJOR (source-mode external-edit queue): while we were in source mode an
      // external echo may have been QUEUED (applyServerBlocks saw _isEditingNow() ===
      // true because the mode was 'source'). Now that we are back in rich, flush it so
      // the queued external edit lands — the SAME flush the blur / compositionend path
      // runs. Re-applying L1's own diff above does not conflict: the external content
      // is the server-confirmed state and supersedes. We flush AFTER setContent so the
      // external apply is the last word.
      this._flushPendingServerBlocks();
    }
    return emitted;
  }

  // Grow the source textarea to fit its content (no internal scroll). Best-effort —
  // a detached test env has no layout, so scrollHeight is 0 and we leave the rows.
  _sizeSourceTextarea() {
    const ta = this._sourceEl;
    if (!ta) return;
    try {
      ta.style.height = "auto";
      const h = ta.scrollHeight;
      if (h > 0) ta.style.height = h + "px";
    } catch (_e) {
      // no layout (test env): leave the default rows.
    }
  }

  // Remove the source textarea + its keydown listener (the exact bound identity).
  // Called on exit AND on disconnect so a teardown mid-source-mode leaks nothing.
  _teardownSourceEl() {
    const ta = this._sourceEl;
    if (!ta) return;
    if (this._onSourceKeyDown) {
      ta.removeEventListener("keydown", this._onSourceKeyDown);
      this._onSourceKeyDown = null;
    }
    if (ta.parentNode) ta.parentNode.removeChild(ta);
    this._sourceEl = null;
  }

  // S4a: ECHO-DRIVEN BASELINE — the server's confirmed-blocks echo lands here.
  //
  // After apply_paper_block_ops persists a batch, the server re-partitions the
  // confirmed blocks and pushes `bp:canvas-update` carrying THIS run's blocks;
  // the BarkparkPaperCanvas hook routes them to this method. There are two cases:
  //
  //   OWN ECHO (the overwhelming common case) — the user edited, the server
  //     confirmed the SAME blocks. We detect this with reconcileServerEcho (the
  //     PURE S4a reconciler): it compares the confirmed blocks to the LIVE doc
  //     node-by-node, treating a live bpId:null node as a WILDCARD matching the
  //     server-minted id at that index. This is the make-or-break for NEW blocks
  //     (Enter-split / paste / typed paragraph — the most common structural
  //     edit): the live new-block node still carries bpId:null while the confirmed
  //     block carries a freshly-minted id (say "m1"). A naive runToOps gate would
  //     MISDETECT this as external (it mints a fresh id for the null node and
  //     reports remove+insert) and, because the live node never learns "m1", every
  //     later batch would re-mint it (the op size never shrinks, the id churns).
  //     Instead we WRITE the server-confirmed ids back onto the live null-bpId
  //     nodes (an ATTR-ONLY change — see _stampOwnEchoIds), so the echo no-ops AND
  //     the next diff is truly incremental. ZERO setContent, ZERO caret movement.
  //
  //   EXTERNAL EDIT — the confirmed blocks DIFFER from the live doc (another tab /
  //     agent / the ingest endpoint changed the run): a different STRUCTURE (length
  //     or kind mismatch) or a REAL content change. We reset the baseline AND
  //     update the editor to the confirmed content. The setContent transaction is
  //     marked addToHistory:false so an external edit NEVER enters the user's undo
  //     stack. GUARD: if the editor is FOCUSED or composing (IME), we QUEUE the
  //     update and apply it on blur / compositionend so we never yank the caret
  //     mid-edit — the baseline still advances immediately (so own ops keep
  //     diffing incrementally), only the visible re-render defers.
  applyServerBlocks(blocks) {
    if (!this._editor) return;
    const next = Array.isArray(blocks) ? blocks : [];

    // An echo can confirm an earlier local snapshot while the user has already
    // edited beyond it. Recognize that snapshot as our own and advance only the
    // confirmed baseline; replacing the live doc here would erase the newer edit.
    if (this._inflightOps && reconcileServerEcho(
      next,
      runToTiptap(this._inflightOps.afterBlocks).content || [],
    ).ownEcho) {
      this._inflightOps.echoSeen = true;
      this._clearPendingServerBlocks();
      return;
    }
    const awaitingIndex = this._awaitingOwnEchoes.findIndex((snapshot) =>
      reconcileServerEcho(next, runToTiptap(snapshot).content || []).ownEcho
    );
    if (awaitingIndex !== -1) {
      this._awaitingOwnEchoes.splice(0, awaitingIndex + 1);
      this._clearPendingServerBlocks();
      return;
    }

    // The match check, id-tolerant. reconcileServerEcho compares the confirmed
    // blocks to the LIVE top-level nodes, treating a live bpId:null as a wildcard
    // for the server id at that index (the NEW-block case), and returns the
    // own-echo verdict + the id-writebacks. normalizeCanvasDoc first so we compare
    // against the same shape the emit path diffs (phantom nested attrs / split
    // dedup), exactly as runToOps was tested against.
    const liveContent = normalizeCanvasDoc(this._editor.getJSON()).content || [];
    const { ownEcho, idWrites } = reconcileServerEcho(next, liveContent);

    // A genuinely external echo cannot safely replace local content while one
    // or more emitted snapshots are still awaiting confirmation. Defer it; a
    // later own echo carries the server's newest folded state and supersedes it.
    if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) {
      this._queueServerBlocks(next);
      return;
    }

    // No local save state remains, so this server run is authoritative for the
    // next diff whether it is an own echo or an external update.
    this._blocks = next;

    if (ownEcho) {
      // OWN ECHO: stamp the server-confirmed ids onto any just-minted live nodes
      // (bpId:null), an ATTR-ONLY transaction PM maps the selection through (the
      // caret does NOT move) and that does NOT enter undo. NO setContent. After
      // the stamp the live nodes carry the confirmed ids, so the next diff is
      // truly incremental (no re-mint, no id churn). If a stale external-edit echo
      // was queued, it is now superseded by this confirmation — drop it.
      this._stampOwnEchoIds(idWrites, next);
      this._clearPendingServerBlocks();
      return;
    }

    // EXTERNAL EDIT: the confirmed content differs from the live doc. If the
    // user is mid-edit (focused or IME-composing), defer the visible re-render
    // until they release; otherwise apply it now.
    if (this._isEditingNow()) {
      this._queueServerBlocks(next);
    } else {
      this._programmaticApply = true;
      try {
        this._applyExternalContent(next);
      } finally {
        this._programmaticApply = false;
      }
    }
  }

  // OWN-ECHO ID WRITEBACK — stamp the server-confirmed ids onto the live
  // just-minted (bpId:null) top-level nodes. ATTR-ONLY: each setNodeMarkup
  // changes ONLY the node's attrs (bpId, and bpType if it too was null) and
  // touches NO content, so ProseMirror MAPS the current selection straight
  // through the transaction — the caret stays exactly where the user is typing.
  // setMeta('addToHistory', false) keeps the stamp out of the user's undo stack.
  // We walk the live doc's top-level nodes so `offset` is each node's start pos
  // (what setNodeMarkup keys by). idWrites is index-keyed into that same top-level
  // sequence (reconcileServerEcho built it from the same liveContent).
  _stampOwnEchoIds(idWrites, serverBlocks) {
    if (!this._editor || !idWrites || idWrites.length === 0) return;
    const writeByIndex = new Map();
    for (const w of idWrites) writeByIndex.set(w.index, w);

    const { state, view } = this._editor;
    const tr = state.tr;
    let mutated = false;
    state.doc.forEach((node, offset, index) => {
      const w = writeByIndex.get(index);
      if (!w) return;
      const attrs = { ...node.attrs, bpId: w.id };
      // Stamp bpType too only when it was also null on the live node and the
      // reconciler resolved it from the confirmed block.
      if (w.bpType != null && node.attrs && node.attrs.bpType == null) {
        attrs.bpType = w.bpType;
      }
      tr.setNodeMarkup(offset, undefined, attrs);
      mutated = true;
    });
    if (!mutated) return;
    // Attr-only change → no content change → selection maps through → caret
    // does NOT move. addToHistory:false keeps it out of undo.
    tr.setMeta("addToHistory", false);
    view.dispatch(tr);
  }

  // Stamp every id minted by docToBlocks back into the corresponding live PM
  // node, including editable descendants inside section/container nodes. The
  // stable projection has the same preorder shape as the live document; text
  // nodes participate in the walk so positions cannot drift between siblings.
  _stampMaterializedIds(stableDoc) {
    if (!this._editor || !stableDoc) return;
    const stableNodes = [];
    const collect = (nodes) => {
      for (const node of nodes || []) {
        stableNodes.push(node);
        collect(node.content);
      }
    };
    collect(stableDoc.content);

    const { state, view } = this._editor;
    const tr = state.tr;
    let index = 0;
    let mutated = false;
    state.doc.descendants((node, pos) => {
      const stable = stableNodes[index++];
      const stableId = stable?.attrs?.bpId;
      if (!node.isText && node.attrs?.bpId == null && stableId != null) {
        tr.setNodeMarkup(pos, undefined, {
          ...node.attrs,
          bpId: stableId,
          bpType: node.attrs.bpType == null ? stable.attrs?.bpType : node.attrs.bpType,
        });
        mutated = true;
      }
    });
    if (!mutated) return;
    tr.setMeta("addToHistory", false);
    view.dispatch(tr);
  }

  // True when the editor is actively being edited and a setContent would yank the
  // caret OR clobber an unseen edit: it has focus, OR ProseMirror is mid-IME-
  // composition, OR we are in SOURCE mode. Each is a reason to DEFER an external
  // re-render.
  //
  // SOURCE mode is the MAJOR case: the rich editor is HIDDEN and a Markdown textarea
  // owns input. If applyServerBlocks applied an external echo now, it would setContent
  // on the hidden editor — and the subsequent source-exit setContent (L1) would then
  // CLOBBER that external edit (the user never sees it; it's lost). So source mode is
  // "busy" exactly like focus/IME: the external blocks are QUEUED (_pendingServerBlocks)
  // and flushed on exit (_exitSourceMode → _flushPendingServerBlocks), so the queued
  // external edit lands once the user is back in rich.
  _isEditingNow() {
    if (!this._editor) return false;
    if (this._mode === "source") return true;
    const composing = !!(this._editor.view && this._editor.view.composing);
    return this._editor.isFocused || composing;
  }

  // Apply the confirmed external content to the editor WITHOUT entering the undo
  // stack. setContent(_, false) does not emit an update (so we don't bounce an op
  // batch back); the addToHistory:false transaction meta keeps the external edit
  // out of the user's undo history. The baseline was already reset by the caller.
  _applyExternalContent(blocks) {
    if (!this._editor) return;
    this._editor
      .chain()
      .setContent(runToTiptap(blocks), false)
      .command(({ tr }) => {
        tr.setMeta("addToHistory", false);
        return true;
      })
      .run();
  }

  // Queue an external-edit re-render to fire once the user stops editing. We
  // listen for compositionend (IME release) and the editor's blur; whichever
  // comes first flushes the latest queued blocks. Re-queuing overwrites the
  // pending blocks (only the latest confirmed state matters).
  _queueServerBlocks(blocks) {
    this._pendingServerBlocks = blocks;
    if (this._onBlurFlush) return; // listeners already armed

    const flush = () => this._flushPendingServerBlocks();

    this._onBlurFlush = flush;
    this._onComposeEnd = flush;
    // The editor blur fires through TipTap's onBlur; but to catch a blur that
    // happens without a TipTap transaction we also bind the DOM listeners on the
    // editable mount. Both call the same idempotent flush.
    if (this._mount) {
      this._mount.addEventListener("blur", this._onBlurFlush, true);
      this._mount.addEventListener("compositionend", this._onComposeEnd, true);
    }
  }

  // Apply the queued external-edit echo, if one is pending and the user is no longer
  // mid-edit. Called by the blur / compositionend release listeners AND by the
  // source-mode exit (so a queued external edit lands once the user is back in rich).
  // Idempotent + guarded: a still-composing editor waits for the next release; a
  // still-in-source mode (e.g. a spurious call) waits for exit; an empty queue no-ops.
  _flushPendingServerBlocks() {
    if (!this._pendingServerBlocks) return;
    // Still mid-composition or still in source mode? Wait for the real release.
    if (this._editor && this._editor.view && this._editor.view.composing) return;
    if (this._mode === "source") return;
    if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) return;
    const pending = this._pendingServerBlocks;
    this._clearPendingServerBlocks();
    if (pending) this._applyExternalContent(pending);
  }

  // Tear down any queued external-edit echo + its release listeners.
  _clearPendingServerBlocks() {
    this._pendingServerBlocks = null;
    if (this._mount) {
      if (this._onBlurFlush) {
        this._mount.removeEventListener("blur", this._onBlurFlush, true);
      }
      if (this._onComposeEnd) {
        this._mount.removeEventListener("compositionend", this._onComposeEnd, true);
      }
    }
    this._onBlurFlush = null;
    this._onComposeEnd = null;
  }

  // Upgrade-safe property reclaim (called from connectedCallback). Mirrors
  // ../index.js:_upgradeProperty.
  _upgradeProperty(name) {
    if (Object.prototype.hasOwnProperty.call(this, name)) {
      const value = this[name];
      delete this[name];
      this[name] = value;
    }
  }

  // `blocks` property — the run this canvas edits (an array of PROSE blocks). A
  // host (the harness, later the LiveView) assigns `el.blocks = [...]` before or
  // after mount. Pre-mount: stash it; connectedCallback projects it. Post-mount:
  // re-project the whole run into the live editor and reset the diff baseline.
  set blocks(value) {
    this._blocks = Array.isArray(value) ? value : [];
    this._inflightOps = null;
    this._awaitingOwnEchoes = [];
    this._dirtyWhileInflight = false;
    if (this._editor) {
      this._programmaticApply = true;
      try {
        this._editor.commands.setContent(runToTiptap(this._blocks), false);
      } finally {
        this._programmaticApply = false;
      }
    }
  }

  get blocks() {
    return this._blocks;
  }

  // Hosts with an acknowledged persistence bridge opt into ordered, one-at-a-
  // time emission. Vanilla consumers retain the historical fire-and-echo API.
  set acknowledgedSaves(value) {
    this._acknowledgedSaves = value === true;
  }

  get acknowledgedSaves() {
    return this._acknowledgedSaves;
  }
}

if (!customElements.get("bp-paper-canvas")) {
  customElements.define("bp-paper-canvas", BpPaperCanvas);
}

export { BpPaperCanvas };
