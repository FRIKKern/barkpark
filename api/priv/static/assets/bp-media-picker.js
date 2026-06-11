// bp-media-picker — Studio image-field Web Component (Task #12 WI1).
//
// Wraps /media upload + the native mediaAsset library (bp-asset-browser).
// Emits bp-change with either a bare URL (legacy) or JSON {"url","assetId"}
// when an asset document is known.
//
// Two states, nothing else:
//   * empty    → ONE drop-target card ("No image selected…"); click or
//                Enter/Space opens the file dialog; Upload / Browse library
//                buttons sit underneath. No inline library grid — the
//                library lives exclusively in the Browse-library modal
//                (bp-asset-browser), so the field never shows unrelated
//                images at rest.
//   * selected → the picked image as a framed preview; drop a new file on
//                it to replace; Remove appears only in this state.
//
// The whole component is the drag-and-drop target (class `bp-mp-drag-over`
// while a file hovers). Remove/clear visibility is toggled via
// style.display, NOT the `hidden` attribute — the shadcn `.btn` class sets
// `display: inline-flex`, which (author CSS beats UA CSS) overrides
// `[hidden]` and used to leave a dead red Remove button visible on empty
// fields.

function bpParseMediaValue(raw) {
  if (!raw || typeof raw !== "string") return { url: "", assetId: "" };
  const trimmed = raw.trim();
  if (trimmed.startsWith("{")) {
    try {
      const o = JSON.parse(trimmed);
      return {
        url: o.url || "",
        assetId: o.assetId || o.id || ""
      };
    } catch (_e) {
      return { url: trimmed, assetId: "" };
    }
  }
  return { url: trimmed, assetId: "" };
}

function bpSerializeMediaValue(url, assetId) {
  if (assetId) return JSON.stringify({ url: url || "", assetId: assetId });
  return url || "";
}

class BpMediaPicker extends HTMLElement {
  constructor() {
    super();
    this._mounted = false;
    this._value = "";
    this._busy = false;
    this._meta = { url: "", assetId: "", alt: "", width: null, height: null, mime: "" };
  }

  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;

    const parsed = bpParseMediaValue(this.getAttribute("value") || "");
    const raw = this.getAttribute("value") || "";

    if (this._isReferenceMode()) {
      this._value = raw;
      this._meta.assetId = raw;
      this._meta.url = parsed.url;
      if (raw && !parsed.url) this._resolveReferencePreview(raw);
    } else {
      this._value = raw;
      this._meta.url = parsed.url;
      this._meta.assetId = parsed.assetId;
    }

