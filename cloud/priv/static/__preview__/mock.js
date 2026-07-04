// mock.js — the browser side of the Cloud SPA preview harness (charter D63).
//
// Loaded as a CLASSIC <script> immediately BEFORE app.js (serve.mjs injects it;
// index.html is never edited). It stubs the two live-data seams — window.fetch
// and window.EventSource — so the SPA renders any committed scenario with zero
// backend, then hands control to the real app.js.
//
// The scenario is chosen by the URL:  ?scen=<name>  (default: empty)
// The theme is pre-seeded by:          ?theme=dark|light  (writes localStorage
//   before app.js's initTheme reads it — mirrors index.html's pre-paint key).
//
// Everything below runs SYNCHRONOUSLY except the fetch router, which lazily
// dynamic-import()s scenarios.mjs (the single source of truth, shared with
// smoke.mjs). That's safe: app.js only ever fetches AFTER boot, and it already
// awaits fetch's promise — so the import resolving a tick later is invisible.
(function () {
  "use strict";

  var SESSION_KEY = "bpcloud.session";
  var THEME_KEY = "bpcloud.theme";
  var INVITE_KEY = "bpcloud.invite";
  var SCENARIOS_URL = "/__preview__/scenarios.mjs";

  var params = new URLSearchParams(window.location.search || "");
  var scen = params.get("scen") || "empty";
  var theme = params.get("theme");

  // 1) Seed / clear the session synchronously so app.js's first render() lands on
  //    the right screen (logged-out scenario → the sign-in card).
  try {
    // Any scenario named loggedout* boots signed out (scenarios.mjs can't be
    // consulted here — the session must be decided synchronously, before app.js).
    if (scen.indexOf("loggedout") === 0) {
      window.localStorage.removeItem(SESSION_KEY);
      window.sessionStorage.removeItem(SESSION_KEY);
    } else {
      window.localStorage.setItem(
        SESSION_KEY,
        JSON.stringify({ token: "preview-session-token", team_id: "preview-team" }),
      );
    }
    // A parked invite token from a previously previewed scenario would hijack
    // this one's first render (the app's invite-resume is BY DESIGN sticky
    // across reloads) — scrub it so every scenario boots deterministic. The
    // invite scenarios re-park from their deepLink's ?token= on landing.
    window.sessionStorage.removeItem(INVITE_KEY);
  } catch (e) {}

  // 2) Pre-seed the theme so the toggle reflects ?theme= on first paint.
  try {
    if (theme === "dark" || theme === "light") {
      window.localStorage.setItem(THEME_KEY, theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  } catch (e) {}

  // 3) The scenarios module, imported once and cached. Any fetch awaits it.
  var scenariosReady = import(SCENARIOS_URL).then(function (mod) {
    // A typo'd ?scen= silently renders the default scenario — say so, loudly.
    if (mod && mod.SCENARIOS && !mod.SCENARIOS[scen]) {
      console.warn(
        '[preview] unknown scenario "' + scen + '" — rendering "' + mod.DEFAULT_SCENARIO +
        '". Known: ' + mod.SCENARIO_NAMES.join(", "),
      );
    }
    return mod;
  }).catch(function (err) {
    console.error("[preview] failed to load scenarios.mjs", err);
    return null;
  });

  // 4) A tiny Response-like wrapper matching exactly what app.js's api() reads:
  //    res.ok, res.status, res.headers.get("content-type"), res.json().
  function jsonResponse(status, body) {
    return {
      ok: status >= 200 && status < 300,
      status: status,
      headers: { get: function (h) { return String(h).toLowerCase() === "content-type" ? "application/json" : null; } },
      json: function () { return Promise.resolve(body); },
      text: function () { return Promise.resolve(JSON.stringify(body)); },
    };
  }

  var realFetch = window.fetch ? window.fetch.bind(window) : null;

  window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || "";
    var method = (init && init.method) || (input && input.method) || "GET";
    var path;
    try { path = new URL(url, window.location.origin).pathname + new URL(url, window.location.origin).search; }
    catch (e) { path = url; }

    return scenariosReady.then(function (mod) {
      if (mod && typeof mod.route === "function") {
        var res = mod.route(scen, method, path);
        if (res) return jsonResponse(res.status, res.body);
      }
      // Not modelled: fall back to the network for real assets, else 404 JSON.
      if (realFetch && path.indexOf("/v1/") !== 0) return realFetch(input, init);
      return jsonResponse(404, { error: "not_found" });
    });
  };

  // 5) Inert EventSource — the SPA opens one live stream at boot. It never fires
  //    on its own (a screenshot must be deterministic), but exposes a manual
  //    push hook for demos: `__preview.push("fleet")` drives handleLiveEvent.
  var streams = [];
  function PreviewEventSource(streamUrl) {
    this.url = streamUrl;
    this.readyState = 1; // OPEN — but silent
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this._listeners = {};
    streams.push(this);
  }
  PreviewEventSource.prototype.addEventListener = function (type, fn) {
    (this._listeners[type] = this._listeners[type] || []).push(fn);
  };
  PreviewEventSource.prototype.removeEventListener = function (type, fn) {
    var arr = this._listeners[type] || [];
    var i = arr.indexOf(fn);
    if (i !== -1) arr.splice(i, 1);
  };
  PreviewEventSource.prototype.close = function () {
    this.readyState = 2;
    var i = streams.indexOf(this);
    if (i !== -1) streams.splice(i, 1);
  };
  window.EventSource = PreviewEventSource;

  // Demo hook: push a live event type into every open stream (drives the SPA's
  // handleLiveEvent invalidation exactly as a real SSE tick would).
  window.__preview = {
    scenario: scen,
    push: function (type) {
      var payload = JSON.stringify({ type: type });
      streams.forEach(function (s) {
        if (typeof s.onmessage === "function") s.onmessage({ data: payload });
        (s._listeners.message || []).forEach(function (fn) { fn({ data: payload }); });
      });
    },
  };
})();
