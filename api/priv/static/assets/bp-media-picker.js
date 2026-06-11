// bp-media-picker — Studio image-field Web Component (Task #12 WI1).
//
// Wraps /v1/media search + /media/upload and the native mediaAsset library
// (bp-asset-browser). Emits bp-change with either a bare URL (legacy)
// or JSON {"url","assetId"} when an asset document is known.

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
    this._files = [];
    this._value = "";
    this._meta = { url: "", assetId: "", alt: "", width: null, height: null, mime: "" };
    this._searchIntel = { clientId: null, parentEventId: null };
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
    this._loadFiles();
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

  _searchHeaders(json, opts) {
    opts = opts || {};
    if (!this._searchIntel.clientId) {
      this._searchIntel.clientId = BpSearchIntel.clientId("media", this._dataset());
    }
    const tok = this._token();
    return BpSearchIntel.searchHeaders(this._searchIntel, {
      contentType: !!json,
      authorization: tok ? "Bearer " + tok : undefined,
      source: "media-picker",
      record: opts.record
    });
  }

  _recordSearchInteraction(objectId, position) {
    BpSearchIntel.trackInteraction(
      "media",
      this._dataset(),
      this._searchIntel,
      objectId,
      position,
      {
        source: "media-picker",
        authorization: this._token() ? "Bearer " + this._token() : undefined
      }
    );
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
      '<button type="button" class="bp-mp-clear btn btn-destructive btn-sm" hidden>Remove</button>' +
      "</div>" +
      '<div class="bp-mp-dropzone">Drop image here</div>' +
      '<div class="bp-mp-grid"></div>';

    this._previewEl = this.querySelector(".bp-mp-preview");
    this._gridEl = this.querySelector(".bp-mp-grid");
    this._dropEl = this.querySelector(".bp-mp-dropzone");
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

  _renderPreview() {
    if (!this._previewEl) return;
    let url = this._meta.url || bpParseMediaValue(this._value).url;
    if (this._isReferenceMode() && !url && this._meta.assetId) {
      this._previewEl.innerHTML =
        '<div class="bp-mp-empty">Asset ' + this._meta.assetId.replace(/</g, "") + "</div>";
      if (this._clearBtn) this._clearBtn.hidden = false;
      return;
    }
    if (url) {
      const safeUrl = url.replace(/"/g, "&quot;");
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
        '<div class="bp-mp-grid-empty">No uploads yet — try Browse library</div>';
      return;
    }
    const html = this._files
      .map((f, idx) => {
        const u = (f.url || "").replace(/"/g, "&quot;");
        const n = (f.originalName || f.filename || "")
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;");
        const aid = (f.assetDocId || "").replace(/"/g, "&quot;");
        return (
          '<div class="bp-mp-item" data-index="' +
          idx +
          '" data-url="' +
          u +
          '" data-mime="' +
          (f.mimeType || "") +
          '" data-asset-id="' +
          aid +
          '">' +
          '<img src="' +
          u +
          '" alt="' +
          n +
          '" />' +
          "</div>"
        );
      })
      .join("");
    this._gridEl.innerHTML = html;
    this._gridEl.querySelectorAll(".bp-mp-item").forEach((item) => {
      item.addEventListener("click", () => {
        const idx = parseInt(item.dataset.index, 10);
        const assetId = item.dataset.assetId || "";
        this._recordSearchInteraction(assetId, isNaN(idx) ? null : idx);
        this._select({
          url: item.dataset.url,
          mime: item.dataset.mime || "",
          assetId: item.dataset.assetId || ""
        });
      });
    });
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

  async _loadFiles() {
    const dataset = this._dataset();
    const params = new URLSearchParams({
      limit: "50",
      offset: "0",
      sort: "created-desc"
    });
    params.set("facet.kind", "image");

    try {
      const r = await fetch(
        this._scopePrefix() + "/v1/media/" + encodeURIComponent(dataset) + "/search?" + params.toString(),
        {
          credentials: "same-origin",
          headers: this._searchHeaders(false, { record: true })
        }
      );
      if (!r.ok) return;
      const data = await r.json();
      if (data && data.searchEventId) BpSearchIntel.captureEventId(this._searchIntel, data);
      const hits = (data && data.result && data.result.hits) || [];
      this._files = hits
        .map((hit) => ({
          url: hit.thumbnailUrl || hit.previewUrl || hit.originalUrl || hit.url || "",
          originalName: hit.originalName || hit.filename,
          filename: hit.filename,
          mimeType: hit.mimeType,
          assetDocId: hit.assetDocId || (hit.asset && hit.asset._id) || ""
        }))
        .filter((f) => f.url);
      this._renderGrid();
    } catch (_e) {
      // Best-effort listing — leave grid empty on failure.
    }
  }

  async _upload(file) {
    const fd = new FormData();
    fd.append("file", file);
    fd.append("dataset", this._dataset());
    const headers = { Accept: "application/json" };
    const tok = this._token();
    if (tok) headers["Authorization"] = "Bearer " + tok;
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
      if (!r.ok) return;
      const data = await r.json();
      this._select({
        url: data.url,
        mime: data.mimeType,
        assetId: data.assetDocId || "",
        alt: ""
      });
      this._loadFiles();
    } catch (_e) {
      // Surface in console; UX-side handling deferred to v2.
    }
  }
}

customElements.define("bp-media-picker", BpMediaPicker);