    this._render();
  }

  async _resolveReferencePreview(docId) {
    if (!docId) return;
    const headers = { Accept: "application/json" };
    const tok = this._token();
    if (tok) headers["Authorization"] = "Bearer " + tok;
    try {
      const url =
        this._scopePrefix() +
        "/v1/data/doc/" +
        encodeURIComponent(this._dataset()) +
        "/mediaAsset/" +
        encodeURIComponent(docId);
      const r = await fetch(url, { credentials: "same-origin", headers: headers });
      if (!r.ok) return;
      const doc = await r.json();
      const fi = doc.fileInfo || {};
      this._meta.url = fi.url || "";
      this._meta.mime = fi.mimeType || "";
      this._renderPreview();
    } catch (_e) {
      /* preview optional */
    }
  }

  disconnectedCallback() {
    this._mounted = false;
  }

  get value() {
    return this._value;
  }

  set value(v) {
    if (v === this._value) return;
    this._value = v || "";
    if (this._isReferenceMode()) {
      this._meta.assetId = this._value;
      this._meta.url = "";
      if (this._value) this._resolveReferencePreview(this._value);
    } else {
      const parsed = bpParseMediaValue(this._value);
      this._meta.url = parsed.url;
      this._meta.assetId = parsed.assetId;
    }
    this._renderPreview();
  }

  get meta() {
    return Object.assign({}, this._meta);
  }

  _dataset() {
    return this.getAttribute("dataset") || "production";
  }

  // Scoped-surface URL prefix ("/w/<ws>/p/<proj>", tsk-url-p2). "" on the
  // flat surface keeps every fetch byte-identical to the legacy paths.
  _scopePrefix() {
    return this.getAttribute("scope-prefix") || "";
  }

  _token() {
    return this.getAttribute("data-token") || "";
  }

  _isReferenceMode() {
    return this.getAttribute("value-mode") === "reference";
  }

  _commitValue() {
    if (this._isReferenceMode()) {
      this._value = this._meta.assetId || "";
    } else {
      this._value = bpSerializeMediaValue(this._meta.url, this._meta.assetId);
    }
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
      "<span>Upload</span>" +
      '<input type="file" accept="image/*" hidden />' +
      "</label>" +
      '<button type="button" class="bp-mp-browse btn btn-sm">Browse library</button>' +
      '<button type="button" class="bp-mp-clear btn btn-destructive btn-sm">Remove</button>' +
      "</div>" +
      '<div class="bp-mp-error" role="alert"></div>';

    this._previewEl = this.querySelector(".bp-mp-preview");
    this._errorEl = this.querySelector(".bp-mp-error");
    this._fileInput = this.querySelector('input[type="file"]');
    this._clearBtn = this.querySelector(".bp-mp-clear");
    this._browseBtn = this.querySelector(".bp-mp-browse");

    this._fileInput.addEventListener("change", (e) => {
      const f = e.target.files && e.target.files[0];
      if (f) this._upload(f);
      e.target.value = "";
    });

    this._clearBtn.addEventListener("click", () => {
      this._value = "";
      this._meta = { url: "", assetId: "", alt: "", width: null, height: null, mime: "" };
      this._renderPreview();
      this._emit();
    });

    this._browseBtn.addEventListener("click", () => this._openBrowser());

    // Empty-state card = click/keyboard target for the file dialog.
    // Delegated once (the preview's innerHTML is replaced on every render).
    this._previewEl.addEventListener("click", (e) => {
      if (this._busy) return;
      if (e.target.closest(".bp-mp-empty")) this._fileInput.click();
    });
    this._previewEl.addEventListener("keydown", (e) => {
      if (this._busy) return;
      if ((e.key === "Enter" || e.key === " ") && e.target.closest(".bp-mp-empty")) {
        e.preventDefault();
        this._fileInput.click();
      }
    });

    // The whole component accepts a dropped image — empty OR selected
    // (drop replaces). dragenter/leave pair via a counter so child
    // elements don't flicker the highlight off.
    this._dragDepth = 0;
    this.addEventListener("dragover", (e) => {
      e.preventDefault();
    });
    this.addEventListener("dragenter", (e) => {
      e.preventDefault();
      this._dragDepth++;
      this.classList.add("bp-mp-drag-over");
    });
    this.addEventListener("dragleave", () => {
      this._dragDepth = Math.max(0, this._dragDepth - 1);
      if (this._dragDepth === 0) this.classList.remove("bp-mp-drag-over");
    });
    this.addEventListener("drop", (e) => {
      e.preventDefault();
      this._dragDepth = 0;
      this.classList.remove("bp-mp-drag-over");
      const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (f && (!f.type || f.type.indexOf("image/") === 0)) this._upload(f);
    });

    this._renderPreview();
  }

  _openBrowser() {
    const ensure = window.BpAssetBrowser && window.BpAssetBrowser.ensure;
    if (!ensure) return;
    const browser = ensure();
    browser.open({
      dataset: this._dataset(),
      token: this._token(),
      accept: "image/*",
      onSelect: (detail) => this._selectAsset(detail)
    });
  }

  _setClearVisible(visible) {
    // style.display, not [hidden] — see the header comment.
    if (this._clearBtn) this._clearBtn.style.display = visible ? "" : "none";
  }

  _setError(msg) {
    if (!this._errorEl) return;
    this._errorEl.textContent = msg || "";
    this._errorEl.style.display = msg ? "" : "none";
  }

  _setBusy(busy) {
    this._busy = busy;
    this.classList.toggle("bp-mp-busy", busy);
    this.setAttribute("aria-busy", busy ? "true" : "false");
    if (this._fileInput) this._fileInput.disabled = busy;
    if (this._browseBtn) this._browseBtn.disabled = busy;
    if (this._clearBtn) this._clearBtn.disabled = busy;
    this._renderPreview();
  }

  _renderPreview() {
    if (!this._previewEl) return;
    let url = this._meta.url || bpParseMediaValue(this._value).url;
    if (this._isReferenceMode() && !url && this._meta.assetId) {
      this._previewEl.innerHTML =
        '<div class="bp-mp-empty" role="button" tabindex="0">Asset ' +
        this._meta.assetId.replace(/</g, "") +
        "</div>";
      this._setClearVisible(true);
      return;
    }
    if (url) {
      const safeUrl = url.replace(/"/g, "&quot;");
      this._previewEl.innerHTML =
        '<img class="bp-mp-preview-img" src="' + safeUrl + '" alt="" />';
      // A dead asset URL must not collapse to an invisible sliver — swap in
      // an explicit broken-state card (Remove stays visible to clear it).
      this._previewEl.querySelector("img").addEventListener("error", () => {
        this._previewEl.innerHTML =
          '<div class="bp-mp-empty bp-mp-broken" role="button" tabindex="0" aria-label="Replace image">' +
          "Image unavailable — drop a file, or click to replace" +
          "</div>";
      });
      this._setClearVisible(true);
    } else {
      const label = this._busy ? "Uploading…" : "No image selected — drop a file, or click to upload";
      this._previewEl.innerHTML =
        '<div class="bp-mp-empty" role="button" tabindex="0" aria-label="Add image">' +
        label +
        "</div>";
      this._setClearVisible(false);
    }
  }

  _select(file) {
    this._meta = {
      url: file.url || "",
      assetId: file.assetId || "",
      alt: file.alt || "",
      width: file.width || null,
      height: file.height || null,
      mime: file.mime || file.mimeType || ""
    };
    this._commitValue();
    this._setError("");
    this._renderPreview();
    this._emit();
  }

  _selectAsset(detail) {
    if (!detail) return;
    this._select({
      url: detail.url,
      assetId: detail.id,
      mime: detail.mime,
      alt: detail.title || ""
    });
  }

  async _upload(file) {
    if (this._busy) return;
    const fd = new FormData();
    fd.append("file", file);
    fd.append("dataset", this._dataset());
    const headers = { Accept: "application/json" };
    const tok = this._token();
    if (tok) headers["Authorization"] = "Bearer " + tok;
    this._setError("");
    this._setBusy(true);
    try {
      // Scoped surface uploads through the scoped v1 mirror (the flat
      // /media/upload has no scoped twin); flat keeps the legacy path.
      const uploadUrl = this._scopePrefix()
        ? this._scopePrefix() + "/v1/media/" + encodeURIComponent(this._dataset()) + "/upload"
        : "/media/upload";
      const r = await fetch(uploadUrl, {
        method: "POST",
        headers: headers,
        body: fd,
        credentials: "same-origin"
      });
      if (!r.ok) {
        this._setError("Upload failed (" + r.status + ") — try again or pick from the library.");
        return;
      }
      const body = await r.json();
      // The scoped v1 mirror wraps the asset in {"result": …}; the flat
      // /media/upload returns it bare. Same field names either way.
      const data = body.result || body;
      this._select({
        url: data.url,
        mime: data.mimeType,
        assetId: data.assetDocId || "",
        alt: ""
      });
    } catch (_e) {
      this._setError("Upload failed — check your connection and try again.");
    } finally {
      this._setBusy(false);
    }
  }
}

customElements.define("bp-media-picker", BpMediaPicker);
