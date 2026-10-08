// block-handle.js — the Notion-style block gutter for <bp-paper-canvas>.
//
// Hovering a top-level block reveals a small gutter to its left: a `+` that
// inserts an empty paragraph below and opens the slash menu, and a `⋮⋮` grip
// that (a) drags the block to a new position and (b) on a plain click opens a
// block menu (turn into…, duplicate, move up/down, delete). Every mutation is a
// normal ProseMirror transaction on the canvas editor, so the existing
// runToOps diff turns it into patch/insert/remove/move ops with no new wire
// shapes. The handle is purely additive: read-mode canvases never mount it.
import { Selection, TextSelection, NodeSelection } from "@tiptap/pm/state";

// Six-dot braille cell: reads as a drag grip without letter-spacing tricks.
const GRIP = "⠿";

// Top-level (depth 0) block index whose DOM box contains clientY, else -1.
export function topLevelIndexAtY(editor, clientY) {
  const { view, state } = editor;
  let index = 0;
  let found = -1;
  let nearest = { index: -1, distance: Infinity };
  state.doc.forEach((_node, offset) => {
    const dom = view.nodeDOM(offset);
    if (dom && dom.getBoundingClientRect) {
      const r = dom.getBoundingClientRect();
      if (clientY >= r.top && clientY <= r.bottom) found = index;
      const d = Math.min(Math.abs(clientY - r.top), Math.abs(clientY - r.bottom));
      if (d < nearest.distance) nearest = { index, distance: d };
    }
    index += 1;
  });
  return found !== -1 ? found : nearest.distance < 24 ? nearest.index : -1;
}

export function topLevelIndexAtSelection(editor) {
  const $from = editor.state.selection.$from;
  return $from.depth === 0 ? Math.min($from.index(0), editor.state.doc.childCount - 1) : $from.index(0);
}

function topLevelAt(state, index) {
  if (index < 0 || index >= state.doc.childCount) return null;
  const node = state.doc.child(index);
  let offset = 0;
  for (let i = 0; i < index; i++) offset += state.doc.child(i).nodeSize;
  return { node, from: offset, to: offset + node.nodeSize };
}

function focusInto(editor, tr, pos) {
  try {
    tr.setSelection(TextSelection.near(tr.doc.resolve(pos), 1));
  } catch (_e) {
    try { tr.setSelection(NodeSelection.create(tr.doc, pos)); } catch (_e2) { /* leave selection */ }
  }
  editor.view.dispatch(tr);
  editor.commands.focus();
}

// Move top-level block `from` so it lands at top-level index `to` (index in the
// document AFTER removal, i.e. 0 puts it first, childCount-1 puts it last).
export function moveTopLevel(editor, from, to) {
  const { state } = editor;
  const count = state.doc.childCount;
  if (from < 0 || from >= count) return false;
  const target = Math.max(0, Math.min(to, count - 1));
  if (target === from) return false;
  const src = topLevelAt(state, from);
  let tr = state.tr.delete(src.from, src.to);
  let insertAt = 0;
  for (let i = 0; i < target; i++) insertAt += tr.doc.child(i).nodeSize;
  tr = tr.insert(insertAt, src.node);
  focusInto(editor, tr, insertAt + 1);
  return true;
}

export function duplicateTopLevel(editor, index) {
  const { state } = editor;
  const src = topLevelAt(state, index);
  if (!src) return false;
  // A duplicate must not carry the source block id or the diff would see two of the same block.
  const copy = src.node.type.create({ ...src.node.attrs, bpId: null }, src.node.content, src.node.marks);
  const tr = state.tr.insert(src.to, copy);
  focusInto(editor, tr, src.to + 1);
  return true;
}

export function deleteTopLevel(editor, index) {
  const { state } = editor;
  const src = topLevelAt(state, index);
  if (!src) return false;
  let tr = state.tr.delete(src.from, src.to);
  if (tr.doc.childCount === 0) tr = tr.insert(0, state.schema.nodes.paragraph.create());
  focusInto(editor, tr, Math.min(src.from + 1, tr.doc.content.size - 1));
  return true;
}

