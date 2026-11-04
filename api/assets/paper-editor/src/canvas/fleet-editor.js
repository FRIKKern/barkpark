// fleet-editor.js — the native Fleet edit-island DOM.

import { DEBOUNCE_MS } from "../contract.js";
import {
  FLEET_ITEM_EDITORS,
  FLEET_CONFIG_EDITORS,
  datumEditorSpec,
  datumEditorRows,
  datumEditorSet,
  datumEditorMove,
  fleetEditorText,
  fleetEditorParse,
} from "./fleet-model.js";

// Build the fleet edit island DOM for a block. Returns { el, refresh, destroy }.
//   onEdit(nextBlock) — called (debounced) with a fresh mutated block clone; the
//     node-view writes it to attrs.bpBlock via setNodeMarkup, which the diff turns
//     into ONE patch-block{items|nodes|query} → server repaint.
//   isEditable() — gates the control (view mode leaves it read-only + hidden).
//
// ── ONE <textarea> island, NO buttons (rule 6 / __atom_chrome guard) ──────────
//
// The whole authored payload rides a SINGLE non-PM <textarea> — the exact code-node
// island shape (stopEvent/ignoreMutation come from the node-view, so PM never sees a
// keystroke). Editing text IS add / remove / reorder / edit: a new line adds an item,
// a deleted line removes one, moving lines reorders, typing edits — no edit-only
// <button> chrome. On `input` (debounced) the text is PARSED back to the block; a
// parse that fails (a half-typed JSON) simply doesn't commit, so the last valid state
// stands. Item kinds (cards/pipeline) edit the array as pretty JSON; notes edit as
// newline-separated lines; task-* kinds edit `query.label` + `query.id` as one small
// JSON object. The DOM is built lazily inside the node-view factory (references
// `document`), so this is never called in the pure-Node harness.
// Build the STRUCTURED per-datum grid DOM for a duel/lineage block. Returns
// { el, refresh, flush, destroy } — the same shape the JSON island returns — or
// null when the kind carries no datum array. Every control is a native <input> or
// <select>: NO <button> (rule 6 / __atom_chrome guard, which reads this file).
//
// The grid renders rows.length + 1 rows. The trailing one is the ADD scaffold: its
// fields are empty and typing into any of them appends a datum. An existing datum
// whose fields are all cleared drops out. A <select> per existing datum holds the
// positions 1…N; picking one reorders. All four operations funnel through the two
// PURE entry points (datumEditorSet / datumEditorMove) the unit tests drive, so the
// DOM here carries no editing rules of its own.
//
// Lives inside the DOM-building half of the module (references `document`), so it is
// never reached by the pure-Node harness.
function buildDatumGrid(initialBlock, { onEdit, isEditable }) {
  const type = (initialBlock && initialBlock.type) || "";
  const spec = datumEditorSpec(type);
  if (!spec) return null;
  let currentBlock = initialBlock || { type };

  const el = document.createElement("div");
  el.className = "bp-fleet-datum";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("data-test-id", `paper-fleet-datum-${type}`);
  el.style.display = "grid";
  el.style.gap = "0.35rem";
  el.style.marginBottom = "0.5rem";

  const hint = document.createElement("div");
  hint.style.opacity = "0.65";
  hint.textContent =
    `Edit each ${spec.itemNoun} — type in the empty ${spec.itemNoun} to add one, ` +
    `clear every field to remove it, pick a position to reorder. ` +
    `Kilde overrides the block's default source for that ${spec.itemNoun}.`;
  el.appendChild(hint);

  const list = document.createElement("div");
  list.style.display = "grid";
  list.style.gap = "0.35rem";
  el.appendChild(list);

  let timer = null;
  let pendingCommit = null;

  // Optimistic local advance: each commit recomputes from the block the LAST commit
  // produced, never from a stale echo, so two quick edits in two fields both land.
  const applyEdit = (next) => {
    if (next == null) return false;
    currentBlock = next;
    onEdit(next);
    return true;
  };

  const flushPending = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    if (!pendingCommit) return false;
    const run = pendingCommit;
    pendingCommit = null;
    return run();
  };

  const focusKey = () => {
    const a = document.activeElement;
    if (!a || !el.contains(a)) return null;
    const idx = a.getAttribute && a.getAttribute("data-bp-datum-index");
    const key = a.getAttribute && a.getAttribute("data-bp-datum-field");
    return idx == null || key == null ? null : { idx, key };
  };

  const restoreFocus = (want) => {
    if (!want) return;
    const input = list.querySelector(
      `input[data-bp-datum-index="${want.idx}"][data-bp-datum-field="${want.key}"]`,
    );
    if (!input) return;
    try {
      input.focus();
      const end = input.value.length;
      input.setSelectionRange(end, end);
    } catch (_) {
      /* a detached/unsupported input must never throw out of a repaint */
    }
  };

  const onFieldInput = (e) => {
    if (!isEditable()) return;
    const input = e.target;
    const index = Number(input.getAttribute("data-bp-datum-index"));
    const key = input.getAttribute("data-bp-datum-field");
    const value = input.value;
    if (timer) clearTimeout(timer);
    pendingCommit = () => {
      const before = datumEditorRows(currentBlock);
      const next = datumEditorSet(currentBlock, index, key, value);
      if (!applyEdit(next)) return false;
      const after = datumEditorRows(currentBlock);
      // A structural change (append / remove) changes the row count, so the grid
      // must be rebuilt; a plain field edit leaves the DOM alone (and the caret).
      if (!before || !after || before.length !== after.length) {
        const want = focusKey();
        paint(currentBlock, true);
        restoreFocus(want);
      }
      return true;
    };
    timer = setTimeout(() => {
      timer = null;
      const run = pendingCommit;
      pendingCommit = null;
      if (run) run();
    }, DEBOUNCE_MS);
  };

  const onPositionChange = (e) => {
    if (!isEditable()) return;
    flushPending();
    const select = e.target;
    const from = Number(select.getAttribute("data-bp-datum-index"));
    const to = Number(select.value);
    const next = datumEditorMove(currentBlock, from, to);
    if (!applyEdit(next)) {
      paint(currentBlock, true);
      return;
    }
    paint(currentBlock, true);
  };

  const buildRow = (datum, index, count) => {
    const row = document.createElement("div");
    row.className = "bp-fleet-datum-row";
    row.setAttribute("data-bp-datum-index", String(index));
    if (index === count) row.setAttribute("data-bp-datum-scaffold", "true");
    row.style.display = "flex";
    row.style.flexWrap = "wrap";
    row.style.gap = "0.25rem";
    row.style.alignItems = "center";

    if (index < count) {
      const pos = document.createElement("select");
      pos.className = "bp-fleet-datum-pos";
      pos.setAttribute("data-bp-datum-index", String(index));
      pos.setAttribute(
        "aria-label",
        `position of ${spec.itemNoun} ${index + 1} of ${count}`,
      );
      for (let i = 0; i < count; i++) {
        const opt = document.createElement("option");
        opt.value = String(i);
        opt.textContent = String(i + 1);
        if (i === index) opt.selected = true;
        pos.appendChild(opt);
      }
      pos.addEventListener("change", onPositionChange);
      row.appendChild(pos);
    } else {
      const badge = document.createElement("span");
      badge.className = "bp-fleet-datum-new";
      badge.setAttribute("aria-hidden", "true");
      badge.textContent = "+";
      badge.style.opacity = "0.5";
      row.appendChild(badge);
    }

    for (const field of spec.fields) {
      const label = document.createElement("label");
      label.style.display = "inline-flex";
      label.style.flexDirection = "column";
      label.style.flex = "1 1 6rem";
      label.style.minWidth = "5rem";
      const cap = document.createElement("span");
      cap.textContent = field.label;
      cap.style.opacity = "0.6";
      cap.style.fontSize = "0.75em";
      const input = document.createElement("input");
      input.type = "text";
      input.className = "bp-fleet-datum-field";
      input.setAttribute("data-bp-datum-index", String(index));
      input.setAttribute("data-bp-datum-field", field.key);
      input.setAttribute("spellcheck", "false");
      input.setAttribute(
        "aria-label",
        index === count
          ? `${field.label} of a new ${spec.itemNoun}`
          : `${field.label} of ${spec.itemNoun} ${index + 1}`,
      );
      const v = datum ? datum[field.key] : "";
      input.value = v === undefined || v === null ? "" : String(v);
      input.readOnly = !isEditable();
      input.style.width = "100%";
      input.addEventListener("input", onFieldInput);
      label.appendChild(cap);
      label.appendChild(input);
      row.appendChild(label);
    }
    return row;
  };

  // Repaint. `force` rebuilds the rows outright (a structural change); otherwise the
  // existing inputs are re-seeded in place, skipping whichever one has focus so an
  // echo can never clobber the field the author is typing in. An unrepresentable
  // array (datumEditorRows → null) hides the grid entirely and leaves the payload to
  // the JSON island rather than showing a lossy view of it.
  function paint(block, force) {
    currentBlock = block || { type };
    const rows = datumEditorRows(currentBlock);
    if (rows === null) {
      el.style.display = "none";
      return;
    }
    el.style.display = "grid";
    const count = rows.length;
    const needRebuild = force || list.children.length !== count + 1;
    if (needRebuild) {
      while (list.firstChild) list.removeChild(list.firstChild);
      for (let i = 0; i < count; i++) list.appendChild(buildRow(rows[i], i, count));
      list.appendChild(buildRow(null, count, count));
      return;
    }
    for (const input of list.querySelectorAll("input[data-bp-datum-field]")) {
      if (document.activeElement === input) continue;
      const i = Number(input.getAttribute("data-bp-datum-index"));
      const key = input.getAttribute("data-bp-datum-field");
      const v = i < count && rows[i] ? rows[i][key] : "";
      const text = v === undefined || v === null ? "" : String(v);
      if (input.value !== text) input.value = text;
      input.readOnly = !isEditable();
    }
  }

  paint(initialBlock || { type }, true);

  return {
    el,
    refresh: (block) => {
      // Never repaint out from under an in-progress edit (the JSON island's own
      // activeElement guard, widened to the whole grid).
      if (el.contains(document.activeElement)) {
        currentBlock = block || currentBlock;
        return;
      }
      paint(block || {}, true);
    },
    flush: () => {
      flushPending();
    },
    destroy: () => {
      if (timer) clearTimeout(timer);
      timer = null;
      pendingCommit = null;
    },
  };
}

