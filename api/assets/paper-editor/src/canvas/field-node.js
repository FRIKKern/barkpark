// field-node.js — Phase-4 Stage S3.5: the canvas CONTROL-ATOM node-view — the
// FOURTH node-view variant, after divider (atom), callout (content), code/diagram
// (attr-atom).
//
// Brings the 7 NATIVE-CONTROL field-* blocks INTO the continuous canvas as a
// ProseMirror ATOM whose VALUE rides in an ATTR (`value`) and is edited by a
// NATIVE HTML control — like the S3.3 code attr-atom, but the edit surface is a
// TYPED control (input / textarea / checkbox / select / datetime-local / color),
// NOT a free textarea, and the value is COERCED BY FIELD TYPE exactly like the
// shipped BarkparkFieldBlockBridge (root.html.heex ~3543):
//   * field-boolean → a CHECKBOX whose value is `control.checked` (a BOOLEAN).
//   * everything else → a string control whose value is `control.value` (a STRING).
//
// ── THE 7 NATIVE-CONTROL FIELD TYPES (the S3.5 scope) ─────────────────────────
//
//   field-string  → <input type=text>         value: string
//   field-slug    → <input type=text>         value: string
//   field-text    → <textarea rows=…>          value: string   (rows config carried)
//   field-boolean → <input type=checkbox>      value: BOOLEAN  (control.checked)
//   field-select  → <select><option…>          value: string   (options config carried)
//   field-datetime→ <input type=datetime-local>value: string
//   field-color   → <input type=color>         value: string
//
// EXPLICITLY OUT OF S3.5 (a documented known limitation): field-image (the
// bp-media-picker WC) and field-reference (the bp-reference-picker WC). Those two
// pickers carry their own LiveView event flow (a bubbling `bp-change` CustomEvent
// the per-block BarkparkFieldBlockBridge forwards) and stay RUN BOUNDARIES — they
// keep their existing per-block widgets and project to bpOpaque in the canvas. So
// the partition makes the 7 native types canvas-eligible while field-image /
// field-reference (and sheet) STILL split.
//
// ── CONTENT MODEL (resolved against the live persist code — cite file:line) ───
//
//   blocks.ex:268  default_block("field-string")  → %{label:"Text",  value:""}
//   blocks.ex:271  default_block("field-slug")     → %{label:"Slug",  value:""}
//   blocks.ex:274  default_block("field-text")     → %{label:"Long text", value:""}
//   blocks.ex:277  default_block("field-boolean")  → %{label:"Boolean", value:false}
//   blocks.ex:280  default_block("field-datetime") → %{label:"Date & time", value:""}
//   blocks.ex:283  default_block("field-color")    → %{label:"Color", value:"#000000"}
//   blocks.ex:286  default_block("field-select")   → %{label:"Select", value:"",
//                    options:[%{value,label}, …]}
//   paper_editor.ex:735-787 — the per-block native controls each read
//     Map.get(@block, "value", <default>) and carry data-field-name=fieldName.
//   compose.ex:400-458 — View render reads ONLY `value` (+ select's `options` /
//     boolean's true-test); the rest (label/options/rows/fieldName) is CONFIG.
//
// So a native field block is { id, type:"field-*", value:<typed>, label?, fieldName?,
// rows?(text), options?(select) }. `value`'s TYPE depends on the field type: a
// BOOLEAN for field-boolean, a STRING for every other native type. `fieldName`
// binds the block to an Expectation field — carried VERBATIM. The canvas edits
// ONLY `value`; label/options/rows/fieldName are CONFIG that must round-trip
// byte-identically, so the node carries the FULL block config (unlike code/diagram,
// which are fully described by value+lang/source+caption). run-convert.js
// fieldNodeToBlock merges the edited value over the carried config.
//
// ── THE COERCION (the crux — lifted from BarkparkFieldBlockBridge) ────────────
//
// BarkparkFieldBlockBridge.mounted (root.html.heex:3575-3598):
//   const send = () => {
//     let value;
//     if (fieldType === "field-boolean") value = control.checked;  // BOOLEAN
//     else                                value = control.value;    // STRING
//     push(value);  // → {op:"patch-block", id, patch:{value}}
//   };
//   // string/slug/text debounce on `input`; the rest commit on `change`.
//   const debounced = ["field-string","field-slug","field-text"].includes(fieldType);
//
// This module LIFTS that exact coercion into `coerceFieldValue(fieldType, control)`
// so a canvas field edit produces the SAME coerced value the per-block path does —
// a canvas field edit persists IDENTICALLY to a per-block field edit.
//
// ── THE CONTROL ISLAND (the make-or-break) ────────────────────────────────────
//
// The NodeView builds a frame holding the native control for bpType. The control
// is the EDIT surface ProseMirror DOES NOT MANAGE:
//   * stopEvent:()=>true      — PM never turns the control's key/input/change/click
//     events into transactions (typing/toggling a field never splits/mutates the
//     PM doc).
//   * ignoreMutation:()=>true — PM never reads the control's DOM mutations back into
//     the document (the control is OUTSIDE any contentDOM; there is none on an atom).
// On the control's `input` (string/slug/text, debounced DEBOUNCE_MS) or `change`
// (boolean/select/datetime/color), the view COERCES the value by bpType and writes
// it back to the node's `value` attr via setNodeMarkup (a PM transaction that ONLY
// changes the attr, not the doc structure) → onUpdate → run-convert emits a
// patch-block carrying the coerced value.
//
// bpId / bpType / fieldName / value (+ label / options / rows) ride the node as
// attrs, carried through the DOM round-trip on data-* — IDENTICAL id contract to
// BpAttrs / divider / callout / code / diagram. data-bp-id is what makes getJSON()
// preserve the id run-convert.js keys by.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in
// plain Node (it imports ONLY @tiptap/core and references `document` lazily, inside
// the NodeView factory, which never runs in the pure-Node smoke harness). So
// __smoke.mjs imports run-convert.js (which references the field TYPE/coercion only,
// never the NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAME is `bpField` (the canvas naming convention, like
// bpCode/bpDiagram). The portable-doc `bpType` is the specific field-* kind
// ("field-string" | … | "field-color"), carried on the node so run-convert.js can
// render the right control and reconstruct the right block.type. There is NO
// StarterKit collision for `bpField` (StarterKit ships no field node), so NO
// StarterKit node is disabled for it.
export const BP_FIELD_NODE_NAME = "bpField";

