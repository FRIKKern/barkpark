// stage-node.js — the `stage` WIDGET as a canvas CONTROL-ATOM node-view.
//
// The editable per-node twin of ONE legacy `pipeline` node. Byte-modelled on
// action-node.js: an ATOM LEAF whose editable data rides in ATTRS and is edited by
// NATIVE HTML controls wrapped in a stopEvent/ignoreMutation island, so ProseMirror
// never turns a keystroke into a doc transaction. All five payload fields are PLAIN
// scalars — three text slots (kind / title / detail) + two chrome scalars (files /
// source) — so a control-atom (native inputs) is the exact fit; there is NO rich
// inline body, hence NO contentDOM and NO mark-stripping to get wrong: a native input's
// value is inherently plain text, which is precisely the reader's escaped-plain model.
//
// ── VIEW⇄EDIT PARITY (the DESIGN-1 carve-out) ────────────────────────────────
//
// CHROME = `bp-canvas-stage*` ONLY. UNLIKE card-node.js (whose node-view emits the
// reader's own model-B bare-semantic shapes to inherit the surface paint), the stage
// node-view does NOT emit the reader pipeline-node cell class — it STAYS in the §3 forbidden
// list so the still-verbatim-carried legacy `pipeline` fleet keeps its gate protection.
// The reader (Components.stage_html/1, server-side) paints the real cell; here the cell
// look is hand-mirrored by dedicated `bp-canvas-stage*` CSS (styles.css embedder +
// paper-surface.css + root.html.heex Studio copy). The saved bytes are the source of
// truth, so a saved stage reader-renders the identical cell regardless of this preview.
//
// ── the data shape ───────────────────────────────────────────────────────────
//
// A persisted stage is { id, type:"stage", kind?, title?, detail?, files?, source? } —
// the WIRE-canonical SCALAR form (byte-aligned with one legacy pipeline `nodes[]`
// entry). Every field OPTIONAL; the byte-fidelity rule (the action precedent): thread
// each onto attrs ONLY when present/non-empty, absence sentinel `null` — so
// `{type:"stage",title:"x"}` round-trips to exactly `{id,type:"stage",title:"x"}`
// (zero ops). `source` is carried VERBATIM (true|"true"|1) so a hand-authored
// `source:"true"` round-trips byte-identical; it is interpreted truthy only for the
// accent + the checkbox + the change key.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside the NodeView
// factory, which never runs in the pure-Node smoke harness), so run-convert.js can be
// imported by __smoke.mjs without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAME is `bpStage` (its portable-doc bpType stays "stage"). No
// StarterKit collision. Keep aligned with run-convert.js:CANVAS_STAGE_NODE_NAME and
// paper_canvas.ex:@canvas_widget_types.
export const BP_STAGE_NODE_NAME = "bpStage";
export const BP_STAGE_BP_TYPE = "stage";

// The reader's `truthy` for the accent (compose truthy/1: true | "true" | 1). A
// `source`-truthy stage gets the accent border; the change key + the checkbox display
// collapse to this same boolean, so a no-op toggle emits nothing.
function stageTruthy(v) {
  return v === true || v === "true" || v === 1;
}

// A string attr's display / absence normalizer: null/absent/"" all mean "no field".
function stageStr(v) {
  return v == null || v === "" ? "" : String(v);
}

// A PRESENT-ONLY string attr (kind/title/detail/files): null is the absence sentinel,
// so an absent field renders no data-attr and round-trips WITHOUT the key.
function presentStrAttr(dataName) {
  return {
    default: null,
    parseHTML: (el) =>
      el.hasAttribute(dataName) ? el.getAttribute(dataName) : null,
    renderHTML: (attrs, key) =>
      attrs[key] != null ? { [dataName]: attrs[key] } : {},
  };
}

