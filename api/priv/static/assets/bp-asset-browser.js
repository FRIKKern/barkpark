// bp-asset-browser — native mediaAsset document browser (Media plugin).
//
// Modal grid over GET /v1/data/query/:dataset/mediaAsset. Used standalone
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
      this._onSelect = null;
      this._accept = "image/*";
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
        this._renderGrid();
      });
      document.addEventListener("keydown", (e) => {
        if (this._open && e.key === "Escape") this.close();
      });
    }

    open(opts) {
      opts = opts || {};
      this._onSelect = opts.onSelect || null;
      this._accept = opts.accept || this.getAttribute("accept") || "image/*";
      if (opts.dataset) this.setAttribute("dataset", opts.dataset);
      if (opts.token) this.setAttribute("data-token", opts.token);

      this.hidden = false;
      this._open = true;
      this._filter = "";
      if (this._search) this._search.value = "";
      this._loadAssets();
      if (this._search) this._search.focus();
    }

    close() {
      this._open = false;
      this.hidden = true;
      this._onSelect = null;
    }

    _dataset() {
      return this.getAttribute("dataset") || "production";
    }

    _token() {
      return this.getAttribute("data-token") || "";
    }

    _acceptKind() {
      const a = this._accept || "";
      if (a.indexOf("image") >= 0) return "image";
      if (a.indexOf("video") >= 0) return "video";
      if (a.indexOf("audio") >= 0) return "audio";
      return null;
    }

    async _loadAssets() {
      if (this._loading) this._loading.hidden = false;
      if (this._empty) this._empty.hidden = true;
      if (this._grid) this._grid.innerHTML = "";

      const dataset = this._dataset();
      const kind = this._acceptKind();
      let url =
        "/v1/data/query/" +
        encodeURIComponent(dataset) +
        "/mediaAsset?perspective=drafts&limit=200&order=updated_at_desc";

      if (kind) {
        url +=
          "&filter[bp_asset_kind][eq]=" + encodeURIComponent(kind);
      }

      const headers = { Accept: "application/json" };
      const tok = this._token();
      if (tok) headers["Authorization"] = "Bearer " + tok;

      try {
        const r = await fetch(url, { credentials: "same-origin", headers: headers });
        if (!r.ok) throw new Error("HTTP " + r.status);
        const data = await r.json();
        const docs =
          (data && data.result && data.result.documents) ||
          (data && data.documents) ||
          [];
        this._assets = docs.filter((d) => assetUrl(d));
        this._renderGrid();
      } catch (_e) {
        this._assets = [];
        if (this._grid) {
          this._grid.innerHTML =
            '<div class="bp-ab-grid-empty text-sm text-muted">Could not load media library.</div>';
        }
      } finally {
        if (this._loading) this._loading.hidden = true;
      }
    }

    _matchesFilter(doc) {
      if (!this._filter) return true;
      const q = this._filter.toLowerCase();
      const title = (doc.title || "").toLowerCase();
      const orig =
        (doc.fileInfo && doc.fileInfo.originalName) || "";
      return title.indexOf(q) >= 0 || orig.toLowerCase().indexOf(q) >= 0;
    }

    _renderGrid() {
      if (!this._grid) return;
      const items = this._assets.filter((d) => this._matchesFilter(d));

      if (!items.length) {
        this._grid.innerHTML = "";
        if (this._empty) this._empty.hidden = false;
        return;
      }

      if (this._empty) this._empty.hidden = true;

      this._grid.innerHTML = items
        .map((doc) => {
          const url = esc(assetUrl(doc));
          const title = esc(doc.title || doc.fileInfo.originalName || doc._id);
          const id = esc(doc._id || "");
          const mime = esc(assetMime(doc));
          const kind = assetKind(doc);
          const thumb =
            kind === "image"
              ? '<img src="' + url + '" alt="" loading="lazy" />'
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
            thumb +
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
