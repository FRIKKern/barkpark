// bp-overflow-menu — "priority+" overflow row Web Component (Task barkpark-smn).
// Fifth in the bp-* suite after bp-rich-text-editor (#111), bp-media-picker
// (#112), bp-reference-picker (#114), bp-document-preview (#115).
//
// Pattern:
//   * Render all action buttons inline in the host slot.
//   * When the row exceeds the host width, hide the right-most items and
//     surface a "•••" trigger that opens a popover with the hidden items.
//   * Resize-driven via ResizeObserver. LiveView-friendly: every reflow
//     re-walks `this.children` so the WC tolerates Phoenix patches that
//     swap conditional buttons in and out.
//
// Popover items are CLONES of the originals; clicking a clone calls
// `.click()` on the original so the original button's phx-click /
// AppleScript / onclick handlers all fire untouched.
//
// Close-on-outside-click and Escape are both wired. The popover is a
// `position: fixed` floating element anchored under the trigger; no
// collision logic — the editor header is at the top of the viewport
// so there is always room below.
//
// Idempotent: connectedCallback guards against double-init; the WC
// survives LiveView re-renders that replace it entirely (new instance
// initializes from scratch) and re-renders that mutate children
// (reflow re-walks children every time).

(function () {
  let triggerSeq = 0;

  class BpOverflowMenu extends HTMLElement {
    constructor() {
      super();
      this._observer = null;
      this._mutation = null;
      this._popover = null;
      this._trigger = null;
      this._raf = null;
      this._initialized = false;
      this._outsideHandler = null;
      this._escHandler = null;
    }

    // task-43fe1756e8ae8120 — measured at 390px in headless Chrome: four doc
    // actions [data-overflowed] and ZERO "More actions" triggers in the
    // document. Two holes, both closed here:
    //
    //   1. A LiveView patch can DETACH and RE-ATTACH this element.
    //      disconnectedCallback disconnects the observers, and the old
    //      `if (this._initialized) return;` guard then skipped re-observing on
    //      reconnect — a dead component: no reflow ever again. Build the
    //      trigger ONCE; (re)wire the observers on EVERY connect.
    //   2. A patch morphs this element's children back to the server render,
    //      which never carries the JS-built trigger, so the trigger is REMOVED
    //      while children keep [data-overflowed]. A size-only ResizeObserver
    //      never hears that; a child-list MutationObserver does, and puts the
    //      trigger back in its own callback (a microtask, before paint).
    connectedCallback() {
      if (!this._initialized) {
        this._initialized = true;
        this._buildTrigger();
      }
      this._reattachTrigger();

      if (!this._observer) {
        this._observer = new ResizeObserver(() => this._scheduleReflow());
        this._observer.observe(this);
      }
      if (!this._mutation) {
        this._mutation = new MutationObserver(() => {
          this._reattachTrigger();
          this._scheduleReflow();
        });
        this._mutation.observe(this, { childList: true });
      }
      this._scheduleReflow();
    }

    disconnectedCallback() {
      if (this._observer) this._observer.disconnect();
      if (this._mutation) this._mutation.disconnect();
      this._closePopover();
      this._observer = null;
      this._mutation = null;
    }

    _buildTrigger() {
      const btn = document.createElement("button");
      // task-c5144f8242efc71b — LiveView's morphdom pairs id-less children by
      // POSITION. When a patch changed the number of actions (Discard draft:
      // seven became six), it rewrote this node in place into a server
      // button: `this._trigger` became a hidden "Delete", the row had two
      // Deletes and no trigger, and `_reattachTrigger` saw nothing to do. An
      // id the server never renders makes morphdom REMOVE the node instead,
      // and the child-list observer puts it back untouched.
      btn.id = `bp-overflow-trigger-${++triggerSeq}`;
      btn.type = "button";
      btn.className = "bp-overflow-trigger";
      btn.setAttribute("aria-haspopup", "menu");
      btn.setAttribute("aria-expanded", "false");
      // The host stamps the word in the viewer's language; English otherwise.
      btn.setAttribute("aria-label", this.getAttribute("data-label") || "More actions");
      btn.textContent = "•••";
      btn.dataset.overflowSkip = "true";
      btn.style.display = "none";
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        this._togglePopover();
      });
      this.appendChild(btn);
      this._trigger = btn;
    }

    // Walk the host's current children, skipping the trigger and any
    // explicitly-opted-out elements. Returns Element[] in DOM order.
    _collectItems() {
      const out = [];
      for (const child of this.children) {
        if (child === this._trigger) continue;
        if (child.nodeType !== 1) continue;
        if (child.hasAttribute("data-overflow-skip")) continue;
        out.push(child);
      }
      return out;
    }

    _scheduleReflow() {
      if (this._raf) cancelAnimationFrame(this._raf);
      this._raf = requestAnimationFrame(() => this._reflow());
    }

    // Re-attach a trigger a LiveView patch stripped (see connectedCallback).
    // The append is itself a child-list mutation; the next callback finds the
    // trigger in place and appends nothing, so this cannot loop.
    _reattachTrigger() {
      if (this._trigger && this._trigger.parentNode !== this) this.appendChild(this._trigger);
    }

    _reflow() {
      this._reattachTrigger();

      const items = this._collectItems();

      // Show everything first, then measure.
      for (const el of items) el.removeAttribute("data-overflowed");
      this._trigger.style.display = "none";

      const available = this.clientWidth;
      if (available <= 0) return;
      if (this.scrollWidth <= available) return;

      // Reveal trigger and reserve room for it.
      this._trigger.style.display = "";
      const triggerWidth = this._trigger.offsetWidth || 36;
      const gap = this._gap();
      const reserved = available - triggerWidth - gap;

      // Walk left-to-right; items whose right-edge would push past
      // `reserved` get hidden via [data-overflowed].
      let runningWidth = 0;
      for (const el of items) {
        const w = el.offsetWidth;
        if (runningWidth + w <= reserved) {
          runningWidth += w + gap;
        } else {
          el.setAttribute("data-overflowed", "true");
        }
      }

      // If nothing actually overflowed (e.g. trigger itself fits where
      // the last item couldn't), hide the trigger again.
      const anyHidden = items.some((el) => el.hasAttribute("data-overflowed"));
      if (!anyHidden) this._trigger.style.display = "none";
    }

    _gap() {
      const cs = getComputedStyle(this);
      const g = parseFloat(cs.columnGap || cs.gap || "0");
      return isFinite(g) ? g : 0;
    }

    _togglePopover() {
      if (this._popover && document.body.contains(this._popover)) {
        this._closePopover();
      } else {
        this._openPopover();
      }
    }

    _openPopover() {
      const items = this._collectItems();
      const overflowed = items.filter((el) => el.hasAttribute("data-overflowed"));
      if (overflowed.length === 0) return;

      const popover = document.createElement("div");
      popover.className = "bp-overflow-popover";
      popover.setAttribute("role", "menu");

      overflowed.forEach((orig) => {
        const clone = orig.cloneNode(true);
        clone.classList.add("bp-overflow-menuitem");
        clone.removeAttribute("data-overflowed");
        clone.setAttribute("role", "menuitem");
        // Strip phx-* / id attributes from the clone so LiveView doesn't
        // try to bind to it (the clone lives outside the LV-managed
        // subtree once appended to <body>). We forward by clicking the
        // ORIGINAL, which is still inside the LV tree and intact.
        for (const attr of Array.from(clone.attributes)) {
          if (attr.name.startsWith("phx-") || attr.name === "id") {
            clone.removeAttribute(attr.name);
          }
        }
        clone.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          this._closePopover();
          orig.click();
        });
        popover.appendChild(clone);
      });

      // Anchor to trigger; below + right-aligned.
      const triggerRect = this._trigger.getBoundingClientRect();
      popover.style.position = "fixed";
      popover.style.top = triggerRect.bottom + 4 + "px";
      popover.style.right = window.innerWidth - triggerRect.right + "px";

      document.body.appendChild(popover);
      this._popover = popover;
      this._trigger.setAttribute("aria-expanded", "true");

      this._outsideHandler = (e) => {
        if (!popover.contains(e.target) && e.target !== this._trigger) {
          this._closePopover();
        }
      };
      this._escHandler = (e) => {
        if (e.key === "Escape") this._closePopover();
      };

      // Defer wiring so the originating click doesn't immediately
      // bubble back through document and re-close.
      setTimeout(() => {
        document.addEventListener("click", this._outsideHandler, true);
        document.addEventListener("keydown", this._escHandler, true);
      }, 0);
    }

    _closePopover() {
      if (this._popover && document.body.contains(this._popover)) {
        this._popover.remove();
      }
      this._popover = null;
      if (this._trigger) this._trigger.setAttribute("aria-expanded", "false");
      if (this._outsideHandler) {
        document.removeEventListener("click", this._outsideHandler, true);
        this._outsideHandler = null;
      }
      if (this._escHandler) {
        document.removeEventListener("keydown", this._escHandler, true);
        this._escHandler = null;
      }
    }
  }

  if (!customElements.get("bp-overflow-menu")) {
    customElements.define("bp-overflow-menu", BpOverflowMenu);
  }
})();
