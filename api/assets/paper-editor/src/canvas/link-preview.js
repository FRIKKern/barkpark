// link-preview.js — the hover card on a link or a wikilink in the canvas (Barkdown plan #23).
//
// Resting the pointer on `<a href>` (the link mark) or `<span data-wikilink>` (the wikilink mark)
// for a moment shows a small card under it: the address, and for a wikilink whatever the host
// resolves for the target (its title and first line — the canvas has no store, so the host injects
// `linkPreviewSource`), plus Open and, in edit mode, Edit. Open hands the link to the host through a
// cancelable `bp-canvas-open-link` event and falls back to a new window for a plain link; Edit
// selects the whole mark and, for a link, opens the format bubble's link row seeded with the href.
//
// Same shape as FormatBubble: one fixed-position element appended to <body>, fully torn down by
// destroy(). Nothing here writes to the document; the card only reads the DOM and the doc marks.

const CLASS = "bp-link-preview";

export class LinkPreview {
  constructor({ editor, host, editable, resolve, onOpen, onEdit, delay = 350, hideDelay = 220 }) {
    this._editor = editor;
    this._host = host;
    this._editable = typeof editable === "function" ? editable : () => !!editable;
    this._resolve = resolve || (() => null);
    this._onOpen = onOpen || (() => {});
    this._onEdit = onEdit || (() => {});
    this._delay = delay;
    this._hideDelay = hideDelay;
    this._el = null;
    this._anchor = null; // the hovered <a> / <span data-wikilink>
    this._info = null; // describe(anchor)
    this._showTimer = null;
    this._hideTimer = null;
    this._ticket = 0; // guards a late resolve against a card that moved on
    this._onOver = (e) => this._handleOver(e);
    this._onOut = (e) => this._handleOut(e);
    this._onKey = () => this.hide();
    this._onScroll = () => this.hide();
    const dom = editor && editor.view && editor.view.dom;
    if (dom) {
      dom.addEventListener("mouseover", this._onOver);
      dom.addEventListener("mouseout", this._onOut);
      dom.addEventListener("keydown", this._onKey);
    }
    document.addEventListener("scroll", this._onScroll, true);
  }

  // ── what is under the pointer ────────────────────────────────────────────────
  static describe(el) {
    if (!el || !el.closest) return null;
    const a = el.closest("a[href]");
    if (a) return { kind: "link", href: a.getAttribute("href") || "", el: a };
    const w = el.closest("span[data-wikilink]");
    if (w) {
      return {
        kind: "wikilink",
        target: w.getAttribute("target") || "",
        docId: w.getAttribute("docId") || w.getAttribute("docid") || null,
        alias: w.getAttribute("alias") || null,
        el: w,
      };
    }
    return null;
  }

  get el() {
    return this._el;
  }

  isOpen() {
    return !!(this._el && this._el.style.display !== "none");
  }

  // ── hover plumbing ──────────────────────────────────────────────────────────
  _handleOver(e) {
    const info = LinkPreview.describe(e.target);
    if (!info) return;
    if (this._anchor === info.el && this.isOpen()) {
      this._cancelHide();
      return;
    }
    this._cancelShow();
    this._showTimer = setTimeout(() => this.showFor(info.el), this._delay);
  }

  _handleOut(e) {
    const info = LinkPreview.describe(e.target);
    if (!info) return;
    // Leaving the anchor for the card keeps it; leaving for anywhere else hides it soon.
    const to = e.relatedTarget;
    if (to && this._el && this._el.contains(to)) return;
    this._cancelShow();
    this._scheduleHide();
  }

  _cancelShow() {
    if (this._showTimer) clearTimeout(this._showTimer);
    this._showTimer = null;
  }

  _cancelHide() {
    if (this._hideTimer) clearTimeout(this._hideTimer);
    this._hideTimer = null;
  }

  _scheduleHide() {
    this._cancelHide();
    this._hideTimer = setTimeout(() => this.hide(), this._hideDelay);
  }

