// bp-reference-picker — Studio reference Web Component (Task #12 WI2 v1).
//
// Typeahead reference picker. Reads `value` (doc id) and `ref-type`
// (target schema) attributes; optional `dataset` (default "production").
// On user search, fetches /v1/data/query/<dataset>/<refType> once and
// filters client-side by the document's `title` (case-insensitive
// substring). The MVP intentionally avoids a server-side q= param —
// the existing query endpoint accepts only structured `filter[..][op]`
// and the publisher fanout for v1 schemas (author, category, post,
// page) is small enough that an unbounded fetch + client-side filter
// is acceptable. v2 may add a search controller and switch the
// fetch URL accordingly without changing this component's contract.
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
// Replaces server-side phx-click="open-ref-picker"/"clear-ref" modal flow
// for the reference renderer; the StudioLive modal handlers remain
// orphaned-but-harmless until v2 cleanup.

class BpReferencePicker extends HTMLElement {
  constructor() {
    super();
    this._value = "";
    this._refType = "";
    this._dataset = "production";
    this._candidates = null; // lazy-loaded list of {id, title}
    this._loading = false;
    this._debounceMs = 200;
    this._debounceTimer = null;
    this._mounted = false;
  }

  connectedCallback() {
    if (this._mounted) return; // double-mount guard
    this._mounted = true;
    this._value = this.getAttribute("value") || "";
    this._refType = this.getAttribute("ref-type") || "";
    this._dataset = this.getAttribute("dataset") || "production";
    this._render();
    if (this._value) this._loadSelectedTitle();
  }

  disconnectedCallback() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
  }

  // ── Rendering ────────────────────────────────────────────────────────
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
    input.placeholder = `Search ${this._refType}…`;
    input.autocomplete = "off";
    input.addEventListener("input", (e) => this._onSearchInput(e.target.value));
    input.addEventListener("focus", () => this._onSearchInput(input.value));
    wrap.appendChild(input);

    const dropdown = document.createElement("ul");
    dropdown.className = "bp-ref-dropdown";
    dropdown.style.cssText =
      "list-style:none;margin:0;padding:0;position:absolute;top:100%;left:0;right:0;z-index:50;background:var(--bg-popover);border:1px solid var(--border);border-radius:var(--radius-sm);max-height:240px;overflow-y:auto;display:none;";
    wrap.appendChild(dropdown);

    this.appendChild(wrap);
    this._searchInput = input;
    this._dropdown = dropdown;
  }

  // ── Behaviour ────────────────────────────────────────────────────────
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
    this._render();
    this._emit(this._value);
  }

  _onSearchInput(term) {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => this._search(term), this._debounceMs);
  }

  async _search(term) {
    await this._ensureCandidates();
    const t = (term || "").trim().toLowerCase();
    const matches = (this._candidates || [])
      .filter((c) => {
        if (!t) return true;
        const haystack = (c.title || c.id).toLowerCase();
        return haystack.includes(t);
      })
      .slice(0, 50);
    this._renderDropdown(matches);
  }

  async _ensureCandidates() {
    if (this._candidates !== null || this._loading) return;
    this._loading = true;
    try {
      const url = `/v1/data/query/${encodeURIComponent(this._dataset)}/${encodeURIComponent(this._refType)}?perspective=published&limit=200`;
      const res = await fetch(url, { credentials: "same-origin" });
      if (!res.ok) {
        this._candidates = [];
        return;
      }
      const body = await res.json();
      const docs =
        (body && body.result && body.result.documents) ||
        (body && body.documents) ||
        [];
      this._candidates = docs.map((d) => ({
        id: d._id || d.id || "",
        title: d.title || d._id || ""
      }));
    } catch (_e) {
      this._candidates = [];
    } finally {
      this._loading = false;
    }
  }

  _renderDropdown(matches) {
    if (!this._dropdown) return;
    this._dropdown.replaceChildren();
    if (!matches.length) {
      this._dropdown.style.display = "none";
      return;
    }
    for (const doc of matches) {
      const li = document.createElement("li");
      li.className = "bp-ref-dropdown-item";
      li.style.cssText =
        "padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--border-muted);";
      li.textContent = doc.title || doc.id;
      // mousedown fires before input blur — keeps click reliable.
      li.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this._select(doc);
      });
      li.addEventListener("mouseenter", () => {
        li.style.background = "var(--bg-accent)";
      });
      li.addEventListener("mouseleave", () => {
        li.style.background = "";
      });
      this._dropdown.appendChild(li);
    }
    this._dropdown.style.display = "block";
  }

  async _loadSelectedTitle() {
    try {
      const url = `/v1/data/doc/${encodeURIComponent(this._dataset)}/${encodeURIComponent(this._refType)}/${encodeURIComponent(this._value)}`;
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
      // Silent: pill keeps showing the id as fallback.
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

  // Programmatic API for tests + future server-pushed updates.
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
