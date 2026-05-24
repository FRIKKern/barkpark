// bp-asset-explorer — full-page Lightroom-style mediaAsset workspace.
//
// Mount on Media tab: <bp-asset-explorer dataset="production" data-token="…">
// Queries /v1/data/query/:dataset/mediaAsset; upload via /media/upload.

(function () {
  function esc(s) {
    return String(s || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/"/g, "&quot;");
  }

  function assetUrl(doc) {
    const fi = doc && doc.fileInfo;
    return (fi && fi.url) || "";
  }

  function assetThumbUrl(rowOrDoc) {
    if (rowOrDoc && rowOrDoc.thumbnailUrl) return rowOrDoc.thumbnailUrl;
    if (rowOrDoc && rowOrDoc.fileInfo && rowOrDoc.fileInfo.thumbnailUrl) {
      return rowOrDoc.fileInfo.thumbnailUrl;
    }
    return assetUrl(rowOrDoc);
  }

  function assetMime(doc) {
    const fi = doc && doc.fileInfo;
    return (fi && fi.mimeType) || "";
  }

  function formatSize(raw) {
    const n = parseInt(raw, 10);
    if (!n || isNaN(n)) return "";
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  function fmtDate(iso) {
    if (!iso) return "";
    try {
      return new Date(iso).toLocaleString();
    } catch (_e) {
      return iso;
    }
  }

  function mergeHit(row) {
    const asset = row.asset || assetFromBlob(row);
    return Object.assign({}, asset, {
      _blobId: row.id,
      thumbnailUrl: row.thumbnailUrl || asset.thumbnailUrl,
      previewUrl: row.previewUrl || asset.previewUrl,
      originalUrl: row.originalUrl || asset.originalUrl
    });
  }

  function assetFromBlob(row) {
    if (!row) return null;
    return {
      _id: row.assetDocId || "",
      title: row.originalName || row.filename,
      bp_asset_kind: "other",
      fileInfo: {
        url: row.thumbnailUrl || row.url,
        mimeType: row.mimeType,
        size: String(row.size || ""),
        originalName: row.originalName
      },
      thumbnailUrl: row.thumbnailUrl,
      previewUrl: row.previewUrl,
      originalUrl: row.originalUrl
    };
  }

  const FILTERS = [
    { id: "all", label: "All" },
    { id: "image", label: "Images" },
    { id: "video", label: "Video" },
    { id: "audio", label: "Audio" },
    { id: "document", label: "Documents" },
    { id: "other", label: "Other" }
  ];

  class BpAssetExplorer extends HTMLElement {
    constructor() {
      super();
      this._assets = [];
      this._selected = null;
      this._filterKind = "all";
      this._collectionId = null;
      this._collections = [];
      this._search = "";
      this._searchTimer = null;
      this._loading = false;
      this._density = 160;
    }

    connectedCallback() {
      if (this._built) return;
      this._built = true;
      this.className = "bp-ae-root";
      this.innerHTML =
        '<aside class="bp-ae-sidebar">' +
        '<div class="bp-ae-sidebar-title">Library</div>' +
        '<nav class="bp-ae-filters"></nav>' +
        '<div class="bp-ae-sidebar-title bp-ae-collections-title">Collections</div>' +
        '<nav class="bp-ae-collections"></nav>' +
        "</aside>" +
        '<main class="bp-ae-main">' +
        '<header class="bp-ae-toolbar">' +
        '<input type="search" class="bp-ae-search form-input" placeholder="Search by title or filename…" />' +
        '<label class="btn btn-primary btn-sm bp-ae-upload">' +
        "<span>Upload</span>" +
        '<input type="file" multiple hidden />' +
        "</label>" +
        '<span class="bp-ae-count text-sm text-muted"></span>' +
        '<label class="bp-ae-density-label text-sm text-muted">' +
        "Size" +
        '<input type="range" class="bp-ae-density" min="100" max="240" value="160" />' +
        "</label>" +
        "</header>" +
        '<section class="bp-ae-grid-wrap">' +
        '<div class="bp-ae-loading text-sm text-muted" hidden>Loading assets…</div>' +
        '<div class="bp-ae-empty text-sm text-muted" hidden>No assets yet — upload a file to get started.</div>' +
        '<div class="bp-ae-grid media-grid"></div>' +
        "</section>" +
        '<footer class="bp-ae-filmstrip">' +
        '<div class="bp-ae-filmstrip-track"></div>' +
        "</footer>" +
        "</main>" +
        '<aside class="bp-ae-inspector">' +
        '<div class="bp-ae-inspector-empty text-sm text-muted">Select an asset</div>' +
        '<div class="bp-ae-inspector-body" hidden></div>' +
        "</aside>";

      this._filtersEl = this.querySelector(".bp-ae-filters");
      this._collectionsEl = this.querySelector(".bp-ae-collections");
      this._gridEl = this.querySelector(".bp-ae-grid");
      this._filmstripEl = this.querySelector(".bp-ae-filmstrip-track");
      this._searchEl = this.querySelector(".bp-ae-search");
      this._countEl = this.querySelector(".bp-ae-count");
      this._loadingEl = this.querySelector(".bp-ae-loading");
      this._emptyEl = this.querySelector(".bp-ae-empty");
      this._inspectorEmpty = this.querySelector(".bp-ae-inspector-empty");
      this._inspectorBody = this.querySelector(".bp-ae-inspector-body");
      this._uploadInput = this.querySelector(".bp-ae-upload input");
      this._densityInput = this.querySelector(".bp-ae-density");

      this._renderFilters();
      this._loadCollections();
      this._applyKindFilterAttr();
      this._searchEl.addEventListener("input", (e) => {
        this._search = e.target.value || "";
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => this._loadAssets(), 250);
      });
      this._uploadInput.addEventListener("change", (e) => {
        const files = e.target.files;
        if (files && files.length) this._uploadFiles(files);
        e.target.value = "";
      });
      this._densityInput.addEventListener("input", (e) => {
        this._density = parseInt(e.target.value, 10) || 160;
        if (this._gridEl) {
          this._gridEl.style.setProperty(
            "--ae-cell",
            this._density + "px"
          );
        }
      });
      if (this._gridEl) {
        this._gridEl.style.setProperty("--ae-cell", this._density + "px");
      }

      document.addEventListener("keydown", (e) => {
        if (!this.isConnected || !this._selected) return;
        if (e.target && /input|textarea/i.test(e.target.tagName)) return;
        if (e.key === "ArrowRight") this._selectRelative(1);
        if (e.key === "ArrowLeft") this._selectRelative(-1);
      });

      this._loadAssets();
    }

    _applyKindFilterAttr() {
      const raw = this.getAttribute("data-kind-filter");
      if (raw && raw !== "all") {
        this._filterKind = raw;
        this._renderFilters();
      }
    }

    _openPath() {
      return this.getAttribute("data-open-path") || "";
    }

    _openDoc(doc) {
      const prefix = this._openPath();
      if (!prefix || !doc) return;
      const pub =
        doc._publishedId ||
        String(doc._id || "").replace(/^drafts\./, "");
      if (!pub) return;
      window.location.href =
        prefix + "/" + encodeURIComponent(pub);
    }

    _dataset() {
      return this.getAttribute("dataset") || "production";
    }

    _token() {
      return this.getAttribute("data-token") || "";
    }

    _headers() {
      const h = { Accept: "application/json" };
      const tok = this._token();
      if (tok) h["Authorization"] = "Bearer " + tok;
      return h;
    }

    _renderFilters() {
      this._filtersEl.innerHTML = FILTERS.map((f) => {
        const active = !this._collectionId && f.id === this._filterKind ? " is-active" : "";
        return (
          '<button type="button" class="bp-ae-filter' +
          active +
          '" data-kind="' +
          f.id +
          '">' +
          esc(f.label) +
          "</button>"
        );
      }).join("");
      this._filtersEl.querySelectorAll(".bp-ae-filter").forEach((btn) => {
        btn.addEventListener("click", () => {
          this._collectionId = null;
          this._filterKind = btn.dataset.kind || "all";
          this._renderFilters();
          this._renderCollections();
          this._loadAssets();
        });
      });
    }

    async _loadCollections() {
      if (!this._collectionsEl) return;
      const url =
        "/v1/media/" + encodeURIComponent(this._dataset()) + "/collections?limit=100";
      try {
        const r = await fetch(url, {
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) throw new Error(String(r.status));
        const data = await r.json();
        this._collections = (data && data.result && data.result.collections) || [];
      } catch (_e) {
        this._collections = [];
      }
      this._renderCollections();
    }

    _renderCollections() {
      if (!this._collectionsEl) return;
      const allActive = this._collectionId ? "" : " is-active";
      let html =
        '<button type="button" class="bp-ae-collection' +
        allActive +
        '" data-id="">All assets</button>';
      html += this._collections
        .map((col) => {
          const active = this._collectionId === col.id ? " is-active" : "";
          const badge = col.kind === "virtual" ? " ⚡" : "";
          return (
            '<button type="button" class="bp-ae-collection' +
            active +
            '" data-id="' +
            esc(col.id) +
            '">' +
            esc(col.title || col.id) +
            badge +
            "</button>"
          );
        })
        .join("");
      this._collectionsEl.innerHTML = html;
      this._collectionsEl.querySelectorAll(".bp-ae-collection").forEach((btn) => {
        btn.addEventListener("click", () => {
          this._collectionId = btn.dataset.id || null;
          this._renderFilters();
          this._renderCollections();
          this._loadAssets();
        });
      });
    }

    async _loadAssets() {
      this._loading = true;
      if (this._loadingEl) this._loadingEl.hidden = false;
      if (this._emptyEl) this._emptyEl.hidden = true;

      const params = new URLSearchParams({
        limit: "500",
        offset: "0",
        sort: this._search ? "relevance" : "created-desc"
      });

      let url;

      if (this._collectionId) {
        if (this._search) params.set("q", this._search);
        url =
          "/v1/media/" +
          encodeURIComponent(this._dataset()) +
          "/collections/" +
          encodeURIComponent(this._collectionId) +
          "/assets?" +
          params.toString();
      } else {
        params.set("facets", "kind");
        if (this._filterKind && this._filterKind !== "all") {
          params.set("facet.kind", this._filterKind);
        }
        if (this._search) params.set("q", this._search);
        url =
          "/v1/media/" +
          encodeURIComponent(this._dataset()) +
          "/search?" +
          params.toString();
      }

      try {
        const r = await fetch(url, {
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) throw new Error(String(r.status));
        const data = await r.json();
        const rows =
          (data && data.result && data.result.hits) ||
          (data && data.result && data.result.assets) ||
          (data && data.assets) ||
          [];
        this._assets = rows
          .map((row) => mergeHit(row))
          .filter((d) => assetUrl(d) || assetThumbUrl(d));
      } catch (_e) {
        this._assets = [];
      } finally {
        this._loading = false;
        if (this._loadingEl) this._loadingEl.hidden = true;
        this._renderGrid();
      }
    }

    _visibleAssets() {
      return this._assets;
    }

    _renderGrid() {
      const items = this._visibleAssets();
      if (this._countEl) {
        this._countEl.classList.remove("bp-ae-status-error");
        this._countEl.textContent =
          items.length + " asset" + (items.length === 1 ? "" : "s");
      }

      if (!items.length) {
        if (this._gridEl) this._gridEl.innerHTML = "";
        if (this._emptyEl) this._emptyEl.hidden = this._assets.length > 0;
        this._renderFilmstrip([]);
        return;
      }

      if (this._emptyEl) this._emptyEl.hidden = true;

      if (this._gridEl) {
        this._gridEl.innerHTML = items
          .map((doc) => {
            const id = doc._id || "";
            const thumbUrl = esc(assetThumbUrl(doc));
            const title = esc(doc.title || (doc.fileInfo && doc.fileInfo.originalName) || id);
            const kind = doc.bp_asset_kind || "other";
            const sel = this._selected && this._selected._id === id ? " is-selected" : "";
            const thumb =
              kind === "image"
                ? '<img src="' + thumbUrl + '" alt="" loading="lazy" />'
                : '<div class="bp-ae-file-icon">' + esc(kind) + "</div>";
            return (
              '<button type="button" class="bp-ae-card media-card' +
              sel +
              '" data-id="' +
              esc(id) +
              '">' +
              '<div class="media-thumb">' +
              thumb +
              "</div>" +
              '<div class="media-info">' +
              '<div class="media-name">' +
              title +
              "</div>" +
              '<div class="media-size">' +
              esc(formatSize(doc.fileInfo && doc.fileInfo.size)) +
              "</div>" +
              "</div></button>"
            );
          })
          .join("");

        this._gridEl.querySelectorAll(".bp-ae-card").forEach((btn) => {
          btn.addEventListener("click", () => {
            const doc = items.find((d) => d._id === btn.dataset.id);
            if (doc) this._select(doc);
          });
          btn.addEventListener("dblclick", () => {
            const doc = items.find((d) => d._id === btn.dataset.id);
            if (doc) this._openDoc(doc);
          });
        });
      }

      this._renderFilmstrip(items.slice(0, 24));
    }

    _renderFilmstrip(items) {
      if (!this._filmstripEl) return;
      this._filmstripEl.innerHTML = items
        .map((doc) => {
          const id = doc._id || "";
          const thumbUrl = esc(assetThumbUrl(doc));
          const kind = doc.bp_asset_kind || "other";
          const sel = this._selected && this._selected._id === id ? " is-selected" : "";
          const inner =
            kind === "image"
              ? '<img src="' + thumbUrl + '" alt="" />'
              : '<span>' + esc(kind) + "</span>";
          return (
            '<button type="button" class="bp-ae-strip-item' +
            sel +
            '" data-id="' +
            esc(id) +
            '">' +
            inner +
            "</button>"
          );
        })
        .join("");

      this._filmstripEl.querySelectorAll(".bp-ae-strip-item").forEach((btn) => {
        btn.addEventListener("click", () => {
          const doc = this._assets.find((d) => d._id === btn.dataset.id);
          if (doc) this._select(doc);
        });
      });
    }

    _select(doc) {
      this._selected = doc;
      this._renderGrid();
      this._renderInspector(doc);
    }

    _selectRelative(delta) {
      const items = this._visibleAssets();
      if (!items.length || !this._selected) return;
      const idx = items.findIndex((d) => d._id === this._selected._id);
      const next = items[(idx + delta + items.length) % items.length];
      if (next) this._select(next);
    }

    _renderInspector(doc) {
      if (!doc) {
        this._inspectorEmpty.hidden = false;
        this._inspectorBody.hidden = true;
        return;
      }

      this._inspectorEmpty.hidden = true;
      this._inspectorBody.hidden = false;

      const originalUrl = doc.originalUrl || assetUrl(doc);
      const previewUrl = doc.previewUrl || originalUrl;
      const kind = doc.bp_asset_kind || "other";
      const fi = doc.fileInfo || {};
      const preview =
        kind === "image"
          ? '<img class="bp-ae-inspector-img" src="' + esc(previewUrl) + '" alt="" />'
          : '<div class="bp-ae-inspector-icon">' + esc(kind) + "</div>";

      this._inspectorBody.innerHTML =
        preview +
        '<h3 class="bp-ae-inspector-title">' +
        esc(doc.title || fi.originalName || doc._id) +
        "</h3>" +
        '<dl class="bp-ae-meta">' +
        "<dt>Document ID</dt><dd><code>" +
        esc(doc._id) +
        "</code></dd>" +
        "<dt>Kind</dt><dd>" +
        esc(kind) +
        "</dd>" +
        "<dt>MIME</dt><dd>" +
        esc(assetMime(doc)) +
        "</dd>" +
        "<dt>Size</dt><dd>" +
        esc(formatSize(fi.size)) +
        "</dd>" +
        "<dt>Updated</dt><dd>" +
        esc(fmtDate(doc._updatedAt)) +
        "</dd>" +
        "<dt>URL</dt><dd><code>" +
        esc(originalUrl) +
        "</code></dd>" +
        "</dl>" +
        '<div class="bp-ae-relations text-sm" hidden></div>' +
        '<div class="bp-ae-inspector-actions">' +
        (this._openPath()
          ? '<button type="button" class="btn btn-primary btn-sm bp-ae-open-doc">Edit metadata</button>'
          : "") +
        '<a class="btn btn-sm" href="' +
        esc(originalUrl) +
        '" target="_blank" rel="noopener">Open file</a>' +
        '<button type="button" class="btn btn-sm bp-ae-copy-url">Copy URL</button>' +
        "</div>";

      const openBtn = this._inspectorBody.querySelector(".bp-ae-open-doc");
      if (openBtn) {
        openBtn.addEventListener("click", () => this._openDoc(doc));
      }

      this._inspectorBody.querySelector(".bp-ae-copy-url").addEventListener("click", () => {
        if (navigator.clipboard && originalUrl) navigator.clipboard.writeText(originalUrl);
      });

      this._loadRelations(doc);
    }

    async _loadRelations(doc) {
      const el = this._inspectorBody && this._inspectorBody.querySelector(".bp-ae-relations");
      if (!el || !doc._blobId) return;

      const url =
        "/v1/media/" +
        encodeURIComponent(this._dataset()) +
        "/" +
        encodeURIComponent(doc._blobId) +
        "/relations";

      try {
        const r = await fetch(url, {
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) return;
        const data = await r.json();
        const outbound = (data && data.result && data.result.outbound) || [];
        const inbound = (data && data.result && data.result.inbound) || [];
        if (!outbound.length && !inbound.length) return;
        el.hidden = false;
        const lines = [];
        outbound.forEach((edge) => {
          const title =
            (edge.asset && edge.asset.asset && edge.asset.asset.title) ||
            edge.assetDocId ||
            "?";
          lines.push("→ " + esc(edge.relation) + ": " + esc(title));
        });
        inbound.forEach((edge) => {
          const title =
            (edge.asset && edge.asset.asset && edge.asset.asset.title) ||
            edge.assetDocId ||
            "?";
          lines.push("← " + esc(edge.relation) + ": " + esc(title));
        });
        el.innerHTML = "<strong>Relations</strong><div>" + lines.join("<br/>") + "</div>";
      } catch (_e) {
        /* optional panel */
      }
    }

    async _uploadFiles(fileList) {
      const headers = { Accept: "application/json" };
      const tok = this._token();
      if (tok) headers["Authorization"] = "Bearer " + tok;

      let failed = 0;

      for (const file of fileList) {
        const fd = new FormData();
        fd.append("file", file);
        fd.append("dataset", this._dataset());
        try {
          const r = await fetch("/media/upload", {
            method: "POST",
            headers: headers,
            body: fd,
            credentials: "same-origin"
          });
          if (!r.ok) {
            failed++;
            if (r.status === 401) {
              this._setStatus(
                "Upload blocked — sign in at /login with barkpark-dev-token"
              );
            } else {
              this._setStatus("Upload failed (" + r.status + ")");
            }
          }
        } catch (_e) {
          failed++;
          this._setStatus("Upload failed — check that the API is running");
        }
      }

      if (!failed) this._setStatus("");
      await this._loadAssets();
    }

    _setStatus(msg) {
      if (!this._countEl) return;
      this._countEl.textContent = msg || this._countLabel();
      this._countEl.classList.toggle("bp-ae-status-error", !!msg);
    }

    _countLabel() {
      const n = this._assets.length;
      return n === 1 ? "1 asset" : n + " assets";
    }
  }

  customElements.define("bp-asset-explorer", BpAssetExplorer);
})();
