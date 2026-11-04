// Picker Web Component node-view implementation for field-image and field-reference.

import { mountFieldBinding } from "./field-binding.js";
import { t } from "../i18n.js";
import { coercePickerValue } from "./field-values.js";
import {
  BP_FIELD_NODE_NAME,
  IMAGE_PLACEHOLDER_HINT,
  IMAGE_PLACEHOLDER_LABEL,
  applyLockCue,
  buildFieldReader,
  canvasScope,
  imagePlaceholderModel,
  isEmptyPickerValue,
  isPickerFieldType,
  mountFieldEditorState,
  mountFieldLabel,
  nameControl,
} from "./field-view.js";

// The picker WC tag name for a picker bpType. field-image → bp-media-picker;
// field-reference → bp-reference-picker. MIRRORS the per-block render
// (paper_editor.ex:813-835) so the canvas mounts the SAME element the per-block path does.
const PICKER_TAG = {
  "field-image": "bp-media-picker",
  "field-reference": "bp-reference-picker",
};

function buildImagePlaceholder(ariaLabel) {
  const el = document.createElement("div");
  el.className = "bp-canvas-field-image-empty";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("role", "button");
  el.setAttribute("tabindex", "0");
  el.setAttribute("aria-label", ariaLabel || t(IMAGE_PLACEHOLDER_LABEL));
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
  label.textContent = t(IMAGE_PLACEHOLDER_LABEL);

  const hint = document.createElement("div");
  hint.className = "bp-canvas-field-image-empty-hint";
  hint.textContent = t(IMAGE_PLACEHOLDER_HINT);

  el.appendChild(icon);
  el.appendChild(label);
  el.appendChild(hint);
  return el;
}

// The field types whose control commits on `input` (debounced), mirroring

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

  const reader = buildFieldReader(node, fieldType);
  const dom = reader.dom;
  dom.classList.add("bp-canvas-field", "bp-canvas-field-picker");
  dom.setAttribute("data-bp-type", "field");
  dom.setAttribute("data-field-type", fieldType);
  applyLockCue(dom, node);
  const editorDom = document.createElement("div");
  editorDom.className = "bp-canvas-field-editor";
  editorDom.setAttribute("contenteditable", "false");

  // The human label (a non-PM, non-editable caption beside the picker) — same as the
  // native variant + the per-block render (paper_editor.ex:816/828).
  const labelEl = document.createElement("label");
  labelEl.className = "bp-canvas-field-label";
  labelEl.textContent = (node.attrs && node.attrs.label) || "";

  const value = node.attrs && node.attrs.value;

  // An item-share edit grant authorizes writes to this one paper, not dataset
  // discovery. Keep the already-stored value visible, but do not mount either
  // picker WC (both issue independent HTTP browse requests when upgraded).
  if (!scope.pickerBrowse) return buildPickerReadOnlyView(node, fieldType);
  let picker = null;
  // The reference picker builds its search input when it renders, so the label
  // rides an attribute it reads then, and names the input already there.
  const label = mountFieldLabel(labelEl, {
    editor,
    getPos,
    onName: (text) => {
      if (!picker) return;
      if (text) picker.setAttribute("data-field-label", text);
      else picker.removeAttribute("data-field-label");
      nameControl(picker.querySelector(".bp-ref-search-input"), text);
    },
  });

  // The picker WC — the EDIT island PM does NOT manage. Seed value + scope as
  // ATTRIBUTES, mirroring the per-block <bp-media-picker>/<bp-reference-picker> render
  // EXACTLY (value / dataset / data-token / ref-type / scope-prefix).
  picker = document.createElement(tag);
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
  // The workspace's picker strings; absent, the WC keeps its English defaults.
  const strings = fieldType === "field-image" ? scope.mediaStrings : scope.referenceStrings;
  if (strings) picker.setAttribute("data-strings", strings);

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

  editorDom.appendChild(labelEl);
  editorDom.appendChild(picker);
  dom.appendChild(editorDom);
  const binding = mountFieldBinding(dom, { editor, getPos });
  const bindingDom = dom.querySelector(":scope > .bp-canvas-field-binding");
  if (bindingDom) editorDom.appendChild(bindingDom);

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
    editorDom.appendChild(placeholder);
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
  let referenceTitle = "";
  let referenceTitleValue = "";
  let paintedValue = value == null ? "" : String(value);
  const onChange = (e) => {
    const nextValue = coercePickerValue(e.detail);
    if (fieldType === "field-reference") {
      const titleEl = picker.querySelector && picker.querySelector(".ref-selected-title");
      referenceTitle = titleEl ? String(titleEl.textContent || "").trim() : "";
      referenceTitleValue = nextValue;
      reader.paint({ attrs: { ...node.attrs, value: nextValue } }, { referenceTitle });
    }
    commit(nextValue);
  };
  picker.addEventListener("bp-change", onChange);
  dom.addEventListener("bp-flush-node", label.flush);

  // Keep the seeded picker in sync with an EXTERNAL attr change (an echo, an undo) — the
  // WC exposes a `value` PROPERTY setter (bp-media-picker.js:108 / bp-reference-picker.js
  // :516) that re-renders its preview/pill. Only write when it differs so we never
  // re-render the picker the user is mid-interaction with, and never re-fire bp-change
  // (the setter does not emit).
  const paint = (n) => {
    const v = n.attrs && n.attrs.value;
    const str = v == null ? "" : String(v);
    if (str !== paintedValue) {
      paintedValue = str;
      if (fieldType === "field-reference" && str !== referenceTitleValue) {
        referenceTitle = "";
        referenceTitleValue = "";
      }
    }
    if (picker.value !== str) picker.value = str;
    label.paint(n);
    reader.paint(n, { referenceTitle });
    binding.paint(n);

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
  const editorState = mountFieldEditorState({
    dom,
    readerParts: reader.parts,
    editorDom,
    editor,
    focusTarget: () => picker.querySelector("input, button, [tabindex]") || picker,
  });

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
      label.destroy();
      editorState.destroy();
      binding.destroy();
      dom.removeEventListener("bp-flush-node", label.flush);
      picker.removeEventListener("bp-change", onChange);
      if (placeholder) {
        placeholder.removeEventListener("click", openPicker);
        placeholder.removeEventListener("keydown", onPlaceholderKey);
        placeholder.removeEventListener("contextmenu", onPlaceholderContext);
      }
    },
  };
}