export function buildFleetEditor(initialBlock, { onEdit, isEditable }) {
  let currentBlock = initialBlock;
  const type = (initialBlock && initialBlock.type) || "";
  const itemEditor = FLEET_ITEM_EDITORS[type];
  const configEditor = FLEET_CONFIG_EDITORS[type];
  const el = document.createElement("div");
  el.className = "bp-fleet-edit";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("data-test-id", `paper-fleet-editor-${type}`);
  el.style.marginTop = "0.5rem";
  el.style.paddingTop = "0.5rem";
  el.style.borderTop = "1px dashed currentColor";
  el.style.fontSize = "0.85rem";

  // The STRUCTURED per-datum grid rides ABOVE the JSON island for the kinds that
  // carry an authored datum array (duel rows / lineage stops). The two never write
  // the same key: the array is not an enumerated config key, so the JSON island
  // leaves it alone and only the grid moves it.
  const datumGrid = buildDatumGrid(initialBlock || { type }, { onEdit, isEditable });
  if (datumGrid) el.appendChild(datumGrid.el);

  const hint = document.createElement("div");
  hint.style.opacity = "0.65";
  hint.style.marginBottom = "0.25rem";
  hint.textContent = itemEditor
    ? "Edit items as JSON — add / remove / reorder rows"
    : configEditor
      ? `Edit config as JSON — keys: ${configEditor.keys.join(", ")}`
      : "Edit query — filter label + task id";
  el.appendChild(hint);

  const area = document.createElement("textarea");
  area.className = "bp-fleet-edit-area";
  area.setAttribute("spellcheck", "false");
  area.setAttribute("aria-label", `edit ${type} content`);
  area.rows = 6;
  area.style.width = "100%";
  area.style.fontFamily = "var(--paper-font-mono, monospace)";
  el.appendChild(area);

  // Serialize / parse delegate to the module-level PURE pair (fleetEditorText /
  // fleetEditorParse — exported so __dataviz.test.mjs exercises the exact island
  // logic in pure Node). A block echoed on refresh keeps its type, so the
  // per-kind branch never shifts mid-life.
  function toText(block) {
    return fleetEditorText({ type, ...(block || {}) });
  }

  function toBlock(text) {
    return fleetEditorParse(currentBlock || { type }, text);
  }

  let textTimer = null;
  const commitText = (text = area.value) => {
    const next = toBlock(text);
    if (next != null) onEdit(next);
  };
  const onInput = () => {
    if (!isEditable()) return;
    if (textTimer) clearTimeout(textTimer);
    const text = area.value;
    textTimer = setTimeout(() => {
      textTimer = null;
      commitText(text);
    }, DEBOUNCE_MS);
  };
  area.addEventListener("input", onInput);

  const paint = (block) => {
    currentBlock = block;
    area.readOnly = !isEditable();
    // Never clobber the field while the user is actively typing in it.
    if (document.activeElement !== area) {
      const text = toText(block || {});
      if (area.value !== text) area.value = text;
    }
  };
  paint(initialBlock || {});

  return {
    el,
    // Re-seed from an echo / undo. Skips while the textarea is focused (mid-edit) via
    // the paint() activeElement guard; `focusInside` is accepted for symmetry with the
    // other islands but paint() already protects the active field.
    refresh: (block) => {
      paint(block || {});
      if (datumGrid) datumGrid.refresh(block || {});
    },
    flush: () => {
      if (datumGrid) datumGrid.flush();
      if (!textTimer) return;
      clearTimeout(textTimer);
      textTimer = null;
      commitText();
    },
    destroy: () => {
      if (datumGrid) datumGrid.destroy();
      if (textTimer) clearTimeout(textTimer);
      area.removeEventListener("input", onInput);
    },
  };
}
