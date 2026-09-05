// bp-asset-browser — native mediaAsset document browser (Media plugin).
//
// Modal grid over GET /v1/media/:dataset/search. Used standalone
// or opened from bp-media-picker ("Browse library"). Emits
// CustomEvent("bp-asset-select", { detail: { id, url, title, mime, asset } }).

(function () {
  function esc(s) {
    return String(s || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/"/g, "&quot;");
  }

  function assetKind(doc) {
    return (doc && doc.bp_asset_kind) || "other";
  }

  function assetUrl(doc) {
    const fi = doc && doc.fileInfo;
    return (fi && fi.url) || "";
  }

  function assetMime(doc) {
    const fi = doc && doc.fileInfo;
    return (fi && fi.mimeType) || "";
  }

  class BpAssetBrowser extends HTMLElement {
    constructor() {
      super();
      this._open = false;
      this._assets = [];
      this._filter = "";
      this._searchTimer = null;
      this._onSelect = null;
      this._accept = "image/*";
      this._loadGeneration = 0;
      this._requestContext = null;
    }

    connectedCallback() {
      if (this._built) return;
      this._built = true;
      this.hidden = true;
      this.className = "bp-ab-overlay";
      this.innerHTML =
        '<div class="bp-ab-dialog" role="dialog" aria-modal="true">' +
        '<header class="bp-ab-header">' +
        '<h2 class="bp-ab-title">Media library</h2>' +
        '<input type="search" class="bp-ab-search form-input" placeholder="Search assets…" />' +
        '<button type="button" class="bp-ab-close btn btn-sm" aria-label="Close">✕</button>' +
        "</header>" +
        '<div class="bp-ab-body">' +
        '<div class="bp-ab-grid media-grid"></div>' +
        '<div class="bp-ab-empty text-sm text-muted" hidden>No matching assets</div>' +
        '<div class="bp-ab-loading text-sm text-muted">Loading…</div>' +
        "</div>" +
        "</div>";

      this._dialog = this.querySelector(".bp-ab-dialog");
      this._grid = this.querySelector(".bp-ab-grid");
      this._empty = this.querySelector(".bp-ab-empty");
      this._loading = this.querySelector(".bp-ab-loading");
      this._search = this.querySelector(".bp-ab-search");

      this.querySelector(".bp-ab-close").addEventListener("click", () => this.close());
      this.addEventListener("click", (e) => {
        if (e.target === this) this.close();
      });
      this._search.addEventListener("input", (e) => {
        this._filter = e.target.value || "";
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => this._loadAssets(), 250);
      });
      document.addEventListener("keydown", (e) => {
        if (this._open && e.key === "Escape") this.close();
      });
    }

    open(opts) {
      opts = opts || {};
      clearTimeout(this._searchTimer);
      this._searchTimer = null;
      this._onSelect = opts.onSelect || null;
      const hasOwn = (key) => Object.prototype.hasOwnProperty.call(opts, key);
      this._requestContext = {
        dataset: hasOwn("dataset") ? opts.dataset || "production" : this._dataset(),
        token: hasOwn("token") ? opts.token || "" : this._token(),
        scopePrefix: hasOwn("scopePrefix") ? opts.scopePrefix || "" : this._scopePrefix(),
        accept: hasOwn("accept") ? opts.accept || "image/*" : this.getAttribute("accept") || "image/*"
      };
      this._accept = this._requestContext.accept;

      this.hidden = false;
      this._open = true;
      this._filter = "";
      if (this._search) this._search.value = "";
      this._assets = [];
      if (this._grid) this._grid.innerHTML = "";
      if (this._empty) this._empty.hidden = true;
      this._loadAssets();
      if (this._search) this._search.focus();
    }

    close() {
      clearTimeout(this._searchTimer);
      this._searchTimer = null;
      this._open = false;
      this._loadGeneration++;
      this._requestContext = null;
      this.hidden = true;
      this._onSelect = null;
    }

    _dataset() {
      return this.getAttribute("dataset") || "production";
    }

    _token() {
      return this.getAttribute("data-token") || "";
    }

    _scopePrefix() {
      return this.getAttribute("scope-prefix") || "";
    }

    _acceptKind(accept) {
      const a = accept == null ? this._accept || "" : accept;
      if (a.indexOf("image") >= 0) return "image";
      if (a.indexOf("video") >= 0) return "video";
      if (a.indexOf("audio") >= 0) return "audio";
      return null;
    }

  async _loadAssets() {
      const generation = ++this._loadGeneration;
      const context = this._requestContext || {
        dataset: this._dataset(),
        token: this._token(),
        scopePrefix: this._scopePrefix(),
        accept: this._accept
      };
      if (this._loading) this._loading.hidden = false;
      if (this._empty) this._empty.hidden = true;
      if (this._grid) this._grid.innerHTML = "";

      const dataset = context.dataset;
      const kind = this._acceptKind(context.accept);
      const params = new URLSearchParams({
        limit: "200",
        offset: "0",
        sort: this._filter ? "relevance" : "updated-desc"
      });
      if (kind) params.set("facet.kind", kind);
      if (this._filter) params.set("q", this._filter);

      const url =
        context.scopePrefix +
        "/v1/media/" +
        encodeURIComponent(dataset) +
        "/search?" +
        params.toString();

      const headers = { Accept: "application/json" };
      const tok = context.token;
      if (tok) headers["Authorization"] = "Bearer " + tok;

      try {
        const r = await fetch(url, { credentials: "same-origin", headers: headers });
        if (!r.ok) throw new Error("HTTP " + r.status);
        const data = await r.json();
        if (generation !== this._loadGeneration || context !== this._requestContext || !this._open) return;
        const hits = (data && data.result && data.result.hits) || [];
        this._assets = hits.map((hit) => this._hitToDoc(hit)).filter((d) => assetUrl(d));
        this._renderGrid();
      } catch (_e) {
        if (generation !== this._loadGeneration || context !== this._requestContext || !this._open) return;
        this._assets = [];
        if (this._grid) {
          this._grid.innerHTML =
            '<div class="bp-ab-grid-empty text-sm text-muted">Could not load media library.</div>';
        }
      } finally {
        if (generation === this._loadGeneration && this._loading) this._loading.hidden = true;
      }
    }

    _hitToDoc(hit) {
      const asset = (hit && hit.asset) || {};
      const url = hit.originalUrl || hit.url || "";
      return {
        _id: hit.assetDocId || asset._id || hit.id,
        title: asset.title || hit.originalName || hit.filename || hit.id,
        bp_asset_kind: asset.bp_asset_kind || hit.kind || "other",
        fileInfo: {
          url: url,
          thumbUrl: hit.thumbnailUrl || hit.previewUrl || url,
          mimeType: hit.mimeType || "",
          originalName: hit.originalName || hit.filename || ""
        },
        _blobId: hit.id
      };
    }

    _renderGrid() {
      if (!this._grid) return;
      const items = this._assets;

      if (!items.length) {
        this._grid.innerHTML = "";
        if (this._empty) this._empty.hidden = false;
        return;
      }

      if (this._empty) this._empty.hidden = true;

      this._grid.innerHTML = items
        .map((doc) => {
          const url = esc(assetUrl(doc));
          const thumb = esc((doc.fileInfo && doc.fileInfo.thumbUrl) || assetUrl(doc));
          const title = esc(doc.title || doc.fileInfo.originalName || doc._id);
          const id = esc(doc._id || "");
          const mime = esc(assetMime(doc));
          const kind = assetKind(doc);
          const cell =
            kind === "image"
              ? '<img src="' + thumb + '" alt="" loading="lazy" />'
              : '<div class="bp-ab-file-icon">' + esc(kind) + "</div>";
          return (
            '<button type="button" class="bp-ab-card media-card" data-id="' +
            id +
            '" data-url="' +
            url +
            '" data-mime="' +
            mime +
            '" data-title="' +
            title +
            '">' +
            cell +
            '<span class="bp-ab-card-title">' +
            title +
            "</span></button>"
          );
        })
        .join("");

      this._grid.querySelectorAll(".bp-ab-card").forEach((btn) => {
        btn.addEventListener("click", () => this._pick(btn));
      });
    }

    _pick(btn) {
      const detail = {
        id: btn.dataset.id,
        url: btn.dataset.url,
        title: btn.dataset.title,
        mime: btn.dataset.mime,
        asset: this._assets.find((d) => d._id === btn.dataset.id)
      };

      this.dispatchEvent(
        new CustomEvent("bp-asset-select", {
          bubbles: true,
          composed: true,
          detail: detail
        })
      );

      if (typeof this._onSelect === "function") {
        this._onSelect(detail);
      }

      this.close();
    }
  }

  customElements.define("bp-asset-browser", BpAssetBrowser);

  window.BpAssetBrowser = {
    ensure() {
      let el = document.querySelector("bp-asset-browser");
      if (!el) {
        el = document.createElement("bp-asset-browser");
        document.body.appendChild(el);
      }
      return el;
    }
  };
})();
