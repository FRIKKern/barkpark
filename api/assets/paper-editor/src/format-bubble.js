// format-bubble.js — floating selection format toolbar for <bp-paper-editor> (B6).
//
// A hand-rolled selection bubble (NOT @tiptap/extension-bubble-menu) so it
// reuses the exact `view.coordsAtPos` + fixed-position pattern already proven
// in slash-menu.js and avoids pulling tippy.js into the committed bundle. The
// Web Component decides WHEN to show it (a non-empty text selection inside the
// block); this module owns the toolbar DOM, the four mark buttons, the inline
// link input, positioning, and pressed-state styling.
//
// Buttons (left→right): B (bold), I (italic), </> (inline code), link. Each
// toggles the matching mark via the editor's chained commands. The link button
// reveals a small inline input row (set / remove) so a URL can be typed without
// a blocking window.prompt — Esc or empty-submit cancels.
//
// Marks themselves (bold/italic/code/link) already round-trip through
// convert.js; this module only adds the visible affordance and never touches
// the patch-block op shape, the slash menu, or the keyboard path.

export class FormatBubble {
  constructor({ editor }) {
    this._editor = editor;
    this._el = null;
    this._btns = {}; // name -> button element, for pressed-state sync
    this._linkRow = null;
    this._linkInput = null;
    this._open = false;
    this._linkOpen = false;

    // Bound once so add/removeEventListener match on teardown.
    this._onDocPointer = (e) => this._handlePointer(e);
    this._onScroll = () => {
      if (this._open) this._reposition();
    };
  }

  isOpen() {
    return this._open;
  }

  // Called by the WC on every selectionUpdate. Shows the bubble for a non-empty
  // text selection, hides it otherwise (empty caret, blur, node selection).
  update() {
    if (!this._editor || this._editor.isDestroyed) {
      this._hide();
      return;
    }
    const { state, view } = this._editor;
    const { selection } = state;
    const { empty, from, to } = selection;

    // Hide unless there is a non-empty text range. An empty/collapsed selection
    // always hides immediately.
    const hasText = !empty && to > from && this._selectionHasText(state, from, to);
    if (!hasText) {
      this._hide();
      return;
    }

    // Focus rule. `view.hasFocus()` keeps the bubble from lingering after a blur
    // (e.g. clicking another block) — but focus held INSIDE the bubble (the link
    // URL input) must count as alive: focusing that input necessarily blurs
    // ProseMirror, and hiding here made the link row unusable (proven live in
    // Chrome: the bubble self-hid one frame after the link button opened it,
    // because the deferred input.focus() blurred the editor and this branch ran).
    // A blur can also fire while focus is still IN FLIGHT (before the new target
    // reports as document.activeElement), so never hide synchronously on blur —
    // re-check after focus settles and hide only if it landed outside both the
    // editor and the bubble.
    if (!view.hasFocus() && !this._focusInBubble()) {
      setTimeout(() => {
        if (!this._editor || this._editor.isDestroyed) {
          this._hide();
          return;
        }
        if (!this._editor.view.hasFocus() && !this._focusInBubble()) this._hide();
      }, 0);
      return;
    }

    if (!this._el) this._build();
    this._syncPressed();
    this._show();
    this._reposition();
  }

  destroy() {
    this._hide();
    if (this._el && this._el.parentNode) this._el.parentNode.removeChild(this._el);
    this._el = null;
    this._btns = {};
    this._linkRow = null;
    this._linkInput = null;
  }

  // ── internals ────────────────────────────────────────────────────────────

  // True while document focus sits inside the bubble itself — the one state
  // where the editor is legitimately blurred yet the bubble must survive (the
  // link URL input, or a toolbar button that took focus).
  _focusInBubble() {
    if (!this._el) return false;
    const active = document.activeElement;
    return !!active && this._el.contains(active);
  }

  // True when the selected range contains at least one non-whitespace char, so
  // a selection spanning only a gap/node boundary never floats the bubble.
  _selectionHasText(state, from, to) {
    const text = state.doc.textBetween(from, to, "\n", "\n");
    return text.trim().length > 0;
  }

