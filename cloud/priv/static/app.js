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
  var lastFocused = null;

  function openModal(html) {
    var root = $("#modal-root");
    var bodyEl = $("#modal-body");
    if (!root || !bodyEl) return;
    lastFocused = document.activeElement;
    bodyEl.innerHTML = html;
    show(root);
    var focusable = bodyEl.querySelector("button, [href], input, select, textarea, [tabindex]");
    (focusable || $(".modal-x")).focus();
    return bodyEl;
  }

  function closeModal() {
    var root = $("#modal-root");
    if (!root || root.hidden) return;
    hide(root);
    $("#modal-body").innerHTML = "";
    if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus();
  }

  function wireModal() {
    var root = $("#modal-root");
    if (!root) return;
    root.addEventListener("click", function (e) {
      if (e.target.hasAttribute && e.target.hasAttribute("data-close")) closeModal();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !root.hidden) closeModal();
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
        '<div id="pw-error" class="auth-error" hidden></div>' +
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
        '<select id="notif-transport">' + transportOpts + "</select></div>" +
      '<div class="notif-row"><label>From address</label>' +
        '<input id="notif-from-addr" type="email" value="' + esc(s.from_address || "") + '" placeholder="noreply@barkpark.cloud"></div>' +
      '<div class="notif-smtp">' +
        '<div class="notif-row"><label>SMTP host</label><input id="notif-smtp-host" placeholder="' +
          (s.smtp_host ? "•••••••• (stored)" : "smtp.example.com") + '"></div>' +
        '<div class="notif-row"><label>SMTP username</label><input id="notif-smtp-user" placeholder="' +
          (s.smtp_username ? "•••••••• (stored)" : "username") + '"></div>' +
        '<div class="notif-row"><label>SMTP password</label><input id="notif-smtp-pass" type="password" placeholder="' +
          (s.smtp_password ? "•••••••• (stored)" : "password") + '"></div>' +
        '<div class="notif-row"><label>SMTP port</label><input id="notif-smtp-port" type="number" value="' + esc(s.smtp_port || "") + '" placeholder="587"></div>' +
      "</div>" +
      '<h2 class="notif-h">Events</h2><div class="notif-toggles">' + toggles + "</div>" +
      '<button class="btn btn-primary" id="notif-save" type="button">Save settings</button>' +
      '<span id="notif-status" class="dim"></span>' +
      "</div>";

    var save = $("#notif-save");
    if (save) save.addEventListener("click", saveNotifications);
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
  function applyTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    setText($("#theme-label"), t === "dark" ? "Light" : "Dark");
  }
  function initTheme() {
    var t = localStorage.getItem(THEME) || "light";
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
    return m ? decodeURIComponent(m[1]) : null;
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
        location.hash = "#fleet";
        render();
      } else {
        showAuthError(friendly(r.data, "Couldn't sign you in."));
      }
    });
  }

  // =========================================================== NAV / ROUTER
  var VIEWS = ["fleet", "sites", "launch", "billing", "providers", "notifications", "tokens", "activity"];

  // Routes are either a tab (#fleet …) or a drill-down (#instance/<id>, #site/<id>).
  var DETAIL_VIEWS = ["instance", "site"];
  function parseHash() {
    var h = (location.hash || "").replace(/^#/, "");
    var mi = h.match(/^instance\/(.+)$/);
    if (mi) return { view: "instance", id: decodeURIComponent(mi[1]) };
    var ms = h.match(/^site\/(.+)$/);
    if (ms) return { view: "site", id: decodeURIComponent(ms[1]) };
    return { view: VIEWS.indexOf(h) !== -1 ? h : "fleet" };
  }

  function applyRoute() {
    var r = parseHash();
    var detail = DETAIL_VIEWS.indexOf(r.view) !== -1;
    // Which tab stays highlighted while in a detail view.
    var activeTab = r.view === "site" ? "sites" : r.view === "instance" ? "fleet" : r.view;
    VIEWS.forEach(function (v) {
      var sec = document.getElementById("view-" + v);
      if (sec) sec.hidden = detail || v !== r.view;
      var link = document.querySelector('.nav-link[data-view="' + v + '"]');
      if (link) link.classList.toggle("is-active", v === activeTab);
    });
    var inst = document.getElementById("view-instance");
    if (inst) inst.hidden = r.view !== "instance";
    var site = document.getElementById("view-site");
    if (site) site.hidden = r.view !== "site";

    if (r.view === "instance") { loadInstance(r.id); return; }
    if (r.view === "site") { loadSite(r.id); return; }
    setBreadcrumb(null);
    if (r.view === "fleet") loadFleet();
    if (r.view === "sites") loadSites();
    if (r.view === "billing") renderRecommended();
    if (r.view === "launch") renderLaunchGate();
    if (r.view === "providers") loadProviders();
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

    var health = bp.health_status || "unknown";
    var healthLabel = health.charAt(0).toUpperCase() + health.slice(1);
    var agent = bp.agent_status || "offline";
    var agentLabel = agent.charAt(0).toUpperCase() + agent.slice(1);
    var version = bp.version ? '<span class="fleet-version">v' + esc(bp.version) + "</span>" : "";

    var badges = removing
      ? badge("Removing…", "unknown")
      : removeFailed
        ? badge("Removal failed", "down")
        : failed
          ? badge("Failed", "down")
          : version + badge(healthLabel, health) + badge(agentLabel, agent);

    // dwb-7 one-click Studio entry: live boxes (host set, nothing in-flight)
    // get an Open Studio button — server-minted single-use link, no token paste.
    var live = !removing && !removeFailed && !failed && !provisioning && bp.host;
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
        badges + openStudioBtn +
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
      fleetCache = (r.ok && r.data && r.data.barkparks) || [];
      return fleetCache;
    });
  }

  function loadFleet() {
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
        body.innerHTML =
          '<div class="card start-card">' +
            "<h2>Get started</h2>" +
            "<p>Two steps to your first managed Barkpark — we host it for you.</p>" +
            startStep(1, "Choose a plan", "Pick a subscription to unlock launches.", "billing", "Choose") +
            startStep(2, "Launch your first instance", "Name it and we provision it for you — fully managed.", "launch", "Launch") +
            '<p class="start-foot dim">Prefer your own cloud account? ' +
              'Connect a provider under <a href="#providers">Providers</a> (advanced).</p>' +
          "</div>";
        wireStartSteps();
        return;
      }
      body.innerHTML = list.map(fleetRow).join("");
      body.querySelectorAll(".fleet-row[data-id]").forEach(function (row) {
        var go = function () { location.hash = "#instance/" + encodeURIComponent(row.getAttribute("data-id")); };
        row.addEventListener("click", go);
        row.addEventListener("keydown", function (e) {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); }
        });
      });
      body.querySelectorAll(".fleet-open-studio").forEach(function (b) {
        b.addEventListener("click", function (e) {
          e.stopPropagation(); // don't also drill into the row's detail view
          openStudio(b.getAttribute("data-id"), b);
        });
      });
    });
  }

  // =========================================================== INSTANCE DETAIL
  function loadInstance(id) {
    var box = $("#instance-body");
    box.innerHTML = '<div class="loading">Loading instance&hellip;</div>';
    ensureFleet().then(function (list) {
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

    var health = bp.health_status || "unknown";
    var agent = bp.agent_status || "offline";
    var version = bp.version ? '<span class="fleet-version">v' + esc(bp.version) + "</span>" : "";
    var badges = removing
      ? badge("Removing…", "unknown")
      : removeFailed
        ? badge("Removal failed", "down")
        : failed
          ? badge("Failed", "down")
          : version + badge(cap(health), health) + badge(cap(agent), agent);

    var actions =
      removing
        ? ""
        : removeFailed
          ? '<button class="btn btn-primary btn-sm" id="inst-remove-retry" type="button">Retry removal</button>'
          : failed
            ? '<button class="btn btn-primary btn-sm" id="inst-retry" type="button">Retry</button>' +
              '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>'
            : bp.host
              ? '<button class="btn btn-primary btn-sm" id="inst-open-studio" type="button">Open Studio</button>' +
                '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>'
              : "";

    var failBanner = removeFailed && bp.deprovision_error
      ? '<div class="notice notice-error" role="alert"><b>Removal failed.</b> ' + esc(bp.deprovision_error) + "</div>"
      : failed && bp.provision_error
        ? '<div class="notice notice-error" role="alert"><b>Provisioning failed.</b> ' + esc(bp.provision_error) + "</div>"
        : removing
          ? '<div class="notice notice-warn" role="status">Tearing down the server and stopping billing — this can take a moment.</div>'
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
          railRow("Version", bp.version ? "v" + bp.version : "—") +
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

  function loadSite(id) {
    currentSiteId = id;
    var box = $("#site-body");
    box.innerHTML = '<div class="loading">Loading site&hellip;</div>';
    Promise.all([
      api("GET", "/v1/sites/" + encodeURIComponent(id)),
      api("GET", "/v1/sites/" + encodeURIComponent(id) + "/deployments"),
      ensureFleet()
    ]).then(function (res) {
      var sr = res[0];
      if (sr.status === 404 || !sr.ok || !sr.data || !sr.data.site) {
        setBreadcrumb(null);
        box.innerHTML = '<div class="empty-state"><h2>Site not found</h2>' +
          '<p>It may have been removed. <a href="#sites">Back to sites</a>.</p></div>';
        return;
      }
      var site = sr.data.site;
      var deployments = (res[1].ok && res[1].data && res[1].data.deployments) || [];
      var bp = (res[2] || []).filter(function (x) { return String(x.id) === String(site.barkpark_id); })[0];
      var domain = (site.domains && site.domains[0]) || site.slug || site.name || "site";
      setBreadcrumb([
        { label: "Sites", href: "#sites" },
        bp ? { label: bp.name, href: "#instance/" + encodeURIComponent(bp.id) } : null,
        { label: domain }
      ].filter(Boolean));
      box.innerHTML = siteDetailHtml(site, bp, deployments, domain);
      var d = $("#site-deploy");
      if (d) d.addEventListener("click", function () { confirmDeploy(site, domain); });
    });
  }

  function siteDetailHtml(site, bp, deployments, domain) {
    var auto = site.github_webhook_configured;
    var repo = site.github_repo
      ? '<span class="mono">' + esc(site.github_repo) + (site.github_branch ? "@" + esc(site.github_branch) : "") + "</span>"
      : "—";
    var sub = (site.framework ? esc(site.framework) : "site") +
      (bp ? ' &middot; on <a href="#instance/' + esc(bp.id) + '">' + esc(bp.name) + "</a>" : "");
    var list = deployments.length
      ? deployments.map(deployRow).join("")
      : '<div class="empty-state"><h2>No deployments yet</h2><p>Trigger the first build with Deploy.</p></div>';
    return '<div class="detail-head"><div><h1>' + esc(domain) + "</h1>" +
        '<div class="fleet-url">' + sub + "</div></div>" +
        '<div class="fleet-badges"><button class="btn btn-primary btn-sm" id="site-deploy" type="button">Deploy</button></div></div>' +
      '<div class="detail-grid">' +
        '<div class="detail-main"><h2>Deployments</h2><div class="deploys">' + list + "</div></div>" +
        '<aside class="detail-rail"><h2>Details</h2>' +
          railRowCopy("Site ID", site.id) +
          railRow("Framework", site.framework || "—") +
          railRowHtml("Repository", repo) +
          railRowHtml("Auto-deploy", badge(auto ? "On" : "Manual", auto ? "online" : "unknown")) +
          railRow("Port", site.port != null ? String(site.port) : "—") +
          railRow("Scale", site.scale_mode || "—") +
          railRowCopy("Current", site.current_deployment_id || "—") +
          railRowPlain("Created", fmtWhen(site.inserted_at)) +
        "</aside>" +
      "</div>";
  }

  function deployRow(d) {
    var st = d.status || "queued";
    var ref = d.image_tag ? '<span class="mono">' + esc(shortId(d.image_tag)) + "</span>"
      : d.git_ref ? '<span class="mono">' + esc(d.git_ref) + "</span>"
      : '<span class="dim">' + esc(shortId(d.id)) + "</span>";
    var when = d.became_live_at || d.updated_at || d.inserted_at;
    var fail = (st === "failed" && d.failure_reason)
      ? '<div class="deploy-fail">' + esc(d.failure_reason) + "</div>" : "";
    return '<div class="deploy-row"><div class="deploy-main">' +
        '<div class="deploy-ref">' + ref + "</div>" +
        '<div class="deploy-meta">' + esc(fmtWhen(when)) + "</div>" + fail +
      "</div>" +
      '<span class="dep-pill dep-' + esc(st) + '">' + esc(cap(st)) + "</span></div>";
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

  function railRowHtml(k, htmlV) { return '<div class="rail-row"><span class="k">' + esc(k) + '</span><span class="v">' + htmlV + "</span></div>"; }
  function shortId(s) { s = String(s || ""); return s.length > 12 ? s.slice(0, 12) : s; }

  function startStep(n, title, sub, view, cta) {
    return '<div class="start-step"><span class="start-num">' + n + "</span>" +
      '<span class="start-main"><span class="start-title">' + esc(title) + "</span>" +
      '<span class="start-sub">' + esc(sub) + "</span></span>" +
      '<button class="btn btn-sm" data-goto="' + esc(view) + '">' + esc(cta) + " &rsaquo;</button></div>";
  }
  function wireStartSteps() {
    document.querySelectorAll("#fleet-body [data-goto]").forEach(function (b) {
      b.addEventListener("click", function () { location.hash = "#" + b.getAttribute("data-goto"); });
    });
  }

  // =========================================================== LAUNCH
  // Does this subscription entitle the team to launch? Mirrors the server's
  // Billing.entitled?/1: an active paid tier or admin "forever" launches; the
  // self-serve "trial" tier launches ONLY while it hasn't expired (its
  // current_period_end is still in the future); "free" / no sub does not.
  function launchEntitled(s) {
    if (!s || s.status !== "active" || s.plan === "free") return false;
    if (s.plan === "trial") {
      return !!s.current_period_end && new Date(s.current_period_end) > new Date();
    }
    // supporter / support_plus / forever — active is sufficient.
    return true;
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

    if (!subLoaded) loadSubscription().then(paint);
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
    if (!subLoaded) {
      box.innerHTML = '<div class="loading">Loading your plan&hellip;</div>';
      loadSubscription().then(renderRecommended);
      return;
    }

    // dwb-13: a team on its free trial gets a days-remaining badge + a
    // one-click upgrade CTA, ahead of the paid-plan state below.
    if (subCache && subCache.plan === "trial") {
      renderTrial(box);
      return;
    }

    if (subCache && subCache.status === "active" && subCache.plan !== "free") {
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

  // The active-subscriber state: their real plan, status and start date. There's
  // no self-serve change/cancel yet (no billing portal) — so we say so honestly
  // rather than render a button that does nothing.
  function renderCurrentPlan(box) {
    var sub = subCache;
    box.innerHTML =
      '<div class="card plan-card">' +
        '<div class="plan-head"><span class="plan-name">' + esc(planName(sub.plan)) + "</span>" +
          '<span class="plan-rec">Active</span></div>' +
        '<p class="plan-tagline">Your current subscription.</p>' +
        '<div class="plan-price">' + esc(priceFor(sub.plan)) + "<small>/mo</small></div>" +
        '<ul class="plan-feats">' +
          PLAN_FEATURES.map(function (f) { return '<li><span class="ck">✓</span>' + esc(f) + "</li>"; }).join("") +
        "</ul>" +
        '<p class="plan-meta dim">Status: ' + esc(cap(sub.status)) +
          (sub.started_at ? " &middot; since " + esc(fmtWhen(sub.started_at)) : "") + "</p>" +
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

  function loadSubscription() {
    return api("GET", "/v1/subscription").then(function (r) {
      subLoaded = true;
      subCache = (r.ok && r.data && r.data.subscription) || null;
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

  function handleLiveEvent(type) {
    if (!type) return;
    var v = currentView();
    if (type === "fleet") {
      fleetCache = null; // any cached fleet is now stale
      if (v === "fleet") loadFleet();
      else if (v === "instance") loadInstance(parseHash().id);
    } else if (type === "subscription") {
      loadSubscription().then(function () {
        if (v === "billing") renderRecommended();
        // The launch gate also reads subCache — if the user is sitting on the
        // launch view when their subscription activates, drop the gate live
        // instead of leaving a stale "subscription required" notice.
        if (v === "launch") renderLaunchGate();
      });
    } else if (type === "sites") {
      if (v === "sites") loadSites();
      else if (v === "instance") loadInstance(parseHash().id);
    } else if (type === "deployments") {
      if (v === "site") loadSite(parseHash().id);
    } else if (type === "audit") {
      // An audited mutation (delete / go-live / site create / member / token /
      // subscription) just landed an event; refresh Activity if it's open.
      if (v === "activity") loadActivity();
    }
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
      params[decodeURIComponent(kv.slice(0, i))] = decodeURIComponent(kv.slice(i + 1));
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

  // =========================================================== RENDER
  function render() {
    // A returning OAuth callback lands a session token on the fragment; consume
    // it BEFORE the logged-in/out decision so the user lands straight in.
    handleOAuthReturn();

    var s = session();
    if (!s || !s.token) {
      closeEvents();
      meCache = null;
      subCache = null;
      subLoaded = false;
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
      location.hash = "#fleet";
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
    $("#fleet-refresh").addEventListener("click", loadFleet);
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
      if (session() && session().token) applyRoute();
    });

    render();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
