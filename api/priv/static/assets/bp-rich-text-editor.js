// bp-rich-text-editor — Studio rich-text Web Component (Task #11 WI4 v1).
//
// Contenteditable with paste-as-plain-text and a formatting toolbar:
// Bold, Italic, Underline, Strike, the block styles paragraph and H2 to H4,
// bullet and numbered lists, and Link (inline URL row, selection preserved
// across the focus hop). When the server stamps data-link-types, the link row
// also offers Internal: a bp-reference-picker over those types, whose pick
// links the text to "#internal:<id>" (task-088575052b459f3e); the server
// stores that as a linkAnnotation with an internalLink reference. The row
// also offers Email (a mailto: address) and File (an uploaded file from the
// media library, data-link-kind="dam" and data-file-name on the <a>), the
// query parameters of a document link (data-link-params) and the new-tab
// switch of an address link (data-new-tab) (task-025d7af119d6f0b8). These are the styles, lists and decorators Sanity's
// Portable Text editor offers for a body; the server turns the HTML into
// Portable Text (Barkpark.Content.PortableText). Emits a bubbling
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
    this._decorateBlocks();

    this._onInput = () => this._emit();
    this._editor.addEventListener("input", this._onInput);

    // A custom Portable Text block (a mediaModule, a quote) is a box the text
    // cannot edit. Clicking it, or Enter or Space on it, asks the host to open
    // its fields (task-19392d1e6fc661e6).
    this._onBlockClick = (e) => {
      const box = e.target.closest && e.target.closest(".bp-pt-block[data-pt-block]");
      if (!box || !this._editor.contains(box) || box.dataset.ptPending) return;
      e.preventDefault();
      this._openBlock(box);
    };
    this._onBlockKey = (e) => {
      const box = e.target.closest && e.target.closest(".bp-pt-block[data-pt-block]");
      if (!box || box.dataset.ptPending || (e.key !== "Enter" && e.key !== " ")) return;
      e.preventDefault();
      this._openBlock(box);
    };
    this._editor.addEventListener("click", this._onBlockClick);
    this._editor.addEventListener("keydown", this._onBlockKey);

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
    this._loadLinkTitles();
  }

  disconnectedCallback() {
    if (this._onSelection) document.removeEventListener("selectionchange", this._onSelection);
    if (this._editor) {
      if (this._onInput) this._editor.removeEventListener("input", this._onInput);
      if (this._onPaste) this._editor.removeEventListener("paste", this._onPaste);
      if (this._onBlockClick) this._editor.removeEventListener("click", this._onBlockClick);
      if (this._onBlockKey) this._editor.removeEventListener("keydown", this._onBlockKey);
    }
  }

  _emit() {
    this.dispatchEvent(
      new CustomEvent("bp-change", {
        bubbles: true,
        composed: false,
        detail: { value: this._serialize() }
      })
    );
  }

  // The editor HTML without the attributes the editor adds for display: a
  // link's document title (`_loadLinkTitles`) and what `_decorateBlocks` adds
  // to make a block box a button. A post carries the server's markup.
  _serialize() {
    if (!this._editor) return "";
    if (!this._editor.querySelector("[data-bp-title], .bp-pt-block[data-pt-decorated]")) return this._editor.innerHTML;
    const copy = this._editor.cloneNode(true);
    for (const a of copy.querySelectorAll("[data-bp-title]")) {
      a.removeAttribute("title");
      a.removeAttribute("data-bp-title");
    }
    copy.querySelectorAll(".bp-pt-block[data-pt-decorated]").forEach((b) => {
      ["tabindex", "role", "title", "aria-label", "data-pt-decorated"].forEach((a) => b.removeAttribute(a));
    });
    return copy.innerHTML;
  }

  _t(text) {
    let strings = {};
    try { strings = JSON.parse(this.getAttribute("data-strings") || "{}") || {}; } catch (_e) { strings = {}; }
    return typeof strings[text] === "string" ? strings[text] : text;
  }

  // Each block box becomes a button: focusable, named, and opened on Enter.
  _decorateBlocks() {
    if (!this._editor) return;
    this._editor.querySelectorAll(".bp-pt-block[data-pt-block]").forEach((b) => {
      if (b.dataset.ptPending) return;
      const label = this._t("Edit block") + ": " + (b.dataset.ptType || "");
      b.setAttribute("tabindex", "0");
      b.setAttribute("role", "button");
      b.setAttribute("title", label);
      b.setAttribute("aria-label", label);
      b.setAttribute("data-pt-decorated", "");
    });
  }

  _openBlock(box) {
    this.dispatchEvent(
      new CustomEvent("bp-pt-block-open", {
        bubbles: true,
        composed: false,
        detail: { key: box.dataset.ptBlock, type: box.dataset.ptType, html: this._serialize() }
      })
    );
  }

  // "Insert block": a placeholder box goes after the block the caret is in,
  // and the host asks the server for the new block. The placeholder names no
  // stored block, so a post that races the answer adds nothing for it.
  _insertBlock(type) {
    if (!this._editor) return;
    this._pendingSeq = (this._pendingSeq || 0) + 1;
    const pending = "p" + Date.now().toString(36) + this._pendingSeq;
    const ph = document.createElement("div");
    ph.className = "bp-pt-block bp-pt-pending";
    ph.setAttribute("contenteditable", "false");
    ph.setAttribute("data-pt-block", "__pending-" + pending);
    ph.setAttribute("data-pt-pending", pending);
    ph.textContent = this._t("Inserting block…");

    let anchor = null;
    const range = this._lastRange;
    if (range && this._editor.contains(range.startContainer)) {
      anchor = range.startContainer;
      while (anchor && anchor.parentNode !== this._editor) anchor = anchor.parentNode;
    }
    if (anchor && anchor.nextSibling) this._editor.insertBefore(ph, anchor.nextSibling);
    else this._editor.appendChild(ph);

    this.dispatchEvent(
      new CustomEvent("bp-pt-block-insert", {
        bubbles: true,
        composed: false,
        detail: { type, pending, html: this._serialize() }
      })
    );
  }

  _boxFrom(html) {
    const tmp = document.createElement("div");
    tmp.innerHTML = html || "";
    return tmp.firstElementChild;
  }

  // The server's answer to `_insertBlock`: the new block's box (or nothing,
  // when the server refused) takes the placeholder's place.
  ptBlockReady(pending, key, html) {
    if (!this._editor) return;
    const ph = this._editor.querySelector('[data-pt-pending="' + CSS.escape(pending) + '"]');
    if (!ph) return;
    const box = key ? this._boxFrom(html) : null;
    if (box) ph.replaceWith(box);
    else ph.remove();
    this._decorateBlocks();
    this._emit();
  }

  // A saved block's box shows its new summary.
  ptBlockUpdate(key, html) {
    if (!this._editor) return;
    const old = this._editor.querySelector('.bp-pt-block[data-pt-block="' + CSS.escape(key) + '"]');
    const box = this._boxFrom(html);
    if (old && box) {
      old.replaceWith(box);
      this._decorateBlocks();
    }
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
    // The document types an internal link may point at, stamped by the server
    // (data-link-types, comma-joined). None: the link row takes an address only.
    const linkTypes = (this.getAttribute("data-link-types") || "")
      .split(",")
      .map((x) => x.trim())
      .filter(Boolean);
    this._linkTypes = linkTypes;
    // Each glyph button is named by its word: the glyph alone read "B, button".
    bar.innerHTML =
      '<button type="button" class="bp-rte-btn" data-cmd="bold" title="' + t("Bold (mod+B)") + '" aria-label="' + t("Bold") + '"><b aria-hidden="true">B</b></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="italic" title="' + t("Italic (mod+I)") + '" aria-label="' + t("Italic") + '"><i aria-hidden="true">I</i></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="underline" title="' + t("Underline") + '" aria-label="' + t("Underline") + '"><u aria-hidden="true">U</u></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="strikeThrough" title="' + t("Strikethrough") + '" aria-label="' + t("Strikethrough") + '"><s aria-hidden="true">S</s></button>' +
      '<span class="bp-rte-sep" aria-hidden="true"></span>' +
      '<button type="button" class="bp-rte-btn" data-cmd="formatBlock" data-arg="p" title="' + t("Paragraph") + '" aria-label="' + t("Paragraph") + '"><span aria-hidden="true">¶</span></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="formatBlock" data-arg="h2" title="' + t("Heading 2") + '" aria-label="' + t("Heading 2") + '"><span aria-hidden="true">H2</span></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="formatBlock" data-arg="h3" title="' + t("Heading 3") + '" aria-label="' + t("Heading 3") + '"><span aria-hidden="true">H3</span></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="formatBlock" data-arg="h4" title="' + t("Heading 4") + '" aria-label="' + t("Heading 4") + '"><span aria-hidden="true">H4</span></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="insertUnorderedList" title="' + t("Bulleted list") + '" aria-label="' + t("Bulleted list") + '"><span aria-hidden="true">•</span></button>' +
      '<button type="button" class="bp-rte-btn" data-cmd="insertOrderedList" title="' + t("Numbered list") + '" aria-label="' + t("Numbered list") + '"><span aria-hidden="true">1.</span></button>' +
      '<span class="bp-rte-sep" aria-hidden="true"></span>' +
      '<button type="button" class="bp-rte-btn bp-rte-link" title="' + t("Link") + '" aria-label="' + t("Link") + '"><span aria-hidden="true">🔗</span></button>' +
      '<span class="bp-rte-linkrow' + (linkTypes.length ? " bp-rte-linkrow-kinds" : "") + '" hidden>' +
      (linkTypes.length
        ? '<span class="bp-rte-kinds" role="group" aria-label="' + t("Link type") + '">' +
          '<button type="button" class="bp-rte-btn bp-rte-kind" data-kind="internal" aria-pressed="true">' + t("Internal") + "</button>" +
          '<button type="button" class="bp-rte-btn bp-rte-kind" data-kind="external" aria-pressed="false">' + t("External") + "</button>" +
          '<button type="button" class="bp-rte-btn bp-rte-kind" data-kind="email" aria-pressed="false">' + t("Email") + "</button>" +
          '<button type="button" class="bp-rte-btn bp-rte-kind" data-kind="file" aria-pressed="false">' + t("File (DAM)") + "</button>" +
          "</span>" +
          '<span class="bp-rte-internal"></span>' +
          '<span class="bp-rte-params-box">' +
          '<input type="text" class="bp-rte-field bp-rte-params" placeholder="tags=a,b&amp;sort=name-asc" aria-label="' + t("Filters / parameters (optional)") + '" title="' + t("Filters / parameters (optional)") + '" />' +
          "</span>"
        : "") +
      '<span class="bp-rte-external">' +
      '<input type="text" class="bp-rte-url" placeholder="https://…" aria-label="' + t("Link address") + '" />' +
      '<button type="button" class="bp-rte-btn bp-rte-set">' + t("Set") + "</button>" +
      (linkTypes.length
        ? '<label class="bp-rte-newtab"><input type="checkbox" class="bp-rte-newtab-box" /> ' + t("Open in new tab") + "</label>"
        : "") +
      "</span>" +
      (linkTypes.length
        ? '<span class="bp-rte-email" hidden>' +
          '<input type="email" class="bp-rte-field bp-rte-email-input" placeholder="name@example.com" aria-label="' + t("Email address") + '" />' +
          '<button type="button" class="bp-rte-btn bp-rte-email-set">' + t("Set") + "</button>" +
          "</span>" +
          '<span class="bp-rte-file" hidden>' +
          '<span class="bp-rte-file-name" data-empty="' + t("No file chosen") + '"></span>' +
          '<button type="button" class="bp-rte-btn bp-rte-file-pick">' + t("Choose file") + "</button>" +
          "</span>"
        : "") +
      '<button type="button" class="bp-rte-btn bp-rte-unset">' + t("Remove") + "</button>" +
      "</span>";
    // The custom blocks the field declares (`blocks.of`), as an "Insert block"
    // menu (task-19392d1e6fc661e6). No declared block, no menu.
    let blockTypes = [];
    try { blockTypes = JSON.parse(this.getAttribute("data-block-types") || "[]") || []; } catch (_e) { blockTypes = []; }
    if (Array.isArray(blockTypes) && blockTypes.length) {
      const esc = (v) => String(v).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
      bar.insertAdjacentHTML(
        "beforeend",
        '<span class="bp-rte-sep" aria-hidden="true"></span>' +
        '<select class="bp-rte-insert" aria-label="' + t("Insert block") + '">' +
        '<option value="">' + t("Insert block…") + "</option>" +
        blockTypes.map((b) => '<option value="' + esc(b.name) + '">' + esc(b.title || b.name) + "</option>").join("") +
        "</select>"
      );
    }
    this.appendChild(bar);
    const insertMenu = bar.querySelector(".bp-rte-insert");
    if (insertMenu) {
      // The menu keeps the caret the author left in the text (`_lastRange`).
      insertMenu.addEventListener("change", (e) => {
        e.stopPropagation();
        const type = insertMenu.value;
        insertMenu.value = "";
        if (type) this._insertBlock(type);
      });
      insertMenu.addEventListener("input", (e) => e.stopPropagation());
    }

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
        exec(b.dataset.cmd, b.dataset.arg);
      });
    });

    const linkRow = bar.querySelector(".bp-rte-linkrow");
    const urlInput = bar.querySelector(".bp-rte-url");
    const externalBox = bar.querySelector(".bp-rte-external");
    const internalBox = bar.querySelector(".bp-rte-internal");
    const kindButtons = Array.from(bar.querySelectorAll(".bp-rte-kind"));
    const paramsBox = bar.querySelector(".bp-rte-params-box");
    const paramsInput = bar.querySelector(".bp-rte-params");
    const newTabBox = bar.querySelector(".bp-rte-newtab-box");
    const emailBox = bar.querySelector(".bp-rte-email");
    const emailInput = bar.querySelector(".bp-rte-email-input");
    const fileBox = bar.querySelector(".bp-rte-file");
    const fileName = bar.querySelector(".bp-rte-file-name");
    // What the author changed in this opening of the row: an untouched
    // parameter box or new-tab switch writes nothing, so a stored value stays
    // as it is (task-025d7af119d6f0b8).
    let paramsTouched = false;
    let newTabTouched = false;

    // The link row's own controls are not fields of the document. Their input
    // and change events stop here: reaching the editor form, they posted
    // phx-change="autosave" (task-32d983d47299e137). The document picker's
    // bp-change stops too, or the field bridge would write a document id over
    // the body.
    for (const type of ["input", "change", "bp-change"]) {
      linkRow.addEventListener(type, (e) => e.stopPropagation());
    }

    const close = () => {
      linkRow.hidden = true;
      if (internalBox) internalBox.replaceChildren();
      this._editAnchor = null;
    };

    // Internal: a document picker over the declared types and the list
    // page's parameters. External: the address box and the new-tab switch.
    // Email: an address box. File: a file from the media library.
    const showKind = (kind) => {
      for (const b of kindButtons) b.setAttribute("aria-pressed", String(b.dataset.kind === kind));
      if (internalBox) internalBox.hidden = kind !== "internal";
      if (paramsBox) paramsBox.hidden = kind !== "internal";
      externalBox.hidden = linkTypes.length ? kind !== "external" : false;
      if (emailBox) emailBox.hidden = kind !== "email";
      if (fileBox) fileBox.hidden = kind !== "file";
    };

    // The kind of link an <a> is: a file link carries data-link-kind="dam".
    const kindOf = (a) => {
      const href = a ? a.getAttribute("href") || "" : "";
      if (!a) return "internal";
      if (a.getAttribute("data-link-kind") === "dam") return "file";
      if (href.startsWith("#internal:")) return "internal";
      if (/^mailto:/i.test(href)) return "email";
      return "external";
    };

    // A pasted list page address keeps only its query: "https://site/list?a=1"
    // and "?a=1" both read "a=1", as Sanity's parameter input does.
    const cleanParams = (v) => {
      const raw = String(v || "").trim();
      const q = raw.indexOf("?");
      return (q >= 0 ? raw.slice(q + 1) : raw).replace(/^[?&]+/, "");
    };

    const showFile = (name) => {
      if (!fileName) return;
      fileName.textContent = name || fileName.getAttribute("data-empty") || "";
      fileName.classList.toggle("bp-rte-file-empty", !name);
    };

    // The attributes beside the address that a link of `kind` carries. A null
    // value removes the attribute. `anchor` is the link being edited, if any.
    const extraAttrs = (kind, anchor, opts) => {
      opts = opts || {};
      const attrs = { "data-link-kind": null, "data-file-name": null };
      if (kind !== "internal") attrs["data-link-params"] = null;
      if (kind === "internal" && paramsInput) {
        const params = cleanParams(paramsInput.value);
        if (paramsTouched) {
          // An emptied box on a link that had parameters clears them.
          attrs["data-link-params"] = params || (anchor && anchor.hasAttribute("data-link-params") ? "" : null);
        } else if (opts.retarget) {
          // The parameters of the old document go with it.
          attrs["data-link-params"] = null;
        } else if (!anchor && params) {
          attrs["data-link-params"] = params;
        }
      }
      if (kind === "external" && newTabBox && (newTabTouched || !anchor)) {
        attrs["data-new-tab"] = String(newTabBox.checked);
      }
      if (kind === "file") {
        attrs["data-link-kind"] = "dam";
        attrs["data-file-name"] = opts.fileName || null;
      }
      return attrs;
    };

    const setAttrs = (a, attrs) => {
      for (const [name, value] of Object.entries(attrs || {})) {
        if (value === undefined) continue;
        if (value === null) a.removeAttribute(name);
        else a.setAttribute(name, value);
      }
    };

    // A fresh picker per opening, holding the link's current target.
    const mountPicker = (id) => {
      if (!internalBox) return null;
      internalBox.replaceChildren();
      const picker = document.createElement("bp-reference-picker");
      picker.setAttribute("ref-type", linkTypes.join(","));
      picker.setAttribute("dataset", this.getAttribute("dataset") || "production");
      picker.setAttribute("scope-prefix", this.getAttribute("scope-prefix") || "");
      picker.setAttribute("data-field-label", t("Link to a document"));
      const pickerStrings = this.getAttribute("data-picker-strings");
      if (pickerStrings) picker.setAttribute("data-strings", pickerStrings);
      if (id) picker.setAttribute("value", id);
      picker.addEventListener("bp-change", (e) => {
        const value = e.detail && e.detail.value;
        if (!value) return;
        const title = picker.querySelector(".ref-selected-title");
        const anchor = this._editAnchor;
        const before = anchor ? anchor.getAttribute("href") || "" : "";
        const href = "#internal:" + value;
        const retarget = before.startsWith("#internal:") && before !== href;
        apply(href, title ? title.textContent : "", extraAttrs("internal", anchor, { retarget }));
      });
      internalBox.appendChild(picker);
      return picker;
    };

    press(bar.querySelector(".bp-rte-link"), () => {
      if (!linkRow.hidden) {
        close();
        return;
      }
      reselect();
      // Save the selection — focusing the URL input destroys it.
      const sel = window.getSelection();
      this._savedRange =
        sel && sel.rangeCount > 0 ? sel.getRangeAt(0).cloneRange() : null;
      const a = this._anchorAtSelection();
      this._editAnchor = a;
      const href = a ? a.getAttribute("href") || "" : "";
      const internalId = href.startsWith("#internal:") ? href.slice("#internal:".length) : "";
      linkRow.hidden = false;
      paramsTouched = false;
      newTabTouched = false;
      if (!linkTypes.length) {
        urlInput.value = href;
        urlInput.focus();
        return;
      }
      const kind = kindOf(a);
      urlInput.value = kind === "external" ? href : "";
      if (paramsInput) paramsInput.value = (kind === "internal" && a && a.getAttribute("data-link-params")) || "";
      // A new address link opens in a new tab, Sanity's initial value; a
      // stored one shows what it holds.
      if (newTabBox) newTabBox.checked = a && kind === "external" ? a.getAttribute("data-new-tab") === "true" : true;
      if (emailInput) emailInput.value = kind === "email" ? href.replace(/^mailto:/i, "") : "";
      showFile(kind === "file" ? a.getAttribute("data-file-name") || href : "");
      showKind(kind);
      if (kind === "internal") {
        const picker = mountPicker(internalId);
        const focusTarget = picker && (picker.querySelector(".bp-ref-search-input") || picker.querySelector("button"));
        if (focusTarget) focusTarget.focus();
      } else if (kind === "email") {
        emailInput.focus();
      } else if (kind === "file") {
        bar.querySelector(".bp-rte-file-pick").focus();
      } else {
        urlInput.focus();
      }
    });

    for (const b of kindButtons) {
      press(b, () => {
        showKind(b.dataset.kind);
        if (b.dataset.kind === "internal") {
          const picker = internalBox.querySelector("bp-reference-picker") || mountPicker("");
          const input = picker && picker.querySelector(".bp-ref-search-input");
          if (input) input.focus();
        } else if (b.dataset.kind === "email") {
          emailInput.focus();
        } else if (b.dataset.kind === "file") {
          bar.querySelector(".bp-rte-file-pick").focus();
        } else {
          urlInput.focus();
        }
      });
    }

    const restore = () => {
      if (!this._savedRange) return;
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(this._savedRange);
    };

    // An existing link takes the new target in place, so a caret inside it is
    // enough; a selection becomes a new link.
    // `attrs` are the link row's fields beside the address (extraAttrs).
    const apply = (href, title, attrs) => {
      const anchor = this._editAnchor;
      if (anchor && this._editor.contains(anchor)) {
        anchor.setAttribute("href", href);
        setAttrs(anchor, attrs);
        this._paintTitle(anchor, title);
        close();
        this._emit();
        return;
      }
      restore();
      const before = new Set(this._editor.querySelectorAll("a"));
      exec("createLink", href);
      const created = Array.from(this._editor.querySelectorAll("a")).filter(
        (a) => !before.has(a) && a.getAttribute("href") === href
      );
      for (const a of created) setAttrs(a, attrs);
      if (title) {
        for (const a of this._editor.querySelectorAll("a")) {
          if (a.getAttribute("href") === href && !a.hasAttribute("title")) this._paintTitle(a, title);
        }
      }
      if (created.length && attrs) this._emit();
      close();
    };

    const applyUrl = () => {
      const href = urlInput.value.trim();
      if (href === "") {
        close();
        return;
      }
      // Normalize bare domains so the anchor never becomes relative.
      const full = /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("#") ? href : "https://" + href;
      if (!linkTypes.length) {
        apply(full, "");
        return;
      }
      // An address typed as mailto: is an email link.
      const kind = /^mailto:/i.test(full) ? "email" : "external";
      apply(full, "", extraAttrs(kind, this._editAnchor));
    };

    // An email link: the address as mailto:, the shape Sanity stores as
    // linkType email.
    const applyEmail = () => {
      const email = emailInput.value.trim().replace(/^mailto:/i, "");
      if (email === "") {
        close();
        return;
      }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        emailInput.setAttribute("aria-invalid", "true");
        emailInput.focus();
        return;
      }
      emailInput.removeAttribute("aria-invalid");
      apply("mailto:" + email, "", extraAttrs("email", this._editAnchor));
    };

    press(bar.querySelector(".bp-rte-set"), applyUrl);

    if (emailBox) {
      press(bar.querySelector(".bp-rte-email-set"), applyEmail);
      emailInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          applyEmail();
        }
      });
      emailInput.addEventListener("input", () => emailInput.removeAttribute("aria-invalid"));
    }

    // A file link: the media library (bp-asset-browser) over every kind of
    // upload; a pick links the text to the file's address and names it.
    if (fileBox) {
      press(bar.querySelector(".bp-rte-file-pick"), () => {
        const ensure = window.BpAssetBrowser && window.BpAssetBrowser.ensure;
        if (!ensure) return;
        let mediaStrings = null;
        try { mediaStrings = JSON.parse(this.getAttribute("data-media-strings") || "null"); } catch (_e) { mediaStrings = null; }
        ensure().open({
          dataset: this.getAttribute("dataset") || "production",
          token: this.getAttribute("data-token") || "",
          scopePrefix: this.getAttribute("scope-prefix") || "",
          accept: "*/*",
          strings: mediaStrings,
          onSelect: (detail) => {
            const url = detail && detail.url;
            if (!url) return;
            const info = (detail.asset && detail.asset.fileInfo) || {};
            const name = info.originalName || detail.title || "";
            showFile(name);
            apply(url, "", extraAttrs("file", this._editAnchor, { fileName: name }));
          }
        });
      });
    }

    // On a link already in the text, the parameter box and the new-tab switch
    // take effect as they change; on a new link they ride with its target.
    if (paramsInput) {
      const commitParams = () => {
        paramsInput.value = cleanParams(paramsInput.value);
        const a = this._editAnchor;
        if (!paramsTouched || !a || !this._editor.contains(a) || kindOf(a) !== "internal") return;
        setAttrs(a, { "data-link-params": extraAttrs("internal", a)["data-link-params"] });
        this._emit();
      };
      paramsInput.addEventListener("input", () => { paramsTouched = true; });
      paramsInput.addEventListener("change", commitParams);
      paramsInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          commitParams();
        }
      });
    }
    if (newTabBox) {
      newTabBox.addEventListener("change", () => {
        newTabTouched = true;
        const a = this._editAnchor;
        if (!a || !this._editor.contains(a) || kindOf(a) !== "external") return;
        a.setAttribute("data-new-tab", String(newTabBox.checked));
        this._emit();
      });
    }
    urlInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        applyUrl();
      } else if (e.key === "Escape") {
        close();
        restore();
      }
    });
    linkRow.addEventListener("keydown", (e) => {
      // The picker's search keeps its own Escape (close the list, cancel a Change).
      const inPicker = e.target.closest && e.target.closest("bp-reference-picker");
      if (e.key === "Escape" && e.target !== urlInput && !inPicker) {
        close();
        restore();
      }
    });
    press(bar.querySelector(".bp-rte-unset"), () => {
      restore();
      exec("unlink");
      close();
    });
  }

  // An internal link (#internal:<id>) reads as its target's title on hover.
  // The title is the editor's view only: _html() leaves it out of the value.
  _paintTitle(anchor, title) {
    if (title) {
      anchor.setAttribute("title", title);
      anchor.setAttribute("data-bp-title", "");
    } else if (anchor.hasAttribute("data-bp-title")) {
      anchor.removeAttribute("title");
      anchor.removeAttribute("data-bp-title");
    }
  }

  // The titles of the documents the internal links name, in one GROQ read on
  // the scoped query endpoint (the one the reference picker filters through).
  async _loadLinkTitles() {
    const anchors = Array.from(this._editor.querySelectorAll('a[href^="#internal:"]'));
    const ids = [...new Set(anchors.map((a) => a.getAttribute("href").slice("#internal:".length)).filter(Boolean))];
    if (!ids.length || typeof fetch !== "function") return;
    const params = new URLSearchParams({
      query: "*[_id in $ids]{_id, title}",
      perspective: "raw",
      returnQuery: "false"
    });
    params.set("$ids", JSON.stringify(ids.concat(ids.map((id) => "drafts." + id))));
    const url =
      (this.getAttribute("scope-prefix") || "") +
      "/v2025-02-19/data/query/" +
      encodeURIComponent(this.getAttribute("dataset") || "production") +
      "?" +
      params.toString();
    try {
      const res = await fetch(url, { credentials: "same-origin" });
      if (!res.ok) return;
      const body = await res.json();
      const titles = {};
      for (const doc of Array.isArray(body.result) ? body.result : []) {
        const id = String(doc._id || "").replace(/^drafts\./, "");
        // The draft's title wins: it is what the editor sees on the desk.
        if (doc.title && (!titles[id] || String(doc._id).startsWith("drafts."))) titles[id] = doc.title;
      }
      for (const a of anchors) {
        const title = titles[a.getAttribute("href").slice("#internal:".length)];
        if (title && !a.hasAttribute("title")) this._paintTitle(a, title);
      }
    } catch (_e) {
      /* the link keeps no title */
    }
  }

  // The editor's HTML without the titles _paintTitle added.
  _html() {
    return this._serialize();
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
    return this._serialize();
  }

  set value(v) {
    if (this._editor && this._html() !== v) {
      this._editor.innerHTML = v;
      this._loadLinkTitles();
    }
  }
}

customElements.define("bp-rich-text-editor", BpRichTextEditor);
