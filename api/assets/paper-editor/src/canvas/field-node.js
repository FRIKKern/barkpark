// field-node.js — Phase-4 Stage S3.5: the canvas CONTROL-ATOM node-view — the
// FOURTH node-view variant, after divider (atom), callout (content), code/diagram
// (attr-atom).
//
// Brings the 8 NATIVE-CONTROL field-* blocks INTO the continuous canvas as a
// ProseMirror ATOM whose VALUE rides in an ATTR (`value`) and is edited by a
// NATIVE HTML control — like the S3.3 code attr-atom, but the edit surface is a
// TYPED control (input / textarea / checkbox / select / datetime-local / color),
// NOT a free textarea, and the value is COERCED BY FIELD TYPE exactly like the
// shipped BarkparkFieldBlockBridge (root.html.heex ~3543):
//   * field-boolean → a CHECKBOX whose value is `control.checked` (a BOOLEAN).
//   * field-number  → a number input whose value is a NUMBER (null when empty).
//   * everything else → a string control whose value is `control.value` (a STRING).
//
// ── THE 8 NATIVE-CONTROL FIELD TYPES (the S3.5 scope + field-number) ──────────
//
//   field-string  → <input type=text>         value: string
//   field-slug    → <input type=text>         value: string
//   field-text    → <textarea rows=…>          value: string   (rows config carried)
//   field-boolean → <input type=checkbox>      value: BOOLEAN  (control.checked)
//   field-select  → <select><option…>          value: string   (options config carried)
//   field-datetime→ <input type=datetime-local>value: string
//   field-color   → <input type=color>         value: string
//   field-number  → <input type=number>        value: NUMBER|null (min/max/step/unit carried)
//
// PHASE-4 RUN-SPLITTER TAIL (part 1): field-image (the bp-media-picker WC) and
// field-reference (the bp-reference-picker WC) now ALSO ride the canvas as CONTROL-ATOM
// node-views — the SAME `bpField` atom shape as the 7 native types, but the edit surface
// is the EXISTING PICKER Web Component instead of a native HTML control. The pickers are
// CLIENT-SIDE (bp-media-picker.js / bp-reference-picker.js fetch their own data over HTTP;
// no pushEvent / phx- / liveSocket — NO LiveView dependency), so they mount inside a
// node-view exactly like a native control. Each emits a bubbling `bp-change` CustomEvent
// ({detail:{value}}) on selection/clear — the per-block BarkparkFieldBlockBridge coerces
// that to the block `value` IDENTITY (push(e.detail.value) → {op:"patch-block", id,
// patch:{value}}). We LIFT that exact identity coercion (coercePickerValue) so a canvas
// picker edit persists the SAME `value` the per-block path does. The picker's own DOM is
// a non-PM island (stopEvent/ignoreMutation) so its clicks/fetches never become PM
// transactions / split the doc.
//
// section/composite/object/arrayOf/codelist/localizedText STILL split (a separate,
// nested-structure increment) — they are NOT in any canvas-field set.
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
import { coerceFieldValue, coercePickerValue, toFieldNumber } from "./field-values.js";
import {
  BP_FIELD_NODE_NAME,
  BP_NATIVE_FIELD_TYPES,
  BP_PICKER_FIELD_TYPES,
  IMAGE_PLACEHOLDER_HINT,
  IMAGE_PLACEHOLDER_LABEL,
  buildNativeFieldNodeView,
  canvasScope,
  imagePlaceholderModel,
  isEmptyPickerValue,
  isPickerFieldType,
  mountFieldLabel,
  nameControl,
} from "./field-view.js";
import { buildPickerFieldNodeView } from "./field-picker-view.js";

export { coerceFieldValue, coercePickerValue, toFieldNumber };
export {
  BP_FIELD_NODE_NAME,
  BP_NATIVE_FIELD_TYPES,
  BP_PICKER_FIELD_TYPES,
  IMAGE_PLACEHOLDER_HINT,
  IMAGE_PLACEHOLDER_LABEL,
  canvasScope,
  imagePlaceholderModel,
  isEmptyPickerValue,
  mountFieldLabel,
  nameControl,
};

// A field-number config attr (min / max / step): a number or null, carried on
// data-field-<key>.
function numberConfigAttr(key) {
  return {
    [key]: {
      default: null,
      parseHTML: (el) => toFieldNumber(el.getAttribute("data-field-" + key)),
      renderHTML: (attrs) =>
        attrs[key] != null ? { ["data-field-" + key]: String(attrs[key]) } : {},
    },
  };
}

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
          if (el.getAttribute("data-field-type") === "field-number") {
            return toFieldNumber(raw);
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
      // min / max / step / unit — field-number's config. min/max/step become the
      // number input's attributes; unit is shown after it. OPTIONAL, carried so the
      // round-trip preserves them. data-field-min / -max / -step / -unit.
      ...numberConfigAttr("min"),
      ...numberConfigAttr("max"),
      ...numberConfigAttr("step"),
      unit: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-field-unit") ? el.getAttribute("data-field-unit") : null,
        renderHTML: (attrs) =>
          attrs.unit != null ? { "data-field-unit": attrs.unit } : {},
      },
      // refType — field-reference's target schema (config; the `ref-type` attr the
      // bp-reference-picker reads to scope its typeahead). OPTIONAL (an unscoped
      // reference browses all types). Carried VERBATIM so the round-trip preserves it.
      // null/absent for non-reference types. data-field-ref-type.
      refType: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-field-ref-type")
            ? el.getAttribute("data-field-ref-type")
            : null,
        renderHTML: (attrs) =>
          attrs.refType != null
            ? { "data-field-ref-type": attrs.refType }
            : {},
      },
      // dataset — a per-block dataset override for the picker's data fetches (config).
      // OPTIONAL; absent → the picker falls back to the canvas-host dataset (the same
      // `Map.get(@block, "dataset", @dataset)` precedence the per-block render uses,
      // paper_editor.ex:820/831). Carried VERBATIM so a block that pinned a dataset
      // round-trips it. data-field-dataset.
      dataset: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-field-dataset")
            ? el.getAttribute("data-field-dataset")
            : null,
        renderHTML: (attrs) =>
          attrs.dataset != null
            ? { "data-field-dataset": attrs.dataset }
            : {},
      },
      // locked / role — the DOCTRINE template attrs (pdd-t2). A field block could
      // itself be a mandated template block (a future doc type's forced field), so
      // it carries the SAME locked/role round-trip the prose title does (BpAttrs).
      // D3 additive: rendered ONLY when set, so an ordinary field round-trips
      // byte-identically. locked also drives the calm lock cue on the node-view
      // (a hover title + a data-bp-locked hook) — chrome, never an error.
      locked: {
        default: null,
        parseHTML: (el) =>
          el.getAttribute("data-bp-locked") === "true" ? true : null,
        renderHTML: (attrs) =>
          attrs.locked === true ? { "data-bp-locked": "true" } : {},
      },
      role: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-role"),
        renderHTML: (attrs) => (attrs.role ? { "data-bp-role": attrs.role } : {}),
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
      const args = { node, editor, getPos, fieldType };
      return isPickerFieldType(fieldType)
        ? buildPickerFieldNodeView(args)
        : buildNativeFieldNodeView(args);
    };
  },
});