// The 7 NATIVE-CONTROL field-* bpTypes this node-view owns. field-image /
// field-reference are EXCLUDED (pickers stay boundaries). Keep aligned with
// run-convert.js:CANVAS_FIELD_TYPES and paper_canvas.ex:@canvas_field_types.
export const BP_NATIVE_FIELD_TYPES = [
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
];

// ── THE COERCION (lifted verbatim from BarkparkFieldBlockBridge) ──────────────
//
// Read the control's value coerced by field type, EXACTLY as the per-block bridge:
//   field-boolean → control.checked  (a BOOLEAN)
//   everything else → control.value   (a STRING)
// Exported so __smoke.mjs / run-convert.js can assert fidelity against the bridge.
export function coerceFieldValue(fieldType, control) {
  if (fieldType === "field-boolean") return !!(control && control.checked);
  return control ? control.value : "";
}

// The field types whose control commits on `input` (debounced), mirroring
// BarkparkFieldBlockBridge's `debounced` set. The rest commit on `change`.
const DEBOUNCED_FIELD_TYPES = new Set([
  "field-string",
  "field-slug",
  "field-text",
]);

export const Field = Node.create({
  name: BP_FIELD_NODE_NAME,

  // A top-level block sibling (paragraph|heading|list|divider|callout|bpCode|
  // bpDiagram|bpField) inside the one canvas document. group:"block" lets it sit in
  // the doc's `block+` content without any schema surgery on the doc node itself.
  group: "block",

  // An atom leaf: no PM-editable interior, treated as a single unit. The field
  // VALUE lives in the `value` attr and is edited by the native control island
  // below (which PM never manages), so PM's atom selection + Backspace/Delete-of-a-
  // selected-atom come free — the entire structural delete affordance v1 needs.
  atom: true,

  // The node is clickable/selectable (caret can select the whole atom and delete
  // it). The native control inside handles its own focus/caret; PM only ever sees a
  // NodeSelection of the whole field block.
  selectable: true,

  // A field block is a leaf container, not a textblock — defining keeps PM from
  // merging an adjacent textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as every other canvas node).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the SPECIFIC field-* kind ("field-string" | … | "field-color").
      // UNLIKE code/diagram (one bpType per node) this node serves 7 bpTypes;
      // the node-view dispatches the control by it, and run-convert reconstructs
      // block.type from it. data-field-type carries it (matching the per-block
      // BarkparkFieldBlockBridge's data-field-type carrier so the coercion reads
      // the identical attribute name).
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-field-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-field-type": attrs.bpType } : {},
      },
      // fieldName — binds the block to an Expectation field. OPTIONAL (a free field
      // block carries none). Carried VERBATIM so the round-trip preserves the
      // binding. data-field-name matches the per-block carrier.
      fieldName: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-field-name"),
        renderHTML: (attrs) =>
          attrs.fieldName != null && attrs.fieldName !== ""
            ? { "data-field-name": attrs.fieldName }
            : {},
      },
      // value — the editable datum. STRING for every native type EXCEPT
      // field-boolean (a BOOLEAN). The native control edits it; the node-view
      // writes it back (coerced) via setNodeMarkup. We serialize it onto
      // data-value as a STRING — a boolean rides as "true"/"false" and parseHTML
      // restores the boolean for field-boolean (see parseHTML below). The live
      // editor reads the attr off node.attrs (the doc JSON), not the DOM, so the
      // data-value string form only matters for the schema-fallback round-trip.
      value: {
        default: "",
        parseHTML: (el) => {
          const raw = el.hasAttribute("data-value")
            ? el.getAttribute("data-value")
            : "";
          // field-boolean's value is a BOOLEAN — restore it from the string form.
          if (el.getAttribute("data-field-type") === "field-boolean") {
            return raw === "true";
          }
          return raw;
        },
        renderHTML: (attrs) => ({
          "data-value":
            attrs.value === true
              ? "true"
              : attrs.value === false
                ? "false"
                : attrs.value == null
                  ? ""
                  : String(attrs.value),
        }),
      },
      // label — the human label rendered beside the control (config, not the datum).
      // OPTIONAL; carried so the round-trip preserves it. data-field-label.
      label: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-field-label")
            ? el.getAttribute("data-field-label")
            : null,
        renderHTML: (attrs) =>
          attrs.label != null
            ? { "data-field-label": attrs.label }
            : {},
      },
      // options — field-select's option list (config). An array of {value,label}.
      // Carried as a JSON string on data-field-options so the select round-trips its
      // options byte-identically. null/absent for non-select types.
      options: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-field-options");
          if (raw == null || raw === "") return null;
          try {
            return JSON.parse(raw);
          } catch (_) {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.options != null
            ? { "data-field-options": JSON.stringify(attrs.options) }
            : {},
      },
      // rows — field-text's textarea row count (config). OPTIONAL (defaults 3 at
      // render time). Carried so a non-default rows round-trips. data-field-rows.
      rows: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-field-rows");
          if (raw == null || raw === "") return null;
          const n = parseInt(raw, 10);
          return Number.isFinite(n) ? n : null;
        },
        renderHTML: (attrs) =>
          attrs.rows != null ? { "data-field-rows": String(attrs.rows) } : {},
      },
    };
  },

  // Parse a rendered field shell back into a field node (so setContent of the
  // node-view's own DOM round-trips). We match ONLY our own data-attributed wrapper
  // (a <div data-bp-type='field'>) reading the typed attrs off data-*; no bare-tag
  // claim (UNLIKE code's <pre>), so we never contend with another node's parse rule.
  parseHTML() {
    return [{ tag: "div[data-bp-type='field']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — e.g. the
  // pure-Node round-trip, or a non-editable export). The node-view (below) OVERRIDES
  // this in the live editor; this keeps the schema self-describing and gives
  // parseHTML a target. All data rides the typed attrs (via their renderHTML), so
  // the <div> body is empty. data-bp-type='field' is the parse anchor.
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-type": "field" })];
  },

  // ── the NodeView: a frame wrapping the NON-PM native control island ──────────
  //
  // Builds:
  //   <div class="bp-canvas-field" data-bp-type="field" data-field-type="field-*">
  //     <label class="bp-canvas-field-label">…label…</label>
  //     <…native control…>                          ← the EDIT island
  //
  // The native control is the edit surface ProseMirror DOES NOT MANAGE:
  //   * stopEvent:()=>true      — PM never turns its key/input/change/click events
  //     into transactions (editing a field never splits/mutates the PM doc).
  //   * ignoreMutation:()=>true — PM never reads its DOM mutations into the
  //     document (the control lives OUTSIDE any contentDOM; there is none).
  // On the control's input/change, the view COERCES the value by bpType (lifted
  // from BarkparkFieldBlockBridge) and writes it back to the node's `value` attr
  // via setNodeMarkup → onUpdate → run-convert emits a patch-block carrying the
  // coerced value.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const fieldType = (node.attrs && node.attrs.bpType) || "field-string";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-field";
      dom.setAttribute("data-bp-type", "field");
      dom.setAttribute("data-field-type", fieldType);

      // The human label (a non-PM, non-editable caption beside the control).
      const labelEl = document.createElement("label");
      labelEl.className = "bp-canvas-field-label";
      labelEl.textContent = (node.attrs && node.attrs.label) || "";

      // Build the native control for this field type. The control is the EDIT
      // island — PM never manages it (stopEvent / ignoreMutation below).
      const control = buildControl(fieldType, node);
      control.classList.add("bp-canvas-field-control");
      control.setAttribute("contenteditable", "false");
      control.setAttribute("data-test-id", "paper-field-" + fieldType);

      dom.appendChild(labelEl);
      dom.appendChild(control);

      // Paint the control from the node's current attrs. Re-run on every update()
      // so an external attr change (an echo, an undo) reflects. Guard against
      // clobbering the field the user is actively editing (don't reset mid-edit) by
      // only writing when the incoming value differs.
      const paint = (n) => {
        const value = n.attrs && n.attrs.value;
        const editable = editor.isEditable;
        if (fieldType === "field-boolean") {
          const checked = value === true;
          if (control.checked !== checked) control.checked = checked;
          control.disabled = !editable;
        } else {
          const str = value == null ? "" : String(value);
          if (control.value !== str) control.value = str;
          // select / color / datetime / text / string controls: lock when read-only.
          if (control.tagName === "SELECT") {
            control.disabled = !editable;
          } else {
            control.readOnly = !editable;
          }
        }
        labelEl.textContent = (n.attrs && n.attrs.label) || "";
      };

      paint(node);

      // Debounced (string/slug/text) or immediate (change) write-back of the COERCED
      // value to the node's `value` attr. setNodeMarkup changes ONLY the attr (the
      // node stays the same atom in the same place), so onUpdate → run-convert emits
      // a single patch-block carrying the new value. The debounce mirrors the
      // editor's DEBOUNCE_MS so a burst of keystrokes coalesces into one attr write.
      let writeTimer = null;
      const commitNow = () => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        // LIFT the BarkparkFieldBlockBridge coercion: boolean → checked; else value.
        const nextValue = coerceFieldValue(fieldType, control);
        if (cur.attrs.value === nextValue) return; // nothing changed — emit nothing
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, value: nextValue });
            return true;
          })
          .run();
      };
      const scheduleWrite = () => {
        if (!editor.isEditable) return;
        if (DEBOUNCED_FIELD_TYPES.has(fieldType)) {
          if (writeTimer) clearTimeout(writeTimer);
          writeTimer = setTimeout(() => {
            writeTimer = null;
            commitNow();
          }, DEBOUNCE_MS);
        } else {
          commitNow();
        }
      };

      // Mirror BarkparkFieldBlockBridge's event binding: string/slug/text on
      // `input` (debounced); boolean/select/datetime/color on `change`.
      const eventName = DEBOUNCED_FIELD_TYPES.has(fieldType) ? "input" : "change";
      control.addEventListener(eventName, scheduleWrite);

      return {
        dom,
        // NO contentDOM — this is an atom; the control is NOT a PM content hole.
        // The value lives in the `value` attr, edited entirely outside ProseMirror.

        // Re-render the control when the node's attrs change (echo/undo). Return
        // false for a different node type so PM rebuilds the view; also rebuild when
        // the field TYPE itself changed (a different control is needed).
        update: (updated) => {
          if (updated.type.name !== BP_FIELD_NODE_NAME) return false;
          const nextType = (updated.attrs && updated.attrs.bpType) || "field-string";
          if (nextType !== fieldType) return false; // type swap → full rebuild
          paint(updated);
          return true;
        },

        // THE ISLAND CONTRACT: PM must NOT turn the control's events into
        // transactions. Returning true from stopEvent for every event in our DOM
        // tree tells ProseMirror "this is handled by the view, leave it alone" — so a
        // keystroke / toggle / select never becomes a PM split/mutation/caret jump.
        stopEvent: () => true,

        // PM must NOT read the control's DOM mutations back into the document. The
        // control is outside any contentDOM; returning true tells PM's
        // MutationObserver to ignore every mutation under this node-view.
        ignoreMutation: () => true,

        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          control.removeEventListener(eventName, scheduleWrite);
        },
      };
    };
  },
});

