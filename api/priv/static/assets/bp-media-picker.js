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
//
// ── chrome="ghost" (pd-doctrine rule 6 — no chrome on atoms) ───────────────
//
// In the continuous-canvas PortableDoc editor an image field is an ATOM that
// must show NOTHING the reader lacks (doctrine rule 6). The default variant's
// Upload / Browse / Remove buttons ARE chrome — so `chrome="ghost"` drops the
// whole `.bp-mp-actions` row: the empty-state card stays the click/Enter/Space
// file-dialog affordance, the SET state renders the bare preview only, and the
// actions ride a right-click context menu (Upload file / Browse library /
// Remove image) instead. The attribute is OPT-IN: absent → the default variant
// renders BYTE-IDENTICALLY (sidebar / per-block form contexts keep full chrome).
// Hosts drive it through the public openFileDialog() / openBrowser() methods
// rather than poking .bp-mp-browse internals.

// The context-menu MODEL for a ghost picker — the ordered menu items given the
// current state. Pure + host-free so the test hook can pin it without a DOM.
// Upload file + Browse library are always offered (a file dialog needs no token,
// and Browse is a no-op if no asset browser is wired); Remove image appears ONLY
// when an asset is set (nothing to remove otherwise). While an upload is in
// flight (`busy`) every item is DISABLED — the exact mirror of the default
// chrome, whose _setBusy disables its Upload/Browse/Remove buttons.
function bpMediaPickerMenuItems({ hasValue, canUpload, busy } = {}) {
  const items = [];
  if (canUpload !== false) items.push({ id: "upload", label: "Upload file" });
  items.push({ id: "browse", label: "Browse library" });
  if (hasValue) items.push({ id: "remove", label: "Remove image", destructive: true });
  if (busy) for (const item of items) item.disabled = true;
  return items;
}

// Whether a variant renders the visible `.bp-mp-actions` button row. Only the
// default (attr absent / any non-"ghost" value) does; "ghost" hides it entirely.
function bpMediaPickerShowsActions(variant) {
  return variant !== "ghost";
}

// A focal coordinate is a number in 0..1 (the fraction of the image's width /
// height); anything else reads as "unset" (null). Gyldendal parity E1: the
// Sanity image hotspot, denormalised onto the field value as focalX / focalY.
function bpFocalCoord(v) {
  const n = typeof v === "number" ? v : typeof v === "string" && v !== "" ? Number(v) : NaN;
  if (!Number.isFinite(n)) return null;
  return Math.min(1, Math.max(0, n));
}

// Where a click on the preview lands as a focal point: the click's position
// inside `rect` ({left, top, width, height}), clamped to 0..1 each way. Pure.
function bpMediaFocalFromClick(rect, clientX, clientY) {
  if (!rect || !(rect.width > 0) || !(rect.height > 0)) return null;
  return {
    x: bpFocalCoord((clientX - rect.left) / rect.width),
    y: bpFocalCoord((clientY - rect.top) / rect.height)
  };
}

function bpParseMediaValue(raw) {
  const empty = { url: "", assetId: "", alt: "", focalX: null, focalY: null };
  if (!raw || typeof raw !== "string") return empty;
  const trimmed = raw.trim();
  if (trimmed.startsWith("{")) {
    try {
      const o = JSON.parse(trimmed);
      return {
        url: o.url || "",
        assetId: o.assetId || o.id || "",
        alt: typeof o.alt === "string" ? o.alt : "",
        focalX: bpFocalCoord(o.focalX),
        focalY: bpFocalCoord(o.focalY)
      };
    } catch (_e) {
      return Object.assign({}, empty, { url: trimmed });
    }
  }
  return Object.assign({}, empty, { url: trimmed });
}

// The stored value. A bare URL stays a bare URL and {url, assetId} stays
// two keys — alt / focalX / focalY are written ONLY when set, so every value
// this picker ever wrote keeps round-tripping byte-identically.
function bpSerializeMediaValue(url, assetId, extra) {
  const e = extra || {};
  const alt = typeof e.alt === "string" ? e.alt : "";
  const fx = bpFocalCoord(e.focalX);
  const fy = bpFocalCoord(e.focalY);
  const rich = alt !== "" || fx != null || fy != null;
  if (!assetId && !rich) return url || "";
  const o = { url: url || "", assetId: assetId || "" };
  if (alt !== "") o.alt = alt;
  if (fx != null) o.focalX = fx;
  if (fy != null) o.focalY = fy;
  return JSON.stringify(o);
}

