// bp-rich-text-editor — Studio rich-text Web Component (Task #11 WI4 v1).
//
// Contenteditable with paste-as-plain-text and a minimal formatting
// toolbar: Bold, Italic, and Link (inline URL row, selection preserved
// across the focus hop — Sanity's portable-text editor has links as a
// core mark; this WC had no affordance at all). Emits a bubbling
// CustomEvent("bp-change", {detail: {value}}) on every input. The
// LiveView hook BarkparkFieldBridge (see root.html.heex) catches the
// bubbled event on the wrapper and mirrors detail.value into the
// sibling hidden input identified by data-bridge-target — Phoenix
// then debounces + serialises + pushes phx-change="autosave" exactly
// as it would for any native input.
//
// Contract: docs/studio/web-components.md
// v2 plan: replace document.execCommand + plain contenteditable with a
// vendored ProseMirror/TipTap engine and add a setValue(v) channel for
// collaborative editing. The toolbar deliberately stays inside the
// documented v1 execCommand architecture.

class BpRichTextEditor extends HTMLElement {
  constructor() {
    super();
    this._editor = null;
    this._onInput = null;
    this._onPaste = null;
  }

  connectedCallback() {
    if (this._editor) return; // double-mount guard

    const initial = this.getAttribute("value") || this.dataset.value || "";

    this._buildToolbar();

    this._editor = document.createElement("div");
    this._editor.contentEditable = "true";
    this._editor.className = "bp-rte-body";
    // A bare contenteditable div has no role and no name; the field's label
    // rides on the host as data-label (task-e471f8bd50a1aefd).
    this._editor.setAttribute("role", "textbox");
    this._editor.setAttribute("aria-multiline", "true");
    if (this.dataset.label) this._editor.setAttribute("aria-label", this.dataset.label);
    this._editor.innerHTML = initial;
    this.appendChild(this._editor);

    this._onInput = () => this._emit();
    this._editor.addEventListener("input", this._onInput);

    // Paste-as-plain-text: strip formatting + sanitise XSS surface.
    // document.execCommand is deprecated but supported across current
    // browsers; v2 will migrate to a structured-paste handler.
    this._onPaste = (e) => {
      e.preventDefault();
      const cb = e.clipboardData || window.clipboardData;
      const text = cb ? cb.getData("text/plain") : "";
      document.execCommand("insertText", false, text);
    };
    this._editor.addEventListener("paste", this._onPaste);
  }

  disconnectedCallback() {
    if (this._onSelection) document.removeEventListener("selectionchange", this._onSelection);
    if (this._editor) {
      if (this._onInput) this._editor.removeEventListener("input", this._onInput);
      if (this._onPaste) this._editor.removeEventListener("paste", this._onPaste);
    }
  }

  _emit() {
    this.dispatchEvent(
      new CustomEvent("bp-change", {
        bubbles: true,
        composed: false,
        detail: { value: this._editor.innerHTML }
      })
    );
  }

