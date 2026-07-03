/* ============================================================================
   Barkpark Cloud dashboard — vanilla SPA, no framework, no build step.
   State lives in localStorage ({token, team_id}); views switch on the hash.
   Every authed call sends `Authorization: Bearer <token>`; any 401 logs out.

   P0 chrome (this file): topbar + tab-nav + footer, plus two reusable
   primitives — toast() for transient feedback and openModal()/closeModal()
   for dialogs. Later phases (onboarding wizard, instance detail) consume
   these same primitives.
   ========================================================================== */
(function () {
  "use strict";

  var STORE = "bpcloud.session";
  var THEME = "bpcloud.theme";

  // ----------------------------------------------------------- tiny DOM utils
  function $(sel) { return document.querySelector(sel); }
  function show(el) { if (el) el.hidden = false; }
  function hide(el) { if (el) el.hidden = true; }
  function setText(el, t) { if (el) el.textContent = t; }
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  // decodeURIComponent that never throws: a malformed escape in a hand-edited or
  // truncated deep link (e.g. "#instance/9f3c%") returns the raw string instead
  // of a URIError that would white-screen render()/applyRoute() permanently.
  function safeDecode(s) {
    try { return decodeURIComponent(s); } catch (e) { return s; }
  }

  // ----------------------------------------------------------- session state
  // "Remember me" picks the backing store: localStorage persists across browser
  // restarts; sessionStorage clears when the tab closes. session() reads either.
  function session() {
    try { return JSON.parse((localStorage.getItem(STORE) || sessionStorage.getItem(STORE)) || "null"); }
    catch (e) { return null; }
  }
  function setSession(s, remember) {
    var t = JSON.stringify(s);
    if (remember === false) { sessionStorage.setItem(STORE, t); localStorage.removeItem(STORE); }
    else { localStorage.setItem(STORE, t); sessionStorage.removeItem(STORE); }
  }
  function clearSession() { localStorage.removeItem(STORE); sessionStorage.removeItem(STORE); }
  // Swap just the bearer token in whichever store currently holds the session,
  // preserving the "remember me" choice. Used after PUT /v1/account/password,
  // which revokes the old token and returns a fresh one — without this swap the
  // very next request would 401 and bounce the caller to login.
  function updateSessionToken(newToken) {
    var s = session(); if (!s) return;
    s.token = newToken;
    var inLocal = localStorage.getItem(STORE) != null;
    setSession(s, inLocal);
  }

  // ----------------------------------------------------------- API helper
  // Returns { ok, status, data }. On 401 (when authed) we clear + bounce.
  function api(method, path, body, opts) {
    opts = opts || {};
    var headers = { "Accept": "application/json" };
    if (body !== undefined && body !== null) headers["Content-Type"] = "application/json";
    var s = session();
    if (s && s.token && !opts.noAuth) headers["Authorization"] = "Bearer " + s.token;

    return fetch(path, {
      method: method,
      headers: headers,
      body: body == null ? undefined : JSON.stringify(body)
    }).then(function (res) {
      var ct = res.headers.get("content-type") || "";
      var parse = ct.indexOf("application/json") !== -1
        ? res.json().catch(function () { return {}; })
        : Promise.resolve({});
      return parse.then(function (data) {
        if (res.status === 401 && !opts.noAuth && !opts.noBounce) {
          clearSession();
          render();
        }
        return { ok: res.ok, status: res.status, data: data };
      });
    }).catch(function () {
      return { ok: false, status: 0, data: { error: "network_error" } };
    });
  }

  // ----------------------------------------------------------- error copy
  var ERRORS = {
    invalid_credentials: "Wrong email or password.",
    email_taken: "That email is already registered.",
    email_invalid: "Enter a valid email address.",
    password_invalid: "Password is too short (12+ characters).",
    validation_failed: "Please check the form and try again.",
    name_required: "A name is required.",
    no_active_subscription: "You need an active subscription to launch.",
    plan_invalid: "That plan can't be checked out.",
    no_team: "Your account has no team yet.",
    invalid: "That didn't work — check your input.",
    not_live: "The instance isn't live yet — wait for provisioning to finish.",
    no_admin_token: "No stored credentials for this instance — it may need a re-provision.",
    instance_unreachable: "Couldn't reach the instance — try again in a moment.",
    network_error: "Network error — is the control plane running?"
  };
  function friendly(data, fallback) {
    if (!data) return fallback || "Something went wrong.";
    var key = data.error;
    if (key && ERRORS[key]) return ERRORS[key];
    if (data.details && typeof data.details === "object") {
      var first = Object.keys(data.details)[0];
      if (first) {
        var msg = data.details[first];
        if (Array.isArray(msg)) msg = msg[0];
        return first.replace(/_/g, " ") + " " + msg;
      }
    }
    return (key ? key.replace(/_/g, " ") : "") || fallback || "Something went wrong.";
  }

  // =========================================================== TOAST primitive
  // toast({ kind, title, body, action, duration }) — kind: success|error|info.
  // action: { label, onClick }. Auto-dismisses; X closes early.
  var TOAST_GLYPH = { success: "✓", error: "!", info: "i" };

  function toast(opts) {
    opts = opts || {};
    var stack = $("#toast-stack");
    if (!stack) return;
    var kind = opts.kind || "info";
    var el = document.createElement("div");
    el.className = "toast toast-" + kind;
    el.setAttribute("role", kind === "error" ? "alert" : "status");

    var html =
      '<span class="toast-ico" aria-hidden="true">' + (TOAST_GLYPH[kind] || "i") + "</span>" +
      '<div class="toast-main">' +
        '<div class="toast-title">' + esc(opts.title || "") + "</div>" +
        (opts.body ? '<div class="toast-body">' + esc(opts.body) + "</div>" : "") +
        (opts.action ? '<button class="btn btn-sm toast-action">' + esc(opts.action.label) + "</button>" : "") +
      "</div>" +
      '<button class="toast-close" type="button" aria-label="Dismiss">&times;</button>';
    el.innerHTML = html;
    stack.appendChild(el);

    var timer = null;
    function dismiss() {
      if (timer) clearTimeout(timer);
      if (el.parentNode) el.parentNode.removeChild(el);
    }
    el.querySelector(".toast-close").addEventListener("click", dismiss);
    if (opts.action) {
      el.querySelector(".toast-action").addEventListener("click", function () {
        dismiss();
        if (typeof opts.action.onClick === "function") opts.action.onClick();
      });
    }
    var dur = opts.duration != null ? opts.duration
      : (opts.action ? 8000 : kind === "error" ? 6000 : 4000);
    if (dur > 0) timer = setTimeout(dismiss, dur);
    return dismiss;
  }

  // =========================================================== MODAL primitive
  // openModal(htmlString) fills the modal body, shows the dialog, moves focus
  // in, and restores focus on close. Backdrop / [data-close] / ESC all close.
  // While open the dialog is a focus TRAP (Tab/Shift+Tab cycle inside it) and
  // the rest of the app is marked `inert` + aria-hidden, so neither the keyboard
  // nor AT can reach the still-rendered shell behind it (WCAG 2.4.3 + dialog APG;
  // aria-modal alone is unreliable in assistive tech).
  var lastFocused = null;
  var FOCUSABLE_SEL = "button, [href], input, select, textarea, [tabindex]";

  // Visible, enabled, tabbable descendants of `container`, in DOM order.
  function focusablesIn(container) {
    if (!container) return [];
    return Array.prototype.filter.call(
      container.querySelectorAll(FOCUSABLE_SEL),
      function (el) {
        if (el.disabled) return false;
        if (el.getAttribute("tabindex") === "-1") return false;
        // offsetParent is null for display:none nodes; in a real browser this
        // drops hidden controls. (Undefined in the vm harness — never runs there.)
        return el.offsetParent !== null || el.getClientRects === undefined;
      },
    );
  }

  function setShellInert(on) {
    var shell = document.getElementById("app-shell");
    if (!shell) return;
    if (on) { shell.setAttribute("inert", ""); shell.setAttribute("aria-hidden", "true"); }
    else { shell.removeAttribute("inert"); shell.removeAttribute("aria-hidden"); }
  }

  function openModal(html) {
    var root = $("#modal-root");
    var bodyEl = $("#modal-body");
    if (!root || !bodyEl) return;
    lastFocused = document.activeElement;
    bodyEl.innerHTML = html;
    show(root);
    setShellInert(true);
    var focusable = bodyEl.querySelector(FOCUSABLE_SEL);
    (focusable || $(".modal-x")).focus();
    return bodyEl;
  }

  function closeModal() {
    var root = $("#modal-root");
    if (!root || root.hidden) return;
    hide(root);
    setShellInert(false);
    $("#modal-body").innerHTML = "";
    if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus();
  }

  // Keep Tab inside the open dialog. Trapping the whole `.modal-card` includes
  // the close (×) button, so focus can never fall back onto the inert shell.
  function trapModalTab(e) {
    if (e.key !== "Tab") return;
    var card = document.querySelector("#modal-root .modal-card");
    if (!card) return;
    var f = focusablesIn(card);
    if (f.length === 0) { e.preventDefault(); return; } // zero-focusable modal: pin, don't crash
    var first = f[0], last = f[f.length - 1];
    var active = document.activeElement;
    if (!card.contains(active)) { e.preventDefault(); first.focus(); return; }
    if (e.shiftKey && active === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus(); }
  }

  function wireModal() {
    var root = $("#modal-root");
    if (!root) return;
    root.addEventListener("click", function (e) {
      if (e.target.hasAttribute && e.target.hasAttribute("data-close")) closeModal();
    });
    document.addEventListener("keydown", function (e) {
      if (root.hidden) return;
      if (e.key === "Escape") { closeModal(); return; }
      trapModalTab(e);
    });
  }

  // ----------------------------------------------------------- account & sessions
  // Best-effort relative time for last_used_at / inserted_at columns.
  function relTime(iso) {
    if (!iso) return "—";
    var then = new Date(iso).getTime();
    if (isNaN(then)) return "—";
    var secs = Math.max(0, Math.round((Date.now() - then) / 1000));
    if (secs < 60) return "just now";
    var mins = Math.round(secs / 60); if (mins < 60) return mins + "m ago";
    var hrs = Math.round(mins / 60); if (hrs < 24) return hrs + "h ago";
    var days = Math.round(hrs / 24); return days + "d ago";
  }

  // Coarse "Device" label from a User-Agent string — enough to recognise a row
  // in the list, deliberately not a full UA parser (no dependency).
  function deviceLabel(ua) {
    if (!ua) return "Unknown device";
    var os = /Windows/.test(ua) ? "Windows" : /Mac OS X|Macintosh/.test(ua) ? "macOS"
      : /Android/.test(ua) ? "Android" : /iPhone|iPad|iOS/.test(ua) ? "iOS"
      : /Linux/.test(ua) ? "Linux" : "";
    var br = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome"
      : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
    return (br + (os ? " · " + os : "")) || "Browser";
  }

  function openAccountModal() {
    var s = session() || {};
    var team = s.team_id ? String(s.team_id) : "—";
    openModal(
      '<h2 class="modal-title" id="modal-title">Account &amp; sessions</h2>' +
      '<p class="modal-sub">You are signed in to Barkpark Cloud.</p>' +
      '<div class="modal-row"><span class="k">Team</span><span class="v">' + esc(team) + "</span></div>" +

      '<h3 class="modal-section">Active sessions</h3>' +
      '<div id="sessions-box" class="sessions-box"><p class="muted">Loading…</p></div>' +
      '<div class="modal-actions inline">' +
        '<button class="btn btn-sm" type="button" id="sessions-revoke-all">Sign out everywhere else</button>' +
      "</div>" +

      '<h3 class="modal-section">Change password</h3>' +
      '<form id="pw-form" class="pw-form">' +
        '<label class="field"><span>Current password</span>' +
          '<input type="password" id="pw-current" autocomplete="current-password" required></label>' +
        '<label class="field"><span>New password (12+ characters)</span>' +
          '<input type="password" id="pw-new" autocomplete="new-password" minlength="12" required></label>' +
        '<div id="pw-error" class="form-error" hidden></div>' +
        '<div class="modal-actions inline">' +
          '<button class="btn btn-primary btn-sm" type="submit">Update password</button>' +
        "</div>" +
      "</form>" +

      '<div class="modal-actions">' +
        '<button class="btn" type="button" data-close>Close</button>' +
        '<button class="btn btn-primary" type="button" id="modal-logout">Log out</button>' +
      "</div>"
    );

    loadSessions();

    var revokeAll = $("#sessions-revoke-all");
    if (revokeAll) revokeAll.addEventListener("click", function () {
      api("DELETE", "/v1/account/sessions").then(function (r) {
        if (r.ok) {
          toast({ kind: "success", title: "Signed out other devices", body: (r.data.revoked || 0) + " session(s) revoked." });
          loadSessions();
        } else {
          toast({ kind: "error", title: "Couldn't sign out", body: friendly(r.data) });
        }
      });
    });

    var pwForm = $("#pw-form");
    if (pwForm) pwForm.addEventListener("submit", submitPasswordChange);

    var out = $("#modal-logout");
    if (out) out.addEventListener("click", function () {
      // Revoke the calling token server-side, THEN clear local state. The result
      // is ignored — even a network failure must still drop the local session.
      api("DELETE", "/v1/auth/logout").catch(function () {}).then(function () {
        closeModal();
        clearSession();
        location.hash = "";
        render();
      });
    });
  }

  // Fetch + render the active-sessions list into #sessions-box. The current row
  // is badged "This device" and its Revoke button disabled.
  function loadSessions() {
    var box = $("#sessions-box");
    if (!box) return;
    api("GET", "/v1/account/sessions").then(function (r) {
      if (!box.isConnected) return;
      if (!r.ok) { box.innerHTML = '<p class="muted">Couldn\'t load sessions.</p>'; return; }
      var rows = (r.data && r.data.sessions) || [];
      if (!rows.length) { box.innerHTML = '<p class="muted">No active sessions.</p>'; return; }
      box.innerHTML = rows.map(function (x) {
        return '<div class="session-row">' +
          '<div class="session-main">' +
            '<div class="session-device">' + esc(deviceLabel(x.user_agent)) +
              (x.current ? ' <span class="badge badge-current">This device</span>' : "") + "</div>" +
            '<div class="session-meta">' + esc(x.ip_address || "unknown IP") +
              " · active " + esc(relTime(x.last_used_at || x.inserted_at)) + "</div>" +
          "</div>" +
          (x.current
            ? '<button class="btn btn-sm" type="button" disabled>Current</button>'
            : '<button class="btn btn-sm session-revoke" type="button" data-id="' + esc(x.id) + '">Revoke</button>') +
          "</div>";
      }).join("");
      box.querySelectorAll(".session-revoke").forEach(function (b) {
        b.addEventListener("click", function () {
          api("DELETE", "/v1/account/sessions/" + encodeURIComponent(b.getAttribute("data-id"))).then(function (r) {
            if (r.ok) loadSessions();
            else toast({ kind: "error", title: "Couldn't revoke", body: friendly(r.data) });
          });
        });
      });
    });
  }

  // PUT /v1/account/password. On 200 the old token is dead and a fresh one is
  // returned — swap it in (updateSessionToken) so the tab stays authenticated,
  // exactly Coolify's "logged out everywhere, re-issued here".
  function submitPasswordChange(e) {
    e.preventDefault();
    var errEl = $("#pw-error");
    if (errEl) { errEl.hidden = true; }
    var cur = ($("#pw-current") || {}).value || "";
    var nw = ($("#pw-new") || {}).value || "";
    api("PUT", "/v1/account/password", { current_password: cur, new_password: nw }, { noBounce: true })
      .then(function (r) {
        if (r.ok && r.data.token) {
          updateSessionToken(r.data.token);
          toast({ kind: "success", title: "Password updated", body: "Other devices were signed out." });
          var c = $("#pw-current"); if (c) c.value = "";
          var n = $("#pw-new"); if (n) n.value = "";
          loadSessions();
        } else if (errEl) {
          errEl.textContent = r.status === 401 ? "Current password is wrong." : friendly(r.data, "Couldn't update password.");
          errEl.hidden = false;
        }
      });
  }

  // ----------------------------------------------------------- eye toggle
  var EYE_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
  function toggleEye(inputSel, btnSel) {
    var inp = $(inputSel);
    if (!inp) return;
    var reveal = inp.type === "password";
    inp.type = reveal ? "text" : "password";
    var b = $(btnSel);
    if (b) b.setAttribute("aria-label", reveal ? "Hide" : "Show");
  }

  // =========================================================== PROVIDER FLOW
  // Forge-style picker → branded credential subform, both in the modal.
  // Only Hetzner is wired to the API; the rest are shown disabled ("Soon").
  var PROVIDERS = [
    { kind: "hetzner", name: "Hetzner Cloud", sub: "Deploy on your own Hetzner account",
      mark: "H", cls: "brand-hetzner", available: true,
      console: "https://console.hetzner.cloud/",
      blurb: "Connect to your Hetzner Cloud account to deploy instances." },
    { kind: "digitalocean", name: "DigitalOcean", sub: "Coming soon", mark: "DO", cls: "brand-do", available: false },
    { kind: "aws", name: "AWS", sub: "Coming soon", mark: "aws", cls: "brand-aws", available: false },
    { kind: "vultr", name: "Vultr", sub: "Coming soon", mark: "V", cls: "brand-vultr", available: false }
  ];
  function providerMeta(kind) {
    return PROVIDERS.filter(function (p) { return p.kind === kind; })[0] || PROVIDERS[0];
  }

  function openProviderPicker() {
    var rows = PROVIDERS.map(function (p) {
      return '<button class="choice" ' + (p.available ? "" : "disabled") + ' data-kind="' + esc(p.kind) + '">' +
        '<span class="choice-ico ' + p.cls + '">' + esc(p.mark) + "</span>" +
        '<span class="choice-main"><span class="choice-name">' + esc(p.name) + "</span>" +
        '<span class="choice-sub">' + esc(p.sub) + "</span></span>" +
        (p.available ? '<span class="choice-chev">&rsaquo;</span>' : '<span class="choice-tag">Soon</span>') +
      "</button>";
    }).join("");
    openModal(
      '<h2 class="modal-title" id="modal-title">Connect a provider</h2>' +
      '<p class="modal-sub">Barkpark provisions instances on the provider of your choice. ' +
        "Server costs are billed to you by the provider.</p>" +
      '<div class="choice-list">' + rows + "</div>"
    );
    $("#modal-body").querySelectorAll('.choice[data-kind]:not([disabled])').forEach(function (b) {
      b.addEventListener("click", function () { openProviderCredential(b.getAttribute("data-kind")); });
    });
  }

  function openProviderCredential(kind) {
    var p = providerMeta(kind);
    openModal(
      '<button class="modal-back" id="cred-back" type="button">&lsaquo; Back to providers</button>' +
      '<div class="modal-head"><span class="choice-ico ' + p.cls + '">' + esc(p.mark) + "</span>" +
        '<h2 class="modal-title" id="modal-title">' + esc(p.name) + "</h2></div>" +
      '<p class="modal-sub">' + esc(p.blurb || "") + "</p>" +
      '<div class="field"><label class="label" for="cred-label">Profile name <span class="dim">(optional)</span></label>' +
        '<input class="form-input" id="cred-label" type="text" placeholder="main" /></div>' +
      '<div class="field"><label class="label" for="cred-token">API key</label>' +
        '<p class="field-hint dim" style="margin:0 0 6px">Create a key in the ' +
          '<a href="' + esc(p.console || "#") + '" target="_blank" rel="noopener">' + esc(p.name) + " console</a>. " +
          "Encrypted at rest, never shown again.</p>" +
        '<div class="input-affix">' +
          '<input class="form-input" id="cred-token" type="password" autocomplete="off" placeholder="••••••••••••••••" />' +
          '<button class="affix-btn" id="cred-eye" type="button" tabindex="-1" aria-label="Show key">' + EYE_SVG + "</button>" +
        "</div></div>" +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="cred-submit" type="button">Add provider</button></div>'
    );
    $("#cred-back").addEventListener("click", openProviderPicker);
    $("#cred-eye").addEventListener("click", function () { toggleEye("#cred-token", "#cred-eye"); });
    $("#cred-submit").addEventListener("click", function () { submitProviderCred(kind); });
    $("#cred-token").focus();
  }

  function submitProviderCred(kind) {
    var token = ($("#cred-token").value || "").trim();
    var label = ($("#cred-label").value || "").trim();
    if (!token) { toast({ kind: "error", title: "An API key is required." }); return; }

    var btn = $("#cred-submit");
    btn.disabled = true;
    btn.textContent = "Validating…";
    var body = { kind: kind, token: token };
    if (label) body.label = label;

    api("POST", "/v1/providers", body).then(function (r) {
      if (r.status === 201) {
        closeModal();
        var p = (r.data && r.data.provider) || { kind: kind, label: label };
        toast({
          kind: "success",
          title: "Provider connected",
          body: "Connected " + (p.kind || kind) + (p.label ? " (" + p.label + ")" : "") + "."
        });
        loadProviders();
      } else {
        btn.disabled = false;
        btn.textContent = "Add provider";
        toast({ kind: "error", title: "Couldn't validate the key", body: friendly(r.data, "Check the API key and try again.") });
      }
    });
  }

  // Fetch the team's connected providers from the server so they SURVIVE a
  // reload (previously the connect flow was optimistic-only — a connected
  // provider vanished on refresh).
  function loadProviders() {
    var box = $("#provider-list");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading providers&hellip;</div>';
    api("GET", "/v1/providers").then(function (r) {
      var list = (r.ok && r.data && r.data.providers) || [];
      renderProviderList(list);
    });
  }

  // Re-renders the Providers view body from a list (server- or optimistically-
  // sourced).
  function renderProviderList(list) {
    var box = $("#provider-list");
    if (!box) return;
    if (!list || !list.length) {
      box.innerHTML =
        '<div class="empty-state"><h2>No providers connected</h2>' +
        "<p>Connect Hetzner Cloud to launch managed instances on your own account.</p>" +
        '<button class="btn btn-primary" id="provider-add-empty" type="button">Connect a provider</button></div>';
      var b = $("#provider-add-empty");
      if (b) b.addEventListener("click", openProviderPicker);
      return;
    }
    box.innerHTML = list.map(function (p) {
      var m = providerMeta(p.kind || "hetzner");
      return '<div class="fleet-row"><div class="fleet-main">' +
        '<div class="fleet-name"><span class="choice-ico sm ' + m.cls + '">' + esc(m.mark) + "</span>" +
          esc(m.name) + (p.label ? " &middot; " + esc(p.label) : "") + "</div>" +
        '</div><div class="fleet-badges"><span class="badge"><span class="dot up"></span>Connected</span></div></div>';
    }).join("");
  }

  // ====================================================== GITHUB (gh-2)
  // A small GitHub card in the Providers view. GET /v1/github/installation
  // returns {connected, account_login, configured, install_url} — no secret.
  // Three states: connected (show login + Disconnect), configured-but-not-
  // connected (a "Connect GitHub" link to the App install URL), and
  // not-configured (a graceful off state, no dead link).
  function loadGithub() {
    var box = $("#github-card");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading GitHub&hellip;</div>';
    api("GET", "/v1/github/installation").then(function (r) {
      if (!box.isConnected) return;
      renderGithub((r.ok && r.data) || {});
    });
  }

  function renderGithub(g) {
    var box = $("#github-card");
    if (!box) return;
    var row;
    if (g.connected) {
      row =
        '<div class="fleet-row"><div class="fleet-main">' +
          '<div class="fleet-name">GitHub &middot; ' + esc(g.account_login || "connected") + "</div>" +
          '<div class="dim">Barkpark can create a repo and deploy a template into your GitHub account.</div>' +
        '</div><div class="fleet-badges">' +
          '<span class="badge"><span class="dot up"></span>Connected</span>' +
          '<button class="btn btn-ghost btn-sm" id="github-disconnect" type="button">Disconnect</button>' +
        "</div></div>";
    } else if (g.configured && g.install_url) {
      row =
        '<div class="fleet-row"><div class="fleet-main">' +
          '<div class="fleet-name">GitHub</div>' +
          '<div class="dim">Connect GitHub so Barkpark can create a repo and deploy a template for you.</div>' +
        '</div><div class="fleet-badges">' +
          '<a class="btn btn-primary btn-sm" href="' + esc(g.install_url) + '">Connect GitHub</a>' +
        "</div></div>";
    } else {
      row =
        '<div class="fleet-row"><div class="fleet-main">' +
          '<div class="fleet-name">GitHub</div>' +
          "<div class=\"dim\">GitHub deploys aren't configured on this Barkpark yet.</div>" +
        '</div><div class="fleet-badges"><span class="badge">Not configured</span></div></div>';
    }
    box.innerHTML = '<div class="notif-card"><h2 class="notif-h">GitHub</h2>' + row + "</div>";
    var d = $("#github-disconnect");
    if (d) d.addEventListener("click", disconnectGithub);
  }

  function disconnectGithub() {
    api("DELETE", "/v1/github/installation").then(function (r) {
      if (r.ok) {
        toast({ kind: "success", title: "GitHub disconnected" });
        loadGithub();
      } else {
        toast({ kind: "error", title: "Couldn't disconnect", body: (r.data && r.data.error) || "" });
      }
    });
  }

  // ====================================================== NOTIFICATIONS
  // The per-event alert toggles, in display order. Labels mirror the server's
  // EmailSettings columns 1:1.
  var NOTIF_EVENTS = [
    ["provision_failed", "Provisioning failed"],
    ["provision_succeeded", "Provisioning succeeded"],
    ["deployment_failed", "Deployment failed"],
    ["deployment_succeeded", "Deployment succeeded"],
    ["agent_unreachable", "Instance unreachable"],
    ["agent_reachable", "Instance reachable again"],
    ["subscription_past_due", "Subscription past due"],
    ["member_invited", "Member invited"],
    ["token_expiring", "API token expiring"]
  ];

  function loadNotifications() {
    var box = $("#notif-body");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading notification settings&hellip;</div>';
    api("GET", "/v1/notifications/settings").then(function (r) {
      if (r.ok && r.data && r.data.settings) renderNotifications(r.data.settings);
      else box.innerHTML = '<div class="empty-state"><h2>Couldn\'t load settings</h2></div>';
    });
  }

  // Render the settings form. Secrets arrive MASKED ("********") — a placeholder
  // stands in for a stored value; leaving the field blank on save keeps it.
  function renderNotifications(s) {
    var box = $("#notif-body");
    if (!box) return;
    var transports = ["instance", "smtp", "api"];
    var transportOpts = transports.map(function (t) {
      return '<option value="' + t + '"' + (s.transport === t ? " selected" : "") + ">" +
        (t === "instance" ? "Barkpark platform" : t.toUpperCase()) + "</option>";
    }).join("");

    var toggles = NOTIF_EVENTS.map(function (pair) {
      var key = pair[0], label = pair[1];
      var on = s[key] === true;
      return '<label class="notif-toggle"><input type="checkbox" data-event="' + key + '"' +
        (on ? " checked" : "") + "> " + esc(label) + "</label>";
    }).join("");

    box.innerHTML =
      '<div class="notif-card">' +
      '<label class="notif-toggle"><input type="checkbox" id="notif-alerts"' +
        (s.alerts_enabled !== false ? " checked" : "") + "> <b>Email alerts enabled</b></label>" +
      '<div class="notif-row"><label>Transport</label>' +
        '<select id="notif-transport" class="form-input">' + transportOpts + "</select></div>" +
      '<div class="notif-row"><label>From address</label>' +
        '<input id="notif-from-addr" class="form-input" type="email" value="' + esc(s.from_address || "") + '" placeholder="noreply@barkpark.cloud"></div>' +
      '<div class="notif-smtp">' +
        '<div class="notif-row"><label>SMTP host</label><input id="notif-smtp-host" class="form-input" placeholder="' +
          (s.smtp_host ? "•••••••• (stored)" : "smtp.example.com") + '"></div>' +
        '<div class="notif-row"><label>SMTP username</label><input id="notif-smtp-user" class="form-input" placeholder="' +
          (s.smtp_username ? "•••••••• (stored)" : "username") + '"></div>' +
        '<div class="notif-row"><label>SMTP password</label><input id="notif-smtp-pass" class="form-input" type="password" placeholder="' +
          (s.smtp_password ? "•••••••• (stored)" : "password") + '"></div>' +
        '<div class="notif-row"><label>SMTP port</label><input id="notif-smtp-port" class="form-input" type="number" value="' + esc(s.smtp_port || "") + '" placeholder="587"></div>' +
      "</div>" +
      '<h2 class="notif-h">Events</h2><div class="notif-toggles">' + toggles + "</div>" +
      '<button class="btn btn-primary" id="notif-save" type="button">Save settings</button>' +
      '<span id="notif-status" class="dim"></span>' +
      "</div>";

    var save = $("#notif-save");
    if (save) save.addEventListener("click", saveNotifications);

    // SMTP fields only apply to the "smtp" transport — hide them otherwise.
    // (Blank secret fields keep stored values on save, so hiding is safe.)
    var transport = $("#notif-transport");
    var smtp = box.querySelector(".notif-smtp");
    function syncSmtpVisibility() { smtp.hidden = transport.value !== "smtp"; }
    transport.addEventListener("change", syncSmtpVisibility);
    syncSmtpVisibility();
  }

  function saveNotifications() {
    var body = {
      alerts_enabled: $("#notif-alerts").checked,
      transport: $("#notif-transport").value,
      from_address: $("#notif-from-addr").value.trim()
    };
    // Only send a secret when the user actually typed one (blank keeps stored).
    var host = $("#notif-smtp-host").value.trim();
    var user = $("#notif-smtp-user").value.trim();
    var pass = $("#notif-smtp-pass").value;
    var port = $("#notif-smtp-port").value.trim();
    if (host) body.smtp_host = host;
    if (user) body.smtp_username = user;
    if (pass) body.smtp_password = pass;
    if (port) body.smtp_port = parseInt(port, 10);
    NOTIF_EVENTS.forEach(function (pair) {
      var el = document.querySelector('input[data-event="' + pair[0] + '"]');
      if (el) body[pair[0]] = el.checked;
    });

    var status = $("#notif-status");
    setText(status, "Saving…");
    api("PUT", "/v1/notifications/settings", body).then(function (r) {
      if (r.ok && r.data && r.data.settings) {
        renderNotifications(r.data.settings);
        setText($("#notif-status"), "Saved.");
      } else {
        setText($("#notif-status"), friendly(r.data, "Couldn't save."));
      }
    });
  }

  // =========================================================== API TOKENS
  // Personal Access Tokens — minted/listed/revoked from the logged-in dashboard
  // (the management routes are SESSION-only; a PAT can never mint another PAT).
  // The plaintext is shown ONCE, in a reveal step after a successful mint.
  var TOKEN_ABILITIES = [
    { id: "read", label: "Read", sub: "Read control-plane resources" },
    { id: "write", label: "Write", sub: "Create / change sites, env, domains" },
    { id: "deploy", label: "Deploy", sub: "Launch / go-live only (exclusive)" },
    { id: "root", label: "Root", sub: "Full access — every ability (exclusive)" }
  ];
  var TOKEN_EXPIRIES = [
    { v: "7", label: "7 days" },
    { v: "30", label: "30 days" },
    { v: "60", label: "60 days" },
    { v: "90", label: "90 days" },
    { v: "365", label: "1 year" },
    { v: "never", label: "Never" }
  ];

  function fmtTokenDate(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    return isNaN(d.getTime()) ? "—" : d.toLocaleDateString();
  }

  function loadTokens() {
    var box = $("#token-list");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading tokens&hellip;</div>';
    api("GET", "/v1/tokens").then(function (r) {
      var list = (r.ok && r.data && r.data.tokens) || [];
      renderTokenList(list);
    });
  }

  function renderTokenList(list) {
    var box = $("#token-list");
    if (!box) return;
    if (!list || !list.length) {
      box.innerHTML =
        '<div class="empty-state"><h2>No API tokens yet</h2>' +
        "<p>Mint a Personal Access Token to call the Barkpark Cloud API from scripts and CI.</p>" +
        '<button class="btn btn-primary" id="token-add-empty" type="button">New token</button></div>';
      var b = $("#token-add-empty");
      if (b) b.addEventListener("click", openTokenModal);
      return;
    }
    box.innerHTML = list.map(tokenRow).join("");
    box.querySelectorAll(".token-revoke[data-id]").forEach(function (b) {
      b.addEventListener("click", function () {
        confirmRevokeToken(b.getAttribute("data-id"), b.getAttribute("data-name"));
      });
    });
  }

  function tokenRow(t) {
    var revoked = !!t.revoked_at;
    var abilities = (t.abilities || []).map(function (a) {
      return '<span class="token-chip">' + esc(a) + "</span>";
    }).join("");
    var lastUsed = t.last_used_at ? fmtTokenDate(t.last_used_at) : "never used";
    var expiry = t.expires_at ? "expires " + fmtTokenDate(t.expires_at) : "no expiry";
    var statusPill = revoked
      ? '<span class="badge"><span class="dot down"></span>Revoked</span>'
      : '<span class="badge"><span class="dot up"></span>Active</span>';
    var action = revoked
      ? ""
      : '<button class="btn btn-ghost btn-sm token-revoke" data-id="' + esc(t.id) +
        '" data-name="' + esc(t.name) + '" type="button">Revoke</button>';

    return '<div class="fleet-row token-row' + (revoked ? " is-revoked" : "") + '">' +
      '<div class="fleet-main">' +
        '<div class="fleet-name">' + esc(t.name) + "</div>" +
        '<div class="token-meta dim">' + abilities +
          '<span class="token-dot">&middot;</span>' + esc(lastUsed) +
          '<span class="token-dot">&middot;</span>' + esc(expiry) +
        "</div>" +
      "</div>" +
      '<div class="fleet-badges">' + statusPill + action + "</div>" +
    "</div>";
  }

  function openTokenModal() {
    var abilityRows = TOKEN_ABILITIES.map(function (a) {
      return '<label class="token-ability"><input type="checkbox" class="token-ab" value="' + esc(a.id) + '"' +
        (a.id === "read" ? " checked" : "") + ' />' +
        '<span class="token-ability-main"><span class="token-ability-name">' + esc(a.label) + "</span>" +
        '<span class="token-ability-sub dim">' + esc(a.sub) + "</span></span></label>";
    }).join("");
    var expiryOpts = TOKEN_EXPIRIES.map(function (e) {
      return '<option value="' + esc(e.v) + '"' + (e.v === "30" ? " selected" : "") + ">" + esc(e.label) + "</option>";
    }).join("");

    openModal(
      '<h2 class="modal-title" id="modal-title">New API token</h2>' +
      '<p class="modal-sub">Scope the token to the abilities it needs. You will see the token value once.</p>' +
      '<div class="field"><label class="label" for="token-name">Name</label>' +
        '<input class="form-input" id="token-name" type="text" placeholder="CI deploy key" /></div>' +
      '<div class="field"><span class="label">Abilities</span>' +
        '<div class="token-ability-list">' + abilityRows + "</div></div>" +
      '<div class="field"><label class="label" for="token-expiry">Expiry</label>' +
        '<select class="form-input" id="token-expiry">' + expiryOpts + "</select></div>" +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="token-submit" type="button">Create token</button></div>'
    );

    // Client-side exclusivity mirror (the SERVER is authoritative via
    // normalize_abilities): checking root/deploy clears the others, and any
    // other check clears root/deploy.
    var boxes = $("#modal-body").querySelectorAll(".token-ab");
    boxes.forEach(function (cb) {
      cb.addEventListener("change", function () {
        if (!cb.checked) return;
        var v = cb.value;
        boxes.forEach(function (other) {
          if (other === cb) return;
          var exclusive = v === "root" || v === "deploy" || other.value === "root" || other.value === "deploy";
          if (exclusive) other.checked = false;
        });
      });
    });
    $("#token-submit").addEventListener("click", submitToken);
    $("#token-name").focus();
  }

  function submitToken() {
    var name = ($("#token-name").value || "").trim();
    var abilities = [];
    $("#modal-body").querySelectorAll(".token-ab:checked").forEach(function (cb) { abilities.push(cb.value); });
    var expiry = $("#token-expiry").value;

    if (name.length < 3) { toast({ kind: "error", title: "Name must be at least 3 characters." }); return; }
    if (!abilities.length) { toast({ kind: "error", title: "Pick at least one ability." }); return; }

    var btn = $("#token-submit");
    btn.disabled = true;
    btn.textContent = "Creating…";

    var body = { name: name, abilities: abilities, expires_in_days: expiry };
    api("POST", "/v1/tokens", body).then(function (r) {
      if (r.status === 201 && r.data && r.data.token) {
        revealToken(r.data.token, r.data.pat || { name: name });
      } else {
        btn.disabled = false;
        btn.textContent = "Create token";
        toast({ kind: "error", title: "Couldn't create token", body: friendly(r.data, "Check the form and try again.") });
      }
    });
  }

  function sendTestNotification() {
    var status = $("#notif-status");
    if (status) setText(status, "Sending test…");
    api("POST", "/v1/notifications/test", {}).then(function (r) {
      var msg;
      if (r.ok) msg = "Test email sent.";
      else if (r.data && r.data.error === "rate_limited")
        msg = "Please wait " + (r.data.retry_after || 10) + "s before another test.";
      else msg = friendly(r.data, "Couldn't send a test.");
      if ($("#notif-status")) setText($("#notif-status"), msg);
    });
  }

  // One-time reveal. The plaintext is shown here and NEVER again — closing
  // reloads the list (the new row shows, no plaintext).
  function revealToken(plaintext, pat) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Token created</h2>' +
      '<p class="modal-sub">Copy it now — <b>you will not see this token again.</b></p>' +
      '<div class="token-reveal">' +
        '<input class="form-input token-reveal-input" id="token-reveal-value" type="text" readonly value="' + esc(plaintext) + '" />' +
        '<button class="btn btn-sm" id="token-copy" type="button">Copy</button>' +
      "</div>" +
      '<p class="field-hint dim">' + esc((pat && pat.name) || "") + '</p>' +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="token-done" type="button">Done</button></div>'
    );
    var input = $("#token-reveal-value");
    if (input) { input.focus(); input.select(); }
    $("#token-copy").addEventListener("click", function () {
      input.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      if (!ok && navigator.clipboard) { navigator.clipboard.writeText(plaintext).then(function () {}); }
      toast({ kind: "success", title: "Copied to clipboard" });
    });
    $("#token-done").addEventListener("click", function () {
      closeModal();
      loadTokens();
    });
  }

  function confirmRevokeToken(id, name) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Revoke token?</h2>' +
      '<p class="modal-sub">Revoking <b>' + esc(name || "this token") + "</b> immediately stops it from authenticating. This cannot be undone.</p>" +
      '<div class="modal-actions">' +
        '<button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" id="token-revoke-go" type="button">Revoke</button>' +
      "</div>"
    );
    $("#token-revoke-go").addEventListener("click", function () {
      var btn = $("#token-revoke-go");
      btn.disabled = true;
      btn.textContent = "Revoking…";
      api("DELETE", "/v1/tokens/" + encodeURIComponent(id)).then(function (r) {
        closeModal();
        if (r.ok) {
          toast({ kind: "success", title: "Token revoked" });
        } else {
          toast({ kind: "error", title: "Couldn't revoke token", body: friendly(r.data) });
        }
        loadTokens();
      });
    });
  }

  // =========================================================== THEME
  // The button's VISIBLE word is the theme you'd switch TO; its accessible name
  // must contain that same word or voice-control ("click Dark") misses and
  // WCAG 2.5.3 Label-in-Name fails. Both derive from one place, in lockstep.
  function themeLabelText(t) { return t === "dark" ? "Light" : "Dark"; }
  function themeToggleAria(t) { return t === "dark" ? "Switch to light theme" : "Switch to dark theme"; }

  function applyTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    var label = themeLabelText(t);
    var aria = themeToggleAria(t);
    setText($("#theme-label"), label);
    setText($("#new-theme-label"), label); // /new screen's own toggle, kept in sync
    var tt = $("#theme-toggle"); if (tt) tt.setAttribute("aria-label", aria);
    var nt = $("#new-theme-toggle"); if (nt) nt.setAttribute("aria-label", aria);
  }
  function initTheme() {
    var t = localStorage.getItem(THEME) || (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    applyTheme(t);
  }
  function toggleTheme() {
    var cur = document.documentElement.getAttribute("data-theme");
    var next = cur === "dark" ? "light" : "dark";
    localStorage.setItem(THEME, next);
    applyTheme(next);
  }

  // =========================================================== AUTH SCREEN
  var authMode = "login";

  function setAuthMode(mode) {
    authMode = mode;
    var login = mode === "login";
    $("#tab-login").classList.toggle("is-active", login);
    $("#tab-signup").classList.toggle("is-active", !login);
    $("#tab-login").setAttribute("aria-selected", String(login));
    $("#tab-signup").setAttribute("aria-selected", String(!login));
    $("#field-team").hidden = login;
    $("#field-remember").hidden = !login;
    setText($("#auth-submit"), login ? "Log in" : "Create account");
    $("#auth-password").setAttribute("autocomplete", login ? "current-password" : "new-password");
    $("#auth-foot").innerHTML = login
      ? 'New to Barkpark Cloud? <a href="#" id="auth-switch-link">Create an account</a>.'
      : 'Already have an account? <a href="#" id="auth-switch-link">Log in</a>.';
    wireSwitchLink();
    hideAuthError();
  }
  function wireSwitchLink() {
    var link = $("#auth-switch-link");
    if (link) link.addEventListener("click", function (e) {
      e.preventDefault();
      setAuthMode(authMode === "login" ? "signup" : "login");
    });
  }
  function showAuthError(msg) { var e = $("#auth-error"); setText(e, msg); show(e); }
  function hideAuthError() { hide($("#auth-error")); }

  // ----------------------------------------------------------- password reset
  // The token from an emailed reset link, held between render() (which reads the
  // hash) and submitReset() (which POSTs it). Cleared once consumed.
  var pendingResetToken = null;

  // Extract the reset token from a #/auth/reset?token=… hash, or null. Kept out
  // of parseHash (which routes the AUTHENTICATED app) — this link is hit logged
  // out, off the email, and only render()'s logged-out branch consults it.
  function resetTokenFromHash() {
    var m = (location.hash || "").match(/^#\/auth\/reset\?token=([^&]+)/);
    return m ? safeDecode(m[1]) : null;
  }

  function showResetError(msg) { var e = $("#reset-error"); setText(e, msg); show(e); }
  function hideResetError() { hide($("#reset-error")); }

  // "Forgot password?" — POST the email; ALWAYS show the same neutral confirmation
  // (the endpoint is enumeration-safe, so the UI must be too — never reveal whether
  // the address has an account).
  function requestPasswordReset() {
    hideAuthError();
    var email = ($("#auth-email").value || "").trim();
    if (!email) {
      showAuthError('Enter your email above, then click "Forgot password?"');
      $("#auth-email").focus();
      return;
    }

    var link = $("#auth-forgot");
    link.setAttribute("aria-disabled", "true");
    api("POST", "/v1/auth/request-reset", { email: email }, { noAuth: true }).then(function () {
      link.removeAttribute("aria-disabled");
      toast({
        kind: "info",
        title: "Check your email",
        body: "If an account exists for " + email + ", a password-reset link is on its way. It expires in an hour."
      });
    });
  }

  // Submit the new password against the emailed token. On success the server has
  // signed the user out everywhere, so we drop the token from the URL and send
  // them back to a clean login.
  function submitReset(e) {
    e.preventDefault();
    hideResetError();
    var password = $("#reset-password").value;
    if (!password) { showResetError("Enter a new password."); return; }
    if (!pendingResetToken) {
      showResetError("This reset link is invalid — request a new one from the login screen.");
      return;
    }

    var btn = $("#reset-submit");
    btn.disabled = true;
    api("POST", "/v1/auth/reset", { token: pendingResetToken, password: password }, { noAuth: true }).then(function (r) {
      btn.disabled = false;
      if (r.ok) {
        pendingResetToken = null;
        location.hash = "";
        toast({ kind: "success", title: "Password reset", body: "Your password was changed — log in with the new one." });
        render();
      } else if (r.status === 401) {
        showResetError("This reset link is invalid or has expired. Request a new one from the login screen.");
      } else {
        showResetError(friendly(r.data, "Couldn't reset your password."));
      }
    });
  }

  function submitAuth(e) {
    e.preventDefault();
    hideAuthError();
    var email = $("#auth-email").value.trim();
    var password = $("#auth-password").value;
    var team = $("#auth-team").value.trim();
    if (!email || !password) { showAuthError("Email and password are required."); return; }

    var btn = $("#auth-submit");
    btn.disabled = true;

    var path = authMode === "login" ? "/v1/auth/login" : "/v1/auth/register";
    var body = { email: email, password: password };
    if (authMode === "signup" && team) body.team_name = team;

    var remember = authMode !== "login" || $("#auth-remember").checked;

    api("POST", path, body, { noAuth: true }).then(function (r) {
      btn.disabled = false;
      if (r.ok && r.data && r.data.token) {
        setSession({ token: r.data.token, team_id: r.data.team_id || null }, remember);
        location.hash = "#overview";
        render();
      } else {
        showAuthError(friendly(r.data, "Couldn't sign you in."));
      }
    });
  }

  // =========================================================== NAV / ROUTER
  // Every rendered section id ("view-<v>"). The IA reshape (charter decision 6)
  // groups these into a 4-place PRIMARY nav (overview/fleet/sites/activity) plus
  // a SETTINGS cluster (billing/providers/notifications/tokens); "launch" is no
  // longer a top tab — it is an ACTION reachable from Overview and the empty
  // fleet — but its old #launch bookmark still resolves to a real view.
  var VIEWS = ["overview", "fleet", "sites", "launch", "billing", "providers", "notifications", "tokens", "activity"];
  var SETTINGS_VIEWS = ["billing", "providers", "notifications", "tokens"];

  // Routes are either a tab (#overview …) or a drill-down (#instance/<id>, #site/<id>).
  var DETAIL_VIEWS = ["instance", "site"];

  // Charter decisions 6 + 14: the IA moved, but no deep link may ever break.
  // legacyRoute is the PURE remap from any historical hash body to its canonical
  // destination. The legacy-stable set `bp cloud open` mints (#fleet, #sites,
  // #activity, #instance/<id>, #site/<id> — decision 14) passes through
  // untouched, FOREVER; the four Settings pages moved under #settings/<page>, so
  // their old flat bookmarks (#billing …) remap here; an empty hash lands on the
  // new Overview home. Total over any string; never throws.
  function legacyRoute(hash) {
    var h = String(hash == null ? "" : hash).replace(/^#/, "");
    if (h === "") return "overview";
    var MAP = {
      billing: "settings/billing",
      providers: "settings/providers",
      notifications: "settings/notifications",
      tokens: "settings/tokens",
    };
    return Object.prototype.hasOwnProperty.call(MAP, h) ? MAP[h] : h;
  }

  // Pure: the Fleet bucket a #fleet/<bucket> deep link selects (charter decision
  // 15 buckets). Anything but a known bucket → null = "show the whole fleet", so
  // a stale or hand-typed suffix degrades to the full list, never an error.
  function parseFleetFilter(hash) {
    var h = String(hash == null ? "" : hash).replace(/^#/, "");
    var m = h.match(/^fleet\/([a-z]+)$/);
    if (!m) return null;
    return m[1] === "attention" || m[1] === "inflight" || m[1] === "healthy" ? m[1] : null;
  }

  function parseHash() {
    var canon = legacyRoute((location.hash || "").replace(/^#/, ""));
    var mi = canon.match(/^instance\/(.+)$/);
    if (mi) return { view: "instance", id: safeDecode(mi[1]) };
    var ms = canon.match(/^site\/(.+)$/);
    if (ms) return { view: "site", id: safeDecode(ms[1]) };
    var mset = canon.match(/^settings\/([a-z]+)$/);
    if (mset && SETTINGS_VIEWS.indexOf(mset[1]) !== -1) return { view: mset[1] };
    if (/^fleet\/[a-z]+$/.test(canon)) return { view: "fleet", filter: parseFleetFilter(canon) };
    return { view: VIEWS.indexOf(canon) !== -1 ? canon : "overview" };
  }

  function applyRoute() {
    var r = parseHash();
    var detail = DETAIL_VIEWS.indexOf(r.view) !== -1;
    // Which PRIMARY nav entry stays highlighted. A drill-down keeps its parent
    // lit; the four Settings pages light the single "settings" cluster trigger.
    var activeNav = r.view === "site" ? "sites"
      : r.view === "instance" ? "fleet"
      : SETTINGS_VIEWS.indexOf(r.view) !== -1 ? "settings"
      : r.view; // overview | fleet | sites | activity | launch
    VIEWS.forEach(function (v) {
      var sec = document.getElementById("view-" + v);
      if (sec) sec.hidden = detail || v !== r.view;
    });
    document.querySelectorAll(".nav-link[data-view]").forEach(function (link) {
      var on = link.getAttribute("data-view") === activeNav;
      link.classList.toggle("is-active", on);
      // Additive SR cue: exactly one nav-link carries aria-current="page".
      if (on) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
    // Collapse the Settings disclosure after every navigation so it never lingers
    // open over the next page.
    var menu = document.querySelector(".nav-menu");
    if (menu) menu.removeAttribute("open");
    var inst = document.getElementById("view-instance");
    if (inst) inst.hidden = r.view !== "instance";
    var site = document.getElementById("view-site");
    if (site) site.hidden = r.view !== "site";

    if (r.view === "instance") { loadInstance(r.id); return; }
    if (r.view === "site") { loadSite(r.id); return; }
    setBreadcrumb(null);
    if (r.view === "overview") loadOverview();
    if (r.view === "fleet") loadFleet(r.filter || null);
    if (r.view === "sites") loadSites();
    if (r.view === "billing") renderRecommended();
    if (r.view === "launch") renderLaunchGate();
    if (r.view === "providers") { loadProviders(); loadGithub(); }
    if (r.view === "notifications") loadNotifications();
    if (r.view === "tokens") loadTokens();
    if (r.view === "activity") loadActivity();
  }

  // crumbs: array of {label, href?}; the last item is the current page (no link,
  // rendered with an avatar chip). Pass null/[] to clear.
  function setBreadcrumb(crumbs) {
    var c = $("#crumbs");
    if (!c) return;
    if (!crumbs || !crumbs.length) { c.innerHTML = ""; return; }
    c.innerHTML = crumbs.map(function (cr, i) {
      var sep = '<span class="crumb-sep" aria-hidden="true">/</span>';
      if (i === crumbs.length - 1) {
        return sep + '<span class="crumb-cur"><span class="org-avatar" aria-hidden="true">' +
          esc((String(cr.label)[0] || "B").toUpperCase()) + "</span><span>" + esc(cr.label) + "</span></span>";
      }
      return sep + (cr.href ? '<a href="' + esc(cr.href) + '">' + esc(cr.label) + "</a>" : "<span>" + esc(cr.label) + "</span>");
    }).join("");
  }

  // =========================================================== FLEET
  function badge(label, kind, value) {
    return '<span class="badge"><span class="dot ' + esc(kind) + '"></span>' +
      esc(label) + '</span>';
  }

  // ------------------------------------------------ status + attention (pure)
  // classifyBp collapses the fleet fields GET /v1/barkparks already returns
  // (provision/deprovision status, suspended, health_status, agent_status,
  // update_state) into exactly ONE of the eight ranked states of charter
  // decision 15 — the single attention-order spec. Both statusOf (the pill) and
  // attentionRank/bucketOf (the queue + rollup) derive from it, so the pill's
  // colour and the queue's order can never disagree. This is the JS twin of
  // slice 9's Go statusRole/attention order; they MUST agree on ordering.
  // CITE: charter decision 15 (Rank, most urgent first; tiebreak name asc, ci).
  function classifyBp(bp) {
    bp = bp || {};
    var host = !!bp.host;
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    // "live" mirrors the Go reference EXACTLY (cloud_status_cmd.go statusOf):
    // host set, not tearing down, not suspended. A failed *latest* provision job
    // is deliberately NOT excluded — for a host-set box that is otherwise
    // healthy the CLI reads "ok", so we must too; and a host-set box that is
    // UNHEALTHY must read "degraded", never slip to a false-green "ok". Both
    // surfaces implement decision 15, so they must agree byte-for-byte.
    var live = host && !removing && !bp.suspended;
    var healthy = (bp.health_status || "unknown") === "up" && (bp.agent_status || "offline") === "online";

    if (bp.deprovision_status === "failed") return "removal_failed"; // 1
    if (!host && bp.provision_status === "failed") return "failed";  // 2
    if (bp.suspended && !removing) return "suspended";              // 3
    if (live && !healthy) return "degraded";                       // 4
    if (live && bp.update_state === "behind") return "behind";     // 5
    if (removing) return "removing";                              // 6
    if (!host) return "provisioning";                            // 7 (rank-2 already excluded)
    return "ok";                                                // 8
  }

  // The rank number per decision 15 (1 = most urgent … 8 = ok).
  var ATTENTION_RANK = {
    removal_failed: 1, failed: 2, suspended: 3, degraded: 4,
    behind: 5, removing: 6, provisioning: 7, ok: 8,
  };
  function attentionRank(bp) { return ATTENTION_RANK[classifyBp(bp)]; }

  // Sort comparator: most urgent first, tiebreak on name ascending,
  // case-insensitive (decision 15). Stable, pure, total over missing names.
  function attentionCompare(a, b) {
    var d = attentionRank(a) - attentionRank(b);
    if (d) return d;
    var an = String((a && a.name) || "").toLowerCase();
    var bn = String((b && b.name) || "").toLowerCase();
    return an < bn ? -1 : an > bn ? 1 : 0;
  }

  // Buckets (decision 15): attention = ranks 1–5, in-flight = 6–7, healthy = 8.
  function bucketOf(bp) {
    var r = attentionRank(bp);
    return r <= 5 ? "attention" : r <= 7 ? "inflight" : "healthy";
  }

  // Pure rollup of a fleet list into the three bucket counts + total.
  function fleetSummary(list) {
    var out = { attention: 0, inflight: 0, healthy: 0, total: 0 };
    (list || []).forEach(function (bp) { out[bucketOf(bp)] += 1; out.total += 1; });
    return out;
  }

  // Pure: the instances in a given bucket (null bucket → the whole list, copied).
  function filterFleet(list, bucket) {
    if (!bucket) return (list || []).slice();
    return (list || []).filter(function (bp) { return bucketOf(bp) === bucket; });
  }

  // Pure: the single semantic status of an instance — ONE role (ok|info|warn|
  // danger|neutral) mapping to the --ok/--info/--warn/--danger token contract,
  // a primary label, and a secondary detail string. Replaces the multi-badge
  // soup; the health/agent/update breakdown lives only in the drill-down rail.
  function statusOf(bp) {
    bp = bp || {};
    var kind = classifyBp(bp);
    if (kind === "removal_failed") return { role: "danger", label: "Removal failed", detail: bp.deprovision_error || "Teardown failed — retry removal" };
    if (kind === "failed") return { role: "danger", label: "Failed", detail: bp.provision_error || "Provisioning failed" };
    if (kind === "suspended") return { role: "danger", label: "Suspended", detail: bp.suspended_reason || "Suspended for billing" };
    if (kind === "degraded") {
      var parts = [];
      if ((bp.health_status || "unknown") !== "up") parts.push("Health " + (bp.health_status || "unknown"));
      if ((bp.agent_status || "offline") !== "online") parts.push("Agent " + (bp.agent_status || "offline"));
      return { role: "warn", label: "Degraded", detail: parts.join(" · ") || "Needs attention" };
    }
    if (kind === "behind") return { role: "info", label: "Update available", detail: bp.update_latest_release ? "→ " + vRel(bp.update_latest_release) : "A newer release is available" };
    if (kind === "removing") return { role: "info", label: "Removing", detail: "Tearing down the server" };
    if (kind === "provisioning") return { role: "info", label: "Provisioning", detail: "Setting up the server" };
    if (kind === "ok") return { role: "ok", label: "Healthy", detail: bp.version ? "v" + String(bp.version).replace(/^v/, "") : "Online" };
    return { role: "neutral", label: "Unknown", detail: "" };
  }

  // The single .status-pill component — one dot + label + optional detail,
  // coloured by the semantic role. This is the only status affordance in a
  // fleet row and the instance-detail header (charter decision 6).
  function statusPill(bp) {
    var s = statusOf(bp);
    return '<span class="status-pill status-pill--' + esc(s.role) + '">' +
      '<span class="status-pill-dot" aria-hidden="true"></span>' +
      '<span class="status-pill-label">' + esc(s.label) + "</span>" +
      (s.detail ? '<span class="status-pill-detail">' + esc(s.detail) + "</span>" : "") +
    "</span>";
  }

  function fleetRow(bp) {
    // host (not url) is the "box is actually up" signal: go_live now sets url at
    // launch (the FQDN is deterministic <slug>-<teamid>), so !bp.url would never
    // be true; host is set only once the worker reports success. A FAILED
    // provision (provision_status) leaves host nil too — distinguish it so the
    // row reads "failed" with a path to retry/remove (in the detail view).
    // A deprovision (Remove) in flight takes display precedence.
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    var removeFailed = bp.deprovision_status === "failed";
    var failed = !removing && !removeFailed && !bp.host && bp.provision_status === "failed";
    var provisioning = !removing && !removeFailed && !bp.host && !failed;

    var urlHtml = removing
      ? '<div class="fleet-url provisioning">&mdash; removing</div>'
      : removeFailed
        ? '<div class="fleet-url failed">&mdash; removal failed</div>'
        : failed
          ? '<div class="fleet-url failed">&mdash; provisioning failed</div>'
          : provisioning
            ? '<div class="fleet-url provisioning">&mdash; provisioning</div>'
            : '<div class="fleet-url">' + esc(bp.url) + "</div>";

    // Billing suspension (see router.ex barkpark_json): the box exists but the
    // platform stopped it — folded into statusOf()'s single pill below.
    var live = !removing && !removeFailed && !failed && !provisioning && !bp.suspended && bp.host;

    // The whole provision/suspend/health/agent/update collapse is now ONE pill
    // (charter decision 6); the health/agent/update breakdown moved to the
    // instance-detail rail only.
    var pill = statusPill(bp);

    // dwb-7 one-click Studio entry: live boxes (host set, nothing in-flight)
    // get an Open Studio button — server-minted single-use link, no token paste.
    var openStudioBtn = live
      ? '<button class="btn btn-primary btn-sm fleet-open-studio" type="button" data-id="' +
          esc(bp.id) + '">Open Studio</button>'
      : "";

    return '<div class="fleet-row" data-id="' + esc(bp.id) + '" role="button" tabindex="0">' +
      '<div class="fleet-main">' +
        '<div class="fleet-name">' + esc(bp.name) + "</div>" +
        urlHtml +
      "</div>" +
      '<div class="fleet-badges">' +
        pill + openStudioBtn +
      "</div>" +
      '<span class="fleet-chev" aria-hidden="true">&rsaquo;</span>' +
    "</div>";
  }

  // dwb-7: one-click Studio entry. POSTs /v1/barkparks/:id/studio-link — the
  // control plane mints a single-use, 60s login ticket ON the instance with its
  // stored admin token and returns {url}. We open the tab SYNCHRONOUSLY inside
  // the click gesture (popup blockers eat deferred window.open) and navigate it
  // when the URL arrives; on failure the tab is closed and a toast explains.
  function openStudio(id, btn) {
    if (btn) { btn.disabled = true; btn.textContent = "Opening…"; }
    var win = window.open("", "_blank");
    api("POST", "/v1/barkparks/" + encodeURIComponent(id) + "/studio-link", {}).then(function (r) {
      if (btn) { btn.disabled = false; btn.textContent = "Open Studio"; }
      if (r.ok && r.data && r.data.url) {
        if (win) { win.location = r.data.url; } else { window.open(r.data.url); }
      } else {
        if (win) win.close();
        toast({ kind: "error", title: "Couldn't open Studio", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // Last fetched fleet, reused by the instance drill-down (avoids a second
  // round-trip on row click). Cleared after a launch so it refetches.
  var fleetCache = null;
  function ensureFleet() {
    if (fleetCache) return Promise.resolve(fleetCache);
    return api("GET", "/v1/barkparks").then(function (r) {
      // Only cache on success — caching a transient 5xx/network failure as []
      // would make every consumer treat live instances as "not found" forever.
      if (r.ok && r.data && r.data.barkparks) {
        fleetCache = r.data.barkparks;
        return fleetCache;
      }
      return null;
    });
  }

  // Shared row wiring: click / keyboard drill-in plus the per-row Open Studio
  // button. Used by both the Fleet list and the Overview attention queue.
  function wireFleetRows(container) {
    if (!container) return;
    container.querySelectorAll(".fleet-row[data-id]").forEach(function (row) {
      var go = function () { location.hash = "#instance/" + encodeURIComponent(row.getAttribute("data-id")); };
      row.addEventListener("click", go);
      row.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); }
      });
    });
    container.querySelectorAll(".fleet-open-studio").forEach(function (b) {
      b.addEventListener("click", function (e) {
        e.stopPropagation(); // don't also drill into the row's detail view
        openStudio(b.getAttribute("data-id"), b);
      });
    });
  }

  // The onboarding card — first-run guidance, also the Overview onboarding slot.
  function onboardingCard() {
    return '<div class="card start-card">' +
      "<h2>Get started</h2>" +
      "<p>Two steps to your first managed Barkpark — we host it for you.</p>" +
      startStep(1, "Choose a plan", "Pick a subscription to unlock launches.", "billing", "Choose") +
      startStep(2, "Launch your first instance", "Name it and we provision it for you — fully managed.", "launch", "Launch") +
      '<p class="start-foot dim">Prefer your own cloud account? ' +
        'Connect a provider under <a href="#providers">Providers</a> (advanced).</p>' +
    "</div>";
  }

  var BUCKET_LABEL = { attention: "needs attention", inflight: "in flight", healthy: "healthy" };
  function fleetFilterBar(bucket, n) {
    return '<div class="fleet-filter-bar">' +
      "<span>Showing " + n + " " + esc(BUCKET_LABEL[bucket] || bucket) + "</span>" +
      '<a href="#fleet">Show all</a>' +
    "</div>";
  }

  // The Fleet list. An optional bucket filter (from #fleet/<bucket>, charter
  // decision 15) narrows the list and shows a bar with a "Show all" affordance.
  function loadFleet(filter) {
    filter = filter || null;
    var body = $("#fleet-body");
    body.innerHTML = '<div class="loading">Loading fleet&hellip;</div>';
    api("GET", "/v1/barkparks").then(function (r) {
      if (!r.ok) {
        body.innerHTML = '<div class="empty-state"><h2>Couldn\'t load fleet</h2><p>' +
          esc(friendly(r.data)) + "</p></div>";
        return;
      }
      var list = (r.data && r.data.barkparks) || [];
      fleetCache = list;
      if (!list.length) {
        body.innerHTML = onboardingCard();
        wireStartSteps();
        return;
      }
      var shown = filterFleet(list, filter);
      var bar = filter ? fleetFilterBar(filter, shown.length) : "";
      if (!shown.length) {
        body.innerHTML = bar +
          '<div class="empty-state"><h2>Nothing here right now</h2>' +
          "<p>No instances are " + esc(BUCKET_LABEL[filter] || "in this view") +
          '. <a href="#fleet">Show all</a>.</p></div>';
        return;
      }
      body.innerHTML = bar + shown.map(fleetRow).join("");
      wireFleetRows(body);
    });
  }

  // =========================================================== OVERVIEW (home)
  // The operator's landing page (charter decision 6): a rollup strip whose three
  // counts are clickable filters that deep-link into #fleet/<bucket>, an
  // attention QUEUE (most-urgent instance on top via attentionRank), an activity
  // digest that HIDES on 403 (/v1/audit is admin-gated), an onboarding card for
  // an empty fleet, and Launch-as-action in the header.
  function rollupCard(bucket, label, n) {
    return '<a class="rollup-card rollup-card--' + bucket + '" href="#fleet/' + bucket + '">' +
      '<span class="rollup-n">' + n + "</span>" +
      '<span class="rollup-k">' + esc(label) + "</span>" +
    "</a>";
  }
  function rollupStrip(sum) {
    return '<div class="rollup">' +
      rollupCard("attention", "Needs attention", sum.attention) +
      rollupCard("inflight", "In flight", sum.inflight) +
      rollupCard("healthy", "Healthy", sum.healthy) +
    "</div>";
  }

  function loadOverview() {
    var body = $("#overview-body");
    if (!body) return;
    body.innerHTML = '<div class="loading">Loading overview&hellip;</div>';
    api("GET", "/v1/barkparks").then(function (r) {
      if (!r.ok) {
        body.innerHTML = '<div class="empty-state"><h2>Couldn\'t load your fleet</h2><p>' +
          esc(friendly(r.data)) + "</p></div>";
        return;
      }
      var list = (r.data && r.data.barkparks) || [];
      fleetCache = list;
      if (!list.length) {
        body.innerHTML = onboardingCard();
        wireStartSteps();
        return;
      }
      var sum = fleetSummary(list);
      // The queue is ONLY the instances that actually need an operator — the
      // attention bucket (ranks 1–5), most-urgent first, capped. In-flight and
      // healthy boxes live in the rollup strip a click away; keeping them out is
      // what makes the "Needs your attention" heading, the "View all" target
      // (#fleet/attention), and the rollup card all name the SAME set.
      var queue = filterFleet(list, "attention").sort(attentionCompare).slice(0, 6);
      var queueHtml;
      if (queue.length) {
        queueHtml = '<div class="overview-sub"><h2>Needs your attention</h2>' +
            (sum.attention > queue.length ? '<a href="#fleet/attention">View all</a>' : "") +
          "</div>" + queue.map(fleetRow).join("");
      } else {
        // Nothing needs action. Stay honest when boxes are still in flight —
        // "all healthy" would be a lie while something is provisioning.
        var settled = sum.inflight === 0;
        queueHtml = '<div class="overview-ok"><span class="status-pill status-pill--ok">' +
            '<span class="status-pill-dot" aria-hidden="true"></span>' +
            '<span class="status-pill-label">' + (settled ? "All healthy" : "All clear") + "</span></span>" +
          "<p>" + (settled
            ? "Every instance is up, current, and reporting in."
            : "Nothing needs your attention right now — " + sum.inflight +
              (sum.inflight === 1 ? " instance in flight." : " instances in flight.")) +
          "</p></div>";
      }
      body.innerHTML = rollupStrip(sum) + queueHtml + '<div id="overview-digest"></div>';
      wireFleetRows(body);
      loadOverviewDigest();
    });
  }

  // Activity digest — the last few audit entries. /v1/audit is admin-gated
  // (charter: "Overview's activity digest must hide on 403, not error"), so a
  // 403 or any error silently removes the section rather than surfacing a scare.
  function loadOverviewDigest() {
    var box = $("#overview-digest");
    if (!box) return;
    api("GET", "/v1/audit?limit=5").then(function (r) {
      box = $("#overview-digest");
      if (!box) return;
      if (!r.ok) { box.innerHTML = ""; return; } // 403 (non-admin) or any error → hide
      var list = (r.data && r.data.events) || [];
      if (!list.length) { box.innerHTML = ""; return; }
      box.innerHTML = '<div class="overview-sub"><h2>Recent activity</h2><a href="#activity">View all</a></div>' +
        list.map(activityRow).join("");
    });
  }

  // =========================================================== INSTANCE DETAIL
  // Monotonic load counter: a slow response from an earlier loadInstance must
  // not paint over a newer one (rapid row-click → back → other row).
  var instanceLoadSeq = 0;
  function loadInstance(id) {
    var seq = ++instanceLoadSeq;
    var box = $("#instance-body");
    box.innerHTML = '<div class="loading">Loading instance&hellip;</div>';
    ensureFleet().then(function (list) {
      if (seq !== instanceLoadSeq) return; // a newer load owns the view
      if (!list) {
        // Fleet fetch failed — distinct from "the id isn't in a real list".
        setBreadcrumb(null);
        box.innerHTML = '<div class="empty-state"><h2>Couldn\'t load this instance</h2>' +
          '<p>Check your connection and retry.</p>' +
          '<p><button class="btn btn-primary btn-sm" id="inst-load-retry" type="button">Retry</button></p></div>';
        var retry = $("#inst-load-retry");
        if (retry) retry.addEventListener("click", function () { loadInstance(id); });
        return;
      }
      var bp = list.filter(function (x) { return String(x.id) === String(id); })[0];
      if (!bp) {
        setBreadcrumb(null);
        box.innerHTML = '<div class="empty-state"><h2>Instance not found</h2>' +
          '<p>It may have been removed. <a href="#fleet">Back to fleet</a>.</p></div>';
        return;
      }
      setBreadcrumb([{ label: "Fleet", href: "#fleet" }, { label: bp.name }]);
      box.innerHTML = instanceDetailHtml(bp);
      wireInstanceActions(bp);
      loadInstanceSites(bp);
    });
  }

  function instanceDetailHtml(bp) {
    // host is the "up" signal, not url (url is set at launch — see fleetRow). A
    // failed provision leaves host nil; surface it distinctly with the error +
    // retry/remove actions.
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    var removeFailed = bp.deprovision_status === "failed";
    var failed = !removing && !removeFailed && !bp.host && bp.provision_status === "failed";
    var provisioning = !removing && !removeFailed && !bp.host && !failed;

    var url = removing
      ? '<div class="fleet-url provisioning">&mdash; removing</div>'
      : removeFailed
        ? '<div class="fleet-url failed">&mdash; removal failed</div>'
        : failed
          ? '<div class="fleet-url failed">&mdash; provisioning failed</div>'
          : provisioning
            ? '<div class="fleet-url provisioning">&mdash; provisioning</div>'
            : '<div class="fleet-url">' + esc(bp.url) + "</div>";

    // Billing suspension: distinct from a health-down box (see fleetRow) — folded
    // into the single header pill; the banner below still spells it out.
    var suspended = !removing && !removeFailed && !failed && bp.suspended;

    // The header collapses to ONE pill (charter decision 6). The health / agent
    // breakdown that USED to be badge-soup now lives only in the Details rail
    // below, where an operator drills in for the specifics.
    var health = bp.health_status || "unknown";
    var agent = bp.agent_status || "offline";
    var badges = statusPill(bp);

    // isu-6: live + behind → offer the one-click update alongside Open Studio.
    var live = !removing && !removeFailed && !failed && !provisioning && !suspended && bp.host;
    var updateBtn = live && bp.update_state === "behind"
      ? '<button class="btn btn-primary btn-sm" id="inst-update" type="button">' +
          esc(bp.update_latest_release ? "Update to " + vRel(bp.update_latest_release) : "Update") + "</button>"
      : "";

    var actions =
      removing
        ? ""
        : removeFailed
          ? '<button class="btn btn-primary btn-sm" id="inst-remove-retry" type="button">Retry removal</button>'
          : failed
            ? '<button class="btn btn-primary btn-sm" id="inst-retry" type="button">Retry</button>' +
              '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>'
            : bp.host
              ? updateBtn +
                '<button class="btn btn-primary btn-sm" id="inst-open-studio" type="button">Open Studio</button>' +
                '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>'
              : "";

    var updateRail = bp.update_state === "behind"
      ? vRel(bp.update_running_release) + " → " + vRel(bp.update_latest_release) + " available"
      : bp.update_state === "current"
        ? "up to date (" + vRel(bp.update_running_release) + ")"
        : "—";

    var failBanner = removeFailed && bp.deprovision_error
      ? '<div class="notice notice-error" role="alert"><b>Removal failed.</b> ' + esc(bp.deprovision_error) + "</div>"
      : failed && bp.provision_error
        ? '<div class="notice notice-error" role="alert"><b>Provisioning failed.</b> ' + esc(bp.provision_error) + "</div>"
        : removing
          ? '<div class="notice notice-warn" role="status">Tearing down the server and stopping billing — this can take a moment.</div>'
          : suspended
            ? '<div class="notice notice-error" role="alert"><b>Suspended.</b> ' +
              esc(bp.suspended_reason || "Suspended for billing reasons") + "</div>"
            : "";

    return '<div class="detail-head"><div><h1>' + esc(bp.name) + "</h1>" + url + "</div>" +
      '<div class="fleet-badges">' + badges + (actions ? '<span class="detail-actions">' + actions + "</span>" : "") + "</div></div>" +
      failBanner +
      '<div class="detail-grid">' +
        '<div class="detail-main"><h2>Sites</h2>' +
          '<div id="instance-sites"><div class="loading">Loading sites&hellip;</div></div></div>' +
        '<aside class="detail-rail"><h2>Details</h2>' +
          railRowCopy("ID", bp.id) +
          railRowCopy("Host", bp.host || "—") +
          railRow("Mode", bp.mode || "—") +
          railRow("Health", cap(health)) +
          railRow("Agent", cap(agent)) +
          railRow("Version", bp.version ? "v" + bp.version : "—") +
          railRow("Update", updateRail) +
          railRow("Git commit", bp.git_commit ? shortSha(bp.git_commit) : "—") +
          railRow("Slug", bp.slug || "—") +
          railRowPlain("Last seen", fmtWhen(bp.last_seen_at)) +
          railRowPlain("Created", fmtWhen(bp.inserted_at)) +
        "</aside>" +
      "</div>";
  }

  function wireInstanceActions(bp) {
    var openBtn = $("#inst-open-studio");
    if (openBtn) openBtn.addEventListener("click", function () { openStudio(bp.id, openBtn); });
    var update = $("#inst-update");
    if (update) update.addEventListener("click", function () { confirmUpdateInstance(bp); });
    var retry = $("#inst-retry");
    if (retry) retry.addEventListener("click", function () { retryInstance(bp, retry); });
    var remove = $("#inst-remove");
    if (remove) remove.addEventListener("click", function () { confirmRemoveInstance(bp); });
    var removeRetry = $("#inst-remove-retry");
    if (removeRetry) removeRetry.addEventListener("click", function () { removeInstance(bp, removeRetry); });
  }

  function retryInstance(bp, btn) {
    btn.disabled = true;
    btn.textContent = "Retrying…";
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/retry", {}).then(function (r) {
      if (r.status === 201) {
        toast({ kind: "success", title: "Retrying provision", body: "Re-queued " + bp.name + "." });
        fleetCache = null;
        loadInstance(bp.id);
      } else {
        btn.disabled = false;
        btn.textContent = "Retry";
        toast({ kind: "error", title: "Couldn't retry", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  function confirmRemoveInstance(bp) {
    var live = !!bp.host;
    var sub = live
      ? "This permanently tears down the server and stops billing. It can't be undone."
      : "This removes the instance from your dashboard. It can't be undone.";
    openModal(
      '<h2 class="modal-title" id="modal-title">Remove ' + esc(bp.name) + "?</h2>" +
      '<p class="modal-sub">' + esc(sub) + "</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" type="button" id="remove-go">Remove</button></div>'
    );
    $("#remove-go").addEventListener("click", function () { removeInstance(bp); });
  }

  function removeInstance(bp, btn) {
    btn = btn || $("#remove-go");
    if (btn) { btn.disabled = true; btn.textContent = "Removing…"; }
    api("DELETE", "/v1/barkparks/" + encodeURIComponent(bp.id)).then(function (r) {
      closeModal();
      fleetCache = null;
      if (r.status === 200) {
        toast({ kind: "success", title: "Instance removed", body: bp.name + " is gone." });
        location.hash = "#fleet";
      } else if (r.status === 202) {
        toast({ kind: "success", title: "Removing " + bp.name, body: "Tearing down the server — billing stops once it's gone." });
        location.hash = "#fleet";
      } else {
        if (btn) { btn.disabled = false; btn.textContent = "Remove"; }
        toast({ kind: "error", title: "Couldn't remove", body: friendly(r.data, "Please try again.") });
      }
    });
  }
  // isu-6: confirm-then-trigger self-update, mirroring the Remove pipeline.
  // The control plane relays to the instance's POST /v1/admin/self-update.
  function confirmUpdateInstance(bp) {
    var latest = vRel(bp.update_latest_release);
    openModal(
      '<h2 class="modal-title" id="modal-title">Update ' + esc(bp.name) + "?</h2>" +
      '<p class="modal-sub">Update this instance to ' + esc(latest) + "? It will rebuild and restart.</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-primary" type="button" id="update-go">Update</button></div>'
    );
    $("#update-go").addEventListener("click", function () { updateInstance(bp); });
  }

  function updateInstance(bp, btn) {
    btn = btn || $("#update-go");
    if (btn) { btn.disabled = true; btn.textContent = "Updating…"; }
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/self-update", {}).then(function (r) {
      closeModal();
      if (r.status === 202) {
        toast({ kind: "success", title: "Update started", body: "The instance will restart." });
        fleetCache = null;
        loadInstance(bp.id);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Update"; }
      // Errors arrive as {error: {code}} — NOT the flat string friendly() reads.
      var code = r.data && r.data.error && r.data.error.code;
      if (code === "already_running") {
        toast({ kind: "info", title: "An update is already running" });
      } else if (code === "not_enabled") {
        toast({
          kind: "error",
          title: "Self-update is not enabled on this instance",
          body: "Set BARKPARK_SELF_UPDATE_APPLY=1 on the box to allow one-click updates."
        });
      } else {
        toast({ kind: "error", title: "Couldn't start the update", body: "Please try again in a moment." });
      }
    });
  }

  function railRow(k, v) { return '<div class="rail-row"><span class="k">' + esc(k) + '</span><span class="v">' + esc(v) + "</span></div>"; }
  function railRowPlain(k, v) { return '<div class="rail-row"><span class="k">' + esc(k) + '</span><span class="v plain">' + esc(v) + "</span></div>"; }
  // A rail row whose mono value carries a copy-to-clipboard button (Forge affordance).
  var COPY_SVG = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
  function railRowCopy(k, v) {
    if (!v || v === "—") return railRow(k, v || "—");
    return '<div class="rail-row"><span class="k">' + esc(k) + '</span>' +
      '<span class="v copy">' + esc(v) +
        '<button class="copy-btn" type="button" data-copy="' + esc(v) + '" aria-label="Copy ' + esc(k) + '">' + COPY_SVG + "</button>" +
      "</span></div>";
  }
  function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1); }
  // Release labels: "0.4.1" and "v0.4.1" both render as "v0.4.1" (never "vv…").
  // A missing release reads as prose, never a bare "v": a divergent instance
  // can report state "behind" without a latest_release, and a confirm dialog
  // for a restart-inducing action must never name an empty version.
  function vRel(rel) {
    if (rel == null || rel === "") return "the latest release";
    rel = String(rel);
    return rel.charAt(0) === "v" ? rel : "v" + rel;
  }
  function shortSha(s) { s = String(s); return s.length > 7 ? s.slice(0, 7) : s; }
  function fmtWhen(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    return isNaN(d.getTime()) ? "—" : d.toLocaleString();
  }

  function loadInstanceSites(bp) {
    api("GET", "/v1/sites").then(function (r) {
      var box = $("#instance-sites");
      if (!box) return;
      var all = (r.ok && r.data && r.data.sites) || [];
      var sites = all.filter(function (s) { return String(s.barkpark_id) === String(bp.id); });
      if (!sites.length) {
        box.innerHTML = '<div class="empty-state"><h2>No sites yet</h2>' +
          "<p>Sites hosted on this instance will appear here.</p></div>";
        return;
      }
      box.innerHTML = sites.map(siteRow).join("");
      wireSiteRows(box);
    });
  }
  // Wires .site-row[data-id] rows (instance detail + sites tab) to #site/<id>.
  function wireSiteRows(scope) {
    scope.querySelectorAll(".site-row[data-id]").forEach(function (row) {
      var go = function () { location.hash = "#site/" + encodeURIComponent(row.getAttribute("data-id")); };
      row.addEventListener("click", go);
      row.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); }
      });
    });
  }
  function siteRow(s) {
    var domain = (s.domains && s.domains[0]) || s.slug || s.name || "—";
    var fw = s.framework ? esc(s.framework) : "site";
    var repo = s.github_repo
      ? '<span class="mono">' + esc(s.github_repo) + (s.github_branch ? "@" + esc(s.github_branch) : "") + "</span>"
      : "not linked";
    var auto = s.github_webhook_configured;
    return '<div class="site-row" data-id="' + esc(s.id) + '" role="button" tabindex="0"><div class="site-main">' +
      '<div class="site-name">' + esc(domain) + "</div>" +
      '<div class="site-meta">' + fw + " &middot; " + repo + "</div>" +
      '</div><div class="fleet-badges">' +
        badge(auto ? "Auto-deploy" : "Manual", auto ? "online" : "unknown") +
        '<span class="fleet-chev" aria-hidden="true">&rsaquo;</span>' +
      "</div></div>";
  }

  // =========================================================== SITES (tab)
  // Every site across the fleet, each labelled with its parent instance.
  function loadSites() {
    var body = $("#sites-body");
    body.innerHTML = '<div class="loading">Loading sites&hellip;</div>';
    Promise.all([api("GET", "/v1/sites"), ensureFleet()]).then(function (res) {
      var r = res[0];
      if (!r.ok) {
        body.innerHTML = '<div class="empty-state"><h2>Couldn\'t load sites</h2><p>' +
          esc(friendly(r.data)) + "</p></div>";
        return;
      }
      var sites = (r.data && r.data.sites) || [];
      if (!sites.length) {
        body.innerHTML = '<div class="empty-state"><h2>No sites yet</h2>' +
          "<p>Sites you host on your instances will appear here.</p></div>";
        return;
      }
      var byId = {};
      (res[1] || []).forEach(function (bp) { byId[String(bp.id)] = bp; });
      body.innerHTML = sites.map(function (s) { return globalSiteRow(s, byId[String(s.barkpark_id)]); }).join("");
      wireSiteRows(body);
    });
  }

  function globalSiteRow(s, bp) {
    var domain = (s.domains && s.domains[0]) || s.slug || s.name || "—";
    var fw = s.framework ? esc(s.framework) : "site";
    var inst = bp ? esc(bp.name) : "—";
    var auto = s.github_webhook_configured;
    return '<div class="site-row" data-id="' + esc(s.id) + '" role="button" tabindex="0"><div class="site-main">' +
      '<div class="site-name">' + esc(domain) + "</div>" +
      '<div class="site-meta">' + fw + ' &middot; on <span class="site-inst">' + inst + "</span></div>" +
      '</div><div class="fleet-badges">' +
        badge(auto ? "Auto-deploy" : "Manual", auto ? "online" : "unknown") +
        '<span class="fleet-chev" aria-hidden="true">&rsaquo;</span>' +
      "</div></div>";
  }

  // =========================================================== SITE DETAIL
  var currentSiteId = null;
  // gh-5: per-deployment build-console expand/collapse state, keyed by deployment
  // id, so a user's toggle survives the full site re-render that each live
  // "deployments" SSE tick triggers. Absent → defaults to open for an ACTIVE
  // deploy (queued/building/pushing), collapsed for a terminal one.
  var deployConsoleOpen = {};

  function loadSite(id) {
    currentSiteId = id;
    var box = $("#site-body");
    box.innerHTML = '<div class="loading">Loading site&hellip;</div>';
    Promise.all([
      api("GET", "/v1/sites/" + encodeURIComponent(id)),
      api("GET", "/v1/sites/" + encodeURIComponent(id) + "/deployments"),
      ensureFleet(),
      api("GET", "/v1/sites/" + encodeURIComponent(id) + "/previews")
    ]).then(function (res) {
      // The user has since navigated to another site (or away): whichever of
      // two overlapping loads finishes last must not render the wrong site.
      if (String(currentSiteId) !== String(id)) return;
      var sr = res[0];
      if (sr.status === 404 || !sr.ok || !sr.data || !sr.data.site) {
        setBreadcrumb(null);
        box.innerHTML = '<div class="empty-state"><h2>Site not found</h2>' +
          '<p>It may have been removed. <a href="#sites">Back to sites</a>.</p></div>';
        return;
      }
      var site = sr.data.site;
      var deployments = (res[1].ok && res[1].data && res[1].data.deployments) || [];
      var previews = (res[3] && res[3].ok && res[3].data && res[3].data.previews) || [];
      var bp = (res[2] || []).filter(function (x) { return String(x.id) === String(site.barkpark_id); })[0];
      var domain = (site.domains && site.domains[0]) || site.slug || site.name || "site";
      setBreadcrumb([
        { label: "Sites", href: "#sites" },
        bp ? { label: bp.name, href: "#instance/" + encodeURIComponent(bp.id) } : null,
        { label: domain }
      ].filter(Boolean));
      box.innerHTML = siteDetailHtml(site, bp, deployments, domain, previews);
      var d = $("#site-deploy");
      if (d) d.addEventListener("click", function () { confirmDeploy(site, domain); });
      wireDeployConsoles(box);
      var g = $("#site-github");
      if (g) g.addEventListener("click", function () { openSiteGithub(site, domain); });
    });
  }

  // gh-5: wire each deployment's build-console toggle and pin open consoles to the
  // bottom (auto-scroll to the newest line). Re-run after every site render — the
  // whole list is rebuilt on each live "deployments" tick.
  function wireDeployConsoles(scope) {
    var panels = scope.querySelectorAll(".deploy-console");
    for (var i = 0; i < panels.length; i++) {
      (function (panel) {
        var id = panel.getAttribute("data-deploy-id");
        var toggle = panel.querySelector(".deploy-console-toggle");
        var body = panel.querySelector(".deploy-console-body");
        if (toggle) toggle.addEventListener("click", function () {
          var open = panel.classList.contains("is-collapsed");
          deployConsoleOpen[id] = open;
          panel.classList.toggle("is-collapsed", !open);
          toggle.setAttribute("aria-expanded", open ? "true" : "false");
          if (body) {
            if (open) { show(body); body.scrollTop = body.scrollHeight; }
            else hide(body);
          }
        });
        // Pin an open console to the newest line so a live build tails itself.
        if (body && !panel.classList.contains("is-collapsed")) body.scrollTop = body.scrollHeight;
      })(panels[i]);
    }
  }

  function siteDetailHtml(site, bp, deployments, domain, previews) {
    previews = previews || [];
    var auto = site.github_webhook_configured;
    var repo = site.github_repo
      ? '<span class="mono">' + esc(site.github_repo) + (site.github_branch ? "@" + esc(site.github_branch) : "") + "</span>"
      : "—";
    var sub = (site.framework ? esc(site.framework) : "site") +
      (bp ? ' &middot; on <a href="#instance/' + esc(bp.id) + '">' + esc(bp.name) + "</a>" : "");
    var list = deployments.length
      ? deployments.map(deployRow).join("")
      : '<div class="empty-state"><h2>No deployments yet</h2><p>Trigger the first build with Deploy.</p></div>';
    var githubLabel = auto ? "Change repo" : "Connect GitHub repo";
    // gh-6: branch previews render in their own section, distinct from the
    // production deploy list — one row per branch, each with a click-through to
    // its preview URL and its own build console (the #815 standard).
    var previewSection = previews.length
      ? '<h2 class="previews-heading">Branch previews' +
          '<span class="previews-count">' + esc(String(previews.length)) + "</span></h2>" +
        '<div class="deploys previews">' + previews.map(previewRow).join("") + "</div>"
      : "";
    var previewsFlag = site.previews_enabled === false ? "Off" : "On";
    return '<div class="detail-head"><div><h1>' + esc(domain) + "</h1>" +
        '<div class="fleet-url">' + sub + "</div></div>" +
        '<div class="fleet-badges">' +
          '<button class="btn btn-ghost btn-sm" id="site-github" type="button">' + githubLabel + "</button>" +
          '<button class="btn btn-primary btn-sm" id="site-deploy" type="button">Deploy</button></div></div>' +
      '<div class="detail-grid">' +
        '<div class="detail-main"><h2>Deployments</h2><div class="deploys">' + list + "</div>" +
          previewSection + "</div>" +
        '<aside class="detail-rail"><h2>Details</h2>' +
          railRowCopy("Site ID", site.id) +
          railRow("Framework", site.framework || "—") +
          railRowHtml("Repository", repo) +
          railRowHtml("Auto-deploy", badge(auto ? "On" : "Manual", auto ? "online" : "unknown")) +
          railRowHtml("Previews", badge(previewsFlag, previewsFlag === "On" ? "online" : "unknown")) +
          railRow("Port", site.port != null ? String(site.port) : "—") +
          railRow("Scale", site.scale_mode || "—") +
          railRowCopy("Current", site.current_deployment_id || "—") +
          railRowPlain("Created", fmtWhen(site.inserted_at)) +
        "</aside>" +
      "</div>";
  }

  // Map a raw internal builder failure_reason (from builder.go) to human copy,
  // the deploy-side twin of friendly()/ERRORS for API errors. Substring match on
  // the RAW reason; unrecognized reasons pass through verbatim (still esc'd at
  // the call site, so escaping is unchanged).
  function failureCopy(reason) {
    if (!reason) return reason;
    if (reason.indexOf("no build source") !== -1)
      return "This site has no build source yet. Connect a repo or run bp deploy.";
    if (reason.indexOf("artifact_url is empty") !== -1 ||
        reason.indexOf("unsupported artifact scheme") !== -1)
      return "The build source couldn't be fetched.";
    return reason;
  }

  // gh-6: one branch-preview row — its branch, a click-through to the preview
  // URL, status pill, and the same live build console as a production deploy.
  function previewRow(d) {
    var st = d.status || "queued";
    var branch = '<span class="mono">' + esc(d.branch || "—") + "</span>";
    var url = d.preview_url || (d.preview_host ? "https://" + d.preview_host : null);
    var link = url
      ? '<a class="preview-url mono" href="' + esc(url) + '" target="_blank" rel="noopener">' +
          esc(d.preview_host || url) + "</a>"
      : '<span class="dim">pending routing</span>';
    var when = d.became_live_at || d.updated_at || d.inserted_at;
    var fail = (st === "failed" && d.failure_reason)
      ? '<div class="deploy-fail">' + esc(failureCopy(d.failure_reason)) + "</div>" : "";
    var head = '<div class="deploy-head"><div class="deploy-main">' +
        '<div class="deploy-ref">' + branch + " &rarr; " + link + "</div>" +
        '<div class="deploy-meta">' + esc(fmtWhen(when)) + "</div>" + fail +
        deployDetailHtml(d, st) +
      "</div>" +
      '<span class="dep-pill dep-' + esc(st) + '">' + esc(cap(st)) + "</span></div>";
    return '<div class="deploy-row preview-row">' + head + deployConsoleHtml(d, deployIsActive(st)) + "</div>";
  }

  function deployIsActive(st) {
    return st === "queued" || st === "building" || st === "pushing";
  }

  // dwb-18: a deploy that's ENQUEUED but not yet CLAIMED by a builder — status
  // still "queued" and not one console line has arrived. This is a distinct,
  // honest state from "building": nothing is streaming yet, so instead of the
  // dark "Waiting for the first log line…" console (which implies an active
  // build) we show a calm muted caption and keep the console collapsed until the
  // first real log line flips the row to building. The /new path solved the same
  // silent-spinner problem with newWaitingForWorker(); this is its deploy twin.
  function deployIsPreClaim(d, st) {
    return (st || "queued") === "queued" && !(d.console && d.console.length);
  }

  // dwb-19: the LIVE sub-caption under a deployment's status pill — the build-side
  // twin of the /new step caption. Shown only while the deploy is ACTIVE (a
  // terminal row shows its failure_reason / final state instead), muted + smaller
  // with the same fade/translate on change. data-cap re-mounts on change.
  function deployDetailHtml(d, st) {
    // dwb-18: pre-claim (queued, no console) → an honest "waiting for a builder"
    // caption instead of a dark spinner console. Prefer the server's own
    // narration if it set one; an optional since-hint uses fmtWhen when present.
    if (deployIsPreClaim(d, st)) {
      var msg = d.detail || "Queued — waiting for a builder to pick this up…";
      var since = d.inserted_at ? " (since " + fmtWhen(d.inserted_at) + ")" : "";
      return '<div class="deploy-detail deploy-queued" data-cap="queued">' + esc(msg + since) + "</div>";
    }
    if (!deployIsActive(st) || !d.detail) return "";
    return '<div class="deploy-detail" data-cap="' + esc(d.detail) + '">' + esc(d.detail) + "</div>";
  }

  function deployRow(d) {
    var st = d.status || "queued";
    var ref = d.image_tag ? '<span class="mono">' + esc(shortId(d.image_tag)) + "</span>"
      : d.git_ref ? '<span class="mono">' + esc(d.git_ref) + "</span>"
      : '<span class="dim">' + esc(shortId(d.id)) + "</span>";
    var when = d.became_live_at || d.updated_at || d.inserted_at;
    var fail = (st === "failed" && d.failure_reason)
      ? '<div class="deploy-fail">' + esc(failureCopy(d.failure_reason)) + "</div>" : "";
    var head = '<div class="deploy-head"><div class="deploy-main">' +
        '<div class="deploy-ref">' + ref + "</div>" +
        '<div class="deploy-meta">' + esc(fmtWhen(when)) + "</div>" + fail +
        deployDetailHtml(d, st) +
      "</div>" +
      '<span class="dep-pill dep-' + esc(st) + '">' + esc(cap(st)) + "</span></div>";
    return '<div class="deploy-row">' + head + deployConsoleHtml(d, deployIsActive(st)) + "</div>";
  }

  // gh-5: the per-deployment build console — the deploy-side twin of the /new
  // provision console. Dark, monospace, timestamped, auto-scrolling. VISIBLE BY
  // DEFAULT for an ACTIVE deploy (that's the point — watch the build stream);
  // collapsed by default once terminal, but the lines STAY so a failed build's
  // console remains inspectable. Rendered only when there are lines or the deploy
  // is still active (no empty panel on old terminal rows).
  function deployConsoleHtml(d, active) {
    var lines = d.console || [];
    // dwb-18: a queued-but-unclaimed deploy shows no dark console at all — the
    // calm queued caption in deployDetailHtml carries the pre-claim state. Once
    // the first log line arrives (builder claimed), this renders normally.
    if (deployIsPreClaim(d, d.status || "queued")) return "";
    if (!lines.length && !active) return "";
    var open = (d.id in deployConsoleOpen) ? deployConsoleOpen[d.id] : active;
    var body = lines.length
      ? lines.map(function (e) {
          var ts = newFmtConsoleTime(e.at);
          return '<div class="deploy-console-line">' +
            (ts ? '<span class="deploy-console-ts">' + esc(ts) + "</span>" : "") +
            '<span class="deploy-console-text">' + esc(e.line) + "</span></div>";
        }).join("")
      : '<div class="deploy-console-line dim">Waiting for the first log line&hellip;</div>';
    var count = lines.length ? esc(String(lines.length)) + (lines.length === 1 ? " line" : " lines") : "";
    return '<div class="deploy-console' + (open ? "" : " is-collapsed") + '" data-deploy-id="' + esc(d.id) + '">' +
        '<button type="button" class="deploy-console-toggle" aria-expanded="' + (open ? "true" : "false") + '">' +
          '<span class="deploy-console-caret" aria-hidden="true"></span>Build console' +
          '<span class="deploy-console-count">' + count + "</span>" +
        "</button>" +
        '<div class="deploy-console-body"' + (open ? "" : " hidden") + ">" + body + "</div>" +
      "</div>";
  }

  function confirmDeploy(site, domain) {
    var note = site.github_repo
      ? "This enqueues a fresh build and rollout for this site."
      : "This site has no linked repo — it builds from an artifact uploaded via the CLI (bp deploy).";
    openModal(
      '<h2 class="modal-title" id="modal-title">Deploy ' + esc(domain) + "?</h2>" +
      '<p class="modal-sub">' + esc(note) + "</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-primary" type="button" id="deploy-go">Deploy</button></div>'
    );
    $("#deploy-go").addEventListener("click", function () { runDeploy(site.id, domain, site.github_branch); });
  }

  function runDeploy(id, domain, gitRef) {
    var btn = $("#deploy-go");
    btn.disabled = true;
    btn.textContent = "Deploying…";
    api("POST", "/v1/sites/" + encodeURIComponent(id) + "/deploy", gitRef ? { git_ref: gitRef } : {}).then(function (r) {
      closeModal();
      if (r.status === 201) {
        toast({ kind: "success", title: "Deploy started", body: "Building " + domain + "." });
        if (String(currentSiteId) === String(id)) loadSite(id);
      } else {
        toast({ kind: "error", title: "Couldn't start deploy", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // The Vercel "Import Git Repository" moment (gh-4): pick a repo from the team's
  // GitHub App installation and link it to this site. The push webhook is
  // auto-registered on GitHub server-side — the user never touches a secret.
  function openSiteGithub(site, domain) {
    openModal(
      '<h2 class="modal-title" id="modal-title">GitHub repository</h2>' +
      '<p class="modal-sub">Loading your repositories&hellip;</p>' +
      '<div id="github-connect-body"><div class="loading">Loading&hellip;</div></div>'
    );

    api("GET", "/v1/github/repos").then(function (r) {
      var host = $("#github-connect-body");
      if (!host) return;

      if (r.status === 503) {
        host.innerHTML = '<div class="empty-state"><p>GitHub isn\'t configured on this deployment yet.</p></div>' +
          modalCloseRow();
        wireGithubCancel();
        return;
      }
      if (r.status === 409 || (r.data && r.data.error === "no_installation")) {
        host.innerHTML = '<div class="empty-state"><p>Connect your GitHub account first, then pick a repository here.</p></div>' +
          '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
            '<a class="btn btn-primary" href="#providers" data-close>Connect GitHub</a></div>';
        wireGithubCancel();
        return;
      }
      if (!r.ok || !r.data || !r.data.repos) {
        host.innerHTML = '<div class="empty-state"><p>' + esc(friendly(r.data, "Couldn't load your repositories.")) + "</p></div>" +
          modalCloseRow();
        wireGithubCancel();
        return;
      }

      var repos = r.data.repos;
      if (!repos.length) {
        host.innerHTML = '<div class="empty-state"><p>Your GitHub App installation can\'t see any repositories.</p></div>' +
          modalCloseRow();
        wireGithubCancel();
        return;
      }

      var opts = repos.map(function (repo) {
        var sel = repo.full_name === site.github_repo ? " selected" : "";
        return '<option value="' + esc(repo.full_name) + '"' + sel + ">" + esc(repo.full_name) +
          (repo.private ? " (private)" : "") + "</option>";
      }).join("");
      var branch = site.github_branch || "main";

      host.innerHTML =
        '<div class="field"><label class="label" for="github-repo">Repository</label>' +
          '<select id="github-repo" class="form-input">' + opts + "</select></div>" +
        '<div class="field"><label class="label" for="github-branch">Production branch</label>' +
          '<input class="form-input" id="github-branch" type="text" value="' + esc(branch) + '" /></div>' +
        '<p class="modal-sub">Pushes to this branch will build and deploy automatically.</p>' +
        '<div class="modal-actions">' +
          (site.github_webhook_configured
            ? '<button class="btn btn-danger" type="button" id="github-disconnect-site">Disconnect</button>'
            : '<button class="btn" type="button" data-close>Cancel</button>') +
          '<button class="btn btn-primary" type="button" id="github-connect-go">' +
            (site.github_webhook_configured ? "Update" : "Connect") + "</button></div>";

      $("#github-connect-go").addEventListener("click", function () { submitSiteGithub(site, domain); });
      var dis = $("#github-disconnect-site");
      if (dis) dis.addEventListener("click", function () { disconnectSiteGithub(site, domain); });
    });
  }

  function modalCloseRow() {
    return '<div class="modal-actions"><button class="btn" type="button" data-close>Close</button></div>';
  }
  function wireGithubCancel() {
    document.querySelectorAll("#modal [data-close]").forEach(function (b) {
      b.addEventListener("click", closeModal);
    });
  }

  function submitSiteGithub(site, domain) {
    var repo = $("#github-repo").value;
    var branch = ($("#github-branch").value || "main").trim() || "main";
    var btn = $("#github-connect-go");
    btn.disabled = true;
    btn.textContent = "Connecting…";
    api("POST", "/v1/sites/" + encodeURIComponent(site.id) + "/github/connect",
      { repo_full_name: repo, branch: branch }).then(function (r) {
      closeModal();
      if (r.status === 200) {
        toast({ kind: "success", title: "Repository connected", body: repo + "@" + branch + " will auto-deploy." });
        if (String(currentSiteId) === String(site.id)) loadSite(site.id);
      } else {
        toast({ kind: "error", title: "Couldn't connect repository", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  function disconnectSiteGithub(site, domain) {
    var btn = $("#github-disconnect-site");
    btn.disabled = true;
    btn.textContent = "Disconnecting…";
    api("DELETE", "/v1/sites/" + encodeURIComponent(site.id) + "/github").then(function (r) {
      closeModal();
      if (r.status === 200) {
        toast({ kind: "success", title: "Repository disconnected", body: "Pushes to " + domain + " will no longer deploy." });
        if (String(currentSiteId) === String(site.id)) loadSite(site.id);
      } else {
        toast({ kind: "error", title: "Couldn't disconnect", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  function railRowHtml(k, htmlV) { return '<div class="rail-row"><span class="k">' + esc(k) + '</span><span class="v">' + htmlV + "</span></div>"; }
  function shortId(s) { s = String(s || ""); return s.length > 12 ? s.slice(0, 12) : s; }

  function startStep(n, title, sub, view, cta) {
    return '<div class="start-step"><span class="start-num">' + n + "</span>" +
      '<span class="start-main"><span class="start-title">' + esc(title) + "</span>" +
      '<span class="start-sub">' + esc(sub) + "</span></span>" +
      '<button class="btn btn-sm" data-goto="' + esc(view) + '">' + esc(cta) + " &rsaquo;</button></div>";
  }
  function wireStartSteps() {
    // The onboarding card renders on both the empty Fleet and the empty Overview.
    document.querySelectorAll("#fleet-body [data-goto], #overview-body [data-goto]").forEach(function (b) {
      b.addEventListener("click", function () { location.hash = "#" + b.getAttribute("data-goto"); });
    });
  }

  // =========================================================== LAUNCH
  // Does this subscription entitle the team to launch? Mirrors the server's
  // Billing.entitled?/1 (billing.ex) case-for-case:
  //   * admin "forever" comp  → always entitled;
  //   * self-serve "trial"    → only while unexpired (current_period_end in the
  //                             future; an unset/expired trial is NOT entitled);
  //   * status "active"       → entitled (a "free" row is signed-up-not-paying,
  //                             so it stays gated);
  //   * status "past_due"     → STILL entitled inside its dunning grace window
  //                             (current_period_end in the future, or unset), so
  //                             a paying customer whose card just failed is not
  //                             locked out mid-grace;
  //   * anything else (no sub / expired trial / past-grace) → not entitled.
  function launchEntitled(s) {
    if (!s) return false;
    if (s.plan === "forever") return true;
    if (s.plan === "trial") {
      return !!s.current_period_end && new Date(s.current_period_end) > new Date();
    }
    if (s.status === "active") return s.plan !== "free";
    if (s.status === "past_due") {
      return !s.current_period_end || new Date(s.current_period_end) > new Date();
    }
    return false;
  }

  // Gate the Launch form on a real subscription so the user learns the actual
  // next step (subscribe) BEFORE filling in a name and hitting a 402. The notice
  // is injected ahead of the form; the submit is disabled until a plan is active.
  function renderLaunchGate() {
    var card = document.querySelector("#view-launch .form-card");
    var submit = $("#launch-submit");
    if (!card) return;

    function paint() {
      var existing = $("#launch-gate");
      // Couldn't verify entitlement and have no cached answer: keep the submit
      // disabled (a 402 is worse than a retry) but don't ASSERT "subscription
      // required" — that mislabels a paying customer whose fetch just blipped.
      if (subError && !subLoaded) {
        if (existing) existing.parentNode.removeChild(existing);
        var e = document.createElement("div");
        e.id = "launch-gate";
        e.className = "notice notice-warn";
        e.innerHTML =
          "<b>Couldn't verify your subscription.</b> " +
          "Check your connection and retry. " +
          '<button class="btn btn-sm" id="launch-gate-retry" type="button">Retry</button>';
        card.insertBefore(e, card.firstChild);
        var gr = $("#launch-gate-retry");
        if (gr) gr.addEventListener("click", function () {
          subError = false;
          loadSubscription().then(paint);
        });
        if (submit) submit.disabled = true;
        return;
      }
      var active = launchEntitled(subCache);
      if (active) {
        if (existing) existing.parentNode.removeChild(existing);
        if (submit) submit.disabled = false;
        return;
      }
      if (!existing) {
        var n = document.createElement("div");
        n.id = "launch-gate";
        n.className = "notice notice-warn";
        n.innerHTML =
          "<b>A subscription is required to launch.</b> " +
          'Pick a plan first — <a href="#billing">go to Billing</a>.';
        card.insertBefore(n, card.firstChild);
      }
      if (submit) submit.disabled = true;
    }

    if (!subLoaded && !subError) loadSubscription().then(paint);
    else paint();
  }

  function submitLaunch(e) {
    e.preventDefault();
    var name = $("#launch-name").value.trim();
    if (!name) { toast({ kind: "error", title: "A name is required." }); return; }

    var btn = $("#launch-submit");
    btn.disabled = true;
    api("POST", "/v1/launch", { name: name }).then(function (r) {
      btn.disabled = false;
      if (r.status === 201) {
        $("#launch-name").value = "";
        fleetCache = null; // force a refetch so the new instance shows
        toast({ kind: "success", title: "Launching " + name, body: "Provisioning a fresh instance." });
        location.hash = "#fleet";
        render(); // re-renders shell, lands on fleet (loadFleet shows the new row)
      } else if (r.status === 402) {
        toast({
          kind: "error",
          title: "Subscription required",
          body: "You need an active subscription before launching.",
          action: { label: "Go to Billing", onClick: function () { location.hash = "#billing"; } }
        });
      } else {
        toast({ kind: "error", title: "Couldn't launch", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // =========================================================== BILLING
  var TIERS = [
    { plan: "free", name: "Free", price: "$0", per: "", note: "Get started. No card required.", free: true },
    { plan: "supporter", name: "Supporter", price: "$69", per: "/mo", note: "Managed hosting for your instance." },
    { plan: "support_plus", name: "Support++", price: "$499", per: "/mo", note: "Priority support and more capacity." }
  ];

  var RECOMMENDED = "supporter";
  var PLAN_FEATURES = [
    "Unlimited managed instances",
    "Automated provisioning & updates",
    "Daily backups",
    "Custom domains with automatic TLS",
    "Standard support"
  ];

  function priceFor(plan) {
    var t = TIERS.filter(function (x) { return x.plan === plan; })[0];
    return t ? t.price : "—";
  }

  // The active plan, per the server (free counts as "no paid subscription").
  function activePlan() { return subCache && subCache.status === "active" ? subCache.plan : "free"; }

  function renderRecommended() {
    var box = $("#billing-recommended");
    if (!box) return;

    // Always read the real subscription before deciding what to show — the plan
    // state is the server's truth, never assumed.
    if (!subLoaded && !subError) {
      box.innerHTML = '<div class="loading">Loading your plan&hellip;</div>';
      loadSubscription().then(renderRecommended);
      return;
    }

    // A transient fetch failure with nothing cached yet: offer a retry, NEVER
    // the free-plan upsell — that would hide a paying customer's real plan and
    // (via the launch gate) block them. `subLoaded` true means we still have the
    // server's last real answer, so we fall through and render it below.
    if (subError && !subLoaded) {
      box.innerHTML =
        '<div class="empty-state"><h2>Couldn\'t load your plan</h2>' +
          "<p>Check your connection and retry.</p>" +
          '<p><button class="btn btn-primary btn-sm" id="sub-retry" type="button">Retry</button></p></div>';
      var rb = $("#sub-retry");
      if (rb) rb.addEventListener("click", function () {
        subError = false;
        renderRecommended();
      });
      return;
    }

    // dwb-13: a team on its free trial gets a days-remaining badge + a
    // one-click upgrade CTA, ahead of the paid-plan state below.
    if (subCache && subCache.plan === "trial") {
      renderTrial(box);
      return;
    }

    // An active paid plan OR a past_due one still in dunning both show the
    // current-plan card (the card surfaces the dunning label + grace date) —
    // a past_due paying customer must not fall through to the upsell.
    if (subCache && (subCache.status === "active" || subCache.status === "past_due") &&
        subCache.plan !== "free") {
      renderCurrentPlan(box);
      return;
    }

    // No active paid subscription → the upsell card.
    var t = TIERS.filter(function (x) { return x.plan === RECOMMENDED; })[0];
    box.innerHTML =
      '<div class="card plan-card">' +
        '<div class="plan-head"><span class="plan-name">' + esc(t.name) + "</span>" +
          '<span class="plan-rec">Recommended</span></div>' +
        '<p class="plan-tagline">Optimized for shipping to production.</p>' +
        '<div class="plan-price">' + t.price + "<small>" + (t.per || "") + "</small></div>" +
        '<ul class="plan-feats">' +
          PLAN_FEATURES.map(function (f) { return '<li><span class="ck">✓</span>' + esc(f) + "</li>"; }).join("") +
        "</ul>" +
        '<button class="btn btn-primary btn-block" id="plan-continue">Continue</button>' +
        '<a class="plan-more" id="plan-more">See more plan options</a>' +
      "</div>";
    var grid = $("#billing-tiers");
    if (grid) grid.hidden = true;
    $("#plan-continue").addEventListener("click", function () { subscribe(RECOMMENDED, $("#plan-continue")); });
    $("#plan-more").addEventListener("click", function () {
      var nowHidden = !grid.hidden;
      grid.hidden = nowHidden;
      setText($("#plan-more"), nowHidden ? "See more plan options" : "Hide plan options");
      if (!nowHidden) renderTiers();
    });
  }

  // Human billing-status label — NEVER the raw enum ("past_due" → "Past_due").
  // A pending grace cancel outranks the bare "active" it rides on.
  function billingStatusLabel(sub) {
    if (sub.status === "past_due") return "Payment past due";
    if (sub.status === "canceled") return "Canceled";
    if (sub.cancel_at_period_end) return "Cancels at period end";
    return cap(sub.status || "active");
  }

  // The short pill in the plan-card header — a compact echo of the status.
  function billingStatusBadge(sub) {
    if (sub.status === "past_due") return "Past due";
    if (sub.status === "canceled") return "Canceled";
    if (sub.cancel_at_period_end) return "Ending";
    return "Active";
  }

  // The renewal / cancel / end date line the server now feeds us
  // (current_period_end, cancel_at_period_end, canceled_at). "" when there's no
  // dated milestone to show.
  function billingPeriodLine(sub) {
    if (sub.status === "canceled") {
      return sub.canceled_at ? "Ended " + fmtWhen(sub.canceled_at) : "";
    }
    if (sub.cancel_at_period_end && sub.current_period_end) {
      return "Access until " + fmtWhen(sub.current_period_end);
    }
    if (sub.status === "past_due" && sub.current_period_end) {
      return "Grace period ends " + fmtWhen(sub.current_period_end);
    }
    if (sub.current_period_end) {
      return "Renews " + fmtWhen(sub.current_period_end);
    }
    return "";
  }

  // The active-subscriber state: their real plan, status, start date and the
  // renewal / dunning / cancel detail the server sends. There's no self-serve
  // change/cancel yet (no billing portal) — so we say so honestly rather than
  // render a button that does nothing.
  function renderCurrentPlan(box) {
    var sub = subCache;
    var periodLine = billingPeriodLine(sub);
    // Past-due gets a prominent dunning notice: their card failed and there's no
    // self-serve portal, so point them at support before the grace elapses.
    var dunning = sub.status === "past_due"
      ? '<div class="notice notice-warn">' +
          "<b>Your last payment failed.</b> " +
          "Update your payment method (contact support) to avoid interruption." +
        "</div>"
      : "";
    box.innerHTML =
      '<div class="card plan-card">' +
        '<div class="plan-head"><span class="plan-name">' + esc(planName(sub.plan)) + "</span>" +
          '<span class="plan-rec">' + esc(billingStatusBadge(sub)) + "</span></div>" +
        '<p class="plan-tagline">Your current subscription.</p>' +
        '<div class="plan-price">' + esc(priceFor(sub.plan)) + "<small>/mo</small></div>" +
        dunning +
        '<ul class="plan-feats">' +
          PLAN_FEATURES.map(function (f) { return '<li><span class="ck">✓</span>' + esc(f) + "</li>"; }).join("") +
        "</ul>" +
        '<p class="plan-meta dim">Status: ' + esc(billingStatusLabel(sub)) +
          (sub.started_at ? " &middot; since " + esc(fmtWhen(sub.started_at)) : "") + "</p>" +
        (periodLine ? '<p class="plan-meta dim">' + esc(periodLine) + "</p>" : "") +
        '<p class="plan-meta dim">To change or cancel your plan, contact support.</p>' +
        '<a class="plan-more" id="plan-more">See all plans</a>' +
      "</div>";
    var grid = $("#billing-tiers");
    if (grid) grid.hidden = true;
    $("#plan-more").addEventListener("click", function () {
      var nowHidden = !grid.hidden;
      grid.hidden = nowHidden;
      setText($("#plan-more"), nowHidden ? "See all plans" : "Hide plans");
      if (!nowHidden) renderTiers();
    });
  }

  // dwb-13: the free-trial state — a days-remaining badge + a one-click upgrade
  // CTA. Reuses the checkout flow (subscribe → POST /v1/billing/checkout); the
  // exact days come from the server (subCache.trial_days_remaining).
  function renderTrial(box) {
    var sub = subCache;
    var days = typeof sub.trial_days_remaining === "number" ? sub.trial_days_remaining : null;
    var badge =
      days === null
        ? "Free trial"
        : days <= 0
        ? "Trial ended"
        : days + (days === 1 ? " day left" : " days left");
    var t = TIERS.filter(function (x) { return x.plan === RECOMMENDED; })[0];
    box.innerHTML =
      '<div class="card plan-card">' +
        '<div class="plan-head"><span class="plan-name">Free trial</span>' +
          '<span class="plan-rec">' + esc(badge) + "</span></div>" +
        '<p class="plan-tagline">A real dedicated instance, free. Upgrade any time to keep it running — ' +
          "your trial instance is torn down automatically when the trial ends.</p>" +
        '<div class="plan-price">' + esc(t.price) + "<small>" + (t.per || "") + "</small></div>" +
        '<ul class="plan-feats">' +
          PLAN_FEATURES.map(function (f) { return '<li><span class="ck">✓</span>' + esc(f) + "</li>"; }).join("") +
        "</ul>" +
        '<button class="btn btn-primary btn-block" id="trial-upgrade">Upgrade now</button>' +
        '<a class="plan-more" id="plan-more">See all plans</a>' +
      "</div>";
    var grid = $("#billing-tiers");
    if (grid) grid.hidden = true;
    $("#trial-upgrade").addEventListener("click", function () { subscribe(RECOMMENDED, $("#trial-upgrade")); });
    $("#plan-more").addEventListener("click", function () {
      var nowHidden = !grid.hidden;
      grid.hidden = nowHidden;
      setText($("#plan-more"), nowHidden ? "See all plans" : "Hide plans");
      if (!nowHidden) renderTiers();
    });
  }

  function renderTiers() {
    var grid = $("#billing-tiers");
    var active = activePlan();
    // A `trial` team has NOT paid — the paid tiers must stay subscribable so it
    // can upgrade (dwb-13); only a real paid plan disables the others.
    var subscribed = active !== "free" && active !== "trial";
    grid.innerHTML = TIERS.map(function (t) {
      var isCurrent = t.plan === active;
      var btn;
      if (isCurrent) {
        btn = '<button class="btn" disabled>Current plan</button>';
      } else if (subscribed) {
        // Already on a paid plan — switching needs support (no proration/portal).
        btn = '<button class="btn" disabled title="Contact support to change plans">Unavailable</button>';
      } else {
        btn = '<button class="btn btn-primary" data-plan="' + esc(t.plan) + '">Subscribe</button>';
      }
      return '<div class="tier' + (isCurrent ? " tier-current" : "") + (t.free ? " tier-free" : "") + '">' +
        '<div class="tier-name">' + esc(t.name) + "</div>" +
        '<div class="tier-price">' + t.price + "<small>" + t.per + "</small></div>" +
        '<p class="tier-note">' + esc(t.note) + "</p>" +
        btn +
      "</div>";
    }).join("");

    grid.querySelectorAll("[data-plan]").forEach(function (b) {
      b.addEventListener("click", function () { subscribe(b.getAttribute("data-plan"), b); });
    });
  }

  function subscribe(plan, btn) {
    btn.disabled = true;
    var prev = btn.textContent;
    btn.textContent = "Opening checkout…";
    api("POST", "/v1/billing/checkout", { plan: plan }).then(function (r) {
      if (r.status === 200 && r.data && r.data.checkout_url) {
        window.location = r.data.checkout_url;
      } else {
        btn.disabled = false;
        btn.textContent = prev;
        toast({ kind: "error", title: "Couldn't open checkout", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // Provider connect lives in the modal flow above (openProviderPicker →
  // openProviderCredential → submitProviderCred).

  // =========================================================== ACCOUNT (/v1/me)
  // Real team name + account email for the topbar chip — replaces the opaque
  // "Team a1b2c3d4" id-slice. Cached for the session; refetched on login.
  var meCache = null;

  function setAccountChip(team, email) {
    var name = (team && team.name) || (email ? email.split("@")[0] : null) || "My team";
    setText($("#account-team"), name);
    setText($("#account-avatar"), (name[0] || "B").toUpperCase());
  }

  function loadMe() {
    setAccountChip(null, null); // immediate placeholder
    api("GET", "/v1/me").then(function (r) {
      if (r.ok && r.data) {
        meCache = r.data;
        setAccountChip(r.data.team, r.data.user && r.data.user.email);
      }
    });
  }

  // =========================================================== SUBSCRIPTION
  // The team's current plan, read from the server (never assumed). null = no
  // active subscription. Cached so the Launch/Billing views can gate without a
  // refetch; refreshed on a "subscription" live event and on billing renders.
  var subCache = null;
  var subLoaded = false;
  // A transient GET /v1/subscription failure (network / 5xx) is NOT the same as
  // "no plan". `subLoaded` means we have the server's real answer at least once;
  // `subError` flags the last fetch failed so a paying customer isn't downgraded
  // to the free-plan upsell / launch gate on a blip. Mirrors ensureFleet, which
  // only caches on success.
  var subError = false;

  function loadSubscription() {
    return api("GET", "/v1/subscription").then(function (r) {
      if (r.ok) {
        subLoaded = true;
        subError = false;
        subCache = (r.data && r.data.subscription) || null;
      } else {
        // Keep the prior cache untouched; surface a retry instead of a
        // free-looking null. `subLoaded` stays as-is (false on a cold first
        // load → the UI shows a retry, not the upsell).
        subError = true;
      }
      return subCache;
    });
  }

  function planName(plan) {
    var t = TIERS.filter(function (x) { return x.plan === plan; })[0];
    return t ? t.name : (plan || "—");
  }

  // =========================================================== ACTIVITY (audit)
  // The team's append-only audit trail. GET /v1/audit returns newest-first,
  // keyset-paginated rows; "Load more" walks back with ?before=<oldest
  // inserted_at>. A live "audit" SSE event reloads the first page. This is the
  // read surface both server-side audit stores (agent_events,
  // plugin_settings_audit) lack — here it has a UI.
  var ACTIVITY_PAGE = 50;

  // Map the closed dotted action vocabulary to a human sentence fragment. An
  // unknown action (a newly-added verb the SPA hasn't learned) falls back to the
  // raw action so it still renders rather than disappearing.
  var ACTION_LABELS = {
    "member.invited": "invited a member",
    "member.role_changed": "changed a member's role",
    "member.removed": "removed a member",
    "invitation.revoked": "revoked an invitation",
    "invitation.accepted": "accepted an invitation",
    "subscription.activated": "activated a subscription",
    "subscription.canceled": "canceled a subscription",
    "token.minted": "minted an API token",
    "token.revoked": "revoked an API token",
    "site.created": "created a site",
    "site.deleted": "deleted a site",
    "barkpark.go_live": "launched a Barkpark",
    "barkpark.deleted": "removed a Barkpark"
  };

  function humanAction(a) { return ACTION_LABELS[a] || a; }

  function activityRow(e) {
    var who = (e.actor && e.actor.email) || "system";
    var when = e.inserted_at ? new Date(e.inserted_at).toLocaleString() : "";
    var meta = e.metadata && e.metadata.name ? " &middot; " + esc(String(e.metadata.name)) : "";
    var target = e.target_type ? '<span class="badge"><span class="dot unknown"></span>' + esc(e.target_type) + "</span>" : "";
    return '<div class="fleet-row activity-row">' +
      '<div class="fleet-main">' +
        '<div class="fleet-name">' + esc(who) + " " + esc(humanAction(e.action)) + meta + "</div>" +
        '<div class="fleet-url dim">' + esc(when) + "</div>" +
      "</div>" +
      '<div class="fleet-badges">' + target + "</div>" +
    "</div>";
  }

  function loadActivity() {
    var body = $("#activity-body");
    body.innerHTML = '<div class="loading">Loading activity&hellip;</div>';
    api("GET", "/v1/audit?limit=" + ACTIVITY_PAGE).then(function (r) {
      if (!r.ok) {
        body.innerHTML = '<div class="empty-state"><h2>Couldn\'t load activity</h2><p>' +
          esc(friendly(r.data)) + "</p></div>";
        return;
      }
      var list = (r.data && r.data.events) || [];
      if (!list.length) {
        body.innerHTML = '<div class="empty-state"><h2>No activity yet</h2>' +
          "<p>Launches, removals, site changes, and subscription updates show up here.</p></div>";
        toggleActivityMore(false);
        return;
      }
      body.innerHTML = list.map(activityRow).join("");
      toggleActivityMore(list.length === ACTIVITY_PAGE, list);
    });
  }

  function loadMoreActivity() {
    var rows = activityCursorRows;
    if (!rows || !rows.length) return;
    var before = rows[rows.length - 1].inserted_at;
    var btn = $("#activity-load-more");
    btn.disabled = true;
    api("GET", "/v1/audit?limit=" + ACTIVITY_PAGE + "&before=" + encodeURIComponent(before)).then(function (r) {
      btn.disabled = false;
      if (!r.ok) {
        toast({ kind: "error", title: "Couldn't load more", body: friendly(r.data, "Please try again.") });
        return;
      }
      var more = (r.data && r.data.events) || [];
      if (more.length) {
        $("#activity-body").insertAdjacentHTML("beforeend", more.map(activityRow).join(""));
      }
      toggleActivityMore(more.length === ACTIVITY_PAGE, (activityCursorRows || []).concat(more));
    });
  }

  // Tracks the rows currently displayed so "Load more" knows the keyset cursor
  // (the oldest visible inserted_at).
  var activityCursorRows = null;
  function toggleActivityMore(show, rows) {
    if (rows) activityCursorRows = rows;
    var wrap = $("#activity-more");
    if (wrap) wrap.hidden = !show;
  }

  // =========================================================== LIVE EVENTS (SSE)
  // One EventSource per session streams coarse {type} invalidations from the
  // control plane; on each we refetch the AFFECTED collection if its view is on
  // screen (the event is a signal to refetch, never trusted as state). Token
  // rides as a query param because EventSource can't set an Authorization
  // header. EventSource auto-reconnects on drop; we only close it on logout.
  var evtSource = null;
  // Tracks whether the stream is currently in the dropped state, so a single
  // disconnect toasts exactly ONCE (not on every retry) and a reconnect can
  // confirm recovery.
  var evtErrored = false;

  function connectEvents() {
    var s = session();
    if (!s || !s.token || evtSource) return;
    try {
      evtSource = new EventSource("/v1/events?token=" + encodeURIComponent(s.token));
    } catch (e) { return; }
    evtSource.onopen = function () {
      // First connect (or a recovery after a drop). Only announce a RECONNECT —
      // the initial connect is silent.
      if (evtErrored) {
        evtErrored = false;
        toast({ kind: "success", title: "Live updates reconnected", duration: 2500 });
      }
    };
    evtSource.onmessage = function (e) {
      var ev;
      try { ev = JSON.parse(e.data); } catch (x) { return; }
      handleLiveEvent(ev && ev.type);
    };
    evtSource.onerror = function () {
      // EventSource auto-reconnects on a dropped connection; surface it ONCE so
      // the user knows live updates paused and are retrying (a stale dashboard
      // otherwise looks fine but silently stops updating). A revoked-token 401
      // also lands here repeatedly — the guard keeps it to a single toast; the
      // next authed XHR 401 logs the user out cleanly.
      if (!evtErrored) {
        evtErrored = true;
        toast({ kind: "info", title: "Live updates interrupted", body: "Reconnecting…", duration: 5000 });
      }
    };
  }

  function closeEvents() {
    if (evtSource) { try { evtSource.close(); } catch (e) {} evtSource = null; }
    evtErrored = false;
  }

  function currentView() { return parseHash().view; }

  // The instance list changed (or an instance's state did): drop the cache and
  // refetch whichever fleet-backed view is on screen.
  function invalidateFleet(v) {
    fleetCache = null; // any cached fleet is now stale
    if (v === "overview") loadOverview();
    else if (v === "fleet") loadFleet(parseHash().filter || null);
    else if (v === "instance") loadInstance(parseHash().id);
  }

  // Registered so the vocabulary stays closed; handled conservatively (same
  // as the unknown-type fallback): don't let a cached fleet outlive the event.
  // Per type, DELIBERATELY no view refetch:
  //   members       — no members panel exists yet (charter wave 3).
  //   onboarding    — no onboarding UI consumes the tick yet.
  //   notifications — a Notifications view EXISTS, but it is a settings form:
  //     a live loadNotifications() would clobber in-progress edits and stomp
  //     the "Saved." status (the saving tab receives its own broadcast).
  function invalidateConservatively() {
    fleetCache = null;
  }

  // The CLOSED event-type vocabulary: one invalidation action per registered
  // type, keyed exactly by the strings the control plane broadcasts. The same
  // list lives in lib/barkpark_cloud/events.ex (@event_types) and in
  // __fixtures__/event_types.json — the Elixir contract test and the node
  // harness both assert against that fixture, so a type added on one side
  // without the other reds a gate instead of silently going stale. Each action
  // receives the current view and refetches the affected collection if it is
  // on screen (the event is a signal to refetch, never trusted as state).
  var TYPE_ACTIONS = {
    fleet: invalidateFleet,
    subscription: function (v) {
      loadSubscription().then(function () {
        if (v === "billing") renderRecommended();
        // The launch gate also reads subCache — if the user is sitting on the
        // launch view when their subscription activates, drop the gate live
        // instead of leaving a stale "subscription required" notice.
        if (v === "launch") renderLaunchGate();
      });
    },
    sites: function (v) {
      if (v === "sites") loadSites();
      else if (v === "instance") loadInstance(parseHash().id);
    },
    deployments: function (v) {
      if (v === "site") loadSite(parseHash().id);
    },
    audit: function (v) {
      // An audited mutation (delete / go-live / site create / member / token /
      // subscription) just landed an event; refresh Activity if it's open.
      if (v === "activity") loadActivity();
    },
    github: function (v) {
      // gh-2: a GitHub connect/disconnect landed (possibly in another tab) —
      // refresh the card if the Providers view is open.
      if (v === "providers") loadGithub();
    },
    // billing.ex broadcasts these on suspend/restore — an instance's state
    // changed; mirror "fleet".
    "barkpark.suspended": invalidateFleet,
    "barkpark.restored": invalidateFleet,
    members: invalidateConservatively,
    notifications: invalidateConservatively,
    onboarding: invalidateConservatively,
  };

  function handleLiveEvent(type) {
    if (!type) return;
    // dwb-6: during the /new deploy flow a "fleet" tick means the provision state
    // may have advanced — re-check the launched instance's real status.
    if (type === "fleet" && isNewFlow() && newFlowFleetHook) { newFlowFleetHook(); return; }
    var action = TYPE_ACTIONS[type];
    if (action) { action(currentView()); return; }
    // Version-skew safety nets (an already-loaded SPA under a newer control
    // plane mid-deploy). An unregistered barkpark.* event still means an
    // instance's state changed; any other unknown type must not silently no-op
    // into a stale dashboard — at minimum, don't let a cached fleet outlive it.
    if (type.indexOf("barkpark.") === 0) { invalidateFleet(currentView()); return; }
    fleetCache = null;
  }

  // =========================================================== CHECKOUT RETURN
  // Stripe's hosted Checkout redirects to the SPA root with a ?checkout=
  // success|cancel flag (#282). Detect it on boot, show the right state, and
  // clean the URL so a refresh doesn't replay it. On success we refetch the
  // subscription (the webhook activates it server-side; an SSE "subscription"
  // event also lands it) — retrying briefly to cover webhook lag.
  function checkoutFlag() {
    var m = (location.search || "").match(/[?&]checkout=(success|cancel)\b/);
    return m ? m[1] : null;
  }
  function handleCheckoutReturn() {
    var flag = checkoutFlag();
    if (flag === "success") {
      history.replaceState(null, "", "/#billing");
      pollSubscriptionActive(0);
      return true;
    }
    if (flag === "cancel") {
      history.replaceState(null, "", "/#billing");
      toast({ kind: "info", title: "Checkout canceled", body: "No charge was made. You can pick a plan anytime." });
      return true;
    }
    return false;
  }

  function pollSubscriptionActive(attempt) {
    loadSubscription().then(function (sub) {
      if (sub && sub.status === "active") {
        toast({ kind: "success", title: "Subscription active", body: planName(sub.plan) + " is live — you can launch now." });
        if (currentView() === "billing") renderRecommended();
      } else if (attempt < 6) {
        // Webhook may lag a few seconds; retry, then give up gracefully (SSE
        // will still flip it when the webhook lands).
        setTimeout(function () { pollSubscriptionActive(attempt + 1); }, 1500);
      } else {
        toast({ kind: "info", title: "Finalizing your subscription", body: "This can take a moment — it'll update automatically." });
      }
    });
  }

  // =========================================================== OAUTH (SSO)
  // The cookieless token handoff: the OAuth callback 302s to /#oauth=<token>&team=<id>
  // (fragment, never the query, so it stays out of access logs). On boot we read
  // it, store the session exactly like a password login, and clean the hash.
  // /#oauth_error=<reason> surfaces a generic toast. Returns true when a token
  // was consumed (so render() proceeds as logged-in).
  function handleOAuthReturn() {
    var h = (location.hash || "").replace(/^#/, "");
    if (h.indexOf("oauth=") === -1 && h.indexOf("oauth_error=") === -1) return false;

    var params = {};
    h.split("&").forEach(function (kv) {
      var i = kv.indexOf("=");
      if (i === -1) return;
      params[safeDecode(kv.slice(0, i))] = safeDecode(kv.slice(i + 1));
    });

    if (params.oauth) {
      // OAuth sign-ins persist (there is no "remember me" checkbox in this flow).
      setSession({ token: params.oauth, team_id: params.team || null }, true);
      location.hash = "#fleet";
      return true;
    }
    if (params.oauth_error) {
      location.hash = "";
      toast({ kind: "error", title: "Sign-in failed", body: "We couldn't complete that sign-in. Please try again." });
    }
    return false;
  }

  function providerLabel(p) {
    if (p === "github") return "GitHub";
    if (p === "google") return "Google";
    return p.charAt(0).toUpperCase() + p.slice(1);
  }

  // Render one "Continue with <provider>" button per ENABLED provider, fetched
  // from the API so a provider with no creds never appears. Each button is a
  // TOP-LEVEL navigation (not fetch) — the route 302s cross-origin to the IdP,
  // which fetch can't follow.
  function renderOAuthButtons() {
    var container = $("#oauth-buttons");
    var divider = $("#oauth-divider");
    if (!container) return;

    api("GET", "/v1/auth/oauth/providers", null, { noAuth: true }).then(function (r) {
      var providers = (r.ok && r.data && r.data.providers) || [];
      if (!providers.length) {
        hide(container);
        hide(divider);
        return;
      }
      container.innerHTML = providers.map(function (p) {
        return '<button type="button" class="btn btn-block btn-oauth" data-provider="' +
          esc(p) + '">Continue with ' + esc(providerLabel(p)) + "</button>";
      }).join("");
      Array.prototype.forEach.call(container.querySelectorAll("[data-provider]"), function (b) {
        b.addEventListener("click", function () {
          window.location = "/v1/auth/oauth/" + encodeURIComponent(b.getAttribute("data-provider"));
        });
      });
      show(divider);
      show(container);
    });
  }

  // ================================================= /new DEPLOY FLOW (dwb-6)
  // The badge → live-site experience. `/new?template=<slug>` is a REAL path the
  // router serves as the SPA shell; here we take over rendering (bypassing the
  // dashboard/auth default) and drive: template card → sign-in-if-needed →
  // Launch → live progress → ready (Open Studio / Deploy to Vercel / View
  // instance). ≤5 clicks, the user types nothing but an optional name.
  var NEW_RETURN_KEY = "bp_new_return"; // stash the slug across an OAuth/checkout round-trip

  // dwb-14: honest step narration is now SERVER-driven. The Go worker reports each
  // create→live transition (create/secure/configure/content/verify/ready ×
  // started|done|failed) to the control plane; /v1/barkparks surfaces them as
  // bp.provision_steps (refresh-durable). The progress screen renders those with
  // real server timestamps + elapsed. Client optimism survives ONLY as the
  // pre-first-event placeholder ("Starting…") before any server step has landed.
  // C2/D45: `verify` is the golden-path gate — the worker probes API/login/Studio
  // against the live box before `ready`, narrating each probe as a live caption.
  var SERVER_STEP_ORDER = ["create", "secure", "configure", "content", "verify", "ready"];
  var SERVER_STEP_LABELS = {
    create: "Creating your server",
    secure: "Securing your domain",
    configure: "Configuring Barkpark",
    content: "Installing your content",
    verify: "Testing login & Studio",
    ready: "Finishing up"
  };

  var newState = null; // {slug, template, id, startedAt, timer, poll, step, bp, serverSteps}
  var newTemplatesCache = null;
  var newAuthMode = "login";
  var newFlowFleetHook = null; // handleLiveEvent() calls this on an SSE "fleet" tick

  function isNewFlow() { return location.pathname === "/new"; }
  function newParams() {
    try { return new URLSearchParams(location.search || ""); }
    catch (e) { return { get: function () { return null; } }; }
  }
  function newTemplateSlug() { return newParams().get("template"); }

  function showNewScreen() {
    hide($("#auth-screen"));
    hide($("#app-shell"));
    show($("#new-screen"));
  }
  function newSetBody(html) { var b = $("#new-body"); if (b) b.innerHTML = html; }
  function newPanel(inner) { return '<div class="new-card card">' + inner + "</div>"; }
  function newTemplateHead(tpl) {
    var bullets = (tpl.what_you_get || []).map(function (b) { return "<li>" + esc(b) + "</li>"; }).join("");
    return '<span class="new-eyebrow">Deploy with Barkpark</span>' +
      '<h1 class="new-title">' + esc(tpl.title) + "</h1>" +
      '<p class="new-desc">' + esc(tpl.description) + "</p>" +
      (bullets ? '<ul class="new-gets">' + bullets + "</ul>" : "");
  }

  function loadNewTemplates() {
    if (newTemplatesCache) return Promise.resolve(newTemplatesCache);
    return api("GET", "/v1/templates", null, { noAuth: true }).then(function (r) {
      newTemplatesCache = (r.ok && r.data && r.data.templates) || [];
      return newTemplatesCache;
    });
  }

  function renderNewFlow() {
    showNewScreen();
    var slug = newTemplateSlug();
    loadNewTemplates().then(function (templates) {
      var tpl = templates.filter(function (t) { return t.slug === slug; })[0];
      if (!tpl) { renderNewPicker(templates); return; }
      newState = newState || {};
      newState.slug = tpl.slug;
      newState.template = tpl;
      var resumeId = newParams().get("bp");
      var authed = session() && session().token;
      if (resumeId && authed) { newStartProgress(resumeId); return; }
      if (!authed) { renderNewAuth(tpl); return; }
      renderNewLaunch(tpl);
    });
  }

  // No/unknown ?template= → let the visitor pick one.
  function renderNewPicker(templates) {
    var cards = (templates || []).map(function (t) {
      return '<a class="new-pick" href="/new?template=' + encodeURIComponent(t.slug) + '">' +
        '<span class="new-pick-title">' + esc(t.title) + "</span>" +
        '<span class="new-pick-desc dim">' + esc(t.description) + "</span></a>";
    }).join("");
    newSetBody(newPanel(
      '<span class="new-eyebrow">Deploy with Barkpark</span>' +
      "<h1 class=\"new-title\">Pick a starter</h1>" +
      '<p class="new-desc">Choose a template to launch a fully-managed Barkpark and deploy a site.</p>' +
      '<div class="new-picks">' + (cards || '<p class="dim">No templates available.</p>') + "</div>"
    ));
  }

  // ---- Step: sign in / up (logged out) --------------------------------------
  function renderNewAuth(tpl) {
    var form =
      '<div class="new-auth">' +
        '<p class="new-auth-lead">Sign in to launch this template. It takes seconds.</p>' +
        '<div class="auth-tabs" role="tablist" aria-label="Authentication mode">' +
          '<button class="auth-tab' + (newAuthMode === "login" ? " is-active" : "") + '" id="new-tab-login" type="button">Log in</button>' +
          '<button class="auth-tab' + (newAuthMode === "signup" ? " is-active" : "") + '" id="new-tab-signup" type="button">Sign up</button>' +
        "</div>" +
        '<form id="new-auth-form" novalidate>' +
          '<div class="field"><label class="label" for="new-email">Email</label>' +
            '<input class="form-input" id="new-email" type="email" autocomplete="email" placeholder="you@example.com" required /></div>' +
          '<div class="field"><label class="label" for="new-password">Password</label>' +
            '<input class="form-input" id="new-password" type="password" autocomplete="' + (newAuthMode === "login" ? "current-password" : "new-password") + '" placeholder="••••••••••••" required /></div>' +
          '<p class="form-error" id="new-auth-error" role="alert" hidden></p>' +
          '<button class="btn btn-primary btn-block" id="new-auth-submit" type="submit">' + (newAuthMode === "login" ? "Log in to launch" : "Sign up to launch") + "</button>" +
        "</form>" +
        '<div class="oauth-divider" id="new-oauth-divider" hidden><span>or</span></div>' +
        '<div class="oauth-buttons" id="new-oauth-buttons" hidden></div>' +
      "</div>";
    newSetBody(newPanel(newTemplateHead(tpl) + form));

    $("#new-tab-login").addEventListener("click", function () { newAuthMode = "login"; renderNewAuth(tpl); });
    $("#new-tab-signup").addEventListener("click", function () { newAuthMode = "signup"; renderNewAuth(tpl); });
    $("#new-auth-form").addEventListener("submit", newSubmitAuth);
    newRenderOAuth(tpl);
    var em = $("#new-email"); if (em) em.focus();
  }

  function newSubmitAuth(e) {
    e.preventDefault();
    var err = $("#new-auth-error");
    hide(err);
    var email = ($("#new-email").value || "").trim();
    var password = $("#new-password").value;
    if (!email || !password) { setText(err, "Email and password are required."); show(err); return; }
    var btn = $("#new-auth-submit");
    btn.disabled = true;
    var path = newAuthMode === "login" ? "/v1/auth/login" : "/v1/auth/register";
    api("POST", path, { email: email, password: password }, { noAuth: true }).then(function (r) {
      btn.disabled = false;
      if (r.ok && r.data && r.data.token) {
        setSession({ token: r.data.token, team_id: r.data.team_id || null }, true);
        renderNewFlow(); // stay on /new — now authed, proceed to Launch
      } else if (r.data && r.data.two_factor_required) {
        // 2FA users finish on the main login screen, then return via the badge.
        try { localStorage.setItem(NEW_RETURN_KEY, newState.slug); } catch (x) {}
        location.href = "/";
      } else {
        setText(err, friendly(r.data, "Couldn't sign you in.")); show(err);
      }
    });
  }

  function newRenderOAuth(tpl) {
    var container = $("#new-oauth-buttons");
    var divider = $("#new-oauth-divider");
    if (!container) return;
    api("GET", "/v1/auth/oauth/providers", null, { noAuth: true }).then(function (r) {
      var providers = (r.ok && r.data && r.data.providers) || [];
      if (!providers.length) { hide(container); hide(divider); return; }
      container.innerHTML = providers.map(function (p) {
        return '<button type="button" class="btn btn-block btn-oauth" data-provider="' + esc(p) + '">Continue with ' + esc(providerLabel(p)) + "</button>";
      }).join("");
      container.querySelectorAll("[data-provider]").forEach(function (b) {
        b.addEventListener("click", function () {
          // Stash the slug so the OAuth callback (which lands at "/") returns here.
          try { localStorage.setItem(NEW_RETURN_KEY, tpl.slug); } catch (x) {}
          window.location = "/v1/auth/oauth/" + encodeURIComponent(b.getAttribute("data-provider"));
        });
      });
      show(divider); show(container);
    });
  }

  // ---- Step: launch (logged in) ---------------------------------------------
  function renderNewLaunch(tpl) {
    var launch =
      '<form id="new-launch-form" class="new-launch" novalidate>' +
        '<div class="field"><label class="label" for="new-name">Project name <span class="dim">(optional)</span></label>' +
          '<input class="form-input" id="new-name" type="text" placeholder="' + esc(tpl.title) + '" /></div>' +
        '<button class="btn btn-primary btn-block btn-lg" id="new-launch-btn" type="submit">Launch</button>' +
        '<p class="new-fineprint dim">Fully managed. Your free trial starts automatically — no card required.</p>' +
      "</form>";
    newSetBody(newPanel(newTemplateHead(tpl) + launch));
    $("#new-launch-form").addEventListener("submit", newLaunch);
  }

  function newLaunch(e) {
    e.preventDefault();
    var btn = $("#new-launch-btn");
    if (!btn || btn.disabled) return; // double-submit guard (client half)
    btn.disabled = true;
    btn.textContent = "Launching…";
    var nameEl = $("#new-name");
    var name = (nameEl && nameEl.value || "").trim();
    var body = { template: newState.slug };
    if (name) body.name = name;
    api("POST", "/v1/launch", body).then(function (r) {
      if (r.status === 201 && r.data && r.data.barkpark && r.data.barkpark.id) {
        newStartProgress(r.data.barkpark.id); // optimistic — progress renders immediately
      } else if (r.status === 402) {
        renderNewPricing(newState.template);
      } else if (r.status === 409 && r.data && r.data.barkpark && r.data.barkpark.id) {
        newStartProgress(r.data.barkpark.id); // already provisioning → jump to its progress
      } else if (r.status === 403) {
        btn.disabled = false; btn.textContent = "Launch";
        toast({ kind: "error", title: "Plan limit reached", body: friendly(r.data, "You're at your plan's instance limit."),
          action: { label: "Open dashboard", onClick: function () { location.href = "/#billing"; } } });
      } else {
        btn.disabled = false; btn.textContent = "Launch";
        toast({ kind: "error", title: "Couldn't launch", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // ---- Step: pricing (402 — price visible before any charge) ----------------
  function renderNewPricing(tpl) {
    var tiers = TIERS.filter(function (t) { return !t.free; }).map(function (t) {
      return '<div class="new-tier">' +
        '<div class="new-tier-head"><span class="new-tier-name">' + esc(t.name) + "</span>" +
          '<span class="new-tier-price">' + esc(t.price) + '<span class="dim">' + esc(t.per) + "</span></span></div>" +
        '<p class="dim">' + esc(t.note) + "</p>" +
        '<button class="btn btn-primary btn-block new-plan" data-plan="' + esc(t.plan) + '" type="button">Choose ' + esc(t.name) + "</button>" +
      "</div>";
    }).join("");
    newSetBody(newPanel(newTemplateHead(tpl) +
      '<div class="new-pricing"><h2>Choose a plan to launch</h2>' +
      '<p class="dim">Your free trial has been used. Pick a plan to launch — cancel anytime.</p>' +
      '<div class="new-tiers">' + tiers + "</div></div>"));
    document.querySelectorAll(".new-plan").forEach(function (b) {
      b.addEventListener("click", function () {
        b.disabled = true; b.textContent = "Opening checkout…";
        try { localStorage.setItem(NEW_RETURN_KEY, tpl.slug); } catch (x) {}
        api("POST", "/v1/billing/checkout", { plan: b.getAttribute("data-plan") }).then(function (r) {
          if (r.status === 200 && r.data && r.data.checkout_url) { window.location = r.data.checkout_url; }
          else {
            b.disabled = false; b.textContent = "Choose";
            try { localStorage.removeItem(NEW_RETURN_KEY); } catch (x) {}
            toast({ kind: "error", title: "Couldn't open checkout", body: friendly(r.data, "Please try again.") });
          }
        });
      });
    });
  }

  // ---- Step: live progress --------------------------------------------------
  function newClearTimers() {
    if (newState) {
      if (newState.timer) clearInterval(newState.timer);
      if (newState.poll) clearInterval(newState.poll);
      newState.timer = null; newState.poll = null;
    }
    newFlowFleetHook = null;
  }

  function newStartProgress(id) {
    newClearTimers();
    newState = newState || {};
    newState.id = id;
    newState.startedAt = Date.now();
    newState.step = "progress";
    // dwb-16: live-console + connection-honesty state. serverConsole holds the
    // worker's redacted narration lines (bp.provision_console); consoleStick keeps
    // the panel pinned to the bottom UNLESS the user scrolled up; lastPollOkAt +
    // the SSE-error flag drive the "connection lost" banner. progressSig lets the
    // 1s tick update only the elapsed clock (leaving the console DOM + scroll
    // untouched) when nothing structural changed.
    newState.serverConsole = newState.serverConsole || [];
    newState.consoleStick = true;
    newState.consoleCollapsed = false;
    newState.provisionStatus = null;
    newState.lastPollOkAt = Date.now();
    newState.progressSig = null;
    // Reflect in the URL so a refresh RESUMES progress (not a fresh launch).
    history.replaceState(null, "", "/new?template=" + encodeURIComponent(newState.slug || "") + "&bp=" + encodeURIComponent(id));
    connectEvents(); // live fleet signals over SSE (auto-reconnects)
    newFlowFleetHook = function () { newCheckStatus(id); };
    newRenderProgress();
    newState.timer = setInterval(newRenderProgress, 1000); // tick elapsed + advance step
    newState.poll = setInterval(function () { newCheckStatus(id); }, 4000); // source of truth
    newCheckStatus(id);
  }

  // Fold the SERVER step array into a per-step status map: the LATEST status wins
  // per step (append-only started→done→failed), so a "done" that arrived after a
  // "started" reads as done. Unknown/extra steps are ignored (forward-compatible).
  function newStepStatuses(serverSteps) {
    var byStep = {};
    (serverSteps || []).forEach(function (s) {
      if (s && SERVER_STEP_LABELS[s.step]) byStep[s.step] = s.status;
    });
    return byStep;
  }

  // dwb-19: the LIVE sub-caption per step. The worker writes the human caption
  // onto the in-flight "started" entry (in place — never a new entry), so the
  // caption is read off that step's "started" entry. It persists for a done/failed
  // step too (the started entry stays in the array), so an active step narrates
  // the current sub-boundary and a finished one keeps its final caption.
  function newStepDetails(serverSteps) {
    var byStep = {};
    (serverSteps || []).forEach(function (s) {
      if (s && SERVER_STEP_LABELS[s.step] && s.status === "started" && s.detail) {
        byStep[s.step] = s.detail;
      }
    });
    return byStep;
  }

  // Elapsed seconds since the FIRST server step's timestamp (the server clock is
  // the source of truth), falling back to the client launch time before any step
  // has landed.
  function newElapsedSeconds(serverSteps) {
    var first = (serverSteps || [])[0];
    var base = (first && Date.parse(first.at)) || newState.startedAt || Date.now();
    return Math.max(0, Math.floor((Date.now() - base) / 1000));
  }

  // dwb-16: is the control plane unreachable? True only when BOTH live channels
  // are down — the SSE stream dropped (evtErrored, EventSource auto-retrying) AND
  // the 4s status poll has not succeeded for >10s. Either one alone is a normal
  // transient; both failing for >10s is a real connection loss the user must SEE
  // (their run otherwise looks frozen at "Starting…" — exactly the reported bug).
  function newConnLost() {
    var sinceOkPoll = Date.now() - (newState.lastPollOkAt || newState.startedAt || Date.now());
    return evtErrored && sinceOkPoll > 10000;
  }

  // The job is enqueued but no worker has claimed it >60s in — surface an honest
  // console line instead of a silent spinner. Cleared the moment it advances to
  // "claimed"/"succeeded"/"failed".
  function newWaitingForWorker() {
    if (newState.provisionStatus !== "pending") return false;
    return (Date.now() - (newState.startedAt || Date.now())) > 60000;
  }

  // The lines the console renders: the SERVER's redacted narration (refresh-durable)
  // plus, when relevant, the client-injected "waiting for a worker" honesty line.
  function newDisplayConsole() {
    var lines = (newState.serverConsole || []).slice();
    if (newWaitingForWorker()) lines.push({ at: null, line: "Waiting for a build worker…" });
    return lines;
  }

  function newFmtConsoleTime(at) {
    if (!at) return "";
    var t = Date.parse(at);
    if (isNaN(t)) return "";
    var d = new Date(t);
    function p(n) { return (n < 10 ? "0" : "") + n; }
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }

  // The dark, monospace, auto-scrolling console panel — VISIBLE BY DEFAULT during
  // provisioning (that's the point), collapsible. Timestamps per line.
  function newConsoleHtml() {
    var lines = newDisplayConsole();
    var body = lines.length
      ? lines.map(function (e) {
          var ts = newFmtConsoleTime(e.at);
          return '<div class="new-console-line">' +
            (ts ? '<span class="new-console-ts">' + esc(ts) + "</span>" : "") +
            '<span class="new-console-text">' + esc(e.line) + "</span></div>";
        }).join("")
      : '<div class="new-console-line dim">Waiting for the first log line…</div>';
    var collapsed = !!newState.consoleCollapsed;
    return '<div class="new-console' + (collapsed ? " is-collapsed" : "") + '">' +
        '<button type="button" class="new-console-toggle" id="new-console-toggle" aria-expanded="' + (collapsed ? "false" : "true") + '">' +
          '<span class="new-console-caret" aria-hidden="true"></span>Console' +
        "</button>" +
        '<div class="new-console-body" id="new-console-body"' + (collapsed ? " hidden" : "") + ">" + body + "</div>" +
      "</div>";
  }

  // The connection-lost banner — shown ONLY while newConnLost(); auto-clears on
  // recovery (the next render drops it once a poll succeeds or SSE reconnects).
  function newConnBannerHtml() {
    if (!newConnLost()) return "";
    return '<p class="notice notice-warn new-conn-lost" role="status">' +
      "Connection to Barkpark Cloud lost — retrying…</p>";
  }

  // Re-pin the console to the bottom (unless the user scrolled up) and wire the
  // collapse toggle + a scroll listener that toggles the stick state.
  function newWireConsole() {
    var toggle = $("#new-console-toggle");
    if (toggle) toggle.addEventListener("click", function () {
      // Collapse/expand in place (no re-render) so this works on BOTH the progress
      // screen and the failed screen, where the console stays visible.
      newState.consoleCollapsed = !newState.consoleCollapsed;
      var b = $("#new-console-body");
      var panel = toggle.parentNode;
      if (b) {
        if (newState.consoleCollapsed) hide(b);
        else { show(b); if (newState.consoleStick !== false) b.scrollTop = b.scrollHeight; }
      }
      if (panel) panel.classList.toggle("is-collapsed", newState.consoleCollapsed);
      toggle.setAttribute("aria-expanded", newState.consoleCollapsed ? "false" : "true");
    });
    var body = $("#new-console-body");
    if (body) {
      body.addEventListener("scroll", function () {
        // Stick to bottom only while the user is near it; scrolling up releases.
        newState.consoleStick = (body.scrollHeight - body.scrollTop - body.clientHeight) < 24;
      });
      if (newState.consoleStick !== false) body.scrollTop = body.scrollHeight;
      else if (typeof newState.consoleScrollTop === "number") body.scrollTop = newState.consoleScrollTop;
    }
  }

  // A stable signature of everything the progress screen shows EXCEPT the elapsed
  // clock — so the 1s tick can update just the clock (leaving the console DOM +
  // the user's scroll position alone) and only fully rebuild when something real
  // changed (a new step, a new console line, the banner, or a collapse toggle).
  function newProgressSig() {
    var byStep = newStepStatuses(newState.serverSteps);
    var detailByStep = newStepDetails(newState.serverSteps);
    // dwb-19: fold the live captions into the signature so a caption change (with
    // no status change) still triggers a rebuild — that's what re-plays the fade.
    var stepSig = SERVER_STEP_ORDER.map(function (n) {
      return (byStep[n] || "-") + ":" + (detailByStep[n] || "");
    }).join(",");
    var dc = newDisplayConsole();
    var lastAt = dc.length ? (dc[dc.length - 1].at || "client") : "none";
    return stepSig + "|" + dc.length + "|" + lastAt +
      "|" + (newState.consoleCollapsed ? "c" : "o") +
      "|" + (newConnLost() ? "lost" : "ok") +
      "|" + ((newState.serverSteps && newState.serverSteps.length) ? "s" : "p");
  }

  function newRenderProgress(force) {
    if (!newState || newState.step !== "progress") return;
    var serverSteps = newState.serverSteps || [];
    var elapsed = newElapsedSeconds(serverSteps);

    // Fast path: nothing structural changed, so just refresh the elapsed clock in
    // place — never re-render the console (that would reset the user's scroll).
    var sig = newProgressSig();
    if (!force && sig === newState.progressSig) {
      var el = document.querySelector("#new-body .new-elapsed");
      if (el) el.textContent = elapsed + "s elapsed";
      return;
    }
    newState.progressSig = sig;

    // Preserve the user's scroll position across the full rebuild when they've
    // scrolled up (not stuck to bottom), so a newly-arrived line doesn't yank them.
    var prevBody = document.querySelector("#new-body .new-console-body");
    if (prevBody && newState.consoleStick === false) newState.consoleScrollTop = prevBody.scrollTop;

    var title = (newState.template && newState.template.title) || "your Barkpark";

    // Pre-first-event placeholder: honest "Starting…" (client optimism, bounded to
    // the window before the worker reports its first transition), never a bare spinner.
    var stepsHtml;
    if (!serverSteps.length) {
      stepsHtml = '<ul class="new-steps"><li class="new-step active">' +
        '<span class="new-step-dot" aria-hidden="true"></span>' +
        '<span class="new-step-label">Starting…</span>' +
        '<span class="new-step-spin" aria-hidden="true"></span>' +
        "</li></ul>";
    } else {
      var byStep = newStepStatuses(serverSteps);
      var detailByStep = newStepDetails(serverSteps);
      var steps = SERVER_STEP_ORDER.map(function (name) {
        var st = byStep[name]; // "started" | "done" | "failed" | undefined
        var cls = st === "done" ? "done" : st === "failed" ? "failed" : st === "started" ? "active" : "pending";
        var dot = st === "done" ? "&#10003;" : st === "failed" ? "&#10007;" : "";
        // dwb-19: the live sub-caption under the label. `key` in the class re-mounts
        // the element on change so the fade/translate replays; muted + smaller.
        var cap = detailByStep[name];
        var capHtml = cap
          ? '<span class="new-step-detail" data-cap="' + esc(cap) + '">' + esc(cap) + "</span>"
          : "";
        return '<li class="new-step ' + cls + '">' +
          '<span class="new-step-dot" aria-hidden="true">' + dot + "</span>" +
          '<span class="new-step-body">' +
            '<span class="new-step-label">' + esc(SERVER_STEP_LABELS[name]) + "</span>" +
            capHtml +
          "</span>" +
          (st === "started" ? '<span class="new-step-spin" aria-hidden="true"></span>' : "") +
          "</li>";
      }).join("");
      stepsHtml = '<ul class="new-steps">' + steps + "</ul>";
    }

    newSetBody(newPanel(
      '<div class="new-progress">' +
        newConnBannerHtml() +
        "<h2>Setting up " + esc(title) + "</h2>" +
        '<p class="dim">This usually takes under a minute. <span class="new-elapsed">' + elapsed + "s elapsed</span></p>" +
        stepsHtml +
        newConsoleHtml() +
      "</div>"));
    newWireConsole();
  }

  function newCheckStatus(id) {
    api("GET", "/v1/barkparks", null, {}).then(function (r) {
      // dwb-16: a FAILED poll (network error / non-2xx) leaves lastPollOkAt stale
      // so the connection-lost banner can surface if SSE is ALSO down >10s. Never
      // a silent frozen spinner — re-render so the banner shows/hides honestly.
      if (!(r.ok && r.data && r.data.barkparks)) { newRenderProgress(true); return; }
      newState.lastPollOkAt = Date.now();
      var bp = r.data.barkparks.filter(function (x) { return String(x.id) === String(id); })[0];
      if (!bp) { newRenderProgress(true); return; }
      // Stash the SERVER-reported steps + live console so the progress screen
      // renders real, refresh-durable state (not the old client-side timer).
      newState.serverSteps = bp.provision_steps || [];
      newState.serverConsole = bp.provision_console || [];
      newState.provisionStatus = bp.provision_status || null;
      if (bp.host) { newRenderReady(bp); }
      else if (bp.provision_status === "failed") { newRenderFailed(bp); }
      else { newRenderProgress(true); } // still provisioning — re-render server state now
    });
  }

  // ---- Step: ready ----------------------------------------------------------
  function newRenderReady(bp) {
    if (newState && newState.step === "ready") return;
    newClearTimers();
    newState.step = "ready";
    newState.bp = bp;
    // Bootstrap outputs power the env copy-block + the Vercel env prefill; the
    // GitHub connection state decides the "Create GitHub repo" affordance (gh-3).
    api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/bootstrap", null, {}).then(function (r) {
      var boot = (r.ok && r.data) || null;
      api("GET", "/v1/github/installation").then(function (gr) {
        var gh = (gr.ok && gr.data) || {};
        newSetBody(newPanel(newReadyHtml(bp, boot, gh)));
        newWireReady(bp, boot, gh);
      });
    });
  }

  // github.com/<owner>/<repo> URL host clone override wins over the template's
  // default (monorepo) repo, so the Vercel handoff clones the user's NEW repo.
  function vercelCloneUrl(tpl, boot, repoOverride) {
    var repo = repoOverride || (tpl && tpl.repo) || "";
    var keys = (tpl && tpl.env_keys && tpl.env_keys.length) ? tpl.env_keys : (boot && boot.env ? Object.keys(boot.env) : []);
    var params = [];
    if (repo) params.push("repository-url=" + encodeURIComponent(repo));
    if (keys.length) params.push("env=" + encodeURIComponent(keys.join(",")));
    params.push("envDescription=" + encodeURIComponent("Paste the values from the copy block on the launch screen."));
    if (tpl && tpl.docs) params.push("envLink=" + encodeURIComponent(tpl.docs));
    return "https://vercel.com/new/clone?" + params.join("&");
  }

  // A .env block (KEY=value per line) in the template's key order, only keys the
  // bootstrap resolved a value for. Treat as a secret (carries the read token).
  function envDotenv(tpl, boot) {
    if (!boot || !boot.env) return "";
    var keys = (tpl && tpl.env_keys && tpl.env_keys.length) ? tpl.env_keys : Object.keys(boot.env);
    return keys.filter(function (k) { return boot.env[k] != null; })
      .map(function (k) { return k + "=" + boot.env[k]; }).join("\n");
  }

  // The GitHub "Create repo" affordance (gh-3), shown only for a DEPLOYABLE
  // template. Connected → an input + "Create GitHub repo" (creates it in the
  // user's account, pushes the app, then rewires the Vercel clone to that repo).
  // Configured-but-not-connected → a Connect GitHub link. Not configured → hidden.
  function newGithubHtml(tpl, gh) {
    if (!tpl || !tpl.deployable) return "";
    if (gh && gh.connected) {
      var def = esc(defaultRepoName(tpl));
      return '<div class="new-gh">' +
        '<label class="label" for="new-gh-name">Create a GitHub repo for this template</label>' +
        '<div class="new-golive-row">' +
          '<input class="form-input" id="new-gh-name" type="text" value="' + def + '" spellcheck="false" />' +
          '<button class="btn btn-primary" id="new-gh-create" type="button">Create GitHub repo</button>' +
        '</div>' +
        '<p class="new-fineprint dim">We create it in ' + esc(gh.account_login || "your GitHub account") +
          ' and push this template’s app. Then “Deploy to Vercel” clones YOUR repo.</p>' +
        '<div id="new-gh-result"></div>' +
      "</div>";
    }
    if (gh && gh.configured && gh.install_url) {
      return '<div class="new-gh">' +
        '<p class="new-fineprint dim">Connect GitHub to push this template into your own repo first.</p>' +
        '<a class="btn btn-block" href="' + esc(gh.install_url) + '">Connect GitHub</a>' +
      "</div>";
    }
    return "";
  }

  function newReadyHtml(bp, boot, gh) {
    var tpl = newState.template;
    var clone = vercelCloneUrl(tpl, boot);
    var dotenv = envDotenv(tpl, boot);
    var envBlock = dotenv
      ? '<div class="new-env"><div class="new-env-head"><span>Environment variables</span>' +
          '<button class="btn btn-ghost btn-sm" type="button" data-copy="' + esc(dotenv) + '">Copy all</button></div>' +
          '<pre class="new-env-body">' + esc(dotenv) + "</pre>" +
          '<p class="new-fineprint dim">Vercel prefills the keys; paste these values when prompted. Treat them as secret.</p></div>'
      : "";
    return '<div class="new-ready">' +
      '<span class="new-eyebrow ok">Live</span>' +
      "<h1 class=\"new-title\">" + esc(bp.name) + " is ready</h1>" +
      '<p class="new-desc">Your managed Barkpark is up' + (bp.url ? ' at <span class="mono">' + esc(bp.url) + "</span>" : "") + ".</p>" +
      '<div class="new-actions">' +
        '<button class="btn btn-primary btn-block" id="new-open-studio" type="button">Open Studio</button>' +
        newGithubHtml(tpl, gh) +
        '<a class="btn btn-block btn-vercel" id="new-vercel" href="' + esc(clone) + '" target="_blank" rel="noopener">Deploy your site to Vercel</a>' +
        '<a class="btn btn-ghost btn-block" href="/#instance/' + esc(bp.id) + '">View instance</a>' +
      "</div>" +
      envBlock +
      '<div class="new-golive"><label class="label" for="new-site-url">Once deployed, tell us your site URL</label>' +
        '<div class="new-golive-row"><input class="form-input" id="new-site-url" type="url" placeholder="https://your-site.vercel.app" />' +
        '<button class="btn btn-primary" id="new-site-url-btn" type="button">Wire revalidation</button></div>' +
        '<p class="new-fineprint dim">This activates instant content updates: edits in Studio refresh your live site.</p></div>' +
      "</div>";
  }

  function newWireReady(bp, boot, gh) {
    var os = $("#new-open-studio");
    if (os) os.addEventListener("click", function () { openStudio(bp.id, os); });
    var sb = $("#new-site-url-btn");
    if (sb) sb.addEventListener("click", function () { newSubmitSiteUrl(bp.id, sb); });
    var gc = $("#new-gh-create");
    if (gc) gc.addEventListener("click", function () { newCreateRepo(bp, boot, gh, gc); });
  }

  // A sensible default GitHub repo name from the template — lowercase, only the
  // URL-safe set GitHub accepts, ≤100 chars. The user can edit it before create.
  function defaultRepoName(tpl) {
    var base = (tpl && (tpl.slug || tpl.title)) || "barkpark-site";
    var slug = String(base).toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^[-.]+|[-.]+$/g, "").slice(0, 100);
    return slug || "barkpark-site";
  }

  // gh-3: create a repo in the user's account, push the template's app, then
  // rewire the Vercel clone button to THAT repo. A busy state + per-step result +
  // toast is the honest feedback for a ~seconds-long action (no heavy console).
  function newCreateRepo(bp, boot, gh, btn) {
    var tpl = newState.template;
    var input = $("#new-gh-name");
    var name = (input && input.value || "").trim();
    if (!name) { toast({ kind: "error", title: "Name the repo first" }); if (input) input.focus(); return; }
    btn.disabled = true; btn.textContent = "Creating repo…";
    if (input) input.disabled = true;
    api("POST", "/v1/github/repos", { template: tpl.slug, name: name, private: false }).then(function (r) {
      if (r.ok && r.data) {
        var v = $("#new-vercel");
        if (v) v.setAttribute("href", vercelCloneUrl(tpl, boot, r.data.html_url));
        btn.textContent = "Repo created";
        var res = $("#new-gh-result");
        if (res) {
          var steps = (r.data.steps || []).map(function (s) { return "<li>" + esc(s) + "</li>"; }).join("");
          res.innerHTML =
            '<p class="new-fineprint">Created <a class="mono" href="' + esc(r.data.html_url) + '" target="_blank" rel="noopener">' +
              esc(r.data.repo_full_name) + "</a>. “Deploy to Vercel” now clones this repo.</p>" +
            (steps ? '<ul class="new-gh-steps dim">' + steps + "</ul>" : "");
        }
        toast({ kind: "success", title: "GitHub repo created", body: r.data.repo_full_name });
      } else {
        btn.disabled = false; btn.textContent = "Create GitHub repo";
        if (input) input.disabled = false;
        if (r.status === 409 && r.data && r.data.error === "repo_exists") {
          toast({ kind: "error", title: "That repo name is taken", body: "Pick a different name and try again." });
          if (input) input.focus();
        } else if (r.status === 409 && r.data && r.data.error === "no_installation") {
          toast({ kind: "error", title: "GitHub isn’t connected", body: "Connect GitHub in Providers, then retry." });
        } else {
          toast({ kind: "error", title: "Couldn’t create the repo", body: friendly(r.data, "Please try again.") });
        }
      }
    });
  }

  function newSubmitSiteUrl(id, btn) {
    var input = $("#new-site-url");
    var url = (input && input.value || "").trim();
    if (!url) { toast({ kind: "error", title: "Enter your site URL first" }); if (input) input.focus(); return; }
    btn.disabled = true; btn.textContent = "Wiring…";
    api("POST", "/v1/barkparks/" + encodeURIComponent(id) + "/site-url", { url: url }).then(function (r) {
      btn.disabled = false; btn.textContent = "Wire revalidation";
      if (r.ok) {
        toast({ kind: "success", title: "Revalidation wired", body: "Content changes will now refresh your live site." });
      } else if (r.status === 422) {
        toast({ kind: "error", title: "That doesn't look like a URL", body: "Enter your site's full https:// address." });
      } else {
        toast({ kind: "error", title: "Couldn't wire revalidation", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // ---- Step: failed (inline retry) ------------------------------------------
  // dwb-19: on failure, the last live caption of the failed step — the plain
  // "what we were doing when it broke" line, shown above the raw console. Reads
  // the failed step's started-entry caption (its human sub-line), else the most
  // recent caption of any step. "" when there was no caption.
  function newFailedCaption(serverSteps) {
    var steps = serverSteps || [];
    var byStatus = newStepStatuses(steps);
    var byDetail = newStepDetails(steps);
    // Prefer the caption of whichever step actually failed.
    for (var i = 0; i < SERVER_STEP_ORDER.length; i++) {
      var n = SERVER_STEP_ORDER[i];
      if (byStatus[n] === "failed" && byDetail[n]) return byDetail[n];
    }
    // Else the last caption seen (the step that was in flight).
    var last = "";
    SERVER_STEP_ORDER.forEach(function (n) { if (byDetail[n]) last = byDetail[n]; });
    return last;
  }

  function newRenderFailed(bp) {
    if (newState && newState.step === "failed") return;
    newClearTimers();
    newState.step = "failed";
    var reason = bp.provision_error ? esc(bp.provision_error) : "Something went wrong while provisioning.";
    // dwb-16: the console STAYS on failure — that's where the user reads what
    // actually happened (the last lines carry the failure detail).
    newState.serverConsole = bp.provision_console || newState.serverConsole || [];
    newState.serverSteps = bp.provision_steps || newState.serverSteps || [];
    // dwb-19: the last human caption before the break, above the raw console.
    var lastCap = newFailedCaption(newState.serverSteps);
    var capLine = lastCap
      ? '<p class="new-failed-caption">Last step: ' + esc(lastCap) + "</p>"
      : "";
    newSetBody(newPanel(
      '<div class="new-failed">' +
        "<h2>Setup didn't finish</h2>" +
        '<p class="notice notice-error" role="alert">' + reason + "</p>" +
        '<p class="dim">You can retry — this re-runs provisioning for the same instance. Nothing was charged.</p>' +
        '<button class="btn btn-primary btn-block" id="new-retry" type="button">Retry setup</button>' +
        capLine +
        newConsoleHtml() +
        '<p class="new-fineprint"><a href="/#instance/' + esc(bp.id) + '">View instance in the dashboard</a></p>' +
      "</div>"));
    newWireConsole();
    $("#new-retry").addEventListener("click", function () {
      var b = $("#new-retry"); b.disabled = true; b.textContent = "Retrying…";
      api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/retry", {}).then(function (r) {
        if (r.status === 201) { newStartProgress(bp.id); }
        else { b.disabled = false; b.textContent = "Retry setup"; toast({ kind: "error", title: "Couldn't retry", body: friendly(r.data, "Please try again.") }); }
      });
    });
  }

  // =========================================================== RENDER
  function render() {
    // A returning OAuth callback lands a session token on the fragment; consume
    // it BEFORE the logged-in/out decision so the user lands straight in.
    var didOAuth = handleOAuthReturn();

    // dwb-6: an OAuth/checkout round-trip that began in the /new flow lands back
    // at "/" — we stashed the template slug, so bounce the user straight back
    // into the deploy flow (now authed / subscribed).
    var pendingNew = null;
    try { pendingNew = localStorage.getItem(NEW_RETURN_KEY); } catch (e) {}
    if (pendingNew && (didOAuth || checkoutFlag() === "success")) {
      try { localStorage.removeItem(NEW_RETURN_KEY); } catch (e) {}
      location.href = "/new?template=" + encodeURIComponent(pendingNew);
      return;
    }

    // The /new deploy flow owns the whole screen when we're on that path.
    if (isNewFlow()) { renderNewFlow(); return; }

    var s = session();
    if (!s || !s.token) {
      closeEvents();
      meCache = null;
      subCache = null;
      subLoaded = false;
      subError = false;
      hide($("#app-shell"));
      show($("#auth-screen"));

      // An emailed password-reset link (#/auth/reset?token=…) lands here while
      // logged out — show the set-new-password card instead of the login form.
      var resetToken = resetTokenFromHash();
      if (resetToken) {
        pendingResetToken = resetToken;
        hide($("#login-card"));
        show($("#reset-card"));
        hideResetError();
        $("#reset-password").value = "";
        $("#reset-password").focus();
      } else {
        show($("#login-card"));
        hide($("#reset-card"));
        setAuthMode("login");
        renderOAuthButtons();
        $("#auth-email").focus();
      }
      return;
    }
    hide($("#auth-screen"));
    show($("#app-shell"));

    // Real account identity (team name + email) + the live event stream.
    loadMe();
    connectEvents();

    // Detect a Stripe checkout return (?checkout=success|cancel) — it rewrites
    // the URL to #billing and shows the right state.
    var fromCheckout = handleCheckoutReturn();

    // Validate the route. Accept tab views and BOTH drill-downs (#instance/…,
    // #site/…) — the old guard reset a site deep-link to #fleet on reload.
    var r = parseHash();
    if (!fromCheckout && VIEWS.indexOf(r.view) === -1 && DETAIL_VIEWS.indexOf(r.view) === -1) {
      location.hash = "#overview";
    }
    applyRoute();
  }

  // =========================================================== WIRE-UP
  function init() {
    initTheme();
    wireModal();

    // Auth.
    $("#tab-login").addEventListener("click", function () { setAuthMode("login"); });
    $("#tab-signup").addEventListener("click", function () { setAuthMode("signup"); });
    $("#auth-form").addEventListener("submit", submitAuth);
    $("#auth-eye").addEventListener("click", function () { toggleEye("#auth-password", "#auth-eye"); });
    $("#auth-forgot").addEventListener("click", function (e) {
      e.preventDefault();
      requestPasswordReset();
    });
    // Password-reset card (shown when an emailed #/auth/reset?token= link opens).
    $("#reset-form").addEventListener("submit", submitReset);
    $("#reset-eye").addEventListener("click", function () { toggleEye("#reset-password", "#reset-eye"); });
    $("#reset-back").addEventListener("click", function (e) {
      e.preventDefault();
      location.hash = "";
      render();
    });
    wireSwitchLink();

    // Shell.
    $("#theme-toggle").addEventListener("click", toggleTheme);
    $("#acct-btn").addEventListener("click", openAccountModal);

    // Views.
    var ovLaunch = $("#overview-launch");
    if (ovLaunch) ovLaunch.addEventListener("click", function () { location.hash = "#launch"; });
    // Close the Settings disclosure when clicking outside it (native <details>
    // only closes on its own summary; this makes it behave like a real menu).
    document.addEventListener("click", function (e) {
      var menu = document.querySelector(".nav-menu[open]");
      if (menu && !(e.target.closest && e.target.closest(".nav-menu"))) menu.removeAttribute("open");
    });
    $("#fleet-refresh").addEventListener("click", function () { loadFleet(parseHash().filter || null); });
    $("#sites-refresh").addEventListener("click", loadSites);
    $("#activity-refresh").addEventListener("click", loadActivity);
    $("#activity-load-more").addEventListener("click", loadMoreActivity);
    var notifTest = $("#notif-test");
    if (notifTest) notifTest.addEventListener("click", sendTestNotification);

    // Copy-to-clipboard (delegated) for any [data-copy] affordance.
    document.addEventListener("click", function (e) {
      var b = e.target.closest && e.target.closest("[data-copy]");
      if (!b) return;
      var text = b.getAttribute("data-copy");
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () { toast({ kind: "success", title: "Copied", body: text, duration: 2000 }); },
          function () { toast({ kind: "error", title: "Couldn't copy" }); }
        );
      }
    });
    $("#launch-form").addEventListener("submit", submitLaunch);
    $("#provider-add").addEventListener("click", openProviderPicker);
    $("#provider-add-empty").addEventListener("click", openProviderPicker);
    $("#token-add").addEventListener("click", openTokenModal);

    window.addEventListener("hashchange", function () {
      if (isNewFlow()) return; // the /new deploy flow is path+query driven, not hash-routed
      if (session() && session().token) applyRoute();
    });

    // /new screen has its own theme toggle (it renders outside the app shell).
    var newTheme = $("#new-theme-toggle");
    if (newTheme) newTheme.addEventListener("click", toggleTheme);

    render();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // Test-only escape hatch (same pattern as the sheet-grid hook): a node:vm
  // harness (__app.test.mjs) sets __bpTestHook to grab the pure helpers. Absent
  // in a real browser, so this is a no-op in production.
  if (typeof globalThis !== "undefined" && typeof globalThis.__bpTestHook === "function") {
    globalThis.__bpTestHook({
      esc: esc, safeDecode: safeDecode, parseHash: parseHash, relTime: relTime,
      failureCopy: failureCopy, liveEventTypes: Object.keys(TYPE_ACTIONS),
      // C2/D45: the /new timeline's step vocabulary — pinned against the Go
      // worker's report vocabulary + the ProvisionJob @steps whitelist.
      serverStepOrder: SERVER_STEP_ORDER, serverStepLabels: SERVER_STEP_LABELS,
      deployIsActive: deployIsActive, deployIsPreClaim: deployIsPreClaim,
      deployDetailHtml: deployDetailHtml, deployConsoleHtml: deployConsoleHtml,
      // IA reshape + attention-rollup pure helpers (charter decisions 6 + 15).
      legacyRoute: legacyRoute, parseFleetFilter: parseFleetFilter,
      classifyBp: classifyBp, statusOf: statusOf,
      attentionRank: attentionRank, attentionCompare: attentionCompare,
      bucketOf: bucketOf, fleetSummary: fleetSummary, filterFleet: filterFleet,
      // Dashboard billing-correctness pure helpers (mirror Billing.entitled?/1).
      launchEntitled: launchEntitled, billingStatusLabel: billingStatusLabel,
      billingStatusBadge: billingStatusBadge, billingPeriodLine: billingPeriodLine,
      // a11y (label-in-name): visible word and accessible name derive together.
      themeLabelText: themeLabelText, themeToggleAria: themeToggleAria,
    });
  }
})();