export function insertParagraphAfter(editor, index) {
  const { state } = editor;
  const src = topLevelAt(state, index);
  if (!src) return false;
  const tr = state.tr.insert(src.to, state.schema.nodes.paragraph.create());
  focusInto(editor, tr, src.to + 1);
  return true;
}

// "Turn into" for prose blocks. Non-prose targets are handled by the caller through the slash insert path.
export function turnTopLevelInto(editor, index, kind) {
  const { state } = editor;
  const src = topLevelAt(state, index);
  if (!src) return false;
  // Select the block's text from its first to its last inline position. A raw
  // src.from + 1 lands BETWEEN a list and its first item (no inline content
  // there), so "Turn into → Checklist / Numbered list" on a list did nothing; and
  // a list converts as a whole only when the selection spans all its items.
  const first = Selection.findFrom(state.doc.resolve(src.from), 1, true);
  const last = Selection.findFrom(state.doc.resolve(src.to), -1, true);
  const range = first && last && first.from >= src.from && last.to <= src.to
    ? { from: first.from, to: src.node.isTextblock ? first.from : last.to }
    : Math.min(src.from + 1, src.to - 1);
  const chain = editor.chain().setTextSelection(range);
  const LISTS = ["bulletList", "orderedList", "taskList"];
  // A list turned into another list kind is the SAME block: keep its id, so the
  // save is a same-id replace and references to the block survive.
  const keepListId = (ok) => {
    const id = src.node.attrs?.bpId;
    if (!ok || !id || !LISTS.includes(src.node.type.name)) return ok;
    const after = topLevelAt(editor.state, index);
    if (after && LISTS.includes(after.node.type.name) && after.node.attrs.bpId == null &&
        "bpId" in after.node.attrs) {
      const tr = editor.state.tr.setNodeMarkup(after.from, undefined, { ...after.node.attrs, bpId: id });
      editor.view.dispatch(tr.setMeta("addToHistory", false));
    }
    return ok;
  };
  // Paragraph <-> quote (owner ruling 2026-10-03 #62): both hold the same inline
  // content, so the block is swapped in place with its id kept — the save is a
  // same-id replace-block, never a remove + insert that would orphan references.
  const swapTextblock = (typeName) => {
    const type = state.schema.nodes[typeName];
    if (!type || !src.node.isTextblock) return false;
    let node;
    try {
      node = type.create({ bpId: src.node.attrs?.bpId ?? null, bpType: typeName }, src.node.content);
    } catch (_e) {
      return false;
    }
    const tr = state.tr.replaceWith(src.from, src.to, node);
    try { tr.setSelection(TextSelection.near(tr.doc.resolve(src.from + 1))); } catch (_e) { /* keep selection */ }
    editor.view.dispatch(tr);
    return true;
  };
  switch (kind) {
    case "paragraph":
      return src.node.type.name === "blockquote" ? swapTextblock("paragraph") : chain.setParagraph().run();
    case "quote":
      return src.node.type.name === "blockquote" ? true : swapTextblock("blockquote");
    case "h1": return chain.setHeading({ level: 1 }).run();
    case "h2": return chain.setHeading({ level: 2 }).run();
    case "h3": return chain.setHeading({ level: 3 }).run();
    case "h4": return chain.setHeading({ level: 4 }).run();
    case "h5": return chain.setHeading({ level: 5 }).run();
    case "h6": return chain.setHeading({ level: 6 }).run();
    case "bullet": return src.node.type.name === "bulletList" ? true : keepListId(chain.toggleBulletList().run());
    case "ordered": return src.node.type.name === "orderedList" ? true : keepListId(chain.toggleOrderedList().run());
    case "task": return src.node.type.name === "taskList" ? true : keepListId(chain.toggleTaskList().run());
    default: return false;
  }
}

