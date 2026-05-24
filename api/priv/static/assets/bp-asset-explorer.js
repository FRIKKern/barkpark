// bp-asset-explorer — Media Desk v2: facets, context inspector, governance.
//
// Mount: <bp-asset-explorer dataset="production" data-token="…">

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
    const nested = asset && typeof asset === "object" ? asset : {};
    return Object.assign({}, nested, {
      _blobId: row.id,
      _id: nested._id || row.assetDocId || row.id,
      title: nested.title || row.originalName || row.filename,
      visibility: row.visibility || nested.bp_visibility,
      thumbnailUrl: row.thumbnailUrl || nested.thumbnailUrl,
      previewUrl: row.previewUrl || nested.previewUrl,
      originalUrl: row.originalUrl || nested.originalUrl,
      permissions: row.permissions || []
    });
  }

  function assetFromBlob(row) {
    if (!row) return null;
    return {
      _id: row.assetDocId || row.id,
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

  function assetPayload(doc) {
    if (!doc) return {};
    if (doc.asset && typeof doc.asset === "object") return doc.asset;
    return doc;
  }

  const FILTERS = [
    { id: "all", label: "All" },
    { id: "image", label: "Images" },
    { id: "video", label: "Video" },
    { id: "audio", label: "Audio" },
    { id: "document", label: "Documents" },
    { id: "other", label: "Other" }
  ];

  const FACET_FIELDS = ["tags", "processing", "visibility", "status"];
  const FACET_LABELS = {
    tags: "Tags",
    processing: "Processing",
    visibility: "Visibility",
    status: "Status",
    kind: "Kind"
  };

  function facetEntries(bucket) {
    if (!bucket) return [];
    if (Array.isArray(bucket)) {
      return bucket
        .map((item) => [item && item.value, item && item.count])
        .filter(([value]) => value != null && value !== "");
    }
    return Object.entries(bucket).filter(([value]) => value != null && value !== "");
  }

  class BpAssetExplorer extends HTMLElement {
    constructor() {
      super();
      this._assets = [];
      this._selected = null;
      this._filterKind = "all";
      this._facetSelections = {};
      this._facets = {};
      this._collectionId = null;
      this._collections = [];
      this._search = "";
      this._searchTimer = null;
      this._loading = false;
      this._density = 160;
      this._inspectorMode = "none";
      this._assetDetail = null;
      this._shareInfo = null;
      this._toastTimer = null;
    }

    connectedCallback() {
      if (this._built) return;
      this._built = true;
      this.className = "bp-ae-root";
      this.innerHTML =
        '<div class="bp-ae-toast" hidden></div>' +
        '<aside class="bp-ae-sidebar">' +
        '<div class="bp-ae-sidebar-title">Library</div>' +
        '<nav class="bp-ae-filters"></nav>' +
        '<div class="bp-ae-sidebar-title bp-ae-facets-title" hidden>Refine</div>' +
        '<nav class="bp-ae-facets" hidden></nav>' +
        '<div class="bp-ae-sidebar-head">' +
        '<div class="bp-ae-sidebar-title bp-ae-collections-title">Collections</div>' +
        '<button type="button" class="bp-ae-new-collection btn btn-sm" title="New folder">+</button>' +
        "</div>" +
        '<nav class="bp-ae-collections"></nav>' +
        "</aside>" +
        '<main class="bp-ae-main">' +
        '<header class="bp-ae-toolbar">' +
        '<input type="search" class="bp-ae-search form-input" placeholder="Search by title or filename…" />' +
        '<div class="bp-ae-toolbar-pills"></div>' +
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
        '<div class="bp-ae-inspector-empty text-sm text-muted">Select an asset or collection</div>' +
        '<div class="bp-ae-inspector-body" hidden></div>' +
        "</aside>" +
        '<div class="bp-ae-modal" hidden role="dialog" aria-modal="true" aria-labelledby="bp-ae-modal-title">' +
        '<div class="bp-ae-modal-backdrop"></div>' +
        '<div class="bp-ae-modal-card">' +
        '<h3 id="bp-ae-modal-title" class="bp-ae-modal-title">New folder</h3>' +
        '<p class="bp-ae-modal-hint text-sm text-muted">Folder collections hold curated sets of assets.</p>' +
        '<input type="text" class="form-input bp-ae-modal-input" placeholder="Collection name" maxlength="120" />' +
        '<div class="bp-ae-modal-actions">' +
        '<button type="button" class="btn btn-sm bp-ae-modal-cancel">Cancel</button>' +
        '<button type="button" class="btn btn-primary btn-sm bp-ae-modal-submit">Create folder</button>' +
        "</div></div></div>";

      this._filtersEl = this.querySelector(".bp-ae-filters");
      this._facetsEl = this.querySelector(".bp-ae-facets");
      this._facetsTitleEl = this.querySelector(".bp-ae-facets-title");
      this._collectionsEl = this.querySelector(".bp-ae-collections");
      this._gridWrapEl = this.querySelector(".bp-ae-grid-wrap");
      this._gridEl = this.querySelector(".bp-ae-grid");
      this._filmstripEl = this.querySelector(".bp-ae-filmstrip-track");
      this._searchEl = this.querySelector(".bp-ae-search");
      this._pillsEl = this.querySelector(".bp-ae-toolbar-pills");
      this._countEl = this.querySelector(".bp-ae-count");
      this._loadingEl = this.querySelector(".bp-ae-loading");
      this._emptyEl = this.querySelector(".bp-ae-empty");
      this._inspectorEmpty = this.querySelector(".bp-ae-inspector-empty");
      this._inspectorBody = this.querySelector(".bp-ae-inspector-body");
      this._uploadInput = this.querySelector(".bp-ae-upload input");
      this._densityInput = this.querySelector(".bp-ae-density");
      this._toastEl = this.querySelector(".bp-ae-toast");
      this._modalEl = this.querySelector(".bp-ae-modal");
      this._modalInput = this.querySelector(".bp-ae-modal-input");
      this._modalBackdrop = this.querySelector(".bp-ae-modal-backdrop");

      this._renderFilters();
      this._loadCollections();
      this._applyKindFilterAttr();

      this._searchEl.addEventListener("input", (e) => {
        this._search = e.target.value || "";
        this._renderToolbarPills();
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
          this._gridEl.style.setProperty("--ae-cell", this._density + "px");
        }
      });
      if (this._gridEl) {
        this._gridEl.style.setProperty("--ae-cell", this._density + "px");
      }

      this.querySelector(".bp-ae-new-collection").addEventListener("click", () => {
        this._openCollectionModal();
      });

      if (this._modalBackdrop) {
        this._modalBackdrop.addEventListener("click", () => this._closeCollectionModal());
      }
      this.querySelector(".bp-ae-modal-cancel").addEventListener("click", () => {
        this._closeCollectionModal();
      });
      this.querySelector(".bp-ae-modal-submit").addEventListener("click", () => {
        this._submitCollectionModal();
      });
      if (this._modalInput) {
        this._modalInput.addEventListener("keydown", (e) => {
          if (e.key === "Enter") this._submitCollectionModal();
          if (e.key === "Escape") this._closeCollectionModal();
        });
      }

      document.addEventListener("keydown", (e) => {
        if (!this.isConnected || !this._selected) return;
        if (e.target && /input|textarea|select/i.test(e.target.tagName)) return;
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
      const payload = assetPayload(doc);
      const pub =
        payload._publishedId ||
        String(payload._id || doc._id || "").replace(/^drafts\./, "");
      if (!pub) return;
      window.location.href = prefix + "/" + encodeURIComponent(pub);
    }

    _dataset() {
      return this.getAttribute("dataset") || "production";
    }

    _token() {
      return this.getAttribute("data-token") || "";
    }

    _headers(json) {
      const h = { Accept: "application/json" };
      if (json) h["Content-Type"] = "application/json";
      const tok = this._token();
      if (tok) h["Authorization"] = "Bearer " + tok;
      return h;
    }

    _mediaBase() {
      return "/v1/media/" + encodeURIComponent(this._dataset());
    }

    _toast(msg) {
      if (!this._toastEl || !msg) return;
      this._toastEl.textContent = msg;
      this._toastEl.hidden = false;
      clearTimeout(this._toastTimer);
      this._toastTimer = setTimeout(() => {
        this._toastEl.hidden = true;
      }, 2200);
    }

    _copyText(text, label) {
      if (!text || !navigator.clipboard) return;
      navigator.clipboard.writeText(text).then(() => {
        this._toast((label || "Link") + " copied");
      });
    }

    _kindLabel(id) {
      const match = FILTERS.find((f) => f.id === id);
      return (match && match.label) || id;
    }

    _activeFacetEntries() {
      const entries = [];

      if (this._search) {
        entries.push(["q", this._search]);
      }

      if (this._collectionId) {
        const col = this._currentCollection();
        entries.push(["collection", (col && col.title) || this._collectionId]);
      }

      Object.entries(this._facetSelections).forEach(([field, value]) => {
        entries.push([field, value]);
      });

      if (this._filterKind && this._filterKind !== "all" && !this._collectionId) {
        entries.push(["kind", this._filterKind]);
      }

      return entries;
    }

    _pillLabel(field, value) {
      if (field === "q") return "Search: " + value;
      if (field === "collection") return "Collection: " + value;
      if (field === "kind") return "Kind: " + this._kindLabel(value);
      const label = FACET_LABELS[field] || field;
      return label + ": " + value;
    }

    _renderToolbarPills() {
      if (!this._pillsEl) return;
      const entries = this._activeFacetEntries();
      if (!entries.length) {
        this._pillsEl.innerHTML = "";
        return;
      }
      this._pillsEl.innerHTML = entries
        .map(([field, value]) => {
          const label = FACET_LABELS[field] || field;
          return (
            '<button type="button" class="bp-ae-pill" data-field="' +
            esc(field) +
            '" data-value="' +
            esc(value) +
            '">' +
            esc(this._pillLabel(field, value)) +
            " ×</button>"
          );
        })
        .join("");
      this._pillsEl.querySelectorAll(".bp-ae-pill").forEach((btn) => {
        btn.addEventListener("click", () => {
          const field = btn.dataset.field;
          const value = btn.dataset.value;
          if (field === "q") {
            this._search = "";
            if (this._searchEl) this._searchEl.value = "";
          } else if (field === "collection") {
            this._collectionId = null;
            this._inspectorMode = "none";
            this._shareInfo = null;
            this._renderCollections();
            this._showEmptyInspector();
          } else if (field === "kind") {
            this._filterKind = "all";
            this._renderFilters();
          } else {
            delete this._facetSelections[field];
          }
          this._renderFacets();
          this._renderToolbarPills();
          this._loadAssets();
        });
      });
    }

    _toggleFacet(field, value) {
      const current = field === "kind" ? this._filterKind : this._facetSelections[field];
      if (current === value) {
        if (field === "kind") this._filterKind = "all";
        else delete this._facetSelections[field];
      } else {
        if (field === "kind") this._filterKind = value;
        else this._facetSelections[field] = value;
      }
      this._renderFilters();
      this._renderFacets();
      this._renderToolbarPills();
      this._loadAssets();
    }

    _renderFacets() {
      if (!this._facetsEl || this._collectionId) {
        if (this._facetsEl) this._facetsEl.hidden = true;
        if (this._facetsTitleEl) this._facetsTitleEl.hidden = true;
        return;
      }

      const hasFacets = FACET_FIELDS.some((f) => facetEntries(this._facets[f]).length > 0);

      if (!hasFacets) {
        this._facetsEl.hidden = true;
        this._facetsTitleEl.hidden = true;
        return;
      }

      this._facetsEl.hidden = false;
      this._facetsTitleEl.hidden = false;

      let html = "";
      FACET_FIELDS.forEach((field) => {
        const entries = facetEntries(this._facets[field]);
        if (!entries.length) return;
        html += '<div class="bp-ae-facet-group">';
        html += '<div class="bp-ae-facet-label">' + esc(FACET_LABELS[field] || field) + "</div>";
        entries.forEach(([value, count]) => {
          const active =
            this._facetSelections[field] === value ? " is-active" : "";
          html +=
            '<button type="button" class="bp-ae-facet' +
            active +
            '" data-field="' +
            esc(field) +
            '" data-value="' +
            esc(value) +
            '">' +
            esc(value) +
            ' <span class="bp-ae-facet-count">' +
            esc(String(count)) +
            "</span></button>";
        });
        html += "</div>";
      });

      this._facetsEl.innerHTML = html;
      this._facetsEl.querySelectorAll(".bp-ae-facet").forEach((btn) => {
        btn.addEventListener("click", () => {
          this._toggleFacet(btn.dataset.field, btn.dataset.value);
        });
      });
    }

    _renderFilters() {
      this._filtersEl.innerHTML = FILTERS.map((f) => {
        const active =
          !this._collectionId && f.id === this._filterKind ? " is-active" : "";
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
          this._selected = null;
          this._inspectorMode = "none";
          this._renderFilters();
          this._renderCollections();
          this._renderFacets();
          this._renderToolbarPills();
          this._loadAssets();
          this._showEmptyInspector();
        });
      });
    }

    async _loadCollections() {
      if (!this._collectionsEl) return;
      try {
        const r = await fetch(this._mediaBase() + "/collections?limit=100", {
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

    _currentCollection() {
      if (!this._collectionId) return null;
      return this._collections.find((c) => c.id === this._collectionId) || null;
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
      if (!this._collections.length) {
        html +=
          '<p class="bp-ae-collections-empty text-sm text-muted">No folders yet — click + to create one.</p>';
      }
      this._collectionsEl.innerHTML = html;
      this._collectionsEl.querySelectorAll(".bp-ae-collection").forEach((btn) => {
        btn.addEventListener("click", () => {
          this._collectionId = btn.dataset.id || null;
          this._selected = null;
          this._inspectorMode = this._collectionId ? "collection" : "none";
          this._shareInfo = null;
          this._renderFilters();
          this._renderCollections();
          this._renderFacets();
          this._renderToolbarPills();
          this._loadAssets();
          if (this._collectionId) this._renderCollectionInspector();
          else this._showEmptyInspector();
        });
      });
    }

    _showEmptyInspector() {
      this._inspectorEmpty.hidden = false;
      this._inspectorBody.hidden = true;
    }

    async _loadAssets() {
      this._loading = true;
      if (this._loadingEl) this._loadingEl.hidden = false;
      if (this._emptyEl) this._emptyEl.hidden = true;
      if (this._gridWrapEl) this._gridWrapEl.classList.add("is-loading");

      const params = new URLSearchParams({
        limit: "500",
        offset: "0",
        sort: this._search ? "relevance" : "created-desc"
      });

      let url;

      if (this._collectionId) {
        if (this._search) params.set("q", this._search);
        url = this._mediaBase() + "/collections/" + encodeURIComponent(this._collectionId) + "/assets?" + params.toString();
      } else {
        params.set("facets", "kind,tags,processing,visibility,status");
        if (this._filterKind && this._filterKind !== "all") {
          params.set("facet.kind", this._filterKind);
        }
        Object.entries(this._facetSelections).forEach(([field, value]) => {
          params.set("facet." + field, value);
        });
        if (this._search) params.set("q", this._search);
        url = this._mediaBase() + "/search?" + params.toString();
      }

      try {
        const r = await fetch(url, {
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) throw new Error(String(r.status));
        const data = await r.json();
        const rows = (data && data.result && data.result.hits) || [];
        if (data && data.result && data.result.facets) {
          this._facets = data.result.facets;
        }
        this._assets = rows
          .map((row) => mergeHit(row))
          .filter((d) => assetUrl(d) || assetThumbUrl(d));
      } catch (_e) {
        this._assets = [];
      } finally {
        this._loading = false;
        if (this._loadingEl) this._loadingEl.hidden = true;
        if (this._gridWrapEl) {
          this._gridWrapEl.classList.remove("is-loading");
          this._gridWrapEl.classList.add("is-loaded");
        }
        this._renderFacets();
        this._renderToolbarPills();
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
        const col = this._currentCollection();
        if (col) {
          this._countEl.textContent = items.length + " in " + (col.title || col.id);
        } else {
          this._countEl.textContent = items.length + " asset" + (items.length === 1 ? "" : "s");
        }
      }

      if (!items.length) {
        if (this._gridEl) this._gridEl.innerHTML = "";
        if (this._emptyEl) this._emptyEl.hidden = false;
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
            const proc = (assetPayload(doc).bp_processing_status || "").toLowerCase();
            const procBadge =
              proc === "processing"
                ? '<span class="bp-ae-card-badge is-pulse">···</span>'
                : "";
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
              procBadge +
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
      this._inspectorMode = "asset";
      this._assetDetail = null;
      this._renderGrid();
      this._renderAssetInspector(doc);
    }

    _selectRelative(delta) {
      const items = this._visibleAssets();
      if (!items.length || !this._selected) return;
      const idx = items.findIndex((d) => d._id === this._selected._id);
      const next = items[(idx + delta + items.length) % items.length];
      if (next) this._select(next);
    }

    _statusBadge(label, variant) {
      return (
        '<span class="bp-ae-badge bp-ae-badge--' +
        esc(variant || "muted") +
        '">' +
        esc(label) +
        "</span>"
      );
    }

    async _renderAssetInspector(doc) {
      this._inspectorEmpty.hidden = true;
      this._inspectorBody.hidden = false;

      const payload = assetPayload(doc);
      const originalUrl = doc.originalUrl || assetUrl(doc);
      const previewUrl = doc.previewUrl || originalUrl;
      const kind = doc.bp_asset_kind || payload.bp_asset_kind || "other";
      const fi = doc.fileInfo || {};
      const preview =
        kind === "image"
          ? '<div class="bp-ae-inspector-preview"><img class="bp-ae-inspector-img" src="' +
            esc(previewUrl) +
            '" alt="" /></div>'
          : '<div class="bp-ae-inspector-icon">' + esc(kind) + "</div>";

      this._inspectorBody.innerHTML =
        preview +
        '<h3 class="bp-ae-inspector-title">' +
        esc(doc.title || fi.originalName || doc._id) +
        "</h3>" +
        '<div class="bp-ae-inspector-status">' +
        this._statusBadge(payload.bp_processing_status || "ready", "ready") +
        this._statusBadge(doc.visibility || payload.bp_visibility || "public", "visibility") +
        "</div>" +
        '<dl class="bp-ae-meta">' +
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
        esc(fmtDate(doc._updatedAt || payload._updatedAt)) +
        "</dd>" +
        "</dl>" +
        '<div class="bp-ae-checkout-row text-sm" hidden></div>' +
        '<div class="bp-ae-relations text-sm" hidden></div>' +
        '<div class="bp-ae-inspector-actions">' +
        '<div class="bp-ae-action-row">' +
        '<button type="button" class="btn btn-sm bp-ae-checkout" hidden>Check out</button>' +
        '<button type="button" class="btn btn-sm bp-ae-undo-checkout" hidden>Release</button>' +
        '<div class="bp-ae-copy-menu">' +
        '<button type="button" class="btn btn-sm bp-ae-copy-toggle">Copy link ▾</button>' +
        '<div class="bp-ae-copy-dropdown" hidden>' +
        '<button type="button" data-link="original">Original</button>' +
        '<button type="button" data-link="preview">Preview</button>' +
        '<button type="button" data-link="thumb">Thumbnail</button>' +
        "</div></div></div>" +
        (this._collectionId && this._currentCollection() && this._currentCollection().kind !== "virtual"
          ? '<button type="button" class="btn btn-sm bp-ae-remove-member">Remove from collection</button>'
          : "") +
        (this._collections.filter((c) => c.kind !== "virtual").length
          ? '<select class="form-input bp-ae-add-collection"><option value="">Add to collection…</option></select>'
          : "") +
        "</div>" +
        '<div class="bp-ae-action-row bp-ae-action-row--secondary">' +
        (this._openPath()
          ? '<button type="button" class="btn btn-primary btn-sm bp-ae-open-doc">Edit metadata</button>'
          : "") +
        '<a class="btn btn-sm bp-ae-open-doc-link" href="' +
        esc(originalUrl) +
        '" target="_blank" rel="noopener">Open file</a>' +
        "</div></div>";

      const openBtn = this._inspectorBody.querySelector(".bp-ae-open-doc");
      if (openBtn) openBtn.addEventListener("click", () => this._openDoc(doc));

      const copyToggle = this._inspectorBody.querySelector(".bp-ae-copy-toggle");
      const copyDrop = this._inspectorBody.querySelector(".bp-ae-copy-dropdown");
      if (copyToggle && copyDrop) {
        copyToggle.addEventListener("click", () => {
          copyDrop.hidden = !copyDrop.hidden;
        });
        copyDrop.querySelectorAll("button[data-link]").forEach((btn) => {
          btn.addEventListener("click", () => {
            const kind = btn.dataset.link;
            const detail = this._assetDetail || doc;
            const url =
              kind === "preview"
                ? detail.previewUrl || previewUrl
                : kind === "thumb"
                  ? detail.thumbnailUrl || assetThumbUrl(doc)
                  : detail.originalUrl || originalUrl;
            this._copyText(url, kind.charAt(0).toUpperCase() + kind.slice(1));
            copyDrop.hidden = true;
          });
        });
      }

      const addSel = this._inspectorBody.querySelector(".bp-ae-add-collection");
      if (addSel) {
        this._collections
          .filter((c) => c.kind !== "virtual" && c.id !== this._collectionId)
          .forEach((c) => {
            const opt = document.createElement("option");
            opt.value = c.id;
            opt.textContent = c.title || c.id;
            addSel.appendChild(opt);
          });
        addSel.addEventListener("change", () => {
          if (addSel.value) this._addMember(addSel.value, doc);
          addSel.value = "";
        });
      }

      const removeBtn = this._inspectorBody.querySelector(".bp-ae-remove-member");
      if (removeBtn && this._collectionId) {
        removeBtn.addEventListener("click", () => {
          this._removeMember(this._collectionId, doc);
        });
      }

      await this._fetchAssetDetail(doc);
      this._loadRelations(doc);
    }

    async _fetchAssetDetail(doc) {
      const blobId = doc._blobId;
      if (!blobId) return;

      const url =
        this._mediaBase() +
        "/" +
        encodeURIComponent(blobId) +
        "?appendRequestSecret=true";

      try {
        const r = await fetch(url, {
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) return;
        const data = await r.json();
        this._assetDetail = (data && data.result) || null;
        this._updateCheckoutUI(doc);
      } catch (_e) {
        /* optional */
      }
    }

    _updateCheckoutUI(doc) {
      const detail = this._assetDetail;
      const payload = detail && detail.asset ? detail.asset : assetPayload(doc);
      const row = this._inspectorBody.querySelector(".bp-ae-checkout-row");
      const checkoutBtn = this._inspectorBody.querySelector(".bp-ae-checkout");
      const undoBtn = this._inspectorBody.querySelector(".bp-ae-undo-checkout");
      if (!row || !checkoutBtn || !undoBtn) return;

      const checkedOutBy = payload.checkedOutBy;
      const isCheckedOut = checkedOutBy != null && String(checkedOutBy) !== "";

      if (isCheckedOut) {
        row.hidden = false;
        row.innerHTML = this._statusBadge("Checked out by " + checkedOutBy, "lock");
        checkoutBtn.hidden = true;
        undoBtn.hidden = false;
      } else {
        row.hidden = true;
        row.innerHTML = "";
        checkoutBtn.hidden = false;
        undoBtn.hidden = true;
      }

      checkoutBtn.onclick = () => this._checkout(doc);
      undoBtn.onclick = () => this._undoCheckout(doc);

      const statusEl = this._inspectorBody.querySelector(".bp-ae-inspector-status");
      if (statusEl && detail) {
        const proc = (payload.bp_processing_status || "ready").toLowerCase();
        let badges =
          this._statusBadge(proc, proc === "processing" ? "processing" : "ready") +
          this._statusBadge(detail.visibility || payload.bp_visibility || "public", "visibility");
        if (isCheckedOut) badges += this._statusBadge("Locked", "lock");
        statusEl.innerHTML = badges;
      }
    }

    async _checkout(doc) {
      const blobId = doc._blobId;
      if (!blobId) return;
      try {
        const r = await fetch(this._mediaBase() + "/" + encodeURIComponent(blobId) + "/checkout", {
          method: "POST",
          credentials: "same-origin",
          headers: this._headers()
        });
        if (!r.ok) throw new Error(String(r.status));
        this._toast("Asset checked out");
        await this._fetchAssetDetail(doc);
      } catch (_e) {
        this._toast("Checkout failed");
      }
    }

    async _undoCheckout(doc) {
      const blobId = doc._blobId;
      if (!blobId) return;
      try {
        const r = await fetch(
          this._mediaBase() + "/" + encodeURIComponent(blobId) + "/undo-checkout",
          { method: "POST", credentials: "same-origin", headers: this._headers() }
        );
        if (!r.ok) throw new Error(String(r.status));
        this._toast("Checkout released");
        await this._fetchAssetDetail(doc);
      } catch (_e) {
        this._toast("Release failed");
      }
    }

    _renderCollectionInspector() {
      const col = this._currentCollection();
      if (!col) {
        this._showEmptyInspector();
        return;
      }

      this._inspectorEmpty.hidden = true;
      this._inspectorBody.hidden = false;
      this._inspectorMode = "collection";

      const kindLabel = col.kind === "virtual" ? "Smart collection" : "Folder";
      const count = this._assets.length;

      this._inspectorBody.innerHTML =
        '<div class="bp-ae-collection-icon">' +
        (col.kind === "virtual" ? "⚡" : "📁") +
        "</div>" +
        '<h3 class="bp-ae-inspector-title">' +
        esc(col.title || col.id) +
        "</h3>" +
        '<div class="bp-ae-inspector-status">' +
        this._statusBadge(kindLabel, "visibility") +
        this._statusBadge(count + " assets", "muted") +
        "</div>" +
        (col.description
          ? '<p class="bp-ae-collection-desc text-sm text-muted">' + esc(col.description) + "</p>"
          : "") +
        '<div class="bp-ae-share-block">' +
        '<div class="bp-ae-share-label text-sm text-muted">Public share link</div>' +
        '<div class="bp-ae-share-row" hidden>' +
        '<input type="text" class="form-input bp-ae-share-url" readonly />' +
        '<button type="button" class="btn btn-sm bp-ae-share-copy">Copy</button>' +
        "</div>" +
        '<div class="bp-ae-share-actions">' +
        '<button type="button" class="btn btn-primary btn-sm bp-ae-share-create">Generate link</button>' +
        '<button type="button" class="btn btn-sm bp-ae-share-revoke" hidden>Revoke</button>' +
        "</div></div>" +
        '<div class="bp-ae-inspector-actions">' +
        (col.kind !== "virtual" && this._selected
          ? '<button type="button" class="btn btn-sm bp-ae-add-selected">Add selected to folder</button>'
          : "") +
        "</div>";

      const createBtn = this._inspectorBody.querySelector(".bp-ae-share-create");
      const revokeBtn = this._inspectorBody.querySelector(".bp-ae-share-revoke");
      const copyBtn = this._inspectorBody.querySelector(".bp-ae-share-copy");
      const shareRow = this._inspectorBody.querySelector(".bp-ae-share-row");
      const shareInput = this._inspectorBody.querySelector(".bp-ae-share-url");

      if (this._shareInfo && this._shareInfo.shareUrl) {
        shareRow.hidden = false;
        const raw = this._shareInfo.shareUrl;
        shareInput.value = raw.indexOf("http") === 0 ? raw : window.location.origin + raw;
        createBtn.textContent = "Rotate link";
        revokeBtn.hidden = false;
      }

      createBtn.addEventListener("click", () => this._createShare(col));
      revokeBtn.addEventListener("click", () => this._revokeShare(col));
      copyBtn.addEventListener("click", () => {
        if (shareInput.value) this._copyText(shareInput.value, "Share link");
      });

      const addSelected = this._inspectorBody.querySelector(".bp-ae-add-selected");
      if (addSelected && this._selected) {
        addSelected.addEventListener("click", () => {
          this._addMember(col.id, this._selected);
        });
      }
    }

    async _createShare(col) {
      try {
        const r = await fetch(
          this._mediaBase() + "/collections/" + encodeURIComponent(col.id) + "/share",
          { method: "POST", credentials: "same-origin", headers: this._headers() }
        );
        if (!r.ok) throw new Error(String(r.status));
        const data = await r.json();
        this._shareInfo = (data && data.result) || null;
        this._toast("Share link created");
        await this._loadCollections();
        this._renderCollectionInspector();
      } catch (_e) {
        this._toast("Share link failed");
      }
    }

    async _revokeShare(col) {
      try {
        const r = await fetch(
          this._mediaBase() + "/collections/" + encodeURIComponent(col.id) + "/share",
          { method: "DELETE", credentials: "same-origin", headers: this._headers() }
        );
        if (!r.ok) throw new Error(String(r.status));
        this._shareInfo = null;
        this._toast("Share link revoked");
        await this._loadCollections();
        this._renderCollectionInspector();
      } catch (_e) {
        this._toast("Revoke failed");
      }
    }

    async _addMember(collectionId, doc) {
      const blobId = doc._blobId;
      if (!blobId || !collectionId) return;
      try {
        const r = await fetch(
          this._mediaBase() + "/collections/" + encodeURIComponent(collectionId) + "/members",
          {
            method: "POST",
            credentials: "same-origin",
            headers: this._headers(true),
            body: JSON.stringify({ assetId: blobId })
          }
        );
        if (!r.ok) throw new Error(String(r.status));
        this._toast("Added to collection");
        if (this._collectionId === collectionId) await this._loadAssets();
      } catch (_e) {
        this._toast("Could not add to collection");
      }
    }

    async _removeMember(collectionId, doc) {
      const blobId = doc._blobId;
      if (!blobId || !collectionId) return;
      try {
        const r = await fetch(
          this._mediaBase() +
            "/collections/" +
            encodeURIComponent(collectionId) +
            "/members/" +
            encodeURIComponent(blobId),
          { method: "DELETE", credentials: "same-origin", headers: this._headers() }
        );
        if (!r.ok) throw new Error(String(r.status));
        this._toast("Removed from collection");
        await this._loadAssets();
        if (this._selected) this._renderAssetInspector(this._selected);
      } catch (_e) {
        this._toast("Remove failed");
      }
    }

    _openCollectionModal() {
      if (!this._modalEl || !this._modalInput) return;
      this._modalInput.value = "New folder";
      this._modalEl.hidden = false;
      requestAnimationFrame(() => {
        this._modalInput.focus();
        this._modalInput.select();
      });
    }

    _closeCollectionModal() {
      if (this._modalEl) this._modalEl.hidden = true;
    }

    _submitCollectionModal() {
      const title = (this._modalInput && this._modalInput.value || "").trim();
      if (!title) {
        this._toast("Enter a collection name");
        if (this._modalInput) this._modalInput.focus();
        return;
      }
      this._closeCollectionModal();
      this._createCollection(title);
    }

    async _createCollection(title) {
      if (!title) return;
      const id = "col-" + Date.now().toString(36);
      try {
        const r = await fetch("/v1/data/mutate/" + encodeURIComponent(this._dataset()), {
          method: "POST",
          credentials: "same-origin",
          headers: this._headers(true),
          body: JSON.stringify({
            mutations: [
              {
                create: {
                  _type: "mediaCollection",
                  _id: id,
                  title: title,
                  kind: "folder",
                  slug: id
                }
              },
              { publish: { id: id, type: "mediaCollection" } }
            ]
          })
        });
        if (!r.ok) throw new Error(String(r.status));
        this._toast("Collection created");
        this._collectionId = id;
        this._inspectorMode = "collection";
        await this._loadCollections();
        await this._loadAssets();
        this._renderCollectionInspector();
      } catch (_e) {
        this._toast("Could not create collection");
      }
    }

    async _loadRelations(doc) {
      const el = this._inspectorBody && this._inspectorBody.querySelector(".bp-ae-relations");
      if (!el || !doc._blobId) return;

      try {
        const r = await fetch(
          this._mediaBase() + "/" + encodeURIComponent(doc._blobId) + "/relations",
          { credentials: "same-origin", headers: this._headers() }
        );
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
        /* optional */
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
              this._setStatus("Upload blocked — sign in at /login with barkpark-dev-token");
            } else {
              this._setStatus("Upload failed (" + r.status + ")");
            }
          }
        } catch (_e) {
          failed++;
          this._setStatus("Upload failed — check that the API is running");
        }
      }

      if (!failed) {
        this._setStatus("");
        this._toast("Upload complete");
      }
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