// Build the native HTML control for a field type, seeded with the node's value.
// MIRRORS the per-block controls (paper_editor.ex:735-787) so the canvas control
// is the same native element the per-block path renders.
function buildControl(fieldType, node) {
  const attrs = (node && node.attrs) || {};
  const value = attrs.value;

  switch (fieldType) {
    case "field-text": {
      const ta = document.createElement("textarea");
      ta.className = "bp-canvas-field-textarea";
      ta.rows = attrs.rows != null ? attrs.rows : 3;
      ta.value = value == null ? "" : String(value);
      return ta;
    }

    case "field-boolean": {
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = value === true;
      return cb;
    }

    case "field-select": {
      const sel = document.createElement("select");
      sel.className = "bp-canvas-field-select";
      const options = Array.isArray(attrs.options) ? attrs.options : [];
      // Render each option from the block's own inline `options` config (the
      // schema descriptor rides the block — see blocks.ex default_block field-select
      // + paper_editor.ex:763-769). Options ARE available in the canvas context, so
      // we render the real <select> — NO read-only degradation needed.
      for (const opt of options) {
        const o = document.createElement("option");
        const ov = opt && opt.value != null ? String(opt.value) : "";
        o.value = ov;
        o.textContent =
          opt && opt.label != null ? String(opt.label) : ov;
        if (ov === (value == null ? "" : String(value))) o.selected = true;
        sel.appendChild(o);
      }
      return sel;
    }

    case "field-datetime": {
      const inp = document.createElement("input");
      inp.type = "datetime-local";
      inp.className = "bp-canvas-field-datetime";
      inp.value = value == null ? "" : String(value);
      return inp;
    }

    case "field-color": {
      const inp = document.createElement("input");
      inp.type = "color";
      inp.className = "bp-canvas-field-color";
      inp.value = value == null || value === "" ? "#000000" : String(value);
      return inp;
    }

    // field-string / field-slug (and any unforeseen native type) → a text input.
    default: {
      const inp = document.createElement("input");
      inp.type = "text";
      inp.className = "bp-canvas-field-text";
      inp.value = value == null ? "" : String(value);
      return inp;
    }
  }
}
