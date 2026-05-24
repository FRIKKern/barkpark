// bp-reference-picker — Studio reference Web Component (Task #12 WI2 v1).
//
// Typeahead reference picker. Reads `value` (doc id) and `ref-type`
// (target schema) attributes; optional `dataset` (default "production").
// Search uses `/v1/data/search/:dataset` with optional `type=` filter and
// feeds Barkpark core search intelligence via X-BP-Search-* headers.
//
// Selected state renders a Sanity-style pill (.ref-selected) with the
// referenced doc's title and a Remove button. The hidden input value
// is always the doc id string (matches v1 reference-field persistence
// model) — no JSON, no `_ref`/`_type` envelope.
//
// Emits CustomEvent("bp-change", {bubbles:true, detail:{value: docId | ""}})
// caught by BarkparkFieldBridge on the wrapper div.
//
// Contract: docs/studio/web-components.md

function bpRefEsc(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

class BpReferencePicker extends HTMLElement {
  constructor() {
    super();
    this._value = "";
    this._refType = "";
    this._dataset = "production";
    this._loading = false;
    this._debounceMs = 200;
    this._debounceTimer = null;
    this._mounted = false;
    this._suggestions = { recent: [], popular: [], nohits: [] };
    this._suggestRecent = [];
    this._suggestPopular = [];
    this._suggestNohits = [];
    this._searchClientId = null;
    this._lastSearchEventId = null;
  }

  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;
    this._value = this.getAttribute("value") || "";
    this._refType = this.getAttribute("ref-type") || "";
    this._dataset = this.getAttribute("dataset") || "production";
    this._searchClientId = this._ensureSearchClientId();
    this._render();
    if (this._value) this._loadSelectedTitle();
  }

  disconnectedCallback() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
  }

  _render() {
    this.replaceChildren();
    if (this._value) {
      this._renderSelected();
    } else {
      this._renderSearch();
    }
  }

  _renderSelected() {
    const wrap = document.createElement("div");
    wrap.className = "ref-field bp-ref-selected-wrap";

    const pill = document.createElement("div");
    pill.className = "ref-selected";

    const info = document.createElement("div");
    info.className = "ref-selected-info";

    const title = document.createElement("span");
    title.className = "ref-selected-title";
    title.textContent = this._selectedTitle || this._value;
    info.appendChild(title);

    const typeSpan = document.createElement("span");
    typeSpan.className = "ref-selected-type";
    typeSpan.textContent = this._refType;
    info.appendChild(typeSpan);

    pill.appendChild(info);

    const actions = document.createElement("div");
    actions.style.cssText = "display:flex;gap:6px;";

    const change = document.createElement("button");
    change.type = "button";
    change.className = "btn btn-sm";
    change.textContent = "Change";
    change.addEventListener("click", () => this._switchToSearch());
    actions.appendChild(change);

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "btn btn-destructive btn-sm";
    remove.textContent = "Remove";
    remove.addEventListener("click", () => this._clear());
    actions.appendChild(remove);

    pill.appendChild(actions);
    wrap.appendChild(pill);
    this.appendChild(wrap);
  }

  _renderSearch() {
    const wrap = document.createElement("div");
    wrap.className = "ref-field bp-ref-search-wrap";
    wrap.style.cssText = "position:relative;";

    const input = document.createElement("input");
    input.type = "text";
    input.className = "form-input bp-ref-search-input";
    input.placeholder = `Search ${this._refType || "documents"}…`;
    input.autocomplete = "off";
    input.setAttribute("aria-expanded", "false");
    input.setAttribute("aria-controls", "bp-ref-suggest-list");
    input.addEventListener("input", (e) => this._onSearchInput(e.target.value));
    input.addEventListener("focus", () => this._onSearchInput(input.value));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") this._hideDropdown();
    });
    wrap.appendChild(input);

    const dropdown = document.createElement("div");
    dropdown.className = "bp-ref-dropdown";
    dropdown.id = "bp-ref-suggest-list";
    dropdown.hidden = true;
    dropdown.setAttribute("role", "listbox");
    wrap.appendChild(dropdown);

    this.appendChild(wrap);
    this._searchInput = input;
    this._dropdown = dropdown;
  }

  _switchToSearch() {
    this._value = "";
    this._selectedTitle = "";
    this._render();
    if (this._searchInput) this._searchInput.focus();
  }

  _clear() {
    this._value = "";
    this._selectedTitle = "";
    this._render();
    this._emit("");
  }

  _select(doc) {
    this._value = doc.id;
    this._selectedTitle = doc.title || doc.id;
    this._hideDropdown();
    this._render();
    this._emit(this._value);
  }

  _onSearchInput(term) {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => this._search(term), this._debounceMs);
  }

  _ensureSearchClientId() {
    const key = "bp-search-client:documents:" + this._dataset;
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

  _searchHeaders() {
    const h = { Accept: "application/json" };
    if (this._searchClientId) h["X-BP-Search-Client"] = this._searchClientId;
    if (this._lastSearchEventId) h["X-BP-Search-Parent"] = this._lastSearchEventId;
    h["X-BP-Search-Source"] = "studio-picker";
    return h;
  }

  _captureSearchEventId(body) {
    if (body && body.searchEventId) {
      this._lastSearchEventId = body.searchEventId;
    }
  }

  async _search(term) {
    const t = (term || "").trim();

    if (!t) {
      await this._fetchSuggestions("");
      this._renderSuggestDropdown();
      return;
    }

    try {
      const matches = await this._fetchSearchResults(t);
      this._renderResultDropdown(matches);
    } catch (_e) {
      this._hideDropdown();
    }
  }

  _searchUrl(query) {
    const params = new URLSearchParams({
      q: query,
      perspective: "published",
      limit: "50"
    });
    if (this._refType) params.set("type", this._refType);
    return (
      "/v1/data/search/" +
      encodeURIComponent(this._dataset) +
      "?" +
      params.toString()
    );
  }

  async _fetchSearchResults(query) {
    const res = await fetch(this._searchUrl(query), {
      credentials: "same-origin",
      headers: this._searchHeaders()
    });
    if (!res.ok) return [];
    const body = await res.json();
    this._captureSearchEventId(body);
    const docs = body.documents || [];
    return docs
      .map((d) => ({ id: d._id || d.id || "", title: d.title || d._id || "" }))
      .filter((d) => d.id);
  }

  async _fetchSuggestions(prefix) {
    const params = new URLSearchParams({ limit: "8" });
    if (prefix) params.set("q", prefix);
    const url =
      "/v1/data/search/" +
      encodeURIComponent(this._dataset) +
      "/suggestions?" +
      params.toString();

    try {
      const res = await fetch(url, {
        credentials: "same-origin",
        headers: this._searchHeaders()
      });
      if (!res.ok) return;
      const data = await res.json();
      this._suggestions = (data && data.result) || {
        recent: [],
        popular: [],
        nohits: []
      };
    } catch (_e) {
      /* optional */
    }
  }

  _renderSuggestDropdown() {
    if (!this._dropdown) return;

    const recent = this._suggestions.recent || [];
    const popular = this._suggestions.popular || [];
    const nohits = this._suggestions.nohits || [];

    this._suggestRecent = recent;
    this._suggestPopular = popular;
    this._suggestNohits = nohits;

    if (!recent.length && !popular.length && !nohits.length) {
      this._hideDropdown();
      return;
    }

    let html = "";

    if (recent.length) {
      html +=
        '<div class="bp-ref-suggest-section"><div class="bp-ref-suggest-title">Recent</div>' +
        recent.map((item, i) => this._suggestRow(item, "recent", i)).join("") +
        "</div>";
    }

    if (popular.length) {
      html +=
        '<div class="bp-ref-suggest-section"><div class="bp-ref-suggest-title">Popular</div>' +
        popular.map((item, i) => this._suggestRow(item, "popular", i, item.count)).join("") +
        "</div>";
    }

    if (nohits.length) {
      html +=
        '<div class="bp-ref-suggest-section"><div class="bp-ref-suggest-title">No matches before</div>' +
        nohits
          .map((item, i) =>
            this._suggestRow({ query: item.query, filters: {} }, "nohits", i, item.count)
          )
          .join("") +
        "</div>";
    }

    this._dropdown.innerHTML = html;
    this._dropdown.hidden = false;
    if (this._searchInput) this._searchInput.setAttribute("aria-expanded", "true");

    this._dropdown.querySelectorAll(".bp-ref-suggest-item").forEach((btn) => {
      btn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const section = btn.dataset.section;
        const idx = parseInt(btn.dataset.index, 10);
        let payload = null;
        if (section === "popular") payload = this._suggestPopular[idx];
        else if (section === "recent") payload = this._suggestRecent[idx];
        else if (section === "nohits") {
          const row = this._suggestNohits[idx];
          if (row) payload = { query: row.query, filters: {} };
        }
        if (payload && payload.query) {
          if (this._searchInput) this._searchInput.value = payload.query;
          this._search(payload.query);
        }
      });
    });
  }

  _suggestRow(item, section, index, count) {
    const label = bpRefEsc(item.query || "");
    const meta =
      typeof count === "number"
        ? '<span class="bp-ref-suggest-meta">' + count + " searches</span>"
        : item.resultCount != null
          ? '<span class="bp-ref-suggest-meta">' + item.resultCount + " docs</span>"
          : "";
    return (
      '<button type="button" class="bp-ref-suggest-item" role="option" data-section="' +
      section +
      '" data-index="' +
      index +
      '"><span class="bp-ref-suggest-label">' +
      label +
      "</span>" +
      meta +
      "</button>"
    );
  }

  _renderResultDropdown(matches) {
    if (!this._dropdown) return;
    this._dropdown.replaceChildren();

    if (!matches.length) {
      const empty = document.createElement("div");
      empty.className = "bp-ref-dropdown-empty";
      empty.textContent = "No matches";
      this._dropdown.appendChild(empty);
      this._dropdown.hidden = false;
      if (this._searchInput) this._searchInput.setAttribute("aria-expanded", "true");
      return;
    }

    for (const doc of matches) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "bp-ref-dropdown-item";
      btn.setAttribute("role", "option");
      btn.textContent = doc.title || doc.id;
      btn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this._select(doc);
      });
      this._dropdown.appendChild(btn);
    }

    this._dropdown.hidden = false;
    if (this._searchInput) this._searchInput.setAttribute("aria-expanded", "true");
  }

  _hideDropdown() {
    if (!this._dropdown) return;
    this._dropdown.hidden = true;
    this._dropdown.replaceChildren();
    if (this._searchInput) this._searchInput.setAttribute("aria-expanded", "false");
  }

  async _loadSelectedTitle() {
    if (!this._refType) {
      await this._loadSelectedTitleViaSearch();
      return;
    }
    try {
      const url =
        "/v1/data/doc/" +
        encodeURIComponent(this._dataset) +
        "/" +
        encodeURIComponent(this._refType) +
        "/" +
        encodeURIComponent(this._value);
      const res = await fetch(url, { credentials: "same-origin" });
      if (!res.ok) return;
      const body = await res.json();
      const doc = (body && body.result) || body || {};
      const title = doc.title || doc._id || "";
      if (title && this._value) {
        this._selectedTitle = title;
        if (this._mounted && this._value) this._render();
      }
    } catch (_e) {
      /* pill keeps id */
    }
  }

  async _loadSelectedTitleViaSearch() {
    const id = (this._value || "").trim();
    if (!id) return;
    try {
      const res = await fetch(this._searchUrl(id), {
        credentials: "same-origin",
        headers: this._searchHeaders()
      });
      if (!res.ok) return;
      const body = await res.json();
      const docs = body.documents || [];
      const match = docs.find((d) => (d._id || d.id) === id) || docs[0] || null;
      const title = match && (match.title || match._id || match.id);
      if (title && this._value) {
        this._selectedTitle = title;
        if (this._mounted && this._value) this._render();
      }
    } catch (_e) {
      /* pill keeps id */
    }
  }

  _emit(value) {
    this.dispatchEvent(
      new CustomEvent("bp-change", {
        bubbles: true,
        composed: false,
        detail: { value }
      })
    );
  }

  get value() {
    return this._value;
  }

  set value(v) {
    if (v === this._value) return;
    this._value = v || "";
    this._render();
    if (this._value) this._loadSelectedTitle();
  }
}

customElements.define("bp-reference-picker", BpReferencePicker);