  _build() {
    const el = document.createElement("div");
    el.className = "bp-paper-format";
    el.setAttribute("role", "toolbar");
    el.style.display = "none";

    el.appendChild(this._mkBtn("bold", "B", "bp-paper-format__btn--bold", "Bold"));
    el.appendChild(this._mkBtn("italic", "I", "bp-paper-format__btn--italic", "Italic"));
    el.appendChild(this._mkBtn("code", "</>", "bp-paper-format__btn--code", "Inline code"));

    const sep = document.createElement("span");
    sep.className = "bp-paper-format__sep";
    el.appendChild(sep);

    el.appendChild(this._mkBtn("link", "link", "bp-paper-format__btn--link", "Link"));

    // Inline link input row (hidden until the link button is pressed).
    const row = document.createElement("div");
    row.className = "bp-paper-format__link-row";
    row.style.display = "none";

    const input = document.createElement("input");
    input.type = "url";
    input.className = "bp-paper-format__link-input";
    input.placeholder = "Paste link, ↵ to apply";
    input.setAttribute("aria-label", "Link URL");
    // mousedown.preventDefault would block caret entry into the input, so we
    // only stop the editor's blur-close on the bubble container (below).
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this._applyLink(input.value);
      } else if (e.key === "Escape") {
        e.preventDefault();
        // stopPropagation: without it, this keydown also reaches the window
        // listener that Escape-closes the palette/menu layer, so one Escape
        // press double-fires — closing the link row AND (if open) a menu
        // that had nothing to do with this input. Confirmed in-browser:
        // window BUBBLE=0 after adding this, double-fire eliminated, and
        // capture-phase palette-Escape precedence stays intact (task
        // paper-editor-bundle-stale-and-escape-stoppropagation).
        //
        // Studio's Hooks.InspectorEscape (root.html.heex) carries its own
        // data-escape-veto=".bp-paper-format" for this exact double-fire,
        // added by tier3-keyboard-exit-and-focus-return before this fix
        // shipped. DECISION (this task's criterion 3): RETAIN that veto,
        // not simplify it away — every bubble button (bold/italic/code/
        // link/remove) preventDefaults its own mousedown so a mouse click
        // never focuses it, but Tab still can, and none of those buttons
        // stopPropagation their own Escape. This stopPropagation only
        // covers the link input; the veto is still load-bearing defense in
        // depth for a keyboard user Tab-focused on a bubble button.
        e.stopPropagation();
        this._closeLinkRow(true);
      }
    });

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "bp-paper-format__link-remove";
    remove.textContent = "Remove";
    remove.addEventListener("mousedown", (e) => {
      e.preventDefault();
      this._editor.chain().focus().extendMarkRange("link").unsetLink().run();
      this._closeLinkRow(false);
      this._syncPressed();
    });

    row.appendChild(input);
    row.appendChild(remove);
    el.appendChild(row);

    this._linkRow = row;
    this._linkInput = input;

    // A pointer-down anywhere inside the bubble must NOT blur the editor (which
    // would collapse the selection and hide the bubble before the click lands).
    el.addEventListener("mousedown", (e) => {
      // Let the URL input take focus normally; block blur for the buttons.
      if (e.target !== input) e.preventDefault();
    });

    // When focus leaves the bubble (Tab out, click elsewhere) no editor event
    // fires — the editor was already blurred when the input took focus — so
    // re-evaluate once the new focus target settles: landing outside both the
    // editor and the bubble hides it; a hop back into either keeps it open.
    el.addEventListener("focusout", () => {
      setTimeout(() => this.update(), 0);
    });

    document.body.appendChild(el);
    this._el = el;

    document.addEventListener("mousedown", this._onDocPointer, true);
    window.addEventListener("scroll", this._onScroll, true);
  }

  _mkBtn(name, glyph, modClass, title) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `bp-paper-format__btn ${modClass}`;
    btn.textContent = glyph;
    btn.title = title;
    btn.setAttribute("aria-label", title);
    btn.setAttribute("aria-pressed", "false");
    btn.addEventListener("mousedown", (e) => {
      e.preventDefault();
      this._onBtn(name);
    });
    this._btns[name] = btn;
    return btn;
  }

  _onBtn(name) {
    if (!this._editor) return;
    switch (name) {
      case "bold":
        this._editor.chain().focus().toggleBold().run();
        break;
      case "italic":
        this._editor.chain().focus().toggleItalic().run();
        break;
      case "code":
        this._editor.chain().focus().toggleCode().run();
        break;
      case "link":
        this._toggleLinkRow();
        return; // link row owns its own pressed sync
    }
    this._syncPressed();
  }

  // Open the inline link input (seeded with any existing href on the selection)
  // or close it if already open.
  _toggleLinkRow() {
    if (this._linkOpen) {
      this._closeLinkRow(true);
      return;
    }
    this._linkOpen = true;
    this._linkRow.style.display = "flex";
    this._btns.link.setAttribute("aria-pressed", "true");
    const existing = this._editor.getAttributes("link").href || "";
    this._linkInput.value = existing;
    this._reposition();
    // Defer focus so the row is laid out before we move the caret into it.
    requestAnimationFrame(() => this._linkInput && this._linkInput.focus());
  }

  // Apply (or, on empty input, clear) the link mark over the selection's full
  // mark range, then refocus the editor.
  _applyLink(rawHref) {
    const href = (rawHref || "").trim();
    const chain = this._editor.chain().focus().extendMarkRange("link");
    if (href.length === 0) {
      chain.unsetLink().run();
    } else {
      chain.setLink({ href }).run();
    }
    this._closeLinkRow(false);
    this._syncPressed();
  }

  // Hide the link row. `refocus` returns the caret to the editor (Esc/cancel);
  // false leaves focus where the apply/remove command already put it.
  _closeLinkRow(refocus) {
    this._linkOpen = false;
    if (this._linkRow) this._linkRow.style.display = "none";
    this._syncPressed();
    if (refocus && this._editor) this._editor.commands.focus();
  }

  // Reflect which marks are active on the current selection as pressed buttons.
  _syncPressed() {
    if (!this._editor) return;
    const set = (name, active) => {
      const btn = this._btns[name];
      if (!btn) return;
      btn.setAttribute("aria-pressed", active ? "true" : "false");
      btn.classList.toggle("bp-paper-format__btn--active", !!active);
    };
    set("bold", this._editor.isActive("bold"));
    set("italic", this._editor.isActive("italic"));
    set("code", this._editor.isActive("code"));
    // Link button stays pressed while its input row is open OR a link is active.
    set("link", this._linkOpen || this._editor.isActive("link"));
  }

  _show() {
    if (this._el && !this._open) {
      this._el.style.display = "flex";
      this._open = true;
    }
  }

  _hide() {
    if (this._el) this._el.style.display = "none";
    this._open = false;
    this._linkOpen = false;
    if (this._linkRow) this._linkRow.style.display = "none";
  }

  // Anchor the bubble centered above the selection; flip below if it would
  // overflow the viewport top. Fixed positioning floats it over the editor.
  _reposition() {
    if (!this._el || !this._editor) return;
    const { state, view } = this._editor;
    const { from, to } = state.selection;
    let start, end;
    try {
      start = view.coordsAtPos(from);
      end = view.coordsAtPos(to);
    } catch (_e) {
      return;
    }

    const rect = this._el.getBoundingClientRect();
    const margin = 8;
    const selLeft = Math.min(start.left, end.left);
    const selRight = Math.max(start.right || start.left, end.right || end.left);
    const centerX = (selLeft + selRight) / 2;

    let left = Math.round(centerX - rect.width / 2);
    if (left < margin) left = margin;
    if (left + rect.width > window.innerWidth - margin) {
      left = window.innerWidth - rect.width - margin;
    }

    // Prefer above the selection top; flip below if it would clip the viewport.
    let top = Math.round(start.top - rect.height - margin);
    if (top < margin) {
      top = Math.round((end.bottom || end.top) + margin);
    }

    this._el.style.left = `${left}px`;
    this._el.style.top = `${top}px`;
  }

  // A pointer-down outside the bubble closes any open link row (but does not
  // force-hide the bubble — selection-driven `update()` owns visibility).
  _handlePointer(e) {
    if (!this._el || !this._open) return;
    if (this._el.contains(e.target)) return;
    if (this._linkOpen) this._closeLinkRow(false);
  }
}