export const TURN_INTO = [
  { kind: "paragraph", label: "Text", glyph: "¶" },
  { kind: "h1", label: "Heading 1", glyph: "H1" },
  { kind: "h2", label: "Heading 2", glyph: "H2" },
  { kind: "h3", label: "Heading 3", glyph: "H3" },
  { kind: "h4", label: "Heading 4", glyph: "H4" },
  { kind: "h5", label: "Heading 5", glyph: "H5" },
  { kind: "h6", label: "Heading 6", glyph: "H6" },
  { kind: "bullet", label: "Bulleted list", glyph: "•" },
  { kind: "ordered", label: "Numbered list", glyph: "1." },
  { kind: "task", label: "Checklist", glyph: "☑" },
  { kind: "quote", label: "Quote", glyph: "❝" },
];

export class BlockHandle {
  // host: the <bp-paper-canvas> element (position: relative via CSS).
  // openSlash(): host callback that opens the slash menu at the caret.
  // canSaveMaster(node) / saveMaster(node): optional paper-masters seam — when
  // canSaveMaster answers true the menu offers "Save as master".
  constructor({ host, editor, openSlash, canSaveMaster, saveMaster }) {
    this._host = host;
    this._editor = editor;
    this._openSlash = openSlash;
    this._canSaveMaster = typeof canSaveMaster === "function" ? canSaveMaster : () => false;
    this._saveMaster = typeof saveMaster === "function" ? saveMaster : () => false;
    this._index = -1;
    this._menu = null;
    this._drag = null;
    this._hideTimer = null;
    this._el = document.createElement("div");
    this._el.className = "bp-block-handle";
    this._el.style.display = "none";
    this._el.innerHTML = `<button type="button" class="bp-block-handle__btn bp-block-handle__add" title="Add a block below (click)" aria-label="Add a block below">+</button><button type="button" class="bp-block-handle__btn bp-block-handle__grip" title="Drag to move · click for options" aria-label="Block options">${GRIP}</button>`;
    this._drop = document.createElement("div");
    this._drop.className = "bp-block-drop";
    this._drop.style.display = "none";
    host.appendChild(this._el);
    host.appendChild(this._drop);

    this._onMove = (e) => this._track(e);
    this._onLeave = () => this._scheduleHide();
    this._onScroll = () => this._reposition();
    this._onDocDown = (e) => { if (this._menu && !this._menu.contains(e.target) && !this._el.contains(e.target)) this._closeMenu(); };
    host.addEventListener("mousemove", this._onMove);
    host.addEventListener("mouseleave", this._onLeave);
    window.addEventListener("scroll", this._onScroll, true);
    document.addEventListener("mousedown", this._onDocDown, true);
    this._el.addEventListener("mouseenter", () => this._cancelHide());
    this._el.addEventListener("mouseleave", () => this._scheduleHide());
    this._el.querySelector(".bp-block-handle__add").addEventListener("mousedown", (e) => e.preventDefault());
    this._el.querySelector(".bp-block-handle__add").addEventListener("click", () => this._add());
    const grip = this._el.querySelector(".bp-block-handle__grip");
    grip.addEventListener("pointerdown", (e) => this._startDrag(e));

    // A touch screen has no hover, so the handle never appeared there and a touch
    // author had no Duplicate / Move / Delete for a block (task-be754bd628311c5f).
    // There it follows the CARET: the block the author is in shows its handle.
    this._touch = typeof window !== "undefined" && typeof window.matchMedia === "function" &&
      window.matchMedia("(hover: none)").matches;
    this._onSelection = () => this._followCaret();
    if (this._touch && editor && typeof editor.on === "function") {
      this._el.classList.add("bp-block-handle--touch");
      editor.on("selectionUpdate", this._onSelection);
      editor.on("focus", this._onSelection);
    }
  }

  _followCaret() {
    if (this._drag || this._menu || !this._editor || this._editor.isDestroyed) return;
    const index = topLevelIndexAtSelection(this._editor);
    if (index === -1) { this.hide(); return; }
    this._index = index;
    this._reposition();
  }

  destroy() {
    this._closeMenu();
    if (this._touch && this._editor && typeof this._editor.off === "function") {
      this._editor.off("selectionUpdate", this._onSelection);
      this._editor.off("focus", this._onSelection);
    }
    this._host.removeEventListener("mousemove", this._onMove);
    this._host.removeEventListener("mouseleave", this._onLeave);
    window.removeEventListener("scroll", this._onScroll, true);
    document.removeEventListener("mousedown", this._onDocDown, true);
    this._el.remove();
    this._drop.remove();
  }

