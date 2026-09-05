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
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAME is `bpField` (the canvas naming convention, like
// bpCode/bpDiagram). The portable-doc `bpType` is the specific field-* kind
// ("field-string" | … | "field-color"), carried on the node so run-convert.js can
// render the right control and reconstruct the right block.type. There is NO
// StarterKit collision for `bpField` (StarterKit ships no field node), so NO
// StarterKit node is disabled for it.
export const BP_FIELD_NODE_NAME = "bpField";

// The 7 NATIVE-CONTROL field-* bpTypes this node-view owns through a native HTML
// control. Keep aligned with run-convert.js:CANVAS_NATIVE_FIELD_TYPES and
// paper_canvas.ex:@canvas_field_types.
export const BP_NATIVE_FIELD_TYPES = [
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
];

// The 2 PICKER field-* bpTypes this node-view owns through a client-side WC (the
// run-splitter tail, part 1). field-image mounts <bp-media-picker>; field-reference
// mounts <bp-reference-picker>. Both ride the SAME `bpField` atom shape as the native
// types — value in an attr, a stopEvent/ignoreMutation island, coerced/patched as
// { value } — but the edit surface is the EXISTING picker WC, not a native control.
// Keep aligned with run-convert.js:CANVAS_PICKER_FIELD_TYPES and
// paper_canvas.ex:@canvas_picker_field_types.
export const BP_PICKER_FIELD_TYPES = ["field-image", "field-reference"];

// True when a bpType is a PICKER field (mounts a WC) rather than a native control.
function isPickerFieldType(bpType) {
  return bpType === "field-image" || bpType === "field-reference";
}

// The picker WC tag name for a picker bpType. field-image → bp-media-picker;
// field-reference → bp-reference-picker. MIRRORS the per-block render
// (paper_editor.ex:813-835) so the canvas mounts the SAME element the per-block path does.
const PICKER_TAG = {
  "field-image": "bp-media-picker",
  "field-reference": "bp-reference-picker",
};

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

// ── THE PICKER COERCION (lifted verbatim from BarkparkFieldBlockBridge) ───────
//
// The pickers (bp-media-picker / bp-reference-picker) own their own DOM and emit a
// bubbling `bp-change` CustomEvent({detail:{value}}) on selection/clear — a plain
// STRING (a media id/url for image; a doc id for reference). The per-block bridge's
// picker branch (root.html.heex:3677-3683) is pure IDENTITY: push(e.detail.value),
// i.e. {op:"patch-block", id, patch:{value: e.detail.value}}. coercePickerValue LIFTS
// that exact identity so a canvas picker edit persists the SAME `value` the per-block
// path does. A missing detail/value coerces to "" (the empty/cleared value).
// Exported so __smoke.mjs can assert fidelity against the bridge.
export function coercePickerValue(detail) {
  const v = detail && detail.value;
  return v == null ? "" : v;
}

// pdd-t2: the calm lock cue for a template-locked field node-view. Stamps
// data-bp-locked (a CSS hook for the quiet accent) + a hover title ("Part of the
// document template") on the frame — chrome around content, NEVER an error flash
// or shake (doctrine rule 5). No-op for an unlocked field.
function applyLockCue(dom, node) {
  if (node && node.attrs && node.attrs.locked === true) {
    dom.setAttribute("data-bp-locked", "true");
    dom.setAttribute("title", "Part of the document template");
  }
}

// ── the featured-image PLACEHOLDER (t13 — pd-doctrine rule 1 + 5) ──────────────
//
// Post-#1161 every new paper seeds a locked `role: "featured"` image with NO asset
// (Content.Papers.Template). An asset-less image picker on the canvas must NOT look
// broken/empty — it is the doctrine's affordance: a calm evergreen GHOST FRAME
// ("Add a featured image") that IS the edit surface (rule 5 — chrome around content,
// never a mode). The frame is the click/Enter/right-click target that opens the
// EXISTING media picker; once an asset is chosen the frame gives way to the picker's
// own preview. These pure helpers hold the DECISION + copy so the pure-Node smoke
// harness (no DOM) can assert the placeholder logic without mounting a node-view.
// COPY NOTE: the frame's copy is the GENERIC "Add an image" — a `field-image`
// node is a schema image FIELD (a cover, a byline portrait, …) whose own label
// renders directly above the frame; claiming "featured" here would be wrong for
// every one of them. The seeded featured block is `type:"image"` — a canvas run
// BOUNDARY that renders through the per-block path (paper_editor.ex `"image"`
// clause), where its role IS known and the featured copy lives (root.html.heex
// `[data-block-role="featured"]`). When t2/w3 route `type:"image"` into the
// canvas, pass its role through here and specialize the copy then.
export const IMAGE_PLACEHOLDER_LABEL = "Add an image";
export const IMAGE_PLACEHOLDER_HINT = "Click, or press Enter, to choose from the media library";

// True when a picker's value is ABSENT — null / undefined / empty / whitespace-only.
// The placeholder shows exactly when this is true for an image picker; the SAME
// emptiness test the reader uses to skip an asset-less image (compose.ex `image`
// clause), so the editor placeholder and the public skip agree on "no asset yet".
export function isEmptyPickerValue(value) {
  return value == null || String(value).trim() === "";
}

// The placeholder MODEL for a picker field: whether to show the ghost frame, plus its
// copy. Only the `field-image` picker gets the image placeholder (a field-reference's
// empty state is its own typeahead pill, unchanged). The optional `label` is the
// block's human field label ("Cover", …): the visible copy stays generic (the label
// already renders above the frame — repeating it would stutter), but the aria-label
// carries it so a screen reader hears WHICH image field the button fills. PURE +
// DOM-free so the smoke harness asserts it directly.
export function imagePlaceholderModel(fieldType, value, label) {
  const fieldLabel = label == null ? "" : String(label).trim();

  return {
    show: fieldType === "field-image" && isEmptyPickerValue(value),
    label: IMAGE_PLACEHOLDER_LABEL,
    hint: IMAGE_PLACEHOLDER_HINT,
    ariaLabel:
      fieldLabel === ""
        ? IMAGE_PLACEHOLDER_LABEL
        : IMAGE_PLACEHOLDER_LABEL + " — " + fieldLabel,
  };
}

// A calm ghost-frame placeholder element — the featured-image affordance. Built in the
// node-view (DOM-only). Keyboard reachable (role=button, tabindex 0, aria-label), and
// wired by the caller so click / Enter / Space / right-click all open the media picker.
// The `.bp-canvas-field-image-empty*` classes are styled in BOTH style mirrors
// (styles.css + root.html.heex — the paper-editor-mirror-check lockstep).
function buildImagePlaceholder(ariaLabel) {
  const el = document.createElement("div");
  el.className = "bp-canvas-field-image-empty";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("role", "button");
  el.setAttribute("tabindex", "0");
  el.setAttribute("aria-label", ariaLabel || IMAGE_PLACEHOLDER_LABEL);
  el.setAttribute("data-test-id", "paper-featured-image-placeholder");

  // A calm framed-picture glyph (inline SVG, currentColor — themes with the label).
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("class", "bp-canvas-field-image-empty-icon");
  icon.setAttribute("viewBox", "0 0 24 24");
  icon.setAttribute("fill", "none");
  icon.setAttribute("stroke", "currentColor");
  icon.setAttribute("stroke-width", "1.6");
  icon.setAttribute("stroke-linecap", "round");
  icon.setAttribute("stroke-linejoin", "round");
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML =
    '<rect x="3" y="4" width="18" height="16" rx="2"></rect>' +
    '<circle cx="8.5" cy="9.5" r="1.5"></circle>' +
    '<path d="M21 16l-5-5-9 9"></path>';

  const label = document.createElement("div");
  label.className = "bp-canvas-field-image-empty-label";
  label.textContent = IMAGE_PLACEHOLDER_LABEL;

  const hint = document.createElement("div");
  hint.className = "bp-canvas-field-image-empty-hint";
  hint.textContent = IMAGE_PLACEHOLDER_HINT;

  el.appendChild(icon);
  el.appendChild(label);
  el.appendChild(hint);
  return el;
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

      // PICKER field types (field-image / field-reference) mount the existing
      // client-side WC instead of a native control — a separate node-view variant
      // (buildPickerNodeView) that mirrors the per-block picker render + lifts the
      // BarkparkFieldBlockBridge identity coercion. Native types fall through.
      if (isPickerFieldType(fieldType)) {
        return buildPickerNodeView({ node, editor, getPos, fieldType });
      }

      const dom = document.createElement("div");
      dom.className = "bp-canvas-field";
      dom.setAttribute("data-bp-type", "field");
      dom.setAttribute("data-field-type", fieldType);
      applyLockCue(dom, node);

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
      const flushPending = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitNow();
      };

      // Mirror BarkparkFieldBlockBridge's event binding: string/slug/text on
      // `input` (debounced); boolean/select/datetime/color on `change`.
      const eventName = DEBOUNCED_FIELD_TYPES.has(fieldType) ? "input" : "change";
      control.addEventListener(eventName, scheduleWrite);
      dom.addEventListener("bp-flush-node", flushPending);

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
          dom.removeEventListener("bp-flush-node", flushPending);
        },
      };
    };
  },
});