  // ── the card ────────────────────────────────────────────────────────────────
  _build() {
    const el = document.createElement("div");
    el.className = CLASS;
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-label", "Link preview");
    el.style.display = "none";

    const title = document.createElement("div");
    title.className = `${CLASS}__title`;
    const addr = document.createElement("div");
    addr.className = `${CLASS}__addr`;
    const excerpt = document.createElement("div");
    excerpt.className = `${CLASS}__excerpt`;
    const actions = document.createElement("div");
    actions.className = `${CLASS}__actions`;
    const open = document.createElement("button");
    open.type = "button";
    open.className = `${CLASS}__btn ${CLASS}__open`;
    open.textContent = "Open";
    const edit = document.createElement("button");
    edit.type = "button";
    edit.className = `${CLASS}__btn ${CLASS}__edit`;
    edit.textContent = "Edit";
    actions.appendChild(open);
    actions.appendChild(edit);
    el.appendChild(title);
    el.appendChild(addr);
    el.appendChild(excerpt);
    el.appendChild(actions);

    // The card is outside ProseMirror: a mousedown inside it must not move the editor's
    // selection (the bubble does the same), but the buttons still act on click.
    el.addEventListener("mousedown", (e) => e.preventDefault());
    el.addEventListener("mouseenter", () => this._cancelHide());
    el.addEventListener("mouseleave", () => this._scheduleHide());
    open.addEventListener("click", () => this.open());
    edit.addEventListener("click", () => this.edit());

    this._parts = { title, addr, excerpt, open, edit };
    document.body.appendChild(el);
    this._el = el;
  }

  // Show the card for an anchor element (a link's <a> or a wikilink's <span>); also the seam the
  // mounted test drives, so the hover delay is not part of what it proves.
  showFor(anchorEl) {
    const info = LinkPreview.describe(anchorEl);
    if (!info) return false;
    if (!this._el) this._build();
    this._cancelHide();
    this._anchor = info.el;
    // The card is portaled to body; preserve the hovered paper's theme.
    const theme = getComputedStyle(info.el);
    for (const name of ["--paper-chrome-bg", "--paper-chrome-border", "--paper-ink", "--paper-ink-soft", "--paper-rule", "--paper-accent", "--paper-font-sans", "--paper-font-mono"]) {
      this._el.style.setProperty(name, theme.getPropertyValue(name));
    }
    this._info = info;
    const ticket = ++this._ticket;
    const p = this._parts;
    if (info.kind === "link") {
      p.title.textContent = hostOf(info.href) || "Link";
      p.addr.textContent = info.href;
    } else {
      p.title.textContent = info.alias && info.alias !== info.target ? `${info.alias} → ${info.target}` : info.target || "Wikilink";
      p.addr.textContent = `[[${info.target}]]`;
    }
    p.excerpt.textContent = "";
    p.excerpt.style.display = "none";
    p.edit.style.display = this._editable() ? "" : "none";
    this._el.dataset.kind = info.kind;
    this._el.style.display = "block";
    this._reposition();

    // What the host knows about the target lands when it arrives, if the card still shows it.
    let pending = null;
    try {
      pending = this._resolve({ kind: info.kind, href: info.href, target: info.target, docId: info.docId, alias: info.alias });
    } catch (_e) {
      pending = null;
    }
    if (pending && typeof pending.then === "function") {
      pending.then(
        (meta) => { if (ticket === this._ticket) this._applyMeta(meta); },
        () => {}
      );
    } else if (pending) {
      this._applyMeta(pending);
    }
    return true;
  }

  _applyMeta(meta) {
    if (!meta || typeof meta !== "object" || !this._el) return;
    const p = this._parts;
    if (typeof meta.title === "string" && meta.title) p.title.textContent = meta.title;
    if (typeof meta.excerpt === "string" && meta.excerpt) {
      p.excerpt.textContent = meta.excerpt;
      p.excerpt.style.display = "";
    }
    if (typeof meta.href === "string" && meta.href && this._info) this._info.resolvedHref = meta.href;
    this._reposition();
  }

