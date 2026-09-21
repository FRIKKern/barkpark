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

  // 2c) The SCENARIO's own pre-paint seed — and it WINS over 2b (GR12).
  //
  //     Ordering is the whole fix (task-a0258bec59b256d7). A scenario declares
  //     `seedLocal: { bp_theme: "iris" }` in scenarios.mjs precisely to assert
  //     that a PERSISTED identity survives; the accent axis in 2b writes the
  //     SHOT's identity into that same key. Applied before 2b, the scenario is
  //     silently overwritten and identity-iris renders whatever ?accent= said —
  //     byte-identical to shell-root at all five accents, which is how the
  //     matrix built to prove GR12 came to disprove nothing. Applied AFTER, the
  //     scenario beats the axis. Do not reorder these two blocks, and do not
  //     move the accent write below this one "for symmetry": identity-seed.test.mjs
  //     reds on exactly that, at every accent.
  //
  //     The map arrives as bytes in the HTML, ahead of this file — serve.mjs
  //     injects it (see __preview__/seed-inject.mjs for why an import cannot
  //     work here). Absent (a page served by something else, or a scenario that
  //     seeds nothing) this block is a no-op and 2b stands.
  try {
    var seedLocal = window.__PREVIEW_SEED_LOCAL;
    if (seedLocal && typeof seedLocal === "object") {
      for (var sk in seedLocal) {
        if (!Object.prototype.hasOwnProperty.call(seedLocal, sk)) continue;
        window.localStorage.setItem(sk, String(seedLocal[sk]));
        // bp_theme also paints: app.js mirrors the key onto the root element at
        // boot, but the pre-paint attribute is what 2b set and what a shot of
        // the first frame captures, so the seed has to move it too.
        if (sk === BP_THEME_KEY && BP_THEMES.indexOf(String(seedLocal[sk])) !== -1) {
          document.documentElement.setAttribute("data-bp-theme", String(seedLocal[sk]));
        }
      }
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
  //     bag (the `fixtureState` literal — grep -n 'const fixtureState' smoke.mjs);
  //     this is the browser twin, so both harnesses now
  //     answer the same destructive routes the same way. Per page load is the
  //     correct lifetime — a reload is a fresh fixture, a refetch is not.
  var fixtureState = {};

  // ── RESIDUAL 1 OF 2 (cch-w34-bl-preview-scenario-for-a-failed-sites-read):
  //     A NEVER-SETTLING READ IS INEXPRESSIBLE HERE, AND IN smoke.mjs TOO.
  //     Every arm of scenarios.mjs's route() RESOLVES — there is no hang, no
  //     reject and no abort arm anywhere in that file — and this stub is TOTAL
  //     over that: it wraps route()'s answer in an already-resolved promise and
  //     falls through to a 404 JSON when nothing matched, so a request handed to
  //     it ALWAYS lands. smoke.mjs's stub does the same (`grep -n 'function
  //     fetchStub' smoke.mjs`). The consequence is a whole class of screen this
  //     harness cannot paint: the PENDING state — app.js's "Loading sites…" box,
  //     the operator console's "Checking operator access…" spinner, every
  //     card-level loading slot — held open, which is what a real control plane
  //     that has stopped answering does to a person. A STATUS CODE IS NOT A
  //     SUBSTITUTE: a 500 settles, and a settled failure is precisely the state
  //     a hung read is NOT. Reaching it would mean returning a promise nobody
  //     resolves, which changes route()'s contract for every caller and every
  //     committed scenario; it is deliberately NOT done here, and is recorded as
  //     a known limit rather than left to be rediscovered by the next reader.
  window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || "";
    var method = (init && init.method) || (input && input.method) || "GET";
    var path;
    try { path = new URL(url, window.location.origin).pathname + new URL(url, window.location.origin).search; }
    catch (e) { path = url; }

    // 4d) cch-w23-bl-real-hetzner-remediation-scenario — THE POSTED BYTES.
    //     route(name, method, path, state, body) takes an OPTIONAL 5th arg.
    //     Until it existed, route() answered from the scenario alone, so a
    //     fixture could model exactly ONE response per endpoint no matter what
    //     the app sent — which is why the preview corpus carried the server's
    //     azure remediation and, for hetzner, a string invented by the corpus.
    //     PARSED HERE, NOT IN route(): `init.body` is a transport-shaped value
    //     (app.js POSTs a JSON string) and scenarios.mjs must stay free of
    //     browser types. A body that is not readable JSON is passed as
    //     UNDEFINED rather than guessed at — the per-kind arm then answers its
    //     `_default`, which is an honest "we could not read what you sent",
    //     never a silent success.
    var parsedBody;
    var rawBody = (init && init.body) || null;
    if (typeof rawBody === "string") {
      try { parsedBody = JSON.parse(rawBody); } catch (e) { parsedBody = undefined; }
    } else if (rawBody && typeof rawBody === "object" &&
               !(typeof Blob !== "undefined" && rawBody instanceof Blob) &&
               !(typeof FormData !== "undefined" && rawBody instanceof FormData)) {
      parsedBody = rawBody;
    }

    return scenariosReady.then(function (mod) {
      if (mod && typeof mod.route === "function") {
        var res = mod.route(scen, method, path, fixtureState, parsedBody);
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
    console.error('[preview] drive gave up waiting for "' + sel + '"');
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
          whenPresent("#a2f-error", freezeShotSurface);
        });
      });
    });
  }

  // ── FREEZE THE SHOT (gr-p5r7-badcode-shot-nondeterministic) ────────────────
  // The drive above ends with the app's own error handler re-focusing the OTP
  // field (`grep -n 'a2f-otp' ../app.js` — the confirm-error branch re-seeds
  // and re-focuses it). A FOCUSED text input is the one thing in this harness
  // that is not a function of the DOM: it carries a BLINKING CARET on a wall
  // clock Chrome's --virtual-time-budget does not freeze, and the focus ring
  // arrives through a CSS transition whose phase depends on when the capture
  // poll happens to fire.
  //
  // MEASURED, not hypothesised. Two clean shoots of this scenario at
  // origin/main 2ff0d2c1a (Chrome for Testing 147.0.7727.15, headless shell):
  //   account-modal-2fa-badcode-light-1440-iris  c1350453… 395866 B
  //                                              7cfb2b44… 395120 B
  // while all four plain `account-modal` shots were byte-identical across the
  // same two runs. `magick compare` put EVERY differing pixel inside one
  // 228x88 device-pixel box — the #a2f-otp input — and the crops show the
  // caret present in one run and absent in the other. It is NOT the QR, which
  // is a byte-matched SVG (`grep -n 'THE GATE IS A BYTE-MATCH' ../app.js`).
  //
  // So freeze both sources at shoot time, in the PREVIEW harness only — app.js
  // is untouched, and a real user still gets a real caret. Focus is KEPT: the
  // shot must still show the focused, rejected field; only its blink phase and
  // its in-flight transitions are removed. Setting `transition:none` mid-
  // transition snaps the property to its final computed value, so what lands
  // is the settled frame rather than an arbitrary one.
  function freezeShotSurface() {
    if (document.querySelector("style[data-preview-shot-freeze]")) return;
    var s = document.createElement("style");
    s.setAttribute("data-preview-shot-freeze", "caret+transition+animation");
    s.textContent =
      "*,*::before,*::after{caret-color:transparent !important;" +
      "transition:none !important;animation:none !important}";
    (document.head || document.documentElement).appendChild(s);
  }

  // ── 4d) THE MODAL SEAM, AS A DECLARED FIELD (task-5ffdec2b609404bc) ───────
  // WHAT THIS REPLACED, and why it mattered far past tidiness. shoot.sh used to
  // derive the one modal query it knew from a scenario NAME:
  //
  //     case "$scen" in account-modal*) modal_q="&modal=account" ;;
  //
  // so the ONLY dialog any PNG in this corpus could contain was the account
  // modal, and a scenario could not ask for a different one at all. Re-derive
  // the cost yourself rather than believing a number written here:
  //
  //     grep -n 'openModal(' ../app.js
  //
  // 31 hits, of which three are not calls (two prose lines and the
  // `function openModal(html)` definition) => 28 call sites; the matrix reached
  // ONE. The name convention was the reason: not one accent, theme or width was
  // missing, the SEAM was.
  //
  // So scenarios.mjs carries `modal: "<driver>"` and shoot.sh passes it through
  // verbatim. Each driver below reaches its dialog the way a PERSON does — the
  // real click, the real keystroke — because a driver that calls the opener
  // directly photographs a dialog no user path is proven to reach.
  //
  // PRECEDENCE: THE SCENARIO'S FIELD WINS, and `?modal=` is the FALLBACK for a
  // scenario that declares none. This was the other way round for one commit
  // and it SILENTLY DOWNGRADED a dialog. hashchange-wiring.mjs, modal-oracle
  // .mjs and overflow-guard.mjs all append a flat `&modal=account` to whatever
  // scenario they are pointed at, which is exactly right for the many that
  // declare nothing — but `account-modal-2fa-badcode` declares
  // `account-2fa-badcode`, the SAME opener followed by the real enrollment
  // through to the 422. Letting the URL's generic `account` win replaced the
  // specific driver with the general one: the modal still opened, `.modal-card`
  // still painted, and only `#a2f-error` was missing — so nothing threw, no
  // drive-failed banner appeared, and overflow-guard.mjs sat at `expr-false`
  // 238 times and refused at exit 2 with a READINESS TIMEOUT that named no
  // cause. MEASURED, both directions, on the same URL: origin/main's mock.js
  // rendered #a2f-error (53731 B of DOM), the inverted precedence did not
  // (38696 B), and dropping `&modal=account` from the URL made this tree render
  // it again from the field alone.
  //
  // A URL that names a driver the scenario ALSO names is a no-op either way
  // (`account-modal` declares `account`, which is what all three instruments
  // append), so nothing that relied on the override loses anything: an override
  // only ever mattered where the field was empty, and there it still applies.
  var MODAL_DRIVERS = {
    // openAccountModal — the original seam, unchanged in behaviour.
    account: function () { openAccountModalThen(null); },
    // Same opener, then the REAL enrollment through to the 422. This was ALSO a
    // name convention (`if (scen === "account-modal-2fa-badcode")`) and it is
    // now the scenario's own declared driver, so a renamed scenario keeps its
    // drive instead of silently shooting the default phase.
    "account-2fa-badcode": function () { openAccountModalThen(drive2faBadCode); },
    // confirmRevokeToken — the confirm-sheet shape.
    "revoke-token": driveRevokeTokenSheet,
    // openCommandPalette — the `.modal-root:has(.cmdk)` arm.
    cmdk: driveCommandPalette,
    // openPinModal / openUpdateConflictModal (task-499cab525e65018b) — the two
    // call sites that had NO scenario at all until this table could be asked
    // for them by name.
    "pin-version": drivePinVersionForm,
    "update-conflict": driveUpdateConflictSheet,
  };

  function openAccountModalThen(after) {
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
        if (after) after();
        return;
      }
      if (tries++ < 40) { window.setTimeout(waitForMe, 50); return; }
      // Reaching here means the hook itself never arrived (the `>= 40` arm
      // above covers a slow /v1/me), which is a shot of the BARE SHELL under a
      // filename promising a dialog. Say so in the pixels.
      driveGaveUp("#acct-email + window.__bpTestHook");
    })();
  }

  // THE CONFIRM SHEET (app.js confirmRevokeToken). A real click on a real row's
  // Revoke, never a direct call: the button is bound by renderTokens()'s own
  // delegation, so calling the function would route around the wiring the shot
  // is supposed to certify. `.token-revoke[data-id]` and not `.token-row`: the
  // `tokens-revoke` fixture carries an ALREADY-REVOKED token that renders a row
  // with NO button, so a row poll can land before any button exists.
  function driveRevokeTokenSheet() {
    whenPresent(".token-revoke[data-id]", function (btn) {
      btn.click();
      // #token-revoke-go is the button that performs the irreversible DELETE —
      // i.e. the sheet that is up is THIS sheet, not merely some dialog.
      // freezeShotSurface for the same reason the badcode drive needs it: the
      // sheet arrives with a focus transition.
      whenPresent("#token-revoke-go", freezeShotSurface);
    });
  }

  // 4d) DEFECT-E (task-7bd507ea989ef248) — the declarative per-scenario DRIVE.
  //     Nine scenarios shot byte-identical to shell-instance in every one of
  //     their 20 cells. Neither cause the filing guessed was the real one: their
  //     data DOES reach route() and their screens DO exist. Two other causes —
  //     the fleet card mounts at the TAIL of the instance Overview column and
  //     shoot.sh shoots a 1000px VIEWPORT (below the fold), and the offload /
  //     verify fixtures are read only by pollOffloadWatch / runVerifyNow, i.e.
  //     behind a CLICK. The fold half is `shotHeight` (shoot.sh); THIS is the
  //     click half: `SCENARIOS[scen].drive`, an ordered step list
  //     (click/fill/await — documented above SCENARIOS in scenarios.mjs).
  //
  //     Two properties this inherits from the 2FA drive above, deliberately:
  //     every step waits on a selector the REAL app painted (never a timer, so
  //     no step can race the mocked fetch), and a step that never arrives paints
  //     driveGaveUp's red banner IN THE FRAME — so a drive that did not land
  //     announces itself in the PNG instead of collapsing back into the very
  //     byte-identical twin it exists to break. The table is in scenarios.mjs
  //     rather than here because smoke.mjs has to read it too (it imports the
  //     module; it cannot import this classic script) — that is what makes
  //     "this scenario is gated, and here is its gate" assertable in node.
  function driveStep(step, done) {
    var sel = step.click || step.fill || step.await;
    if (!sel) { done(); return; }
    whenPresent(sel, function (el) {
      if (step.click) el.click();
      else if (step.fill) el.value = step.value == null ? "" : String(step.value);
      done();
    });
  }

  function runDrive(steps, i) {
    if (!steps || i >= steps.length) return;
    driveStep(steps[i], function () { runDrive(steps, i + 1); });
  }

  // The modal seam has its own resolver below (startModalDrive, keyed on the
  // scenario's declared `modal` field — task-5ffdec2b609404bc retired the
  // shoot.sh `account-modal*` name convention); this one is keyed on the
  // scenario's `drive` field, so nothing has to be taught twice.
  window.addEventListener("load", function () {
    scenariosReady.then(function (mod) {
      var def = mod && mod.SCENARIOS && mod.SCENARIOS[scen];
      if (def && def.drive && def.drive.length) runDrive(def.drive, 0);
    });
  });

  // THE COMMAND PALETTE (app.js openCommandPalette). Dispatched as a REAL
  // Cmd+K keydown, so the shot passes through the handler's four no-op guards
  // (a modal already open, /new, /activate, no session) instead of around them.
  // Re-fired each tick until the palette answers, because the keydown listener
  // is installed during boot wiring and a single shot at first paint can lose
  // that race; the `root.hidden` guard is what stops it firing once the palette
  // is up. The palette focuses #cmdk-input, whose caret blinks on a wall clock
  // --virtual-time-budget does not freeze — hence freezeShotSurface.
  function driveCommandPalette() {
    var tries = 0;
    (function fire() {
      if (document.getElementById("cmdk-input")) { freezeShotSurface(); return; }
      var view = document.querySelector("section.view:not([hidden])");
      var root = document.getElementById("modal-root");
      if (view && root && root.hidden) {
        document.dispatchEvent(new KeyboardEvent("keydown", {
          key: "k", metaKey: true, bubbles: true, cancelable: true,
        }));
      }
      if (tries++ < 60) { window.setTimeout(fire, 50); return; }
      driveGaveUp("#cmdk-input");
    })();
  }

  // THE PIN FORM (app.js openPinModal). A real click on the Updates panel's own
  // `[data-au="pin"]` control, never a direct call: that control is bound by
  // wireUpdatePanel()'s delegation and the live `data-au` mount hook exists on
  // the AUTHORITY-GRANTED arm only (adminWriteControlHtml), so calling the
  // opener would photograph a dialog a plain member is never handed the button
  // for. `#pin-go` and not `.modal-card`: the panel's other three policy
  // controls (pause/resume/unpin) are `data-au` too and open no dialog at all,
  // so the submit button of the pin FORM is what proves this is the pin sheet.
  function drivePinVersionForm() {
    whenPresent('[data-au="pin"]', function (btn) {
      btn.click();
      // #pin-input takes focus on open, so the caret blinks on a wall clock
      // --virtual-time-budget does not freeze — same reason the other drives
      // freeze the surface.
      whenPresent("#pin-go", freezeShotSurface);
    });
  }

  // THE PIN-CONFLICT SHEET (app.js openUpdateConflictModal). TWO real clicks,
  // because that is how many a person makes: #inst-update opens
  // confirmUpdateInstance's generic confirm, and #update-go inside it is what
  // POSTs the self-update. The 409 the scenario's `instanceSelfUpdate` answers
  // is what REPLACES that confirm with this sheet — so the dialog is reached
  // through the real transport branch (updateConflict -> kind "pinned" ->
  // !opts.force), not by calling the opener with a hand-built copy object.
  // #update-force is the override button; it exists ONLY on a conflict copy
  // that carries a forceLabel, which is precisely what tells this sheet apart
  // from the confirm it replaced.
  function driveUpdateConflictSheet() {
    whenPresent("#inst-update", function (cta) {
      cta.click();
      whenPresent("#update-go", function (go) {
        go.click();
        whenPresent("#update-force", freezeShotSurface);
      });
    });
  }

  // The resolution order, stated once: the scenario's own declared field, then
  // the `?modal=` URL fallback (see PRECEDENCE above — the inverse of this
  // order is what downgraded account-modal-2fa-badcode to the plain account
  // modal). An unknown name is NOT ignored — a typo'd driver would otherwise
  // shoot the bare host screen under a filename promising a dialog, which is
  // exactly the class of lie the drive-failed banner exists to kill.
  function startModalDrive() {
    scenariosReady.then(function (mod) {
      var entry = mod && mod.SCENARIOS && mod.SCENARIOS[scen];
      var name = (entry && entry.modal) || params.get("modal") || "";
      if (!name) return;
      var drive = MODAL_DRIVERS[name];
      if (typeof drive !== "function") {
        driveGaveUp('a MODAL_DRIVERS entry named "' + name + '"');
        return;
      }
      drive();
    });
  }

  if (document.readyState === "complete") startModalDrive();
  else window.addEventListener("load", startModalDrive);

  // 5) Inert EventSource — the SPA opens one live stream at boot. It never fires
  //    on its own (a screenshot must be deterministic), but exposes a manual
  //    push hook for demos: `__preview.push("fleet")` drives handleLiveEvent.
  var streams = [];
  // ── RESIDUAL 2 OF 2 (cch-w34-bl-preview-scenario-for-a-failed-sites-read):
  //     SSE DEATH IS NOT CONTRASTABLE IN THIS HARNESS, and it needs a seam that
  //     does not exist. This stub reports `readyState = 1` — OPEN — from the
  //     moment it is constructed and then never fires anything on its own: no
  //     `open`, no `error`, no close the app did not ask for. `__preview.push()`
  //     below can make it SPEAK, but nothing anywhere can make it DIE, so a
  //     stream that has dropped and a stream that is merely quiet render
  //     BYTE-IDENTICALLY and no instrument in this repo can tell them apart.
  //     Separating them needs a `__preview.drop()` beside `__preview.push()` —
  //     roughly: set `readyState = 2`, fire `onerror` and the registered `error`
  //     listeners on every open stream — so that the console's live-tick
  //     degradation has a state to be asserted against. That seam is NOT added
  //     here; this comment is the record that it is missing, not a plan.
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
