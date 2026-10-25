// card-menu.js — the "…" of a block card (contract `block-cards`), as Sanity's block
// object preview: a 25 px button whose menu offers Edit and Remove. Shared by the image
// card (image-node.js) and a declared object block's card (opaque-node.js).
//
// The menu is a BODY PORTAL, like the block handle's: the canvas host scrolls and clips
// (overflow:auto), so a menu inside it would be cut off. Out of the host it loses the
// surface-scoped --paper-* tokens, so the ones it paints with are copied onto it.

import { Extension } from "@tiptap/core";
import { NodeSelection, Plugin, Selection, TextSelection } from "@tiptap/pm/state";
import { t } from "../i18n.js";

// Sanity's EllipsisHorizontalIcon (21 px in a 25 px button), EditIcon and TrashIcon.
const ICON = (d) => `<svg width="21" height="21" viewBox="0 0 25 25" fill="none" aria-hidden="true">${d}</svg>`;
export const MORE = ICON('<path d="M6.5 11C7.32843 11 8 11.6716 8 12.5C8 13.3284 7.32843 14 6.5 14C5.67157 14 5 13.3284 5 12.5C5 11.6716 5.67157 11 6.5 11Z" fill="currentColor"/><path d="M12.5 11C13.3284 11 14 11.6716 14 12.5C14 13.3284 13.3284 14 12.5 14C11.6716 14 11 13.3284 11 12.5C11 11.6716 11.6716 11 12.5 11Z" fill="currentColor"/><path d="M18.5 11C19.3284 11 20 11.6716 20 12.5C20 13.3284 19.3284 14 18.5 14C17.6716 14 17 13.3284 17 12.5C17 11.6716 17.6716 11 18.5 11Z" fill="currentColor"/>');
export const EDIT = ICON('<path d="M15 7L18 10M6 19L7 15L17 5L20 8L10 18L6 19Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>');
export const TRASH = ICON('<path d="M5 6.5H20M10 6.5V4.5C10 3.94772 10.4477 3.5 11 3.5H14C14.5523 3.5 15 3.94772 15 4.5V6.5M12.5 9V17M15.5 9L15 17M9.5 9L10 17M18.5 6.5L17.571 18.5767C17.5309 19.0977 17.0965 19.5 16.574 19.5H8.42603C7.90349 19.5 7.46905 19.0977 7.42898 18.5767L6.5 6.5H18.5Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>');

const TOKENS = ["--paper-chrome-bg", "--paper-chrome-border", "--paper-ink", "--paper-ink-soft", "--paper-rule", "--paper-edit-hover", "--bp-tone-danger-fg", "--paper-font-sans"];

/** The card's "…": Sanity's label for it, never "Block options" (the block handle's). */
export function cardMoreButton(className) {
  const more = document.createElement("button");
  more.type = "button";
  more.className = className;
  more.innerHTML = MORE;
  more.setAttribute("aria-label", t("Open menu"));
  more.setAttribute("aria-haspopup", "menu");
  more.setAttribute("aria-expanded", "false");
  more.setAttribute("contenteditable", "false");
  more.addEventListener("mousedown", (e) => e.preventDefault());
  return more;
}

/**
 * Wire `more` to its menu. `items()` answers the actions at open time, a list of
 * "edit" | "remove"; `onPick(action)` runs one; `top()` is the menu's top in viewport px;
 * `enabled()` gates opening (an editable canvas). Answers `close` for the node view's destroy.
 */
