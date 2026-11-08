import {
  editInlineObjectAt, editObjectBlockAt, HostObjectDialog, InlineObjectDialog, refusalField,
} from "./inline-object.js";
import {
  blockParents, holdsNodeIds, reconcileServerEcho, runToOps, runToTiptap, withObjectOverrides,
} from "./run-convert.js";
import { parseVocabulary } from "./vocabulary.js";
import { Fragment, Mark } from "@tiptap/pm/model";


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

// Diff the live doc against the current baseline run and, if anything changed,
// emit the ordered op array S0 produces. The diff is runToOps VERBATIM — the
// canvas is a thin shell over S0's PURE projector/op-mapper.
//
// `_blocks` advances when the bridge acknowledges the one in-flight batch, so
// the next dispatch is incremental even if its server echo arrives later.
// The live doc as the emit diffs it: a repeated id stays with the copy the
// baseline knew (freshenRepeatedIds), so every reader agrees with the next batch.
function _normalizedDoc(doc) {
  return normalizeCanvasDoc(doc, this._debounceBaselineBlocks || this._blocks);
}

// ── inline objects (./inline-object.js) ───────────────────────────────────
// Declared object block names that win over a same-named built-in
// (task-5bc7771edf30199a), cached per data-vocabulary string. Every
// run-convert projection this canvas makes runs inside them (_rt/_ro/_re).
function _objectOverrides() {
  const raw = this.getAttribute("data-vocabulary") || "";
  if (this._overridesFor !== raw) {
    this._overridesFor = raw;
    const vocab = parseVocabulary(raw);
    this._overrides = new Set(((vocab && vocab.objects) || []).map((o) => o.name));
  }
  return this._overrides;
}

function _rt(blocks) {
  return withObjectOverrides(this._objectOverrides(), () => runToTiptap(blocks));
}

function _ro(...args) {
  return withObjectOverrides(this._objectOverrides(), () => runToOps(...args));
}

function _re(...args) {
  return withObjectOverrides(this._objectOverrides(), () => reconcileServerEcho(...args));
}

function _inlineObjectVocabulary() {
  return parseVocabulary(this.getAttribute("data-vocabulary"));
}

function _inlineObjectDialog() {
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
function setEditBlockObject(fn) {
  const next = typeof fn === "function" ? fn : null;
  if (next !== this._editBlockObject) {
    if (this._hostObjectDialog) this._hostObjectDialog.close(false);
    if (this._inlineDialog) this._inlineDialog.close(false);
  }
  this._editBlockObject = next;
}

function getEditBlockObject() {
  return this._editBlockObject;
}

// Whether a declared object's editor is open (the popover or the host's).
function _objectEditorOpen() {
  return !!((this._inlineDialog && this._inlineDialog.isOpen()) || (this._hostObjectDialog && this._hostObjectDialog.isOpen()));
}

// The value the dialog just saved: the batch that carries it is the one a
// refusal would name.
function _noteInlineObjectSave(values) {
  this._inlineSavePending = values;
}

function _reopenRefusedInlineObject(refusal) {
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

export {
  _inlineObjectDialog, _inlineObjectVocabulary, _normalizedDoc, _noteInlineObjectSave,
  _objectEditorOpen, _objectOverrides, _re, _reopenRefusedInlineObject, _ro, _rt,
  getEditBlockObject, normalizeCanvasDoc, replaceTopNode, setEditBlockObject,
};