  // ── Toolbar (B / I / Link) ────────────────────────────────────────────
  // execCommand on the live selection; the link flow saves the Range
  // before the URL input steals focus and restores it before exec, so
  // the link lands on what the user actually selected.
  _buildToolbar() {
    const bar = document.createElement("div");
    bar.className = "bp-rte-toolbar";
    // The host's words (data-strings, keyed by the English); English otherwise.
    let strings = {};
    try { strings = JSON.parse(this.getAttribute("data-strings") || "{}") || {}; } catch (_e) { strings = {}; }
    const t = (text) => {
      const out = typeof strings[text] === "string" ? strings[text] : text;
      return out.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
    };
    // Each glyph button is named by its word: the glyph alone read "B, button".
    bar.innerHTML =
      '<button type="button" class="bp-rte-btn" data-cmd="bold" title="' + t("Bold (mod+B)") + '" aria-label="' + t("Bold") + '"><b aria-hidden="true">B</b></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="italic" title="' + t("Italic (mod+I)") + '" aria-label="' + t("Italic") + '"><i aria-hidden="true">I</i></button>' +
      '<button type="button" class="bp-rte-btn bp-rte-link" title="' + t("Link") + '" aria-label="' + t("Link") + '"><span aria-hidden="true">🔗</span></button>' +
      '<span class="bp-rte-linkrow" hidden>' +
      '<input type="text" class="bp-rte-url" placeholder="https://…" aria-label="' + t("Link address") + '" />' +
      '<button type="button" class="bp-rte-btn bp-rte-set">' + t("Set") + "</button>" +
      '<button type="button" class="bp-rte-btn bp-rte-unset">' + t("Remove") + "</button>" +
      "</span>";
    this.appendChild(bar);

    const exec = (cmd, arg) => {
      this._editor.focus();
      // Focusing the text from a toolbar reached by Tab drops the selection to
      // a caret; put back the last one the author made in the text.
      if (this._lastRange) {
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(this._lastRange);
      }
      document.execCommand(cmd, false, arg);
      this._emit();
    };

    // A pointer acts on mousedown (+ preventDefault keeps the text selection
    // alive; a click would blur the contenteditable and collapse it). Enter and
    // Space fire only `click`, with detail 0, so a keyboard press acts there; a
    // pointer's own click (detail >= 1) is skipped so it never acts twice.
    const press = (el, act) => {
      el.addEventListener("mousedown", (e) => {
        e.preventDefault();
        act();
      });
      el.addEventListener("click", (e) => {
        if (e.detail === 0) act();
      });
    };

    // The last selection inside the text, kept so a toolbar reached by Tab
    // (which moves focus off the text) still acts on what the author selected.
    this._onSelection = () => {
      const sel = window.getSelection();
      // Only while the text has focus: leaving it collapses the selection,
      // and that must not overwrite the one the author made.
      if (
        sel && sel.rangeCount > 0 && this._editor &&
        document.activeElement === this._editor && this._editor.contains(sel.anchorNode)
      ) {
        this._lastRange = sel.getRangeAt(0).cloneRange();
      }
    };
    document.addEventListener("selectionchange", this._onSelection);
    const reselect = () => {
      const sel = window.getSelection();
      const inside = sel && sel.rangeCount > 0 && this._editor.contains(sel.anchorNode);
      if (!inside && this._lastRange) {
        sel.removeAllRanges();
        sel.addRange(this._lastRange);
      }
    };
    bar.querySelectorAll("[data-cmd]").forEach((b) => {
      press(b, () => {
        reselect();
        exec(b.dataset.cmd);
      });
    });

    const linkRow = bar.querySelector(".bp-rte-linkrow");
    const urlInput = bar.querySelector(".bp-rte-url");

    press(bar.querySelector(".bp-rte-link"), () => {
      reselect();
      // Save the selection — focusing the URL input destroys it.
      const sel = window.getSelection();
      this._savedRange =
        sel && sel.rangeCount > 0 ? sel.getRangeAt(0).cloneRange() : null;
      const a = this._anchorAtSelection();
      urlInput.value = a ? a.getAttribute("href") || "" : "";
      linkRow.hidden = !linkRow.hidden;
      if (!linkRow.hidden) urlInput.focus();
    });

    const restore = () => {
      if (!this._savedRange) return;
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(this._savedRange);
    };

    const apply = () => {
      const href = urlInput.value.trim();
      restore();
      if (href !== "") {
        // Normalize bare domains so the anchor never becomes relative.
        exec("createLink", /^[a-z][a-z0-9+.-]*:/i.test(href) ? href : "https://" + href);
      }
      linkRow.hidden = true;
    };

    press(bar.querySelector(".bp-rte-set"), apply);
    urlInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        apply();
      } else if (e.key === "Escape") {
        linkRow.hidden = true;
        restore();
      }
    });
    press(bar.querySelector(".bp-rte-unset"), () => {
      restore();
      exec("unlink");
      linkRow.hidden = true;
    });
  }

  // The <a> the current selection sits inside, if any — pre-fills the URL
  // row so editing an existing link shows its target.
  _anchorAtSelection() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== this._editor) {
      if (node.nodeType === 1 && node.tagName === "A") return node;
      node = node.parentNode;
    }
    return null;
  }

  // Programmatic getter/setter for future server-pushed updates and
  // for tests. Reflects to the contenteditable's innerHTML.
  get value() {
    return this._editor ? this._editor.innerHTML : "";
  }

  set value(v) {
    if (this._editor && this._editor.innerHTML !== v) {
      this._editor.innerHTML = v;
    }
  }
}

customElements.define("bp-rich-text-editor", BpRichTextEditor);