export function wireCardMenu(more, { dom, menuClass, items, onPick, top, enabled }) {
  let menu = null;
  const onDocDown = (e) => {
    if (menu && !menu.contains(e.target) && !more.contains(e.target)) close(false);
  };
  const close = (refocus) => {
    if (!menu) return;
    menu.remove();
    menu = null;
    more.setAttribute("aria-expanded", "false");
    document.removeEventListener("mousedown", onDocDown, true);
    if (refocus) more.focus();
  };
  const open = () => {
    if (menu) return close(true);
    const actions = enabled() ? items() : [];
    if (!actions.length) return;
    menu = document.createElement("div");
    menu.className = `bp-block-menu bp-canvas-card-menu ${menuClass || ""}`.trim();
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-label", t("Block options"));
    for (const action of actions) {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.className = "bp-block-menu__item" + (action === "remove" ? " bp-block-menu__item--danger" : "");
      b.dataset.action = action;
      b.innerHTML = action === "remove" ? TRASH : EDIT;
      b.append(t(action === "remove" ? "Remove" : "Edit"));
      menu.appendChild(b);
    }
    const host = dom.closest("bp-paper-canvas");
    if (host) for (const v of TOKENS) {
      const value = getComputedStyle(host).getPropertyValue(v);
      if (value) menu.style.setProperty(v, value.trim());
    }
    menu.addEventListener("mousedown", (e) => e.preventDefault());
    menu.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const action = btn.dataset.action;
      close(false);
      onPick(action);
    });
    menu.addEventListener("keydown", (e) => {
      const list = [...menu.querySelectorAll("[role=menuitem]")];
      const at = list.indexOf(document.activeElement);
      if (e.key === "Escape" || e.key === "Tab") { e.preventDefault(); close(true); }
      else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        list[(at + (e.key === "ArrowDown" ? 1 : list.length - 1)) % list.length].focus();
      }
    });
    document.body.appendChild(menu);
    const r = more.getBoundingClientRect();
    const m = menu.getBoundingClientRect();
    const vw = window.innerWidth || document.documentElement.clientWidth || 0;
    menu.style.position = "fixed";
    // Centred under the "…", as Sanity's.
    menu.style.left = `${Math.max(8, Math.min(r.left + r.width / 2 - m.width / 2, vw - 8 - m.width))}px`;
    menu.style.top = `${top(r)}px`;
    more.setAttribute("aria-expanded", "true");
    document.addEventListener("mousedown", onDocDown, true);
    menu.querySelector("[role=menuitem]").focus();
  };
  more.addEventListener("click", (e) => {
    e.preventDefault();
    open();
  });
  return close;
}

const CARDS = new Set(["bpImage", "bpOpaque"]);
const isCard = (node) => !!node && CARDS.has(node.type.name);
const onCardsCanvas = (view) => !!(view.dom.closest && view.dom.closest("bp-paper-canvas[block-cards]"));
// A top-level card the selection holds: { node, pos, index } or null.
function selectedCard(state) {
  const sel = state.selection;
  if (!(sel instanceof NodeSelection) || sel.$from.depth !== 0 || !isCard(sel.node)) return null;
  return { node: sel.node, pos: sel.from, index: sel.$from.index(0) };
}

// The keys of a selected card on a canvas with `block-cards` (contract 1.11.0), as Sanity's
// Portable Text editor treats a selected block object:
//   * a typed character never replaces it (the whole block gone for one key);
//   * ArrowDown/Right and ArrowUp/Left reach an adjacent card directly, with no extra stop
//     (ProseMirror's gap cursor) between two cards;
//   * Enter opens a new paragraph after it, the caret in it (Sanity's: no dialog; the
//     card's "…" Edit and a double-click still edit it);
//   * Delete / Backspace remove it and leave the caret at the end of the text before.
// A canvas without the attribute keeps ProseMirror's and the canvas's own keys (Enter
// edits an object block there).
export function keepSelectedCard() {
  return new Plugin({
    props: {
      handleTextInput(view) {
        return !!selectedCard(view.state) && onCardsCanvas(view);
      },
      handleKeyDown(view, event) {
        if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || !onCardsCanvas(view)) return false;
        const card = selectedCard(view.state);
        if (!card) return false;
        const { state } = view;
        const doc = state.doc;
        const forward = event.key === "ArrowDown" || event.key === "ArrowRight";
        const back = event.key === "ArrowUp" || event.key === "ArrowLeft";
        if (forward || back) {
          const at = card.index + (forward ? 1 : -1);
          if (at < 0 || at >= doc.childCount || !isCard(doc.child(at))) return false;
          let pos = 0;
          for (let i = 0; i < at; i++) pos += doc.child(i).nodeSize;
          view.dispatch(state.tr.setSelection(NodeSelection.create(doc, pos)).scrollIntoView());
          return true;
        }
        if (event.key === "Enter") {
          const paragraph = state.schema.nodes.paragraph;
          if (!paragraph) return false;
          const after = card.pos + card.node.nodeSize;
          const tr = state.tr.insert(after, paragraph.create());
          tr.setSelection(TextSelection.create(tr.doc, after + 1)).scrollIntoView();
          view.dispatch(tr);
          return true;
        }
        if (event.key === "Delete" || event.key === "Backspace") {
          const tr = state.tr.delete(card.pos, card.pos + card.node.nodeSize);
          const $at = tr.doc.resolve(Math.min(card.pos, tr.doc.content.size));
          tr.setSelection(Selection.near($at, -1)).scrollIntoView();
          view.dispatch(tr);
          return true;
        }
        return false;
      },
    },
  });
}

// Ahead of every other key handler (the inline objects' Enter-to-edit runs at 1000), so a
// selected card's keys are decided here first on a block-cards canvas.
export const CardKeys = Extension.create({
  name: "bpCardKeys",
  priority: 1100,
  addProseMirrorPlugins() {
    return [keepSelectedCard()];
  },
});
