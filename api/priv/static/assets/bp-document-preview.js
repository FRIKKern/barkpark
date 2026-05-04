// bp-document-preview — Studio read-only document preview Web Component
// (Task #12 WI3). Final WI of the four-WC suite that started with
// bp-rich-text-editor (PR #111), bp-media-picker (PR #112), and
// bp-reference-picker (PR #114).
//
// READ-ONLY. Does not emit `bp-change`. Has no BarkparkFieldBridge
// dependency since it never writes back. The host LiveView wraps it in
// a `phx-update="ignore"` div via `BarkparkWeb.StudioComponents.document_preview/1`.
//
// Attributes:
//   * `document-json` — JSON-encoded document (the same object shape
//     the API returns under `/v1/data/doc/...`). Empty / missing →
//     "no document" placeholder.
//   * `schema-name`   — string schema name, e.g. "post" or "book". Used
//     to pick a renderer. Anything we don't know → JSON dump fallback.
//
// Rendering strategy:
//   * Curated renderer per known schema (currently only `book` —
//     the v1 plugin schema in this repo). The renderer surfaces the
//     headline fields (title, contributors, identifiers, blurb, …)
//     with sensible labels, and dumps the rest as collapsed JSON.
//   * Anything else → pretty-printed JSON in <pre><code>.
//
// Re-renders idempotently when attributes change (observedAttributes).

class BpDocumentPreview extends HTMLElement {
  static get observedAttributes() {
    return ["document-json", "schema-name"];
  }

  constructor() {
    super();
    this._mounted = false;
  }

  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;
    this._render();
  }

  disconnectedCallback() {
    this._mounted = false;
  }

  attributeChangedCallback(_name, oldVal, newVal) {
    if (!this._mounted) return;
    if (oldVal === newVal) return;
    this._render();
  }

  // ── Internals ───────────────────────────────────────────────────
  _doc() {
    const raw = this.getAttribute("document-json") || "";
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch (_e) {
      return { _parseError: true, _raw: raw };
    }
  }

  _schema() {
    return this.getAttribute("schema-name") || "";
  }

  _render() {
    const doc = this._doc();
    const schema = this._schema();

    if (!doc) {
      this.innerHTML =
        '<div class="bp-dp-empty">No document selected</div>';
      return;
    }
    if (doc._parseError) {
      this.innerHTML =
        '<div class="bp-dp-error">Could not parse document JSON</div>' +
        '<pre class="bp-dp-json"><code>' +
        this._esc(doc._raw || "") +
        "</code></pre>";
      return;
    }

    let body = "";
    if (schema === "book") {
      body = this._renderBook(doc);
    } else {
      body = this._renderJson(doc);
    }

    this.innerHTML =
      '<div class="bp-dp-root" data-schema="' +
      this._esc(schema) +
      '">' +
      body +
      "</div>";
  }

  // ── Curated renderer: book ─────────────────────────────────────
  _renderBook(doc) {
    const c = (doc && doc.content) || {};

    // Title — top-level (Document.title is mirrored above content)
    const title = doc.title || c.title || "Untitled";

    // Contributors — composite arrayOf with name/role
    const contribs = Array.isArray(c.contributors) ? c.contributors : [];

    // Identifiers — composite arrayOf {type, value}
    const ids = Array.isArray(c.identifiers) ? c.identifiers : [];

    // Blurb / textContent — localizedText or composite
    const blurb = c.blurb || c.textContent || c.shortBlurb || "";

    const parts = [];
    parts.push(this._field("Title", this._esc(title)));
    parts.push(this._field("Type", "book"));
    if (doc._id) parts.push(this._field("Document ID", this._esc(doc._id)));

    if (contribs.length) {
      const items = contribs
        .map((p) => {
          const n = (p && (p.name || p.contributorName)) || "";
          const r = (p && (p.role || p.contributorRole)) || "";
          return (
            '<li class="bp-dp-contrib"><span class="bp-dp-contrib-name">' +
            this._esc(n) +
            "</span>" +
            (r
              ? ' <span class="bp-dp-contrib-role">(' +
                this._esc(r) +
                ")</span>"
              : "") +
            "</li>"
          );
        })
        .join("");
      parts.push(
        this._field(
          "Contributors",
          '<ul class="bp-dp-list">' + items + "</ul>"
        )
      );
    }

    if (ids.length) {
      const items = ids
        .map((i) => {
          const t = (i && i.type) || "";
          const v = (i && i.value) || "";
          return (
            '<li class="bp-dp-id">' +
            (t
              ? '<span class="bp-dp-id-type">' +
                this._esc(t) +
                "</span> "
              : "") +
            '<code class="bp-dp-id-value">' +
            this._esc(v) +
            "</code></li>"
          );
        })
        .join("");
      parts.push(
        this._field(
          "Identifiers",
          '<ul class="bp-dp-list">' + items + "</ul>"
        )
      );
    }

    if (blurb) {
      const text =
        typeof blurb === "string" ? blurb : this._stringifyLocalized(blurb);
      if (text) {
        parts.push(this._field("Blurb", '<p class="bp-dp-blurb">' + this._esc(text) + "</p>"));
      }
    }

    // Always show the full content as a collapsible JSON dump for
    // anything not covered by the curated fields above.
    parts.push(
      '<details class="bp-dp-raw"><summary>Full content (JSON)</summary>' +
        this._renderJson(doc) +
        "</details>"
    );

    return parts.join("");
  }

  _stringifyLocalized(v) {
    // localizedText is shape: { "en": "...", "no": "..." } or { format, value }.
    // Return the first string we find.
    if (!v) return "";
    if (typeof v === "string") return v;
    if (typeof v === "object") {
      if (typeof v.value === "string") return v.value;
      const keys = Object.keys(v);
      for (let i = 0; i < keys.length; i++) {
        const x = v[keys[i]];
        if (typeof x === "string") return x;
      }
    }
    return "";
  }

  // ── Generic fallback: JSON dump ────────────────────────────────
  _renderJson(value) {
    let pretty = "";
    try {
      pretty = JSON.stringify(value, null, 2);
    } catch (_e) {
      pretty = String(value);
    }
    return (
      '<pre class="bp-dp-json"><code>' + this._esc(pretty) + "</code></pre>"
    );
  }

  _field(label, htmlValue) {
    return (
      '<div class="bp-dp-field">' +
      '<div class="bp-dp-label">' + this._esc(label) + "</div>" +
      '<div class="bp-dp-value">' + htmlValue + "</div>" +
      "</div>"
    );
  }

  _esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
}

customElements.define("bp-document-preview", BpDocumentPreview);
