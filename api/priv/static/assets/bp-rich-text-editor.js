// bp-rich-text-editor — Studio rich-text Web Component (Task #11 WI4 v1).
//
// Plain contenteditable with paste-as-plain-text. Emits a bubbling
// CustomEvent("bp-change", {detail: {value}}) on every input. The
// LiveView hook BarkparkFieldBridge (see root.html.heex) catches the
// bubbled event on the wrapper and mirrors detail.value into the
// sibling hidden input identified by data-bridge-target — Phoenix
// then debounces + serialises + pushes phx-change="autosave" exactly
// as it would for any native input.
//
// Contract: docs/studio/web-components.md
// v2 plan: replace document.execCommand("insertText") + plain
// contenteditable with a vendored ProseMirror/TipTap engine and add
// a setValue(v) channel for collaborative editing.

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
