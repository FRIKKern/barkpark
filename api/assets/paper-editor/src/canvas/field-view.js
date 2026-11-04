// Shared field reader, label, scope and native-control node-view implementation.

import { mountFieldBinding } from "./field-binding.js";
import { DEBOUNCE_MS } from "../contract.js";
import { FIELD_SETTINGS_TYPES, buildFieldSettings } from "./field-settings.js";
import { t } from "../i18n.js";
import { safeUrl } from "../safe-url.js";
import { coerceFieldValue, toFieldNumber } from "./field-values.js";

// The TipTap node NAME is `bpField` (the canvas naming convention, like
// bpCode/bpDiagram). The portable-doc `bpType` is the specific field-* kind
// ("field-string" | … | "field-color"), carried on the node so run-convert.js can
// render the right control and reconstruct the right block.type. There is NO
// StarterKit collision for `bpField` (StarterKit ships no field node), so NO
// StarterKit node is disabled for it.
export const BP_FIELD_NODE_NAME = "bpField";

// The 8 NATIVE-CONTROL field-* bpTypes this node-view owns through a native HTML
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
  "field-number",
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
export function isPickerFieldType(bpType) {
  return bpType === "field-image" || bpType === "field-reference";
}

// The article reader's field row, painted as real DOM so Edit and View share the
// same resting surface. Authoring controls are mounted beside this by the node
// view and revealed only while the field is active; they never replace or
// re-synthesize the reader value.
export function buildFieldReader(node, fieldType) {
  const dom = document.createElement("div");
  dom.className = "bp-field";
  const label = document.createElement("span");
  label.className = "bp-field__l";
  const value = document.createElement("div");
  value.className = "bp-field__v";
  dom.append(label, value);

  const stringish = (input) =>
    typeof input === "string" || typeof input === "boolean"
      ? String(input)
      : typeof input === "number" && Number.isFinite(input)
        ? String(input)
        : "";
  const textValue = (text) => {
    const display = stringish(text);
    const span = document.createElement("span");
    span.textContent = display.trim() === "" ? "—" : display;
    value.replaceChildren(span);
  };
  const mediaUrl = (raw) => {
    const text = stringish(raw).trim();
    if (!text.startsWith("{")) return text;
    try {
      const parsed = JSON.parse(text);
      return parsed && typeof parsed.url === "string" && parsed.url ? parsed.url : text;
    } catch (_) {
      return text;
    }
  };
  const paint = (n, { referenceTitle = "" } = {}) => {
    const attrs = (n && n.attrs) || {};
    const raw = attrs.value;
    label.textContent = stringish(attrs.label);
    value.replaceChildren();
    if (fieldType === "field-boolean") {
      textValue(t(raw === true ? "Yes" : "No"));
    } else if (fieldType === "field-select") {
      const options = Array.isArray(attrs.options) ? attrs.options : [];
      const selected = options.find((option) => option && option.value === raw);
      textValue(selected ? (Object.hasOwn(selected, "label") ? selected.label : selected.value) : raw);
    } else if (fieldType === "field-datetime") {
      textValue(typeof raw === "string" ? raw.replace(/T/g, " ") : raw);
    } else if (fieldType === "field-color") {
      const hex = stringish(raw);
      if (!hex) {
        const none = document.createElement("span");
        none.className = "bp-field__none";
        none.textContent = "—";
        value.appendChild(none);
      } else {
        const swatch = document.createElement("i");
        swatch.className = "bp-field__swatch";
        const background = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(hex) ? hex : "transparent";
        swatch.setAttribute("style", `background:${background}`);
        const mono = document.createElement("span");
        mono.className = "bp-field__mono";
        mono.textContent = hex;
        value.append(swatch, mono);
      }
    } else if (fieldType === "field-number") {
      const number = toFieldNumber(raw);
      const unit = stringish(attrs.unit).trim();
      textValue(number == null ? "—" : `${String(number)}${unit ? ` ${unit}` : ""}`);
    } else if (fieldType === "field-reference") {
      const stored = stringish(raw);
      textValue(stored ? referenceTitle || stored : "—");
    } else if (fieldType === "field-image") {
      const src = mediaUrl(raw);
      if (!src) {
        const none = document.createElement("span");
        none.className = "bp-field__none";
        none.textContent = t("No image");
        value.appendChild(none);
      } else {
        const image = document.createElement("img");
        image.className = "bp-field__img";
        image.setAttribute("src", safeUrl(src));
        image.setAttribute("alt", stringish(attrs.label));
        value.appendChild(image);
      }
    } else {
      textValue(raw);
    }
  };
  paint(node);
  return { dom, paint, parts: [label, value] };
}

