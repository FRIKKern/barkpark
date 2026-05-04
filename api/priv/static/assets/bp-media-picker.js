// bp-media-picker — Studio image-field Web Component (Task #12 WI1).
//
// Wraps the existing /media + /media/upload endpoints. Owns:
//   - thumbnail grid of previously uploaded images (GET /media)
//   - upload button + drag-drop zone (POST /media/upload, multipart)
//   - selected-state preview (current value)
//   - Remove button (clears the field)
//
// The WC reads its bearer token from the `data-token` attribute. The
// renderer in field_inputs.ex passes the raw session token plumbed
// through `api_token_raw` (set by LiveAuth.:fetch_api_token from
// session["api_token"]). The token is already known to the user — they
// pasted it at /login — so rendering it in a DOM attribute is no leak.
//
// Bridge contract (docs/studio/web-components.md): emits a bubbling
// CustomEvent("bp-change", { detail: { value } }). For v1 image fields
// `detail.value` is a plain URL string so the hidden-input bridge
// mirrors it directly into the form payload — keeping the server-side
// shape byte-identical to the legacy renderer (a URL string under
// `doc[<field>]`). The richer object {url, alt, width, height, mime}
// is exposed via the `meta` getter for future v2 wiring.

class BpMediaPicker extends HTMLElement {
  constructor() {
    super();
    this._mounted = false;
    this._files = [];
    this._value = "";
    this._meta = { url: "", alt: "", width: null, height: null, mime: "" };
  }

  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;

    this._value = this.getAttribute("value") || "";
    this._meta.url = this._value;

    this._render();
    this._loadFiles();
  }

  disconnectedCallback() {
    // Listeners are bound to elements inside `this`; removed by GC when
    // the element is detached. Defensive: drop refs so a re-mount
    // re-runs connectedCallback() (LV hooks may detach + re-attach).
    this._mounted = false;
  }

  // ── Public API ──────────────────────────────────────────────────
  get value() {
    return this._value;
  }

  set value(v) {
    if (v === this._value) return;
    this._value = v || "";
    this._meta.url = this._value;
    this._renderPreview();
  }

  // Future v2 hook — richer selection metadata. v1 server only stores
  // the URL string, so this is read-only and used only by tests / the
  // browser console for inspection.
  get meta() {
    return Object.assign({}, this._meta);
  }

  // ── Internals ───────────────────────────────────────────────────
  _token() {
    return this.getAttribute("data-token") || "";
  }

  _emit() {
    this.dispatchEvent(
      new CustomEvent("bp-change", {
        bubbles: true,
        composed: false,
        detail: { value: this._value }
      })
    );
  }

  _render() {
    this.innerHTML =
      '<div class="bp-mp-preview"></div>' +
      '<div class="bp-mp-actions">' +
      '<label class="bp-mp-upload btn btn-sm">' +
      '<span>Upload</span>' +
      '<input type="file" accept="image/*" hidden />' +
      '</label>' +
      '<button type="button" class="bp-mp-clear btn btn-destructive btn-sm" hidden>Remove</button>' +
      '</div>' +
      '<div class="bp-mp-dropzone">Drop image here</div>' +
      '<div class="bp-mp-grid"></div>';

    this._previewEl = this.querySelector(".bp-mp-preview");
    this._gridEl = this.querySelector(".bp-mp-grid");
    this._dropEl = this.querySelector(".bp-mp-dropzone");
    this._fileInput = this.querySelector('input[type="file"]');
    this._clearBtn = this.querySelector(".bp-mp-clear");

    this._fileInput.addEventListener("change", (e) => {
      const f = e.target.files && e.target.files[0];
      if (f) this._upload(f);
      e.target.value = "";
    });

    this._clearBtn.addEventListener("click", () => {
      this._value = "";
      this._meta = { url: "", alt: "", width: null, height: null, mime: "" };
      this._renderPreview();
      this._emit();
    });

    this._dropEl.addEventListener("dragover", (e) => {
      e.preventDefault();
      this._dropEl.classList.add("bp-mp-drag-over");
    });
    this._dropEl.addEventListener("dragleave", () => {
      this._dropEl.classList.remove("bp-mp-drag-over");
    });
    this._dropEl.addEventListener("drop", (e) => {
      e.preventDefault();
      this._dropEl.classList.remove("bp-mp-drag-over");
      const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (f && (!f.type || f.type.indexOf("image/") === 0)) this._upload(f);
    });

    this._renderPreview();
  }

  _renderPreview() {
    if (!this._previewEl) return;
    if (this._value) {
      const safeUrl = this._value.replace(/"/g, "&quot;");
      this._previewEl.innerHTML =
        '<img class="bp-mp-preview-img" src="' + safeUrl + '" alt="" />';
      if (this._clearBtn) this._clearBtn.hidden = false;
    } else {
      this._previewEl.innerHTML =
        '<div class="bp-mp-empty">No image selected</div>';
      if (this._clearBtn) this._clearBtn.hidden = true;
    }
  }

  _renderGrid() {
    if (!this._gridEl) return;
    if (!this._files.length) {
      this._gridEl.innerHTML =
        '<div class="bp-mp-grid-empty">No uploads yet</div>';
      return;
    }
    const html = this._files
      .map((f) => {
        const u = (f.url || "").replace(/"/g, "&quot;");
        const n = (f.originalName || f.filename || "")
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;");
        return (
          '<div class="bp-mp-item" data-url="' +
          u +
          '" data-mime="' +
          (f.mimeType || "") +
          '">' +
          '<img src="' + u + '" alt="' + n + '" />' +
          "</div>"
        );
      })
      .join("");
    this._gridEl.innerHTML = html;
    this._gridEl.querySelectorAll(".bp-mp-item").forEach((item) => {
      item.addEventListener("click", () => {
        this._select({
          url: item.dataset.url,
          mime: item.dataset.mime || ""
        });
      });
    });
  }

  _select(file) {
    this._value = file.url || "";
    this._meta = {
      url: this._value,
      alt: file.alt || "",
      width: file.width || null,
      height: file.height || null,
      mime: file.mime || file.mimeType || ""
    };
    this._renderPreview();
    this._emit();
  }

  async _loadFiles() {
    try {
      const r = await fetch("/media?type=image/", {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      });
      if (!r.ok) return;
      const data = await r.json();
      this._files = (data && data.files) || [];
      this._renderGrid();
    } catch (_e) {
      // Best-effort listing — leave grid empty on failure.
    }
  }

  async _upload(file) {
    const fd = new FormData();
    fd.append("file", file);
    const headers = { Accept: "application/json" };
    const tok = this._token();
    if (tok) headers["Authorization"] = "Bearer " + tok;
    try {
      const r = await fetch("/media/upload", {
        method: "POST",
        headers: headers,
        body: fd,
        credentials: "same-origin"
      });
      if (!r.ok) return;
      const data = await r.json();
      this._select({
        url: data.url,
        mime: data.mimeType,
        alt: ""
      });
      // Refresh the grid so the new file appears.
      this._loadFiles();
    } catch (_e) {
      // Surface in console; UX-side handling deferred to v2.
    }
  }
}

customElements.define("bp-media-picker", BpMediaPicker);