class BpMediaPicker extends HTMLElement {
  constructor() {
    super();
    this._mounted = false;
    this._value = "";
    this._busy = false;
    this._meta = { url: "", assetId: "", alt: "", focalX: null, focalY: null, width: null, height: null, mime: "" };
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
      this._meta.alt = parsed.alt;
      this._meta.focalX = parsed.focalX;
      this._meta.focalY = parsed.focalY;
    }

    this._render();
  }

  // Gyldendal parity E1 — opt-in affordances on the DEFAULT variant only.
  // `hotspot`: click the preview to set a focal point (a marker shows it);
  // `alt`: an alt-text input under the preview. Absent → byte-identical render.
  _wantsHotspot() {
    return this.hasAttribute("hotspot") && !this._isGhost() && !this._isReferenceMode();
  }

  _wantsAlt() {
    return this.hasAttribute("alt") && !this._isGhost() && !this._isReferenceMode();
  }

  async _resolveReferencePreview(docId) {
    if (!docId) return;
    const headers = { Accept: "application/json" };
    const tok = this._token();
    if (tok) headers["Authorization"] = "Bearer " + tok;
    // ACCOUNT-SESSION FALLBACK (gfr-w1-account-session-bearer-gap): with no
    // bearer we take RequireBearerOrSessionToken's cookie branch, which
    // requires this header. Sent ONLY when the token is genuinely empty.
    else headers["x-requested-with"] = "bp-media-picker";
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
    this._closeContextMenu();
  }

  // Ghost chrome (pd-doctrine rule 6): drop the visible actions row; actions
  // ride the empty-card click + a right-click context menu instead.
  _isGhost() {
    return this.getAttribute("chrome") === "ghost";
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
      this._meta.alt = parsed.alt;
      this._meta.focalX = parsed.focalX;
      this._meta.focalY = parsed.focalY;
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
      this._value = bpSerializeMediaValue(this._meta.url, this._meta.assetId, {
        alt: this._meta.alt,
        focalX: this._meta.focalX,
        focalY: this._meta.focalY
      });
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
    const ghost = this._isGhost();

    // Ghost chrome omits the whole actions row (no Upload / Browse / Remove
    // buttons ever) — but the file input must still exist for the file dialog,
    // so it rides bare when there's no `.bp-mp-upload` label to host it.
    const actionsHtml = ghost
      ? '<input class="bp-mp-file" type="file" accept="image/*" hidden />'
      : '<div class="bp-mp-actions">' +
        '<label class="bp-mp-upload btn btn-sm">' +
        "<span>Upload</span>" +
        '<input type="file" accept="image/*" hidden />' +
        "</label>" +
        '<button type="button" class="bp-mp-browse btn btn-sm">Browse library</button>' +
        '<button type="button" class="bp-mp-clear btn btn-destructive btn-sm">Remove</button>' +
        "</div>";

    const altHtml = this._wantsAlt()
      ? '<label class="bp-mp-alt-row"><span class="bp-mp-alt-label">Alt text</span>' +
        '<input class="bp-mp-alt" type="text" placeholder="Describe the image for people who cannot see it" /></label>'
      : "";

    this.innerHTML =
      '<div class="bp-mp-preview"' + (this._wantsHotspot() ? ' data-hotspot="true"' : "") + "></div>" +
      altHtml +
      actionsHtml +
      '<div class="bp-mp-error" role="alert"></div>';

    this._altInput = this.querySelector(".bp-mp-alt");
    if (this._altInput) {
      this._altInput.value = this._meta.alt || "";
      this._altInput.addEventListener("input", (e) => {
        this._meta.alt = e.target.value;
        this._commitValue();
        this._emit();
      });
    }

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

    // Browse/Remove buttons exist only in the default variant (ghost drops the
    // whole row and routes those actions through the context menu instead).
    if (this._clearBtn) {
      this._clearBtn.addEventListener("click", () => this._clearValue());
    }
    if (this._browseBtn) {
      this._browseBtn.addEventListener("click", () => this._openBrowser());
    }

    // Ghost mode's actions are right-click-only — a hover tooltip is the
    // doctrine-sanctioned discoverability affordance (rule 5: hover tooltips +
    // context menus). Never set in the default variant (byte-identical render).
    if (ghost && !this.title) {
      this.title = "Right-click for image options";
    }

    // Empty-state card = click/keyboard target for the file dialog.
    // Delegated once (the preview's innerHTML is replaced on every render).
    this._previewEl.addEventListener("click", (e) => {
      if (this._busy) return;
      if (e.target.closest(".bp-mp-empty")) {
        this._fileInput.click();
        return;
      }
      // Gyldendal parity E1: with `hotspot`, a click on the image IS the
      // focal-point gesture (Sanity's hotspot without the crop rectangle).
      if (this._wantsHotspot()) {
        const img = e.target.closest(".bp-mp-preview-img");
        if (!img) return;
        const focal = bpMediaFocalFromClick(img.getBoundingClientRect(), e.clientX, e.clientY);
        if (!focal) return;
        this._meta.focalX = focal.x;
        this._meta.focalY = focal.y;
        this._commitValue();
        this._renderFocalMarker();
        this._emit();
      }
    });
    this._previewEl.addEventListener("keydown", (e) => {
      if (this._busy) return;
      if ((e.key === "Enter" || e.key === " ") && e.target.closest(".bp-mp-empty")) {
        e.preventDefault();
        this._fileInput.click();
      }
    });

    // Root-level listeners bind ONCE per element, not once per render: a
    // ProseMirror node move disconnects + reconnects the element, re-running
    // connectedCallback → _render — binding here unguarded would stack
    // duplicate contextmenu/drag handlers on every remount.
    this._dragDepth = 0;
    if (!this._rootListenersBound) {
      this._rootListenersBound = true;

      // Ghost variant: a right-click on the field opens the calm actions menu.
      // Checked per-event (not at bind time) so the guard stays correct even if
      // the `chrome` attribute changes after mount.
      this.addEventListener("contextmenu", (e) => {
        if (!this._isGhost()) return;
        e.preventDefault();
        this._openContextMenu(e.clientX, e.clientY);
      });

      // The whole component accepts a dropped image — empty OR selected
      // (drop replaces). dragenter/leave pair via a counter so child
      // elements don't flicker the highlight off.
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
    }

    this._renderPreview();
  }

  // Returns TRUE when the asset-browser modal actually opened, FALSE when no
  // browser is wired (window.BpAssetBrowser absent) — hosts use the report to
  // fall back to the file dialog instead of leaving a click dead.
  _openBrowser() {
    const ensure = window.BpAssetBrowser && window.BpAssetBrowser.ensure;
    if (!ensure) return false;
    const browser = ensure();
    browser.open({
      dataset: this._dataset(),
      token: this._token(),
      scopePrefix: this._scopePrefix(),
      accept: "image/*",
      onSelect: (detail) => this._selectAsset(detail)
    });
    return true;
  }

  _clearValue() {
    this._value = "";
    this._meta = { url: "", assetId: "", alt: "", width: null, height: null, mime: "" };
    this._renderPreview();
    this._emit();
  }

  // ── public host API — call these instead of poking .bp-mp-* internals ──────
  // Ghost-chrome hosts (the canvas node-view) drive the picker through these so
  // they never depend on the internal button DOM (which ghost mode omits).

  // Open the native file dialog (upload a new file). No-op while busy.
  openFileDialog() {
    if (this._busy) return;
    if (this._fileInput) this._fileInput.click();
  }

  // Open the asset-library browser modal. Returns true when it opened, false
  // when no asset browser is wired (so hosts can fall back to the file dialog).
  openBrowser() {
    return this._openBrowser();
  }

  // ── the ghost-chrome context menu (Upload / Browse / Remove) ───────────────
  //
  // A small self-contained calm menu positioned at the cursor. Items use the
  // Studio `.btn` styling; container styling is inlined so the menu is fully
  // self-contained (it appends to <body>, outside the light-DOM WC). Dismisses
  // on Escape, click-away, or after an action fires.
  _openContextMenu(x, y) {
    this._closeContextMenu();

    const hasValue = !!(
      this._meta.url ||
      this._meta.assetId ||
      bpParseMediaValue(this._value).url
    );
    // busy mirrors default chrome's _setBusy: items stay VISIBLE but disabled
    // while an upload is in flight — never a menu item that silently no-ops.
    const items = bpMediaPickerMenuItems({ hasValue, canUpload: true, busy: this._busy });

    // Focus-restore anchor: whatever was focused before the menu opened (the
    // empty-state card, usually) so Escape lands the keyboard user back where
    // they were instead of dropping focus to <body>.
    this._menuPrevFocus =
      document.activeElement && document.activeElement !== document.body
        ? document.activeElement
        : this.querySelector(".bp-mp-empty");

    const menu = document.createElement("div");
    menu.className = "bp-mp-menu";
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-label", "Image options");
    menu.style.cssText =
      "position:fixed;z-index:1000;display:flex;flex-direction:column;gap:2px;" +
      "min-width:160px;padding:4px;border-radius:8px;" +
      "background:var(--popover,var(--bg,#fff));color:var(--fg,inherit);" +
      "border:1px solid var(--border,rgba(0,0,0,0.12));" +
      "box-shadow:0 6px 20px rgba(0,0,0,0.16);";
    menu.style.left = x + "px";
    menu.style.top = y + "px";
    // Right-clicking the menu itself must not stack the native menu on ours.
    menu.addEventListener("contextmenu", (e) => e.preventDefault());

    for (const item of items) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "bp-mp-menu-item btn btn-sm" + (item.destructive ? " btn-destructive" : "");
      btn.setAttribute("role", "menuitem");
      btn.style.cssText = "justify-content:flex-start;width:100%;text-align:left;";
      btn.textContent = item.label;
      if (item.disabled) {
        btn.disabled = true;
        btn.setAttribute("aria-disabled", "true");
      }
      btn.addEventListener("click", () => {
        this._closeContextMenu(true);
        this._runMenuAction(item.id);
      });
      menu.appendChild(btn);
    }

    document.body.appendChild(menu);
    this._menuEl = menu;

    // Clamp inside the viewport so a right-click near an edge stays reachable.
    if (typeof menu.getBoundingClientRect === "function" && typeof window !== "undefined") {
      const r = menu.getBoundingClientRect();
      if (r.right > window.innerWidth) menu.style.left = Math.max(0, window.innerWidth - r.width - 4) + "px";
      if (r.bottom > window.innerHeight) menu.style.top = Math.max(0, window.innerHeight - r.height - 4) + "px";
    }

    const focusables = () =>
      Array.prototype.slice.call(menu.querySelectorAll(".bp-mp-menu-item:not([disabled])"));
    const first = focusables()[0];
    if (first && typeof first.focus === "function") {
      first.focus();
    } else if (typeof menu.focus === "function") {
      // All items disabled (busy) — park focus on the menu container so Escape
      // and the away-dismiss still work for a keyboard user.
      menu.tabIndex = -1;
      menu.focus();
    }

    // role=menu keyboarding: Escape dismisses (swallowed — a host Escape
    // handler must not also fire), arrows/Home/End walk the enabled items,
    // Tab walks OUT of a menu so it dismisses and lets focus move on.
    this._menuKeyHandler = (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this._closeContextMenu(true);
        return;
      }
      if (e.key === "Tab") {
        this._closeContextMenu();
        return;
      }
      if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Home" || e.key === "End") {
        const its = focusables();
        if (!its.length) return;
        e.preventDefault();
        const idx = its.indexOf(document.activeElement);
        let next;
        if (e.key === "Home") next = 0;
        else if (e.key === "End") next = its.length - 1;
        else if (e.key === "ArrowDown") next = idx < 0 ? 0 : (idx + 1) % its.length;
        else next = idx < 0 ? its.length - 1 : (idx - 1 + its.length) % its.length;
        if (typeof its[next].focus === "function") its[next].focus();
      }
    };
    this._menuAwayHandler = (e) => {
      if (this._menuEl && !this._menuEl.contains(e.target)) this._closeContextMenu();
    };
    // A fixed-position menu must not drift away from its field — any scroll
    // (capture catches inner scrollers) or resize dismisses it, like native menus.
    this._menuViewportHandler = () => this._closeContextMenu();
    document.addEventListener("keydown", this._menuKeyHandler, true);
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
      window.addEventListener("scroll", this._menuViewportHandler, true);
      window.addEventListener("resize", this._menuViewportHandler);
    }
    // Defer the click-away bind a tick so the opening right-click doesn't
    // immediately dismiss the menu it just spawned.
    this._menuAwayArm = setTimeout(() => {
      document.addEventListener("mousedown", this._menuAwayHandler, true);
    }, 0);
  }

  // restoreFocus: true on Escape / a chosen action (keyboard continuity);
  // absent on click-away / scroll / disconnect (focus must follow the click,
  // and a removed element must never yank focus).
  _closeContextMenu(restoreFocus) {
    if (this._menuAwayArm) {
      clearTimeout(this._menuAwayArm);
      this._menuAwayArm = null;
    }
    if (this._menuEl && this._menuEl.parentNode) {
      this._menuEl.parentNode.removeChild(this._menuEl);
    }
    this._menuEl = null;
    if (this._menuKeyHandler) {
      document.removeEventListener("keydown", this._menuKeyHandler, true);
      this._menuKeyHandler = null;
    }
    if (this._menuAwayHandler) {
      document.removeEventListener("mousedown", this._menuAwayHandler, true);
      this._menuAwayHandler = null;
    }
    if (this._menuViewportHandler) {
      if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
        window.removeEventListener("scroll", this._menuViewportHandler, true);
        window.removeEventListener("resize", this._menuViewportHandler);
      }
      this._menuViewportHandler = null;
    }
    const prev = this._menuPrevFocus;
    this._menuPrevFocus = null;
    if (restoreFocus && prev && typeof prev.focus === "function" && prev.isConnected !== false) {
      prev.focus();
    }
  }

  _runMenuAction(id) {
    if (id === "upload") this.openFileDialog();
    else if (id === "browse") this.openBrowser();
    else if (id === "remove") {
      this._clearValue();
      // Keyboard continuity after the destructive action: the field just went
      // empty — land focus on the empty-state card (the next affordance).
      const card = this._previewEl && this._previewEl.querySelector(".bp-mp-empty");
      if (card && typeof card.focus === "function") card.focus();
    }
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
      const hotspot = this._wantsHotspot();
      const safeAlt = (this._meta.alt || "").replace(/"/g, "&quot;");
      this._previewEl.innerHTML =
        (hotspot ? '<div class="bp-mp-hotspot" title="Click the image to set its focal point">' : "") +
        '<img class="bp-mp-preview-img" src="' + safeUrl + '" alt="' + safeAlt + '" />' +
        (hotspot ? '<span class="bp-mp-focal" aria-hidden="true" hidden></span></div>' : "");
      if (hotspot) this._renderFocalMarker();
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

  // Position the focal marker at the stored focal point (percent of the box),
  // or hide it when none is set. The marker is a layered dot over the preview.
  _renderFocalMarker() {
    if (!this._previewEl) return;
    const dot = this._previewEl.querySelector(".bp-mp-focal");
    if (!dot) return;
    const fx = bpFocalCoord(this._meta.focalX);
    const fy = bpFocalCoord(this._meta.focalY);
    if (fx == null || fy == null) {
      dot.hidden = true;
      return;
    }
    dot.hidden = false;
    dot.style.left = (fx * 100).toFixed(2) + "%";
    dot.style.top = (fy * 100).toFixed(2) + "%";
  }

  _select(file) {
    // A NEW image resets the focal point (it belongs to the pixels); the alt
    // text the author typed survives a swap, else the library's own alt seeds it.
    const keptAlt = this._meta.alt && this._meta.alt !== "" ? this._meta.alt : file.alt || "";
    this._meta = {
      url: file.url || "",
      assetId: file.assetId || "",
      alt: keptAlt,
      focalX: null,
      focalY: null,
      width: file.width || null,
      height: file.height || null,
      mime: file.mime || file.mimeType || ""
    };
    this._commitValue();
    this._setError("");
    this._renderPreview();
    if (this._altInput) this._altInput.value = this._meta.alt || "";
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
    // ACCOUNT-SESSION FALLBACK (gfr-w1-account-session-bearer-gap): with no
    // bearer we take RequireBearerOrSessionToken's cookie branch, which
    // requires this header. Sent ONLY when the token is genuinely empty.
    else headers["x-requested-with"] = "bp-media-picker";
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

// Test hook (cloud-SPA __bpTestHook pattern): expose the PURE variant/menu model
// so __picker_chrome.test.mjs can assert it without a browser. No behavior in
// prod — a plain data hook off the same pure functions the WC uses.
if (typeof window !== "undefined") {
  window.__bpMediaPickerTestHook = {
    menuItems: bpMediaPickerMenuItems,
    showsActions: bpMediaPickerShowsActions,
    parseValue: bpParseMediaValue,
    serializeValue: bpSerializeMediaValue,
    focalFromClick: bpMediaFocalFromClick
  };
}