// Reader-at-rest interaction: the canonical row is the only visible surface
// until an author clicks it or presses Enter/Space. Escape or leaving the field
// restores the reader row. The editor island remains mounted throughout, so
// existing controls, picker state, debounce and persistence semantics are kept.
export function mountFieldEditorState({ dom, readerParts, editorDom, editor, focusTarget }) {
  let active = false;
  if (editor.isEditable) dom.tabIndex = 0;
  const paint = () => {
    for (const part of readerParts) part.hidden = active;
    editorDom.hidden = !active;
    editorDom.style.display = active ? "contents" : "none";
  };
  const activate = () => {
    if (active || !editor.isEditable) return;
    active = true;
    paint();
    queueMicrotask(() => {
      const target = typeof focusTarget === "function" ? focusTarget() : focusTarget;
      if (target && typeof target.focus === "function") target.focus();
    });
  };
  const deactivate = ({ focus = false } = {}) => {
    if (!active) return;
    active = false;
    paint();
    if (focus && typeof dom.focus === "function") dom.focus();
  };
  const onClick = (event) => {
    if (!active && readerParts.some((part) => part.contains(event.target))) activate();
  };
  const onKey = (event) => {
    if (!active && event.target === dom && (event.key === "Enter" || event.key === " " || event.key === "Spacebar")) {
      event.preventDefault();
      activate();
    } else if (active && event.key === "Escape") {
      event.preventDefault();
      deactivate({ focus: true });
    }
  };
  const onFocusOut = () => queueMicrotask(() => {
    if (active && !dom.contains(dom.ownerDocument.activeElement)) deactivate();
  });
  const onProgrammaticActivate = () => activate();
  dom.addEventListener("click", onClick);
  dom.addEventListener("keydown", onKey);
  dom.addEventListener("focusout", onFocusOut);
  dom.addEventListener("bp-activate-field-editor", onProgrammaticActivate);
  paint();
  return {
    destroy() {
      dom.removeEventListener("click", onClick);
      dom.removeEventListener("keydown", onKey);
      dom.removeEventListener("focusout", onFocusOut);
      dom.removeEventListener("bp-activate-field-editor", onProgrammaticActivate);
    },
  };
}

// True when a number control holds input the server would refuse: text the browser
// cannot parse, or a value outside the block's min/max (blocks.ex
// validate_block_patch). Step alignment is not checked there, so not here either.
function numberInputRefused(control) {
  const v = control.validity;
  return !!(v && (v.badInput || v.rangeUnderflow || v.rangeOverflow));
}

// ── THE PICKER COERCION (lifted verbatim from BarkparkFieldBlockBridge) ───────
//
// The pickers (bp-media-picker / bp-reference-picker) own their own DOM and emit a