// The read-only picker atom: label + the stored value, no WC. Used when the grant
// cannot browse (an item-share edit grant authorizes writes to this one paper, not
// dataset discovery) and when the picker WC failed to build (`failed`).
function buildPickerReadOnlyView(node, fieldType, { failed = false } = {}) {
  const reader = buildFieldReader(node, fieldType);
  const dom = reader.dom;
  dom.classList.add("bp-canvas-field", "bp-canvas-field-picker");
  dom.setAttribute("data-bp-type", "field");
  dom.setAttribute("data-field-type", fieldType);
  if (failed) dom.setAttribute("data-node-view-failed", "true");
  applyLockCue(dom, node);

  // A failed media picker must remain inspectable without relying on the image
  // request succeeding. The canonical reader intentionally paints only the image;
  // this extra stored-value text belongs solely to the degraded node-view path.
  const failedImageValue = failed && fieldType === "field-image"
    ? document.createElement("span")
    : null;
  const paintFailedValue = () => {
    if (!failedImageValue) return;
    failedImageValue.className = "bp-field__fallback";
    failedImageValue.textContent = String((node.attrs && node.attrs.value) || "");
    reader.parts[1].appendChild(failedImageValue);
  };
  paintFailedValue();

  return {
    dom,
    update(updatedNode) {
      if (!isPickerFieldType(updatedNode.attrs && updatedNode.attrs.bpType)) return false;
      if (((updatedNode.attrs && updatedNode.attrs.bpType) || "") !== fieldType) return false;
      node = updatedNode;
      applyLockCue(dom, node);
      reader.paint(node);
      paintFailedValue();
      return true;
    },
    stopEvent: () => true,
    ignoreMutation: () => true,
  };
}

// Say that a node view could not be built: a console error for the author's
// devtools and a bubbling `bp-canvas-node-failed` event a host can surface.
function reportNodeViewFailure(editor, node, fieldType, error) {
  const detail = {
    blockId: (node && node.attrs && node.attrs.bpId) || null,
    type: fieldType,
    message: String((error && error.message) || error),
  };
  try {
    console.error("bp-paper-canvas: " + fieldType + " could not open for editing", error);
  } catch (_e) {}
  try {
    const mount = editor && editor.options && editor.options.element;
    if (mount && typeof mount.dispatchEvent === "function") {
      mount.dispatchEvent(new CustomEvent("bp-canvas-node-failed", { detail, bubbles: true, composed: true }));
    }
  } catch (_e) {}
}

export function buildPickerFieldNodeView({ node, editor, getPos, fieldType }) {
  // A picker WC that throws while it is built (a missing global, an
  // upgrade-order bug) must not take the whole run down with it: ProseMirror
  // aborts the paint and the author sees an EMPTY editor where the prose was
  // (task-7188bd8e9eb2625a). Paint the stored value read-only and say so.
  try {
    return buildPickerNodeView({ node, editor, getPos, fieldType });
  } catch (error) {
    reportNodeViewFailure(editor, node, fieldType, error);
    return buildPickerReadOnlyView(node, fieldType, { failed: true });
  }
}
