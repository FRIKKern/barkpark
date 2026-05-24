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

  function inferKind(mime, fallback) {
    if (fallback && fallback !== "other") return fallback;
    const m = (mime || "").toLowerCase();
    if (m.indexOf("image/") === 0) return "image";
    if (m.indexOf("video/") === 0) return "video";
    if (m.indexOf("audio/") === 0) return "audio";
    if (m.indexOf("application/") === 0 || m.indexOf("text/") === 0) return "document";
    return "other";
  }

  function mergeHit(row) {
    const asset = row.asset || assetFromBlob(row);
    const nested = asset && typeof asset === "object" ? asset : {};
    const mime = nested.fileInfo && nested.fileInfo.mimeType ? nested.fileInfo.mimeType : row.mimeType;
    const kind = nested.bp_asset_kind || inferKind(mime, row.kind);
    return Object.assign({}, nested, {
      _blobId: row.id,
      _id: nested._id || row.assetDocId || row.id,
      title: nested.title || row.originalName || row.filename,
      bp_asset_kind: kind,
      visibility: row.visibility || nested.bp_visibility,
      thumbnailUrl: row.thumbnailUrl || nested.thumbnailUrl,
      previewUrl: row.previewUrl || nested.previewUrl,
      originalUrl: row.originalUrl || nested.originalUrl,
      _updatedAt: nested._updatedAt || row.updatedAt,
      permissions: row.permissions || [],
      fileInfo: Object.assign({}, nested.fileInfo || {}, {
        url: (nested.fileInfo && nested.fileInfo.url) || row.originalUrl || row.url,
        mimeType: mime,
        size: (nested.fileInfo && nested.fileInfo.size) || String(row.size || ""),
        originalName: (nested.fileInfo && nested.fileInfo.originalName) || row.originalName || row.filename
      })
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

  const FACET_FIELDS = ["tags", "mimeType", "processing", "visibility", "status"];
  const FACET_LABELS = {
    tags: "Tags",
    mimeType: "Format",
    processing: "Processing",
    visibility: "Visibility",
    status: "Status",
    kind: "Kind"
  };

  const SORT_OPTIONS = [
    { id: "created-desc", label: "Newest first" },
    { id: "created-asc", label: "Oldest first" },
    { id: "updated-desc", label: "Recently updated" },
    { id: "relevance", label: "Best match" }
  ];

  const STORAGE_KEY = "bp-ae-prefs";

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
      this._total = 0;
      this._offset = 0;
      this._pageSize = 50;
      this._viewMode = "grid";
      this._sort = "created-desc";
      this._loadAbort = null;
      this._scrollObserver = null;
      this._suggestTimer = null;
      this._suggestHideTimer = null;
      this._suggestions = { recent: [], popular: [], nohits: [] };
      this._searchClientId = this._ensureSearchClientId();
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
        '<div class="bp-ae-search-wrap">' +
        '<input type="search" class="bp-ae-search form-input" placeholder="Find assets…  (/ to focus)" aria-label="Search assets" autocomplete="off" aria-expanded="false" aria-controls="bp-ae-suggest-list" />' +
        '<div class="bp-ae-suggest" id="bp-ae-suggest-list" hidden role="listbox"></div>' +
        "</div>" +
        '<div class="bp-ae-toolbar-pills"></div>' +
        '<div class="bp-ae-view-toggle" role="group" aria-label="Result view">' +
        '<button type="button" class="btn btn-sm bp-ae-view-btn bp-ae-view-grid is-active" data-view="grid" title="Grid view">Grid</button>' +
        '<button type="button" class="btn btn-sm bp-ae-view-btn bp-ae-view-list" data-view="list" title="List view">List</button>' +
        "</div>" +
        '<select class="form-input bp-ae-sort text-sm" aria-label="Sort results">' +
        SORT_OPTIONS.map(
          (o) =>
            '<option value="' + o.id + '">' + esc(o.label) + "</option>"
        ).join("") +
        "</select>" +
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
        '<div class="bp-ae-find-bar text-sm" hidden></div>' +
        '<section class="bp-ae-grid-wrap">' +
        '<div class="bp-ae-loading text-sm text-muted" hidden>Loading assets…</div>' +
        '<div class="bp-ae-empty text-sm text-muted" hidden>No assets yet — upload a file to get started.</div>' +
        '<div class="bp-ae-grid media-grid"></div>' +
        '<div class="bp-ae-load-more-wrap">' +
        '<button type="button" class="btn btn-sm bp-ae-load-more" hidden>Load more</button>' +
        '<div class="bp-ae-scroll-sentinel" aria-hidden="true"></div>' +
        "</div>" +
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
      this._loadMoreEl = this.querySelector(".bp-ae-load-more");
      this._filmstripEl = this.querySelector(".bp-ae-filmstrip-track");
      this._searchEl = this.querySelector(".bp-ae-search");
      this._suggestEl = this.querySelector(".bp-ae-suggest");
      this._pillsEl = this.querySelector(".bp-ae-toolbar-pills");
      this._findBarEl = this.querySelector(".bp-ae-find-bar");
      this._sortEl = this.querySelector(".bp-ae-sort");
      this._densityLabelEl = this.querySelector(".bp-ae-density-label");
      this._scrollSentinel = this.querySelector(".bp-ae-scroll-sentinel");
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
      this._restorePrefs();

      this._searchEl.addEventListener("input", (e) => {
        this._search = e.target.value || "";
        if (this._search && this._sort === "created-desc") {
          this._sort = "relevance";
          if (this._sortEl) this._sortEl.value = "relevance";
        }
        if (!this._search && this._sort === "relevance") {
          this._sort = "created-desc";
          if (this._sortEl) this._sortEl.value = "created-desc";
        }
        this._renderToolbarPills();
        this._scheduleSuggestFetch();
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => this._loadAssets(), 250);
      });
      this._searchEl.addEventListener("focus", () => {
        this._scheduleSuggestFetch();
      });
      this._searchEl.addEventListener("blur", () => {
        clearTimeout(this._suggestHideTimer);
        this._suggestHideTimer = setTimeout(() => this._hideSuggest(), 180);
      });
      if (this._suggestEl) {
        this._suggestEl.addEventListener("mousedown", (e) => {
          e.preventDefault();
        });
      }
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

      if (this._loadMoreEl) {
        this._loadMoreEl.addEventListener("click", () => this._loadAssets(true));
      }

      if (this._sortEl) {
        this._sortEl.addEventListener("change", () => {
          this._sort = this._sortEl.value || "created-desc";
          this._savePrefs();
          this._loadAssets();
        });
      }

      this.querySelectorAll(".bp-ae-view-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
          const mode = btn.dataset.view || "grid";
          if (mode === this._viewMode) return;
          this._viewMode = mode;
          this.querySelectorAll(".bp-ae-view-btn").forEach((b) => {
            b.classList.toggle("is-active", b.dataset.view === mode);
          });
          this._syncToolbarChrome();
          this._savePrefs();
          this._renderGrid();
        });
      });

      this._bindScrollLoad();

      document.addEventListener("keydown", (e) => {
        if (!this.isConnected) return;
        if (e.key === "/" && !/input|textarea|select/i.test(e.target.tagName)) {
          e.preventDefault();
          if (this._searchEl) this._searchEl.focus();
          return;
        }
        if (!this._selected) return;
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
      if (this._searchClientId) h["X-BP-Search-Client"] = this._searchClientId;
      return h;
    }

    _ensureSearchClientId() {
      const key = "bp-search-client:" + this._dataset();
      try {
        let id = sessionStorage.getItem(key);
        if (!id) {
          id =
            typeof crypto !== "undefined" && crypto.randomUUID
              ? crypto.randomUUID()
              : "c" + Date.now().toString(36);
          sessionStorage.setItem(key, id);
        }
        return id;
      } catch (_e) {
        return "anon-" + Date.now().toString(36);
      }
    }

    _scheduleSuggestFetch() {
      clearTimeout(this._suggestTimer);
      this._suggestTimer = setTimeout(() => this._fetchSuggestions(), 120);
    }

    async _fetchSuggestions() {
      if (!this._suggestEl) return;
      const prefix = (this._search || "").trim();
      const params = new URLSearchParams({ limit: "8" });
      if (prefix) params.set("q", prefix);

      try {
        const r = await fetch(
          this._mediaBase() + "/search/suggestions?" + params.toString(),
          { credentials: "same-origin", headers: this._headers() }
        );
        if (!r.ok) return;
        const data = await r.json();
        this._suggestions = (data && data.result) || {
          recent: [],
          popular: [],
          nohits: []
        };
        this._renderSuggest();
      } catch (_e) {
        /* optional */
      }
    }

    _suggestLabel(item) {
      if (item.query) return item.query;
      return this._filtersSummary(item.filters || {});
    }

    _filtersSummary(filters) {
      const parts = [];
      if (filters.kind) parts.push(this._kindLabel(filters.kind));
      const facets = filters.facets || {};
      Object.entries(facets).forEach(([k, v]) => {
        parts.push((FACET_LABELS[k] || k) + ": " + v);
      });
      return parts.length ? parts.join(" · ") : "Filtered search";
    }

    _renderSuggest() {
      if (!this._suggestEl) return;
      const recent = this._suggestions.recent || [];
      const popular = this._suggestions.popular || [];
      const nohits = this._suggestions.nohits || [];

      if (!recent.length && !popular.length && !nohits.length) {
        this._hideSuggest();
        return;
      }

      let html = "";

      this._suggestRecent = recent;
      this._suggestPopular = popular;
      this._suggestNohits = nohits;

      if (recent.length) {
        html +=
          '<div class="bp-ae-suggest-section"><div class="bp-ae-suggest-title">Recent</div>' +
          recent
            .map((item, i) => this._suggestRow(item, "recent", i))
            .join("") +
          "</div>";
      }

      if (popular.length) {
        html +=
          '<div class="bp-ae-suggest-section"><div class="bp-ae-suggest-title">Popular</div>' +
          popular
            .map((item, i) => this._suggestRow(item, "popular", i, item.count))
            .join("") +
          "</div>";
      }

      if (nohits.length && !popular.length) {
        html +=
          '<div class="bp-ae-suggest-section"><div class="bp-ae-suggest-title">No results before</div>' +
          nohits
            .map((item, i) =>
              this._suggestRow({ query: item.query, filters: {} }, "nohits", i, item.count)
            )
            .join("") +
          "</div>";
      }

      this._suggestEl.innerHTML = html;
      this._suggestEl.hidden = false;
      if (this._searchEl) this._searchEl.setAttribute("aria-expanded", "true");

      this._suggestEl.querySelectorAll(".bp-ae-suggest-item").forEach((btn) => {
        btn.addEventListener("click", () => {
          const section = btn.dataset.section;
          const idx = parseInt(btn.dataset.index, 10);
          let payload = null;
          if (section === "popular") payload = this._suggestPopular[idx];
          else if (section === "recent") payload = this._suggestRecent[idx];
          else if (section === "nohits") {
            const row = this._suggestNohits[idx];
            if (row) payload = { query: row.query, filters: {} };
          }
          if (payload) this._applySuggestion(payload);
        });
      });
    }

    _suggestRow(item, section, index, count) {
      const label = esc(this._suggestLabel(item));
      const meta =
        typeof count === "number"
          ? '<span class="bp-ae-suggest-meta">' + count + " searches</span>"
          : item.resultCount != null
            ? '<span class="bp-ae-suggest-meta">' + item.resultCount + " assets</span>"
            : "";
      return (
        '<button type="button" class="bp-ae-suggest-item" role="option" data-section="' +
        section +
        '" data-index="' +
        index +
        '"><span class="bp-ae-suggest-label">' +
        label +
        "</span>" +
        meta +
        "</button>"
      );
    }

    _applySuggestion(item) {
      clearTimeout(this._suggestHideTimer);
      const filters = item.filters || {};
      this._search = item.query || "";
      if (this._searchEl) this._searchEl.value = this._search;
      this._filterKind = filters.kind || "all";
      this._facetSelections = Object.assign({}, filters.facets || {});
      this._sort = this._search ? "relevance" : "created-desc";
      if (this._sortEl) this._sortEl.value = this._sort;
      this._renderFilters();
      this._hideSuggest();
      this._renderToolbarPills();
      this._loadAssets();
    }

    _hideSuggest() {
      if (!this._suggestEl) return;
      this._suggestEl.hidden = true;
      this._suggestEl.innerHTML = "";
      if (this._searchEl) this._searchEl.setAttribute("aria-expanded", "false");
    }

    _mediaBase() {
      return "/v1/media/" + encodeURIComponent(this._dataset());
    }

    _prefsKey() {
      return STORAGE_KEY + ":" + this._dataset();
    }

    _restorePrefs() {
      try {
        const raw = sessionStorage.getItem(this._prefsKey());
        if (!raw) return;
        const prefs = JSON.parse(raw);
        if (prefs.viewMode === "grid" || prefs.viewMode === "list") {
          this._viewMode = prefs.viewMode;
          this.querySelectorAll(".bp-ae-view-btn").forEach((b) => {
            b.classList.toggle("is-active", b.dataset.view === this._viewMode);
          });
        }
        if (prefs.sort && SORT_OPTIONS.some((o) => o.id === prefs.sort)) {
          this._sort = prefs.sort;
          if (this._sortEl) this._sortEl.value = this._sort;
        }
        this._syncToolbarChrome();
      } catch (_e) {
        /* ignore */
      }
    }

    _savePrefs() {
      try {
        sessionStorage.setItem(
          this._prefsKey(),
          JSON.stringify({ viewMode: this._viewMode, sort: this._sort })
        );
      } catch (_e) {
        /* ignore */
      }
    }

    _syncToolbarChrome() {
      const list = this._viewMode === "list";
      if (this._densityLabelEl) this._densityLabelEl.hidden = list;
      if (this._gridEl) this._gridEl.classList.toggle("bp-ae-list", list);
    }

    _effectiveSort() {
      if (this._sort === "relevance" && !this._search) return "created-desc";
      return this._sort || "created-desc";
    }

    _bindScrollLoad() {
      if (!this._scrollSentinel || typeof IntersectionObserver === "undefined") return;
      if (this._scrollObserver) this._scrollObserver.disconnect();
      this._scrollObserver = new IntersectionObserver(
        (entries) => {
          const hit = entries.find((e) => e.isIntersecting);
          if (!hit || this._loading) return;
          if (this._assets.length >= this._total || this._total === 0) return;
          this._loadAssets(true);
        },
        { root: this._gridWrapEl, rootMargin: "120px" }
      );
      this._scrollObserver.observe(this._scrollSentinel);
    }

    _updateLoadMoreBtn() {
      if (!this._loadMoreEl) return;
      const remaining = Math.max(0, this._total - this._assets.length);
      if (remaining <= 0) {
        this._loadMoreEl.hidden = true;
        return;
      }
      this._loadMoreEl.hidden = false;
      this._loadMoreEl.textContent =
        "Load more · " + remaining.toLocaleString() + " remaining";
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

    _clearAllFilters() {
      this._search = "";
      if (this._searchEl) this._searchEl.value = "";
      this._filterKind = "all";
      this._facetSelections = {};
      this._collectionId = null;
      this._inspectorMode = "none";
      this._shareInfo = null;
      this._selected = null;
      this._renderFilters();
      this._renderCollections();
      this._showEmptyInspector();
      this._renderFacets();
      this._renderToolbarPills();
      this._loadAssets();
    }

    _renderToolbarPills() {
      if (!this._pillsEl) return;
      const entries = this._activeFacetEntries();
      if (!entries.length) {
        this._pillsEl.innerHTML = "";
        this._renderFindBar();
        return;
      }
      this._pillsEl.innerHTML =
        entries
          .map(([field, value]) => {
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
          .join("") +
        (entries.length > 1
          ? '<button type="button" class="bp-ae-pill bp-ae-pill--clear">Clear all</button>'
          : "");
      this._pillsEl.querySelectorAll(".bp-ae-pill").forEach((btn) => {
        if (btn.classList.contains("bp-ae-pill--clear")) {
          btn.addEventListener("click", () => this._clearAllFilters());
          return;
        }
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
      this._renderFindBar();
    }

    _renderFindBar() {
      if (!this._findBarEl) return;
      const entries = this._activeFacetEntries();
      if (!entries.length) {
        this._findBarEl.hidden = true;
        this._findBarEl.innerHTML = "";
        return;
      }
      const total = this._total;
      const scope =
        total > 0
          ? total === 1
            ? "1 asset matches"
            : total.toLocaleString() + " assets match"
          : "No assets match";
      this._findBarEl.hidden = false;
      this._findBarEl.innerHTML =
        '<span class="bp-ae-find-scope">' +
        esc(scope) +
        '</span><span class="bp-ae-find-hint text-muted">Use Refine or clear filters to broaden</span>';
    }

    _emptyMessage() {
      if (this._activeFacetEntries().length) {
        return "No assets match these filters — try removing one or search for something broader.";
      }
      if (this._collectionId) {
        return "This folder is empty — upload files or add assets from All assets.";
      }
      return "No assets yet — upload a file to get started.";
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

    async _loadAssets(append) {
      if (this._loadAbort) this._loadAbort.abort();
      this._loadAbort = new AbortController();
      const signal = this._loadAbort.signal;

      if (!append) {
        this._offset = 0;
        this._total = 0;
      }

      this._loading = true;
      if (this._loadingEl) this._loadingEl.hidden = false;
      if (!append && this._emptyEl) this._emptyEl.hidden = true;
      if (this._gridWrapEl) this._gridWrapEl.classList.add("is-loading");
      if (this._loadMoreEl) this._loadMoreEl.disabled = true;

      const params = new URLSearchParams({
        limit: String(this._pageSize),
        offset: String(this._offset),
        sort: this._effectiveSort()
      });

      let url;

      if (this._collectionId) {
        if (this._search) params.set("q", this._search);
        url = this._mediaBase() + "/collections/" + encodeURIComponent(this._collectionId) + "/assets?" + params.toString();
      } else {
        params.set("facets", "kind,tags,mimeType,processing,visibility,status");
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
          headers: this._headers(),
          signal: signal
        });
        if (!r.ok) throw new Error(String(r.status));
        const data = await r.json();
        const rows = (data && data.result && data.result.hits) || [];
        if (data && data.result && data.result.facets) {
          this._facets = data.result.facets;
        }
        if (data && data.result && typeof data.result.total === "number") {
          this._total = data.result.total;
        }
        const page = rows
          .map((row) => mergeHit(row))
          .filter((d) => assetUrl(d) || assetThumbUrl(d));
        if (append) {
          this._assets = this._assets.concat(page);
        } else {
          this._assets = page;
        }
        this._offset = this._assets.length;
      } catch (err) {
        if (err && err.name === "AbortError") return;
        if (!append) this._assets = [];
      } finally {
        if (signal.aborted) return;
        this._loading = false;
        if (this._loadingEl) this._loadingEl.hidden = true;
        if (this._gridWrapEl) {
          this._gridWrapEl.classList.remove("is-loading");
          this._gridWrapEl.classList.add("is-loaded");
        }
        if (this._loadMoreEl) this._loadMoreEl.disabled = false;
        this._updateLoadMoreBtn();
        this._renderFacets();
        this._renderToolbarPills();
        this._renderGrid();
      }
    }

    _cardThumb(doc) {
      const kind = doc.bp_asset_kind || "other";
      const thumbUrl = assetThumbUrl(doc);
      const previewUrl = doc.previewUrl || thumbUrl;
      if (kind === "image" && thumbUrl) {
        return '<img src="' + esc(thumbUrl) + '" alt="" loading="lazy" />';
      }
      if ((kind === "video" || kind === "document") && previewUrl && previewUrl !== thumbUrl) {
        return (
          '<img src="' +
          esc(previewUrl) +
          '" alt="" loading="lazy" class="bp-ae-preview-thumb" />'
        );
      }
      const label =
        kind === "document" ? "DOC" : kind === "video" ? "VID" : kind === "audio" ? "AUD" : kind.toUpperCase();
      return '<div class="bp-ae-file-icon">' + esc(label) + "</div>";
    }

    _listHeadHtml() {
      return (
        '<div class="bp-ae-list-head" aria-hidden="true">' +
        "<span></span><span>Name</span><span>Kind</span><span>Format</span><span>Size</span>" +
        "</div>"
      );
    }

    _renderListRow(doc) {
      const id = doc._id || "";
      const title = esc(doc.title || (doc.fileInfo && doc.fileInfo.originalName) || id);
      const kind = esc(doc.bp_asset_kind || "other");
      const mime = esc(assetMime(doc) || "—");
      const size = esc(formatSize(doc.fileInfo && doc.fileInfo.size) || "—");
      const sel = this._selected && this._selected._id === id ? " is-selected" : "";
      return (
        '<button type="button" class="bp-ae-list-row' +
        sel +
        '" data-id="' +
        esc(id) +
        '">' +
        '<span class="bp-ae-list-thumb">' +
        this._cardThumb(doc) +
        "</span>" +
        '<span class="bp-ae-list-title">' +
        title +
        "</span>" +
        '<span class="bp-ae-list-kind">' +
        kind +
        "</span>" +
        '<span class="bp-ae-list-mime">' +
        mime +
        "</span>" +
        '<span class="bp-ae-list-size">' +
        size +
        "</span></button>"
      );
    }

    _visibleAssets() {
      return this._assets;
    }

    _renderGrid() {
      const items = this._visibleAssets();
      if (this._countEl) {
        this._countEl.classList.remove("bp-ae-status-error");
        this._countEl.textContent = this._countLabel();
      }

      if (!items.length) {
        if (this._gridEl) this._gridEl.innerHTML = "";
        if (this._emptyEl) {
          this._emptyEl.hidden = false;
          this._emptyEl.textContent = this._emptyMessage();
        }
        if (this._loadMoreEl) this._loadMoreEl.hidden = true;
        this._renderFilmstrip([]);
        return;
      }

      if (this._emptyEl) this._emptyEl.hidden = true;

      if (this._gridEl) {
        this._gridEl.classList.toggle("bp-ae-list", this._viewMode === "list");
        if (this._viewMode === "list") {
          this._gridEl.innerHTML =
            this._listHeadHtml() + items.map((doc) => this._renderListRow(doc)).join("");
        } else {
          this._gridEl.innerHTML = items
            .map((doc) => {
              const id = doc._id || "";
              const title = esc(doc.title || (doc.fileInfo && doc.fileInfo.originalName) || id);
              const sel = this._selected && this._selected._id === id ? " is-selected" : "";
              const proc = (assetPayload(doc).bp_processing_status || "").toLowerCase();
              const procBadge =
                proc === "processing"
                  ? '<span class="bp-ae-card-badge is-pulse">···</span>'
                  : "";
              return (
                '<button type="button" class="bp-ae-card media-card' +
                sel +
                '" data-id="' +
                esc(id) +
                '">' +
                procBadge +
                '<div class="media-thumb">' +
                this._cardThumb(doc) +
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
        }

        this._gridEl.querySelectorAll(".bp-ae-card, .bp-ae-list-row").forEach((btn) => {
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
      this._scrollSelectedIntoView(doc);
      this._renderAssetInspector(doc);
    }

    _scrollSelectedIntoView(doc) {
      if (!this._gridEl || !doc || !doc._id) return;
      const el = Array.prototype.find.call(
        this._gridEl.querySelectorAll("[data-id]"),
        (node) => node.dataset.id === doc._id
      );
      if (el) el.scrollIntoView({ block: "nearest", behavior: "smooth" });
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
      const tags = payload.tags || doc.tags;
      const tagList = Array.isArray(tags) ? tags.filter(Boolean) : [];
      const preview = this._inspectorPreview(doc, kind, previewUrl);

      let tagsHtml = "";
      if (tagList.length) {
        tagsHtml =
          "<dt>Tags</dt><dd>" +
          tagList
            .map((t) => '<span class="bp-ae-tag">' + esc(String(t)) + "</span>")
            .join(" ") +
          "</dd>";
      }

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
        tagsHtml +
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

    _inspectorPreview(doc, kind, previewUrl) {
      const originalUrl = doc.originalUrl || assetUrl(doc);
      if (kind === "image" && previewUrl) {
        return (
          '<div class="bp-ae-inspector-preview"><img class="bp-ae-inspector-img" src="' +
          esc(previewUrl) +
          '" alt="" /></div>'
        );
      }
      if ((kind === "video" || kind === "document") && previewUrl && previewUrl !== originalUrl) {
        return (
          '<div class="bp-ae-inspector-preview"><img class="bp-ae-inspector-img" src="' +
          esc(previewUrl) +
          '" alt="" /><span class="bp-ae-preview-badge">' +
          esc(kind === "video" ? "Video preview" : "Preview") +
          "</span></div>"
        );
      }
      const label =
        kind === "document" ? "Document" : kind === "video" ? "Video" : kind === "audio" ? "Audio" : kind;
      return '<div class="bp-ae-inspector-icon">' + esc(label) + "</div>";
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
      const loaded = this._assets.length;
      const total = this._total;
      const col = this._currentCollection();

      if (col) {
        if (total > loaded) {
          return (
            "Showing " +
            loaded +
            " of " +
            total +
            " in " +
            (col.title || col.id)
          );
        }
        return loaded + " in " + (col.title || col.id);
      }

      if (total > loaded) {
        return "Showing " + loaded + " of " + total + " assets";
      }
      if (total === loaded && total > 0) {
        return total === 1 ? "1 asset" : total + " assets";
      }
      return loaded === 1 ? "1 asset" : loaded + " assets";
    }
  }

  customElements.define("bp-asset-explorer", BpAssetExplorer);
})();