  hide() { this._el.style.display = "none"; this._index = -1; }

  _cancelHide() { if (this._hideTimer) { clearTimeout(this._hideTimer); this._hideTimer = null; } }
  _scheduleHide() {
    this._cancelHide();
    this._hideTimer = setTimeout(() => { if (!this._menu && !this._drag) this.hide(); }, 250);
  }

  _track(e) {
    if (this._drag || this._menu) return;
    if (!this._editor || this._editor.isDestroyed) return;
    const index = topLevelIndexAtY(this._editor, e.clientY);
    if (index === -1) { this._scheduleHide(); return; }
    this._cancelHide();
    this._index = index;
    this._reposition();
  }

  _reposition() {
    if (this._index < 0 || !this._editor || this._editor.isDestroyed) return;
    const { view, state } = this._editor;
    const block = topLevelAt(state, this._index);
    if (!block) { this.hide(); return; }
    const dom = view.nodeDOM(block.from);
    if (!dom || !dom.getBoundingClientRect) { this.hide(); return; }
    const r = dom.getBoundingClientRect();
    const h = this._host.getBoundingClientRect();
    const line = Math.min(parseFloat(getComputedStyle(dom).lineHeight) || 24, r.height);
    // The gutter sits LEFT of the block's text, never over it: a handle clamped onto
    // the text start would take the click aimed at a block's first word. Where no
    // gutter exists (the block starts within 52px of the viewport edge — a phone),
    // there is no handle; the slash menu and the keyboard still add blocks.
    // On a touch screen with no gutter the handle sits at the block's top-right
    // corner instead, with 44px targets (CSS: .bp-block-handle--touch).
    if (r.left - 52 < 0) {
      if (!this._touch) { this.hide(); return; }
      this._el.style.display = "flex";
      this._el.style.top = `${r.top - h.top + this._host.scrollTop}px`;
      this._el.style.left = `${Math.max(0, r.right - h.left - 92)}px`;
      return;
    }
    this._el.style.display = "flex";
    this._el.style.top = `${r.top - h.top + this._host.scrollTop + Math.max(0, (line - 22) / 2)}px`;
    this._el.style.left = `${r.left - h.left - 52}px`;
  }

  _add() {
    const index = this._index;
    if (index < 0) return;
    insertParagraphAfter(this._editor, index);
    if (typeof this._openSlash === "function") this._openSlash();
  }

  // ── drag to move ───────────────────────────────────────────────────────────
  _startDrag(e) {
    if (e.button !== 0 || this._index < 0) return;
    e.preventDefault();
    const grip = e.currentTarget;
    const startY = e.clientY;
    const source = this._index;
    let moved = false;
    let target = null;
    const onMove = (ev) => {
      if (!moved && Math.abs(ev.clientY - startY) < 4) return;
      moved = true;
      this._drag = { source };
      this._el.classList.add("bp-block-handle--dragging");
      target = this._dropTargetAt(ev.clientY);
      this._showDrop(target);
    };
    const onUp = () => {
      grip.releasePointerCapture?.(e.pointerId);
      grip.removeEventListener("pointermove", onMove);
      grip.removeEventListener("pointerup", onUp);
      grip.removeEventListener("pointercancel", onUp);
      this._drop.style.display = "none";
      this._el.classList.remove("bp-block-handle--dragging");
      if (!moved) { this._drag = null; this._openMenu(); return; }
      this._drag = null;
      if (target && target.index !== source) {
        // target.index is the boundary index in the ORIGINAL doc; after removal, boundaries above the source shift down by one.
        const to = target.index > source ? target.index - 1 : target.index;
        moveTopLevel(this._editor, source, to);
        this._index = to;
        this._reposition();
      }
    };
    grip.setPointerCapture?.(e.pointerId);
    grip.addEventListener("pointermove", onMove);
    grip.addEventListener("pointerup", onUp);
    grip.addEventListener("pointercancel", onUp);
  }

