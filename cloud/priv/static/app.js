/* ============================================================================
   Barkpark Cloud dashboard — vanilla SPA, no framework, no build step.
   State lives in localStorage ({token, team_id}); views switch on the hash.
   Every authed call sends `Authorization: Bearer <token>`; any 401 logs out.
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
  function session() {
    try { return JSON.parse(localStorage.getItem(STORE) || "null"); }
    catch (e) { return null; }
  }
  function setSession(s) { localStorage.setItem(STORE, JSON.stringify(s)); }
  function clearSession() { localStorage.removeItem(STORE); }

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

    api("POST", path, body, { noAuth: true }).then(function (r) {
      btn.disabled = false;
      if (r.ok && r.data && r.data.token) {
        setSession({ token: r.data.token, team_id: r.data.team_id || null });
        location.hash = "#fleet";
        render();
      } else {
        showAuthError(friendly(r.data, "Couldn't sign you in."));
      }
    });
  }

  // =========================================================== NAV / ROUTER
  var VIEWS = ["fleet", "launch", "billing", "providers"];

  function currentView() {
    var v = (location.hash || "").replace(/^#/, "");
    return VIEWS.indexOf(v) !== -1 ? v : "fleet";
  }

  function switchView(view) {
    VIEWS.forEach(function (v) {
      var sec = document.getElementById("view-" + v);
      if (sec) sec.hidden = v !== view;
      var link = document.querySelector('.nav-link[data-view="' + v + '"]');
      if (link) link.classList.toggle("is-active", v === view);
    });
    if (view === "fleet") loadFleet();
    if (view === "billing") renderTiers();
  }

  // =========================================================== FLEET
  function badge(label, kind, value) {
    return '<span class="badge"><span class="dot ' + esc(kind) + '"></span>' +
      esc(label) + '</span>';
  }

  function fleetRow(bp) {
    var provisioning = !bp.url;
    var urlHtml = provisioning
      ? '<div class="fleet-url provisioning">&mdash; provisioning</div>'
      : '<div class="fleet-url">' + esc(bp.url) + "</div>";

    var health = bp.health_status || "unknown";
    var healthLabel = health.charAt(0).toUpperCase() + health.slice(1);
    var agent = bp.agent_status || "offline";
    var agentLabel = agent.charAt(0).toUpperCase() + agent.slice(1);
    var version = bp.version ? '<span class="fleet-version">v' + esc(bp.version) + "</span>" : "";

    return '<div class="fleet-row">' +
      '<div class="fleet-main">' +
        '<div class="fleet-name">' + esc(bp.name) + "</div>" +
        urlHtml +
      "</div>" +
      '<div class="fleet-badges">' +
        version +
        badge(healthLabel, health) +
        badge(agentLabel, agent) +
      "</div>" +
    "</div>";
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
      if (!list.length) {
        body.innerHTML =
          '<div class="empty-state">' +
            "<h2>No Barkparks yet</h2>" +
            "<p>Launch your first managed instance to get started.</p>" +
            '<button class="btn btn-primary" id="empty-launch">Launch a Barkpark</button>' +
          "</div>";
        var b = $("#empty-launch");
        if (b) b.addEventListener("click", function () { location.hash = "#launch"; });
        return;
      }
      body.innerHTML = list.map(fleetRow).join("");
    });
  }

  // =========================================================== LAUNCH
  function submitLaunch(e) {
    e.preventDefault();
    hide($("#launch-error"));
    hide($("#launch-notice"));
    var name = $("#launch-name").value.trim();
    if (!name) { showFieldError("#launch-error", "A name is required."); return; }

    var btn = $("#launch-submit");
    btn.disabled = true;
    api("POST", "/v1/launch", { name: name }).then(function (r) {
      btn.disabled = false;
      if (r.status === 201) {
        $("#launch-name").value = "";
        location.hash = "#fleet";
        render(); // re-renders shell, lands on fleet (loadFleet shows the new row)
      } else if (r.status === 402) {
        show($("#launch-notice"));
        setText($("#launch-notice-text"),
          "You need an active subscription before launching.");
      } else if (r.status === 422) {
        showFieldError("#launch-error", friendly(r.data, "Couldn't launch."));
      } else {
        showFieldError("#launch-error", friendly(r.data, "Couldn't launch."));
      }
    });
  }
  function showFieldError(sel, msg) { var e = $(sel); setText(e, msg); show(e); }

  // =========================================================== BILLING
  var TIERS = [
    { plan: "free", name: "Free", price: "&euro;0", per: "", note: "Get started. No card required.", free: true },
    { plan: "starter", name: "Starter", price: "&euro;69", per: "/mo", note: "For a single small instance." },
    { plan: "pro", name: "Pro", price: "&euro;149", per: "/mo", note: "Production workloads, room to grow." },
    { plan: "business", name: "Business", price: "&euro;399", per: "/mo", note: "Multiple instances, more capacity." },
    { plan: "dedicated", name: "Dedicated", price: "&euro;999", per: "+", note: "Isolated infrastructure. Talk to us." }
  ];

  function renderTiers() {
    var grid = $("#billing-tiers");
    hide($("#billing-error"));
    grid.innerHTML = TIERS.map(function (t) {
      var btn = t.free
        ? '<button class="btn" disabled>Current plan</button>'
        : '<button class="btn btn-primary" data-plan="' + esc(t.plan) + '">Subscribe</button>';
      return '<div class="tier' + (t.free ? " tier-free" : "") + '">' +
        '<div class="tier-name">' + esc(t.name) + "</div>" +
        '<div class="tier-price">' + t.price + "<small>" + t.per + "</small></div>" +
        '<p class="tier-note">' + esc(t.note) + "</p>" +
        btn +
      "</div>";
    }).join("");

    grid.querySelectorAll("[data-plan]").forEach(function (b) {
      b.addEventListener("click", function () { subscribe(b.getAttribute("data-plan"), b); });
    });
    // The pricing-is-TBD note.
    if (!grid.querySelector(".tier-tbd")) {
      var note = document.createElement("p");
      note.className = "dim tier-tbd";
      note.style.cssText = "grid-column: 1 / -1; font-size: 12px; margin: 4px 2px 0;";
      note.textContent = "Pricing shown is placeholder — final numbers TBD.";
      grid.appendChild(note);
    }
  }

  function subscribe(plan, btn) {
    hide($("#billing-error"));
    btn.disabled = true;
    var prev = btn.textContent;
    btn.textContent = "Opening checkout…";
    api("POST", "/v1/billing/checkout", { plan: plan }).then(function (r) {
      if (r.status === 200 && r.data && r.data.checkout_url) {
        window.location = r.data.checkout_url;
      } else {
        btn.disabled = false;
        btn.textContent = prev;
        showFieldError("#billing-error", friendly(r.data, "Couldn't open checkout."));
      }
    });
  }

  // =========================================================== PROVIDERS
  function submitProvider(e) {
    e.preventDefault();
    hide($("#provider-error"));
    hide($("#provider-success"));
    var kind = $("#provider-kind").value;
    var token = $("#provider-token").value.trim();
    var label = $("#provider-label").value.trim();
    if (!token) { showFieldError("#provider-error", "An API token is required."); return; }

    var btn = $("#provider-submit");
    btn.disabled = true;
    var body = { kind: kind, token: token };
    if (label) body.label = label;

    api("POST", "/v1/providers", body).then(function (r) {
      btn.disabled = false;
      if (r.status === 201) {
        $("#provider-token").value = "";
        $("#provider-label").value = "";
        var p = (r.data && r.data.provider) || {};
        setText($("#provider-success-text"),
          "Connected " + (p.kind || kind) + (p.label ? " (" + p.label + ")" : "") + ".");
        show($("#provider-success"));
      } else {
        showFieldError("#provider-error", friendly(r.data, "Couldn't connect provider."));
      }
    });
  }

  // =========================================================== RENDER
  function render() {
    var s = session();
    if (!s || !s.token) {
      hide($("#app-shell"));
      show($("#auth-screen"));
      setAuthMode("login");
      $("#auth-email").focus();
      return;
    }
    hide($("#auth-screen"));
    show($("#app-shell"));

    // Account chip from whatever we know (team_id is opaque; show a short hint).
    var label = s.team_id ? "Team " + String(s.team_id).slice(0, 8) : "No team";
    setText($("#account-team"), label);
    setText($("#account-avatar"), (label[0] || "B").toUpperCase());

    if (!location.hash || VIEWS.indexOf(location.hash.replace(/^#/, "")) === -1) {
      location.hash = "#fleet";
    }
    switchView(currentView());
  }

  // =========================================================== WIRE-UP
  function init() {
    initTheme();

    // Auth.
    $("#tab-login").addEventListener("click", function () { setAuthMode("login"); });
    $("#tab-signup").addEventListener("click", function () { setAuthMode("signup"); });
    $("#auth-form").addEventListener("submit", submitAuth);
    wireSwitchLink();

    // Shell.
    $("#theme-toggle").addEventListener("click", toggleTheme);
    $("#logout").addEventListener("click", function () {
      clearSession();
      location.hash = "";
      render();
    });

    // Views.
    $("#fleet-refresh").addEventListener("click", loadFleet);
    $("#launch-form").addEventListener("submit", submitLaunch);
    $("#launch-to-billing").addEventListener("click", function () { location.hash = "#billing"; });
    $("#provider-form").addEventListener("submit", submitProvider);

    window.addEventListener("hashchange", function () {
      if (session() && session().token) switchView(currentView());
    });

    render();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