// pdd-t2: the calm lock cue for a template-locked field node-view. Stamps
// data-bp-locked (a CSS hook for the quiet accent) + a hover title ("Part of the
// document template") on the frame — chrome around content, NEVER an error flash
// or shake (doctrine rule 5). No-op for an unlocked field.
export function applyLockCue(dom, node) {
  if (node && node.attrs && node.attrs.locked === true) {
    dom.setAttribute("data-bp-locked", "true");
    dom.setAttribute("title", t("Part of the document template"));
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
    // Shown in the viewer's Studio language (the constants are the English keys).
    label: t(IMAGE_PLACEHOLDER_LABEL),
    hint: t(IMAGE_PLACEHOLDER_HINT),
    ariaLabel:
      fieldLabel === ""
        ? t(IMAGE_PLACEHOLDER_LABEL)
        : t(IMAGE_PLACEHOLDER_LABEL) + " — " + fieldLabel,
  };
}

// A calm ghost-frame placeholder element — the featured-image affordance. Built in the
// node-view (DOM-only). Keyboard reachable (role=button, tabindex 0, aria-label), and
// wired by the caller so click / Enter / Space / right-click all open the media picker.
// The `.bp-canvas-field-image-empty*` classes are styled in BOTH style mirrors

const DEBOUNCED_FIELD_TYPES = new Set([
  "field-string",
  "field-slug",
  "field-text",
]);

// Keep a number input's min / max / step on the node's config, so an edit made
// in the settings disclosure bounds the value input without rebuilding it.
function paintNumberBounds(control, attrs) {
  for (const key of ["min", "max"]) {
    const next = attrs[key] != null ? String(attrs[key]) : null;
    if (control.getAttribute(key) === next) continue;
    if (next == null) control.removeAttribute(key);
    else control.setAttribute(key, next);
  }
  const step = attrs.step != null ? String(attrs.step) : "any";
  if (control.getAttribute("step") !== step) control.setAttribute("step", step);
}

// Rebuild a select's <option>s when the node's options list changed.
function paintSelectOptions(select, options, value) {
  const list = Array.isArray(options) ? options : [];
  const painted = [...select.options].map((o) => [o.value, o.textContent]);
  const wanted = list.map((opt) => {
    const ov = opt && opt.value != null ? String(opt.value) : "";
    return [ov, opt && opt.label != null ? String(opt.label) : ov];
  });
  if (JSON.stringify(painted) === JSON.stringify(wanted)) return;
  select.replaceChildren();
  const current = value == null ? "" : String(value);
  for (const [ov, text] of wanted) {
    const o = document.createElement("option");
    o.value = ov;
    o.textContent = text;
    if (ov === current) o.selected = true;
    select.appendChild(o);
  }
}

