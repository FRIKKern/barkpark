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
import { stripPastedImages } from "./clipboard-paste-policy.js";
import { cleanPastedHTML } from "./paste-html.js";
import { safeUrl } from "../safe-url.js";
import StarterKit from "@tiptap/starter-kit";
import { ListItemSource } from "../list-item-source.js";
import { HeadingSource } from "../heading-source.js";
import { ParagraphSource } from "../paragraph-source.js";
import { portableTextBoundary } from "../portable-text-boundary.js";
import { PortableLink as Link } from "../link-mark.js";
import Placeholder from "@tiptap/extension-placeholder";
import Typography from "@tiptap/extension-typography";
import Underline from "@tiptap/extension-underline";
// The highlight mark: `==text==` shorthand and Mod-Shift-h come with the extension; it persists as the
// portable-doc `highlight` wrapper (convert.js) and renders as <mark> on both surfaces.
import Highlight from "@tiptap/extension-highlight";
// Subscript (Mod-,) and superscript (Mod-.): the portable-doc `sub` / `sup` wrappers.
import Subscript from "@tiptap/extension-subscript";
import Superscript from "@tiptap/extension-superscript";
// Text alignment on paragraphs and headings: the portable-doc `align` attribute.
import TextAlign from "@tiptap/extension-text-align";
import TiptapTaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
// ProseMirror selection constructors — used by the slash direct-insert to place the
// caret naturally after the swap (TextSelection INTO a prose/callout body;
// NodeSelection ONTO a divider/code/diagram/field atom). @tiptap/pm re-exports the
// PM core modules, so this is the canonical TipTap-vanilla import (no extra dep).
import { TextSelection, NodeSelection, Plugin, Selection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { Fragment, Mark, DOMParser as PMDOMParser } from "@tiptap/pm/model";
import { normalizeWordListHTML } from "./word-paste.js";
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
  nodeContentEqual,
  docToBlocks,
  hasOverlappingOps,
  opsRebaseSafe,
  pendingUploadIndexes,
  blockParents,
  holdsNodeIds,

  withObjectOverrides,
} from "./run-convert.js";
// The attr-preservation extension — the make-or-break of S1 (see ./bp-attrs.js).
import { BpAttrs } from "./bp-attrs.js";
import { restingScaffolds } from "./resting-scaffolds.js";
import { inlineObjects, InlineObjectDialog, HostObjectDialog, editInlineObjectAt, editObjectBlockAt, canEditObjectBlock, refusalField } from "./inline-object.js";
import { BlockBoundary } from "./block-boundary.js";
import { exactClipboardSerializer, sliceWithFreshIds } from "./clipboard-slice.js";
import { RestingSelection } from "./resting-selection.js";
import { CaretBeforeKeys } from "./caret-before-keys.js";
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
// scaffy-backlog-blocks-editable-studio: the `diff` + `filetree` blocks as canvas
// ATTR-ATOM nodes — the code/diagram shape GENERALIZED to one verbatim-body attr
// plus optional scalar metadata. UNLIKE code/diagram their PREVIEW is the reader's
// OWN server-pushed HTML (bp:block-html), because no client runtime can produce
// diff/filetree markup and the parity gate forbids hand-mirroring it. Named
// `bpDiff` / `bpFiletree`; NO StarterKit collision, so no StarterKit node is
// disabled for them. See ./technical-node.js.
import { Diff, Filetree } from "./technical-node.js";
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
// The expandable (native toggle) container: a summary island over a block+ body.
import { Expandable } from "./expandable-node.js";
// steps / tabs: containers of titled rows (a title input over a block+ body each).
import { Steps, Step, Tabs, Tab } from "./rows-node.js";
// The "data + island" atoms: equation, footnotes, contents, video.
import { Equation, Footnote, Toc, Video } from "./island-node.js";
// Find in the paper + replace one/all: a decoration plugin driven by the host's bar.
import { remoteSelections, setRemoteSelections as rsSet } from "./remote-selections.js";
import { commentRanges, setCommentRanges as crSet } from "./comment-ranges.js";
// A document link's words painted live from the host's wikilinkResolve; see ./wikilink-titles.js.
import { wikilinkTitles, setWikilinkMissing, wikilinkInfo } from "./wikilink-titles.js";
// A typed or pasted [[Title]] that names a known document becomes a link; see ./wikilink-input.js.
import { wikilinkInput } from "./wikilink-input.js";
import { findReplace } from "./find-replace.js";
// editable-image: the `image` block as a self-painting atom with alt + url inputs.
import { Image } from "./image-node.js";
import { CardKeys } from "./card-menu.js";
// live-data task-list: the EDITABLE-QUERY + server-painted-ROWS atom (`bpTaskList`).
import { TaskList } from "./task-list-node.js";
// article-chrome roles: the eyebrow / byline / ingress / pullquote blocks as PLAIN
// canvas PROSE nodes (NO node-view — chrome-free, the reader emits one styled
// element with a bp-role-* class). Each renders `["p", {class:"bp-role-*"}, 0]` so
// PM derives the contentDOM from the content hole; getJSON round-trips the styled
// element + bpId/bpType, and run-convert.js maps the block ⇄ node. See ./role-nodes.js.
import { Eyebrow, Byline, Ingress, Pullquote, Blockquote } from "./role-nodes.js";
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
import { BlockHandle } from "./block-handle.js";
// The hover card on a link / wikilink: address, resolved title + first line, Open, Edit (plan #23).
import { LinkPreview } from "./link-preview.js";
// P4 S-slash: the SAME caret-anchored "/" insert popup the per-block editor uses
// (slash-menu.js), REUSED verbatim — only the WC-side wiring differs. SLASH_ITEMS
// is the per-block menu's item list, imported INTACT (never edited): the canvas
// filters it to CANVAS_SLASH_TYPES (the insertable-into-a-run set) via an allowlist
// so the per-block menu's items stay untouched. UNLIKE the per-block editor (which,
// on a pick, wipes the origin block + dispatches `bp-slash-insert` for the SERVER's
// default_block/2 to build), the canvas inserts the default NODE DIRECTLY into the
// ProseMirror doc — so runToOps emits an insert-after carrying the reconstructed
// block and the S4a echo stamps the server id. See _maybeSlash / _chooseSlash below.
import { t, loadStringsFrom } from "../i18n.js";
// The DOM-free tone normalizer (note→info, warn→warning, error→danger, …) shared
// with the per-block `> [!type]` callout shorthand. Reused VERBATIM so the canvas
// shorthand maps tones identically. See _maybeCalloutShorthand below.
// The PURE, DOM-free slash-insert core (split out so it unit-tests in plain Node —
// canvas/index.js itself can't, being a custom element). CANVAS_SLASH_TYPES is the
// insertable-type allowlist; canvasDefaultBlock mirrors default_block/2; slashTypeToNode
// builds the per-type default NODE via runToTiptap (so it round-trips byte-identically);
// CANVAS_SLASH_TEXTABLE_NODES marks which inserted nodes take an into-body caret.
// P5 command palette: the Obsidian Cmd-P analog — a fuzzy, keyboard-triggered (Mod-p)
// launcher over editor COMMANDS (NOT a typed "/" trigger). CommandPalette is a THIN
// subclass of SlashMenu (reuses its render/keyboard/positioning DOM + CSS, only re-
// parameterized: eyebrow / footer / fuzzy filter / centered position). The registry is
// a static { id, label, group, run } array — Insert commands REUSE the slash insert
// seam (insertSlashTypeAtSelection, factored from _chooseSlash → default_block parity),
// Format commands toggle the canvas StarterKit marks, Turn-into commands set the block.
// Canvas-only; <bp-paper-editor> (src/index.js) is byte-unchanged. See _onKeyDown
// (Mod-p trigger + mutual exclusion) and _openPalette / _choosePaletteCommand below.
// The PURE id-realigner + deep-cloner for the exit-source diff (split into its own
// module so it unit-tests in plain Node — canvas/index.js itself calls
// customElements.define at load and can't be imported DOM-free). On EXIT we parse the
// edited markdown (markdownToBlocks → fresh minted ids), then realign those ids onto
// the source baseline so a surviving block keeps its id and runToOps emits a PATCH
// (not remove+insert) for an in-place edit. See ./source-realign.js.
import { deepCloneBlocks } from "./source-realign.js";
import {
  sourceModeToggle,
  sourceModeEnter,
  sourceModeExit,
  sourceModeCommit,
  sourceModeSyncText,
  sourceModeActive,
  sourceModeSizeTextarea,
  sourceModeTeardown,
} from "./source-mode.js";
import { isFigureSingletonCanvas } from "./figure-context.js";
// pdd-t2: the PURE doctrine template-lock veto predicate — wired into the editor's
// filterTransaction below so a locked mandated block (title @0 / featured @1) can
// never be deleted or moved live (the FELT half of the server backstop). Split into
// its own DOM-free module so it unit-tests in plain Node (this file can't be
// imported DOM-free — it calls customElements.define at load).
import { transactionVetoesLock, isLockedTitle } from "./locks.js";
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
} from "./vocabulary.js";
// Internal-link marks — schema registration only, so the canvas holds existing
// wikilink/blockref/tag inline marks through a setContent->getJSON round-trip
// (identical role to ../index.js). The [[ / # autocomplete UI lands on top of
// these marks in P4: a pick inserts a wikilink/tag MARK, which runToOps emits as
// a patch-block for that block (the existing prose patch path).
import { Wikilink, Blockref, Tag, Valueref, InlineOpaque } from "../marks.js";
import { BUILD_SHA, CONTRACT_VERSION, DEBOUNCE_MS, EDITOR_VERSION, PLACEHOLDER } from "../contract.js";
import * as hostApiMethods from "./canvas-methods-host-api.js";
import * as keyboardMethods from "./canvas-methods-keyboard.js";
import * as pasteMediaMethods from "./canvas-methods-paste-media.js";
import * as pickerMethods from "./canvas-methods-pickers.js";
import * as slashPaletteMethods from "./canvas-methods-slash-palette.js";
// How long after compositionend ProseMirror has read the committed text (it ends the
// composition 20 ms after the event).
const COMPOSE_SETTLE_MS = 50;
import { OpaqueMark } from "../opaque-mark.js";

// How long a focusBlock(id) for a block that has not arrived yet stays armed.
const PENDING_FOCUS_MS = 5000;


// Left is the model's "no alignment" (convert.js stores only center/right; run-convert
// treats left and absent as one), so Edit paints it as NO alignment too. Stock TextAlign
// writes an inline `text-align: left` for its default on every paragraph and heading,
// overriding the inherited `start` the reader paints: a View/Edit divergence on every
// block, and the wrong edge in right-to-left text.
export const ReaderTextAlign = TextAlign.extend({
  addGlobalAttributes() {
    return this.parent().map((group) => ({
      ...group,
      attributes: {
        ...group.attributes,
        textAlign: {
          ...group.attributes.textAlign,
          renderHTML: ({ textAlign }) =>
            textAlign === "center" || textAlign === "right" ? { style: `text-align: ${textAlign}` } : {},
        },
      },
    }));
  },
});

// Collect attribute-only refreshes without replacing text or changing its undo
// mappings. List carriers live on descendants, not just the top-level block.
function attributeRefreshes(node, replacement, position) {
  if (node.eq(replacement)) return [];
  if (node.type !== replacement.type || node.isText ||
      !Mark.sameSet(node.marks, replacement.marks) ||
      node.childCount !== replacement.childCount) return null;
  const changes = node.sameMarkup(replacement) ? [] : [{ position, replacement }];
  let offset = position + 1;
  for (let index = 0; index < node.childCount; index++) {
    const child = node.child(index);
    const nested = attributeRefreshes(child, replacement.child(index), offset);
    if (nested === null) return null;
    changes.push(...nested);
    offset += child.nodeSize;
  }
  return changes;
}

// Preserve positions inside unchanged descendants of a list or table. Only
// recurse through an unchanged structural shape; inserted/deleted/retyped
// containers retain the existing replacement path.
const mappedContainers = new Set(["bulletList", "orderedList", "listItem", "taskList", "taskItem", "bpTable", "bpTableRow", "bpTableCell", "bpTableHeaderCell"]);
function canMapExternalNode(node, next) {
  if (node.eq(next)) return true;
  if (node.type !== next.type) return false;
  if (node.isTextblock) return true;
  if (!mappedContainers.has(node.type.name) || node.childCount !== next.childCount) return false;
  const oldId = node.attrs.bpListSource?.id;
  const newId = next.attrs.bpListSource?.id;
  if (oldId !== newId) return false;
  for (let i = 0; i < node.childCount; i++) if (!canMapExternalNode(node.child(i), next.child(i))) return false;
  return true;
}
function mapExternalNode(tr, node, next, position) {
  if (node.eq(next)) return;
  tr.setNodeMarkup(position, next.type, next.attrs, next.marks);
  if (node.isTextblock) {
    const bare = content => {
      const children = []; content.forEach(child => children.push(child.mark([])));
      return Fragment.fromArray(children);
    };
    if (bare(node.content).eq(bare(next.content))) {
      // Marks and link destinations do not delete text. Mark steps have empty
      // position maps, retaining forward/backward selections and local history.
      tr.removeMark(position + 1, position + 1 + node.content.size);
      next.forEach((child, offset) => {
        for (const mark of child.marks) tr.addMark(position + 1 + offset, position + 1 + offset + child.nodeSize, mark);
      });
      return;
    }
    const start = node.content.findDiffStart(next.content);
    if (start != null) {
      const end = node.content.findDiffEnd(next.content);
      let oldEnd = end.a, newEnd = end.b;
      const overlap = start - Math.min(oldEnd, newEnd);
      if (overlap > 0) { oldEnd += overlap; newEnd += overlap; }
      tr.replaceWith(position + 1 + start, position + 1 + oldEnd, next.content.cut(start, newEnd));
    }
    return;
  }
  // Apply from the end so earlier child positions remain valid when text grows.
  let offset = position + 1 + node.content.size;
  for (let i = node.childCount - 1; i >= 0; i--) {
    const child = node.child(i); offset -= child.nodeSize;
    mapExternalNode(tr, child, next.child(i), offset);
  }
}

// Replace one top-level node in place, keeping what the caret and local undo
// steps map through: attribute-only refreshes first, then a mapped text or
// container diff, and a plain replace only when neither fits.
function replaceTopNode(tr, node, replacement, position) {
  if (node.eq(replacement)) return;
  // Saved carrier metadata can change without changing the text. Refresh
  // attributes in place: replacing that text maps local undo steps away.
  const refreshes = attributeRefreshes(node, replacement, position);
  if (refreshes !== null) {
    for (const refresh of refreshes) {
      const target = refresh.replacement;
      const current = tr.doc.nodeAt(refresh.position);
      if (target.type.name === "note" &&
          current.attrs.label === target.attrs.label && current.attrs.lead === target.attrs.lead) {
        // Preserve local field history only for same-visible metadata.
        // Remote field edits must map conflicting label/lead steps away.
        for (const [key, value] of Object.entries(target.attrs)) {
          if (current.attrs[key] !== value) tr.setNodeAttribute(refresh.position, key, value);
        }
      } else {
        tr.setNodeMarkup(refresh.position, target.type, target.attrs, target.marks);
      }
    }
  } else if (canMapExternalNode(node, replacement)) {
    mapExternalNode(tr, node, replacement, position);
  } else {
    tr.replaceWith(position, position + node.nodeSize, replacement);
  }
}

// The top-level block ids a save batch touches.
function opBlockIds(ops) {
  const ids = new Set();
  for (const op of ops || []) {
    if (op && op.id != null) ids.add(op.id);
    if (op && op.block && op.block.id != null) ids.add(op.block.id);
  }
  return [...ids];
}

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