export const Stage = Node.create({
  name: BP_STAGE_NODE_NAME,

  // A top-level block sibling inside the one canvas document. group:"block" lets it
  // sit in the doc's `block+` content AND in a section body (bpStage is in the section
  // content set), so a `section` of stages composes the pipeline flow.
  group: "block",

  // An atom leaf: no PM-editable interior. The five fields live in attrs, edited by the
  // native control island below (which PM never manages), so PM's atom selection +
  // Backspace/Delete-of-a-selected-atom come free. Identical rationale to bpAction.
  atom: true,

  selectable: true,

  // A leaf container, not a textblock — defining keeps PM from merging an adjacent
  // textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — CONSTANT "stage" (this node serves ONE bpType, like bpCode/bpAction).
      bpType: {
        default: BP_STAGE_BP_TYPE,
        parseHTML: (el) => el.getAttribute("data-bp-type-kind") || BP_STAGE_BP_TYPE,
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type-kind": attrs.bpType } : {},
      },
      // kind / title / detail — the three PLAIN-TEXT slots as PRESENT-ONLY scalars.
      kind: { ...presentStrAttr("data-kind"), renderHTML: (a) => (a.kind != null ? { "data-kind": a.kind } : {}) },
      title: { ...presentStrAttr("data-title"), renderHTML: (a) => (a.title != null ? { "data-title": a.title } : {}) },
      detail: { ...presentStrAttr("data-detail"), renderHTML: (a) => (a.detail != null ? { "data-detail": a.detail } : {}) },
      // files — a chrome scalar (NOT a slot), PRESENT-ONLY.
      files: { ...presentStrAttr("data-files"), renderHTML: (a) => (a.files != null ? { "data-files": a.files } : {}) },
      // source — a chrome flag, carried VERBATIM (true|"true"|1). PRESENT-ONLY: absent
      // means falsy; a truthy value drives the accent. Stringified onto the data-attr
      // and coerced back so getJSON round-trips the original scalar.
      source: {
        default: null,
        parseHTML: (el) => {
          if (!el.hasAttribute("data-source")) return null;
          const raw = el.getAttribute("data-source");
          if (raw === "true") return true;
          if (raw === "1") return 1;
          return raw;
        },
        renderHTML: (attrs) =>
          attrs.source != null ? { "data-source": String(attrs.source) } : {},
      },
    };
  },

  parseHTML() {
    return [{ tag: "div[data-bp-type='stage']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — the pure-Node
  // round-trip / a non-editable export). The node-view (below) OVERRIDES this. All data
  // rides the typed attrs, so the <div> body is empty.
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-type": "stage" })];
  },

  // ── the NodeView: a cell of native controls (the pnode-look, edit-only) ───────
  //
  //   <div class="bp-canvas-stage[ bp-canvas-stage--src]" data-bp-type="stage"
  //        contenteditable="false">
  //     <input class="bp-canvas-stage__k">   ← kind
  //     <input class="bp-canvas-stage__t">   ← title
  //     <input class="bp-canvas-stage__d">   ← detail
  //     <input class="bp-canvas-stage__f">   ← files
  //     <label class="bp-canvas-stage__src-toggle"><input type=checkbox> source</label>
  //
  // The controls are the edit surface PM DOES NOT MANAGE (stopEvent/ignoreMutation).
  // Text fields commit DEBOUNCED on `input`; the source checkbox commits IMMEDIATELY on
  // `change`. Each handler builds nextAttrs and setNodeMarkup → onUpdate → run-convert
  // emits the patch. A commit is skipped when the canonical stage key is unchanged.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.setAttribute("data-bp-type", "stage");
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", "paper-stage");

      const mkInput = (cls, placeholder, testId) => {
        const el = document.createElement("input");
        el.type = "text";
        el.className = cls;
        el.placeholder = placeholder;
        el.setAttribute("contenteditable", "false");
        el.setAttribute("data-test-id", testId);
        return el;
      };

      const kindInput = mkInput("bp-canvas-stage__k", "kind", "paper-stage-kind");
      const titleInput = mkInput("bp-canvas-stage__t", "title", "paper-stage-title");
      const detailInput = mkInput("bp-canvas-stage__d", "detail", "paper-stage-detail");
      const filesInput = mkInput("bp-canvas-stage__f", "files", "paper-stage-files");

      const srcLabel = document.createElement("label");
      srcLabel.className = "bp-canvas-stage__src-toggle";
      srcLabel.setAttribute("contenteditable", "false");
      const srcCheckbox = document.createElement("input");
      srcCheckbox.type = "checkbox";
      srcCheckbox.setAttribute("data-test-id", "paper-stage-source");
      const srcText = document.createElement("span");
      srcText.textContent = "source";
      srcLabel.appendChild(srcCheckbox);
      srcLabel.appendChild(srcText);

      dom.append(kindInput, titleInput, detailInput, filesInput, srcLabel);

      // Paint the controls from the node's current attrs. Re-run on every update() so an
      // external attr change (an echo, an undo) reflects. Guard "only write when differs"
      // so an echo/undo never clobbers a field mid-edit.
      const paint = (n) => {
        const a = (n && n.attrs) || {};
        const editable = editor.isEditable;
        const src = stageTruthy(a.source);
        dom.className = src ? "bp-canvas-stage bp-canvas-stage--src" : "bp-canvas-stage";

        const setVal = (el, v) => {
          if (el.value !== v) el.value = v;
          el.readOnly = !editable;
        };
        setVal(kindInput, stageStr(a.kind));
        setVal(titleInput, stageStr(a.title));
        setVal(detailInput, stageStr(a.detail));
        setVal(filesInput, stageStr(a.files));
        if (srcCheckbox.checked !== src) srcCheckbox.checked = src;
        srcCheckbox.disabled = !editable;
      };

      paint(node);

      // Build the next attrs bag from the controls. Text fields ride PRESENT-ONLY
      // (empty → null → the removal lands as an absent/empty cell); source rides
      // true when checked, null when not (present-only chrome flag).
      const buildNextAttrs = (cur) => {
        const norm = (v) => (v === "" ? null : v);
        return {
          ...cur.attrs,
          kind: norm(kindInput.value),
          title: norm(titleInput.value),
          detail: norm(detailInput.value),
          files: norm(filesInput.value),
          source: srcCheckbox.checked ? true : null,
        };
      };

      const commitNow = () => {
        if (!editor.isEditable) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_STAGE_NODE_NAME) return;
        const nextAttrs = buildNextAttrs(cur);
        if (stageKey(cur.attrs) === stageKey(nextAttrs)) return; // no-op
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, nextAttrs);
            return true;
          })
          .run();
      };

      // Text fields commit DEBOUNCED on `input`; the source checkbox IMMEDIATELY.
      let writeTimer = null;
      const scheduleWrite = () => {
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          commitNow();
        }, DEBOUNCE_MS);
      };
      const flushPending = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitNow();
      };

      kindInput.addEventListener("input", scheduleWrite);
      titleInput.addEventListener("input", scheduleWrite);
      detailInput.addEventListener("input", scheduleWrite);
      filesInput.addEventListener("input", scheduleWrite);
      srcCheckbox.addEventListener("change", commitNow);
      dom.addEventListener("bp-flush-node", flushPending);

      return {
        dom,
        // NO contentDOM — an atom; every field lives in attrs, edited outside PM.
        update: (updated) => {
          if (updated.type.name !== BP_STAGE_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        // THE ISLAND CONTRACT: PM must NOT turn the controls' events into transactions,
        // nor read their DOM mutations back into the document.
        stopEvent: () => true,
        ignoreMutation: () => true,
        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          kindInput.removeEventListener("input", scheduleWrite);
          titleInput.removeEventListener("input", scheduleWrite);
          detailInput.removeEventListener("input", scheduleWrite);
          filesInput.removeEventListener("input", scheduleWrite);
          srcCheckbox.removeEventListener("change", commitNow);
          dom.removeEventListener("bp-flush-node", flushPending);
        },
      };
    };
  },
});

// The canonical (order/absence-insensitive) key of a stage node's diff-relevant attrs
// — text fields as their display strings ("" when absent), source collapsed to its
// truthy boolean. Two nodes with the SAME key render-identically, so a no-op re-edit
// emits nothing. Mirrors run-convert.js:stableStageKey (kept in lockstep).
function stageKey(attrs) {
  const a = attrs || {};
  return JSON.stringify({
    kind: stageStr(a.kind),
    title: stageStr(a.title),
    detail: stageStr(a.detail),
    files: stageStr(a.files),
    source: stageTruthy(a.source),
  });
}