export function buildNativeFieldNodeView({ node, editor, getPos, fieldType }) {
  const reader = buildFieldReader(node, fieldType);
  const dom = reader.dom;
  dom.classList.add("bp-canvas-field");
  dom.setAttribute("data-bp-type", "field");
  dom.setAttribute("data-field-type", fieldType);
  applyLockCue(dom, node);
  const editorDom = document.createElement("div");
  editorDom.className = "bp-canvas-field-editor";
  editorDom.setAttribute("contenteditable", "false");

  // The human label (a non-PM, non-editable caption beside the control).
  // Build the native control for this field type. The control is the EDIT
  // island — PM never manages it (stopEvent / ignoreMutation below).
  const control = buildControl(fieldType, node);

  const labelEl = document.createElement("label");
  labelEl.className = "bp-canvas-field-label";
  labelEl.textContent = (node.attrs && node.attrs.label) || "";
  const label = mountFieldLabel(labelEl, {
    editor,
    getPos,
    onName: (text) => nameControl(control, text),
  });
  control.classList.add("bp-canvas-field-control");
  control.setAttribute("contenteditable", "false");
  control.setAttribute("data-test-id", "paper-field-" + fieldType);

  editorDom.appendChild(labelEl);
  editorDom.appendChild(control);
  dom.appendChild(editorDom);
  // A bound block's n/max badge and unbind × (field-binding.js, contract 1.13.0).
  const binding = mountFieldBinding(dom, { editor, getPos });
  const bindingDom = dom.querySelector(":scope > .bp-canvas-field-binding");
  if (bindingDom) editorDom.appendChild(bindingDom);
  // field-number shows its unit (if any) after the input, as quiet text. The
  // input and unit share the row's value column. Painted in place (paintUnit)
  // so a unit edited in the settings disclosure keeps the control's focus.
  let valueEl = null;
  const paintUnit = (unit) => {
    if (fieldType !== "field-number") return;
    if (unit && !valueEl) {
      valueEl = document.createElement("span");
      valueEl.className = "bp-canvas-field-value";
      const unitEl = document.createElement("span");
      unitEl.className = "bp-canvas-field-unit";
      control.replaceWith(valueEl);
      valueEl.append(control, unitEl);
    } else if (!unit && valueEl) {
      valueEl.replaceWith(control);
      valueEl = null;
    }
    if (valueEl && valueEl.lastChild.textContent !== unit) valueEl.lastChild.textContent = unit;
  };

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
      if (fieldType === "field-select") paintSelectOptions(control, n.attrs.options, value);
      if (fieldType === "field-number") {
        paintNumberBounds(control, n.attrs);
        paintUnit(n.attrs.unit);
      }
      const str = value == null ? "" : String(value);
      if (control.value !== str) control.value = str;
      // select / color / datetime / text / string controls: lock when read-only.
      if (control.tagName === "SELECT") {
        control.disabled = !editable;
      } else {
        control.readOnly = !editable;
      }
    }
    label.paint(n);
    reader.paint(n);
    if (settings) settings.paint(n);
    binding.paint(n);
  };

  // The quiet CONFIG disclosure (a select's options, a number's range + unit).
  const settings = FIELD_SETTINGS_TYPES.has(fieldType)
    ? buildFieldSettings({
        fieldType,
        editor,
        current: () => {
          const pos = typeof getPos === "function" ? getPos() : null;
          return pos == null ? null : editor.state.doc.nodeAt(pos);
        },
        write: (config) => {
          const pos = getPos();
          const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
          if (!cur) return;
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, { ...cur.attrs, ...config });
              return true;
            })
            .run();
        },
      })
    : null;
  if (settings) editorDom.appendChild(settings.dom);

  const editorState = mountFieldEditorState({
    dom,
    readerParts: reader.parts,
    editorDom,
    editor,
    focusTarget: control,
  });

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
    // A number the server would refuse (out of range, unparseable) stays in the
    // control, marked invalid, and is not saved.
    if (fieldType === "field-number") {
      if (numberInputRefused(control)) {
        control.setAttribute("aria-invalid", "true");
        return;
      }
      control.removeAttribute("aria-invalid");
    }
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
    label.flush();
    if (!writeTimer) return;
    clearTimeout(writeTimer);
    writeTimer = null;
    commitNow();
  };

  // Mirror BarkparkFieldBlockBridge's event binding: string/slug/text on
  // `input` (debounced); boolean/select/datetime/color/number on `change`.
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
      label.destroy();
      editorState.destroy();
      if (settings) settings.destroy();
      binding.destroy();
      control.removeEventListener(eventName, scheduleWrite);
      dom.removeEventListener("bp-flush-node", flushPending);
    },
  };

}

// Name a value control after its field label; an empty label leaves it unnamed
// rather than named "".
export function nameControl(el, text) {
  if (!el) return;
  if (text) el.setAttribute("aria-label", text);
  else el.removeAttribute("aria-label");
}