// A Figure owns one singular child MAP, while a normal canvas owns a list. Keep
// ProseMirror from manufacturing list-shaped operations for that one special host:
// content edits may change the child, but the direct node and its authored identity
// must survive. Programmatic server echoes bypass this alongside the other vetoes.
function transactionVetoesFigureSingleton(tr, state, host) {
  if (!tr.docChanged || !isFigureSingletonCanvas(host)) return false;
  if (tr.doc.childCount !== 1) {
    host._showFigureConstraint();
    return true;
  }

  const expectedId = host._blocks[0]?.id ?? state.doc.firstChild?.attrs?.bpId;
  const after = tr.doc.firstChild;
  const replacesChild = expectedId != null && expectedId !== after.attrs?.bpId;
  if (replacesChild) host._showFigureConstraint();
  return replacesChild;
}


// Which copy of a bpId keeps it (task-42d085f7431b8417). ProseMirror's splitBlock
// copies the source node's attrs, bpId included, so an Enter leaves two nodes with
// one id: two top-level blocks, or two children of one section / expandable / step /
// tab. A drop or paste can put a copy anywhere else. runToOps keys edits by id and
// patch.ex refuses a batch that repeats one, so every copy but one reads as new
// (bpId null) and the projection mints it a fresh id, which _stampMaterializedIds
// writes back. The keeper is the copy still where the id was (`prevBlocks`, the
// diff's baseline), preferring the top level, else the first. A top-level node whose
// id was only ever nested reads as new as well: runToOps mints for it, and the live
// doc has to carry the id the server got. Only ids the projection keeps count: a
// column's children and a list's paragraphs carry none (holdsNodeIds).
function freshenRepeatedIds(doc, prevBlocks) {
  const was = blockParents(prevBlocks);
  const copies = new Map();
  const walk = (nodes, parent) => {
    for (const node of nodes) {
      const id = node.attrs && node.attrs.bpId;
      if (id != null) copies.set(id, [...(copies.get(id) || []), { node, parent }]);
      if (holdsNodeIds(node)) walk(node.content, id);
    }
  };
  walk(doc.content, null);
  for (const [id, found] of copies) {
    const parents = was.get(id);
    const placed = parents && !parents.has(null) ? found.filter((copy) => copy.parent !== null) : found;
    if (found.length === 1 && placed.length === 1) continue;
    const stayed = placed.filter((copy) => parents && parents.has(copy.parent));
    const pool = stayed.length ? stayed : placed;
    const keeper = pool.find((copy) => copy.parent === null) || pool[0];
    for (const copy of found) if (copy !== keeper) copy.node.attrs = { ...copy.node.attrs, bpId: null };
  }
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
function normalizeCanvasDoc(doc, prevBlocks) {
  freshenRepeatedIds(doc, prevBlocks);

  const stripNested = (node) => {
    if (node && node.attrs) {
      // ProseMirror toJSON retains each live attrs object by reference.
      // Normalize a projection-owned bag; deleting live defaults creates
      // phantom DOM-reparse edits and poisons native Undo history.
      const a = node.attrs = { ...node.attrs };
      if (a.bpParagraphSource == null) delete a.bpParagraphSource;
      if (a.bpListFrameSource == null) delete a.bpListFrameSource;
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


// The first control a person can type into or press inside a node view, or null.
function focusableControlIn(dom) {
  if (!dom || typeof dom.querySelectorAll !== "function") return null;
  // Something to type into first (a picker's search, a field's input); a button only
  // when the node view has nothing else (a Boolean toggle, a picker's Choose).
  for (const selector of ['input:not([type="hidden"]), select, textarea, [contenteditable="true"]', 'button, [tabindex]:not([tabindex="-1"])']) {
    for (const el of dom.querySelectorAll(selector)) {
      if (el.disabled || el.readOnly || el.getAttribute("aria-hidden") === "true") continue;
      if (el.closest && el.closest('[hidden], [aria-hidden="true"]')) continue;
      return el;
    }
  }
  return null;
}

// A textblock's text with one char per inline leaf, so offsets are positions: a
// hard break reads as a newline (it ends a trigger), any other atom as U+FFFC.


class BpPaperCanvas extends HTMLElement {
  static CONTRACT_VERSION = CONTRACT_VERSION;
  static EDITOR_VERSION = EDITOR_VERSION;
  static BUILD_SHA = BUILD_SHA;

  static get observedAttributes() {
    return ["editable", "format-bubble"];
  }

  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._bubble = null; // FormatBubble instance (selection format toolbar)
    this._linkPreview = null; // LinkPreview instance (hover card on links and wikilinks)
    this._composeEndEmit = null; // one-shot compositionend listener: an ops emit held back by an open IME composition
    this._linkPreviewSource = null; // injected async ({ kind, href, target, docId }) => { title, excerpt, href, missing }
    this._wikilinkResolve = null; // injected (docId) => { title?, missing? } | null, or a Promise of it
    this._modEnterPending = false;
    this._debounceTimer = null;
    // Baseline captured when a local debounce window opens. Server broadcasts may
    // advance `_blocks` while that draft is waiting; the eventual diff must still
    // describe only the local transaction, not manufacture an inverse patch that
    // reverts newly queued authority.
    this._debounceBaselineBlocks = null;
    this._emitCache = null;
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
    // liveRemote (1.15.0): opt in to taking server blocks while the author edits,
    // block by block. Held blocks already reported: id -> the remote block's JSON.
    this._liveRemote = false;
    this._heldRemote = new Map();
    // flushKeepsSource (1.20.0): opt in to a source-mode flush that commits the
    // Markdown and keeps source mode open. Default false: the flush leaves source mode.
    this._flushKeepsSource = false;
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
    // injected async (file) => { src, alt?, width?, height? } — where a pasted or dropped
    // picture goes (the host's Barkpark media); unset → the image node says so.
    this._mediaUploader = null;
    // injected async ({ kind, current }) => { src, alt?, width? } | null — the host's own
    // image picker (upload / library): the Image insert and an image's Select open it.
    this._mediaPicker = null;
    // An image's Select asks for the host's picker on that image (image-node.js).
    this.addEventListener("bp-canvas-image-pick", (event) => {
      event.stopPropagation();
      if (event.detail && Number.isInteger(event.detail.pos)) void this._pickImageAt(event.detail.pos);
    });
    // injected async ({ type, title, inline, fields, value, error }) => value | null — the
    // host's own editor for a declared block or inline object (instead of the popover).
    this._editBlockObject = null;
    // Shared carets: the host's last setRemoteSelections list (re-applied on
    // mount), and the rAF-coalesced bp-canvas-selection emit.
    this._remoteSelections = [];
    this._selectionFrame = null;
    this._lastSelectionDetail = undefined;
    // Comment ranges: the host's last setCommentRanges list (re-applied on mount),
    // and the rAF-coalesced bp-canvas-comment-ranges emit.
    this._commentRanges = [];
    this._commentRangesFrame = null;
    // Toolbar state: the rAF-coalesced bp-selection-change emit.
    this._toolbarFrame = null;
    this._lastToolbarState = undefined;
    this._uploadSeq = 0;
    // Settled receipts survive native history while this editor is mounted.
    // They contain metadata only, never another upload request.
    this._uploadResults = new Map();
    this._tagRange = null; // { from, to } PM range to replace on the current pick
    this._emoji = null; // WikilinkMenu instance reused for the `:` emoji picker (lazy)
    this._emojiRange = null; // { from, to } PM range to replace on the current pick
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
    // The blocks of the last source commit (1.20.0): the second id donor, after the
    // enter baseline, so a block born in this session keeps its id (_commitSource).
    this._sourceCommitBlocks = null;
    // The markdown the rich document holds: shown on ENTER (blocksToMarkdown of the
    // baseline), then the text of the last source commit (_commitSource). The NO-EDIT
    // guard compares the textarea value against THIS string verbatim: equal → the
    // flush or toggle is provably op-free (no re-parse, no setContent, no caret churn).
    this._sourceOriginalMd = "";
    // Bound listener for the textarea's own Mod-Shift-m (toggle BACK to rich) +
    // Escape — kept as a field so the exact identity is removed on cleanup.
    this._onSourceKeyDown = null;
    // Responsive Studio morphs can blur the rich editor immediately BEFORE the
    // custom element's disconnectedCallback. Keep the last focused intent alive
    // through the current DOM mutation only; onBlur clears it in a microtask.
    this._richFocusIntent = false;
    this._richFocusIntentVersion = 0;
    // Reconnect recovery temporarily freezes the stable editor root with `inert`.
    // Keep a separate, one-shot focus intent so that freeze-induced blur can return
    // to the exact same rich editor after a successful retry without touching its
    // ProseMirror selection or history. Deliberate focus elsewhere cancels it.
    this._resumeFocusIntent = null;
    this._resumeFocusState = "idle"; // "idle" | "armed" | "cancelled"
    this._onResumeFocusIn = null;
  }

  connectedCallback() {
    if (this._editor || this._mountFailure) return; // double-mount guard

    ensureStyles();
    // The canvas's own words in the viewer's Studio language (task-addade22d350314a).
    loadStringsFrom(this);

    // Upgrade-safe property reclaim: a host may set `el.blocks = [...]` (or, for
    // P4, `el.wikilinkSource = …` / `el.tagSource = …`) BEFORE the custom-element
    // definition upgrades this node; that assignment lands as a plain own-property
    // shadowing the prototype accessor. Delete + re-assign so it flows back through
    // the real setter. Mirrors ../index.js.
    this._upgradeProperty("blocks");
    this._upgradeProperty("acknowledgedSaves");
    this._upgradeProperty("liveRemote");
    this._upgradeProperty("wikilinkSource");
    this._upgradeProperty("tagSource");
    this._upgradeProperty("mediaUploader");
    this._upgradeProperty("mediaPicker");
    this._upgradeProperty("editBlockObject");
    this._upgradeProperty("linkPreviewSource");
    this._upgradeProperty("wikilinkResolve");

    // Default true; only the literal string "false" disables editing. Mount-time
    // read is authoritative — attributeChangedCallback handles later toggles.
    this._editable = this.getAttribute("editable") !== "false";

    // The contenteditable element the WC owns. TipTap mounts onto it. Same body
    // class as ../index.js so the shared stylesheet styles the canvas identically.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);
    // IME (task-39cb3d6e4709054e): where an open composition started, mapped through every
    // transaction, so a save during a long composition leaves out only the composing run,
    // and a committed phrase is saved at its compositionend.
    this._compStart = null;
    this._onCompStart = () => {
      const sel = this._editor && this._editor.state.selection;
      this._compStart = sel && sel.empty ? sel.from : null;
      this._compBlockSize = sel && sel.empty ? sel.$from.parent.content.size : null;
    };
    this._onCompEnd = () => this._afterComposition();
    this._mount.addEventListener("compositionstart", this._onCompStart, true);
    this._mount.addEventListener("compositionend", this._onCompEnd, true);
    this._onWikilinkClick = (event) => this._wikilinkClicked(event);
    this._mount.addEventListener("click", this._onWikilinkClick);
    // Leaving the page sends what is committed now, not after the debounce or the composition.
    this._onPageHide = () => this.flushPendingChanges();
    this._pageWindow = this.ownerDocument.defaultView;
    this._pageWindow?.addEventListener("pagehide", this._onPageHide);

    // ONE Editor over the WHOLE run. Mirrors ../index.js's Editor config; the
    // KEY differences: (1) content is runToTiptap(this._blocks) — MANY top-level
    // blocks, not blockToTiptap of one; StarterKit's doc is block+, so the
    // siblings are native and cross-block caret/selection/split/merge come free.
    // (2) BpAttrs is in the extension list so getJSON() preserves bpId/bpType.
    // pdd-t14: lexical handle for the lock-veto plugin below — `this` (the WC
    // host) is not reachable from inside Extension.create's plugin factory.
    const host = this;

    this._editor = this._createEditorSafely(() => new Editor({
      element: this._mount,
      editable: this._editable,
      extensions: [
      ListItemSource,
      HeadingSource,
      ParagraphSource,
        portableTextBoundary(this),
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
                  !transactionVetoesFigureSingleton(tr, state, host) &&
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
        ownDomReadback,
        StarterKit.configure({
          // Same as ../index.js: heading levels 1–6 (owner ruling 2026-10-03 #63),
          // lists, history on. The levels drive the `# `…`###### ` input rules and
          // the Mod-Alt-1..6 turn-into chords.
          heading: { levels: [1, 2, 3, 4, 5, 6] },
          // Authored quotes have a dedicated PortableDoc editor. Native nested
          // quotes lose their body on save and preempt `> [!note] ` shorthand.
          blockquote: false,
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
          // tiptap 3 folded Link, Underline, ListKeymap and TrailingNode into
          // StarterKit. Link and Underline are registered below with their own
          // config; ListKeymap and TrailingNode would change list keyboard
          // behaviour and append an empty paragraph the run never authored.
          link: false,
          underline: false,
          listKeymap: false,
          trailingNode: false,
        }),
        // Link mark — same config as ../index.js so existing `link` inline nodes
        // render/edit and the format bubble's link button works.
        Link.configure({ openOnClick: false, autolink: true }),
        // Empty-block ghost text — same contract as ../index.js. includeChildren
        // :false so one placeholder shows on the focused top-level textblock only.
        Placeholder.configure({
          includeChildren: false,
          showOnlyWhenEditable: true,
          placeholder: ({ node }) => {
            // contract.js holds the English (import-free); shown translated.
            if (isLockedTitle(node)) return t(PLACEHOLDER.title);
            if (node.type.name === "heading") {
              return t("Heading %{level}", { level: (node.attrs && node.attrs.level) || 1 });
            }
            return t(PLACEHOLDER[node.type.name] || PLACEHOLDER.paragraph);
          },
        }),
        // The empty locked title reads "Title" wherever the caret is (owner ruling
        // 2026-10-03 #54). The Placeholder extension above marks only the caret's
        // node; this keeps the title's ghost text up at rest. Same `is-empty` +
        // data-placeholder pair, so the existing placeholder CSS paints it.
        Extension.create({
          name: "bpTitlePlaceholder",
          addProseMirrorPlugins: () => [
            new Plugin({
              props: {
                decorations: (state) => {
                  if (!host._editable) return null;
                  const decorations = [];
                  state.doc.forEach((node, pos) => {
                    if (isLockedTitle(node) && node.content.size === 0) {
                      decorations.push(Decoration.node(pos, pos + node.nodeSize, {
                        class: "is-empty",
                        "data-placeholder": t(PLACEHOLDER.title),
                      }));
                    }
                  });
                  return decorations.length ? DecorationSet.create(state.doc, decorations) : null;
                },
              },
            }),
          ],
        }),
        // Smart typography — parity with ../index.js. A prose run holds no code
        // block, so nothing to exclude.
        Typography,
        // Underline (Mod-u) — the PortableDoc inline wire already carries an `underline`
        // wrapper (convert.js), so this only adds the mark the schema was missing.
        Underline,
        Highlight.configure({ HTMLAttributes: { class: "bp-highlight" } }),
        Subscript,
        Superscript,
        // A stored flat mark with no editor (smallcaps, annotations) — carried verbatim.
        OpaqueMark,
        ReaderTextAlign.configure({ types: ["heading", "paragraph"], alignments: ["left", "center", "right"], defaultAlignment: "left" }),
        // Checklist: the list block with task:true (convert.js listToTiptap). `[ ] ` typed at the
        // start of a paragraph wraps it; the checkbox is a native control whose toggle is an
        // ordinary transaction, so runToOps patches the item's `checked`.
        TiptapTaskList,
        TaskItem.configure({ nested: true }),
        // Internal-link marks — schema registration only (see import note). This
        // keeps existing inline wikilink/blockref/tag marks round-tripping; the
        // [[ / # autocomplete UI is OUT of S1.
        Wikilink,
        Blockref,
        Tag,
        Valueref,
        InlineOpaque,
        // Declared inline objects (blocks.inline): accessible names on the atoms,
        // Enter / double-click opens the field dialog. See ./inline-object.js.
        inlineObjects(this),
        // No keystroke at a block boundary deletes a block the author did not
        // Backspace/Delete. See ./block-boundary.js.
        BlockBoundary,
        // THE make-or-break: declares bpId/bpType on the block nodes so the run's
        // ids survive the setContent->getJSON round-trip runToOps depends on.
        BpAttrs,
        restingScaffolds(this),
        findReplace(),
        // Shared carets: the host's remote selections as decorations. See
        // ./remote-selections.js.
        remoteSelections(),
        // Comments on a span of text: the host's ranges as decorations that follow
        // edits. See ./comment-ranges.js.
        commentRanges(this),
        wikilinkTitles(this),
        wikilinkInput(this),
        // A hydrated run rests on a caret, not on an AllSelection a first keystroke would
        // replace wholesale. See ./resting-selection.js.
        RestingSelection,
        // A key acts on the caret a click just put down, not the one before it. See
        // ./caret-before-keys.js.
        CaretBeforeKeys,
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
        // scaffy-backlog-blocks-editable-studio: the diff + filetree attr-atom nodes
        // + their shared node-view. Registers the `bpDiff` / `bpFiletree` node types
        // (atoms; the verbatim body + optional metadata ride data-* attrs; a NodeView
        // pairing a SERVER-PAINTED reader preview hole with a non-PM <textarea>
        // island that uses stopEvent/ignoreMutation so PM never turns diff keystrokes
        // into transactions) so runToTiptap's { type:"bpDiff", attrs:{diff,file?,lang?} }
        // / { type:"bpFiletree", attrs:{text,legend?} } nodes mount as editable blocks
        // whose fields round-trip through getJSON(). Each parses ONLY its own
        // <div data-bp-type='diff'|'filetree'>.
        Diff,
        Filetree,
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
        Image,
        // A selected card's keys on a block-cards canvas (card-menu.js), ahead of all others.
        CardKeys,
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
        Blockquote,
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
        Expandable,
        Steps,
        Step,
        Tabs,
        Tab,
        Equation,
        Footnote,
        Toc,
        Video,
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
      content: this._rt(this._blocks),
      editorProps: {
        // The editable root is ProseMirror's role=textbox: name it, or a screen
        // reader lands in an unnamed "edit text" (axe aria-input-field-name,
        // task-3dbe834e19630e74).
        attributes: { "aria-label": t("Paper text"), "aria-multiline": "true" },
        // P4: while a `[[` / `#` / `/` popup is open it OWNS the navigation keys
        // (↑/↓/Enter/Tab/Esc) — _onKeyDown returns true so ProseMirror does not also
        // act on them (Enter must PICK the active item, NOT split the doc, while a
        // menu is open). When ALL popups are closed every keystroke falls through to
        // TipTap unchanged, so cross-block caret / split / merge are untouched.
        handleKeyDown: (_view, event) => this._onKeyDown(event),
        // ProseMirror prevents the default of every Escape. Hand a bare Escape
        // to the host instead, unless one of the canvas's menus is open to use it.
        // Mod+Enter goes to the host too, and edits nothing if the host leaves it.
        handleDOMEvents: {
          keydown: (view, event) => this._modEnterForHost(view, event) || this._escapeForHost(view, event),
          beforeinput: (_view, event) => this._swallowModEnter(event),
          drop: (view, event) => this._noteDropMoves(view, event),
        },
        handlePaste: (view, event, slice) => this._onPaste(view, event, slice),
        // The canvas's own copy carries the exact fragment, so its paste rebuilds
        // the very nodes copied instead of re-parsing their HTML. See
        // ./clipboard-slice.js.
        clipboardSerializer: exactClipboardSerializer(() => this._editor.schema),
        // Word puts list items on the clipboard as <p style="mso-list:…"> with the
        // bullet as literal text; rebuild them as real lists before parsing, or
        // they land as paragraphs starting "·   ". See ./word-paste.js.
        // Then images the schema cannot hold are left out (counted, and named in
        // a notice by _fitPastedSlice) instead of refusing the whole paste.
        transformPastedHTML: (html) => {
          const { html: clean, count } = stripPastedImages(cleanPastedHTML(normalizeWordListHTML(html)));
          this._pasteImagesLeftOut = count;
          return clean;
        },
        // A copy of a block this doc holds reads as new (clipboard-slice.js); then
        // a field canvas fits the pasted slice to its vocabulary, node by node.
        transformPasted: (slice, view) => this._fitPastedSlice(this._dropMoves ? slice : sliceWithFreshIds(view.state.schema, slice, view.state.doc)),
        // Image files dropped onto the canvas land as image nodes at the drop point
        // and upload through the host's mediaUploader (see _insertImageFiles).
        handleDrop: (view, event, _slice, moved) => this._onDrop(view, event, moved),
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
      onUpdate: ({ transaction }) => {
        this._restoreUploadResults();
        this._clearFigureConstraint(transaction);
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
        // An object editor open over the canvas (the popover, or the host's): its slash
        // line stays until the answer, and an update meanwhile (the save echo stamping
        // ids) must not reopen a menu behind it.
        if (this._objectEditorOpen()) {
          this._closeWikilink();
          this._closeTag();
          this._closeEmoji();
          this._closeSlash();
          if (this._bubble) this._bubble.update();
          return;
        }
        const consumed = this._maybeBlockShorthand() || this._maybeCalloutShorthand();
        if (!consumed) {
          if (this._maybeWikilink()) {
            this._closeTag();
            this._closeEmoji();
            this._closeSlash();
          } else if (this._maybeTag()) {
            this._closeEmoji();
            this._closeSlash();
          } else if (this._maybeEmoji()) {
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
        this._scheduleSelectionEmit();
      },
      // Every transaction may change what a host toolbar shows (a stored mark, a
      // block turned into a heading): bp-selection-change, one per frame at most.
      onTransaction: ({ transaction }) => {
        if (this._compStart != null) this._compStart = transaction.mapping.map(this._compStart, -1);
        this._scheduleToolbarState();
        this._emitHistory(transaction);
      },
      onBlur: () => {
        const version = ++this._richFocusIntentVersion;
        queueMicrotask(() => {
          if (this._richFocusIntentVersion === version && !this._editor?.isFocused) {
            this._richFocusIntent = false;
          }
        });
        if (this._bubble) this._bubble.update();
        this._scheduleSelectionEmit();
      },
      onFocus: () => {
        this._richFocusIntentVersion += 1;
        this._richFocusIntent = true;
        if (this._bubble) this._bubble.update();
        this._scheduleSelectionEmit();
      },
    }));
    // A node view that throws while the run is first painted leaves no editor
    // (construction threw) or an empty one: show the read-only fallback instead.
    if (!this._editor || !this._verifyPainted("create")) return;
    if (this._remoteSelections.length) rsSet(this._editor, this._remoteSelections);
    if (this._commentRanges.length) crSet(this._editor, this._commentRanges);

    // Selection format toolbar — REUSED verbatim from ../format-bubble.js. It is
    // agnostic to how many blocks the editor holds: it floats on any non-empty
    // text selection, including one spanning multiple blocks. Skipped in read
    // mode; every consumer is `if (this._bubble)` guarded.
    if (this._editable) {
      // A host that draws its own toolbar turns the bubble off (format-bubble="off").
      if (this._wantsBubble()) this._bubble = new FormatBubble({ editor: this._editor });
      // Notion-style block gutter: + to add below, ⋮⋮ to drag / open the block menu.
      this._handle = new BlockHandle({
        host: this,
        editor: this._editor,
        openSlash: () => this._openSlash(""),
        // Paper masters: "Save as master" in the block menu, offered only where
        // the editor carries the masters carrier (the pane may write) and the
        // block is one the server already holds.
        canSaveMaster: (node) => this._canSaveMaster(node),
        saveMaster: (node) => this._saveMaster(node),
        // A declared object block's Edit opens its field editor, as a double-click does.
        canEdit: (node) => this._editable && canEditObjectBlock(this, node),
        edit: (pos) => editObjectBlockAt(this, this._editor, pos),
      });
    }
    // The link hover card works in both modes (a reader wants the address too); Edit shows only
    // when editable. Open is the host's call first (`bp-canvas-open-link`, cancelable) — a plain
    // link falls back to a new window; a wikilink has nowhere to go without the host.
    this._linkPreview = new LinkPreview({
      editor: this._editor,
      host: this,
      editable: () => this._editable,
      // Contract 1.14.0: a block-cards host gets Sanity's annotation pill, named by the
      // annotation's schema title (Sanity's start-cased name when none: "Internal Link").
      pill: () => this.hasAttribute("block-cards"),
      label: (info) => {
        const titles = (this._toolbarVocabulary() || {}).annotationTitles || {};
        if (info.kind === "link") return titles.link || t("Link");
        return titles.wikilink || titles.internalLink || t("Internal Link");
      },
      resolve: (info) => (typeof this._linkPreviewSource === "function" ? this._linkPreviewSource(info) : null),
      known: (info) => wikilinkInfo(this._editor, info),
      onMissing: (info, missing) => setWikilinkMissing(this._editor, info, missing),
      onOpen: (detail) => {
        const ev = new CustomEvent("bp-canvas-open-link", { detail, bubbles: true, composed: true, cancelable: true });
        const go = this.dispatchEvent(ev);
        if (go && detail.kind === "link" && detail.href && typeof window !== "undefined" && window.open) {
          try { window.open(detail.href, "_blank", "noopener,noreferrer"); } catch (_e) {}
        }
      },
      onEdit: (detail) => {
        if (detail.kind === "link" && this._bubble) this._bubble.openLink();
        else if (this._bubble) this._bubble.update();
        else if (detail.kind === "link") this._requestHostLink();
      },
    });

    this._restSelectionOffAtom();
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
    if (name === "format-bubble") {
      if (!this._editor || this._editor.isDestroyed || !this._editable) return;
      if (!this._wantsBubble() && this._bubble) {
        this._bubble.destroy();
        this._bubble = null;
      } else if (this._wantsBubble() && !this._bubble) {
        this._bubble = new FormatBubble({ editor: this._editor });
        this._bubble.update();
      }
      return;
    }
    if (name === "editable") {
      // A run that failed to mount stays read-only whatever the host asks.
      this._editable = val !== "false" && !this._mountFailure;
      if (this._editor) this._editor.setEditable(this._editable);
    }
  }

  disconnectedCallback() {
    this._clearHTMLPasteNotice();
    // LiveView may move this keyed canvas between responsive Studio columns.
    // Custom-element reactions report that connected-to-connected reparent as a
    // disconnect followed synchronously by a reconnect. Defer destructive
    // teardown one microtask so the same editor, history, and pending debounce
    // survive that move; a genuine removal is still torn down immediately after
    // the current DOM mutation finishes.
    const editor = this._editor;
    const ownerDocument = this.ownerDocument;
    const restoreRichFocus =
      this._mode === "rich" &&
      this._editable &&
      editor?.isEditable === true &&
      this._richFocusIntent === true;
    queueMicrotask(() => {
      if (!this.isConnected) {
        this._teardownDisconnected();
        return;
      }

      // A DOM move drops native focus to <body>; Blink also delivers a blur that
      // clears TipTap's live isFocused flag before this microtask. The value
      // captured above is the pre-move intent. Restore only that narrow case. A
      // prior blur, any meaningful intervening focus, an editor replacement,
      // source mode, read mode, cross-document move, or inert destination wins.
      const activeElement = ownerDocument?.activeElement;
      const focusIsEmpty =
        activeElement == null ||
        activeElement === ownerDocument.body ||
        activeElement === ownerDocument.documentElement;
      if (
        restoreRichFocus &&
        this._editor === editor &&
        this.ownerDocument === ownerDocument &&
        this._mode === "rich" &&
        this._editable &&
        editor.isEditable === true &&
        this.closest("[inert]") == null &&
        focusIsEmpty
      ) {
        editor.view.focus();
      }
    });
  }

  captureResumeFocus() {
    if (this._resumeFocusState !== "idle") {
      return this._resumeFocusState === "armed";
    }

    const editor = this._editor;
    const ownerDocument = this.ownerDocument;
    const activeElement = ownerDocument?.activeElement;
    const paperRoot = this.closest(".bp-paper-editor[data-paper-doc-key]");
    const paperRootId = paperRoot?.id;
    const paperDocKey = paperRoot?.getAttribute("data-paper-doc-key");
    const hasRichFocus =
      editor?.view?.hasFocus?.() === true &&
      activeElement != null &&
      this.contains(activeElement);

    if (
      !this.isConnected ||
      this._mode !== "rich" ||
      !this._editable ||
      editor?.isEditable !== true ||
      !hasRichFocus ||
      !paperRoot ||
      !paperRootId ||
      !paperDocKey
    ) {
      return false;
    }

    this._resumeFocusIntent = {
      editor,
      ownerDocument,
      paperRootId,
      paperDocKey,
    };
    this._resumeFocusState = "armed";
    this._onResumeFocusIn = (event) => {
      const target = event.target;
      const emptyFocusTarget =
        target == null || target === ownerDocument.body || target === ownerDocument.documentElement;
      if (!emptyFocusTarget && !this.contains(target)) this._cancelResumeFocus();
    };
    ownerDocument.addEventListener("focusin", this._onResumeFocusIn, true);
    return true;
  }

  restoreResumeFocus() {
    const intent = this._resumeFocusIntent;
    const armed = this._resumeFocusState === "armed";
    this._clearResumeFocusIntent();
    if (!armed || !intent) return false;

    const { editor, ownerDocument, paperRootId, paperDocKey } = intent;
    const activeElement = ownerDocument?.activeElement;
    const paperRoot = this.closest(".bp-paper-editor[data-paper-doc-key]");
    const focusIsEmpty =
      activeElement == null ||
      activeElement === ownerDocument.body ||
      activeElement === ownerDocument.documentElement;

    if (
      !this.isConnected ||
      this._editor !== editor ||
      this.ownerDocument !== ownerDocument ||
      this._mode !== "rich" ||
      !this._editable ||
      editor.isEditable !== true ||
      paperRoot?.id !== paperRootId ||
      paperRoot?.getAttribute("data-paper-doc-key") !== paperDocKey ||
      this.closest("[inert]") != null ||
      !focusIsEmpty
    ) {
      return false;
    }

    editor.view.focus();
    return true;
  }

  _cancelResumeFocus() {
    if (this._resumeFocusState !== "armed") return;
    const ownerDocument = this._resumeFocusIntent?.ownerDocument;
    if (ownerDocument && this._onResumeFocusIn) {
      ownerDocument.removeEventListener("focusin", this._onResumeFocusIn, true);
    }
    this._resumeFocusIntent = null;
    this._resumeFocusState = "cancelled";
    this._onResumeFocusIn = null;
  }

  _clearResumeFocusIntent() {
    const ownerDocument = this._resumeFocusIntent?.ownerDocument;
    if (ownerDocument && this._onResumeFocusIn) {
      ownerDocument.removeEventListener("focusin", this._onResumeFocusIn, true);
    }
    this._resumeFocusIntent = null;
    this._resumeFocusState = "idle";
    this._onResumeFocusIn = null;
  }

  _teardownDisconnected() {
    this._uploadResults.clear();
    if (this._selectionFrame != null) {
      cancelAnimationFrame(this._selectionFrame);
      this._selectionFrame = null;
    }
    if (this._toolbarFrame != null) {
      cancelAnimationFrame(this._toolbarFrame);
      this._toolbarFrame = null;
    }
    if (this._commentRangesFrame != null) {
      cancelAnimationFrame(this._commentRangesFrame);
      this._commentRangesFrame = null;
    }
    this._clearResumeFocusIntent();
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    this._debounceBaselineBlocks = null;
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
    if (this._linkPreview) {
      this._linkPreview.destroy();
      this._linkPreview = null;
    }
    if (this._composeEndEmit && this._mount) {
      this._mount.removeEventListener("compositionend", this._composeEndEmit, true);
      this._composeEndEmit = null;
    }
    if (this._mount && this._onCompStart) {
      this._mount.removeEventListener("compositionstart", this._onCompStart, true);
      this._mount.removeEventListener("compositionend", this._onCompEnd, true);
    }
    this._pageWindow?.removeEventListener("pagehide", this._onPageHide);
    clearTimeout(this._compEndTimer);
    this._compStart = null;
    if (this._handle) {
      this._handle.destroy();
      this._handle = null;
    }
    // P5 source-mode: tear down the markdown textarea + its keydown listener if the
    // element disconnects while in source mode (so neither the node nor the listener
    // leaks). Reset the mode bookkeeping; the editor.destroy() below frees the rest.
    this._teardownSourceEl();
    this._sourceBaselineBlocks = null;
    this._sourceCommitBlocks = null;
    this._sourceOriginalMd = "";
    this._mode = "rich";
    this._richFocusIntentVersion += 1;
    this._richFocusIntent = false;
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
      if (!this._flushKeepsSource) return this._exitSourceMode();
      // flushKeepsSource: the Markdown is committed in place (1.20.0).
      const md = this._sourceEl.value;
      return md === this._sourceOriginalMd ? false : this._commitSource(md);
    }

    // Node-view controls (code, captions, field inputs, and component editors)
    // debounce their own attributes before they reach ProseMirror. Commit those
    // islands first; their transactions schedule the canvas batch below.
    this.querySelectorAll("[data-bp-type]").forEach((node) => {
      node.dispatchEvent(new CustomEvent("bp-flush-node"));
    });
    this._readDomTyping();

    // Mid-composition, the text committed around the composing run (see _committedDoc).
    const composing = this._compStart != null && !!this._editor.view?.composing;
    if (!this._debounceTimer && !this._compEndTimer && !composing) return false;
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    clearTimeout(this._compEndTimer);
    this._compEndTimer = null;
    return this._emitOps();
  }

  setRemoteSelections(list) {
    return hostApiMethods.setRemoteSelections.call(this, list);
  }

  setCommentRanges(list) {
    return hostApiMethods.setCommentRanges.call(this, list);
  }

  commentRanges() {
    return hostApiMethods.commentRanges.call(this);
  }

  commentsInSelection() {
    return hostApiMethods.commentsInSelection.call(this);
  }

  _scheduleCommentRangesEmit() {
    return hostApiMethods._scheduleCommentRangesEmit.call(this);
  }

  _scheduleSelectionEmit() {
    return hostApiMethods._scheduleSelectionEmit.call(this);
  }

  _wantsBubble() {
    return hostApiMethods._wantsBubble.call(this);
  }

  _requestHostLink() {
    return hostApiMethods._requestHostLink.call(this);
  }

  _readDomTyping() {
    return hostApiMethods._readDomTyping.call(this);
  }

  _escapeForHost(view, event) {
    return hostApiMethods._escapeForHost.call(this, view, event);
  }

  _modEnterForHost(view, event) {
    return hostApiMethods._modEnterForHost.call(this, view, event);
  }

  _swallowModEnter(event) {
    return hostApiMethods._swallowModEnter.call(this, event);
  }

  _wikilinkClicked(event) {
    return hostApiMethods._wikilinkClicked.call(this, event);
  }

  _flushDomSelection() {
    return hostApiMethods._flushDomSelection.call(this);
  }

  run(command, args = {}) {
    return hostApiMethods.run.call(this, command, args);
  }

  toggleMark(mark, attrs) {
    return hostApiMethods.toggleMark.call(this, mark, attrs);
  }
  setBlockStyle(style) {
    return hostApiMethods.setBlockStyle.call(this, style);
  }
  toggleList(kind) {
    return hostApiMethods.toggleList.call(this, kind);
  }
  insertBlock(type, attrs) {
    return hostApiMethods.insertBlock.call(this, type, attrs);
  }
  insertInline(type) {
    return hostApiMethods.insertInline.call(this, type);
  }
  undo() {
    return hostApiMethods.undo.call(this);
  }
  redo() {
    return hostApiMethods.redo.call(this);
  }

  can(command, args = {}) {
    return hostApiMethods.can.call(this, command, args);
  }

  state() {
    return hostApiMethods.state.call(this);
  }

  _toolbarVocabulary() {
    return hostApiMethods._toolbarVocabulary.call(this);
  }

  _toolbarInsertItem(type) {
    return hostApiMethods._toolbarInsertItem.call(this, type);
  }

  _canInsertInline(type, vocab) {
    return hostApiMethods._canInsertInline.call(this, type, vocab);
  }

  _insertToolbarInline(type) {
    return hostApiMethods._insertToolbarInline.call(this, type);
  }

  _insertToolbarBlock(type, attrs) {
    return hostApiMethods._insertToolbarBlock.call(this, type, attrs);
  }

  _emitHistory(transaction) {
    return hostApiMethods._emitHistory.call(this, transaction);
  }

  _scheduleToolbarState() {
    return hostApiMethods._scheduleToolbarState.call(this);
  }

  findSet(query, opts) {
    return hostApiMethods.findSet.call(this, query, opts);
  }
  findNext() {
    return hostApiMethods.findNext.call(this);
  }
  findPrev() {
    return hostApiMethods.findPrev.call(this);
  }
  findClear() {
    return hostApiMethods.findClear.call(this);
  }
  findState() {
    return hostApiMethods.findState.call(this);
  }
  replaceCurrent(text) {
    return hostApiMethods.replaceCurrent.call(this, text);
  }
  replaceAll(text) {
    return hostApiMethods.replaceAll.call(this, text);
  }

  hasPendingChanges() {
    return hostApiMethods.hasPendingChanges.call(this);
  }

  recoverySnapshot() {
    return hostApiMethods.recoverySnapshot.call(this);
  }

  resolveConflictWithServerBlocks(blocks) {
    return hostApiMethods.resolveConflictWithServerBlocks.call(this, blocks);
  }

  _scheduleEmit() {
    if (!this._editable) return; // read mode emits no ops
    if (!this._debounceTimer) {
      // The reference, not a deep clone: `_blocks` is only ever REPLACED (never
      // edited in place), so a later broadcast cannot change what this holds. The
      // clone cost a full copy of the run at the first key of every window
      // (task-fb938eb8be3bce48).
      this._debounceBaselineBlocks = this._blocks;
    }
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      // An IME composition still open when the debounce fires (a dead key held, a CJK run being
      // picked): ProseMirror has already read the candidate text into the doc, so emitting now would
      // send the half-composed run as a patch, then the committed one as another (Barkdown row 15).
      // Hold the timer instead; compositionend re-arms it and the run lands once.
      // Since task-39cb3d6e4709054e the text committed around it still goes: _emitOps sends the
      // run without the composing range (or holds, when it cannot), and compositionend sends
      // the composed text.
      if (this._editor && this._editor.view && this._editor.view.composing) {
        this._debounceTimer = null;
        this._emitOps();
        return;
      }
      this._debounceTimer = null;
      const emitted = this._emitOps();
      // An external echo can arrive after blur but before this debounce fires.
      // If the local transaction normalized to no PortableDoc change, no save/echo
      // will release it, so apply the queued authority now. A real emitted batch
      // remains protected by the in-flight/own-echo acknowledgement path.
      if (!emitted) this._flushPendingServerBlocks();
    }, DEBOUNCE_MS);
  }

  // One-shot: when the IME releases, run the debounce path at once (still debounced by
  // DEBOUNCE_MS from the release, so a commit followed by more typing stays one batch).
  _armComposeEndEmit() {
    if (this._composeEndEmit || !this._mount) return;
    this._composeEndEmit = () => {
      this._mount.removeEventListener("compositionend", this._composeEndEmit, true);
      this._composeEndEmit = null;
      if (this._debounceTimer) { clearTimeout(this._debounceTimer); this._debounceTimer = null; }
      this._scheduleEmit();
    };
    this._mount.addEventListener("compositionend", this._composeEndEmit, true);
  }

  // Diff the live doc against the current baseline run and, if anything changed,
  // emit the ordered op array S0 produces. The diff is runToOps VERBATIM — the
  // canvas is a thin shell over S0's PURE projector/op-mapper.
  //
  // `_blocks` advances when the bridge acknowledges the one in-flight batch, so
  // the next dispatch is incremental even if its server echo arrives later.
  // The live doc as the emit diffs it: a repeated id stays with the copy the
  // baseline knew (freshenRepeatedIds), so every reader agrees with the next batch.
  _normalizedDoc(doc) {
    return normalizeCanvasDoc(doc, this._debounceBaselineBlocks || this._blocks);
  }

  _emitOps() {
    if (!this._editor) return false;
    // Never the half-composed run (see _scheduleEmit): mid-composition the doc holds the IME's
    // candidate text, so the run goes without the composing range (_committedDoc), or waits
    // for compositionend when that range cannot be told apart.
    const composing = !!(this._editor.view && this._editor.view.composing);
    let source = null;
    if (composing) {
      source = this._committedDoc();
      if (!source) { this._armComposeEndEmit(); return false; }
    }
    const diffBaseline = this._debounceBaselineBlocks || this._blocks;
    const nextDoc = this._normalizedDoc(source ? source.toJSON() : this._editor.getJSON());
    // The fast path (task-fb938eb8be3bce48): a top-level node that is the SAME
    // ProseMirror node object it was at the last acknowledged emit is unchanged
    // since then, and when the baseline is exactly that emit's after-state its
    // block, its projection and its (empty) patch are already known. Only the
    // nodes a transaction touched are projected and diffed.
    const liveTop = [];
    (source || this._editor.state.doc).forEach((node) => liveTop.push(node));
    const reuse = this._emitReuse(diffBaseline);
    const reusedAt = new Map();
    const unchangedIds = new Set();
    if (reuse) {
      liveTop.forEach((node, i) => {
        const hit = reuse.get(node);
        const json = (nextDoc.content || [])[i];
        // A duplicated bpId was nulled by normalizeCanvasDoc: that node is new.
        if (hit && json && json.attrs && json.attrs.bpId === hit.block.id) {
          reusedAt.set(i, hit);
          unchangedIds.add(hit.block.id);
        }
      });
    }
    const nextBlocks = docToBlocks(nextDoc, reusedAt.size ? { reuse: (i) => reusedAt.get(i)?.block } : {});
    const stableDoc = reusedAt.size
      ? { type: "doc", content: nextBlocks.map((block, i) => reusedAt.has(i) ? reusedAt.get(i).node : this._rt([block]).content[0]) }
      : this._rt(nextBlocks);

    // runToOps mints ids for null-id nodes. Materialize those ids in the live
    // document before another edit can diff, otherwise each cumulative diff
    // invents a different id for the same inserted paragraph.
    // An id stamp is a transaction, and one mid-composition can break the IME: wait.
    if (composing && this._stampMaterializedIds(stableDoc, nextDoc, { dryRun: true })) { this._armComposeEndEmit(); return false; }
    this._stampMaterializedIds(stableDoc, nextDoc);
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }

    if (this._inflightOps) {
      this._dirtyWhileInflight = true;
      return false;
    }

    this._debounceBaselineBlocks = null;
    // A picture still uploading, or whose upload failed, is not sent (run-convert.js
    // pendingUploadIndexes). stableDoc keeps it above so ids materialize by position.
    const held = pendingUploadIndexes(nextDoc, diffBaseline);
    // Indexes are top-level positions in the live doc; they apply only while the
    // round-trip kept one top-level node per live node (otherwise nothing is held).
    const aligned = (nextDoc.content || []).length === (stableDoc.content || []).length;
    const opsDoc = held.size && aligned ? { ...stableDoc, content: (stableDoc.content || []).filter((_, i) => !held.has(i)) } : stableDoc;
    const ops = this._ro(diffBaseline, opsDoc, { preserveNewIds: true, unchangedIds });
    // Mid-composition with nothing committed to send: not "nothing to save" (bp-noop would
    // tell the page's exit guard all is saved, with the composing run still unsent).
    if (composing && (!ops || !ops.length)) return false;
    if (!ops || !ops.length) {
      // Nothing to save: the edits since the last batch cancelled out (typed,
      // then undone inside one debounce). Say so. The page's exit guard marked
      // this run dirty on the native input, and without this signal no save
      // ever arrives to clear it, so leaving the page warned about unsaved
      // changes that were never there.
      this.dispatchEvent(new CustomEvent("bp-noop", { bubbles: true, composed: true }));
      return false;
    }
    const dispatched = this._dispatchOps(ops, nextBlocks, diffBaseline);
    if (dispatched) this._rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc);
    return dispatched;
  }

  // The doc to save during an IME composition: the live doc without the composing run
  // (compositionstart's position, mapped, to the caret: plain text in one text block, and
  // that block grown by exactly that run since compositionstart). null when the run cannot
  // be told apart; the emit then waits for compositionend, as before.
  _committedDoc() {
    const { state } = this._editor;
    if (this._compStart == null) return null;
    const head = state.selection.head;
    const from = Math.min(this._compStart, head);
    const to = Math.max(this._compStart, head);
    let $from;
    let $to;
    try {
      $from = state.doc.resolve(from);
      $to = state.doc.resolve(to);
    } catch (_e) {
      return null;
    }
    if (!$from.parent.isTextblock || $from.parent !== $to.parent) return null;
    if ($from.parent.content.size - (to - from) !== this._compBlockSize) return null;
    let textOnly = true;
    state.doc.nodesBetween(from, to, (node) => { if (node.isInline && !node.isText) textOnly = false; });
    if (!textOnly) return null;
    return from === to ? state.doc : state.tr.delete(from, to).doc;
  }

  // A committed phrase is saved at once, not DEBOUNCE_MS later (by when a CJK writer has
  // opened the next composition, and the debounce held again: 0 characters stored in 12.5 s
  // of continuous typing). ProseMirror reads the committed text a moment after compositionend.
  _afterComposition() {
    this._compStart = null;
    clearTimeout(this._compEndTimer);
    this._compEndTimer = setTimeout(() => {
      this._compEndTimer = null;
      if (!this._editor || this._editor.isDestroyed || !this._editable || this._mode === "source") return;
      if (this._debounceTimer) {
        clearTimeout(this._debounceTimer);
        this._debounceTimer = null;
      }
      const emitted = this._emitOps();
      if (!emitted && !(this._editor.view && this._editor.view.composing)) this._flushPendingServerBlocks();
    }, COMPOSE_SETTLE_MS);
  }

  // The fast path's memory of one emit (task-fb938eb8be3bce48): each top-level
  // node with a stable id that the id stamp left untouched, keyed by the node
  // object, with the block and projection this emit gave it. It becomes usable
  // only when the bridge acknowledges this exact batch (acknowledgeOps sets
  // `blocks`): from then on a baseline that IS that acknowledged run equals this
  // emit's blocks, so an untouched node has nothing to patch.
  _rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc) {
    this._emitCache = null;
    if (!this._inflightOps) return;
    const afterStamp = [];
    this._editor.state.doc.forEach((node) => afterStamp.push(node));
    if (afterStamp.length !== liveTop.length) return;
    const nodes = new Map();
    liveTop.forEach((node, i) => {
      const json = (nextDoc.content || [])[i];
      const block = nextBlocks[i];
      if (afterStamp[i] !== node || !block || !json || !json.attrs) return;
      if (json.attrs.bpId == null || json.attrs.bpId !== block.id) return;
      nodes.set(node, { block, node: stableDoc.content[i] });
    });
    this._emitCache = { nodes, afterBlocks: this._inflightOps.afterBlocks, blocks: null };
  }

  // The remembered nodes, when `diffBaseline` is exactly the run the remembered
  // emit's acknowledgement installed; otherwise null and every node is projected.
  // Any other writer of `_blocks` (an echo, a remote update, setContent) replaces
  // the array, so the identity check sends it down the full path.
  _emitReuse(diffBaseline) {
    const cache = this._emitCache;
    if (!cache || !cache.blocks || diffBaseline !== cache.blocks) return null;
    return cache.nodes;
  }

  // Dispatch one op array for the LiveView hook to fold and retain its after-state
  // until the hook acknowledges the exact sequence. A zero-length array is a no-op.
  _dispatchOps(ops, nextBlocks = null, diffBaseline = this._blocks) {
    if (!ops || !ops.length) return false;
    const conflictBlocks = hasOverlappingOps(ops, diffBaseline, this._pendingServerBlocks)
      ? deepCloneBlocks(this._pendingServerBlocks)
      : null;
    const seq = this._acknowledgedSaves ? ++this._opsSeq : undefined;
    if (this._acknowledgedSaves) {
      this._inflightOps = {
        seq,
        ops,
        // A fresh array over this emit's own blocks: nextBlocks was built for this
        // call (its reused entries are shared, never edited in place), so a deep
        // copy of the whole run per keystroke bought nothing (task-fb938eb8be3bce48).
        afterBlocks: nextBlocks ? nextBlocks.slice() : deepCloneBlocks(this._blocks),
        // The run these ops were diffed against, so the bridge can ask whether
        // they still apply on a newer stored version (rebaseSafe).
        baseline: diffBaseline,
        pendingServerBlocks: this._pendingServerBlocks,
        echoSeen: false,
        requestId: null,
      };
    }
    this.dispatchEvent(
      new CustomEvent("bp-canvas-ops", {
        detail: { ...(seq == null ? { ops } : { ops, seq }),
          ...(conflictBlocks ? { conflictBlocks } : {}) },
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  }

  // Called by the LiveView bridge after the exact `paper-ops` request settles.
  // Failure retains the batch so the bridge can retry it byte-for-byte. Success
  // advances the local baseline and releases any edits made while it was pending.
  identifyOpsRequest(seq, requestId, previousRequestId = null) {
    const current = this._inflightOps;
    if (!current || current.seq !== seq || typeof requestId !== "string" || requestId === "") {
      return false;
    }
    // Explicit Keep mine changes the retry identity. Require the bridge to name
    // the exact old request before rebinding an already identified snapshot.
    if (current.requestId && current.requestId !== requestId &&
        previousRequestId !== current.requestId) return false;
    current.requestId = requestId;
    return true;
  }

  // Whether the in-flight batch `seq` can be resent unchanged on the newer
  // stored version `serverBlocks` of this run: its ops address blocks by id and
  // touch nothing the other writer changed (opsRebaseSafe). The bridge asks this
  // when the server refuses the batch because another session saved first.
  rebaseSafe(seq, serverBlocks) {
    const current = this._inflightOps;
    if (!current || current.seq !== seq) return false;
    return opsRebaseSafe(current.ops, current.baseline || this._blocks, serverBlocks);
  }

  // Whether the edits this canvas still holds (an in-flight batch and/or a
  // draft not yet sent) can ride on top of `serverBlocks`, a newer version
  // another session saved: the same test as rebaseSafe, over everything local.
  // True means "no conflict to show yet"; the save itself rebases.
  localEditsRebaseSafe(serverBlocks) {
    if (!this._editor || !Array.isArray(serverBlocks)) return false;
    const inflight = this._inflightOps;
    if (inflight && !opsRebaseSafe(inflight.ops, inflight.baseline || this._blocks, serverBlocks)) {
      return false;
    }
    const draftBase = inflight ? inflight.afterBlocks : (this._debounceBaselineBlocks || this._blocks);
    const draft = this._ro(draftBase, normalizeCanvasDoc(this._editor.getJSON(), draftBase), { preserveNewIds: true }) || [];
    if (!draft.length) return true;
    // Behind an in-flight batch the run's shape was already checked above; the
    // draft only must not touch what the other writer changed.
    if (inflight) {
      return draft.every((op) => ["patch-block", "remove-block", "insert-after", "append-block"].includes(op.op)) &&
        !hasOverlappingOps(draft, draftBase, serverBlocks);
    }
    return opsRebaseSafe(draft, draftBase, serverBlocks);
  }

  acknowledgeOps(seq, saved) {
    if (!this._acknowledgedSaves) return false;
    const current = this._inflightOps;
    if (!current || current.seq !== seq) return false;
    // A `saved:false` acknowledgement keeps the batch in flight: the Studio host's
    // contract is that a failed head stays pending and its Retry resends the same
    // batch verbatim, with later edits waiting behind it (__save_ack_mounted). A host
    // that wants the other behaviour — drop the refused batch and fold it into the
    // next edit — calls discardInflightOps(seq) instead.
    if (saved !== true) return false;
    this._inlineSavePending = null;

    // Diff against the local snapshot the author still sees. A canonical reply
    // can contain remote sibling changes queued for later display; advancing
    // to those unseen values would turn the next local edit into a reversion.
    this._blocks = deepCloneBlocks(current.afterBlocks);
    if (this._emitCache && this._emitCache.afterBlocks === current.afterBlocks) {
      this._emitCache.blocks = this._blocks;
    }
    // A successful reviewed write supersedes the overlapping fields in the
    // deferred snapshot it was authored against. Keep remote sibling data, but
    // do not compare continued typing against those now-obsolete field values
    // while the canonical echo is still travelling. A newer queued snapshot
    // must retain its authority and still gets an independent overlap check.
    if (current.pendingServerBlocks && this._pendingServerBlocks === current.pendingServerBlocks) {
      const pending = deepCloneBlocks(this._pendingServerBlocks);
      for (const op of current.ops) {
        if (op.op !== "patch-block") continue;
        const block = pending.find((item) => item.id === op.id);
        if (block) Object.assign(block, JSON.parse(JSON.stringify(op.patch)));
      }
      this._pendingServerBlocks = pending;
    }
    // A newer local edit may still be inside its debounce while this earlier
    // batch is acknowledged. Advance that draft's captured baseline with the
    // confirmed local snapshot so its next diff stays incremental.
    if (this._debounceBaselineBlocks) {
      // The run just installed holds the same content; share it (it is never
      // edited in place), so the fast path recognises this baseline too.
      this._debounceBaselineBlocks = this._blocks;
    }
    if (!current.echoSeen) {
      this._awaitingOwnEchoes.push({
        blocks: deepCloneBlocks(current.afterBlocks),
        requestId: current.requestId,
        ids: opBlockIds(current.ops),
      });
    }
    this._inflightOps = null;
    const dirty = this._dirtyWhileInflight;
    this._dirtyWhileInflight = false;
    if (dirty) this._emitOps();
    else this._flushPendingServerBlocks();
    return true;
  }

  // The host's OTHER answer to a refused batch (a lifecycle veto such as "a published
  // paper cannot be hollowed out", or a request that will not succeed by retrying):
  // drop the in-flight batch WITHOUT advancing the baseline. `_blocks` still holds the
  // last SAVED snapshot, so the next local edit diffs against it and carries the
  // refused change along — the author keeps what they see, and it lands as soon as
  // the server will take it (a batch that would hollow the paper saves once they
  // write again). Edits made while the batch was travelling are emitted now: that
  // diff already differs from the refused one. An unchanged vetoed batch is never
  // resent on its own; resendPendingOps() is the host's explicit "try again".
  // Without this seam a refused batch pinned the pipeline: every later edit queued
  // behind it, never sent (found by Barkdown's editor-multiblock row: cut all, type).
  //
  // `refusal` (optional) is the host's reason for the refusal, `{reason}`. When
  // the refused batch carried an inline object the field dialog just saved, the
  // dialog reopens on that object with the reason on the field it names
  // (task-85fee859cf3bfef6), instead of only the host's generic notice.
  discardInflightOps(seq, refusal) {
    if (!this._acknowledgedSaves) return false;
    const current = this._inflightOps;
    if (!current || current.seq !== seq) return false;
    this._inflightOps = null;
    this._reopenRefusedInlineObject(refusal);
    const dirty = this._dirtyWhileInflight;
    this._dirtyWhileInflight = false;
    if (dirty) this._emitOps();
    return true;
  }

  // ── inline objects (./inline-object.js) ───────────────────────────────────
  // Declared object block names that win over a same-named built-in
  // (task-5bc7771edf30199a), cached per data-vocabulary string. Every
  // run-convert projection this canvas makes runs inside them (_rt/_ro/_re).
  _objectOverrides() {
    const raw = this.getAttribute("data-vocabulary") || "";
    if (this._overridesFor !== raw) {
      this._overridesFor = raw;
      const vocab = parseVocabulary(raw);
      this._overrides = new Set(((vocab && vocab.objects) || []).map((o) => o.name));
    }
    return this._overrides;
  }

  _rt(blocks) {
    return withObjectOverrides(this._objectOverrides(), () => runToTiptap(blocks));
  }

  _ro(...args) {
    return withObjectOverrides(this._objectOverrides(), () => runToOps(...args));
  }

  _re(...args) {
    return withObjectOverrides(this._objectOverrides(), () => reconcileServerEcho(...args));
  }

  _inlineObjectVocabulary() {
    return parseVocabulary(this.getAttribute("data-vocabulary"));
  }

  _inlineObjectDialog() {
    // A host editor (editBlockObject) takes every object insert and edit; else the popover.
    if (this._editBlockObject) {
      if (!this._hostObjectDialog) this._hostObjectDialog = new HostObjectDialog((request) => this._editBlockObject(request));
      return this._hostObjectDialog;
    }
    if (!this._inlineDialog) this._inlineDialog = new InlineObjectDialog();
    return this._inlineDialog;
  }

  // The host's editor for declared objects. Set: inserting or editing a block or
  // inline object asks it instead of opening the popover. Unset: the popover.
  set editBlockObject(fn) {
    const next = typeof fn === "function" ? fn : null;
    if (next !== this._editBlockObject) {
      if (this._hostObjectDialog) this._hostObjectDialog.close(false);
      if (this._inlineDialog) this._inlineDialog.close(false);
    }
    this._editBlockObject = next;
  }

  get editBlockObject() {
    return this._editBlockObject;
  }

  // Whether a declared object's editor is open (the popover or the host's).
  _objectEditorOpen() {
    return !!((this._inlineDialog && this._inlineDialog.isOpen()) || (this._hostObjectDialog && this._hostObjectDialog.isOpen()));
  }

  // The value the dialog just saved: the batch that carries it is the one a
  // refusal would name.
  _noteInlineObjectSave(values) {
    this._inlineSavePending = values;
  }

  _reopenRefusedInlineObject(refusal) {
    const values = this._inlineSavePending;
    this._inlineSavePending = null;
    const reason = refusal && typeof refusal.reason === "string" ? refusal.reason : "";
    if (!values || reason === "" || !this._editor) return false;
    let at = null;
    let block = false;
    this._editor.state.doc.descendants((node, pos) => {
      if (at != null) return;
      if (node.type.name === "bpInlineOpaque" && JSON.stringify(node.attrs.node) === JSON.stringify(values)) at = pos;
      if (node.type.name === "bpOpaque" && JSON.stringify(node.attrs.bpBlock) === JSON.stringify(values)) {
        at = pos;
        block = true;
      }
    });
    if (at == null) return false;
    const vocab = this._inlineObjectVocabulary();
    const kind = ((block ? vocab?.objects : vocab?.inlineObjects) || []).find((o) => o.name === values.type);
    const message = reason.replace(/^[^\s:]+: /, "");
    const error = { field: refusalField(reason, kind ? kind.fields : []), message };
    return block ? editObjectBlockAt(this, this._editor, at, error) : editInlineObjectAt(this, this._editor, at, error);
  }

  // Re-diff the live document against the saved baseline and emit the batch, if any
  // and if nothing is in flight. The host's Retry after discardInflightOps: it must
  // NOT resend the discarded ops (an insert would land twice); it asks for a fresh diff.
  resendPendingOps() {
    if (this._inflightOps || !this._editor) return false;
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    return this._emitOps() === true;
  }

  _onKeyDown(event) {
    return keyboardMethods._onKeyDown.call(this, event);
  }

  _onPaste(view, _event, slice) {
    return pasteMediaMethods._onPaste.call(this, view, _event, slice);
  }

  // Plain-text paste that carries markdown block syntax (headings, lists, quotes, fences, rules)
  // lands as the corresponding blocks instead of literal `## ` and `- ` paragraphs. HTML on the
  // clipboard keeps the native path (the browser already structured it); a single plain line too.
  // ── pasted / dropped pictures ────────────────────────────────────────────────
  //
  // A picture on the clipboard or dropped on the canvas becomes a bpImage node at
  // once (its alt is the file name, its src is empty, a local object URL previews
  // it), then uploads through the host-injected mediaUploader; when the upload
  // lands the node's src is set (one patch-block), a failure stays on the node.
  // Without an uploader the node says so instead of storing a data: URL.
  static _imageFiles(list) {
    return [...(list || [])].filter((f) => f && typeof f.type === "string" && f.type.startsWith("image/"));
  }

  _pasteImageFiles(view, event, imageAlt = null) {
    const files = BpPaperCanvas._imageFiles(event && event.clipboardData && event.clipboardData.files);
    if (!files.length) return false;
    this._insertImageFiles(view, files, null, imageAlt);
    return true;
  }

  _onDrop(view, event, moved) {
    if (!this._editable || moved || isFigureSingletonCanvas(this)) return false;
    const files = BpPaperCanvas._imageFiles(event && event.dataTransfer && event.dataTransfer.files);
    if (!files.length) return false;
    const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
    this._insertImageFiles(view, files, at ? at.pos : null);
    event.preventDefault();
    return true;
  }

  _insertImageFiles(view, files, atPos, imageAlt = null) {
    return pasteMediaMethods._insertImageFiles.call(this, view, files, atPos, imageAlt);
  }

  _findUploadNode(key) {
    return pasteMediaMethods._findUploadNode.call(this, key);
  }

  _patchUploadNode(key, receipt) {
    return pasteMediaMethods._patchUploadNode.call(this, key, receipt);
  }

  _restoreUploadResults() {
    return pasteMediaMethods._restoreUploadResults.call(this);
  }

  async _uploadImage(key, file, previewUrl) {
    const uploader = this._mediaUploader;
    const editor = this._editor;
    const initialAlt = this._findUploadNode(key)?.node.attrs.alt;
    const release = () => { if (previewUrl) { try { URL.revokeObjectURL(previewUrl); } catch (_) {} } };
    const settle = patch => {
      // A disconnected/remounted canvas must never consume an old callback.
      if (this._editor !== editor || editor.isDestroyed) return;
      const receipt = { editor, initialAlt, patch: { ...patch, uploadKey: null } };
      this._uploadResults.set(key, receipt);
      this._patchUploadNode(key, receipt);
    };
    if (typeof uploader !== "function") {
      settle({ uploading: null, uploadError: "no media uploader is connected" });
      return;
    }
    try {
      const result = await uploader(file);
      const src = result && typeof result === "object" ? result.src || result.url || "" : String(result || "");
      if (!src) throw new Error("the uploader returned no url");
      const patch = { src, uploading: null, uploadError: null, previewUrl: null };
      if (result && result.alt) patch.alt = String(result.alt);
      settle(patch);
      // Let the <img> switch to the uploaded source before the object URL goes.
      setTimeout(release, 2000);
    } catch (e) {
      settle({ uploading: null, uploadError: (e && e.message) || String(e) });
      setTimeout(release, 60000);
    }
  }

  set mediaUploader(fn) {
    return pasteMediaMethods.setMediaUploader.call(this, fn);
  }

  set mediaPicker(fn) {
    return pasteMediaMethods.setMediaPicker.call(this, fn);
  }

  get mediaPicker() {
    return pasteMediaMethods.getMediaPicker.call(this);
  }

  // Run the host's picker for the image at `pos`; its answer becomes the image's src
  // (and alt / width when given) in one undo step. null, a throw or a refused src
  // leaves it as it was.
  async _pickImageAt(pos) {
    const picker = this._mediaPicker;
    const editor = this._editor;
    if (typeof picker !== "function" || !editor || editor.isDestroyed || !this._editable) return false;
    const node = editor.state.doc.nodeAt(pos);
    if (!node || node.type.name !== "bpImage") return false;
    const id = node.attrs.bpId;
    let picked = null;
    try {
      picked = await picker({ kind: node.attrs.src ? "replace" : "insert", current: node.attrs.src ? { src: node.attrs.src, alt: node.attrs.alt || null } : null });
    } catch (_e) {
      return false;
    }
    if (this._editor !== editor || editor.isDestroyed || !picked || typeof picked.src !== "string") return false;
    // The image node paints src through the reader's allowlist (safeUrl): a src it would
    // refuse (javascript:, data:, protocol-relative) is not stored at all.
    const src = safeUrl(picked.src.trim());
    if (src === "#" || src.trim() === "") return false;
    // The image may have moved meanwhile: find it again, by id when it has one.
    let at = null;
    editor.state.doc.descendants((n, p) => {
      if (at != null) return false;
      if (n.type.name === "bpImage" && (id ? n.attrs.bpId === id : p === pos)) at = p;
      return true;
    });
    const cur = at != null ? editor.state.doc.nodeAt(at) : null;
    if (!cur) return false;
    const attrs = { ...cur.attrs, src, uploadError: null };
    if (typeof picked.alt === "string") attrs.alt = picked.alt;
    if (Number.isFinite(picked.width) && picked.width >= 16) attrs.width = Math.round(picked.width);
    editor.view.dispatch(editor.state.tr.setNodeMarkup(at, undefined, attrs));
    return true;
  }

  _pickInsertedImage() {
    return pasteMediaMethods._pickInsertedImage.call(this);
  }

  get mediaUploader() {
    return pasteMediaMethods.getMediaUploader.call(this);
  }

  _pasteHTMLTables(view, event) {
    return pasteMediaMethods._pasteHTMLTables.call(this, view, event);
  }

  _pasteMarkdown(view, event) {
    return pasteMediaMethods._pasteMarkdown.call(this, view, event);
  }

  _pastePlainText(view, event, force = false) {
    return pasteMediaMethods._pastePlainText.call(this, view, event, force);
  }

  _noteDropMoves(view, event) {
    return pasteMediaMethods._noteDropMoves.call(this, view, event);
  }

  _fitPastedSlice(slice) {
    return pasteMediaMethods._fitPastedSlice.call(this, slice);
  }

  _fitPastedNodes(fragment, imagesLeftOut = 0) {
    return pasteMediaMethods._fitPastedNodes.call(this, fragment, imagesLeftOut);
  }

  _noticeLeftOut(dropped) {
    return pasteMediaMethods._noticeLeftOut.call(this, dropped);
  }

  _showHTMLPasteNotice(message) {
    return pasteMediaMethods._showHTMLPasteNotice.call(this, message);
  }

  _clearHTMLPasteNotice() {
    return pasteMediaMethods._clearHTMLPasteNotice.call(this);
  }

  _showFigureConstraint(message = "A Figure keeps one content block. Enter cannot split or remove it.") {
    return pasteMediaMethods._showFigureConstraint.call(this, message);
  }

  _clearFigureConstraint(transaction = null) {
    return pasteMediaMethods._clearFigureConstraint.call(this, transaction);
  }

  _caretRect() {
    return pickerMethods._caretRect.call(this);
  }

  _maybeWikilink() {
    return pickerMethods._maybeWikilink.call(this);
  }

  _openWikilink(rect, query = "") {
    return pickerMethods._openWikilink.call(this, rect, query);
  }

  _closeWikilink() {
    return pickerMethods._closeWikilink.call(this);
  }

  _chooseWikilink(candidate) {
    return pickerMethods._chooseWikilink.call(this, candidate);
  }

  _dismissWikilink() {
    return pickerMethods._dismissWikilink.call(this);
  }

  set wikilinkSource(fn) {
    return pickerMethods.setWikilinkSource.call(this, fn);
  }

  get wikilinkSource() {
    return pickerMethods.getWikilinkSource.call(this);
  }

  set linkPreviewSource(fn) {
    return pickerMethods.setLinkPreviewSource.call(this, fn);
  }

  get linkPreviewSource() {
    return pickerMethods.getLinkPreviewSource.call(this);
  }

  set wikilinkResolve(fn) {
    return pickerMethods.setWikilinkResolve.call(this, fn);
  }

  get wikilinkResolve() {
    return pickerMethods.getWikilinkResolve.call(this);
  }

  refreshWikilinks() {
    return pickerMethods.refreshWikilinks.call(this);
  }

  _maybeTag() {
    return pickerMethods._maybeTag.call(this);
  }

  _maybeEmoji() {
    return pickerMethods._maybeEmoji.call(this);
  }

  _openEmoji(rect, query = "") {
    return pickerMethods._openEmoji.call(this, rect, query);
  }

  _closeEmoji() {
    return pickerMethods._closeEmoji.call(this);
  }

  _chooseEmoji(candidate) {
    return pickerMethods._chooseEmoji.call(this, candidate);
  }

  _dismissEmoji() {
    return pickerMethods._dismissEmoji.call(this);
  }

  _openTag(rect, query = "") {
    return pickerMethods._openTag.call(this, rect, query);
  }

  _closeTag() {
    return pickerMethods._closeTag.call(this);
  }

  _chooseTag(candidate) {
    return pickerMethods._chooseTag.call(this, candidate);
  }

  _dismissTag() {
    return pickerMethods._dismissTag.call(this);
  }

  set tagSource(fn) {
    return pickerMethods.setTagSource.call(this, fn);
  }

  get tagSource() {
    return pickerMethods.getTagSource.call(this);
  }

  _maybeSlash() {
    return slashPaletteMethods._maybeSlash.call(this);
  }

  _replaceTopBlockWithQuote(type) {
    return slashPaletteMethods._replaceTopBlockWithQuote.call(this, type);
  }

  _maybeBlockShorthand() {
    return slashPaletteMethods._maybeBlockShorthand.call(this);
  }

  _maybeCalloutShorthand() {
    return slashPaletteMethods._maybeCalloutShorthand.call(this);
  }

  _openSlash(query = "") {
    return slashPaletteMethods._openSlash.call(this, query);
  }

  _closeSlash() {
    return slashPaletteMethods._closeSlash.call(this);
  }

  _slashInListItem($from) {
    return slashPaletteMethods._slashInListItem.call(this, $from);
  }

  _chooseSlash(item) {
    return slashPaletteMethods._chooseSlash.call(this, item);
  }

  _insertObjectBlock(type, bpBlock, opts = {}) {
    return slashPaletteMethods._insertObjectBlock.call(this, type, bpBlock, opts);
  }

  _insertDeclaredObject(type) {
    return slashPaletteMethods._insertDeclaredObject.call(this, type);
  }

  _mastersRoot() {
    return slashPaletteMethods._mastersRoot.call(this);
  }

  _canSaveMaster(node) {
    return slashPaletteMethods._canSaveMaster.call(this, node);
  }

  _saveMaster(node) {
    return slashPaletteMethods._saveMaster.call(this, node);
  }

  _insertMaster(masterId, mode = null) {
    return slashPaletteMethods._insertMaster.call(this, masterId, mode);
  }

  _hostBuildsInserts() {
    return slashPaletteMethods._hostBuildsInserts.call(this);
  }

  _insertViaServer(type, { replaceSlashLine = false } = {}) {
    return slashPaletteMethods._insertViaServer.call(this, type, replaceSlashLine);
  }

  _dismissSlash() {
    return slashPaletteMethods._dismissSlash.call(this);
  }

  _openPalette() {
    return slashPaletteMethods._openPalette.call(this);
  }

  _closePalette() {
    return slashPaletteMethods._closePalette.call(this);
  }

  _choosePaletteCommand(cmd) {
    return slashPaletteMethods._choosePaletteCommand.call(this, cmd);
  }

  _dismissPalette() {
    return slashPaletteMethods._dismissPalette.call(this);
  }

  // ── P5 MARKDOWN SOURCE-MODE (Mod-Shift-m / palette "Toggle Markdown source") ──
  //
  // The Obsidian "source mode" analog: swap the rich ProseMirror editor for a plain
  // Markdown <textarea> and back. The SAME toggle method is bound to both triggers
  // (the keyboard shortcut in _onKeyDown and the palette command in
  // buildCommandRegistry → run()), so they are guaranteed identical.
  //
  //   rich → source : serialize the live run to markdown, including unsaved edits, stash
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
  toggleSourceMode() { return sourceModeToggle.call(this); }
  _enterSourceMode() { return sourceModeEnter.call(this); }
  _exitSourceMode() { return sourceModeExit.call(this); }
  _commitSource(md) { return sourceModeCommit.call(this, md); }
  _syncSourceText() { return sourceModeSyncText.call(this); }
  get sourceMode() { return sourceModeActive.call(this); }
  _sizeSourceTextarea() { return sourceModeSizeTextarea.call(this); }
  _teardownSourceEl() { return sourceModeTeardown.call(this); }

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
  //     stack. GUARD: if the editor is FOCUSED, composing (IME), or has an edit in
  //     its debounce window, we QUEUE the update and apply it after that local
  //     state settles so we never yank the caret or erase an un-emitted draft —
  //     the diff baseline stays with the displayed snapshot until that render lands.
  // A revision-owning host may present acknowledged external content while an
  // idle rich-text caret remains focused. Unlike applyServerBlocks this never
  // queues: true means the content and baseline landed synchronously; false
  // means the host must retain its previous revision. The caller must fence old
  // read/echo responses by revision. It never discards an unacknowledged draft.
  applyServerBlocksIfIdle(blocks) {
    if (!this._editor || this._mode === "source" || this._editor.view.composing ||
        this._bubble?.hasFocus()) return false;
    const active = this.ownerDocument.activeElement;
    if (active && this.contains(active) && active !== this._editor.view.dom) return false;
    // Some node views buffer fields outside ProseMirror. Flush their real input
    // first so a recently blurred field cannot masquerade as an idle canvas.
    this.querySelectorAll("[data-bp-type]").forEach(node => {
      node.dispatchEvent(new CustomEvent("bp-flush-node"));
    });
    if (this.hasPendingChanges()) return false;
    if (!Array.isArray(blocks)) throw new TypeError("Expected confirmed Paper blocks");
    this._programmaticApply = true;
    try {
      this._applyExternalContent(blocks);
      this._blocks = deepCloneBlocks(blocks);
      this._clearPendingServerBlocks();
      // These receipts already completed successfully; this newer authority
      // supersedes them. Actual in-flight saves remain guarded above.
      this._awaitingOwnEchoes = [];
      return true;
    } finally {
      this._programmaticApply = false;
    }
  }

  applyServerBlocks(blocks, echoMeta = null) {
    if (!this._editor) return;
    this._readDomTyping();
    const next = Array.isArray(blocks) ? blocks : [];
    const echoMode = echoMeta && typeof echoMeta === "object" ? echoMeta.mode : null;
    const echoRequestId = echoMeta && typeof echoMeta === "object"
      ? echoMeta.requestId
      : null;
    const coordinatorOwnMode = echoMode === "own" || echoMode === "own-stale";

    // An echo can confirm an earlier local snapshot while the user has already
    // edited beyond it. Recognize that snapshot as our own and advance only the
    // confirmed baseline; replacing the live doc here would erase the newer edit.
    if (this._inflightOps) {
      const exactInflightEcho = this._re(
        next,
        this._rt(this._inflightOps.afterBlocks).content || [],
      ).ownEcho;
      const foreignOwnRequest = coordinatorOwnMode && echoRequestId != null &&
        this._inflightOps.requestId != null && echoRequestId !== this._inflightOps.requestId;
      const correlatedOwnEcho = echoMode === "own" && echoRequestId != null &&
        echoRequestId === this._inflightOps.requestId;
      if ((!foreignOwnRequest && exactInflightEcho) || correlatedOwnEcho) {
        this._inflightOps.echoSeen = true;
        if (!exactInflightEcho) {
          this._queueServerBlocks(next);
        } else if (echoMode !== "own-stale") {
          this._clearPendingServerBlocks();
        }
        return;
      }
    }
    const awaitingIndex = this._awaitingOwnEchoes.findIndex((entry) =>
      !(coordinatorOwnMode && echoRequestId != null && entry.requestId != null &&
        echoRequestId !== entry.requestId) &&
      this._re(next, this._rt(entry.blocks).content || []).ownEcho
    );
    if (awaitingIndex !== -1) {
      this._awaitingOwnEchoes.splice(0, awaitingIndex + 1);
      if (echoMode === "own-stale") this._flushPendingServerBlocks();
      else this._clearPendingServerBlocks();
      return;
    }
    // The coordinator has already observed a newer confirmed revision. A stale
    // own receipt can close an exact snapshot above, but a non-exact payload is
    // never authority and must not replace or queue over the newer document.
    if (echoMode === "own-stale") return;
    const correlatedAwaitingIndex = echoMode === "own" && echoRequestId != null
      ? this._awaitingOwnEchoes.findIndex((entry) => entry.requestId === echoRequestId)
      : -1;
    if (correlatedAwaitingIndex !== -1) {
      this._awaitingOwnEchoes.splice(0, correlatedAwaitingIndex + 1);
      if (this._liveRemote) {
        this._takeServerBlocks(next);
      } else if (this._isEditingNow()) {
        this._queueServerBlocks(next);
      } else {
        this._blocks = deepCloneBlocks(next);
        this._clearPendingServerBlocks();
        this._programmaticApply = true;
        try {
          this._applyExternalContent(next);
        } finally {
          this._programmaticApply = false;
        }
      }
      return;
    }

    // The match check, id-tolerant. reconcileServerEcho compares the confirmed
    // blocks to the LIVE top-level nodes, treating a live bpId:null as a wildcard
    // for the server id at that index (the NEW-block case), and returns the
    // own-echo verdict + the id-writebacks. normalizeCanvasDoc first so we compare
    // against the same shape the emit path diffs (phantom nested attrs / split
    // dedup), exactly as runToOps was tested against.
    const liveContent = this._normalizedDoc(this._editor.getJSON()).content || [];
    const { ownEcho, idWrites } = this._re(next, liveContent);

    // A genuinely external echo cannot safely replace local content while one
    // or more emitted snapshots are still awaiting confirmation. Defer it; a
    // later own echo carries the server's newest folded state and supersedes it.
    if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) {
      if (this._liveRemote) this._takeServerBlocks(next);
      else this._queueServerBlocks(next);
      return;
    }

    if (ownEcho) {
      this._blocks = next;
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
    // until they release; otherwise apply it now. A liveRemote canvas takes it
    // block by block instead (_takeServerBlocks).
    if (this._liveRemote) {
      this._takeServerBlocks(next);
    } else if (this._isEditingNow()) {
      this._queueServerBlocks(next);
    } else {
      this._blocks = next;
      this._clearPendingServerBlocks();
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
      if (node.type.name === "note") {
        // Note field history must survive the non-history identity stamp.
        tr.setNodeAttribute(offset, "bpId", attrs.bpId);
        if (attrs.bpType !== node.attrs.bpType) tr.setNodeAttribute(offset, "bpType", attrs.bpType);
      } else {
        tr.setNodeMarkup(offset, undefined, attrs);
      }
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
  _stampMaterializedIds(stableDoc, nextDoc, { dryRun = false } = {}) {
    if (!this._editor || !stableDoc) return false;
    // A node is stamped when the diff read it as new: no id, or a copy
    // normalizeCanvasDoc cleared (freshenRepeatedIds). Typing into stamped blocks
    // has neither, and flattening the whole projection per keystroke was the
    // emit's largest remaining cost (task-fb938eb8be3bce48).
    const flatten = (nodes, out = []) => {
      for (const node of nodes || []) {
        out.push(node);
        flatten(node.content, out);
      }
      return out;
    };
    const diffed = flatten(nextDoc.content);
    if (!diffed.some((node) => node.type !== "text" && node.attrs?.bpId == null)) return false;
    const stableNodes = flatten(stableDoc.content);

    const { state, view } = this._editor;
    const tr = state.tr;
    let index = 0;
    let mutated = false;
    state.doc.descendants((node, pos) => {
      const diffedId = diffed[index]?.attrs?.bpId;
      const stable = stableNodes[index++];
      const stableId = stable?.attrs?.bpId;
      if (!node.isText && diffedId == null && stableId != null) {
        const bpType = node.attrs.bpType == null ? stable.attrs?.bpType : node.attrs.bpType;
        if (node.type.name === "note") {
          // Keep pre-save label/lead AttrSteps mapped to this same note.
          tr.setNodeAttribute(pos, "bpId", stableId);
          if (bpType !== node.attrs.bpType) tr.setNodeAttribute(pos, "bpType", bpType);
        } else {
          tr.setNodeMarkup(pos, undefined, { ...node.attrs, bpId: stableId, bpType });
        }
        mutated = true;
      }
    });
    if (!mutated || dryRun) return mutated;
    tr.setMeta("addToHistory", false);
    view.dispatch(tr);
    return true;
  }

  // True when the editor is actively being edited and a setContent would yank the
  // caret OR clobber an unseen edit: it has focus, ProseMirror is mid-IME-
  // composition, a local update is waiting in the debounce window, OR we are in
  // SOURCE mode. Each is a reason to DEFER an external re-render.
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
    // With flushKeepsSource, source mode is editing only while the textarea holds text
    // not yet committed (1.20.0); without it, for as long as source mode is open.
    if (this._mode === "source") return !this._flushKeepsSource || this._sourceEl?.value !== this._sourceOriginalMd;
    const composing = !!(this._editor.view && this._editor.view.composing);
    const noteIslandFocused = this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]');
    return this._editor.isFocused || noteIslandFocused || this._bubble?.hasFocus() || composing || this._debounceTimer != null;
  }

  // Apply the confirmed external content to the editor WITHOUT entering the undo
  // stack. setContent(_, { emitUpdate: false }) does not emit an update (so we don't bounce an op
  // batch back); the addToHistory:false transaction meta keeps the external edit
  // out of the user's undo history. The baseline was already reset by the caller.
  _applyExternalContent(blocks) {
    if (!this._editor) return;
    const { state } = this._editor;
    const next = state.schema.nodeFromJSON(this._rt(blocks));
    const previousIds = [];
    const nextIds = [];
    state.doc.forEach((node) => previousIds.push(node.attrs.bpId));
    next.forEach((node) => nextIds.push(node.attrs.bpId));
    const previousSet = new Set(previousIds);
    const nextSet = new Set(nextIds);
    const retainedIds = previousIds.filter((id) => nextSet.has(id));
    const nextRetainedIds = nextIds.filter((id) => previousSet.has(id));
    const stableOrder = previousIds.every((id) => id != null) && nextIds.every((id) => id != null) &&
      previousSet.size === previousIds.length && nextSet.size === nextIds.length &&
      retainedIds.every((id, index) => id === nextRetainedIds[index]);
    if (stableOrder) {
      // Preserve mappings/history for untouched siblings. Replacing the entire
      // document maps their local undo steps through a deletion, even when the
      // remote update changed, inserted, or removed only other blocks.
      const tr = state.tr.setMeta("addToHistory", false).setMeta("preventUpdate", true);
      let position = 0;
      let previousIndex = 0;
      next.forEach((replacement) => {
        const id = replacement.attrs.bpId;
        if (!previousSet.has(id)) {
          tr.insert(position, replacement);
          position += replacement.nodeSize;
          return;
        }
        while (previousIds[previousIndex] !== id) {
          const removed = state.doc.child(previousIndex++);
          tr.delete(position, position + removed.nodeSize);
        }
        const node = state.doc.child(previousIndex++);
        replaceTopNode(tr, node, replacement, position);
        position += replacement.nodeSize;
      });
      while (previousIndex < state.doc.childCount) {
        const removed = state.doc.child(previousIndex++);
        tr.delete(position, position + removed.nodeSize);
      }
      if (tr.docChanged) this._editor.view.dispatch(tr);
      this._restSelectionOffAtom();
      if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
      this._consumePendingFocus();
      return;
    }
    const caret = this._captureCaret();
    this._editor
      .chain()
      .setContent(this._rt(blocks), { emitUpdate: false })
      .command(({ tr }) => {
        tr.setMeta("addToHistory", false);
        return true;
      })
      .run();
    this._restoreCaret(caret);
    this._restSelectionOffAtom();
    if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
    this._consumePendingFocus();
  }

  // A whole-document replace (a REORDER, which cannot be applied in place) maps
  // the selection through "everything was replaced", so the caret lands at an
  // edge of the doc — after a "Move up" that is inside the moved block, and the
  // author's next Enter or "/" goes there (task-b2abe773242241f8). While the
  // author is in the editor, remember the caret as block id + offset and put it
  // back in the same block afterwards. Selection only: no doc change, no ops.
  _captureCaret() {
    const editor = this._editor;
    if (!editor || !editor.view || !editor.isFocused) return null;
    const { $head } = editor.state.selection;
    if ($head.depth < 1) return null;
    const id = $head.node(1)?.attrs?.bpId;
    if (id == null) return null;
    return { id, offset: $head.pos - $head.before(1) };
  }

  _restoreCaret(caret) {
    if (!caret || !this._editor) return;
    const { state, view } = this._editor;
    let target = null;
    state.doc.forEach((node, pos) => {
      if (!target && node.attrs?.bpId === caret.id) target = { node, pos };
    });
    if (!target) return;
    const at = Math.min(target.pos + caret.offset, target.pos + target.node.nodeSize - 1);
    let selection;
    try {
      selection = TextSelection.near(state.doc.resolve(at));
    } catch (_) {
      return;
    }
    view.dispatch(state.tr.setSelection(selection).setMeta("addToHistory", false));
  }

  // A canvas at rest must not hold a NodeSelection on a whole block. A fresh doc (or one
  // replaced by setContent) starts with the selection on block 0, and when that block is
  // an atom (a bound field-string title) a click whose DOM selection never reached the
  // editor state left it there, so the first keystroke REPLACED the bound block — a data
  // loss (task-f24549dea0618da2). While the editor is unfocused, move such a selection to
  // the first text position; with no text block, leave it. Selection-only: no doc change,
  // no ops, no history.
  _restSelectionOffAtom() {
    const editor = this._editor;
    if (!editor || editor.isDestroyed) return;
    const { state, view } = editor;
    if (!(state.selection instanceof NodeSelection)) return;
    if (view && typeof view.hasFocus === "function" && view.hasFocus()) return;
    const text = TextSelection.findFrom(state.doc.resolve(0), 1, true);
    if (!text) return;
    view.dispatch(state.tr.setSelection(text).setMeta("addToHistory", false));
  }

  // Put the caret in the top-level block `id` and focus the editor. The host
  // calls this after an Add-block / Ingress-ghost write: an EMPTY paragraph is
  // collapsed at rest (resting-scaffolds.js) and only opens while the caret is
  // in it, so without this the new block was invisible and typing went nowhere.
  // The block may not have arrived yet (the server's run update can land after
  // the request) — remember it briefly and retry on the next external apply.
  // Returns true when the caret was placed. Selection-only: no doc change, no
  // ops, no history entry.
  focusBlock(id) {
    if (typeof id !== "string" || id === "") return false;
    const pos = this._editor ? this._topLevelPos(id) : null;
    if (pos == null) {
      this._pendingFocus = { id, until: Date.now() + PENDING_FOCUS_MS };
      return false;
    }
    this._pendingFocus = null;
    const { state, view } = this._editor;
    // A field block (String, Select, Date & time, the Image/Reference pickers…) is an
    // atom whose node view holds its own control: a TextSelection lands BESIDE it, so
    // focus the control instead (task-13abe9408c006c96). An atom with no control — a
    // divider — falls through to the caret as before.
    const node = state.doc.nodeAt(pos);
    if (node && node.isAtom && !node.isTextblock) {
      const nodeDom = view.nodeDOM(pos);
      // Reader-shaped fields keep their controls mounted but hidden at rest.
      // Wake that field synchronously before resolving its focus target so the
      // public focusBlock contract still lands in the native control/picker.
      if (nodeDom && nodeDom.matches && nodeDom.matches("[data-field-type]")) {
        nodeDom.dispatchEvent(new CustomEvent("bp-activate-field-editor"));
      }
      const control = focusableControlIn(nodeDom);
      if (control) {
        control.focus();
        return true;
      }
    }
    let selection;
    try {
      selection = TextSelection.near(state.doc.resolve(pos + 1));
    } catch (_e) {
      return false;
    }
    view.dispatch(state.tr.setSelection(selection).setMeta("addToHistory", false));
    view.focus();
    return true;
  }

  // Select the top-level card `id`, an image or an object block, as a click on it does
  // (contract 1.12.0, Sanity's selected block object): a host that wakes the body on a
  // click on its card at rest hands that click on, instead of a caret past the card.
  // Answers true when selected. Selection-only: no doc change, no ops, no history.
  selectBlock(id) {
    const pos = this._editor && typeof id === "string" && id !== "" ? this._topLevelPos(id) : null;
    if (pos == null) return false;
    const { state, view } = this._editor;
    const node = state.doc.nodeAt(pos);
    if (!node || (node.type.name !== "bpImage" && node.type.name !== "bpOpaque")) return false;
    view.dispatch(state.tr.setSelection(NodeSelection.create(state.doc, pos)).setMeta("addToHistory", false));
    view.focus();
    return true;
  }

  // Enter with the caret in the locked title. Returns false when the caret is not
  // in it (Enter keeps its normal meaning). Otherwise the caret goes to the first
  // unlocked block after the title in this run; with none, to the next run's first
  // body block, else the first ghost slot or the "+ Add block" control. Selection
  // only: no doc change, no op, no history entry. Returns true either way, so the
  // Enter stays a no-op on the document (the D6 guarantee).
  _enterFromLockedTitle() {
    const editor = this._editor;
    if (!editor) return false;
    const { selection } = editor.state;
    const $from = selection.$from;
    if ($from.depth !== 1 || !isLockedTitle($from.parent)) return false;
    if (!selection.$to.sameParent($from)) return false;
    if (this._focusBodyFrom($from.index(0) + 1)) return true;
    this._focusBodyAfterRun();
    return true;
  }

  // Put the caret in the first unlocked top-level block at or after `startIndex`.
  _focusBodyFrom(startIndex = 0) {
    const editor = this._editor;
    if (!editor || !this._editable) return false;
    const { state, view } = editor;
    let target = null;
    state.doc.forEach((node, offset, index) => {
      if (target == null && index >= startIndex && node.attrs?.locked !== true) target = offset;
    });
    if (target == null) return false;
    let next;
    try {
      next = Selection.near(state.doc.resolve(target), 1);
    } catch (_e) {
      return false;
    }
    if (!next || next.from < target) return false;
    view.dispatch(state.tr.setSelection(next).setMeta("addToHistory", false).scrollIntoView());
    view.focus();
    return true;
  }

  // 1.22.0: focus the editing surface where its selection already is, so a host
  // no longer focuses [contenteditable] or .ProseMirror inside the element.
  focusSelection() {
    const view = this._editor?.view;
    if (!view) return false;
    view.focus();
    return view.hasFocus();
  }

  // Public seam for a neighbouring run: focus this run's first body block.
  focusFirstBodyBlock() {
    return this._focusBodyFrom(0);
  }

  // The title run holds no body block: try the following canvas runs in document
  // order, then the first ghost slot (Ingress / Featured), then "+ Add block".
  _focusBodyAfterRun() {
    const root = this.closest(".bp-paper-editor") || this.ownerDocument?.body;
    if (!root) return false;
    const canvases = [...root.querySelectorAll("bp-paper-canvas")];
    for (const canvas of canvases.slice(canvases.indexOf(this) + 1)) {
      if (typeof canvas.focusFirstBodyBlock === "function" && canvas.focusFirstBodyBlock()) return true;
    }
    const affordance =
      root.querySelector('[data-test-id="paper-ghost-slots"] button:not([disabled])') ||
      root.querySelector('[data-test-id="paper-add-block"] select, [data-test-id="paper-add-block"] button');
    if (!affordance) return false;
    this._editor?.commands.blur();
    affordance.focus();
    return true;
  }

  _topLevelPos(id) {
    let found = null;
    this._editor.state.doc.forEach((node, pos) => {
      if (found == null && node.attrs?.bpId === id) found = pos;
    });
    return found;
  }

  _consumePendingFocus() {
    const pending = this._pendingFocus;
    if (!pending) return;
    if (Date.now() > pending.until) {
      this._pendingFocus = null;
      return;
    }
    this.focusBlock(pending.id);
  }

  // ── liveRemote (1.15.0): server blocks while the author edits ─────────────
  //
  //   remote block is not one the author holds  ─► applied now, selection mapped
  //   caret block, nothing unsaved in it          ─► applied now, caret mapped
  //   a block with unsaved typing, remote differs ─► live text kept, the remote
  //       block held and reported (bp-canvas-remote-held); retried at release
  //
  // "Holds" means: changed since the baseline, saved but not yet echoed (its
  // batch is on _awaitingOwnEchoes), or the caret's block when the snapshot
  // removes it. Held snapshots stay pending; the next own echo or snapshot
  // supersedes them, as before.
  _takeServerBlocks(remote) {
    this._queueServerBlocks(remote);
    this._flushPendingServerBlocks();
  }

  // Merge the pending snapshot now. False when it cannot merge here; the
  // release path then waits, as without liveRemote.
  _mergePendingServerBlocks() {
    if (!this._canMergeRemote()) return false;
    const held = this._mergeRemote(this._pendingServerBlocks);
    if (held === null) return false;
    if (held.length) this._reportHeld(held);
    else this._clearPendingServerBlocks();
    return true;
  }

  // Moments the live document cannot take a snapshot block by block: a batch in
  // flight (its ack installs the emit's snapshot), an IME composition, source
  // mode, or an input outside ProseMirror (a note, the link row, a node-view
  // field) that buffers its own text.
  _canMergeRemote() {
    const editor = this._editor;
    if (!editor || editor.isDestroyed || this._mode === "source") return false;
    if (editor.view.composing || this._compStart != null || this._compEndTimer) return false;
    if (this._inflightOps || this._dirtyWhileInflight) return false;
    if (this._bubble?.hasFocus()) return false;
    if (this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]')) return false;
    const active = this.ownerDocument.activeElement;
    return !(active && active !== editor.view.dom && this.contains(active));
  }

  // Merge `remote` into the live document. Returns the held blocks
  // ([{ id, remote, unsaved }]) or null when it cannot merge here: a block
  // without an id or a repeated id, or a reorder across a block the author holds.
  _mergeRemote(remote) {
    const editor = this._editor;
    const { state, view } = editor;
    const base = this._debounceBaselineBlocks || this._blocks;
    const remoteIds = remote.map((block) => block && block.id);
    if (remoteIds.some((id) => id == null) || new Set(remoteIds).size !== remoteIds.length) return null;
    const live = normalizeCanvasDoc(editor.getJSON(), base).content || [];
    const baseNodes = this._rt(base).content || [];
    const remoteNodes = this._rt(remote).content || [];
    if (live.length !== state.doc.childCount || baseNodes.length !== base.length ||
        remoteNodes.length !== remote.length) return null;
    const same = (a, b) => withObjectOverrides(this._objectOverrides(), () => nodeContentEqual(a, b));
    const baseAt = new Map(base.map((block, i) => [block.id, i]));
    const remoteAt = new Map(remoteIds.map((id, i) => [id, i]));
    const awaiting = new Set(this._awaitingOwnEchoes.flatMap((entry) => entry.ids || []));
    const caret = this._caretBlockIndexes();
    const liveIds = live.map((node) => (node.attrs && node.attrs.bpId) ?? null);
    const held = [];
    let holds = false;

    const plan = live.map((json, i) => {
      const id = liveIds[i];
      const r = id == null || !remoteAt.has(id) ? -1 : remoteAt.get(id);
      const b = id == null || !baseAt.has(id) ? -1 : baseAt.get(id);
      const unsaved = b === -1 || !same(baseNodes[b], json);
      if (unsaved || awaiting.has(id)) {
        holds = true;
        const remoteChanged = r === -1
          ? b !== -1
          : !same(remoteNodes[r], json) && (b === -1 || !same(remoteNodes[r], baseNodes[b]));
        if (remoteChanged) held.push({ id, remote: r === -1 ? null : remote[r], unsaved });
        const baseline = unsaved ? (b !== -1 && r !== -1 ? base[b] : null) : base[b];
        return { kind: "keep", i, r, baseline };
      }
      if (r === -1) {
        if (!caret.has(i)) return { kind: "drop", i, r };
        holds = true;
        held.push({ id, remote: null, unsaved: false });
        return { kind: "keep", i, r, baseline: base[b] };
      }
      return { kind: same(remoteNodes[r], json) ? "keep" : "take", i, r, baseline: remote[r] };
    });

    const liveIdSet = new Set(liveIds.filter((id) => id != null));
    const extras = [];
    remote.forEach((block, r) => {
      if (liveIdSet.has(block.id) || awaiting.has(block.id)) return;
      const b = baseAt.has(block.id) ? baseAt.get(block.id) : -1;
      if (b === -1) {
        extras.push({ kind: "insert", r, block });
        return;
      }
      // The author removed it and has not saved that yet: stay removed, and keep
      // it in the baseline so the next batch removes it.
      holds = true;
      if (!same(remoteNodes[r], baseNodes[b])) held.push({ id: block.id, remote: block, unsaved: true });
      extras.push({ kind: "removed", r, block });
    });

    const survivors = plan.filter((entry) => entry.kind !== "drop");
    let last = -1;
    for (const entry of survivors) {
      if (entry.r === -1) continue;
      if (entry.r < last) {
        // A reorder. With nothing to keep, the snapshot is the document.
        if (holds) return null;
        this._applyWholeSnapshot(remote);
        return [];
      }
      last = entry.r;
    }

    const target = [];
    const baseline = [];
    let next = 0;
    const takeExtras = (upTo) => {
      while (next < extras.length && extras[next].r < upTo) {
        const extra = extras[next++];
        if (extra.kind === "insert") target.push(extra);
        baseline.push(extra.block);
      }
    };
    for (const entry of survivors) {
      if (entry.r !== -1) takeExtras(entry.r);
      target.push(entry);
      if (entry.baseline) baseline.push(entry.baseline);
    }
    takeExtras(Infinity);

    const tr = state.tr.setMeta("addToHistory", false).setMeta("preventUpdate", true);
    let position = 0;
    let liveIndex = 0;
    for (const entry of target) {
      if (entry.kind === "insert") {
        const node = state.schema.nodeFromJSON(remoteNodes[entry.r]);
        tr.insert(position, node);
        position += node.nodeSize;
        continue;
      }
      while (liveIndex < entry.i) {
        tr.delete(position, position + state.doc.child(liveIndex++).nodeSize);
      }
      const node = state.doc.child(liveIndex++);
      if (entry.kind === "take") {
        const replacement = state.schema.nodeFromJSON(remoteNodes[entry.r]);
        replaceTopNode(tr, node, replacement, position);
        position += replacement.nodeSize;
      } else {
        position += node.nodeSize;
      }
    }
    while (liveIndex < state.doc.childCount) {
      tr.delete(position, position + state.doc.child(liveIndex++).nodeSize);
    }

    // Text a remote writer put at the caret lands after it: the author's next
    // key goes where it was going.
    const { selection } = state;
    if (tr.docChanged && selection instanceof TextSelection) {
      tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(selection.anchor, -1), tr.mapping.map(selection.head, -1)));
    }
    this._blocks = deepCloneBlocks(baseline);
    if (this._debounceBaselineBlocks) this._debounceBaselineBlocks = this._blocks;
    this._programmaticApply = true;
    try {
      if (tr.docChanged) view.dispatch(tr);
    } finally {
      this._programmaticApply = false;
    }
    this._restSelectionOffAtom();
    this._consumePendingFocus();
    return held;
  }

  _applyWholeSnapshot(remote) {
    this._blocks = deepCloneBlocks(remote);
    if (this._debounceBaselineBlocks) this._debounceBaselineBlocks = this._blocks;
    this._programmaticApply = true;
    try {
      this._applyExternalContent(remote);
    } finally {
      this._programmaticApply = false;
    }
  }

  // Top-level indexes the selection touches, while the author is in the editor.
  _caretBlockIndexes() {
    const editor = this._editor;
    const indexes = new Set();
    if (!editor || !editor.isFocused) return indexes;
    const { $from, $to } = editor.state.selection;
    const from = $from.index(0);
    const to = Math.max(from, $to.depth === 0 ? $to.index(0) - 1 : $to.index(0));
    for (let i = from; i <= to; i++) indexes.add(i);
    return indexes;
  }

  // bp-canvas-remote-held, once per block and remote version, for blocks held
  // against the author's unsaved typing (or removal).
  _reportHeld(held) {
    const reported = new Map();
    for (const entry of held) {
      if (!entry.unsaved) continue;
      const key = JSON.stringify(entry.remote);
      reported.set(entry.id, key);
      if (this._heldRemote.get(entry.id) === key) continue;
      this.dispatchEvent(new CustomEvent("bp-canvas-remote-held", {
        detail: { blockId: entry.id, remote: entry.remote == null ? null : deepCloneBlocks([entry.remote])[0] },
        bubbles: true,
        composed: true,
      }));
    }
    this._heldRemote = reported;
  }

  // Queue an external-edit re-render to fire once the user stops editing and any
  // local debounce settles. We listen for compositionend (IME release) and the
  // editor's blur; the debounce callback also flushes after a zero-op local diff.
  // Re-queuing overwrites the pending blocks (only latest authority matters).
  _queueServerBlocks(blocks) {
    this._pendingServerBlocks = blocks;
    if (this._onBlurFlush) return; // listeners already armed

    // TipTap's blur notification can run before `editor.isFocused` flips false.
    // Release on the next task so the focus guard observes the settled state.
    const flush = () => setTimeout(() => this._flushPendingServerBlocks(), 0);

    this._onBlurFlush = flush;
    this._onComposeEnd = flush;
    // The contextual toolbar is mounted under body, outside the canvas. Its
    // focus release must also wake the queued update after link editing ends.
    this.ownerDocument.addEventListener("focusout", this._onBlurFlush);
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
  // Idempotent + guarded: focus/composition waits for blur/release, source mode
  // waits for exit, a live debounce waits for its callback, and an empty queue no-ops.
  _flushPendingServerBlocks() {
    if (!this._pendingServerBlocks) return;
    if (this._liveRemote && this._mergePendingServerBlocks()) return;
    // Still mid-composition/source mode, or still holding an un-emitted local
    // transaction in the debounce window? Wait for the real release. A blur can
    // be delivered after the server echo armed this listener; applying at that
    // point would overwrite the draft before its debounce gets a chance to emit.
    if (this._editor && this._editor.view && this._editor.view.composing) return;
    if (this._mode === "source" && (!this._flushKeepsSource || this._sourceEl?.value !== this._sourceOriginalMd)) return;
    if (this._editor && this._editor.isFocused) return;
    if (this._bubble?.hasFocus()) return;
    if (this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]')) return;
    if (this._debounceTimer) return;
    if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) return;
    const pending = this._pendingServerBlocks;
    this._clearPendingServerBlocks();
    if (pending) {
      this._blocks = deepCloneBlocks(pending);
      this._applyExternalContent(pending);
    }
  }

  // Tear down any queued external-edit echo + its release listeners.
  _clearPendingServerBlocks() {
    this._pendingServerBlocks = null;
    this._heldRemote.clear();
    if (this._onBlurFlush) this.ownerDocument.removeEventListener("focusout", this._onBlurFlush);
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
      const caret = this._captureCaret();
      this._programmaticApply = true;
      try {
        // The seed is the run's starting point, not an edit: keep it out of
        // undo history. In history, a Cmd+Z on an untouched run inverted it to
        // the empty pre-seed doc and ProseMirror threw (doc needs a block).
        this._editor
          .chain()
          .setContent(this._rt(this._blocks), { emitUpdate: false })
          .command(({ tr }) => {
            tr.setMeta("addToHistory", false);
            return true;
          })
          .run();
      } catch (error) {
        this._failMount("seed", error);
        return;
      } finally {
        this._programmaticApply = false;
      }
      this._restoreCaret(caret);
      this._restSelectionOffAtom();
      this._verifyPainted("seed");
      if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
      this._consumePendingFocus();
    }
  }

  // A run whose content could not be painted must never rest as an EMPTY editor:
  // the author would see prose missing, and any structural edit on the empty run
  // could persist the loss (task-7188bd8e9eb2625a). ProseMirror aborts a paint
  // when a node view throws, leaving the new state behind an empty (or partial)
  // DOM. Detect both shapes and fall back to a read-only paint of the run.
  _createEditorSafely(factory) {
    try {
      return factory();
    } catch (error) {
      this._failMount("create", error);
      return null;
    }
  }

  _verifyPainted(stage) {
    if (this._mountFailure) return false;
    const view = this._editor && this._editor.view;
    if (!view || !view.dom) return true;
    const expected = this._editor.state.doc.childCount;
    if (expected > 0 && view.dom.childElementCount === 0) {
      this._failMount(stage, new Error("the editor painted no blocks"));
      return false;
    }
    return true;
  }

  _failMount(stage, error) {
    const message = String((error && error.message) || error || "unknown failure");
    const blockIds = (this._blocks || []).map((block) => block && block.id).filter(Boolean);
    this._mountFailure = { stage, message };
    try {
      console.error("bp-paper-canvas: this run could not open for editing (" + stage + ")", error);
    } catch (_e) {}
    this._editable = false;
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    try {
      if (this._editor) this._editor.setEditable(false);
    } catch (_e) {}
    if (this._mount) this._mount.hidden = true;
    this.setAttribute("data-mount-failed", "true");
    let fallback = [...this.children].find((child) => child.classList.contains("bp-canvas-mount-failed"));
    if (!fallback) {
      fallback = document.createElement("div");
      fallback.className = "bp-canvas-mount-failed";
      this.appendChild(fallback);
    }
    fallback.replaceChildren();
    const notice = document.createElement("p");
    notice.className = "bp-canvas-mount-failed__notice";
    notice.setAttribute("role", "alert");
    notice.textContent =
      "This part of the paper could not open for editing. It is shown read-only; nothing in it was changed.";
    fallback.appendChild(notice);
    for (const block of this._blocks || []) {
      const row = document.createElement("div");
      row.className = "bp-canvas-mount-failed__block";
      if (block && block.id) row.setAttribute("data-bp-id", block.id);
      if (block && block.type) row.setAttribute("data-bp-type", block.type);
      row.textContent = readOnlyBlockText(block);
      fallback.appendChild(row);
    }
    this.dispatchEvent(
      new CustomEvent("bp-canvas-mount-failed", {
        detail: { stage, message, blockIds },
        bubbles: true,
        composed: true,
      }),
    );
  }

  get blocks() {
    return this._blocks;
  }

  // Hosts with an acknowledged persistence bridge opt into ordered, one-at-a-
  // time emission. Vanilla consumers retain the historical fire-and-echo API.
  set acknowledgedSaves(value) {
    this._acknowledgedSaves = value === true;
  }

  // `true` (strictly) takes server blocks into the live document while the author
  // edits (1.15.0, _takeServerBlocks). Default false: deferred until release.
  set liveRemote(value) {
    this._liveRemote = value === true;
  }

  get liveRemote() {
    return this._liveRemote;
  }

  // `true` (strictly): flushPendingChanges() in source mode commits the Markdown and
  // keeps source mode open, and a server apply reaches a textarea with no unsaved
  // text (1.20.0). Default false: the flush leaves source mode, as before 1.20.0.
  set flushKeepsSource(value) {
    this._flushKeepsSource = value === true;
  }

  get flushKeepsSource() {
    return this._flushKeepsSource;
  }

  get acknowledgedSaves() {
    return this._acknowledgedSaves;
  }
}

// The text a reader would see in one block, for the read-only mount fallback:
// every inline `value` in document order, plus a field's label and value.
function readOnlyBlockText(block) {
  const parts = [];
  const walk = (node) => {
    if (node == null) return;
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (typeof node !== "object") return;
    if (node.type === "text" && typeof node.value === "string") parts.push(node.value);
    walk(node.content);
    walk(node.children);
    walk(node.items);
  };
  if (block && typeof block === "object") {
    if (typeof block.label === "string" && block.label) parts.push(block.label);
    if (typeof block.title === "string" && block.title) parts.push(block.title);
    walk(block.content);
    walk(block.items);
    if (block.value != null && typeof block.value !== "object") parts.push(String(block.value));
  }
  return parts.join(" ").trim();
}

// ProseMirror reads the editor's OWN DOM back after native typing, and when it
// cannot localise the change inside one textblock it re-parses from the parent,
// reading each block element's inline `style` through the schema's style rules.
// The pullquote paints the reader's role italic as `style="font-style:italic"` on
// its <p>, so that re-parse turned the role styling into an Italic MARK over the
// whole quote and saved it as data (task-7f5c6a3c94ab82cc). The editor paints
// every italic mark it owns as <em>, so reading its own DOM needs no font-style
// style rule. Drop those rules from the DOM-readback parser only; pasted and
// dropped HTML keep the full schema parser (clipboardParser), where a Google Docs
// `<span style="font-style:italic">` is still italic.
const ownDomReadback = Extension.create({
  name: "bpOwnDomReadback",
  addProseMirrorPlugins() {
    const schema = this.editor.schema;
    const full = PMDOMParser.fromSchema(schema);
    const readback = new PMDOMParser(
      schema,
      full.rules.filter((rule) => !(typeof rule.style === "string" && /^font-style\b/.test(rule.style))),
    );
    return [new Plugin({ props: { domParser: readback, clipboardParser: full } })];
  },
});

if (!customElements.get("bp-paper-canvas")) {
  customElements.define("bp-paper-canvas", BpPaperCanvas);
}

export { BpPaperCanvas };
