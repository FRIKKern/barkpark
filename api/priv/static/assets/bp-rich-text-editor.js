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
    bar.innerHTML =
      '<button type="button" class="bp-rte-btn" data-cmd="bold" title="Bold (mod+B)"><b>B</b></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="italic" title="Italic (mod+I)"><i>I</i></button>' +
      '<button type="button" class="bp-rte-btn bp-rte-link" title="Link">🔗</button>' +
      '<span class="bp-rte-linkrow" hidden>' +
      '<input type="text" class="bp-rte-url" placeholder="https://…" />' +
      '<button type="button" class="bp-rte-btn bp-rte-set">Set</button>' +
      '<button type="button" class="bp-rte-btn bp-rte-unset">Remove</button>' +
      "</span>";
    this.appendChild(bar);

    const exec = (cmd, arg) => {
      this._editor.focus();
      document.execCommand(cmd, false, arg);
      this._emit();
    };

    bar.querySelectorAll("[data-cmd]").forEach((b) => {
      // mousedown + preventDefault keeps the text selection alive (a click
      // would blur the contenteditable and collapse it).
      b.addEventListener("mousedown", (e) => {
        e.preventDefault();
        exec(b.dataset.cmd);
      });
    });

    const linkRow = bar.querySelector(".bp-rte-linkrow");
    const urlInput = bar.querySelector(".bp-rte-url");

    bar.querySelector(".bp-rte-link").addEventListener("mousedown", (e) => {
      e.preventDefault();
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

    bar.querySelector(".bp-rte-set").addEventListener("mousedown", (e) => {
      e.preventDefault();
      apply();
    });
    urlInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        apply();
      } else if (e.key === "Escape") {
        linkRow.hidden = true;
        restore();
      }
    });
    bar.querySelector(".bp-rte-unset").addEventListener("mousedown", (e) => {
      e.preventDefault();
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