// ── the field LABEL, edited where it reads ──────────────────────────────────────
//
// The label is the caption the reader paints above the field (block `label`). In
// Edit it is its own plain-text typing surface: a click puts the caret in it, the
// words save as the block's `label` (run-convert's field patch carries only the keys
// that changed), Enter commits instead of breaking. An absent label stays absent
// until the author types one. The surface is outside ProseMirror (the node view
// already stops its events), so it never splits or mutates the run.
export function mountFieldLabel(labelEl, { editor, getPos, onName }) {
  let timer = null;
  // The value control's accessible name is the visible label (WCAG 4.1.2): the
  // label is an editable caption, not a <label for>, so the node view names its
  // control through onName — on paint and on every keystroke in the label.
  const name = () => {
    if (typeof onName === "function") onName((labelEl.textContent || "").replace(/\s+/g, " ").trim());
  };
  const editable = () => !!(editor && editor.isEditable);
  const sync = () => {
    if (editable()) {
      labelEl.setAttribute("contenteditable", "plaintext-only");
      labelEl.setAttribute("role", "textbox");
      labelEl.setAttribute("aria-label", t("Field label"));
      labelEl.setAttribute("aria-multiline", "false");
      labelEl.setAttribute("spellcheck", "false");
      labelEl.tabIndex = 0;
    } else {
      labelEl.removeAttribute("contenteditable");
      labelEl.removeAttribute("role");
    }
  };
  const commit = () => {
    if (timer) { clearTimeout(timer); timer = null; }
    if (!editable() || typeof getPos !== "function") return;
    const pos = getPos();
    if (pos == null) return;
    const cur = editor.state.doc.nodeAt(pos);
    if (!cur) return;
    const text = (labelEl.textContent || "").replace(/\n+/g, " ");
    const prev = cur.attrs.label;
    if ((prev == null ? "" : String(prev)) === text) return;
    const label = prev == null && text === "" ? null : text;
    editor.chain().command(({ tr }) => {
      tr.setNodeMarkup(pos, undefined, { ...cur.attrs, label });
      return true;
    }).run();
  };
  const onInput = () => {
    name();
    if (timer) clearTimeout(timer);
    timer = setTimeout(commit, DEBOUNCE_MS);
  };
  const onKey = (e) => {
    if (e.key === "Enter") { e.preventDefault(); commit(); }
  };
  labelEl.addEventListener("input", onInput);
  labelEl.addEventListener("keydown", onKey);
  labelEl.addEventListener("blur", commit);
  sync();
  return {
    // Paint from attrs unless the author is typing in it (never move their caret).
    paint(n) {
      sync();
      const next = (n.attrs && n.attrs.label) || "";
      if (labelEl.ownerDocument.activeElement !== labelEl && labelEl.textContent !== next) {
        labelEl.textContent = next;
      }
      name();
    },
    flush: commit,
    destroy() {
      if (timer) clearTimeout(timer);
      labelEl.removeEventListener("input", onInput);
      labelEl.removeEventListener("keydown", onKey);
      labelEl.removeEventListener("blur", commit);
    },
  };
}

// Read the canvas-host scope (dataset / scope-prefix / bearer token / picker strings)
// for the pickers.
// The host <bp-paper-canvas> carries data-dataset / data-scope-prefix / data-token
// (stamped by the BarkparkPaperCanvas hook from the run wrapper). The node-view reaches
// it via editor.options.element (the mount .bp-paper-editor-body) → closest(
// "bp-paper-canvas"). All optional — a missing host or missing attr yields "" so the
// picker keeps its own defaults (dataset="production", no token → upload disabled).
export function canvasScope(editor) {
  const empty = {
    dataset: "",
    scopePrefix: "",
    token: "",
    pickerBrowse: true,
    mediaStrings: "",
    referenceStrings: "",
  };
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
      mediaStrings: host.getAttribute("data-media-strings") || "",
      referenceStrings: host.getAttribute("data-reference-strings") || "",
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

    case "field-number": {
      // MIRRORS the per-block number input (paper_editor.ex field-number form):
      // step="any" unless the block sets one; min/max from the block config.
      const inp = document.createElement("input");
      inp.type = "number";
      inp.className = "bp-canvas-field-number";
      if (attrs.min != null) inp.min = String(attrs.min);
      if (attrs.max != null) inp.max = String(attrs.max);
      inp.step = attrs.step != null ? String(attrs.step) : "any";
      inp.value = value == null ? "" : String(value);
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
