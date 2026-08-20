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
// The accent identity is pre-seeded by: ?accent=evergreen|ember|fjord|charple|iris
//   (writes localStorage `bp_theme` + sets data-bp-theme before first paint —
//   mirrors index.html's identity pre-paint; theme MODE and accent IDENTITY are
//   two orthogonal switches). Unlocks non-evergreen headless accent shots (GR30).
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
  // Accent IDENTITY key — mirrors app.js's `var BP_THEME = "bp_theme"` and
  // index.html's identity pre-paint. Orthogonal to THEME_KEY (light/dark mode).
  var BP_THEME_KEY = "bp_theme";
  var BP_THEMES = ["evergreen", "ember", "fjord", "charple", "iris"];
  var SCENARIOS_URL = "/__preview__/scenarios.mjs";

  var params = new URLSearchParams(window.location.search || "");
  var scen = params.get("scen") || "empty";
  var theme = params.get("theme");
  var accent = params.get("accent");

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

  // 2b) Pre-seed the accent IDENTITY so [data-bp-theme] reflects ?accent= before
  //     first paint (app.js's initBpTheme reads bp_theme; the picker mirrors it).
  //     A bad id is ignored — evergreen is the bare-declaration fallback in CSS.
  try {
    if (accent && BP_THEMES.indexOf(accent) !== -1) {
      window.localStorage.setItem(BP_THEME_KEY, accent);
      document.documentElement.setAttribute("data-bp-theme", accent);
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

  // A structural copy of a fixture body, so nothing the app holds can be mutated
  // later by the shared state bag below. Fixtures are plain JSON; a body that
  // somehow is not round-trips to itself rather than throwing.
  function snapshot(body) {
    if (body === null || typeof body !== "object") return body;
    try { return JSON.parse(JSON.stringify(body)); } catch (e) { return body; }
  }

  var realFetch = window.fetch ? window.fetch.bind(window) : null;

  // 4c) cch-bl-mockjs-revoke-stateless — the per-boot mutable fixture bag.
  //     route(name, method, path, state) takes an OPTIONAL 4th arg; omitting it
  //     keeps every route stateless, which is exactly what made the browser
  //     preview report a successful revoke over a session list that never
  //     changed: the DELETE splice is guarded by `if (state)`, so the row
  //     vanished from the optimistic re-render and REAPPEARED on the refetch
  //     app.js fires right after the success toast. smoke.mjs already passes a
  //     bag (smoke.mjs:317); this is the browser twin, so both harnesses now
  //     answer the same destructive routes the same way. Per page load is the
  //     correct lifetime — a reload is a fresh fixture, a refetch is not.
  var fixtureState = {};

  window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || "";
    var method = (init && init.method) || (input && input.method) || "GET";
    var path;
    try { path = new URL(url, window.location.origin).pathname + new URL(url, window.location.origin).search; }
    catch (e) { path = url; }

    return scenariosReady.then(function (mod) {
      if (mod && typeof mod.route === "function") {
        var res = mod.route(scen, method, path, fixtureState);
        // route() hands back the LIVE state array by reference (sessionsOf
        // returns state.sessions itself), so a body handed to the app earlier
        // would mutate under it on the next revoke — a rendered list that
        // silently rewrites itself is the same lie one level down. Snapshot.
        if (res) return jsonResponse(res.status, snapshot(res.body));
      }
      // Not modelled: fall back to the network for real assets, else 404 JSON.
      if (realFetch && path.indexOf("/v1/") !== 0) return realFetch(input, init);
      return jsonResponse(404, { error: "not_found" });
    });
  };

  // 4b) gr-p5-account-2fa (GR58) — the ?modal=account seam.
  //     The account modal is opened by a CLICK, and scenarios reach screens by
  //     deepLink only, so the modal was structurally INVISIBLE to the accent x
  //     theme shot matrix. mock.js loads immediately BEFORE app.js (serve.mjs
  //     injects it), so it can install the hook capture first and then drive the
  //     REAL openAccountModal once /v1/me has painted the account chip. This is
  //     the browser twin of the seam smoke.mjs uses for the same modal.
  var appHooks = null;
  globalThis.__bpTestHook = function (h) { appHooks = h; };

  // Poll for a selector, then run fn(el). Every step of the 2FA drive below is
  // gated on a DOM element the REAL app painted, never on a timer — a fixed
  // sleep would race the mocked fetch and silently shoot the wrong phase.
  // REVIEW ADDENDUM — the give-up is visible IN THE FRAME, not only in console.
  // The original exhausted its 60 tries in silence and shot the DEFAULT phase
  // under a filename promising the 422 — the exact lie this drive exists to
  // kill, merely pushed one level down. The twin-sha assertion is a real
  // backstop, but it reports "these two files match", not "the drive never
  // arrived", and a reader chasing the wrong mechanism is precisely how
  // .modal-root stayed dead for five waves.
  //
  // console.error ALONE would not have closed this — verified, not assumed: I
  // broke the selector, re-shot, and the message never reached shoot.sh's log,
  // because Chrome's `--headless --screenshot` discards console entirely. The
  // only channel this harness actually captures is the PIXELS. So paint the
  // failure into the document: the PNG then states its own invalidity, and a
  // failed drive can never again be byte-identical to the twin it failed to
  // differ from — it fails LOUDLY instead of collapsing back into a collision.
  function driveGaveUp(sel) {
    console.error('[preview] 2FA drive gave up waiting for "' + sel + '"');
    var b = document.createElement("div");
    b.setAttribute("data-preview-drive-failed", sel);
    b.style.cssText =
      "position:fixed;left:0;right:0;top:0;z-index:2147483647;background:#b00020;" +
      "color:#fff;font:600 14px/1.5 system-ui,sans-serif;padding:12px 16px;text-align:left";
    b.textContent =
      'PREVIEW DRIVE FAILED — never found "' + sel + '". This shot shows the ' +
      "DEFAULT modal phase, NOT the state its filename promises. Do not trust it.";
    (document.body || document.documentElement).appendChild(b);
  }

  function whenPresent(sel, fn, tries) {
    tries = tries || 0;
    var el = document.querySelector(sel);
    if (el) { fn(el); return; }
    if (tries < 60) { window.setTimeout(function () { whenPresent(sel, fn, tries + 1); }, 50); return; }
    driveGaveUp(sel);
  }

  // GR76 — the account modal opens in its DEFAULT phase, which for
  // "account-modal-2fa-badcode" is the 2FA OFF state. The scenario's whole
  // subject (d.twoFactorConfirm → 422 invalid_otp) lives behind a form
  // SUBMISSION: mock.js only opened the modal, so the badcode PNG came out
  // byte-identical to its plain account-modal twin — 20 files whose names
  // promised a state they did not show, and a green count that certified them.
  // (Reproduced on origin/main: account-modal-light-1440-iris.png and
  // account-modal-2fa-badcode-light-1440-iris.png shared sha256
  // b3962224310076cd…) So drive the REAL enrollment through the REAL handlers —
  // #a2f-start → POST enroll → #a2f-otp → #a2f-confirm → POST confirm → 422 —
  // and let app.js paint its own #a2f-error. Nothing is faked into the DOM; the
  // shot shows exactly what a user typing a wrong code sees.
  function drive2faBadCode() {
    whenPresent("#a2f-start", function (start) {
      start.click();                       // POST /v1/account/two-factor/enroll
      whenPresent("#a2f-otp", function (otp) {
        otp.value = "000000";              // a code the 422 arm will reject
        whenPresent("#a2f-confirm", function (confirm) {
          confirm.click();                 // POST …/confirm → 422 invalid_otp
          // REVIEW ADDENDUM: assert the drive ARRIVED. Clicking Confirm is not
          // the same as rendering the rejection — app.js paints #a2f-error
          // (role=alert) only once the 422 lands. Without this the drive merely
          // ASSUMED its own subject; now a shot that never reached the 422 says
          // so by name instead of quietly photographing the enroll form.
          whenPresent("#a2f-error", function () {});
        });
      });
    });
  }

  if (params.get("modal") === "account") {
    window.addEventListener("load", function () {
      var tries = 0;
      (function waitForMe() {
        // Wait for the account chip to carry the real email — that is the
        // observable proof /v1/me resolved, so the identity row and the 2FA
        // on-state render from real data instead of the placeholder.
        var chip = document.getElementById("acct-email");
        var ready = chip && chip.textContent;
        // `>= 40`, not `> 40`: the increment below lives inside `tries++ < 40`,
        // so `tries` never exceeds 40 and the give-up branch was UNREACHABLE —
        // a scenario whose /v1/me does not land simply stopped, silently, with
        // no modal to photograph. Fixed with cch-w39-s2, which is the first
        // change to make that path worth reaching.
        if ((ready || tries >= 40) && appHooks && appHooks.openAccountModal) {
          appHooks.openAccountModal();
          // Scenario-specific post-open drive. Keyed on the scenario NAME, the
          // same convention shoot.sh uses to derive ?modal=account at all.
          if (scen === "account-modal-2fa-badcode") drive2faBadCode();
          return;
        }
        if (tries++ < 40) window.setTimeout(waitForMe, 50);
      })();
    });
  }

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
    accent: accent || "evergreen",
    push: function (type) {
      var payload = JSON.stringify({ type: type });
      streams.forEach(function (s) {
        if (typeof s.onmessage === "function") s.onmessage({ data: payload });
        (s._listeners.message || []).forEach(function (fn) { fn({ data: payload }); });
      });
    },
  };
})();