// ── the PICKER NodeView: a frame wrapping the non-PM client-side PICKER WC ─────
//
// The picker variant of the control-atom (field-image / field-reference). It mounts
// the EXISTING <bp-media-picker> / <bp-reference-picker> Web Component — client-side,
// no LiveView dependency — exactly the way the per-block editor does
// (paper_editor.ex:813-835), seeded with `value` (+ the dataset/refType/token scope),
// listens for the picker's bubbling `bp-change` CustomEvent, and on selection writes
// the new value back via setNodeMarkup → onUpdate → run-convert emits a patch-block
// carrying ONLY { value } (the exact bridge op shape). The picker's own DOM is a non-PM
// island (stopEvent/ignoreMutation) so its clicks/typeahead-fetches never become PM
// transactions / split the doc.
//
// SCOPE: a picker fetches against a dataset (+ a scope-prefix on the scoped surface,
// + a bearer token for media uploads). Per-block precedence is
// `Map.get(@block, "dataset", @dataset)` — a block-pinned dataset wins, else the
// canvas-host dataset. We mirror it: the block-pinned `dataset` rides the node attr;
// the host dataset / scope-prefix / token ride data-* on the <bp-paper-canvas> host
// (read once via canvasScope below). The picker still RENDERS without scope (it
// defaults dataset="production" and an empty token just disables upload) — so the
// pure-Node harness, which never mounts a node-view, is unaffected.
function buildPickerNodeView({ node, editor, getPos, fieldType }) {
  const tag = PICKER_TAG[fieldType] || "bp-media-picker";
  const scope = canvasScope(editor);

  const dom = document.createElement("div");
  dom.className = "bp-canvas-field bp-canvas-field-picker";
  dom.setAttribute("data-bp-type", "field");
  dom.setAttribute("data-field-type", fieldType);
  applyLockCue(dom, node);

  // The human label (a non-PM, non-editable caption beside the picker) — same as the
  // native variant + the per-block render (paper_editor.ex:816/828).
  const labelEl = document.createElement("label");
  labelEl.className = "bp-canvas-field-label";
  labelEl.textContent = (node.attrs && node.attrs.label) || "";

  const value = node.attrs && node.attrs.value;

  // An item-share edit grant authorizes writes to this one paper, not dataset
  // discovery. Keep the already-stored value visible, but do not mount either
  // picker WC (both issue independent HTTP browse requests when upgraded).
  if (!scope.pickerBrowse) {
    const current = document.createElement("output");
    current.className = "bp-canvas-field-control bp-paper-picker-current";
    current.setAttribute("data-test-id", "paper-picker-current");
    current.textContent = value == null ? "" : String(value);
    dom.appendChild(labelEl);
    dom.appendChild(current);

    return {
      dom,
      update(updatedNode) {
        if (!isPickerFieldType(updatedNode.attrs && updatedNode.attrs.bpType)) return false;
        node = updatedNode;
        applyLockCue(dom, node);
        labelEl.textContent = (node.attrs && node.attrs.label) || "";
        const next = node.attrs && node.attrs.value;
        current.textContent = next == null ? "" : String(next);
        return true;
      },
      stopEvent: () => true,
      ignoreMutation: () => true,
    };
  }

  // The picker WC — the EDIT island PM does NOT manage. Seed value + scope as
  // ATTRIBUTES, mirroring the per-block <bp-media-picker>/<bp-reference-picker> render
  // EXACTLY (value / dataset / data-token / ref-type / scope-prefix).
  const picker = document.createElement(tag);
  picker.className = "bp-canvas-field-control";
  picker.setAttribute("contenteditable", "false");
  picker.setAttribute("data-test-id", "paper-field-" + fieldType);

  picker.setAttribute("value", value == null ? "" : String(value));

  // dataset precedence: block-pinned attr wins, else the canvas-host dataset (the same
  // `Map.get(@block, "dataset", @dataset)` order the per-block render uses). Omit the
  // attr entirely when neither is set so the WC keeps its own "production" default.
  const ds = (node.attrs && node.attrs.dataset) || scope.dataset;
  if (ds) picker.setAttribute("dataset", ds);
  // scope-prefix ("" on the flat surface) — byte-identical fetch paths when empty, so
  // only set it when non-empty.
  if (scope.scopePrefix) picker.setAttribute("scope-prefix", scope.scopePrefix);

  if (fieldType === "field-image") {
    // GHOST chrome (pd-doctrine rule 6): in the canvas the picker is an atom that
    // must show nothing the reader lacks — no Upload/Browse/Remove button row. The
    // ghost variant renders the bare preview (or, while empty, the placeholder
    // frame in front of it) and routes actions through the WC's context menu +
    // the public openFileDialog()/openBrowser() methods below.
    picker.setAttribute("chrome", "ghost");
    // The media picker reads the raw bearer token from data-token (empty disables
    // upload; browse + select still work). Per-block: data-token={@api_token_raw}.
    if (scope.token) picker.setAttribute("data-token", scope.token);
  } else {
    // The reference picker reads its target schema from ref-type (empty browses all
    // types). Per-block: ref-type={Map.get(@block, "refType", "")}.
    picker.setAttribute("ref-type", (node.attrs && node.attrs.refType) || "");
  }

  dom.appendChild(labelEl);
  dom.appendChild(picker);

  // ── the featured-image PLACEHOLDER affordance (t13) ─────────────────────────
  //
  // For a `field-image` picker with NO asset, the calm ghost frame IS the edit
  // surface (rule 5: chrome around content, never a mode). It sits IN FRONT of the
  // raw WC (whose bare empty card would read as "damaged" on a freshly-seeded paper)
  // and, on click / Enter / Space / right-click, REVEALS the media picker and opens
  // its chooser — a progressive reveal, not a mode-switch: the block is always
  // editable and the placeholder is its affordance. Once an asset lands (value set),
  // the frame steps aside for the WC's own preview. field-reference keeps its native
  // typeahead pill (no placeholder).
  const isImagePicker = fieldType === "field-image";
  const placeholder = isImagePicker
    ? buildImagePlaceholder(
        imagePlaceholderModel(fieldType, value, node.attrs && node.attrs.label).ariaLabel
      )
    : null;

  // Once the user reveals the picker we keep it revealed even if an echo re-paints
  // with a still-empty value, so an in-flight browse is never yanked away.
  let revealed = false;

  // Open the media picker: reveal the real WC and trigger its chooser. We prefer
  // the WC's PUBLIC openBrowser() method (ghost chrome omits the .bp-mp-browse
  // button, so we no longer poke internals); the querySelector chain is kept as a
  // best-effort fallback for an older/default-chrome WC. Each step is guarded so a
  // WC-internal change can never throw here.
  const openPicker = () => {
    if (!editor.isEditable) return;
    revealed = true;
    if (placeholder) placeholder.hidden = true;
    picker.hidden = false;
    if (typeof picker.openBrowser === "function") {
      // openBrowser() reports whether the asset-browser modal actually opened
      // (false when window.BpAssetBrowser isn't wired) — fall back to the file
      // dialog so a placeholder click is never a dead affordance.
      if (picker.openBrowser()) return;
      if (typeof picker.openFileDialog === "function") {
        // Hand keyboard focus to the revealed empty card BEFORE the dialog, so
        // a cancel lands the keyboard user on the picker, not <body>.
        const card = picker.querySelector && picker.querySelector(".bp-mp-empty");
        if (card && typeof card.focus === "function") card.focus();
        picker.openFileDialog();
        return;
      }
      return;
    }
    // Fallback (older WC without the public method): poke the internal DOM.
    const trigger =
      (picker.querySelector && picker.querySelector(".bp-mp-browse")) ||
      (picker.querySelector && picker.querySelector(".bp-mp-empty"));
    if (trigger && typeof trigger.click === "function") {
      // Hand keyboard focus to the revealed control BEFORE clicking it — hiding
      // the focused placeholder would otherwise drop focus to <body>, stranding
      // a keyboard user (Escape-out of the asset browser lands back here).
      if (typeof trigger.focus === "function") trigger.focus();
      trigger.click();
    } else if (typeof picker.focus === "function") {
      picker.focus();
    }
  };

  const onPlaceholderKey = (e) => {
    if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
      e.preventDefault();
      openPicker();
    }
  };
  const onPlaceholderContext = (e) => {
    // A right-click on the placeholder is a one-entry menu: open the picker.
    e.preventDefault();
    openPicker();
  };

  if (placeholder) {
    dom.appendChild(placeholder);
    placeholder.addEventListener("click", openPicker);
    placeholder.addEventListener("keydown", onPlaceholderKey);
    placeholder.addEventListener("contextmenu", onPlaceholderContext);
  }

  // Write the COERCED value back to the node's `value` attr. setNodeMarkup changes ONLY
  // the attr (the node stays the same atom in the same place), so onUpdate → run-convert
  // emits a single patch-block carrying { value }. UNLIKE the native types there is NO
  // debounce: the picker only fires `bp-change` on a discrete selection/clear (not per
  // keystroke), so each change is committed immediately — matching the per-block bridge
  // (which forwards the picker's bp-change straight through, undebounced).
  const commit = (nextValue) => {
    if (!editor.isEditable) return;
    if (typeof getPos !== "function") return;
    const pos = getPos();
    if (pos == null) return;
    const cur = editor.state.doc.nodeAt(pos);
    if (!cur) return;
    if (cur.attrs.value === nextValue) return; // nothing changed — emit nothing
    editor
      .chain()
      .command(({ tr }) => {
        tr.setNodeMarkup(pos, undefined, { ...cur.attrs, value: nextValue });
        return true;
      })
      .run();
  };

  // LIFT the BarkparkFieldBlockBridge picker branch: the picker's bp-change detail.value
  // IS the new value (identity), forwarded as a patch-block{value}.
  const onChange = (e) => commit(coercePickerValue(e.detail));
  picker.addEventListener("bp-change", onChange);

  // Keep the seeded picker in sync with an EXTERNAL attr change (an echo, an undo) — the
  // WC exposes a `value` PROPERTY setter (bp-media-picker.js:108 / bp-reference-picker.js
  // :516) that re-renders its preview/pill. Only write when it differs so we never
  // re-render the picker the user is mid-interaction with, and never re-fire bp-change
  // (the setter does not emit).
  const paint = (n) => {
    const v = n.attrs && n.attrs.value;
    const str = v == null ? "" : String(v);
    if (picker.value !== str) picker.value = str;
    labelEl.textContent = (n.attrs && n.attrs.label) || "";

    // Show the ghost frame ONLY for an asset-less image picker that has not yet been
    // revealed; the moment an asset is present the frame steps aside for the WC.
    if (placeholder) {
      const model = imagePlaceholderModel(fieldType, str, n.attrs && n.attrs.label);
      const showPlaceholder = model.show && !revealed;
      placeholder.hidden = !showPlaceholder;
      placeholder.setAttribute("aria-label", model.ariaLabel);
      picker.hidden = showPlaceholder;
      // A non-empty value ends any prior reveal, so a later CLEAR shows the frame again.
      if (!isEmptyPickerValue(str)) revealed = false;
    }
  };

  // Initialize placeholder/picker visibility from the seed value (the WC seeds its own
  // value via the attribute above; this only toggles the ghost-frame overlay).
  paint(node);

  return {
    dom,
    // NO contentDOM — an atom; the picker WC is NOT a PM content hole. The value lives
    // in the `value` attr, edited entirely outside ProseMirror.
    update: (updated) => {
      if (updated.type.name !== BP_FIELD_NODE_NAME) return false;
      const nextType = (updated.attrs && updated.attrs.bpType) || "field-string";
      if (nextType !== fieldType) return false; // type swap → full rebuild
      paint(updated);
      return true;
    },
    // THE ISLAND CONTRACT: PM must NOT turn the picker's events into transactions — a
    // click / typeahead keystroke / fetch never becomes a PM split/mutation/caret jump.
    stopEvent: () => true,
    // PM must NOT read the picker's DOM mutations back into the document — the picker
    // renders its own preview/dropdown DOM outside any contentDOM.
    ignoreMutation: () => true,
    destroy: () => {
      picker.removeEventListener("bp-change", onChange);
      if (placeholder) {
        placeholder.removeEventListener("click", openPicker);
        placeholder.removeEventListener("keydown", onPlaceholderKey);
        placeholder.removeEventListener("contextmenu", onPlaceholderContext);
      }
    },
  };
}

// Read the canvas-host scope (dataset / scope-prefix / bearer token) for the pickers.
// The host <bp-paper-canvas> carries data-dataset / data-scope-prefix / data-token
// (stamped by the BarkparkPaperCanvas hook from the run wrapper). The node-view reaches
// it via editor.options.element (the mount .bp-paper-editor-body) → closest(
// "bp-paper-canvas"). All optional — a missing host or missing attr yields "" so the
// picker keeps its own defaults (dataset="production", no token → upload disabled).
export function canvasScope(editor) {
  const empty = { dataset: "", scopePrefix: "", token: "", pickerBrowse: true };
  try {
    const mount = editor && editor.options && editor.options.element;
    if (!mount || typeof mount.closest !== "function") return empty;
    const host = mount.closest("bp-paper-canvas");
    if (!host || typeof host.getAttribute !== "function") return empty;
    return {
      dataset: host.getAttribute("data-dataset") || "",
      scopePrefix: host.getAttribute("data-scope-prefix") || "",
      token: host.getAttribute("data-token") || "",
      pickerBrowse: host.getAttribute("data-picker-browse") !== "false",
    };
  } catch (_e) {
    return empty;
  }
}

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