  // Boundary index (0..childCount) nearest to clientY: dropping at boundary i puts the block before child i.
  _dropTargetAt(clientY) {
    const { view, state } = this._editor;
    let best = { index: 0, y: -Infinity, distance: Infinity };
    let offset = 0;
    const count = state.doc.childCount;
    for (let i = 0; i < count; i++) {
      const dom = view.nodeDOM(offset);
      const r = dom && dom.getBoundingClientRect ? dom.getBoundingClientRect() : null;
      if (r) {
        const dTop = Math.abs(clientY - r.top);
        if (dTop < best.distance) best = { index: i, y: r.top, distance: dTop };
        const dBottom = Math.abs(clientY - r.bottom);
        if (dBottom < best.distance) best = { index: i + 1, y: r.bottom, distance: dBottom };
      }
      offset += state.doc.child(i).nodeSize;
    }
    return best;
  }

  _showDrop(target) {
    if (!target) { this._drop.style.display = "none"; return; }
    const h = this._host.getBoundingClientRect();
    const body = this._editor.view.dom.getBoundingClientRect();
    this._drop.style.display = "block";
    this._drop.style.top = `${target.y - h.top + this._host.scrollTop - 1}px`;
    this._drop.style.left = `${body.left - h.left}px`;
    this._drop.style.width = `${body.width}px`;
  }

  // ── block menu ─────────────────────────────────────────────────────────────
  _openMenu() {
    this._closeMenu();
    const index = this._index;
    if (index < 0) return;
    const menu = document.createElement("div");
    menu.className = "bp-block-menu";
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-label", "Block options");
    const node = this._editor.state.doc.child(index);
    const prose = ["paragraph", "heading", "bulletList", "orderedList"].includes(node.type.name);
    // A role=menu owns menuitems, grouped (axe aria-required-children): each
    // visible heading names its role=group, and the heading itself is hidden
    // from the tree so it is not read twice.
    const item = (label, glyph, action, extra = "") => `<button type="button" role="menuitem" class="bp-block-menu__item ${extra}" data-action="${action}"><span class="bp-block-menu__glyph" aria-hidden="true">${glyph}</span>${label}</button>`;
    const group = (title, items) => `<div role="group" aria-label="${title}"><div class="bp-block-menu__group" aria-hidden="true">${title}</div>${items.join("")}</div>`;
    menu.innerHTML = [
      prose ? group("Turn into", TURN_INTO.map((t) => item(t.label, t.glyph, "turn:" + t.kind))) : "",
      group("Block", [
        item("Duplicate", "⧉", "duplicate"),
        item("Move up", "↑", "up"),
        item("Move down", "↓", "down"),
        this._canSaveMaster(node) ? item("Save as master", "★", "save-master") : "",
        item("Delete", "✕", "delete", "bp-block-menu__item--danger"),
      ]),
    ].join("");
    menu.addEventListener("mousedown", (e) => e.preventDefault());
    menu.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      this._runAction(btn.dataset.action, index);
      this._closeMenu();
    });
    menu.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.preventDefault(); this._closeMenu(); this._editor.commands.focus(); } });
    this._host.appendChild(menu);
    const h = this._host.getBoundingClientRect();
    const r = this._el.getBoundingClientRect();
    menu.style.top = `${r.bottom - h.top + this._host.scrollTop + 4}px`;
    menu.style.left = `${r.left - h.left}px`;
    this._menu = menu;
    const first = menu.querySelector("[data-action]");
    if (first) first.focus();
  }

  _closeMenu() {
    if (this._menu) { this._menu.remove(); this._menu = null; }
  }

  _runAction(action, index) {
    if (action.startsWith("turn:")) { turnTopLevelInto(this._editor, index, action.slice(5)); return; }
    if (action === "save-master") {
      const node = index >= 0 && index < this._editor.state.doc.childCount
        ? this._editor.state.doc.child(index)
        : null;
      if (node) this._saveMaster(node);
    } else if (action === "duplicate") duplicateTopLevel(this._editor, index);
    else if (action === "up") moveTopLevel(this._editor, index, index - 1);
    else if (action === "down") moveTopLevel(this._editor, index, index + 1);
    else if (action === "delete") deleteTopLevel(this._editor, index);
    this._index = -1;
    this.hide();
  }
}
