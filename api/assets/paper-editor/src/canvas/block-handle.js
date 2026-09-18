// block-handle.js — the Notion-style block gutter for <bp-paper-canvas>.
//
// Hovering a top-level block reveals a small gutter to its left: a `+` that
// inserts an empty paragraph below and opens the slash menu, and a `⋮⋮` grip
// that (a) drags the block to a new position and (b) on a plain click opens a
// block menu (turn into…, duplicate, move up/down, delete). Every mutation is a
// normal ProseMirror transaction on the canvas editor, so the existing
// runToOps diff turns it into patch/insert/remove/move ops with no new wire
// shapes. The handle is purely additive: read-mode canvases never mount it.
import { TextSelection, NodeSelection } from "@tiptap/pm/state";

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
  const chain = editor.chain().setTextSelection(Math.min(src.from + 1, src.to - 1));
  switch (kind) {
    case "paragraph": return chain.setParagraph().run();
    case "h1": return chain.setHeading({ level: 1 }).run();
    case "h2": return chain.setHeading({ level: 2 }).run();
    case "h3": return chain.setHeading({ level: 3 }).run();
    case "bullet": return src.node.type.name === "bulletList" ? true : chain.toggleBulletList().run();
    case "ordered": return src.node.type.name === "orderedList" ? true : chain.toggleOrderedList().run();
    case "task": return src.node.type.name === "taskList" ? true : chain.toggleTaskList().run();
    default: return false;
  }
}

export const TURN_INTO = [
  { kind: "paragraph", label: "Text", glyph: "¶" },
  { kind: "h1", label: "Heading 1", glyph: "H1" },
  { kind: "h2", label: "Heading 2", glyph: "H2" },
  { kind: "h3", label: "Heading 3", glyph: "H3" },
  { kind: "bullet", label: "Bulleted list", glyph: "•" },
  { kind: "ordered", label: "Numbered list", glyph: "1." },
  { kind: "task", label: "Checklist", glyph: "☑" },
];

export class BlockHandle {
  // host: the <bp-paper-canvas> element (position: relative via CSS).
  // openSlash(): host callback that opens the slash menu at the caret.
  constructor({ host, editor, openSlash }) {
    this._host = host;
    this._editor = editor;
    this._openSlash = openSlash;
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
  }

  destroy() {
    this._closeMenu();
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
    this._el.style.display = "flex";
    this._el.style.top = `${r.top - h.top + this._host.scrollTop + Math.max(0, (line - 22) / 2)}px`;
    this._el.style.left = `${Math.max(0, r.left - h.left - 52)}px`;
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
    const node = this._editor.state.doc.child(index);
    const prose = ["paragraph", "heading", "bulletList", "orderedList"].includes(node.type.name);
    const item = (label, glyph, action, extra = "") => `<button type="button" class="bp-block-menu__item ${extra}" data-action="${action}"><span class="bp-block-menu__glyph">${glyph}</span>${label}</button>`;
    menu.innerHTML = [
      prose ? `<div class="bp-block-menu__group">Turn into</div>${TURN_INTO.map((t) => item(t.label, t.glyph, "turn:" + t.kind)).join("")}` : "",
      `<div class="bp-block-menu__group">Block</div>`,
      item("Duplicate", "⧉", "duplicate"),
      item("Move up", "↑", "up"),
      item("Move down", "↓", "down"),
      item("Delete", "✕", "delete", "bp-block-menu__item--danger"),
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
    if (action === "duplicate") duplicateTopLevel(this._editor, index);
    else if (action === "up") moveTopLevel(this._editor, index, index - 1);
    else if (action === "down") moveTopLevel(this._editor, index, index + 1);
    else if (action === "delete") deleteTopLevel(this._editor, index);
    this._index = -1;
    this.hide();
  }
}