  hide() {
    this._cancelShow();
    this._cancelHide();
    if (this._el) this._el.style.display = "none";
    this._anchor = null;
    this._info = null;
    this._ticket += 1;
  }

  // Under the anchor, left-aligned to it; above when the viewport bottom is near; never off the side.
  _reposition() {
    if (!this._el || !this._anchor) return;
    const a = this._anchor.getBoundingClientRect();
    const rect = this._el.getBoundingClientRect();
    const margin = 8;
    const vw = window.innerWidth || 0;
    const vh = window.innerHeight || 0;
    let left = Math.round(a.left);
    if (vw && left + rect.width > vw - margin) left = Math.max(margin, vw - rect.width - margin);
    let top = Math.round(a.bottom + 6);
    if (vh && top + rect.height > vh - margin) top = Math.max(margin, Math.round(a.top - rect.height - 6));
    this._el.style.left = `${left}px`;
    this._el.style.top = `${top}px`;
  }

  // ── actions ─────────────────────────────────────────────────────────────────
  open() {
    const info = this._info;
    if (!info) return;
    const detail = { kind: info.kind, href: info.resolvedHref || info.href || null, target: info.target || null, docId: info.docId || null, alias: info.alias || null };
    this.hide();
    this._onOpen(detail);
  }

  // Select the whole mark under the card (so the bubble shows it) and let the host continue —
  // for a link that is the bubble's link row seeded with the current href.
  edit() {
    const info = this._info;
    if (!info) return;
    const range = this.markRange(info);
    this.hide();
    if (range) {
      this._editor.commands.setTextSelection(range);
      this._editor.commands.focus();
    }
    this._onEdit({ kind: info.kind, href: info.href || null, target: info.target || null, docId: info.docId || null, range });
  }

  // The doc range of the contiguous text carrying the hovered mark (same href / same target).
  markRange(info) {
    const { view, state } = this._editor;
    let pos;
    try {
      pos = view.posAtDOM(info.el, 0);
    } catch (_e) {
      return null;
    }
    const $pos = state.doc.resolve(pos);
    const parent = $pos.parent;
    if (!parent.isTextblock) return null;
    const base = $pos.start();
    const markName = info.kind === "link" ? "link" : "wikilink";
    const same = (node) => node.isText && node.marks.some((m) => m.type.name === markName && (info.kind === "link" ? (m.attrs.href || "") === (info.href || "") : (m.attrs.target || "") === (info.target || "")));
    let offset = 0;
    let from = null;
    let to = null;
    parent.forEach((child) => {
      const start = base + offset;
      const end = start + child.nodeSize;
      if (same(child)) {
        if (from == null) from = start;
        to = end;
        if (start <= pos && pos <= end) {
          // the run containing the pointer: keep extending
        }
      } else if (from != null && to != null && to <= pos) {
        // a run that ended before the pointer belongs to another link: start over
        from = null;
        to = null;
      }
      offset += child.nodeSize;
    });
    if (from == null || to == null || pos < from || pos > to) {
      // fall back to the single text node under the pointer
      const node = state.doc.nodeAt(pos);
      if (node && same(node)) return { from: pos, to: pos + node.nodeSize };
      return null;
    }
    return { from, to };
  }

  destroy() {
    this._cancelShow();
    this._cancelHide();
    const dom = this._editor && this._editor.view && this._editor.view.dom;
    if (dom) {
      dom.removeEventListener("mouseover", this._onOver);
      dom.removeEventListener("mouseout", this._onOut);
      dom.removeEventListener("keydown", this._onKey);
    }
    document.removeEventListener("scroll", this._onScroll, true);
    if (this._el && this._el.parentNode) this._el.parentNode.removeChild(this._el);
    this._el = null;
    this._anchor = null;
    this._info = null;
  }
}

function hostOf(href) {
  try {
    const u = new URL(href, "http://localhost/");
    if (/^https?:$/.test(u.protocol)) return u.host;
  } catch (_e) {}
  return "";
}
