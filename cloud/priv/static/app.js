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
  // Theme IDENTITY (data-bp-theme) is orthogonal to light/dark MODE (data-theme):
  // two independent switches (theme-system D23/D36). The pre-paint inline script
  // in index.html seeds data-bp-theme from this same key; the picker mutates it.
  var BP_THEME = "bp_theme";
  // The identity enum is GENERATED from design/themes/*.json (GR12) — the hand
  // list drifted once (charple emitted but omitted here → unreachable). The
  // switcher renders its <option>s from this at runtime, so a new theme file
  // reaches the picker the moment `node design/emit.mjs --write` runs. Hand edits
  // red design/check.mjs Part A. Regenerate: node design/emit.mjs --write.
  var BP_THEMES = [
    /* BEGIN GENERATED: bp-theme ids (design/themes/*.json via design/emit.mjs — node design/emit.mjs --write; do not hand-edit) */
    "evergreen", "charple", "ember", "fjord", "iris"
    /* END GENERATED: bp-theme ids */
  ];

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
    // Team switcher: pin every request to the chosen team. The server honors
    // it only when the caller is a member (stale values degrade to primary).
    var teamPin = localStorage.getItem("bp.active-team");
    if (teamPin && !opts.noAuth) headers["x-barkpark-team"] = teamPin;

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
    // Two-factor challenge (POST /v1/auth/two-factor-challenge) — DISTINCT copy
    // so a 401 (wrong code, retryable) never reads like a 429 (limiter tripped).
    invalid_code: "That code didn't match. Authenticator codes rotate every 30 seconds — enter the current one, or use a recovery code.",
    rate_limited: "Too many attempts. Wait a moment, then try the code again.",
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

  // Pure: given the focusables of the open dialog (DOM order), the currently
  // active element, and the Tab direction, which element must receive focus to
  // keep the trap closed? null = focus may move naturally (mid-list). An
  // active element that is not in the list (focus escaped, or sits on a
  // non-tabbable node) snaps back to the first focusable. Empty list → null
  // (the caller pins focus by preventDefault'ing with nowhere to send it).
  function trapTarget(f, active, shiftKey) {
    f = f || [];
    if (f.length === 0) return null;
    var first = f[0], last = f[f.length - 1];
    if (f.indexOf(active) === -1) return first;
    if (shiftKey && active === first) return last;
    if (!shiftKey && active === last) return first;
    return null;
  }

  // Keep Tab inside the open dialog. Trapping the whole `.modal-card` includes
  // the close (×) button, so focus can never fall back onto the inert shell.
  function trapModalTab(e) {
    if (e.key !== "Tab") return;
    var card = document.querySelector("#modal-root .modal-card");
    if (!card) return;
    var f = focusablesIn(card);
    if (f.length === 0) { e.preventDefault(); return; } // zero-focusable modal: pin, don't crash
    var target = trapTarget(f, document.activeElement, e.shiftKey);
    if (target) { e.preventDefault(); target.focus(); }
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

  // =========================================================== CONFIRM MODAL
  // The ONE confirm grammar for every risky action, both tiers (charter
  // decision 5 — the SPA twin of the CLI's hzConfirmDestroy):
  //   mutate  — title + ONE honest consequence sentence + Confirm/Cancel.
  //   destroy — consequence LIST + a typed-resource-name input; Confirm stays
  //             disabled until the typed echo matches exactly. (Built now,
  //             consumed by the destroy sweeps of later waves.)
  // The state machine is PURE (exported via __bpTestHook); openConfirmModal()
  // is the thin DOM wrapper on the openModal primitive, which already owns the
  // focus trap, Escape-to-dismiss, and restore-focus-on-close.
  //
  // Failure contract (decision 25): a failed confirm never dies into a toast —
  // the modal renders the human sentence inline and the primary button MORPHS
  // into exactly one recovery action (retry, or refresh-and-close).

  // opts: { tier: "mutate"|"destroy", title, consequence | consequences[],
  //         resourceName (destroy), confirmLabel }. Total over junk.
  function confirmModalInit(opts) {
    opts = opts || {};
    var tier = opts.tier === "destroy" ? "destroy" : "mutate";
    var consequences = [];
    if (Array.isArray(opts.consequences)) {
      consequences = opts.consequences.map(function (c) { return String(c); });
    } else if (opts.consequence != null) {
      consequences = [String(opts.consequence)];
    }
    return {
      tier: tier,
      title: String(opts.title || "Are you sure?"),
      consequences: consequences,
      resourceName: tier === "destroy" ? String(opts.resourceName || "") : null,
      confirmLabel: String(opts.confirmLabel || "Confirm"),
      typed: "",
      phase: "open", // open | busy | error | done | closed
      error: null,
    };
  }

  // Typed-echo gate: mutate is always armed; destroy requires the typed text to
  // equal the resource name EXACTLY (no trim, no case-folding — the echo is the
  // proof of attention, same contract as the CLI's typed-name prompt).
  function confirmModalTypedMatch(state) {
    if (!state) return false;
    if (state.tier !== "destroy") return true;
    return !!state.resourceName && state.typed === state.resourceName;
  }

  // May the Confirm action fire right now? (error phase stays armed so a
  // recovery retry can re-enter busy without re-typing the echo.)
  function confirmModalArmed(state) {
    return !!state && (state.phase === "open" || state.phase === "error") &&
      confirmModalTypedMatch(state);
  }

  // Pure reducer. Events: {type:"type",value} {type:"confirm"} {type:"fail",
  // message} {type:"succeed"} {type:"dismiss"}. Unknown events / illegal
  // transitions return the state unchanged — total, never throws.
  function confirmModalReduce(state, ev) {
    if (!state || !ev) return state;
    var next = Object.assign({}, state);
    if (ev.type === "type") {
      if (state.phase !== "open" && state.phase !== "error") return state;
      next.typed = String(ev.value == null ? "" : ev.value);
      return next;
    }
    if (ev.type === "confirm") {
      if (!confirmModalArmed(state)) return state;
      next.phase = "busy";
      next.error = null;
      return next;
    }
    if (ev.type === "fail") {
      if (state.phase !== "busy") return state;
      next.phase = "error";
      next.error = String(ev.message || "That didn't work.");
      return next;
    }
    if (ev.type === "succeed") {
      if (state.phase !== "busy") return state;
      next.phase = "done";
      return next;
    }
    if (ev.type === "dismiss") {
      next.phase = "closed";
      return next;
    }
    return state;
  }

  // Pure render of the modal body for an initial state. The destroy tier's
  // Confirm ships disabled (armed only by the typed echo); mutate ships live.
  function confirmModalHtml(state) {
    var h = '<h2 class="modal-title" id="modal-title">' + esc(state.title) + "</h2>";
    if (state.tier === "destroy") {
      h += '<ul class="cm-consequences">' +
        state.consequences.map(function (c) { return "<li>" + esc(c) + "</li>"; }).join("") +
        "</ul>" +
        '<div class="field cm-typed-field">' +
          '<label class="label" for="cm-typed">Type <span class="cm-name">' + esc(state.resourceName) + "</span> to confirm</label>" +
          '<input class="form-input" id="cm-typed" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" />' +
        "</div>";
    } else if (state.consequences.length) {
      h += '<p class="modal-sub cm-consequence">' + esc(state.consequences[0]) + "</p>";
    }
    h += '<div class="cm-error" id="cm-error" role="alert" hidden>' +
      '<p class="cm-error-msg" id="cm-error-msg"></p></div>';
    h += '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
      (state.tier === "destroy"
        ? '<button class="btn btn-danger" type="button" id="cm-confirm" disabled>' + esc(state.confirmLabel) + "</button>"
        : '<button class="btn btn-primary" type="button" id="cm-confirm">' + esc(state.confirmLabel) + "</button>") +
      "</div>";
    return h;
  }

  // DOM wrapper. opts additionally takes busyLabel and onConfirm(ctl); ctl is
  //   ctl.busy(label?)                     — re-enter the working state (retry)
  //   ctl.succeed()                        — close the modal, focus restored
  //   ctl.fail(message, recoveryLabel, fn) — inline sentence + ONE recovery
  // Escape / backdrop / Cancel dismissal stays available in every phase (a
  // hung request must never imprison the operator); handlers guard on
  // closeModal having cleared the body.
  function openConfirmModal(opts) {
    opts = opts || {};
    var state = confirmModalInit(opts);
    openModal(confirmModalHtml(state));
    var confirmBtn = $("#cm-confirm");
    if (!confirmBtn) return;
    var typedInput = $("#cm-typed");
    var errBox = $("#cm-error");
    var errMsg = $("#cm-error-msg");
    var mode = "confirm"; // what the primary button does: confirm | recover
    var recover = null;

    var ctl = {
      busy: function (label) {
        mode = "confirm";
        recover = null;
        state = confirmModalReduce(state, { type: "confirm" });
        hide(errBox);
        confirmBtn.disabled = true;
        confirmBtn.textContent = label || opts.busyLabel || "Working…";
      },
      succeed: function () {
        state = confirmModalReduce(state, { type: "succeed" });
        // The operator may have Escape/Cancel-dismissed while the request was
        // in flight — and might have opened a DIFFERENT modal since. Only close
        // when OUR button is still mounted, so a stale settle can never shut an
        // unrelated dialog.
        if (confirmBtn.isConnected !== false) closeModal();
      },
      fail: function (message, recoveryLabel, onRecover) {
        state = confirmModalReduce(state, { type: "fail", message: message });
        if (confirmBtn.isConnected === false) return; // dismissed mid-flight: nothing to morph
        mode = "recover";
        recover = onRecover || null;
        if (errMsg) setText(errMsg, state.error || String(message || ""));
        show(errBox);
        confirmBtn.disabled = false;
        confirmBtn.textContent = recoveryLabel || "Try again";
        confirmBtn.focus();
      },
    };

    if (typedInput) {
      typedInput.addEventListener("input", function () {
        state = confirmModalReduce(state, { type: "type", value: typedInput.value });
        if (mode === "confirm") confirmBtn.disabled = !confirmModalArmed(state);
      });
    }

    confirmBtn.addEventListener("click", function () {
      if (mode === "recover") {
        var r = recover;
        recover = null;
        if (r) r(ctl);
        return;
      }
      if (!confirmModalArmed(state)) return;
      ctl.busy();
      if (typeof opts.onConfirm === "function") opts.onConfirm(ctl);
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
      mark: "H", cls: "brand-hetzner", available: true, fields: "token",
      console: "https://console.hetzner.cloud/",
      blurb: "Connect to your Hetzner Cloud account to deploy instances." },
    { kind: "azure", name: "Microsoft Azure", sub: "Deploy on your own Azure subscription",
      mark: "Az", cls: "brand-azure", available: true, fields: "azure",
      console: "https://portal.azure.com/",
      blurb: "Connect an Azure service principal so Barkpark can provision on your subscription." },
    { kind: "digitalocean", name: "DigitalOcean", sub: "Coming soon", mark: "DO", cls: "brand-do", available: false },
    { kind: "aws", name: "AWS", sub: "Coming soon", mark: "aws", cls: "brand-aws", available: false },
    { kind: "vultr", name: "Vultr", sub: "Coming soon", mark: "V", cls: "brand-vultr", available: false }
  ];

  // Azure's service-principal is a four-tuple (Decision 4 — the single
  // encrypted_token credential home holds it as a JSON blob). The field order +
  // copy mirror the Azure Portal → App registrations surface so an operator
  // copies each value straight across; the router keeps ONLY these four keys
  // (router.ex azure_credential_blob), so stray input never persists.
  var AZURE_FIELDS = [
    { key: "tenant_id", label: "Directory (tenant) ID", secret: false, placeholder: "00000000-0000-0000-0000-000000000000" },
    { key: "client_id", label: "Application (client) ID", secret: false, placeholder: "00000000-0000-0000-0000-000000000000" },
    { key: "client_secret", label: "Client secret", secret: true, placeholder: "••••••••••••••••" },
    { key: "subscription_id", label: "Subscription ID", secret: false, placeholder: "00000000-0000-0000-0000-000000000000" }
  ];

  // ---- provider/launch pure helpers (S7) — every one is exported through the
  // __bpTestHook block at the tail and asserted in __app.test.mjs.

  // The provider identity chip (IDENTITY, never status — Decision 7). Returns ""
  // for an unknown/absent kind so a fleet row NEVER fakes a provider it doesn't
  // have: the chip only renders once the payload actually carries `provider`.
  // Static class strings per kind (no dynamic head) so the CSS checker resolves
  // every token; the tint rides --provider-<kind> via the modifier class.
  function providerChipHtml(kind) {
    if (kind === "hetzner")
      return '<span class="provider-chip provider-chip--hetzner">' +
        '<span class="provider-mark" aria-hidden="true"></span>Hetzner</span>';
    if (kind === "azure")
      return '<span class="provider-chip provider-chip--azure">' +
        '<span class="provider-mark" aria-hidden="true"></span>Azure</span>';
    return "";
  }

  // Instance-lifecycle glyph class (STATUS). Maps one of the seven canonical
  // states (S4 tokens) to its `.bp-inst--<state>` class, "" for anything else so
  // an unknown state degrades to the untinted glyph rather than a fabricated hue.
  var INSTANCE_LIFECYCLE = ["provisioning", "live", "degraded", "stopped", "archived", "decommissioned", "adopted"];
  function instanceLifecycleClass(state) {
    return INSTANCE_LIFECYCLE.indexOf(state) !== -1 ? "bp-inst--" + state : "";
  }

  // ---- S11b lifecycle-console pure helpers (azure-hetzner hosting) ------------
  // The console operates the instance through a conduit-driven action row. Every
  // rule here is a node-pinned pure function; the DOM mount (wireLifecycleActions)
  // is browser-verified. Charter decisions 20-22 / roadmap S11b.

  // Human labels for the seven S4 lifecycle-token states. `decommissioned` is an
  // in-flight teardown from the operator's seat, so it reads "Decommissioning".
  var LIFECYCLE_PILL_LABEL = {
    provisioning: "Provisioning", live: "Live", degraded: "Degraded",
    stopped: "Stopped", archived: "Archived", decommissioned: "Decommissioning",
    adopted: "Adopted",
  };

  // Map the client-derived instance state (instanceLifecycle booleans, the same
  // fold the fleet row and header read) onto ONE canonical S4 lifecycle-token
  // state — NO server lifecycle_state column this wave. removing wins first
  // (a teardown in flight is the display truth), then the error/paused folds.
  // "" for a state we can't place, so instanceLifecycleClass degrades to no tint.
  function lifecyclePillState(bp) {
    var lc = instanceLifecycle(bp || {});
    if (lc.removing) return "decommissioned";
    if (lc.failed || lc.removeFailed) return "degraded";
    if (lc.suspended) return "stopped";
    if (lc.provisioning) return "provisioning";
    if (lc.live) return "live";
    return "";
  }

  // The lifecycle pill descriptor for a box: token state + its label + the S4
  // `.bp-inst--<state>` class. Shared by the fleet row and the action-row model
  // so the two never disagree about which hue a state wears.
  function lifecyclePill(bp) {
    var state = lifecyclePillState(bp);
    return { state: state, label: LIFECYCLE_PILL_LABEL[state] || "Unknown", cls: instanceLifecycleClass(state) };
  }

  // Region · size meta for a fleet row (blank-tolerant — pre-S6 rows carry null
  // region/server_type). Renders nothing when both are absent so an old row never
  // shows an empty "·". Presentation only; the values are server-stamped slugs.
  function fleetInfraLine(bp) {
    bp = bp || {};
    var parts = [];
    if (bp.region) parts.push(String(bp.region));
    if (bp.server_type) parts.push(String(bp.server_type));
    return parts.length ? '<div class="fleet-infra">' + esc(parts.join(" · ")) + "</div>" : "";
  }

  // The instance name a lifecycle CLI chip / destroy-echo names. Stable slug/id
  // preferred; falls back to the display name so the chip is never empty.
  function lifecycleCliName(bp) {
    bp = bp || {};
    return String(bp.name || bp.slug || bp.id || "");
  }

  // Whether the workspace shows the lifecycle action row at all. It owns teardown
  // wherever the old bare Remove button used to sit (live/host boxes + a failed
  // provision), and stays hidden for the transient in-flight states the header
  // already narrates (removing → nothing to do; removeFailed → header's Retry
  // removal; clean provisioning → the timeline is the surface).
  function showLifecycleRow(bp) {
    var lc = instanceLifecycle(bp || {});
    return !lc.removing && !lc.removeFailed && (!!(bp && bp.host) || lc.failed);
  }

  // The lifecycle verbs the console surfaces, in operator order (destructive last).
  // decommission is the ONE console-wired verb — every other verb degrades to a
  // CLI affordance (capability true) or a disabled control (capability false).
  var LIFECYCLE_VERBS = [
    { verb: "archive", label: "Archive" },
    { verb: "resurrect", label: "Resurrect" },
    { verb: "adopt", label: "Adopt" },
    { verb: "audit", label: "Audit" },
    { verb: "pause", label: "Pause" },
    { verb: "decommission", label: "Decommission" },
  ];

  // The always-live decommission action: it drives the console's own deprovision
  // (the existing Remove/DELETE path) and predates the capability conduit, so it
  // stays wired even when the payload is missing or claims decommission=false.
  function decommissionAction(bp) {
    return { verb: "decommission", label: "Decommission", mode: "live", resourceName: lifecycleCliName(bp) };
  }

  // Pure model for the lifecycle action row from the /v1/providers/capabilities
  // conduit payload {providers:{kind:{tier,capabilities,gaps}}, default_gap} and
  // the instance. Three honest degrade paths, none hidden / dead / faked:
  //   capPayload === undefined → loading shell (decommission live from frame 1)
  //   payload null/malformed / kind missing → "capabilities unavailable" + Retry
  //   provider tier === "dev"  → an fake/dev box we don't operate from the console
  // A wired provider yields one action per verb: capability true → CLI affordance,
  // capability false → disabled with the SERVER-OWNED gap reason (never invented;
  // falls back only to the payload's own default_gap).
  function lifecycleActionsModel(capPayload, bp) {
    bp = bp || {};
    var kind = bp.provider || "hetzner";
    var pill = lifecyclePill(bp);
    var decommission = decommissionAction(bp);

    if (capPayload === undefined) {
      return { kind: kind, provider: bp.provider || null, pill: pill, available: false,
        loading: true, retry: false, devTier: false, actions: [decommission] };
    }

    var providers = capPayload && typeof capPayload === "object" ? capPayload.providers : null;
    var entry = providers && typeof providers === "object" ? providers[kind] : null;
    var devTier = !!(entry && entry.tier === "dev");

    if (!entry || devTier) {
      return { kind: kind, provider: bp.provider || null, pill: pill, available: false,
        loading: false, retry: !devTier, devTier: devTier, actions: [decommission] };
    }

    var caps = entry.capabilities || {};
    var gaps = entry.gaps || {};
    var defaultGap = capPayload && typeof capPayload.default_gap === "string" ? capPayload.default_gap : "";
    var actions = LIFECYCLE_VERBS.map(function (v) {
      if (v.verb === "decommission") return decommission;
      if (caps[v.verb] === true) {
        return { verb: v.verb, label: v.label, mode: "cli",
          cli: "bp cloud instance " + v.verb + " " + lifecycleCliName(bp) };
      }
      var reason = typeof gaps[v.verb] === "string" && gaps[v.verb].trim() !== "" ? gaps[v.verb] : defaultGap;
      return { verb: v.verb, label: v.label, mode: "disabled", reason: reason };
    });
    return { kind: kind, provider: bp.provider || null, pill: pill, available: true,
      loading: false, retry: false, devTier: false, actions: actions };
  }

  // Pure optimistic-transition reducer for the live decommission: applies the
  // decommissioned pill immediately (remembering the prior pill), and rolls back
  // to it verbatim on failure. The DOM (runDecommission) mirrors this exactly —
  // the model is what the harness proves.
  function lifecycleOptimistic(model, ev) {
    if (!model) return model;
    if (ev === "decommission") {
      var next = instanceLifecycleClass("decommissioned");
      return Object.assign({}, model, {
        pill: { state: "decommissioned", label: LIFECYCLE_PILL_LABEL.decommissioned, cls: next },
        _rollback: model.pill,
      });
    }
    if (ev === "rollback") {
      if (!model._rollback) return model;
      var restored = Object.assign({}, model, { pill: model._rollback });
      delete restored._rollback;
      return restored;
    }
    return model;
  }

  // Pure render of ONE action into its honest control.
  function lifecycleActionHtml(a) {
    if (!a) return "";
    if (a.mode === "live") {
      return '<button class="btn btn-danger btn-sm" type="button" data-life-verb="' + esc(a.verb) +
        '" data-life-name="' + esc(a.resourceName || "") + '">' + esc(a.label) + "</button>";
    }
    if (a.mode === "cli") {
      // Capability true but console-unwired: the verb label + the exact command
      // chip. The "via the bp CLI" caption is rendered ONCE at the row level
      // (lifecycleActionRowHtml) instead of repeated per verb — density cut.
      return '<div class="inst-life-cli"><span class="inst-life-verb">' + esc(a.label) + "</span>" +
        cliChipHtml(a.cli) + "</div>";
    }
    // Capability false: disabled control carrying the SERVER-OWNED gap reason.
    // JS never invents copy — an absent reason shows the label alone.
    return '<div class="inst-life-disabled"><button class="btn btn-sm" type="button" disabled' +
      (a.reason ? ' title="' + esc(a.reason) + '"' : "") + ">" + esc(a.label) + "</button>" +
      (a.reason ? '<span class="inst-life-reason">' + esc(a.reason) + "</span>" : "") + "</div>";
  }

  // Pure render of the whole action row from its model.
  function lifecycleActionRowHtml(model) {
    if (!model) return "";
    // The label sits in its own span so it stays neutral (--text) while the dot
    // carries the S4 state hue (the model.pill.cls bp-inst--<state> tints color,
    // the dot reads it through currentColor) — mirrors .status-pill.
    var pill = '<span class="inst-life-pill ' + model.pill.cls + '">' +
      '<span class="inst-life-dot" aria-hidden="true"></span>' +
      '<span class="inst-life-label">' + esc(model.pill.label) + "</span></span>";

    var status = "";
    if (model.loading) {
      status = '<span class="inst-life-note">Checking capabilities&hellip;</span>';
    } else if (!model.available) {
      status = '<span class="inst-life-note' + (model.retry ? " inst-life-note--warn" : "") + '">' +
        esc(model.devTier
          ? "Developer-tier provider — operate it with the bp CLI."
          : "Capabilities unavailable.") + "</span>" +
        (model.retry ? '<button class="btn btn-ghost btn-sm" type="button" data-life-retry>Retry</button>' : "");
    }

    // One "via the bp CLI" caption for the whole row when any verb is a CLI
    // affordance — replaces the per-verb repetition (four → one).
    var hasCli = (model.actions || []).some(function (a) { return a && a.mode === "cli"; });
    var via = hasCli ? '<div class="inst-life-via">via the bp CLI</div>' : "";

    return '<div class="inst-life-head">' + pill +
      (status ? '<div class="inst-life-status">' + status + "</div>" : "") + "</div>" +
      '<div class="inst-life-actions">' + model.actions.map(lifecycleActionHtml).join("") + "</div>" +
      via;
  }

  // ---- S14 portable-archives pure helpers (azure-hetzner hosting) ------------
  // The console makes a team's archived-instance bundles VISIBLE (charter S14 /
  // D39). GET /v1/archives serves the manifests straight from object storage;
  // this is a pure PROJECTION of that envelope — the console does NOT execute
  // resurrect this wave, it hands the operator the exact CLI command (the S11b
  // CLI-affordance precedent). Every rule is a node-pinned pure function; the
  // DOM mount (loadArchives) is browser-verified.

  // Pure model for the archives panel from the GET /v1/archives payload
  // {ok, archives:[{fqdn, slug, source_provider, created_at, bundle_ref,
  // spec:{region,server_type}}]}. Four honest states, none faked:
  //   undefined            → loading shell (fetch in flight)
  //   {ok:false, error}    → error state carrying the SERVER-OWNED message + Retry
  //   {ok:true, archives:[]} → true empty (the store answered; no bundles yet)
  //   {ok:true, archives}  → one row per bundle, each with a copy-paste resurrect
  //                          command `bp cloud instance resurrect <slug> --provider <kind>`
  // Order is the server's (newest-first); this stays a faithful projection.
  function archivesModel(payload) {
    if (payload === undefined) return { loading: true, error: false, rows: [] };
    if (!payload || payload.ok !== true) {
      // Server-owned copy ONLY when the server explicitly said {ok:false,error}
      // (the 502 degrade). A client-side transport failure (api()'s
      // {error:"network_error"} sentinel, no ok:false) gets a generic client
      // message — never a raw internal token surfaced as if the server sent it.
      var serverMsg = payload && payload.ok === false && typeof payload.error === "string" &&
        payload.error.trim() !== "" ? payload.error : null;
      return { loading: false, error: true,
        message: serverMsg || "Couldn't load your archives — try again shortly.", rows: [] };
    }
    var archives = Array.isArray(payload.archives) ? payload.archives : [];
    var rows = archives.map(function (a) {
      a = a || {};
      var kind = String(a.source_provider || "");
      var slug = String(a.slug || "");
      var spec = a.spec && typeof a.spec === "object" ? a.spec : {};
      return {
        fqdn: String(a.fqdn || slug || ""),
        slug: slug,
        providerKind: kind,
        createdAt: String(a.created_at || ""),
        createdLabel: a.created_at ? relTime(a.created_at) : "",
        region: String(spec.region || ""),
        serverType: String(spec.server_type || ""),
        bundleRef: String(a.bundle_ref || ""),
        // The copy-paste affordance — empty when we can't name a slug (never a
        // command that would fail on paste).
        resurrectCommand: slug
          ? ("bp cloud instance resurrect " + slug + (kind ? " --provider " + kind : ""))
          : "",
      };
    });
    return { loading: false, error: false, rows: rows };
  }

  // One archive row: identity (fqdn + provider chip), when, region · size, and
  // the resurrect CLI chip. Provider chip is IDENTITY only (Decision 7); it
  // renders nothing for an unknown kind rather than faking one.
  function archiveRowHtml(row) {
    if (!row) return "";
    var meta = [];
    if (row.region) meta.push(esc(row.region));
    if (row.serverType) meta.push(esc(row.serverType));
    var metaLine = meta.length ? '<div class="archive-meta">' + meta.join(" · ") + "</div>" : "";
    var when = row.createdLabel
      ? '<span class="archive-when" title="' + esc(row.createdAt) + '">' + esc(row.createdLabel) + "</span>"
      : "";
    return '<div class="archive-row">' +
      '<div class="archive-id">' +
        '<span class="archive-fqdn">' + esc(row.fqdn) + "</span>" +
        providerChipHtml(row.providerKind) + when +
        metaLine +
      "</div>" +
      (row.resurrectCommand
        ? '<div class="archive-resurrect">' +
            '<button class="btn btn-primary btn-sm archive-resurrect-btn" type="button" data-resurrect-ref="' +
              esc(row.bundleRef) + '">Resurrect</button>' +
            cliChipHtml(row.resurrectCommand) +
          "</div>"
        : "") +
    "</div>";
  }

  // ---- Resurrect flow pure helpers (azh-w7) — node-pinned via __bpTestHook ----

  // The POST /v1/resurrect body for a row + chosen provider. name = the archive
  // slug (what the CLI resurrect names too); bundle_ref = THIS row's bundle; the
  // provider rides only when known so a source-less bundle falls back to the
  // server default. Portable by design — provider may differ from the source.
  function resurrectRequestBody(row, provider) {
    row = row || {};
    var body = { name: String(row.slug || ""), bundle_ref: String(row.bundleRef || "") };
    var p = String(provider || row.providerKind || "");
    if (p) body.provider = p;
    return body;
  }

  // Map the /v1/resurrect response to the next action. A 202 hands off to the
  // /new step feed; a provider_not_connected 422 surfaces the SERVER remediation
  // in-sheet (D19 — friendly() drops .remediation, so read it first); anything
  // else is a plain error sentence. Pure + total.
  function resurrectOutcome(r) {
    r = r || {};
    var d = r.data || {};
    if (r.status === 202 && d.id) return { action: "progress", id: String(d.id) };
    if (r.status === 422 && d.error === "provider_not_connected") {
      return { action: "remediate", message: remediationCopy(d) || friendly(d, "Connect that provider first.") };
    }
    return { action: "error", message: friendly(d, "Couldn't resurrect — please try again.") };
  }

  // The resurrect sheet body: a portable-provider picker (launch tab strip,
  // default = source provider), a destroy-tier typed echo (proof of attention —
  // a resurrect bills a real box), and a server-owned inline error slot for the
  // 422 remediation. The Resurrect button ships disabled; the typed echo arms it.
  function resurrectModalHtml(row, activeProvider) {
    row = row || {};
    var slug = String(row.slug || "");
    var tabs = launchProviderTabsHtml(activeProvider || row.providerKind || "");
    var picker = tabs
      ? '<div class="field"><span class="label">Resurrect onto</span>' +
          '<div class="seg" role="group" aria-label="Target provider" data-resurrect-tabs>' + tabs + "</div>" +
          '<p class="dim resurrect-portable">Portable bundle — restore onto Hetzner or Azure.</p></div>'
      : "";
    return '<h2 class="modal-title" id="modal-title">Resurrect ' + esc(slug) + "?</h2>" +
      '<p class="modal-sub">Stands up a NEW instance from this archive bundle. The restored box bills like any other.</p>' +
      picker +
      '<div class="field cm-typed-field">' +
        '<label class="label" for="resurrect-typed">Type <span class="cm-name">' + esc(slug) + "</span> to confirm</label>" +
        '<input class="form-input" id="resurrect-typed" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" /></div>' +
      '<div class="cm-error" id="resurrect-error" role="alert" hidden><p class="cm-error-msg" id="resurrect-error-msg"></p></div>' +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-primary" type="button" id="resurrect-go" disabled>Resurrect</button></div>';
  }

  // DOM wrapper (browser-verified). Opens the sheet, tracks the picked provider,
  // drives the typed-echo gate through the pure confirmModal reducer, POSTs THIS
  // row's bundle_ref, and routes the outcome: 202 → the /new step feed; a
  // provider_not_connected 422 → the server remediation IN the sheet (never a
  // toast); any other error → an inline retry.
  function openResurrectModal(row) {
    if (!row || !row.bundleRef) return;
    var avail = PROVIDERS.filter(function (p) { return p.available; });
    var provider = (avail.filter(function (p) { return p.kind === row.providerKind; })[0] ||
      avail[0] || {}).kind || row.providerKind || "";
    openModal(resurrectModalHtml(row, provider));
    var go = $("#resurrect-go");
    if (!go) return;
    var typed = $("#resurrect-typed");
    var errBox = $("#resurrect-error");
    var errMsg = $("#resurrect-error-msg");
    var state = confirmModalInit({ tier: "destroy", resourceName: String(row.slug || ""), confirmLabel: "Resurrect" });
    var bodyEl = $("#modal-body");
    var tabsWrap = bodyEl ? bodyEl.querySelector("[data-resurrect-tabs]") : null;
    if (tabsWrap) {
      tabsWrap.querySelectorAll(".seg-btn").forEach(function (b) {
        b.addEventListener("click", function () {
          provider = b.getAttribute("data-kind") || provider;
          tabsWrap.querySelectorAll(".seg-btn").forEach(function (x) {
            x.setAttribute("aria-pressed", x === b ? "true" : "false");
          });
        });
      });
    }
    function arm() { go.disabled = !confirmModalArmed(state); }
    if (typed) {
      typed.addEventListener("input", function () {
        state = confirmModalReduce(state, { type: "type", value: typed.value });
        arm();
      });
    }
    go.addEventListener("click", function () {
      if (!confirmModalArmed(state)) return;
      state = confirmModalReduce(state, { type: "confirm" });
      go.disabled = true;
      go.textContent = "Resurrecting…";
      if (errBox) errBox.hidden = true;
      api("POST", "/v1/resurrect", resurrectRequestBody(row, provider)).then(function (r) {
        var out = resurrectOutcome(r);
        if (out.action === "progress") {
          closeModal();
          // Fresh progress screen — clear any stale /new template so the header
          // reads the neutral "Setting up your Barkpark", then jump to the feed.
          newState = null;
          showNewScreen();
          newStartProgress(out.id);
          return;
        }
        state = confirmModalReduce(state, { type: "fail", message: out.message });
        go.disabled = false;
        go.textContent = "Resurrect";
        if (errMsg) setText(errMsg, out.message);
        if (errBox) errBox.hidden = false;
      });
    });
  }

  // The whole panel body from the model — loading / error+Retry / empty / rows.
  function archivesPanelHtml(model) {
    if (!model || model.loading) {
      return '<div class="loading">Loading archives&hellip;</div>';
    }
    if (model.error) {
      return '<div class="archives-note archives-note--warn"><p>' + esc(model.message) + "</p>" +
        '<button class="btn btn-ghost btn-sm" type="button" data-archives-retry>Retry</button></div>';
    }
    if (!model.rows.length) {
      return '<div class="archives-note"><p>No archives yet. Archive an instance with ' +
        cliChipHtml("bp cloud instance archive <name>") +
        " to keep a portable, cross-provider bundle you can resurrect on Hetzner or Azure.</p></div>";
    }
    return '<div class="archive-list">' + model.rows.map(archiveRowHtml).join("") + "</div>";
  }

  // Azure four-field validator: every service-principal field must be a non-empty
  // (trimmed) string before we spend a verify-before-save round trip.
  function azureFieldsValid(fields) {
    if (!fields || typeof fields !== "object") return false;
    for (var i = 0; i < AZURE_FIELDS.length; i++) {
      var v = fields[AZURE_FIELDS[i].key];
      if (typeof v !== "string" || v.trim() === "") return false;
    }
    return true;
  }

  // The POST /v1/providers body, per kind (router.ex:5572-5583): hetzner sends
  // {kind, token}; azure sends {kind, credentials:{tenant_id,…}}. label is added
  // only when the operator typed one. Trims each value so trailing paste
  // whitespace never reaches the vault.
  function providerCredBody(kind, fields, label) {
    var body = { kind: kind };
    if (kind === "azure") {
      var creds = {};
      for (var i = 0; i < AZURE_FIELDS.length; i++) {
        var k = AZURE_FIELDS[i].key;
        creds[k] = ((fields && fields[k]) || "").trim();
      }
      body.credentials = creds;
    } else {
      body.token = ((fields && fields.token) || "").trim();
    }
    var lb = (label || "").trim();
    if (lb) body.label = lb;
    return body;
  }

  // Server-owned remediation extractor. The connect preflight returns a 422 with
  // a human `remediation` string (FailureCopy.connect_remediation) that names the
  // exact console fix. friendly() reads only .error/.details and PROVABLY drops
  // this field (asserted in the harness) — so we surface it directly, never
  // through friendly(), keeping the copy server-owned and un-rewritten.
  function remediationCopy(data) {
    if (!data || typeof data !== "object") return null;
    var r = data.remediation;
    return typeof r === "string" && r.trim() !== "" ? r : null;
  }

  // Normalized monthly-price formatter (Decision 6 — real price on BOTH clouds).
  // A number renders as "<sym>N/mo"; azure is framed "from ~$N/mo compute" (its
  // catalog is a floor, VM-only). A nil price is an HONEST "Price unavailable" —
  // never a fabricated $0. `currency` is the catalog payload's own code
  // (Decision 15: "EUR" hetzner / "USD" azure) so a EUR price is never dressed
  // as dollars; absent (pre-currency server) it defaults to "$".
  function formatMonthlyPrice(price, kind, currency) {
    if (typeof price !== "number" || !isFinite(price) || price < 0) return "Price unavailable";
    var sym = currency === "EUR" ? "€" : "$";
    var n = price >= 10 ? String(Math.round(price)) : (Math.round(price * 100) / 100).toString();
    return kind === "azure" ? "from ~" + sym + n + "/mo compute" : sym + n + "/mo";
  }

  // Map an api() catalog response to a render state. The catalog needs a
  // connected provider of that kind (404 no_provider = connect-first), degrades
  // honestly on an upstream failure (502 unavailable), and never white-screens on
  // a surprise status.
  function catalogViewState(r) {
    if (!r) return { state: "error" };
    if (r.status === 200 && r.data && Array.isArray(r.data.server_types)) {
      return { state: "ready", catalog: r.data };
    }
    var err = (r.data && r.data.error) || "";
    if (r.status === 404 && err === "no_provider") return { state: "no_provider" };
    if (r.status === 404) return { state: "unknown" };
    if (r.status === 502) return { state: "unavailable" };
    return { state: "error" };
  }

  // Human size line: "2 vCPU · 8 GB RAM · 40 GB SSD", each part dropped when the
  // catalog didn't carry it (honest partial, never "undefined GB").
  function serverTypeLabel(st) {
    if (!st) return "";
    var parts = [];
    if (typeof st.cores === "number") parts.push(st.cores + " vCPU");
    if (typeof st.ram_gb === "number") parts.push(st.ram_gb + " GB RAM");
    if (typeof st.disk_gb === "number") parts.push(st.disk_gb + " GB SSD");
    return parts.join(" · ");
  }

  // Default catalog selection: first region, and the cheapest priced server type
  // (falling back to the first type when none carry a price). Returns null slugs
  // for an empty catalog so the caller renders the empty state, not a phantom pick.
  function defaultCatalogSelection(catalog) {
    var regions = (catalog && catalog.regions) || [];
    var types = (catalog && catalog.server_types) || [];
    var region = regions.length ? regions[0].slug : null;
    var pick = null;
    for (var i = 0; i < types.length; i++) {
      var t = types[i];
      if (typeof t.monthly_price === "number") {
        if (!pick || t.monthly_price < pick.monthly_price) pick = t;
      }
    }
    if (!pick && types.length) pick = types[0];
    return { region: region, server_type: pick ? pick.slug : null };
  }

  // The POST /v1/launch body. name is always sent; provider/region/server_type
  // ride along ONLY when a real selection exists — the server honors them once
  // S6 lands and harmlessly ignores them before, so a name-only managed launch
  // (no connected provider) keeps working unchanged.
  function launchBody(name, provider, region, serverType) {
    var body = { name: name };
    if (provider) body.provider = provider;
    if (region) body.region = region;
    if (serverType) body.server_type = serverType;
    return body;
  }
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

  // The per-kind credential inputs. hetzner: one API key (affixed eye toggle).
  // azure: the four service-principal fields, the secret one carrying its own eye
  // toggle. Every input id is namespaced cred-az-<field> so submit can read them.
  function credentialFieldsHtml(p) {
    if (p.fields === "azure") {
      return '<p class="field-hint dim" style="margin:0 0 10px">Create a service principal in the ' +
        '<a href="' + esc(p.console || "#") + '" target="_blank" rel="noopener">Azure Portal</a> ' +
        "(App registrations → your app). Encrypted at rest, never shown again.</p>" +
        AZURE_FIELDS.map(function (f) {
          var id = "cred-az-" + f.key;
          if (f.secret) {
            return '<div class="field"><label class="label" for="' + id + '">' + esc(f.label) + "</label>" +
              '<div class="input-affix">' +
                '<input class="form-input" id="' + id + '" type="password" autocomplete="off" placeholder="' + esc(f.placeholder) + '" />' +
                '<button class="affix-btn" id="cred-az-eye" type="button" tabindex="-1" aria-label="Show secret">' + EYE_SVG + "</button>" +
              "</div></div>";
          }
          return '<div class="field"><label class="label" for="' + id + '">' + esc(f.label) + "</label>" +
            '<input class="form-input" id="' + id + '" type="text" autocomplete="off" spellcheck="false" placeholder="' + esc(f.placeholder) + '" /></div>';
        }).join("");
    }
    return '<div class="field"><label class="label" for="cred-token">API key</label>' +
      '<p class="field-hint dim" style="margin:0 0 6px">Create a key in the ' +
        '<a href="' + esc(p.console || "#") + '" target="_blank" rel="noopener">' + esc(p.name) + " console</a>. " +
        "Encrypted at rest, never shown again.</p>" +
      '<div class="input-affix">' +
        '<input class="form-input" id="cred-token" type="password" autocomplete="off" placeholder="••••••••••••••••" />' +
        '<button class="affix-btn" id="cred-eye" type="button" tabindex="-1" aria-label="Show key">' + EYE_SVG + "</button>" +
      "</div></div>";
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
      credentialFieldsHtml(p) +
      '<div class="cred-remediation" id="cred-remediation" role="alert" hidden></div>' +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="cred-submit" type="button">Add provider</button></div>'
    );
    $("#cred-back").addEventListener("click", openProviderPicker);
    var eye = $("#cred-eye");
    if (eye) eye.addEventListener("click", function () { toggleEye("#cred-token", "#cred-eye"); });
    var azEye = $("#cred-az-eye");
    if (azEye) azEye.addEventListener("click", function () { toggleEye("#cred-az-client_secret", "#cred-az-eye"); });
    $("#cred-submit").addEventListener("click", function () { submitProviderCred(kind); });
    var first = $("#cred-token") || $("#cred-az-tenant_id");
    if (first) first.focus();
  }

  // Read the operator's inputs into the shape providerCredBody() expects.
  function readCredentialFields(p) {
    if (p.fields === "azure") {
      var f = {};
      AZURE_FIELDS.forEach(function (af) {
        var el = $("#cred-az-" + af.key);
        f[af.key] = el ? el.value : "";
      });
      return f;
    }
    var t = $("#cred-token");
    return { token: t ? t.value : "" };
  }

  // Paint the server-owned remediation copy INSIDE the sheet (both kinds). Never
  // routed through friendly() — the copy is the server's, verbatim (esc'd only).
  function showCredRemediation(copy) {
    var box = $("#cred-remediation");
    if (!box) return;
    box.innerHTML = '<span class="cred-remediation-ico" aria-hidden="true">!</span>' +
      '<span class="cred-remediation-body">' + esc(copy) + "</span>";
    box.hidden = false;
  }

  function submitProviderCred(kind) {
    var p = providerMeta(kind);
    var fields = readCredentialFields(p);
    var label = ($("#cred-label").value || "").trim();

    var valid = p.fields === "azure" ? azureFieldsValid(fields) : !!(fields.token || "").trim();
    if (!valid) {
      toast({ kind: "error", title: p.fields === "azure" ? "All four fields are required." : "An API key is required." });
      return;
    }

    var rem = $("#cred-remediation");
    if (rem) { rem.hidden = true; rem.innerHTML = ""; } // clear a prior failure

    var btn = $("#cred-submit");
    btn.disabled = true;
    btn.textContent = "Verifying…";

    api("POST", "/v1/providers", providerCredBody(kind, fields, label)).then(function (r) {
      if (r.status === 201) {
        closeModal();
        var prov = (r.data && r.data.provider) || { kind: kind, label: label };
        toast({
          kind: "success",
          title: "Provider connected",
          body: "Connected " + (prov.kind || kind) + (prov.label ? " (" + prov.label + ")" : "") + "."
        });
        loadProviders();
        return;
      }
      btn.disabled = false;
      btn.textContent = "Add provider";
      // Verify-before-save failure carries server-owned remediation (naming the
      // exact console fix) — render it in-sheet so the operator can act without
      // dismissing the form. Anything else falls back to friendly()'s copy.
      var copy = remediationCopy(r.data);
      if (copy) showCredRemediation(copy);
      else toast({ kind: "error", title: "Couldn't verify those credentials", body: friendly(r.data, "Check the details and try again.") });
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
    setText($("#activate-theme-label"), label); // /activate screen's own toggle, kept in sync
    var tt = $("#theme-toggle"); if (tt) tt.setAttribute("aria-label", aria);
    var nt = $("#new-theme-toggle"); if (nt) nt.setAttribute("aria-label", aria);
    var at = $("#activate-theme-toggle"); if (at) at.setAttribute("aria-label", aria);
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

  // ------------------------------------------------- theme IDENTITY (data-bp-theme)
  // The identity picker mirrors toggleTheme() one axis over: it swaps the whole
  // palette (evergreen / ember / fjord) via [data-bp-theme], which the emitted
  // per-theme CSS blocks in app.css re-skin every var off. An unknown id (stale
  // localStorage, a retired theme) falls back to evergreen so a bad value never
  // white-screens — the bare declarations in app.css ARE the evergreen fallback.
  function normalizeBpTheme(id) {
    return BP_THEMES.indexOf(id) === -1 ? "evergreen" : id;
  }
  function applyBpTheme(id) {
    var t = normalizeBpTheme(id);
    document.documentElement.setAttribute("data-bp-theme", t);
    var sel = $("#bp-theme-picker");
    if (sel && sel.value !== t) sel.value = t; // keep the control in sync on init/restore
    return t;
  }
  function initBpTheme() {
    applyBpTheme(localStorage.getItem(BP_THEME) || "evergreen");
  }
  function selectBpTheme(id) {
    var t = normalizeBpTheme(id);
    localStorage.setItem(BP_THEME, t);
    return applyBpTheme(t);
  }

  // The picker's human label for an id — Title-case of the slug (the ids ARE the
  // design's identity names: evergreen / charple / ember / fjord / iris). Pure.
  function bpThemeLabel(id) {
    var s = String(id == null ? "" : id);
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
  }
  // The picker's option model, derived from the GENERATED BP_THEMES (GR12) — so
  // every identity emit.mjs knows about is offered, in the canonical order, with
  // zero hand-list to drift. Pure; node-pinned.
  function bpThemeOptions() {
    return BP_THEMES.map(function (id) { return { id: id, label: bpThemeLabel(id) }; });
  }
  // Populate the identity <select> from bpThemeOptions() at boot. The prior
  // hardcoded <option>s (and their charple/iris omission) are gone — the control
  // is now a pure projection of the emitted enum. Re-selects the active id so the
  // control mirrors [data-bp-theme] after initBpTheme().
  function renderThemePicker() {
    var sel = $("#bp-theme-picker");
    if (!sel) return;
    sel.innerHTML = bpThemeOptions().map(function (o) {
      return '<option value="' + esc(o.id) + '">' + esc(o.label) + "</option>";
    }).join("");
    var active = normalizeBpTheme(localStorage.getItem(BP_THEME) || "evergreen");
    sel.value = active;
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

  // ---------------------------------------------------- two-factor challenge card
  // The control plane's login is two-phase for TOTP-enrolled accounts: POST
  // /v1/auth/login answers `200 {two_factor_required:true, challenge_token}`
  // (the challenge_token is a 5-min single-use pending token) instead of a
  // session, and POST /v1/auth/two-factor-challenge trades {challenge_token,
  // code|recovery_code} for the SAME `{token, team_id}` a plain login mints —
  // or 401 {error:"invalid_code"} / 429 {error:"rate_limited"}. ONE shared card
  // renders at every login submit site (main #login-card, /new, and the /activate
  // logged-out park→resume that rides submitAuth). The challenge_token lives in
  // the mount CLOSURE only — never sessionStorage/localStorage (short-lived
  // secret). SECONDS the disabled-countdown mirrors renderActivateRateLimited so
  // a 429 can't be instantly re-fired.
  var TFA_RATE_WAIT_S = 30;

  // Pure classifier for a POST /v1/auth/login result: does it carry a session,
  // a two-factor challenge, or an error? Shared by submitAuth + newSubmitAuth so
  // every submit site routes to the card identically (node-pinned).
  function loginResponseKind(r) {
    if (r && r.ok && r.data && r.data.token) return "session";
    if (r && r.data && r.data.two_factor_required && r.data.challenge_token) return "two_factor";
    return "error";
  }

  // Pure classifier for the challenge response → the card's next state.
  function twoFactorChallengeOutcome(r) {
    if (r && r.ok && r.data && r.data.token) {
      return { state: "success", token: r.data.token, team_id: (r.data.team_id != null ? r.data.team_id : null) };
    }
    if (r && r.status === 429) return { state: "rate_limited" };
    if (r && (r.status === 401 || (r.data && r.data.error === "invalid_code"))) return { state: "invalid_code" };
    return { state: "error" };
  }

  function twoFactorErrorCopy(state, recovery) {
    if (state === "invalid_code") return ERRORS.invalid_code;
    if (state === "empty") return recovery ? "Enter a recovery code." : "Enter your 6-digit code.";
    return "Couldn't verify that code just now — nothing changed. Please try again.";
  }

  // Pure card markup — tokens only, no native controls. `mode` toggles the OTP
  // field ↔ the recovery-code field; `error` paints an honest inline message;
  // `rateLimited` swaps in the paused-retry state; `back` adds a return link.
  function twoFactorCardHtml(opts) {
    opts = opts || {};
    var recovery = opts.mode === "recovery";
    var backLink = opts.back
      ? '<p class="auth-foot dim"><a href="#" id="tfa-back">Back to sign in</a></p>'
      : "";
    var head =
      '<div class="auth-brand">' +
        '<svg class="wordmark-mark" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2 6.5 10H9l-4.5 7h6v3.5h3V17h6L15 10h2.5Z"/></svg>' +
        '<span class="wordmark-text">Barkpark <b>Cloud</b></span>' +
      '</div>' +
      '<h1 class="new-title">Two-factor authentication</h1>' +
      '<p class="new-desc">' + (recovery
        ? "Enter one of your recovery codes to finish signing in."
        : "Enter the 6-digit code from your authenticator app to finish signing in.") + "</p>";

    if (opts.rateLimited) {
      return head +
        '<p class="form-error" id="tfa-error" role="alert">' + esc(ERRORS.rate_limited) + "</p>" +
        '<button class="btn btn-primary btn-block" id="tfa-submit" type="button" disabled>' +
          "Try again in " + (opts.waitSecs || TFA_RATE_WAIT_S) + "s</button>" +
        backLink;
    }

    var errHtml = opts.error
      ? '<p class="form-error" id="tfa-error" role="alert">' + esc(twoFactorErrorCopy(opts.error, recovery)) + "</p>"
      : '<p class="form-error" id="tfa-error" role="alert" hidden></p>';

    var field = recovery
      ? '<div class="field"><label class="label" for="tfa-code">Recovery code</label>' +
          '<input class="form-input" id="tfa-code" type="text" autocomplete="one-time-code" ' +
            'autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="xxxxxxxx" /></div>'
      : '<div class="field"><label class="label" for="tfa-code">Authentication code</label>' +
          '<input class="form-input" id="tfa-code" type="text" inputmode="numeric" autocomplete="one-time-code" ' +
            'autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="123456" maxlength="6" /></div>';

    return head +
      '<form id="tfa-form" novalidate>' +
        field + errHtml +
        '<button class="btn btn-primary btn-block" id="tfa-submit" type="submit">Verify</button>' +
      "</form>" +
      '<p class="auth-foot dim">' +
        (recovery
          ? 'Have your authenticator app? <a href="#" id="tfa-alt">Use a 6-digit code</a>.'
          : 'Lost your device? <a href="#" id="tfa-alt">Use a recovery code</a>.') +
      "</p>" +
      backLink;
  }

  // Mount the shared card into `root`, wiring the challenge round-trip. The
  // challenge_token is captured HERE and never leaves the closure. opts.onDone
  // (sess) is the success continuation (setSession + render, or renderNewFlow);
  // opts.onBack (optional) returns to the prior screen.
  function mountTwoFactorCard(root, opts) {
    if (!root) return;
    opts = opts || {};
    var challengeToken = opts.challengeToken;
    var mode = "otp"; // "otp" | "recovery"

    function wireBack() {
      var back = root.querySelector("#tfa-back");
      if (back && opts.onBack) back.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        opts.onBack();
      });
    }

    function paint(errState) {
      root.innerHTML = twoFactorCardHtml({ mode: mode, error: errState || null, back: !!opts.onBack });
      wireBack();
      var alt = root.querySelector("#tfa-alt");
      if (alt) alt.addEventListener("click", function (e) {
        if (e && e.preventDefault) e.preventDefault();
        mode = mode === "otp" ? "recovery" : "otp";
        paint();
      });
      var form = root.querySelector("#tfa-form");
      if (form) form.addEventListener("submit", onSubmit);
      var input = root.querySelector("#tfa-code");
      if (input && input.focus) input.focus();
    }

    function paintRateLimited() {
      root.innerHTML = twoFactorCardHtml({ mode: mode, rateLimited: true, waitSecs: TFA_RATE_WAIT_S, back: !!opts.onBack });
      wireBack();
      var btn = root.querySelector("#tfa-submit");
      if (!btn) return;
      var left = TFA_RATE_WAIT_S;
      var tick = setInterval(function () {
        left -= 1;
        if (left <= 0) { clearInterval(tick); paint(); } // the live form returns
        else { btn.textContent = "Try again in " + left + "s"; }
      }, 1000);
    }

    function onSubmit(e) {
      if (e && e.preventDefault) e.preventDefault();
      var input = root.querySelector("#tfa-code");
      var code = ((input && input.value) || "").trim();
      if (!code) { paint("empty"); return; }
      var btn = root.querySelector("#tfa-submit");
      if (btn) btn.disabled = true;
      var body = mode === "recovery"
        ? { challenge_token: challengeToken, recovery_code: code }
        : { challenge_token: challengeToken, code: code };
      return api("POST", "/v1/auth/two-factor-challenge", body, { noAuth: true }).then(function (r) {
        var out = twoFactorChallengeOutcome(r);
        if (out.state === "success") { if (opts.onDone) opts.onDone({ token: out.token, team_id: out.team_id }); return; }
        if (out.state === "rate_limited") { paintRateLimited(); return; }
        paint(out.state); // "invalid_code" (re-enabled form) | "error"
      });
    }

    paint();
  }

  // Main #login-card site: swap the login form for the shared card. `remember`
  // is threaded from submitAuth so the minted session honours the checkbox.
  function showTwoFactorLoginCard(challengeToken, remember) {
    hideAuthError();
    var card = $("#twofa-card");
    if (!card) { // no dedicated slot (shouldn't happen) — fail honest, not silent
      showAuthError("Two-factor sign-in isn't available here — reload and try again.");
      return;
    }
    hide($("#login-card"));
    show(card);
    mountTwoFactorCard(card, {
      challengeToken: challengeToken,
      onDone: function (sess) {
        setSession({ token: sess.token, team_id: sess.team_id || null }, remember);
        hide(card);
        location.hash = "#overview"; // the /activate resume intercept runs first regardless
        render();
      },
      onBack: function () {
        hide(card);
        show($("#login-card"));
        hideAuthError();
        var em = $("#auth-email"); if (em && em.focus) em.focus();
      }
    });
  }

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
      var kind = loginResponseKind(r);
      if (kind === "session") {
        setSession({ token: r.data.token, team_id: r.data.team_id || null }, remember);
        location.hash = "#overview";
        render();
      } else if (kind === "two_factor") {
        // TOTP-enrolled account: swap in the shared challenge card. The minted
        // session honours the "Remember me" choice; a parked /activate code
        // resumes on the post-challenge render() for free.
        showTwoFactorLoginCard(r.data.challenge_token, remember);
      } else {
        showAuthError(friendly(r.data, "Couldn't sign you in."));
      }
    });
  }

  // =========================================================== NAV / ROUTER
  // Every rendered section id ("view-<v>"). The IA reshape (charter decision 6)
  // groups these into a 4-place PRIMARY nav (overview/fleet/sites/activity) plus
  // a SETTINGS cluster (billing/providers/notifications/tokens). "launch" is no
  // longer a view at all (A4/D66): it is the launchFlow() component, opened in a
  // modal or rendered as the empty-fleet welcome runway. Its old #launch bookmark
  // remaps to Overview (legacyRoute) and auto-opens the flow (wantsLaunchFlow).
  var VIEWS = ["overview", "fleet", "sites", "billing", "providers", "notifications", "tokens", "members", "activity"];
  var SETTINGS_VIEWS = ["billing", "providers", "notifications", "tokens", "members"];

  // Routes are either a tab (#overview …), a drill-down (#instance/<id>,
  // #site/<id>), or the invitation-accept landing (#invitations/accept —
  // grouped here because, like a drill-down, it is not a nav tab).
  var DETAIL_VIEWS = ["instance", "site", "invite"];

  // C6 (charter D49): the instance drill-down is a sub-tabbed workspace, routed
  // as #instance/<id>/<tab>. A tab REGISTERS here only when its backend is live —
  // Overview, Timeline (C8/D10: the merged events+audit incident home over the
  // existing GET /v1/barkparks/:id/events + /v1/audit routes), and Webhooks (the
  // C4/C5 instance-API proxy spine). #instance/<id> (the legacy-stable hash
  // `bp cloud open` mints, D14) maps to "overview" forever; an unknown/stale tab
  // suffix degrades to overview rather than 404ing a bookmark.
  var INSTANCE_TABS = ["overview", "timeline", "webhooks", "usage", "metrics"];
  var INSTANCE_TAB_DEFAULT = "overview";
  function instanceTabOf(tab) {
    return INSTANCE_TABS.indexOf(tab) !== -1 ? tab : INSTANCE_TAB_DEFAULT;
  }

  // Charter decisions 6 + 14: the IA moved, but no deep link may ever break.
  // legacyRoute is the PURE remap from any historical hash body to its canonical
  // destination. The legacy-stable set `bp cloud open` mints (#fleet, #sites,
  // #activity, #instance/<id>, #site/<id> — decision 14) passes through
  // untouched, FOREVER; the four Settings pages moved under #settings/<page>, so
  // their old flat bookmarks (#billing …) remap here; an empty hash lands on the
  // new Overview home. A4/D66: #launch is no longer a place — its old bookmark
  // resolves to Overview (and wantsLaunchFlow reopens the launch component on
  // top). Total over any string; never throws.
  function legacyRoute(hash) {
    var h = String(hash == null ? "" : hash).replace(/^#/, "");
    if (h === "") return "overview";
    // The server mints invitation accept links as `/#/invitations/accept?token=…`
    // (router.ex accept_url/2 — leading slash, token in the fragment's query).
    // Normalize that minted shape to the canonical slash-less hash body so the
    // SPA routes EXACTLY what the server hands out, forever.
    if (h.indexOf("/invitations/accept") === 0) return h.slice(1);
    var MAP = {
      launch: "overview",
      billing: "settings/billing",
      providers: "settings/providers",
      notifications: "settings/notifications",
      tokens: "settings/tokens",
    };
    return Object.prototype.hasOwnProperty.call(MAP, h) ? MAP[h] : h;
  }

  // Pure: does this raw hash want the launch component opened over Overview? Only
  // the legacy #launch bookmark (D66 — launch is an action, not a view) does; any
  // other hash → false. legacyRoute already lands #launch on Overview; this is the
  // "and open the flow" companion so a stale bookmark still reaches the launcher.
  function wantsLaunchFlow(hash) {
    return String(hash == null ? "" : hash).replace(/^#/, "") === "launch";
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

  // Pure: the raw accept token from an invitation hash, or null. Tolerates the
  // minted leading-slash shape AND the canonical one, extra query params, and a
  // percent-encoded token (safeDecode never throws). Anything else → null.
  function parseInviteToken(hash) {
    var h = String(hash == null ? "" : hash).replace(/^#/, "").replace(/^\//, "");
    var m = h.match(/^invitations\/accept(?:\?(.*))?$/);
    if (!m || !m[1]) return null;
    var parts = m[1].split("&");
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].indexOf("token=") === 0) {
        var v = parts[i].slice(6);
        return v ? safeDecode(v) : null;
      }
    }
    return null;
  }

  function parseHash() {
    var canon = legacyRoute((location.hash || "").replace(/^#/, ""));
    if (/^invitations\/accept(\?|$)/.test(canon)) {
      return { view: "invite", token: parseInviteToken(canon) };
    }
    var mi = canon.match(/^instance\/(.+)$/);
    if (mi) {
      // The body after "instance/" is "<id>" or "<id>/<tab>". Instance ids are
      // UUIDs (no slash), so the FIRST slash splits id from tab; a missing tab is
      // the Overview default and an unregistered tab degrades to it (D49/D14).
      var rest = mi[1];
      var slash = rest.indexOf("/");
      if (slash === -1) return { view: "instance", id: safeDecode(rest), tab: INSTANCE_TAB_DEFAULT };
      return {
        view: "instance",
        id: safeDecode(rest.slice(0, slash)),
        tab: instanceTabOf(rest.slice(slash + 1)),
      };
    }
    var ms = canon.match(/^site\/(.+)$/);
    if (ms) return { view: "site", id: safeDecode(ms[1]) };
    var mset = canon.match(/^settings\/([a-z]+)$/);
    if (mset && SETTINGS_VIEWS.indexOf(mset[1]) !== -1) return { view: mset[1] };
    if (/^fleet\/[a-z]+$/.test(canon)) return { view: "fleet", filter: parseFleetFilter(canon) };
    return { view: VIEWS.indexOf(canon) !== -1 ? canon : "overview" };
  }

  function applyRoute() {
    var r = parseHash();
    if (r.view !== "instance") stopInstanceTicker(); // C3: leave the timeline ticker with its view
    var detail = DETAIL_VIEWS.indexOf(r.view) !== -1;
    // Which PRIMARY nav entry stays highlighted. A drill-down keeps its parent
    // lit; the four Settings pages light the single "settings" cluster trigger.
    var activeNav = r.view === "site" ? "sites"
      : r.view === "instance" ? "fleet"
      : SETTINGS_VIEWS.indexOf(r.view) !== -1 ? "settings"
      : r.view; // overview | fleet | sites | activity
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
    // v4 shell presentation over the unchanged route (GR10): morph the sidebar
    // layer, paint the drilled-in context, keep the scope label + operator gate
    // honest. Pure routing behaviour above is untouched — this only reflects `r`
    // onto the new chrome (null-guarded, so the pre-v4 DOM / test shims no-op).
    applyShellNav(r);
    // Collapse the Settings disclosure after every navigation so it never lingers
    // open over the next page.
    var menu = document.querySelector(".nav-menu");
    if (menu) menu.removeAttribute("open");
    var inst = document.getElementById("view-instance");
    if (inst) inst.hidden = r.view !== "instance";
    var site = document.getElementById("view-site");
    if (site) site.hidden = r.view !== "site";
    var invite = document.getElementById("view-invite");
    if (invite) invite.hidden = r.view !== "invite";

    if (r.view === "instance") { loadInstance(r.id, r.tab); return; }
    if (r.view === "site") { loadSite(r.id); return; }
    if (r.view === "invite") { setBreadcrumb(null); loadInvite(r.token); return; }
    setBreadcrumb(null);
    if (r.view === "overview") {
      loadOverview();
      // A stale #launch bookmark landed on Overview — reopen the launch flow,
      // and normalise the address bar so a reload or Back doesn't replay it.
      if (wantsLaunchFlow(location.hash)) {
        history.replaceState(null, "", "/#overview");
        openLaunchModal();
      }
    }
    if (r.view === "fleet") loadFleet(r.filter || null);
    if (r.view === "sites") loadSites();
    if (r.view === "billing") renderRecommended();
    if (r.view === "providers") { loadProviders(); loadGithub(); }
    if (r.view === "notifications") loadNotifications();
    if (r.view === "tokens") loadTokens();
    if (r.view === "members") loadMembers(); // C10: the team Members settings panel
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

  // =========================================================== SHELL NAV (v4)
  // The v4 sidebar CONTEXT-MORPHS: at a workspace route the root nav shows
  // (Overview/Fleet/Sites/Activity + Settings); entering an instance or a site
  // collapses layer 1 to a '← back' row and reveals THAT thing's sections. The
  // layer is a PURE function of the parsed route — the prototype's
  // navRoot/navSite/navInstance flags, folded to one enum. node-pinned; the DOM
  // applier below reads it. The router (parseHash) is untouched: this is
  // presentation over the unchanged IA (GR10).
  function shellNavLayer(r) {
    var view = r && r.view;
    if (view === "instance") return "instance";
    if (view === "site") return "site";
    return "root";
  }

  // Fail-CLOSED operator gate (GR9): the sidebar Operator entry renders ONLY when
  // /v1/me answered platform_operator === true. An absent field, a null me, a
  // truthy-but-not-true value → hidden. Never keyed on team role (owner/admin is
  // a different axis — Authz law). Pure; node-pinned.
  function operatorVisible(me) {
    return !!(me && me.platform_operator === true);
  }

  // The sidebar layer the instance/site morph shows a context NAME for. Kept in a
  // closure var so loadInstance/loadSite can refine it once their fixture lands
  // (a deep-link reload paints from fleetCache first, then the real name).
  var shellCtxName = { instance: "", site: "" };
  function setShellContextName(kind, name) {
    if (kind !== "instance" && kind !== "site") return;
    shellCtxName[kind] = name || "";
    var el = $("#nav-" + kind + "-name");
    if (el) setText(el, shellCtxName[kind] || (kind === "instance" ? "Instance" : "Site"));
  }

  // Apply the morph to the DOM: show exactly one nav layer, paint the drilled-in
  // context + its section links, keep the topbar scope label honest, and re-run
  // the operator gate off the cached me. Null-guarded throughout so the node/
  // smoke shims (no real layer nodes) never throw. Presentation only.
  function applyShellNav(r) {
    var layer = shellNavLayer(r);
    var layers = { root: $("#nav-layer-root"), instance: $("#nav-layer-instance"), site: $("#nav-layer-site") };
    Object.keys(layers).forEach(function (k) { if (layers[k]) layers[k].hidden = k !== layer; });

    if (layer === "instance") {
      var bp = fleetLookup(r.id);
      setShellContextName("instance", (bp && (bp.name || bp.slug)) || shellCtxName.instance);
      paintCtxDot("#nav-instance-dot", bp ? classifyBp(bp) : "");
      paintInstanceSections(r.id, r.tab);
    } else if (layer === "site") {
      setShellContextName("site", shellCtxName.site);
      paintCtxDot("#nav-site-dot", "");
    }
    // Settings sub-items carry their OWN data-view (billing/providers/…);
    // applyRoute's activeNav lights only the "settings" cluster (which the flat
    // sidebar has no single trigger for), so highlight the exact settings page
    // here — additive presentation, the router is unchanged.
    if (document.querySelectorAll) {
      document.querySelectorAll(".nav-sub[data-view]").forEach(function (link) {
        var on = link.getAttribute("data-view") === (r && r.view);
        link.classList.toggle("is-active", on);
        if (on) link.setAttribute("aria-current", "page");
        else link.removeAttribute("aria-current");
      });
    }
    setScopeLabel(r, layer);
    applyOperatorGate();
    // A navigation closes an open scope dropdown so it never lingers over the
    // next page (the .nav-menu disclosure gets the same treatment in applyRoute).
    var sm = $("#scope-menu");
    if (sm) sm.hidden = true;
  }

  function fleetLookup(id) {
    if (!fleetCache || !id) return null;
    for (var i = 0; i < fleetCache.length; i++) if (fleetCache[i].id === id) return fleetCache[i];
    return null;
  }

  // The instance morph's section links: the registered instance sub-tabs, routed
  // as #instance/<id>/<tab> so a click rides the UNCHANGED router (loadInstance
  // repaints; the in-page tab strip stays the source of truth for the panel).
  function paintInstanceSections(id, activeTab) {
    var box = $("#nav-instance-sections");
    if (!box) return;
    box.innerHTML = INSTANCE_TABS.map(function (tab) {
      var href = "#instance/" + encodeURIComponent(id) + (tab === INSTANCE_TAB_DEFAULT ? "" : "/" + tab);
      var on = instanceTabOf(activeTab) === tab;
      return '<a class="nav-link nav-sub' + (on ? " is-active" : "") + '" href="' + esc(href) + '"' +
        (on ? ' aria-current="page"' : "") + ">" + esc(bpThemeLabel(tab)) + "</a>";
    }).join("");
  }

  // The ctx dot's colour maps the fleet status kind (classifyBp) onto a semantic
  // token via inline style — a FIXED class keeps it out of the dynamic-class gate
  // (E3), and every var() here is a defined token (E1). Pure; node-pinned.
  function ctxDotColor(kind) {
    if (kind === "ok" || kind === "behind") return "var(--ok)";
    if (kind === "failed" || kind === "removal_failed" || kind === "suspended" || kind === "degraded") return "var(--danger)";
    if (kind === "provisioning" || kind === "removing") return "var(--warn)";
    return "var(--muted-text)";
  }
  function paintCtxDot(sel, statusKind) {
    var el = $(sel);
    if (!el) return;
    el.className = "nav-ctx-dot";
    el.style.background = ctxDotColor(statusKind);
  }

  // Reflect the fail-closed operator gate onto the sidebar Operator entry. Reads
  // the /v1/me cache (undefined before it loads → hidden); re-run from loadMe's
  // callback AND every route so a late me-load flips it on without a reroute.
  function applyOperatorGate() {
    var el = $("#nav-operator");
    if (el) el.hidden = !operatorVisible(meCache);
  }

  // The topbar scope label: the drilled-in instance/site name, else the
  // workspace (team) name. Honest fallback strings before the caches land.
  function setScopeLabel(r, layer) {
    var el = $("#scope-label");
    if (!el) return;
    var label;
    if (layer === "instance") label = shellCtxName.instance || "Instance";
    else if (layer === "site") label = shellCtxName.site || "Site";
    else label = (meCache && meCache.team && meCache.team.name) || "Workspace";
    setText(el, label);
  }

  // ---- instance-scope dropdown (topbar) — a fleet jumper over the SAME router.
  // Rows link to #instance/<id> (no fork of the ⌘K palette machinery); the menu
  // paints from fleetCache instantly and refreshes when ensureFleet() resolves.
  function renderScopeMenu() {
    var menu = $("#scope-menu");
    if (!menu) return;
    var rows = (fleetCache || []).map(function (bp) {
      return '<a class="scope-item" href="#instance/' + esc(bp.id) + '">' +
        '<span class="scope-dot" style="background:' + ctxDotColor(classifyBp(bp)) + '"></span>' +
        '<span class="scope-name">' + esc(bp.name || bp.slug || bp.id) + "</span></a>";
    }).join("");
    menu.innerHTML =
      '<div class="scope-eyebrow">Instances</div>' +
      (rows || '<div class="scope-empty">No instances yet</div>') +
      '<a class="scope-item scope-foot" href="#fleet">View fleet</a>' +
      '<button type="button" class="scope-item scope-foot" id="scope-launch">+ Launch instance</button>';
    var launch = $("#scope-launch");
    if (launch) launch.addEventListener("click", function () { toggleScopeMenu(false); openLaunchModal(); });
  }
  function toggleScopeMenu(force) {
    var menu = $("#scope-menu");
    var btn = $("#scope-switch");
    if (!menu) return;
    var open = force != null ? force : !!menu.hidden;
    menu.hidden = !open;
    if (btn) btn.setAttribute("aria-expanded", String(open));
    if (open) {
      renderScopeMenu();
      ensureFleet().then(function () { if (menu && !menu.hidden) renderScopeMenu(); });
    }
  }

  // =========================================================== SHELL NAV (v4)

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
  function statusPill(bp, extraClass) {
    var s = statusOf(bp);
    return '<span class="status-pill status-pill--' + esc(s.role) +
      (extraClass ? " " + extraClass : "") + '">' +
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
            ? provisionChipHtml(bp, Date.now()) // C3: "configuring · 1m 42s"
            : '<div class="fleet-url">' + esc(publicUrl(bp)) + "</div>";

    // Billing suspension (see router.ex barkpark_json): the box exists but the
    // platform stopped it — folded into statusOf()'s single pill below.
    var live = !removing && !removeFailed && !failed && !provisioning && !bp.suspended && bp.host;

    // The whole provision/suspend/health/agent/update collapse is now ONE pill
    // (charter decision 6); the health/agent/update breakdown moved to the
    // instance-detail rail only. S11b: the pill also carries its S4 lifecycle
    // token class so the fleet row's status IS the lifecycle pill (identity chip
    // stays separate — never a status stand-in).
    var pill = statusPill(bp, instanceLifecycleClass(lifecyclePillState(bp)));

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
        // Region · size, server-stamped (S6). Blank-tolerant: pre-S6 rows carry
        // no region/server_type and render nothing here.
        fleetInfraLine(bp) +
      "</div>" +
      '<div class="fleet-badges">' +
        // Provider IDENTITY chip — renders ONLY when the payload carries
        // `provider` (S6 stamps it); never a fabricated identity, and never a
        // stand-in for the status pill beside it.
        providerChipHtml(bp.provider) + pill + openStudioBtn +
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

  var BUCKET_LABEL = { attention: "needs attention", inflight: "in flight", healthy: "healthy" };
  function fleetFilterBar(bucket, n) {
    return '<div class="fleet-filter-bar">' +
      "<span>Showing " + n + " " + esc(BUCKET_LABEL[bucket] || bucket) + "</span>" +
      '<a href="#fleet">Show all</a>' +
    "</div>";
  }

  // A4/D56: while the welcome runway IS the body, its CTA must be the ONE
  // primary launch affordance — hide the duplicate header button; restore it as
  // soon as the fleet has rows (or the load failed and the runway isn't shown).
  function setHeaderLaunchHidden(btnId, hidden) {
    var b = document.getElementById(btnId);
    if (b) b.hidden = !!hidden;
  }

  // The Fleet list. An optional bucket filter (from #fleet/<bucket>, charter
  // decision 15) narrows the list and shows a bar with a "Show all" affordance.
  function loadFleet(filter) {
    filter = filter || null;
    var body = $("#fleet-body");
    body.innerHTML = '<div class="loading">Loading fleet&hellip;</div>';
    loadArchives(); // S14: the archives panel loads independently of live boxes
    api("GET", "/v1/barkparks").then(function (r) {
      if (!r.ok) {
        body.innerHTML = '<div class="empty-state"><h2>Couldn\'t load fleet</h2><p>' +
          esc(friendly(r.data)) + "</p></div>";
        return;
      }
      var list = (r.data && r.data.barkparks) || [];
      fleetCache = list;
      setHeaderLaunchHidden("fleet-launch", !list.length);
      if (!list.length) {
        launchFlow(body, { runway: true }); // A4: empty fleet → the welcome runway
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
      // isu-w5: the fleet-wide rollout banner (Halt/Resume) mounts above the list;
      // the slot stays empty against an older CP / for a non-admin.
      body.innerHTML = '<div id="fleet-rollout"></div>' + bar + shown.map(fleetRow).join("");
      loadFleetRollout(body);
      wireFleetRows(body);
    });
  }

  // S14 portable archives — the ONE archives mount. Fetches GET /v1/archives and
  // paints #archives-body through the pure archivesModel/archivesPanelHtml. Honest
  // states throughout: loading shell first, then rows / true-empty / error+Retry
  // (api() never rejects, so a store outage lands in the error branch with a
  // working Retry, never a dead spinner). The panel lives in the fleet view and
  // is a no-op when its mount is absent.
  function loadArchives() {
    var panel = document.getElementById("archives-body");
    if (!panel) return;
    panel.innerHTML = archivesPanelHtml(archivesModel(undefined));
    api("GET", "/v1/archives").then(function (r) {
      // The route emits {ok, archives|error} in the body on BOTH 200 and 502;
      // api() surfaces that body as r.data, so the model reads it uniformly.
      var model = archivesModel(r.data);
      panel.innerHTML = archivesPanelHtml(model);
      var retry = panel.querySelector("[data-archives-retry]");
      if (retry) retry.addEventListener("click", loadArchives);
      wireArchiveResurrect(panel, model);
    });
  }

  // Wire each row's Resurrect button to its model row (keyed by bundle_ref, the
  // unique S3 key) so a click opens the typed-confirm sheet for THAT bundle.
  function wireArchiveResurrect(panel, model) {
    var byRef = {};
    (model && model.rows || []).forEach(function (row) {
      if (row && row.bundleRef) byRef[row.bundleRef] = row;
    });
    panel.querySelectorAll(".archive-resurrect-btn").forEach(function (btn) {
      var row = byRef[btn.getAttribute("data-resurrect-ref")];
      if (row) btn.addEventListener("click", function () { openResurrectModal(row); });
    });
  }

  // =========================================================== OVERVIEW (home)
  // The operator's landing page (charter decision 6): a rollup strip whose three
  // counts are clickable filters that deep-link into #fleet/<bucket>, an
  // attention QUEUE (most-urgent instance on top via attentionRank), an activity
  // digest that HIDES on 403 (/v1/audit is admin-gated), the welcome runway for
  // an empty fleet (A4), and Launch-as-action in the header.
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
      setHeaderLaunchHidden("overview-launch", !list.length);
      if (!list.length) {
        launchFlow(body, { runway: true }); // A4: empty fleet → the welcome runway
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
      body.innerHTML = rollupStrip(sum) +
        '<div id="overview-fleet-usage"></div>' +
        queueHtml + '<div id="overview-digest"></div>';
      wireFleetRows(body);
      loadFleetUsageStrip(); // wave-3: the whole fleet's usage from cached samples
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
  function loadInstance(id, tab) {
    var seq = ++instanceLoadSeq;
    // Default the tab from the current route when a caller omits it (SSE retry,
    // post-mutation reload), but never trust a foreign view's tab.
    if (tab === undefined) {
      var h = parseHash();
      tab = h.view === "instance" ? h.tab : INSTANCE_TAB_DEFAULT;
    }
    tab = instanceTabOf(tab);
    stopInstanceTicker(); // the DOM the ticker updates is about to be replaced (or re-armed by the fast path)
    var box = $("#instance-body");
    // Keep the current view up while refetching — wiping to "Loading…" here
    // made every provisioning SSE tick flash the whole panel. The loading state
    // only shows when the box isn't already rendering THIS instance (navigating
    // to a different one still swaps to an honest loading state immediately).
    var mountedPanel = box.querySelector("#instance-tabpanel");
    if (!mountedPanel || mountedPanel.getAttribute("data-inst") !== String(id)) {
      box.innerHTML = '<div class="loading">Loading instance&hellip;</div>';
    }
    ensureFleet().then(function (list) {
      if (seq !== instanceLoadSeq) return; // a newer load owns the view
      if (!list) {
        // Fleet fetch failed — distinct from "the id isn't in a real list".
        setBreadcrumb(null);
        box.innerHTML = '<div class="empty-state"><h2>Couldn\'t load this instance</h2>' +
          '<p>Check your connection and retry.</p>' +
          '<p><button class="btn btn-primary btn-sm" id="inst-load-retry" type="button">Retry</button></p></div>';
        var retry = $("#inst-load-retry");
        if (retry) retry.addEventListener("click", function () { loadInstance(id, tab); });
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
      setShellContextName("instance", bp.name); // refine the sidebar morph ctx name
      setScopeLabel(parseHash(), shellNavLayer(parseHash()));
      // A4 ready fold: if we watched this box provisioning and it's now live, show
      // the ready panel. The flag is consumed on the operator's DISMISS (View
      // details), not on render — going live fires several SSE ticks in quick
      // succession (agent connect, health flip) and each one repaints this view;
      // consuming on render would blink the celebration away before it's read.
      var lc = instanceLifecycle(bp);
      if (lc.provisioning || lc.failed) provisioningSeen[bp.id] = true;
      var showReady = tab === "overview" && readyFoldTrigger(bp) && !!provisioningSeen[bp.id];
      // SSE fast path (unified-provision-view): while provisioning, every step/
      // console broadcast lands here — but a full remount restarts every
      // animation (the same bug #1157 fixed on /new). When THIS instance's
      // timeline is already mounted in the SAME phase, patch the live regions
      // (steps / console / clocks / header chip) in place and re-arm the ticker;
      // any phase change (→ failed, → live/ready fold) falls through to the
      // full render below.
      var mountedTl = box.querySelector('[data-tl][data-tl-bp="' + bp.id + '"]');
      if (mountedTl && tab === "overview" && !showReady && lc.provisioning &&
          mountedTl.getAttribute("data-tl-lc") === "provisioning") {
        patchInstanceTimeline(mountedTl, bp);
        var chip = box.querySelector(".fleet-url.provisioning");
        if (chip) chip.outerHTML = provisionChipHtml(bp, Date.now());
        startInstanceTicker(bp);
        return;
      }
      box.innerHTML = instanceDetailHtml(bp, tab, { ready: showReady });
      wireInstanceActions(bp);
      wireLifecycleActions(bp); // S11b: fill the lifecycle action-row slot (conduit-driven)
      var panel = box.querySelector("#instance-tabpanel");
      if (tab === "webhooks") {
        mountWebhooksTab(panel, bp);
      } else if (tab === "timeline") {
        mountTimelineTab(panel, bp); // C8: the merged events+audit incident home
      } else if (tab === "usage") {
        mountUsageTab(panel, bp); // C10: the instance usage meters (C9 /usage endpoint)
      } else if (tab === "metrics") {
        mountMetricsTab(panel, bp); // S12: the on-box agent vitals beat (Metrics endpoint)
      } else if (showReady) {
        // The ready fold owns the timeline slot — wire its Open Studio + dismiss.
        var rs = $("#inst-ready-studio");
        if (rs) rs.addEventListener("click", function () { openStudio(bp.id, rs); });
        var rd = $("#inst-ready-dismiss");
        if (rd) rd.addEventListener("click", function () {
          delete provisioningSeen[bp.id]; // dismissal consumes the fold
          loadInstance(bp.id, tab);
        });
        loadInstanceSites(bp);
        loadInstanceVerify(bp); // C8: golden-path chips beside the fresh box
        if (bp.host) loadInstanceDomains(bp); // S13: per-host DNS/TLS checklist
      } else {
        // Overview: the C3 provisioning timeline + sites + rail, wired exactly as
        // before (the tab seam only wraps the SAME render in a panel).
        wireInstanceTimeline(box, bp);   // C3: console toggle + Retry
        startInstanceTicker(bp);         // C3: live per-step elapsed (tick, no remount)
        loadInstanceSites(bp);
        loadInstanceVerify(bp);          // C8: golden-path verify chips (host-set boxes)
        if (bp.host) loadInstanceDomains(bp); // S13: per-host DNS/TLS checklist
      }
    });
  }
  // A4: instance ids we've rendered mid-provision — so the provision→live SSE
  // tick can fold the timeline into the ready panel. Set while provisioning,
  // cleared when the operator dismisses the fold (in-memory: a refresh forgets).
  var provisioningSeen = {};

  // A4: has this instance just crossed into live/healthy? The predicate that
  // flips the timeline area into the ready panel (the provision→live moment).
  function readyFoldTrigger(bp) { return !!instanceLifecycle(bp || {}).live; }

  // The persistent workspace chrome (name + status pill + actions), the
  // instance-level banner, then the tab strip, then the active tab's panel. The
  // Overview panel is the pre-C6 detail body verbatim; the Timeline and Webhooks
  // panels are filled by their mount fns after the shell paints. opts.ready folds
  // the timeline slot into the shared ready panel (A4 — the provision→live moment).
  function instanceDetailHtml(bp, tab, opts) {
    tab = instanceTabOf(tab);
    // S11b: the persistent lifecycle action row sits between the header and the
    // tabs — a workspace affordance visible on every tab. The slot is filled
    // async by wireLifecycleActions (the /v1/providers/capabilities conduit); it
    // renders ONLY where teardown makes sense (showLifecycleRow), so a clean
    // provisioning box keeps the timeline as its sole surface.
    var lifeSlot = showLifecycleRow(bp)
      ? '<div id="inst-lifecycle-actions" class="inst-lifecycle-actions" data-inst="' + esc(bp.id) + '"></div>'
      : "";
    return instanceHeaderHtml(bp) +
      lifeSlot +
      instanceTabStripHtml(bp, tab) +
      '<div id="instance-tabpanel" class="inst-tabpanel" data-inst="' + esc(bp.id) + '">' +
        (tab === "overview" ? instanceOverviewHtml(bp, opts) : "") +
      "</div>";
  }

  // The a11y tab strip (charter D49 + the #991 pattern): plain in-app anchors so
  // Back/deep-links/copy work, the active one carrying aria-current="page"; the
  // house focus-visible ring is applied in app.css.
  function instanceTabStripHtml(bp, tab) {
    tab = instanceTabOf(tab);
    var labels = { overview: "Overview", timeline: "Timeline", webhooks: "Webhooks", usage: "Usage", metrics: "Metrics" };
    return '<nav class="inst-tabs" aria-label="Instance sections">' +
      INSTANCE_TABS.map(function (t) {
        var on = t === tab;
        return '<a class="inst-tab' + (on ? " is-active" : "") + '" href="#instance/' +
          esc(bp.id) + "/" + t + '"' + (on ? ' aria-current="page"' : "") + ">" +
          esc(labels[t] || t) + "</a>";
      }).join("") +
      "</nav>";
  }

  // The pre-C6 lifecycle fold, shared by the header and the Overview panel so the
  // two never disagree about which state the box is in. host is the "up" signal,
  // not url (url is set at launch — see fleetRow); a failed provision leaves host
  // nil, surfaced distinctly with the error + retry/remove actions.
  function instanceLifecycle(bp) {
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    var removeFailed = bp.deprovision_status === "failed";
    var failed = !removing && !removeFailed && !bp.host && bp.provision_status === "failed";
    var provisioning = !removing && !removeFailed && !bp.host && !failed;
    var suspended = !removing && !removeFailed && !failed && bp.suspended;
    var live = !removing && !removeFailed && !failed && !provisioning && !suspended && bp.host;
    return { removing: removing, removeFailed: removeFailed, failed: failed, provisioning: provisioning, suspended: suspended, live: live };
  }

  // The persistent workspace header: title + one status pill + the actions, then
  // the instance-level banner (removal / teardown / suspension). These live ABOVE
  // the tab strip so they stay visible on every tab.
  // The user-facing address: an attached custom host is THE address the
  // operator chose; the provisioning FQDN stays the canonical row identity.
  function publicUrl(bp) {
    return bp.custom_host ? "https://" + bp.custom_host : bp.url;
  }

  function instanceHeaderHtml(bp) {
    var lc = instanceLifecycle(bp);

    var url = lc.removing
      ? '<div class="fleet-url provisioning">&mdash; removing</div>'
      : lc.removeFailed
        ? '<div class="fleet-url failed">&mdash; removal failed</div>'
        : lc.failed
          ? '<div class="fleet-url failed">&mdash; provisioning failed</div>'
          : lc.provisioning
            ? provisionChipHtml(bp, Date.now()) // C3: live "configuring · 1m 42s"
            : '<div class="fleet-url">' + esc(publicUrl(bp)) + "</div>";

    // The header collapses to ONE pill (charter decision 6). The health / agent
    // breakdown that USED to be badge-soup now lives only in the Details rail.
    var badges = statusPill(bp);

    // isu-6: live + behind → offer the one-click update alongside Open Studio.
    var updateBtn = lc.live && bp.update_state === "behind"
      ? '<button class="btn btn-primary btn-sm" id="inst-update" type="button">' +
          esc(bp.update_latest_release ? "Update to " + vRel(bp.update_latest_release) : "Update") + "</button>"
      : "";

    // custom-domain: live + no custom host yet → offer the attach flow.
    var domainBtn = lc.live && !bp.custom_host
      ? '<button class="btn btn-ghost btn-sm" id="inst-domain" type="button">Attach domain</button>'
      : "";

    // S11b: the bare Remove button is SUPERSEDED by the lifecycle action row's
    // typed-confirm Decommission (one teardown affordance, not two). The header
    // keeps Retry removal (a distinct retry of a FAILED teardown, which the
    // conduit doesn't cover). Failed provisions get their teardown from the
    // action row + Retry from the timeline, so the header stays action-free.
    var actions =
      lc.removing
        ? ""
        : lc.removeFailed
          ? '<button class="btn btn-primary btn-sm" id="inst-remove-retry" type="button">Retry removal</button>'
          : lc.failed
            ? "" // teardown lives in the lifecycle action row; Retry in the timeline (data-tl-retry)
            : bp.host
              ? updateBtn +
                '<button class="btn btn-primary btn-sm" id="inst-open-studio" type="button">Open Studio</button>' +
                domainBtn
              : "";

    // The failed case is owned by the timeline now (its fail block shows the
    // verbatim provision_error), so no duplicate "provisioning failed" banner.
    var failBanner = lc.removeFailed && bp.deprovision_error
      ? '<div class="notice notice-error" role="alert"><b>Removal failed.</b> ' + esc(bp.deprovision_error) + "</div>"
      : lc.removing
        ? '<div class="notice notice-warn" role="status">Tearing down the server and stopping billing — this can take a moment.</div>'
        : lc.suspended
          ? '<div class="notice notice-error" role="alert"><b>Suspended.</b> ' +
            esc(bp.suspended_reason || "Suspended for billing reasons") + "</div>"
          : "";

    return '<div class="detail-head"><div><h1>' + esc(bp.name) + "</h1>" + url + "</div>" +
      '<div class="fleet-badges">' + badges + (actions ? '<span class="detail-actions">' + actions + "</span>" : "") + "</div></div>" +
      failBanner;
  }

  // The Overview tab panel: the C3 provisioning timeline + the sites/details grid
  // — the pre-C6 detail body verbatim, now living under the Overview tab. opts.ready
  // folds the timeline slot into the shared ready panel (A4).
  function instanceOverviewHtml(bp, opts) {
    opts = opts || {};
    var lc = instanceLifecycle(bp);
    var hasHost = !!bp.host;
    var health = bp.health_status || "unknown";
    var agent = bp.agent_status || "offline";

    // A4: the provision→live moment folds the timeline into the ready panel.
    // C3: while provisioning or provision-failed, the timeline is the primary
    // surface — the step ladder, the console, the verbatim failure detail, Retry.
    var timeline = opts.ready
      ? readyHeroHtml(bp, { studioBtnId: "inst-ready-studio", viewBtnId: "inst-ready-dismiss", viewLabel: "View details", demoteHeading: true })
      : (lc.provisioning || lc.failed)
        ? instanceTimelineHtml(bp, Date.now(), { consoleCollapsed: instanceConsoleCollapsed })
        : "";

    // C8: the golden-path verify card mounts here for a host-set box (a box
    // that's still provisioning has its own timeline as the primary surface,
    // and a box mid-removal must not invite a check that would lie). Filled
    // async by loadInstanceVerify — an empty slot renders nothing.
    var verifySlot = hasHost && !lc.removing && !lc.removeFailed
      ? '<div id="instance-verify"></div>'
      : "";

    // A4/D60: pre-host the timeline is the primary surface — the whole Sites
    // block stays quiet (no floating "Sites" heading over an empty slot, no
    // loading flash). loadInstanceSites keeps the slot honest either way.
    // The rail is grouped into labelled sub-sections instead of one flat list, so
    // it scans as chunks (identity / runtime / platform / activity). railGroup is
    // a thin local wrapper — same railRow* helpers, same #instance-domains slot.
    var railGroup = function (label, rows) {
      return '<div class="rail-group"><div class="rail-group-label">' + esc(label) + "</div>" + rows + "</div>";
    };
    return timeline + verifySlot +
      // detail-grid--instance widens the rail (the domain checklist lives there);
      // the site-deploys grid keeps the bare .detail-grid (byte-identical).
      '<div class="detail-grid detail-grid--instance">' +
        // .inst-overview gives the main column a uniform vertical rhythm so the
        // update panel + Sites read as evenly-spaced sections, not a flat stack.
        '<div class="detail-main inst-overview">' +
          // isu-w5: the operator update panel is the face of the Overview for a
          // live box — update truth + policy controls sit above Sites.
          (hasHost
            ? updatePanelHtml(bp) +
              '<section><h2 style="display:flex;align-items:center;justify-content:space-between">Sites ' +
                '<button class="btn" id="site-new-btn" type="button" style="font-size:.85em">+ New site</button></h2>' +
                '<div id="instance-sites"><div class="loading">Loading sites&hellip;</div></div></section>'
            : '<div id="instance-sites"></div>') +
        "</div>" +
        '<aside class="detail-rail">' +
          railGroup("Identity",
            railRowCopy("ID", bp.id) +
            railRowCopy("Host", bp.host || "—") +
            railRow("Slug", bp.slug || "—")) +
          railGroup("Runtime",
            railRow("Mode", bp.mode || "—") +
            railRow("Health", railValue(cap(health), hasHost)) +
            railRow("Agent", railValue(cap(agent), hasHost)) +
            railRow("Version", bp.version ? "v" + bp.version : "—") +
            railRow("Git commit", bp.git_commit ? shortSha(bp.git_commit) : "—")) +
          // S13 (azure-hetzner hosting): the Domain rail row GROWS into the live
          // per-host DNS/TLS checklist. The slot renders the static value first
          // (no layout jump); loadInstanceDomains replaces it with the checklist
          // when the box has attached domains (GET /v1/barkparks/:id/domain-status).
          '<div class="rail-group"><div class="rail-group-label">Platform</div>' +
            '<div id="instance-domains">' + railRow("Domain", bp.custom_host || "—") + "</div></div>" +
          railGroup("Activity",
            railRowPlain("Last seen", fmtWhen(bp.last_seen_at)) +
            railRowPlain("Created", fmtWhen(bp.inserted_at))) +
        "</aside>" +
      "</div>";
  }

  function wireInstanceActions(bp) {
    var openBtn = $("#inst-open-studio");
    if (openBtn) openBtn.addEventListener("click", function () { openStudio(bp.id, openBtn); });
    var update = $("#inst-update");
    if (update) update.addEventListener("click", function () { confirmUpdateInstance(bp); });
    wireUpdatePanel(bp); // isu-w5: per-instance pin/unpin/pause/resume policy buttons
    var domain = $("#inst-domain");
    if (domain) domain.addEventListener("click", function () { openAttachDomainModal(bp); });
    var retry = $("#inst-retry");
    if (retry) retry.addEventListener("click", function () { retryInstance(bp, retry); });
    // The bare Remove button is superseded by the lifecycle action row's typed
    // Decommission (see wireLifecycleActions); the header keeps only Retry removal.
    var removeRetry = $("#inst-remove-retry");
    if (removeRetry) removeRetry.addEventListener("click", function () { removeInstance(bp, removeRetry); });
  }

  // The thin DOM mount for the lifecycle action row — an extension of the
  // wireInstanceActions pattern (add-listener-if-present), called right after it.
  // Paints the live-decommission frame immediately, then queries the capability
  // conduit and repaints with the honest per-verb model. Browser-verified only;
  // ALL of the logic lives in the pure helpers above.
  function wireLifecycleActions(bp) {
    var box = $("#inst-lifecycle-actions");
    if (!box) return;
    // Frame 1: decommission is live from the first paint (it predates the
    // conduit), with a "checking capabilities" note — teardown is never absent.
    paintLifecycleActions(box, bp, lifecycleActionsModel(undefined, bp));
    api("GET", "/v1/providers/capabilities").then(function (r) {
      if (!box.isConnected && box.isConnected !== undefined) return; // navigated away
      // 404 (conduit not deployed yet) / 5xx / network → null → the honest
      // "capabilities unavailable" + Retry state, decommission still live.
      var payload = r && r.ok && r.data ? r.data : null;
      paintLifecycleActions(box, bp, lifecycleActionsModel(payload, bp));
    });
  }

  function paintLifecycleActions(box, bp, model) {
    box.innerHTML = lifecycleActionRowHtml(model);
    var retry = box.querySelector("[data-life-retry]");
    if (retry) retry.addEventListener("click", function () { wireLifecycleActions(bp); });
    var decomm = box.querySelector('[data-life-verb="decommission"]');
    if (decomm) decomm.addEventListener("click", function () { confirmDecommission(bp); });
  }

  // The destroy-tier typed-confirm for Decommission (charter decision 21). Reuses
  // the EXACT deprovision request path the old Remove drove; the typed name echo
  // is the proof-of-attention gate (confirmModal DESTROY tier).
  function confirmDecommission(bp) {
    var live = !!bp.host;
    openConfirmModal({
      tier: "destroy",
      title: "Decommission " + bp.name + "?",
      resourceName: bp.name,
      consequences: live
        ? ["Permanently tears down the server and stops billing.", "This can't be undone."]
        : ["Removes the instance from your dashboard.", "This can't be undone."],
      confirmLabel: "Decommission",
      busyLabel: "Decommissioning…",
      onConfirm: function (ctl) { runDecommission(bp, ctl); },
    });
  }

  // The live decommission with an optimistic pill + rollback (mirrors the pure
  // lifecycleOptimistic reducer). Same DELETE the Remove button issued.
  function runDecommission(bp, ctl) {
    var pill = $("#inst-lifecycle-actions .inst-life-pill");
    var prev = pill ? pill.outerHTML : null;
    if (pill) {
      pill.className = "inst-life-pill " + instanceLifecycleClass("decommissioned");
      pill.innerHTML = '<span class="inst-life-dot" aria-hidden="true"></span>' + esc(LIFECYCLE_PILL_LABEL.decommissioned);
    }
    api("DELETE", "/v1/barkparks/" + encodeURIComponent(bp.id)).then(function (r) {
      if (r.status === 200 || r.status === 202) {
        fleetCache = null;
        ctl.succeed();
        toast({
          kind: "success",
          title: "Decommissioning " + bp.name,
          body: r.status === 200 ? bp.name + " is gone." : "Tearing down the server — billing stops once it's gone.",
        });
        location.hash = "#fleet";
        return;
      }
      // Rollback the optimistic pill, then offer an in-modal retry.
      var back = $("#inst-lifecycle-actions .inst-life-pill");
      if (back && prev) back.outerHTML = prev;
      ctl.fail(friendly(r.data, "Please try again."), "Try again", function (c) {
        c.busy();
        runDecommission(bp, c);
      });
    });
  }

  function retryInstance(bp, btn) {
    var label = btn.textContent; // "Retry setup" on the timeline; restore verbatim
    btn.disabled = true;
    btn.textContent = "Retrying…";
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/retry", {}).then(function (r) {
      if (r.status === 201) {
        toast({ kind: "success", title: "Retrying provision", body: "Re-queued " + bp.name + "." });
        fleetCache = null;
        loadInstance(bp.id);
      } else {
        btn.disabled = false;
        btn.textContent = label;
        toast({ kind: "error", title: "Couldn't retry", body: friendly(r.data, "Please try again.") });
      }
    });
  }

  // removeInstance is the "Retry removal" handler for a box whose teardown FAILED
  // (id="inst-remove-retry"). The initial teardown is now the lifecycle action
  // row's typed Decommission (runDecommission); confirmRemoveInstance retired.
  function removeInstance(bp, btn) {
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

  // isu-w5: opts.force re-POSTs with {force:true} to OVERRIDE a pin for this one
  // run. A pin conflict (409) keeps the modal open, names the pin, and offers an
  // EXPLICIT "Update anyway" — the update button never silently bypasses a pin.
  function updateInstance(bp, btn, opts) {
    opts = opts || {};
    btn = btn || $("#update-go") || $("#update-force");
    if (btn) { btn.disabled = true; btn.textContent = "Updating…"; }
    var reqBody = opts.force ? forceUpdateBody() : {};
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/self-update", reqBody).then(function (r) {
      if (r.status === 202) {
        closeModal();
        toast({ kind: "success", title: "Update started", body: "The instance will restart." });
        fleetCache = null;
        loadInstance(bp.id);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = opts.force ? "Update anyway" : "Update"; }
      // Errors arrive as {error: {code}} — NOT the flat string friendly() reads.
      var c = updateConflict(r.data);
      var copy = updateConflictCopy(c);
      // Pin honesty: a pin conflict on a NON-forced call keeps the operator in a
      // modal that names the pin and offers the explicit force re-trigger.
      if (c.kind === "pinned" && !opts.force) {
        openUpdateConflictModal(bp, c, copy);
        return;
      }
      closeModal();
      toast({ kind: copy.forceLabel ? "info" : "error", title: copy.title, body: copy.body });
    });
  }

  // The pin-conflict modal (isu-w5 pin honesty): names the freeze and offers an
  // explicit override. Reused for any conflict copy that carries a forceLabel.
  function openUpdateConflictModal(bp, c, copy) {
    openModal(
      '<h2 class="modal-title" id="modal-title">' + esc(copy.title) + "</h2>" +
      '<p class="modal-sub">' + esc(copy.body) + "</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        (copy.forceLabel
          ? '<button class="btn btn-danger" type="button" id="update-force">' + esc(copy.forceLabel) + "</button>"
          : "") +
      "</div>"
    );
    var f = $("#update-force");
    if (f) f.addEventListener("click", function () { updateInstance(bp, f, { force: true }); });
  }

  // isu-w6: confirm-then-trigger an app-level rollback, cloning the isu-w5 update
  // trio 1:1. The control plane relays to the instance's POST /v1/admin/rollback,
  // which flips Caddy's upstream to the previous blue/green slot. Distinct from the
  // D7/D25 SITE-deployment "Roll back to this" promote (app.js:5139-5175) — that's
  // per-site deployment history; this is per-INSTANCE slot flip.
  function confirmRollbackInstance(bp) {
    openModal(rollbackConfirmHtml(bp));
    var go = $("#rollback-go");
    if (go) go.addEventListener("click", function () { rollbackInstance(bp, go); });
  }

  // POST /v1/barkparks/:id/rollback → 202 {status,target_sha,pinned_release}. On
  // 202 the CP has ALREADY re-pinned at the rolled-back target (charter D16) — the
  // toast names it so the operator sees the pin land. A typed 409/50x refusal is
  // classified by rollbackConflictCopy and surfaced honestly (no silent retry).
  //
  // NO noBounce: this route is session-gated (require_primary_team_admin), so a 401
  // is a genuinely-expired session that SHOULD bounce to login. noBounce is ONLY
  // for the worker-gated fleet-banner probe (loadFleetRollout above) where a plain
  // session token 401s by design.
  function rollbackInstance(bp, btn) {
    btn = btn || $("#rollback-go");
    if (btn) { btn.disabled = true; btn.textContent = "Rolling back…"; }
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/rollback", {}).then(function (r) {
      if (r.status === 202) {
        closeModal();
        var d = r.data || {};
        // target_sha is server data → toast() escapes it (see toast()).
        var target = d.target_sha ? shortSha(d.target_sha)
          : (d.pinned_release ? vRel(d.pinned_release) : "the previous slot");
        toast({
          kind: "success", title: "Rollback started",
          body: "Rolling back to " + target + " and pinning there — the instance will restart.",
        });
        fleetCache = null;
        loadInstance(bp.id);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Roll back"; }
      // Errors arrive as {error:{code}} (or a bare string) — never the flat
      // friendly() shape. Classify to typed, honest copy.
      var err = (r.data && r.data.error) || {};
      var code = typeof err === "string" ? err : err.code;
      var copy = rollbackConflictCopy(code, r.data);
      closeModal();
      toast({ kind: "error", title: copy.title, body: copy.body });
    });
  }

  // custom-domain: attach a bare barkpark.cloud host to a live instance. The
  // control plane validates + queues the DNS/TLS work (202); the fleet payload
  // carries custom_host once it's persisted.
  function openAttachDomainModal(bp) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Attach a domain to ' + esc(bp.name) + "</h2>" +
      '<p class="modal-sub">Point a <b>barkpark.cloud</b> subdomain at this instance &mdash; DNS and TLS are set up for you.</p>' +
      '<form id="domain-form">' +
        '<label class="label" for="domain-input">Domain</label>' +
        '<input class="form-input" id="domain-input" placeholder="name.barkpark.cloud" required autocomplete="off" spellcheck="false">' +
        '<div id="domain-error" class="form-error" hidden></div>' +
        '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
          '<button class="btn btn-primary" type="submit" id="domain-go">Attach domain</button></div>' +
      "</form>"
    );
    var form = $("#domain-form");
    if (form) form.addEventListener("submit", function (e) { e.preventDefault(); attachDomain(bp); });
  }

  function attachDomain(bp) {
    var value = (($("#domain-input") || {}).value || "").trim();
    var errEl = $("#domain-error");
    if (errEl) errEl.hidden = true;
    if (!value) {
      // Belt-and-braces behind the input's `required` — never POST an empty domain.
      if (errEl) { errEl.hidden = false; errEl.textContent = "Enter a domain like name.barkpark.cloud."; }
      return;
    }
    var btn = $("#domain-go");
    if (btn) { btn.disabled = true; btn.textContent = "Attaching…"; }
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/domain", { domain: value }).then(function (r) {
      if (r.status === 202) {
        // S13: the fire-and-forget toast is replaced by the LIVE per-host
        // checklist. loadInstance re-renders the overview (Domain rail slot),
        // and loadInstanceDomains fetches + polls it — the operator watches
        // DNS → points here → TLS → serving turn green in place.
        closeModal();
        fleetCache = null;
        loadInstance(bp.id);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Attach domain"; }
      var code = r.data && r.data.error;
      var msg = code === "taken"
        ? "That domain is already in use."
        : code === "already_attaching"
          ? "An attach is already running."
          : r.status === 422
            ? "Only <name>.barkpark.cloud domains are supported for now."
            : friendly(r.data, "Something went wrong — please try again.");
      // textContent, not innerHTML — the literal "<name>" (and any echoed input)
      // must render as text, never as markup.
      if (errEl) { errEl.hidden = false; errEl.textContent = msg; }
      else toast({ kind: "error", title: "Couldn't attach the domain", body: msg });
    });
  }

  // =========================================================== UPDATE PANEL (isu-w5)
  // The operator's per-instance update-truth surface + the fleet rollout banner.
  // Every derivation here is PURE and node-pinned via __bpTestHook; the DOM mounts
  // (policy buttons, the fleet-banner fetch) are browser-verified. The Decision-10
  // policy fields (autoupdate_enabled/paused, pinned_release, channel) and the
  // fleet halt state are built by the sibling slice isu-w5-canary-gated-fleet —
  // this panel CODES AGAINST THOSE NAMES and DEGRADES GRACEFULLY (blank cells,
  // hidden policy buttons, hidden banner) so it keeps working against an older
  // control plane that doesn't send them yet.

  // True once the CP serializes the autoupdate policy block. An older CP omits
  // every policy field → undefined → the policy chip + pin/pause buttons hide.
  function hasAutoupdatePolicy(bp) {
    bp = bp || {};
    return bp.autoupdate_enabled !== undefined ||
      bp.autoupdate_paused !== undefined ||
      bp.pinned_release !== undefined ||
      bp.channel !== undefined;
  }

  // The ONE update-state badge: current | behind | in-flight | unknown. An
  // in-flight autoupdate (the trigger marker is set) OUTRANKS the cached verdict
  // — a rollout is actively landing. Roles reuse the --ok/--info/--warn/--neutral
  // token contract that statusPill already styles.
  function updateBadge(bp) {
    bp = bp || {};
    if (bp.autoupdate_triggered_at) return { state: "in-flight", role: "info", label: "Updating" };
    var st = bp.update_state;
    if (st === "behind") return { state: "behind", role: "info", label: "Update available" };
    if (st === "current") return { state: "current", role: "ok", label: "Up to date" };
    return { state: "unknown", role: "neutral", label: "Unknown" };
  }

  // "Checked 5m ago" / "Never checked" — the last-verified freshness line. Reuses
  // relTime; an absent/unparsable stamp reads honestly, never a bare "—".
  function lastCheckedText(iso) {
    if (!iso) return "Never checked";
    var rel = relTime(iso);
    return rel === "—" ? "Never checked" : "Checked " + rel;
  }

  // A concise, HONEST label of the autoupdate policy. Precedence: a pin is the
  // hardest freeze (names a version), then a temporary pause, then opt-out
  // (manual), else auto-riding its channel. Returns null when the CP sends no
  // policy block (older CP → the chip is hidden entirely). tone maps to a
  // .badge .dot kind (online|warn|unknown).
  function autoupdatePolicyLabel(bp) {
    bp = bp || {};
    if (!hasAutoupdatePolicy(bp)) return null;
    if (bp.pinned_release) return { tone: "warn", dot: "warn", text: "Pinned to " + vRel(bp.pinned_release) };
    if (bp.autoupdate_paused) return { tone: "warn", dot: "warn", text: "Paused" };
    if (bp.autoupdate_enabled === false) return { tone: "neutral", dot: "unknown", text: "Manual" };
    var chan = bp.channel ? String(bp.channel) : "";
    return { tone: "ok", dot: "online", text: chan ? "Auto · " + chan : "Auto" };
  }

  // Which policy buttons to offer (only when the policy block is present). A pin
  // and a pause are INDEPENDENT freezes; expose the toggle for each.
  function autoupdateActions(bp) {
    bp = bp || {};
    if (!hasAutoupdatePolicy(bp)) {
      return { policy: false, showPin: false, showUnpin: false, showPause: false, showResume: false };
    }
    var pinned = !!bp.pinned_release;
    var paused = !!bp.autoupdate_paused;
    return { policy: true, showPin: !pinned, showUnpin: pinned, showPause: !paused, showResume: paused };
  }

  // Classify a self-update failure body into an actionable kind. The sibling
  // slice adds a pin-conflict 409 ({error:{code:"pinned", pinned_release}}) atop
  // the existing already_running/not_enabled/not_live codes; this reads BOTH
  // shapes so the UI never silently retries. `pin` is the frozen release, named.
  function updateConflict(data) {
    var err = (data && data.error) || {};
    var code = typeof err === "string" ? err : err.code;
    var pin = err.pinned_release || err.pinned || (data && data.pinned_release) || null;
    if (code === "pinned" || (code == null && pin)) return { kind: "pinned", pin: pin };
    if (code === "already_running") return { kind: "already_running", pin: null };
    if (code === "not_enabled") return { kind: "not_enabled", pin: null };
    if (code === "not_live") return { kind: "not_live", pin: null };
    return { kind: "other", pin: pin, code: code || null };
  }

  // The honest copy + force affordance for a conflict. ONLY a pin conflict offers
  // a force re-trigger (forceLabel non-null); it always names the pin and carries
  // the charter's honest pin caveat. already_running/not_enabled/not_live are
  // terminal — no force.
  function updateConflictCopy(c) {
    c = c || {};
    if (c.kind === "pinned") {
      var at = c.pin ? " at " + vRel(c.pin) : "";
      return {
        title: "This instance is pinned",
        body: "Autoupdate is frozen" + at + ". Pinning holds an instance at or above its " +
          "current version; it does not roll back. Update anyway to override the pin for this one run.",
        forceLabel: "Update anyway",
      };
    }
    if (c.kind === "already_running") return { title: "An update is already running", body: "Give it a moment to finish.", forceLabel: null };
    if (c.kind === "not_enabled") return { title: "Self-update is not enabled on this instance", body: "Set BARKPARK_SELF_UPDATE_APPLY=1 on the box to allow one-click updates.", forceLabel: null };
    if (c.kind === "not_live") return { title: "This instance isn't live yet", body: "Wait until it finishes provisioning.", forceLabel: null };
    return { title: "Couldn't start the update", body: "Please try again in a moment.", forceLabel: null };
  }

  // The request body for a forced (pin-overriding) self-update re-trigger.
  function forceUpdateBody() { return { force: true }; }

  // isu-w6: the rollback confirm-modal markup. HONEST copy per charter D19 — a
  // rollback flips code to the previous slot but the SCHEMA STAYS FORWARD (it
  // does not undo migrations), and the instance is PINNED at the rolled-back
  // version (D16: an unpinned rollback re-updates on the next cron tick — a lie).
  // bp.name is server data → escaped, so a hostile instance name can never inject
  // markup (escaping test mirrors the isu-w5 hostile-channel precedent).
  function rollbackConfirmHtml(bp) {
    bp = bp || {};
    return '<h2 class="modal-title" id="modal-title">Roll back ' + esc(bp.name) + "?</h2>" +
      '<p class="modal-sub">App-level rollback to the previous slot. Schema stays forward &mdash; ' +
        "rolling back code does <b>not</b> undo migrations (write a compensating migration if you " +
        "need to). The instance will be <b>pinned</b> at the rolled-back version so autoupdate " +
        "won't re-apply the version you're leaving.</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" type="button" id="rollback-go">Roll back</button></div>';
  }

  // isu-w6: typed, honest copy for a rollback refusal. PURE — maps the charter's
  // W6 refusal vocabulary (D23) to operator-facing title+body. Static strings only
  // (no server free-text embedded), so nothing here can carry markup; `body` is the
  // raw envelope, accepted for signature parity + future enrichment. NO force
  // affordance: unlike a pin conflict, a rollback refusal is always terminal.
  function rollbackConflictCopy(code, body) {
    body = body || {};
    switch (code) {
      case "no_previous_slot":
        return {
          title: "Nothing to roll back to",
          body: "No previous slot build to roll back to — nothing was recorded, or it was " +
            "already recycled by a newer deploy.",
        };
      case "already_running":
        return { title: "An update or rollback is already running", body: "Give it a moment to finish, then try again." };
      case "not_supported":
        return { title: "Rollback isn't available here", body: "This isn't a blue/green slot box — there's no previous slot to flip to." };
      case "not_enabled":
      case "feature_not_configured":
        return { title: "Rollback is not enabled on this instance", body: "Set BARKPARK_SELF_UPDATE_APPLY=1 on the box to allow one-click rollback." };
      case "not_live":
        return { title: "This instance isn't live yet", body: "Wait until it finishes provisioning." };
      case "instance_unreachable":
        return { title: "Couldn't reach the instance", body: "The box didn't answer. Give it a moment and try again." };
      case "instance_error":
        return { title: "The instance rejected the rollback", body: "The box couldn't complete the rollback — check its logs, then try again." };
      default:
        return { title: "Couldn't start the rollback", body: "Please try again in a moment." };
    }
  }

  // The per-instance update panel: state badge, running→latest, channel, last
  // checked, the policy chip, and the policy action buttons. Pure string builder;
  // buttons carry data-au the wiring reads. Degrades: blank cells + hidden buttons
  // when the policy block is absent (older CP).
  function updatePanelHtml(bp) {
    bp = bp || {};
    var b = updateBadge(bp);
    var running = bp.update_running_release
      ? vRel(bp.update_running_release)
      : (bp.version ? "v" + String(bp.version).replace(/^v/, "") : "—");
    var latest = bp.update_latest_release ? vRel(bp.update_latest_release) : "—";
    var channel = bp.channel ? cap(String(bp.channel)) : "—";
    var policy = autoupdatePolicyLabel(bp);
    var acts = autoupdateActions(bp);

    var badgeHtml =
      '<span class="status-pill status-pill--' + esc(b.role) + ' update-badge" data-update-state="' + esc(b.state) + '">' +
        '<span class="status-pill-dot" aria-hidden="true"></span>' +
        '<span class="status-pill-label">' + esc(b.label) + "</span>" +
      "</span>";

    var rows =
      railRow("Running", running) +
      railRow("Latest", latest) +
      railRow("Channel", channel) +
      railRowPlain("Last checked", lastCheckedText(bp.update_checked_at)) +
      (policy ? railRowHtml("Autoupdate", badge(policy.text, policy.dot)) : "");

    var buttons = "";
    if (acts.policy) {
      if (acts.showPause) buttons += '<button class="btn btn-ghost btn-sm" type="button" data-au="pause">Pause autoupdate</button>';
      if (acts.showResume) buttons += '<button class="btn btn-ghost btn-sm" type="button" data-au="resume">Resume autoupdate</button>';
      if (acts.showPin) buttons += '<button class="btn btn-ghost btn-sm" type="button" data-au="pin">Pin version</button>';
      if (acts.showUnpin) buttons += '<button class="btn btn-ghost btn-sm" type="button" data-au="unpin">Unpin</button>';
    }
    // isu-w6: Rollback is offered for every hosted box (this panel only renders
    // when the box has a host). It's a DISTINCT affordance from the policy toggles
    // — data-rollback, never data-au — and the SERVER owns whether a previous slot
    // exists: a box with nothing to flip to gets the honest no_previous_slot typed
    // conflict on click, never a flip to garbage (charter D23).
    buttons += '<button class="btn btn-ghost btn-sm" type="button" data-rollback="1">Roll back</button>';
    var actionsHtml = buttons ? '<div class="update-panel-actions">' + buttons + "</div>" : "";

    return '<div class="card update-panel">' +
      '<div class="update-panel-head"><h2>Updates</h2>' + badgeHtml + "</div>" +
      '<div class="update-panel-body">' + rows + "</div>" +
      actionsHtml +
    "</div>";
  }

  // The DOM mount for the per-instance policy buttons — the add-listener-if-present
  // pattern (browser-verified). Each button PATCHes /v1/barkparks/:id/autoupdate
  // with the ONE field it toggles; a pin prompts for a tag first.
  function wireUpdatePanel(bp) {
    var panel = $("#instance-tabpanel .update-panel");
    if (!panel) return;
    panel.querySelectorAll("[data-au]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var verb = btn.getAttribute("data-au");
        if (verb === "pin") return openPinModal(bp);
        if (verb === "unpin") return patchAutoupdate(bp, { pinned_release: null }, "Unpinned");
        if (verb === "pause") return patchAutoupdate(bp, { autoupdate_paused: true }, "Autoupdate paused");
        if (verb === "resume") return patchAutoupdate(bp, { autoupdate_paused: false }, "Autoupdate resumed");
      });
    });
    // isu-w6: the Rollback affordance (data-rollback) opens the confirm modal.
    var rb = panel.querySelector("[data-rollback]");
    if (rb) rb.addEventListener("click", function () { confirmRollbackInstance(bp); });
  }

  // The pin prompt — a release tag input with the charter's HONEST pin caveat
  // ("does not roll back"), mirroring openAttachDomainModal.
  function openPinModal(bp) {
    var current = bp.update_running_release || bp.version || "";
    openModal(
      '<h2 class="modal-title" id="modal-title">Pin ' + esc(bp.name) + " to a version</h2>" +
      '<p class="modal-sub">Freeze this instance so autoupdate holds it in place. ' +
        "Pinning holds an instance at or above its current version &mdash; it does not roll back.</p>" +
      '<form id="pin-form">' +
        '<label class="label" for="pin-input">Release tag</label>' +
        '<input class="form-input" id="pin-input" placeholder="' + esc(current ? String(current) : "v0.4.1") +
          '" value="' + esc(current ? String(current) : "") + '" autocomplete="off" spellcheck="false">' +
        '<div id="pin-error" class="form-error" hidden></div>' +
        '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
          '<button class="btn btn-primary" type="submit" id="pin-go">Pin version</button></div>' +
      "</form>"
    );
    var form = $("#pin-form");
    if (form) form.addEventListener("submit", function (e) {
      e.preventDefault();
      var value = (($("#pin-input") || {}).value || "").trim();
      var errEl = $("#pin-error");
      if (errEl) errEl.hidden = true;
      if (!value) {
        if (errEl) { errEl.hidden = false; errEl.textContent = "Enter a release tag like v0.4.1."; }
        return;
      }
      var btn = $("#pin-go");
      if (btn) { btn.disabled = true; btn.textContent = "Pinning…"; }
      patchAutoupdate(bp, { pinned_release: value }, "Pinned to " + vRel(value));
    });
  }

  // One PATCH → toast → reload. Absent route / older CP surfaces the friendly
  // error (api() never rejects). Reuses the fleetCache-bust + loadInstance path.
  function patchAutoupdate(bp, body, okTitle) {
    api("PATCH", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/autoupdate", body).then(function (r) {
      if (r.ok) {
        closeModal();
        toast({ kind: "success", title: okTitle, body: bp.name });
        fleetCache = null;
        loadInstance(bp.id);
        return;
      }
      var msg = friendly(r.data, "Please try again.");
      var errEl = $("#pin-error");
      if (errEl && document.getElementById("pin-error")) { errEl.hidden = false; errEl.textContent = msg; }
      else toast({ kind: "error", title: "Couldn't update the policy", body: msg });
      var btn = $("#pin-go");
      if (btn) { btn.disabled = false; btn.textContent = "Pin version"; }
    });
  }

  // ---- Fleet rollout banner (isu-w5) ----------------------------------------
  // GET /v1/admin/autoupdate reports the fleet-wide halt state; POST halt/resume
  // toggles it. halted → a warn banner with Resume; rolling → a quiet line with
  // Halt. Absent route / non-admin → null → nothing renders (degrade).
  function fleetRolloutBanner(state) {
    if (!state || typeof state !== "object") return null;
    if (state.halted) {
      var why = state.halted_reason || state.reason;
      return {
        tone: "warn", halted: true, title: "Fleet autoupdate is halted",
        body: why ? String(why) : "New releases won't roll out to any instance until you resume.",
        verb: "resume", actionLabel: "Resume rollout",
      };
    }
    return {
      tone: "", halted: false, title: "Fleet autoupdate is live",
      body: "Blessed releases roll out to eligible instances automatically.",
      verb: "halt", actionLabel: "Halt rollout",
    };
  }

  function fleetRolloutBannerHtml(state) {
    var b = fleetRolloutBanner(state);
    if (!b) return "";
    return '<div class="notice' + (b.tone ? " notice-" + esc(b.tone) : "") + '" role="status">' +
      "<b>" + esc(b.title) + "</b> " + esc(b.body) +
      '<button class="btn btn-sm" type="button" data-fleet-au="' + esc(b.verb) + '">' + esc(b.actionLabel) + "</button>" +
    "</div>";
  }

  // The DOM mount: fetch the fleet halt state and paint the banner slot. Silent
  // on a non-ok read (older CP 404 / non-operator 401/403) — the slot stays
  // empty. noBounce is LOAD-BEARING: the route is platform-operator gated, so a
  // plain session token 401s — without noBounce that probe would clearSession()
  // and log the user out on every fleet render.
  function loadFleetRollout(container) {
    var slot = container.querySelector("#fleet-rollout");
    if (!slot) return;
    api("GET", "/v1/admin/autoupdate", null, { noBounce: true }).then(function (r) {
      if (!r.ok || !r.data) return; // older CP / non-operator → hidden
      slot.innerHTML = fleetRolloutBannerHtml(r.data);
      var btn = slot.querySelector("[data-fleet-au]");
      if (btn) btn.addEventListener("click", function () { fleetRolloutAction(btn.getAttribute("data-fleet-au"), container); });
    });
  }

  function fleetRolloutAction(verb, container) {
    var path = "/v1/admin/autoupdate/" + (verb === "halt" ? "halt" : "resume");
    api("POST", path, {}, { noBounce: true }).then(function (r) {
      if (r.ok) {
        toast({ kind: "success", title: verb === "halt" ? "Rollout halted" : "Rollout resumed" });
        loadFleetRollout(container);
      } else {
        toast({ kind: "error", title: "Couldn't " + verb + " the rollout", body: friendly(r.data, "Please try again.") });
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
  // A4/D60: a rail reading is only honest once the box HAS a host. Pre-host
  // (provisioning / provision-failed) the health/agent columns would otherwise
  // read "Unknown"/"Offline" — scare values for a box that simply isn't up yet —
  // so render a calm "—" until there's a real signal to report.
  function railValue(raw, hasHost) { return hasHost ? raw : "—"; }
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

  // Monotonic request ticket for loadInstanceSites. When the operator switches
  // instances fast, two /v1/sites reads overlap; the LATE one must not paint
  // instance A's sites into instance B's now-showing slot (charter wave-4 "Owed
  // post-merge": A's sites can paint into B's slot). Each call captures the
  // ticket at fire time; on resolve staleGuard drops the response if a newer
  // call has since started.
  var instanceSitesReq = 0;
  // Pure: true when this response is STALE — a newer request superseded it, so
  // its paint must be discarded. Exported for the harness (drop-stale/accept).
  function staleGuard(reqId, currentId) { return reqId !== currentId; }

  function loadInstanceSites(bp) {
    // The "+ New site" header button renders with the section (idempotent
    // wiring: onclick assignment survives repeated loads without stacking).
    var nb = $("#site-new-btn");
    if (nb) nb.onclick = function () { openCreateSiteModal(bp); };
    var reqId = ++instanceSitesReq;
    api("GET", "/v1/sites").then(function (r) {
      // A newer instance switch won the race — discard this late response
      // rather than paint the wrong instance's sites into the current slot.
      if (staleGuard(reqId, instanceSitesReq)) return;
      var box = $("#instance-sites");
      if (!box) return;
      var all = (r.ok && r.data && r.data.sites) || [];
      var sites = all.filter(function (s) { return String(s.barkpark_id) === String(bp.id); });
      if (!sites.length) {
        // A4/D60: pre-host (provisioning / provision-failed) the timeline is the
        // primary surface — a "No sites yet" box beside it is just noise, so stay
        // quiet until the box is up.
        box.innerHTML = bp.host
          ? '<div class="empty-state"><h2>No sites yet</h2>' +
            "<p>Sites hosted on this instance will appear here.</p></div>"
          : "";
        return;
      }
      box.innerHTML = sites.map(function (s) { return siteRow(s, bp); }).join("");
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
    // The "Visit ↗" link opens the LIVE site — it must NOT also trigger the
    // row's drill-into-detail navigation, so swallow the bubble.
    scope.querySelectorAll(".site-open").forEach(function (a) {
      a.addEventListener("click", function (e) { e.stopPropagation(); });
    });
  }
  // The live URL of a spawned site: `<instance>/sites/<slug>/`. The DETAIL
  // surface serializes it as `s.url` (the CP loads the instance there); the LIST
  // surfaces skip that N+1, so we reconstruct it from the instance the row
  // already carries. Null when neither is available (never invent a dead link).
  function siteLiveUrl(s, bp) {
    if (s && s.url) return s.url;
    if (bp && bp.url && s && s.slug) {
      return String(bp.url).replace(/\/+$/, "") + "/sites/" + esc(s.slug).replace(/[^A-Za-z0-9._-]/g, "") + "/";
    }
    return null;
  }
  // A "Visit ↗" anchor to the live site, opened in a new tab. Empty string when
  // there is no URL, so callers can concatenate unconditionally.
  function siteOpenLink(url) {
    return url
      ? '<a class="site-open" href="' + esc(url) + '" target="_blank" rel="noopener" title="Open the live site">Visit&nbsp;&#8599;</a>'
      : "";
  }

  // ── Create-site flow (search-template W2, charter D8) ─────────────────────
  //
  // The dashboard twin of `bp cloud site create`: a modal on the instance
  // Overview posts /v1/sites with the same body the CLI sends. The three pure
  // helpers below are node-pinned via __bpTestHook.

  // Pure: the runtime kind a framework deploys as (mirrors the engine default —
  // astro is the static symlink-swap flagship, nextjs rides the node slot).
  function siteKindFor(framework) {
    return framework === "astro" ? "static" : "node";
  }

  // Pure: the shipped starters offerable for a framework ("" = the engine's
  // framework-derived default). search-starter is FEATURED for nextjs — the
  // flagship search site (finder + corpus graph + PortableDoc pages).
  function siteTemplateOptions(framework) {
    if (framework === "astro") return ["", "astro-starter"];
    if (framework === "nextjs") return ["", "search-starter", "next-starter"];
    return [""];
  }

  // Pure: the POST /v1/sites body from the form fields. Empty optionals are
  // OMITTED (the server owns every default); template "" = framework-derived.
  function siteCreateBody(f) {
    var body = {
      name: f.name,
      framework: f.framework,
      kind: siteKindFor(f.framework),
      workspace: f.workspace,
      project: f.project,
      dataset: f.dataset,
      barkpark_id: f.barkpark_id
    };
    if (f.template) body.template = f.template;
    if (f.doc_type) body.doc_type = f.doc_type;
    return body;
  }

  function siteTemplateLabel(t) {
    if (t === "") return "Auto (framework default)";
    if (t === "search-starter") return "\u2605 Search Starter \u2014 flagship: live search + corpus graph + PortableDoc";
    if (t === "next-starter") return "Next Starter \u2014 minimal SSR page";
    if (t === "astro-starter") return "Astro Starter \u2014 minimal static page";
    return t;
  }

  function siteTemplateSelectHtml(framework) {
    return siteTemplateOptions(framework).map(function (t) {
      return '<option value="' + esc(t) + '"' + (t === "search-starter" ? " selected" : "") + ">" +
        esc(siteTemplateLabel(t)) + "</option>";
    }).join("");
  }

  function openCreateSiteModal(bp) {
    // W4 (charter D18): Deploy-now is checked by default — one motion from create
    // to a live URL. It is disabled while the instance is still provisioning (a
    // deploy would 422 instance_not_live), with an honest caption saying why.
    var canDeploy = instanceCanDeploy(bp);
    openModal(
      '<h2 class="modal-title" id="modal-title">New site on ' + esc(bp.name || bp.slug || "this instance") + "</h2>" +
      '<p class="modal-sub">Spawned next to Phoenix on the box, built from a shipped starter through the six-stage engine (health-gated, instant rollback).</p>' +
      '<div class="field"><label class="label" for="site-nc-name">Name</label>' +
        '<input class="form-input" id="site-nc-name" type="text" autocomplete="off" spellcheck="false" placeholder="my-search" /></div>' +
      '<div class="field"><label class="label" for="site-nc-framework">Framework</label>' +
        '<select class="form-input" id="site-nc-framework">' +
          '<option value="nextjs" selected>Next.js (SSR, node slot)</option>' +
          '<option value="astro">Astro (static, symlink swap)</option>' +
        "</select></div>" +
      '<div class="field"><label class="label" for="site-nc-template">Starter</label>' +
        '<select class="form-input" id="site-nc-template">' + siteTemplateSelectHtml("nextjs") + "</select></div>" +
      '<div class="field"><label class="label" for="site-nc-dataset">Content (workspace/project/dataset)</label>' +
        '<input class="form-input" id="site-nc-dataset" type="text" autocomplete="off" spellcheck="false" placeholder="default/default/production" /></div>' +
      '<div class="field"><label class="label" for="site-nc-doctype">Content type <span class="dim">(optional)</span></label>' +
        '<input class="form-input" id="site-nc-doctype" type="text" autocomplete="off" spellcheck="false" placeholder="entry" /></div>' +
      '<div class="field field-check"><label class="check-row">' +
        '<input type="checkbox" id="site-nc-deploy"' + (canDeploy ? " checked" : " disabled") + " /> " +
        "<span>Deploy now <span class=\"dim\">— build and go live immediately</span></span></label>" +
        (canDeploy ? "" :
          '<div class="dim check-note">This instance is still provisioning — deploy becomes available once it’s live.</div>') +
        "</div>" +
      '<div class="cred-remediation" id="site-nc-err" role="alert" hidden></div>' +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="site-nc-submit" type="button">Create site</button></div>'
    );
    var fw = $("#site-nc-framework");
    if (fw) fw.addEventListener("change", function () {
      var sel = $("#site-nc-template");
      if (sel) sel.innerHTML = siteTemplateSelectHtml(fw.value);
    });
    var submit = $("#site-nc-submit");
    if (submit) submit.addEventListener("click", function () {
      var errBox = $("#site-nc-err");
      var name = ($("#site-nc-name").value || "").trim();
      var triple = (($("#site-nc-dataset").value || "").trim() || "").split("/");
      if (!name || triple.length !== 3 || triple.some(function (p) { return !p; })) {
        errBox.textContent = "A name and a workspace/project/dataset triple are required.";
        errBox.hidden = false;
        return;
      }
      var body = siteCreateBody({
        name: name,
        framework: fw ? fw.value : "nextjs",
        template: ($("#site-nc-template") || {}).value || "",
        workspace: triple[0], project: triple[1], dataset: triple[2],
        doc_type: ($("#site-nc-doctype").value || "").trim(),
        barkpark_id: bp.id
      });
      // Read the checkbox BEFORE closeModal() empties the modal body.
      var deployNow = canDeploy && !!($("#site-nc-deploy") && $("#site-nc-deploy").checked);
      submit.disabled = true;
      api("POST", "/v1/sites", body).then(function (r) {
        submit.disabled = false;
        if (r.ok) {
          var created = r.data && r.data.site;
          closeModal();
          if (created && created.id && deployNow) {
            // One motion: create \u2192 deploy \u2192 live rail \u2192 copyable URL toast.
            createAndDeploy(bp, created);
          } else {
            // Toast bug fix: a bare-string toast is silently dropped (toast()
            // reads opts.kind/title/body/action) \u2014 pass an object.
            toast({ kind: "success", title: "Site created", body: "First deploy makes it live." });
            loadInstanceSites(bp);
          }
        } else {
          var msg = (r.data && (r.data.error || r.data.message)) || ("create failed (" + r.status + ")");
          var known = r.data && r.data.known_templates;
          errBox.textContent = String(msg) + (known ? " \u2014 templates: " + known.join(", ") : "");
          errBox.hidden = false;
        }
      });
    });
  }

  function siteRow(s, bp) {
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
        siteOpenLink(siteLiveUrl(s, bp)) +
        freshnessBadge(s) +
        badge(auto ? "Auto-deploy" : "Manual", auto ? "online" : "unknown") +
        '<span class="fleet-chev" aria-hidden="true">&rsaquo;</span>' +
      "</div></div>";
  }

  // =========================================================== WEBHOOKS TAB (C6)
  // The instance-workspace Webhooks tab, driven ENTIRELY through the C4/C5
  // control-plane proxy (`/v1/barkparks/:id/api/webhooks…`): the browser never
  // touches the instance's admin token, and every reply is the uniform proxy
  // envelope ({ok, resource, data} | {ok:false, error:{code,…}}). Instance-API
  // mutations have NO SSE confirmation, so every optimistic action reconciles on
  // the HTTP RESPONSE body — never on the guess (charter D18/D51/D55).

  // The instance identifier the copy-as-CLI chips name. The id is stable and
  // always resolvable (a rename can't stale a copied command).
  function cliInstance(bp) { return String((bp && bp.id) || ""); }

  // The ONE ratified verb grammar, byte-for-byte with C7's parser:
  //   bp cloud webhook <verb> <instance> [--dataset production]
  // `--dataset` is emitted only for a NON-default dataset (production is the
  // documented default), so the common chip stays terse.
  function webhookCliChip(verb, instance, dataset) {
    var cmd = "bp cloud webhook " + verb + " " + instance;
    if (dataset && dataset !== "production") cmd += " --dataset " + dataset;
    return cmd;
  }

  // A copy-as-CLI chip: the command in mono + the shared [data-copy] affordance
  // (the delegated clipboard handler toasts "Copied").
  function cliChipHtml(cmd) {
    return '<span class="cli-chip"><code class="cli-chip-code">' + esc(cmd) + "</code>" +
      '<button class="copy-btn" type="button" data-copy="' + esc(cmd) +
      '" aria-label="Copy CLI command">' + COPY_SVG + "</button></span>";
  }

  // Pure: the event/type filter chips for a webhook row (empty subscription =
  // "all events", matching the instance dispatcher's fan-out-to-all default).
  function webhookEventsHtml(wh) {
    wh = wh || {};
    var evs = (wh.events || []).map(function (e) { return String(e); });
    var types = (wh.types || []).map(function (t) { return "type:" + String(t); });
    var all = evs.concat(types);
    if (!all.length) {
      return '<div class="wh-events"><span class="wh-event-chip wh-event-chip--all">all events</span></div>';
    }
    return '<div class="wh-events">' +
      all.map(function (x) { return '<span class="wh-event-chip">' + esc(x) + "</span>"; }).join("") +
      "</div>";
  }

  // Pure: the AUTODISABLE banner (charter #1013 substrate). Renders ONLY when the
  // row carries `auto_disabled_at` AND is still inactive, and prints
  // `disable_reason` + `consecutive_failures` VERBATIM from the row (never a
  // client re-derivation) — the honest reason the instance's dispatcher gave up.
  // The Re-enable button PUTs {active:true} through the update capability (there
  // is NO toggle route). The `active` gate matters: the instance's update path
  // can't clear the server-managed `auto_disabled_at` stamp (not castable), so a
  // re-enabled row keeps the old stamp — without the gate, Re-enable would
  // "succeed" and the reconciled card would STILL shout Auto-disabled next to an
  // Active pill, forever.
  function webhookBannerHtml(wh) {
    wh = wh || {};
    if (!wh.auto_disabled_at || wh.active) return "";
    var reason = wh.disable_reason != null && String(wh.disable_reason) !== ""
      ? esc(wh.disable_reason)
      : "This endpoint was auto-disabled after repeated delivery failures.";
    var count = wh.consecutive_failures != null
      ? ' <span class="wh-autodisable-count">' + esc(wh.consecutive_failures) + " consecutive failures</span>"
      : "";
    return '<div class="notice notice-error wh-autodisable" role="alert">' +
      '<span class="wh-autodisable-text"><b>Auto-disabled.</b> ' + reason + count + "</span>" +
      '<button class="btn btn-sm" type="button" data-wh-reenable>Re-enable</button>' +
      "</div>";
  }

  // Pure: one webhook row. Renders url/events/active + the autodisable banner, an
  // action bar (toggle / rotate / deliveries / delete), and copy-as-CLI chips for
  // every action. State is rendered from the ROW, so a reconciled response
  // repaints the true state (D55: pre-C6.5 instances degrade to their stale
  // stamps honestly rather than to an optimistic guess).
  function webhookCardHtml(wh, instance, dataset) {
    wh = wh || {};
    var active = !!wh.active;
    var pill = active
      ? '<span class="status-pill status-pill--ok"><span class="status-pill-dot" aria-hidden="true"></span><span class="status-pill-label">Active</span></span>'
      : '<span class="status-pill status-pill--neutral"><span class="status-pill-dot" aria-hidden="true"></span><span class="status-pill-label">Disabled</span></span>';
    var toggleBtn = active
      ? '<button class="btn btn-sm" type="button" data-wh-toggle>Disable</button>'
      : '<button class="btn btn-sm" type="button" data-wh-toggle>Enable</button>';
    var fails = wh.consecutive_failures != null && wh.consecutive_failures > 0
      ? '<span class="wh-meta-fail">' + esc(wh.consecutive_failures) + " consecutive failures</span>"
      : "";
    var updated = wh.updated_at ? "Updated " + esc(fmtWhen(wh.updated_at)) : "";
    var meta = [updated, fails].filter(Boolean).join(" &middot; ");
    return '<div class="wh-card" data-wh="' + esc(wh.id) + '">' +
      '<div class="wh-card-head">' +
        '<div class="wh-card-id">' +
          (wh.name ? '<div class="wh-name">' + esc(wh.name) + "</div>" : "") +
          '<div class="wh-url">' + esc(wh.url) + "</div>" +
          webhookEventsHtml(wh) +
        "</div>" + pill +
      "</div>" +
      webhookBannerHtml(wh) +
      (meta ? '<div class="wh-meta">' + meta + "</div>" : "") +
      '<div class="wh-actions">' +
        '<button class="btn btn-sm" type="button" data-wh-edit>Edit</button>' +
        toggleBtn +
        '<button class="btn btn-sm" type="button" data-wh-rotate>Rotate secret</button>' +
        '<button class="btn btn-sm" type="button" data-wh-deliveries>Deliveries</button>' +
        '<button class="btn btn-sm btn-danger" type="button" data-wh-delete>Delete</button>' +
        '<span class="wh-toggle-note" role="status" hidden></span>' +
      "</div>" +
      '<div class="wh-cli">' +
        cliChipHtml(webhookCliChip("show", instance, dataset)) +
        cliChipHtml(webhookCliChip("toggle", instance, dataset)) +
        cliChipHtml(webhookCliChip("rotate", instance, dataset)) +
        cliChipHtml(webhookCliChip("deliveries", instance, dataset)) +
        cliChipHtml(webhookCliChip("rm", instance, dataset)) +
      "</div>" +
      '<div class="wh-deliveries" data-wh-deliveries-box hidden></div>' +
      "</div>";
  }

  // Pure: the semantic tone of a delivery — the SAME status token contract as the
  // rest of the SPA (2xx → ok, 4xx/5xx → danger, pending/other → info).
  function deliveryTone(d) {
    d = d || {};
    var code = d.status_code != null ? d.status_code : d.last_status_code;
    if (code == null) {
      // The instance's actual vocabulary is pending|ok|failed_giveup
      // (Delivery @statuses); the extra aliases are shape-drift insurance.
      var s = String(d.status || "").toLowerCase();
      if (s === "delivered" || s === "success" || s === "ok") return "ok";
      if (s === "failed_giveup" || s === "failed" || s === "error" || s === "giveup") return "danger";
      return "info"; // pending / queued / unknown
    }
    code = Number(code);
    if (code >= 200 && code < 300) return "ok";
    if (code >= 400) return "danger";
    return "info"; // 3xx / 0 / other
  }

  // Pure: one delivery-log row — status code (toned), latency, when, attempts,
  // plus a per-row Replay button and, when the instance recorded one, the
  // verbatim `last_error_text` (the WHY of a failure — connection refused, TLS,
  // 500 body — not just the tone). `delivered_at`/`status_code` are read
  // defensively (the instance's render_delivery names them updated_at /
  // last_status_code today; a future rename won't blank the row).
  function deliveryRowHtml(d, instance, dataset) {
    d = d || {};
    var tone = deliveryTone(d);
    var code = d.status_code != null ? d.status_code : d.last_status_code;
    // A code-less row falls back to the status word; "failed_giveup" (the
    // instance's terminal status token) reads "failed" — same truth, no jargon.
    var codeLabel = code != null
      ? String(code)
      : (d.status ? (String(d.status) === "failed_giveup" ? "failed" : String(d.status)) : "pending");
    var latency = d.last_latency_ms != null ? esc(d.last_latency_ms) + "ms" : "&mdash;";
    var when = esc(fmtWhen(d.delivered_at || d.updated_at || d.created_at));
    var attempts = d.attempts != null
      ? esc(d.attempts) + (String(d.attempts) === "1" ? " attempt" : " attempts")
      : "&mdash;";
    var evId = d.event_id != null && d.event_id !== "" ? d.event_id : null;
    var errText = d.last_error_text != null && String(d.last_error_text) !== ""
      ? '<span class="wh-del-err">' + esc(d.last_error_text) + "</span>"
      : "";
    return '<div class="wh-delivery">' +
      '<span class="wh-del-status wh-del-status--' + tone + '">' + esc(codeLabel) + "</span>" +
      '<span class="wh-del-meta">' +
        (evId !== null ? "event #" + esc(evId) + " &middot; " : "") +
        latency + " &middot; " + when + " &middot; " + attempts +
      "</span>" +
      (evId !== null ? '<button class="btn btn-sm" type="button" data-wh-replay="' + esc(evId) + '">Replay</button>' : "") +
      errText +
      "</div>";
  }

  // Pure: the enable/disable toggle's rendered state under the D18 optimistic
  // grammar. `active` is the last KNOWN server truth; `phase` is the in-flight
  // status. Pending shows the transitional label; a failed/timed-out resolve
  // returns to the known state with an honest 'Unconfirmed — retry' note — the
  // toggle NEVER lies about a change the server did not confirm.
  function hookToggleState(active, phase) {
    active = !!active;
    phase = phase || "idle";
    if (phase === "pending") {
      return { disabled: true, checked: active, label: active ? "Disabling…" : "Enabling…", tone: "info", note: "" };
    }
    if (phase === "unconfirmed") {
      return { disabled: false, checked: active, label: active ? "Disable" : "Enable", tone: "warn", note: "Unconfirmed — retry" };
    }
    return { disabled: false, checked: active, label: active ? "Disable" : "Enable", tone: "neutral", note: "" };
  }

  // Pure: the honest degradation block for a failed webhooks fetch (charter D51).
  // The tab is ABOUT the box, not served BY it — an unreachable box gets a
  // retry, never an infinite spinner; a too-old box gets the update chip; a
  // coded (or older uncoded 404) not-found says so plainly.
  function webhookErrorHtml(resp, instance) {
    resp = resp || {};
    var err = resp.error || {};
    var code = typeof err === "object" ? err.code : null;
    var status = typeof err === "object" ? err.status : null;
    var detail = typeof err === "object" && typeof err.detail === "string" ? err.detail : null;
    var title, body, retry = true, updateChip = false;
    if (resp.reachable === false || code === "instance_unreachable") {
      title = "This instance is unreachable";
      body = "We couldn't reach the box to load its webhooks — it may be restarting. This tab is about the instance, not served by it.";
    } else if (err === "network_error") {
      // api()'s fetch-catch shape: the CONTROL PLANE didn't answer (a string
      // code, not the proxy envelope) — distinct from the box being down.
      title = "Network error";
      body = ERRORS.network_error;
    } else if (code === "capability_unavailable") {
      title = "This instance needs an update";
      body = "Webhook management needs a newer Barkpark on this instance. Update it to enable this tab.";
      retry = false;
      updateChip = true;
    } else if (code === "not_live") {
      title = "This instance isn't live yet";
      body = "Webhooks become available once provisioning finishes.";
    } else if (code === "no_admin_token") {
      title = "No stored credentials";
      body = "This instance has no admin token on file — it may need a re-provision.";
      retry = false;
    } else if (code === "webhook_not_found" || (code === "upstream_error" && status === 404)) {
      title = "Webhook not found";
      body = "This endpoint no longer exists — it may have been deleted elsewhere.";
    } else {
      title = "Couldn't load webhooks";
      body = detail || "Something went wrong reaching this instance.";
    }
    return '<div class="wh-error empty-state"><h2>' + esc(title) + "</h2><p>" + esc(body) + "</p>" +
      (retry ? '<p><button class="btn btn-sm btn-primary" type="button" data-wh-retry>Retry</button></p>' : "") +
      (updateChip ? '<div class="wh-cli wh-cli--center">' + cliChipHtml("bp cloud update " + instance) + "</div>" : "") +
      "</div>";
  }

  // A friendly one-liner for a FAILED mutation envelope (create/toggle/rotate/
  // delete/replay). The proxy relays instance validation as
  // upstream_error{status, detail:<instance envelope>}; dig the first field
  // error out of that so the form/toast is specific, not generic.
  function webhookMutationError(data) {
    data = data || {};
    var err = data.error || {};
    // api()'s fetch-catch shape is { error: "network_error" } (a STRING, the
    // control plane itself unreachable) — telling the user to "check the
    // details" for that would be actively wrong.
    if (err === "network_error") return ERRORS.network_error;
    if (data.reachable === false || err.code === "instance_unreachable") {
      return "Couldn't reach the instance — the change is unconfirmed.";
    }
    if (err.code === "capability_unavailable") return "This instance needs an update to manage webhooks.";
    if (err.code === "not_live") return ERRORS.not_live;
    var d = err.detail;
    if (d && typeof d === "object" && d.error) {
      var e2 = d.error;
      if (e2.details && typeof e2.details === "object") {
        var k = Object.keys(e2.details)[0];
        if (k) {
          var m = e2.details[k];
          if (Array.isArray(m)) m = m[0];
          return k.replace(/_/g, " ") + " " + m;
        }
      }
      if (e2.message) return String(e2.message);
    }
    return "Please check the details and try again.";
  }

  // The proxy path for a webhook capability under a dataset. `suffix` is "" for
  // the collection or "/<id>[/…]" for a specific endpoint.
  function whPath(bp, suffix, ds) {
    return "/v1/barkparks/" + encodeURIComponent(bp.id) + "/api/webhooks" + (suffix || "") +
      "?dataset=" + encodeURIComponent(ds || "production");
  }

  function webhooksTabShellHtml(bp, ds) {
    return '<div class="wh-toolbar">' +
      '<div class="wh-dataset">' +
        '<label class="wh-dataset-label" for="wh-dataset-input">Dataset</label>' +
        '<input class="form-input wh-dataset-input" id="wh-dataset-input" value="' + esc(ds) +
          '" spellcheck="false" autocomplete="off" autocapitalize="off">' +
        '<button class="btn btn-sm" type="button" data-wh-load>Load</button>' +
      "</div>" +
      '<button class="btn btn-primary btn-sm" type="button" data-wh-new>New webhook</button>' +
      "</div>" +
      '<div class="wh-list" aria-live="polite"><div class="loading">Loading webhooks&hellip;</div></div>';
  }

  function whListHeadHtml(bp, ds, count) {
    return '<div class="wh-list-head">' +
      '<span class="wh-list-count">' + esc(count) + " webhook" + (count === 1 ? "" : "s") +
        " on " + esc(ds) + "</span>" +
      cliChipHtml(webhookCliChip("list", cliInstance(bp), ds)) +
      "</div>";
  }

  function currentWhDataset(root) {
    var input = root && root.querySelector ? root.querySelector(".wh-dataset-input") : null;
    var v = input && input.value ? String(input.value).trim() : "";
    return v || "production";
  }

  function findWhCard(listBox, id) {
    if (!listBox || !listBox.querySelectorAll) return null;
    var cards = listBox.querySelectorAll(".wh-card");
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].getAttribute("data-wh") === String(id)) return cards[i];
    }
    return null;
  }

  // Render + wire the Webhooks tab into a mounted panel. Kept side-effect-light
  // so the fake-DOM smoke can drive it: the shell paints synchronously, the list
  // fetch fills in on resolve.
  function mountWebhooksTab(root, bp) {
    // Defensive re-acquire by id: the caller passes the freshly-rendered tabpanel,
    // but a lost ref still resolves through getElementById — so the panel shell
    // renders (and stays observable to the preview harness) rather than no-op.
    // Same idiom as mountUsageTab.
    if (!root && typeof document !== "undefined" && document.getElementById) root = document.getElementById("instance-tabpanel");
    if (!root) return;
    var ds = "production";
    root.innerHTML = webhooksTabShellHtml(bp, ds);
    wireWebhooksToolbar(root, bp);
    loadWebhooks(root, bp, ds);
  }

  function wireWebhooksToolbar(root, bp) {
    if (!root || !root.querySelector) return;
    var load = root.querySelector("[data-wh-load]");
    var input = root.querySelector(".wh-dataset-input");
    var go = function () { loadWebhooks(root, bp, currentWhDataset(root)); };
    if (load) load.addEventListener("click", go);
    if (input) input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); go(); }
    });
    var neu = root.querySelector("[data-wh-new]");
    if (neu) neu.addEventListener("click", function () { openCreateWebhookModal(root, bp, currentWhDataset(root)); });
  }

  var webhookLoadSeq = 0;
  function loadWebhooks(root, bp, ds) {
    // .wh-list is the swap target in the live DOM; if a harness (smoke.mjs) can't
    // resolve the sub-query it falls back to the root itself — the same element
    // the list lands in — so the endpoint list stays observable (mirrors
    // mountUsageTab's `.fleet-body || panel` fallback). Live DOM always resolves
    // .wh-list, so behaviour there is unchanged.
    var listBox = (root && root.querySelector && root.querySelector(".wh-list")) || root;
    if (!listBox) return;
    var seq = ++webhookLoadSeq;
    listBox.innerHTML = '<div class="loading">Loading webhooks&hellip;</div>';
    api("GET", whPath(bp, "", ds)).then(function (r) {
      if (seq !== webhookLoadSeq) return; // a newer dataset load owns the list
      if (!r.ok) {
        listBox.innerHTML = webhookErrorHtml(r.data, cliInstance(bp));
        var rt = listBox.querySelector("[data-wh-retry]");
        if (rt) rt.addEventListener("click", function () { loadWebhooks(root, bp, ds); });
        return;
      }
      var whs = (r.data && r.data.data && r.data.data.webhooks) || [];
      var head = whListHeadHtml(bp, ds, whs.length);
      if (!whs.length) {
        listBox.innerHTML = head +
          '<div class="empty-state wh-empty"><h2>No webhooks on ' + esc(ds) + "</h2>" +
          "<p>Deliver document mutation events to your own endpoints.</p>" +
          '<p><button class="btn btn-sm btn-primary" type="button" data-wh-new>New webhook</button></p></div>';
        var neu = listBox.querySelector("[data-wh-new]");
        if (neu) neu.addEventListener("click", function () { openCreateWebhookModal(root, bp, ds); });
        return;
      }
      listBox.innerHTML = head + whs.map(function (w) { return webhookCardHtml(w, cliInstance(bp), ds); }).join("");
      whs.forEach(function (w) { wireWebhookCard(listBox, bp, ds, w); });
    });
  }

  function wireWebhookCard(listBox, bp, ds, wh) {
    var card = findWhCard(listBox, wh.id);
    if (!card) return;
    var on = function (sel, fn) { var el = card.querySelector(sel); if (el) el.addEventListener("click", fn); };
    on("[data-wh-edit]", function () { openEditWebhookModal(listBox, bp, ds, wh); });
    on("[data-wh-toggle]", function () { toggleWebhook(listBox, bp, ds, wh, false); });
    on("[data-wh-reenable]", function () { toggleWebhook(listBox, bp, ds, wh, true); });
    on("[data-wh-rotate]", function () { rotateWebhook(listBox, bp, ds, wh); });
    on("[data-wh-delete]", function () { confirmDeleteWebhook(listBox, bp, ds, wh); });
    var del = card.querySelector("[data-wh-deliveries]");
    if (del) del.addEventListener("click", function () { toggleDeliveries(listBox, bp, ds, wh, del); });
  }

  // Replace ONE card node from a reconciled webhook row and re-wire it. Isolates
  // the repaint so a toggle/rotate on one row can't disturb another's open
  // delivery log.
  function renderWhCard(listBox, bp, ds, wh) {
    var card = findWhCard(listBox, wh.id);
    if (!card || !card.parentNode) return;
    var tmp = document.createElement("div");
    tmp.innerHTML = webhookCardHtml(wh, cliInstance(bp), ds);
    var fresh = tmp.firstChild;
    if (!fresh) return;
    card.parentNode.replaceChild(fresh, card);
    wireWebhookCard(listBox, bp, ds, wh);
  }

  function setWhToggleNote(card, note) {
    var el = card && card.querySelector ? card.querySelector(".wh-toggle-note") : null;
    if (!el) return;
    if (note) { el.textContent = note; el.hidden = false; }
    else { el.textContent = ""; el.hidden = true; }
  }

  // Enable/disable through the UPDATE capability (PUT {active}); there is NO
  // toggle route (wave-C1 ratification (a)). Optimistic label flips to pending,
  // then reconciles on the RESPONSE body — the banner/pill repaint from what the
  // instance actually returned, never from the guess.
  function toggleWebhook(listBox, bp, ds, wh, forceEnable) {
    var target = forceEnable ? true : !wh.active;
    var card = findWhCard(listBox, wh.id);
    var btn = card && (card.querySelector("[data-wh-toggle]") || card.querySelector("[data-wh-reenable]"));
    var pending = hookToggleState(wh.active, "pending");
    if (btn) { btn.disabled = true; btn.textContent = pending.label; }
    setWhToggleNote(card, "");
    api("PUT", whPath(bp, "/" + encodeURIComponent(wh.id), ds), { active: target }).then(function (r) {
      var updated = r.ok && r.data && r.data.data && r.data.data.webhook;
      if (updated) {
        renderWhCard(listBox, bp, ds, updated);
        toast({ kind: "success", title: target ? "Webhook enabled" : "Webhook disabled", body: wh.url });
        return;
      }
      var unc = hookToggleState(wh.active, "unconfirmed");
      if (btn) { btn.disabled = unc.disabled; btn.textContent = unc.label; }
      setWhToggleNote(card, unc.note);
      // Title stays failure-agnostic: the body (webhookMutationError) says
      // WHY — unreachable, needs-update, validation — the title must not
      // claim "unreachable" for a validation reply.
      toast({ kind: "error", title: target ? "Couldn't enable the webhook" : "Couldn't disable the webhook", body: webhookMutationError(r.data) });
    });
  }

  function rotateWebhook(listBox, bp, ds, wh) {
    var card = findWhCard(listBox, wh.id);
    var btn = card && card.querySelector("[data-wh-rotate]");
    // textContent, not innerHTML — an entity here would render literally.
    if (btn) { btn.disabled = true; btn.textContent = "Rotating…"; }
    api("POST", whPath(bp, "/" + encodeURIComponent(wh.id) + "/rotate", ds), {}).then(function (r) {
      var secret = r.ok && r.data && r.data.data && r.data.data.secret;
      if (secret) {
        showWebhookSecretModal(secret);
        var updated = r.data.data.webhook;
        if (updated) renderWhCard(listBox, bp, ds, updated);
        else if (btn) { btn.disabled = false; btn.textContent = "Rotate secret"; }
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Rotate secret"; }
      toast({ kind: "error", title: "Couldn't rotate the secret", body: webhookMutationError(r.data) });
    });
  }

  // The rotated secret is returned EXACTLY once — a shown-once modal with a copy
  // button and the explicit "you will not see this again" warning.
  function showWebhookSecretModal(secret) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Signing secret</h2>' +
      '<p class="modal-sub">Copy this secret now &mdash; you will not see it again.</p>' +
      '<div class="wh-secret"><code class="wh-secret-code">' + esc(secret) + "</code>" +
        '<button class="btn btn-sm" type="button" data-copy="' + esc(secret) + '">Copy</button></div>' +
      '<div class="modal-actions"><button class="btn btn-primary" type="button" data-close>Done</button></div>'
    );
  }

  // The mutation-event vocabulary the instance dispatcher fans out on — the ONE
  // list both the create and edit modals draw their checkboxes from, so their
  // event set can never drift apart.
  var WEBHOOK_EVENTS = ["create", "update", "publish", "unpublish", "delete", "discardDraft", "patch"];

  // Pure: the event-checkbox grid, marking every event in `selected` checked.
  // Shared by the create (nothing selected) + edit (pre-filled) modals.
  function webhookEventPickHtml(selected) {
    var sel = (selected || []).map(function (e) { return String(e); });
    return '<div class="wh-events-pick">' + WEBHOOK_EVENTS.map(function (e) {
      var on = sel.indexOf(e) >= 0 ? " checked" : "";
      return '<label class="wh-event-opt"><input type="checkbox" class="wh-event-cb" value="' + esc(e) + '"' + on + "> " + esc(e) + "</label>";
    }).join("") + "</div>";
  }

  function openCreateWebhookModal(root, bp, ds) {
    openModal(
      '<h2 class="modal-title" id="modal-title">New webhook</h2>' +
      '<p class="modal-sub">Deliver document mutation events on <b>' + esc(ds) + "</b> to an HTTPS endpoint.</p>" +
      '<form id="wh-create-form" class="wh-form">' +
        '<label class="label" for="wh-c-name">Name</label>' +
        '<input class="form-input" id="wh-c-name" required autocomplete="off">' +
        '<label class="label" for="wh-c-url">Payload URL</label>' +
        '<input class="form-input" id="wh-c-url" type="url" placeholder="https://example.com/hooks" required autocomplete="off" spellcheck="false">' +
        '<span class="label">Events <span class="muted">(none = all)</span></span>' +
        webhookEventPickHtml([]) +
        '<label class="label" for="wh-c-types">Document types <span class="muted">(optional, comma-separated)</span></label>' +
        '<input class="form-input" id="wh-c-types" autocomplete="off" placeholder="post, page">' +
        '<div id="wh-c-error" class="form-error" hidden></div>' +
        '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
          '<button class="btn btn-primary" type="submit">Create webhook</button></div>' +
      "</form>"
    );
    var form = $("#wh-create-form");
    if (form) form.addEventListener("submit", function (e) { e.preventDefault(); submitCreateWebhook(root, bp, ds); });
  }

  // Pure: the EDIT modal body, pre-filled from the listed webhook row — name,
  // payload URL, the event subscription (checked), and comma-joined types. Field
  // ids are e-prefixed so they can never collide with an open create form. The
  // whole surface is one testable string (adapts openCreateWebhookModal).
  function webhookEditFormHtml(wh) {
    wh = wh || {};
    var types = (wh.types || []).map(function (t) { return String(t); }).join(", ");
    return '<h2 class="modal-title" id="modal-title">Edit webhook</h2>' +
      '<p class="modal-sub">Update where and what this endpoint receives &mdash; changes apply on save.</p>' +
      '<form id="wh-edit-form" class="wh-form">' +
        '<label class="label" for="wh-e-name">Name</label>' +
        '<input class="form-input" id="wh-e-name" required autocomplete="off" value="' + esc(wh.name || "") + '">' +
        '<label class="label" for="wh-e-url">Payload URL</label>' +
        '<input class="form-input" id="wh-e-url" type="url" placeholder="https://example.com/hooks" required autocomplete="off" spellcheck="false" value="' + esc(wh.url || "") + '">' +
        '<span class="label">Events <span class="muted">(none = all)</span></span>' +
        webhookEventPickHtml(wh.events) +
        '<label class="label" for="wh-e-types">Document types <span class="muted">(optional, comma-separated)</span></label>' +
        '<input class="form-input" id="wh-e-types" autocomplete="off" placeholder="post, page" value="' + esc(types) + '">' +
        '<div id="wh-e-error" class="form-error" hidden></div>' +
        '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
          '<button class="btn btn-primary" type="submit">Save changes</button></div>' +
      "</form>";
  }

  // Pure: the FULL PUT body from the edit form's gathered state. name/url are
  // trimmed; events + types are ALWAYS sent as arrays (an empty array clears the
  // filter → all events / all types) so an edit can REMOVE a subscription, not
  // only add one. This is the single place the edited body is shaped, so the
  // wire contract is pinned by one unit test.
  function webhookEditBody(state) {
    state = state || {};
    var events = (state.events || []).map(function (s) { return String(s).trim(); }).filter(Boolean);
    var types = (state.types || []).map(function (s) { return String(s).trim(); }).filter(Boolean);
    return {
      name: String(state.name || "").trim(),
      url: String(state.url || "").trim(),
      events: events,
      types: types
    };
  }

  function openEditWebhookModal(listBox, bp, ds, wh) {
    openModal(webhookEditFormHtml(wh));
    var form = $("#wh-edit-form");
    if (form) form.addEventListener("submit", function (e) { e.preventDefault(); submitEditWebhook(listBox, bp, ds, wh); });
  }

  // PUT the full edited body through the SAME generic update path the toggle uses
  // (whPath + api()); the control-plane proxy forwards the body verbatim and the
  // upstream changeset casts name/url/events/types. On success we refetch the
  // list so the reconciled rows repaint from server truth; a failure keeps the
  // modal open with exactly one honest sentence (webhookMutationError, D25).
  function submitEditWebhook(listBox, bp, ds, wh) {
    var typesRaw = ($("#wh-e-types") || {}).value || "";
    var events = [];
    document.querySelectorAll(".wh-event-cb").forEach(function (cb) { if (cb.checked) events.push(cb.value); });
    var body = webhookEditBody({
      name: ($("#wh-e-name") || {}).value || "",
      url: ($("#wh-e-url") || {}).value || "",
      events: events,
      types: typesRaw.split(",")
    });
    var errEl = $("#wh-e-error");
    if (errEl) errEl.hidden = true;
    var btn = document.querySelector('#wh-edit-form button[type="submit"]');
    if (btn) { btn.disabled = true; btn.textContent = "Saving…"; }
    api("PUT", whPath(bp, "/" + encodeURIComponent(wh.id), ds), body).then(function (r) {
      if (r.ok) {
        closeModal();
        toast({ kind: "success", title: "Webhook updated", body: body.url });
        // .wh-list is a direct child of the tab panel (webhooksTabShellHtml), so
        // its parent IS the root loadWebhooks re-queries; fall back to the list
        // node itself if it is somehow detached.
        var root = (listBox && listBox.parentNode) || listBox;
        loadWebhooks(root, bp, ds);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Save changes"; }
      if (errEl) { errEl.hidden = false; errEl.textContent = webhookMutationError(r.data); }
    });
  }

  function submitCreateWebhook(root, bp, ds) {
    var name = (($("#wh-c-name") || {}).value || "").trim();
    var url = (($("#wh-c-url") || {}).value || "").trim();
    var typesRaw = ($("#wh-c-types") || {}).value || "";
    var events = [];
    document.querySelectorAll(".wh-event-cb").forEach(function (cb) { if (cb.checked) events.push(cb.value); });
    var types = typesRaw.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
    var errEl = $("#wh-c-error");
    if (errEl) errEl.hidden = true;
    var body = { name: name, url: url };
    if (events.length) body.events = events;
    if (types.length) body.types = types;
    var btn = document.querySelector('#wh-create-form button[type="submit"]');
    if (btn) { btn.disabled = true; btn.textContent = "Creating…"; }
    api("POST", whPath(bp, "", ds), body).then(function (r) {
      if (r.ok || r.status === 201) {
        closeModal();
        toast({ kind: "success", title: "Webhook created", body: url });
        loadWebhooks(root, bp, ds);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Create webhook"; }
      if (errEl) { errEl.hidden = false; errEl.textContent = webhookMutationError(r.data); }
    });
  }

  // Delete behind a typed-name confirm (charter D5 grammar) — reusing openModal's
  // focus-trap + inert-background verbatim; the danger button unlocks only when
  // the endpoint's name is typed exactly.
  function confirmDeleteWebhook(listBox, bp, ds, wh) {
    var expect = wh.name || wh.url || String(wh.id);
    openModal(
      '<h2 class="modal-title" id="modal-title">Delete this webhook?</h2>' +
      '<p class="modal-sub">This removes the endpoint <b>' + esc(wh.url) + "</b> and its delivery history. It can't be undone.</p>" +
      '<label class="label" for="wh-del-confirm">Type <b>' + esc(expect) + "</b> to confirm</label>" +
      '<input class="form-input" id="wh-del-confirm" autocomplete="off" spellcheck="false">' +
      '<div id="wh-del-error" class="form-error" hidden></div>' +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" type="button" id="wh-del-go" disabled>Delete webhook</button></div>'
    );
    var input = $("#wh-del-confirm");
    var go = $("#wh-del-go");
    if (input && go) {
      input.addEventListener("input", function () { go.disabled = input.value !== expect; });
      // Enter in the confirm field fires the (unlocked) delete — keyboard
      // parity with every other form; a mismatch keeps the button disabled.
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); if (!go.disabled) go.click(); }
      });
      go.addEventListener("click", function () { deleteWebhook(listBox, bp, ds, wh, go); });
    }
  }

  function deleteWebhook(listBox, bp, ds, wh, btn) {
    if (btn) { btn.disabled = true; btn.textContent = "Deleting…"; }
    api("DELETE", whPath(bp, "/" + encodeURIComponent(wh.id), ds)).then(function (r) {
      if (r.ok) {
        closeModal();
        toast({ kind: "success", title: "Webhook deleted", body: wh.url });
        var card = findWhCard(listBox, wh.id);
        if (card && card.parentNode) card.parentNode.removeChild(card);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Delete webhook"; }
      var errEl = $("#wh-del-error");
      if (errEl) { errEl.hidden = false; errEl.textContent = webhookMutationError(r.data); }
    });
  }

  function toggleDeliveries(listBox, bp, ds, wh, btn) {
    var card = findWhCard(listBox, wh.id);
    var box = card && card.querySelector("[data-wh-deliveries-box]");
    if (!box) return;
    if (!box.hidden) { hide(box); if (btn) btn.textContent = "Deliveries"; return; }
    show(box);
    if (btn) btn.textContent = "Hide deliveries";
    loadDeliveries(listBox, bp, ds, wh);
  }

  function loadDeliveries(listBox, bp, ds, wh) {
    var card = findWhCard(listBox, wh.id);
    var box = card && card.querySelector("[data-wh-deliveries-box]");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading deliveries&hellip;</div>';
    api("GET", whPath(bp, "/" + encodeURIComponent(wh.id) + "/deliveries", ds)).then(function (r) {
      if (!r.ok) {
        box.innerHTML = webhookErrorHtml(r.data, cliInstance(bp));
        var rt = box.querySelector("[data-wh-retry]");
        if (rt) rt.addEventListener("click", function () { loadDeliveries(listBox, bp, ds, wh); });
        return;
      }
      var rows = (r.data && r.data.data && r.data.data.deliveries) || [];
      // Sanctioned copy hint (wave-C1 ratification (d)): replay-to-inactive is
      // allowed and delivers to the URL regardless of the endpoint's state.
      var hint = !wh.active
        ? '<div class="wh-del-hint muted">This endpoint is disabled &mdash; a replay is still delivered to its URL.</div>'
        : "";
      if (!rows.length) {
        box.innerHTML = hint + '<div class="wh-del-empty muted">No deliveries yet.</div>';
        return;
      }
      box.innerHTML = hint + rows.map(function (d) { return deliveryRowHtml(d, cliInstance(bp), ds); }).join("");
      box.querySelectorAll("[data-wh-replay]").forEach(function (b) {
        b.addEventListener("click", function () {
          replayDelivery(listBox, bp, ds, wh, b.getAttribute("data-wh-replay"), b);
        });
      });
    });
  }

  function replayDelivery(listBox, bp, ds, wh, eventId, btn) {
    if (btn) { btn.disabled = true; btn.textContent = "Replaying…"; }
    api("POST", whPath(bp, "/" + encodeURIComponent(wh.id) + "/deliveries/" + encodeURIComponent(eventId) + "/replay", ds), {}).then(function (r) {
      if (r.ok) {
        toast({ kind: "success", title: "Replayed", body: "event #" + eventId });
        loadDeliveries(listBox, bp, ds, wh);
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = "Replay"; }
      toast({ kind: "error", title: "Couldn't replay", body: webhookMutationError(r.data) });
    });
  }

  // ============================== TIMELINE TAB + VERIFY CHIPS (C8/D10/D53)
  // The instance's incident home: GET /v1/barkparks/:id/events (newest-first;
  // agent events, provisioning steps, and `verify` runs) merged chronologically
  // with the instance-scoped slice of GET /v1/audit into ONE feed, live-ticking
  // off the EXISTING `fleet`/`audit` SSE types (D2/D33: the closed vocabulary
  // gains no new member — verify runs ride the `fleet` nudge the server already
  // sends). /v1/audit is team-admin-only: a 403 degrades to events-only with one
  // honest quiet line, never an error state (D18). The verify chips on the
  // Overview tab derive from the SAME events payload; "Check now" POSTs the
  // synchronous /verify suite and renders the returned envelope immediately —
  // an unreachable box is a NORMAL result rendered honestly, not an error.

  // The event-type vocabulary is CLOSED server-side (AgentEvent @types:
  // health status backup tls content verify); an unknown type renders its raw
  // name (version-skew safety), never blanks a row.
  var TLV_EVENT_TITLES = {
    health: "Health report",
    status: "Status change",
    backup: "Backup",
    tls: "TLS",
    content: "Content",
    verify: "Verification",
  };

  // Pure: epoch ms of an ISO stamp; 0 (sorts oldest, never NaN) on junk.
  function tlvTs(at) {
    var t = Date.parse(at);
    return isNaN(t) ? 0 : t;
  }

  // Pure: does this audit row MIRROR an instance event already in the feed?
  // Two sanctioned signals: (a) the audit's metadata names the event outright
  // (metadata.event_id), or (b) same-second timestamp AND the audit action's
  // dot-suffix equals the event type (e.g. a future "barkpark.verify" audit
  // beside the `verify` event). The EVENT wins the dedup — it carries the
  // richer payload; the audit row is the actor attribution of the same fact.
  function auditMirrorsEvent(a, events) {
    if (!a) return false;
    var evId = a.metadata && a.metadata.event_id != null ? String(a.metadata.event_id) : null;
    var sec = a.inserted_at ? Math.floor(tlvTs(a.inserted_at) / 1000) : null;
    var suffix = String(a.action || "").split(".").pop();
    for (var i = 0; i < events.length; i++) {
      var e = events[i];
      if (!e) continue;
      if (evId !== null && String(e.id) === evId) return true;
      if (sec !== null && suffix && String(e.type) === suffix &&
          Math.floor(tlvTs(e.inserted_at) / 1000) === sec) return true;
    }
    return false;
  }

  // Pure: merge the two feeds into one newest-first timeline. Each entry:
  // { source: "event"|"verify"|"audit", key, at, type, payload, actor }.
  // Ordering is TOTAL and stable: timestamp desc; at equal timestamps the
  // instance event outranks its audit attribution (the event is the primary
  // record); final tiebreak on key so two repaints can never reorder.
  function mergeTimeline(events, audits) {
    events = Array.isArray(events) ? events : [];
    audits = Array.isArray(audits) ? audits : [];
    var entries = [];
    events.forEach(function (e) {
      if (!e) return;
      entries.push({
        source: e.type === "verify" ? "verify" : "event",
        key: "e:" + String(e.id),
        at: e.inserted_at || null,
        type: String(e.type || ""),
        payload: e.payload || null,
        actor: null,
      });
    });
    audits.forEach(function (a) {
      if (!a) return;
      if (auditMirrorsEvent(a, events)) return; // the event already tells it
      entries.push({
        source: "audit",
        key: "a:" + String(a.id),
        at: a.inserted_at || null,
        type: String(a.action || ""),
        payload: a.metadata || null,
        actor: (a.actor && a.actor.email) || null,
      });
    });
    entries.sort(function (x, y) {
      var d = tlvTs(y.at) - tlvTs(x.at);
      if (d) return d;
      var r = (x.source === "audit" ? 1 : 0) - (y.source === "audit" ? 1 : 0);
      if (r) return r;
      return x.key < y.key ? -1 : x.key > y.key ? 1 : 0;
    });
    return entries;
  }

  // Pure: one human title per entry. Audit rows read like the Activity tab
  // (actor + humanAction); verify rows read the verdict; agent events read
  // their kind, enriched with the status transition when the payload has one.
  function tlvEntryTitle(entry) {
    entry = entry || {};
    var p = entry.payload || {};
    if (entry.source === "audit") {
      return (entry.actor || "system") + " " + humanAction(entry.type);
    }
    if (entry.source === "verify") {
      if (p.ok) return "Verification passed";
      var m = probeChipsModel(p);
      // A degenerate envelope (no probes array — never produced by Verify.run,
      // total-over-junk safety) states the failure without inventing a cause.
      if (!m.ran) return "Verification failed";
      if (!m.reachable) return "Verification failed — unreachable";
      var failing = m.chips.filter(function (c) { return c.role === "fail"; }).length;
      return "Verification failed — " + failing + " of " + m.chips.length + " checks";
    }
    var base = TLV_EVENT_TITLES[entry.type] || entry.type || "Event";
    if (entry.type === "status" && p.transition) return "Status → " + String(p.transition);
    if (entry.type === "health" && p.health) return "Health report — " + String(p.health);
    return base;
  }

  // Pure: does the entry carry anything worth an inline expansion?
  function tlvHasDetail(entry) {
    var p = entry && entry.payload;
    return !!(p && typeof p === "object" && Object.keys(p).length);
  }

  // Pure: the expanded detail body (escaped). Verify runs get a readable
  // per-probe console (name, status, latency, verbatim evidence); everything
  // else shows its payload verbatim as pretty JSON — the honest raw record.
  function tlvDetailHtml(entry) {
    entry = entry || {};
    var p = entry.payload || {};
    if (entry.source === "verify" && Array.isArray(p.probes)) {
      return p.probes.map(function (pr) {
        pr = pr || {};
        var status = pr.status != null ? String(pr.status) : (pr.reachable === false ? "unreachable" : "—");
        var lat = pr.latency_ms != null ? " in " + String(pr.latency_ms) + "ms" : "";
        return esc(String(pr.name || "probe") + ": " + status + lat +
          (pr.evidence ? " — " + String(pr.evidence) : ""));
      }).join("\n");
    }
    try {
      return esc(JSON.stringify(p, null, 2));
    } catch (e) {
      return esc(String(p));
    }
  }

  // Pure: one feed row. `expanded` re-applies the operator's open details
  // across live repaints (an SSE tick must never fold what they were reading).
  // The verify badge colours by OUTCOME (ok → green, anything else → red):
  // a green VERIFY chip over "Verification failed" would be the badge lying.
  function tlvRowHtml(entry, expanded) {
    var hasDetail = tlvHasDetail(entry);
    var badgeMod = entry.source === "verify" && !(entry.payload && entry.payload.ok)
      ? "verify-fail"
      : entry.source;
    return '<div class="tlv-row" data-tlv-key="' + esc(entry.key) + '">' +
      '<div class="tlv-head">' +
        '<span class="tlv-badge tlv-badge--' + esc(badgeMod) + '">' + esc(entry.source) + "</span>" +
        '<span class="tlv-title">' + esc(tlvEntryTitle(entry)) + "</span>" +
        '<span class="tlv-when" title="' + esc(fmtWhen(entry.at)) + '">' + esc(relTime(entry.at)) + "</span>" +
        (hasDetail
          ? '<button class="tlv-toggle" type="button" data-tlv-toggle aria-expanded="' +
            (expanded ? "true" : "false") + '">Details</button>'
          : "") +
      "</div>" +
      (hasDetail
        ? '<pre class="tlv-detail"' + (expanded ? "" : " hidden") + ">" + tlvDetailHtml(entry) + "</pre>"
        : "") +
      "</div>";
  }

  // Pure: the whole feed. opts.quietLine is the ONE honest degradation line
  // (audit 403 → "visible to team admins"); opts.expandedKeys re-opens rows.
  // Empty teaches rather than apologises.
  function timelineFeedHtml(entries, opts) {
    opts = opts || {};
    entries = Array.isArray(entries) ? entries : [];
    var quiet = opts.quietLine
      ? '<div class="tlv-quiet">' + esc(opts.quietLine) + "</div>"
      : "";
    if (!entries.length) {
      return quiet + '<div class="empty-state"><h2>Nothing here yet</h2>' +
        "<p>Events will appear here as this Barkpark works &mdash; health reports, backups, " +
        "verification runs, and team actions, in order.</p></div>";
    }
    var open = opts.expandedKeys || [];
    return quiet + entries.map(function (e) {
      return tlvRowHtml(e, open.indexOf(e.key) !== -1);
    }).join("");
  }

  function timelineTabShellHtml() {
    return '<div class="tlv" aria-live="polite"><div class="loading">Loading timeline&hellip;</div></div>';
  }

  // Expanded-detail memory, keyed "<bp.id>|<entry.key>". Module-level so the
  // SSE-driven remount (loadInstance repaints the whole workspace) re-opens
  // exactly what the operator had open. In-memory: a refresh forgets.
  var tlvExpanded = {};
  // Last painted feed per instance — an SSE remount paints this instantly
  // instead of flashing "Loading…" on every live tick.
  var tlvCache = null;
  var tlvLoadSeq = 0;
  var tlvMountedBp = null;

  function mountTimelineTab(root, bp) {
    if (!root) return;
    tlvMountedBp = bp;
    root.innerHTML = timelineTabShellHtml();
    wireTimelineFeed(root, bp);
    if (tlvCache && String(tlvCache.id) === String(bp.id)) {
      paintTimeline(root, bp, tlvCache.entries, tlvCache.quietLine);
    }
    loadTimeline(root, bp);
  }

  // Fetch both feeds in parallel and paint on resolve (never blanks first —
  // a repaint-in-place, so the live refetch path is flicker-free). The events
  // fetch failing is the ERROR state (one Retry); the audit fetch failing only
  // DEGRADES the feed: 403 = not-an-admin (quiet, honest, expected), anything
  // else = one quiet events-only line. Never an error state for audit (D18).
  function loadTimeline(root, bp) {
    var seq = ++tlvLoadSeq;
    Promise.all([
      api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/events?limit=100"),
      api("GET", "/v1/audit?target_type=barkpark&target_id=" + encodeURIComponent(bp.id) + "&limit=100"),
    ]).then(function (rs) {
      if (seq !== tlvLoadSeq) return; // a newer load owns the feed
      var box = root && root.querySelector ? root.querySelector(".tlv") : null;
      if (!box) return;
      var ev = rs[0], au = rs[1];
      if (!ev.ok) {
        box.innerHTML = '<div class="empty-state"><h2>Couldn\'t load the timeline</h2>' +
          "<p>" + esc(friendly(ev.data, "Check your connection and retry.")) + "</p>" +
          '<p><button class="btn btn-sm btn-primary" type="button" data-tlv-retry>Retry</button></p></div>';
        return;
      }
      var events = (ev.data && ev.data.events) || [];
      var audits = [];
      var quietLine = "";
      if (au.ok) {
        audits = (au.data && au.data.events) || [];
      } else if (au.status === 403) {
        quietLine = "Audit entries are visible to team admins.";
      } else {
        quietLine = "Audit entries couldn't be loaded — showing instance events only.";
      }
      var entries = mergeTimeline(events, audits);
      tlvCache = { id: bp.id, entries: entries, quietLine: quietLine };
      paintTimeline(root, bp, entries, quietLine);
    });
  }

  function paintTimeline(root, bp, entries, quietLine) {
    var box = root && root.querySelector ? root.querySelector(".tlv") : null;
    if (!box) return;
    var open = [];
    entries.forEach(function (e) {
      if (tlvExpanded[String(bp.id) + "|" + e.key]) open.push(e.key);
    });
    box.innerHTML = timelineFeedHtml(entries, { quietLine: quietLine, expandedKeys: open });
  }

  // ONE delegated listener per mount (the panel node lives for the tab's whole
  // life; paints only swap its inner feed) — details toggle + error Retry.
  function wireTimelineFeed(root, bp) {
    if (!root || !root.addEventListener) return; // fake-DOM smoke
    root.addEventListener("click", function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      var btn = t.closest("[data-tlv-toggle]");
      if (btn) {
        var row = btn.closest("[data-tlv-key]");
        if (!row) return;
        var detail = row.querySelector(".tlv-detail");
        if (!detail) return;
        var opening = detail.hidden;
        detail.hidden = !opening;
        btn.setAttribute("aria-expanded", opening ? "true" : "false");
        var key = String(bp.id) + "|" + row.getAttribute("data-tlv-key");
        if (opening) tlvExpanded[key] = true;
        else delete tlvExpanded[key];
        return;
      }
      if (t.closest("[data-tlv-retry]")) loadTimeline(root, bp);
    });
  }

  // SSE hook: an `audit` tick while the Timeline tab is on screen refetches the
  // feed in place (TYPE_ACTIONS wires this; `fleet` ticks already remount the
  // whole instance view, which re-lands here through mountTimelineTab).
  function refreshInstanceTimeline() {
    var h = parseHash();
    if (h.view !== "instance" || h.tab !== "timeline") return;
    if (!tlvMountedBp || String(tlvMountedBp.id) !== String(h.id)) return;
    var panel = document.getElementById("instance-tabpanel");
    if (!panel) return;
    loadTimeline(panel, tlvMountedBp);
  }

  // ------------------------------------------------ verify chips (Overview)
  // The probe vocabulary, byte-pinned against __fixtures__/verify_probes.json
  // (the same fixture the Elixir suite and the Go provision gate assert). The
  // node harness asserts name+label equality so a vocabulary change reds here.
  var VERIFY_PROBES = [
    { name: "verify.api", label: "API answers" },
    { name: "verify.login", label: "Login responds" },
    { name: "verify.studio", label: "Studio renders" },
  ];

  // Pure: the newest `verify` event in a newest-first events payload, or null.
  function latestVerifyOf(events) {
    if (!Array.isArray(events)) return null;
    for (var i = 0; i < events.length; i++) {
      if (events[i] && events[i].type === "verify") return events[i];
    }
    return null;
  }

  // Pure: chips model from a verify RESULT envelope ({ok, reachable,
  // verified_at, probes}) — the POST response and the persisted event payload
  // share this shape — or null for the never-run state. Every probe in the
  // vocabulary gets a chip even if the envelope omits it (role "unknown"):
  // three chips always, so the row never shifts.
  function probeChipsModel(result) {
    var ran = !!(result && typeof result === "object" && Array.isArray(result.probes));
    var byName = {};
    if (ran) {
      result.probes.forEach(function (p) { if (p && p.name) byName[p.name] = p; });
    }
    return {
      ran: ran,
      ok: ran ? !!result.ok : null,
      reachable: ran ? result.reachable !== false : null,
      verifiedAt: (ran && result.verified_at) || null,
      chips: VERIFY_PROBES.map(function (v) {
        var p = byName[v.name];
        if (!p) return { name: v.name, label: v.label, role: "unknown", status: null, latencyMs: null, unreachable: false };
        return {
          name: v.name,
          label: v.label,
          role: p.ok ? "pass" : "fail",
          status: p.status != null ? p.status : null,
          latencyMs: p.latency_ms != null ? p.latency_ms : null,
          unreachable: p.reachable === false,
        };
      }),
    };
  }

  // Pure: the one-line verdict under the chips.
  function verifySummaryText(model) {
    if (!model.ran) return "Never checked — run the first one to prove the golden path.";
    var when = model.verifiedAt ? " · checked " + relTime(model.verifiedAt) : "";
    if (model.ok) return "All checks passed" + when;
    if (!model.reachable) return "Unreachable — the box didn't answer any probe" + when;
    var failing = model.chips.filter(function (c) { return c.role === "fail"; }).length;
    return failing + " of " + model.chips.length + " checks failing" + when;
  }

  // Pure: one probe chip. pass/fail carry the semantic role; a chip that never
  // ran (or an unreachable probe) says so in words, not just colour.
  function verifyChipHtml(chip) {
    var glyph = chip.role === "pass" ? "&#10003;" : chip.role === "fail" ? "&#10007;" : "&middot;";
    var code = chip.role === "unknown" ? ""
      : chip.unreachable || chip.status == null ? "unreachable"
      : String(chip.status) + (chip.latencyMs != null ? " · " + chip.latencyMs + "ms" : "");
    var state = chip.role === "pass" ? "passed" : chip.role === "fail" ? "failed" : "not checked";
    return '<span class="vf-chip vf-chip--' + esc(chip.role) + '" role="listitem" aria-label="' +
      esc(chip.label + " — " + state) + '">' +
      '<span class="vf-chip-glyph" aria-hidden="true">' + glyph + "</span>" +
      esc(chip.label) +
      (code ? '<span class="vf-chip-code">' + esc(code) + "</span>" : "") +
      "</span>";
  }

  // Pure: the whole card. Never-run invites the first check; a completed run
  // (pass, fail, or unreachable — ALL normal results) renders the verdict.
  // noteHtml is the 409/404 recovery note (verifyNoteHtml), rendered inline.
  function verifyCardHtml(model, noteHtml) {
    // The first-ever check is THE next step for a fresh box (primary); a
    // re-check on a verified box is routine (quiet).
    var runBtn = model.ran
      ? '<button class="btn btn-sm" type="button" data-vf-run>Check now</button>'
      : '<button class="btn btn-sm btn-primary" type="button" data-vf-run>Run first check</button>';
    return '<div class="vf-card">' +
      '<div class="vf-head"><h2>Golden path</h2>' + runBtn + "</div>" +
      '<div class="vf-chips" role="list" aria-label="Verification checks">' +
        model.chips.map(verifyChipHtml).join("") +
      "</div>" +
      '<div class="vf-meta">' + esc(verifySummaryText(model)) + "</div>" +
      (noteHtml || "") +
      "</div>";
  }

  // Pure: the human copy + EXACTLY ONE recovery action for the two coded
  // /verify refusals (D25). 409 not_live → watch the Timeline (the check works
  // once the box is live); 404 no_admin_token → the server's own hint is a
  // re-provision, and POST /retry is that primitive.
  function verifyNoteHtml(code, bp) {
    if (code === "not_live") {
      return '<div class="vf-note"><b>Not live yet.</b> Verification probes the running box &mdash; ' +
        "it works once provisioning finishes. " +
        '<a href="#instance/' + esc(bp.id) + '/timeline">View timeline</a></div>';
    }
    if (code === "no_admin_token") {
      return '<div class="vf-note"><b>No stored credentials.</b> This instance predates verification ' +
        "&mdash; re-provisioning captures the credentials the check needs. " +
        '<button class="btn btn-sm" type="button" data-vf-reprovision>Re-provision</button></div>';
    }
    return "";
  }

  // Who owns the #instance-verify slot right now. Re-querying the DOM after an
  // await is NOT enough on its own: navigating A → B replaces the slot with
  // B's, and A's still-in-flight response would paint A's chips (and wire
  // A-targeted actions) into B's overview. verifySeq drops stale GETs; the
  // owner id gates the long-running POST (an unreachable box holds /verify
  // open for tens of seconds — plenty of time to click another instance).
  var verifySeq = 0;
  var verifyOwnerId = null;

  // Derive the chips from the SAME events feed the Timeline reads. A failed
  // events fetch hides the card quietly — the chips are an additive proof, and
  // the Overview must never error because history was unavailable (the next
  // fleet SSE tick retries via the normal repaint).
  function loadInstanceVerify(bp) {
    var box = $("#instance-verify");
    if (!box) return;
    verifyOwnerId = String(bp.id);
    var seq = ++verifySeq;
    // limit=200 (the route's max): the per-cycle health beat dominates the
    // stream, and a verify run buried behind a day of beats must not make the
    // card lie "never checked" at the default 50-event window.
    api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/events?limit=200").then(function (r) {
      if (seq !== verifySeq) return; // a newer mount owns the slot
      box = $("#instance-verify");
      if (!box) return;
      if (!r.ok) { box.innerHTML = ""; return; }
      var latest = latestVerifyOf((r.data && r.data.events) || []);
      renderVerifyCard(box, bp, probeChipsModel(latest ? latest.payload : null));
    });
  }

  function renderVerifyCard(box, bp, model, noteHtml) {
    box.innerHTML = verifyCardHtml(model, noteHtml);
    var run = box.querySelector("[data-vf-run]");
    if (run) run.addEventListener("click", function () { runVerifyNow(box, bp, model, run); });
    var rp = box.querySelector("[data-vf-reprovision]");
    if (rp) rp.addEventListener("click", function () { retryInstance(bp, rp); });
  }

  // POST the synchronous suite. 200 renders the returned envelope IMMEDIATELY
  // (unreachable is a normal 200 with reachable:false — rendered honestly, not
  // as an error); 409/404 get their coded recovery notes; anything else is a
  // toast + a re-enabled button. The server also nudges `fleet`, so the
  // persisted event repaints the same truth moments later.
  function runVerifyNow(box, bp, model, btn) {
    var label = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Checking…";
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/verify", {}).then(function (r) {
      // Another instance's overview owns the slot now — this result (and its
      // wrong-target Check-now/Re-provision wiring) must not paint there. The
      // run itself isn't lost: the server persisted it as a `verify` event.
      if (verifyOwnerId !== String(bp.id)) return;
      box = $("#instance-verify");
      if (!box) return; // navigated away mid-check
      if (r.status === 200 && r.data && Array.isArray(r.data.probes)) {
        renderVerifyCard(box, bp, probeChipsModel(r.data));
        return;
      }
      if (r.status === 409) {
        renderVerifyCard(box, bp, model, verifyNoteHtml("not_live", bp));
        return;
      }
      if (r.status === 404 && r.data && r.data.error === "no_admin_token") {
        renderVerifyCard(box, bp, model, verifyNoteHtml("no_admin_token", bp));
        return;
      }
      btn.disabled = false;
      btn.textContent = label;
      toast({ kind: "error", title: "Couldn't run the check", body: friendly(r.data, "Please try again in a moment.") });
    });
  }

  // ================================================== DOMAIN CHECKLIST (S13)
  // The per-host DNS/TLS checklist — DNS found → points here → TLS issued →
  // serving — for the azure-hetzner hosting parity work. The CLI (`bp cloud
  // domain status`) and this rail render the SAME control-plane envelope (GET
  // /v1/barkparks/:id/domain-status); NEITHER surface probes — the CP owns the
  // truth. domainStages is the ONE pure fold, node-pinned in __app.test.mjs;
  // the DOM mount + 4s poll (loadInstanceDomains) are browser-verified.

  // Fold one host's stage array into display rows. Roles: ok/failed pass
  // through; a pending rung is "pending" (waiting) EXCEPT the first pending rung
  // after at least one ok rung, which becomes "active" (the front currently
  // being established) — the checklist shows honest motion (the markNextStep
  // idiom). showRemediation is true ONLY under a non-ok rung that carries a
  // server remediation string (server-owned copy, rendered verbatim — the SPA
  // never invents fix text).
  function domainStageRows(stages) {
    stages = Array.isArray(stages) ? stages : [];
    var rows = [], seenOk = false, sawActive = false;
    for (var i = 0; i < stages.length; i++) {
      var s = stages[i] || {};
      var status = typeof s.status === "string" ? s.status : "";
      var role = status === "ok" ? "ok" : status === "failed" ? "failed" : "pending";
      if (role === "ok") seenOk = true;
      if (role === "pending" && seenOk && !sawActive) { role = "active"; sawActive = true; }
      var remediation = typeof s.remediation === "string" ? s.remediation : "";
      var label = (typeof s.label === "string" && s.label) ? s.label
        : (typeof s.stage === "string" ? s.stage : "");
      rows.push({
        stage: typeof s.stage === "string" ? s.stage : "",
        label: label,
        role: role,
        status: status,
        evidence: typeof s.evidence === "string" ? s.evidence : "",
        remediation: remediation,
        showRemediation: role !== "ok" && !!remediation,
      });
    }
    return rows;
  }

  // The canonical fold: the domain-status envelope → a render-ready model. Each
  // host carries its rolled-up overall (role-mapped) + its rung rows. `terminal`
  // is true when nothing more can change on its own — every host's rungs are all
  // ok-or-failed, EXCEPT a failed SERVING rung (see below) — and the DOM mount
  // stops polling there. `empty` (no attached domains) keeps the original single
  // Domain rail row.
  function domainStages(payload, now) {
    now = (typeof now === "number") ? now : Date.now();
    var domains = (payload && Array.isArray(payload.domains)) ? payload.domains : [];
    var out = domains.map(function (d) {
      d = d || {};
      var overall = typeof d.overall === "string" ? d.overall : "";
      var overallRole = overall === "ok" ? "ok" : overall === "failed" ? "failed" : "pending";
      return {
        host: typeof d.host === "string" ? d.host : "",
        kind: typeof d.kind === "string" ? d.kind : "",
        overall: overall,
        overallRole: overallRole,
        rows: domainStageRows(d.stages),
      };
    });
    var terminal = out.every(function (d) {
      return d.rows.every(function (r) {
        // A failed SERVING rung stays NON-terminal: tls:ok + serving:failed is a
        // modeled state (the domain + cert are wired, the app behind them is
        // down) that an app restart heals — so we keep polling to catch the heal.
        // Every OTHER failed rung is terminal (a misconfiguration the operator
        // must fix; a genuinely-terminal DNS/points failure already keeps polling
        // via its trailing skipped-pending rungs, so this stays narrow — never
        // broaden it to every failed rung or a real dead-end infinite-polls).
        if (r.role === "failed" && r.stage === "serving") return false;
        return r.role === "ok" || r.role === "failed";
      });
    });
    return {
      ok: !!(payload && payload.ok),
      checkedAt: (payload && typeof payload.checked_at === "string") ? payload.checked_at : null,
      empty: out.length === 0,
      terminal: terminal,
      domains: out,
    };
  }

  // The host-kind chip copy (platform = a name.barkpark.cloud subdomain we own
  // end to end; custom = a BYO domain pointed at the box). Unknown kinds pass
  // through; empty yields "".
  function domainKindChip(kind) {
    if (kind === "platform") return "platform";
    if (kind === "custom") return "custom";
    return kind || "";
  }

  // Pure: one rung chip. Reuses the verify-card chip vocabulary (.vf-chip) so it
  // is styled without new CSS: ok → pass (✓), failed → fail (✗), pending/active
  // → the neutral "unknown" chip (·). The accessible name carries the state in
  // WORDS, never colour alone.
  function domainRungChip(row, showEvidence) {
    if (showEvidence === undefined) showEvidence = true;
    var vfRole = row.role === "ok" ? "pass" : row.role === "failed" ? "fail" : "unknown";
    var glyph = vfRole === "pass" ? "&#10003;" : vfRole === "fail" ? "&#10007;" : "&middot;";
    var state = row.role === "ok" ? "done"
      : row.role === "failed" ? "failed"
      : row.role === "active" ? "in progress" : "waiting";
    return '<span class="vf-chip vf-chip--' + vfRole + '" role="listitem" aria-label="' +
      esc(row.label + " — " + state) + '">' +
      '<span class="vf-chip-glyph" aria-hidden="true">' + glyph + "</span>" +
      esc(row.label) +
      (showEvidence && row.evidence ? '<span class="vf-chip-code">' + esc(row.evidence) + "</span>" : "") +
      "</span>";
  }

  // Pure: the whole rail checklist. Empty (no attached domains) degrades to the
  // original single Domain rail row. Otherwise one .vf-card per host — head
  // (host + kind), the rung chips, then the server's remediation lines under any
  // non-ok rung, verbatim.
  function domainChecklistHtml(model, bp) {
    if (!model || model.empty) {
      return railRow("Domain", (bp && bp.custom_host) || "—");
    }
    return model.domains.map(function (d) {
      var head = esc(d.host) +
        (domainKindChip(d.kind) ? ' <span class="vf-chip-code">' + esc(domainKindChip(d.kind)) + "</span>" : "");
      // Evidence dedup: keep it on ok / failed / the FRONT non-ok rung; drop the
      // repeated "…an earlier step isn't passing." filler on downstream pending
      // rungs (render layer only — the pure domainStageRows model is untouched).
      var frontSeen = false;
      var rungs = d.rows.map(function (row) {
        var showEvidence = true;
        if (row.role !== "ok") {
          if (frontSeen && row.role === "pending") showEvidence = false;
          frontSeen = true;
        }
        return domainRungChip(row, showEvidence);
      }).join("");
      // Collapse identical remediation strings so two rungs with the same fix
      // render ONE amber note instead of a stack.
      var seenRem = {};
      var remedies = d.rows.filter(function (r) { return r.showRemediation; })
        .map(function (r) { return r.remediation; })
        .filter(function (t) { if (seenRem[t]) return false; seenRem[t] = true; return true; })
        .map(function (t) { return '<div class="vf-note">' + esc(t) + "</div>"; }).join("");
      var when = model.checkedAt
        ? '<div class="vf-meta">checked ' + esc(relTime(model.checkedAt)) + "</div>"
        : "";
      return '<div class="vf-card">' +
        '<div class="vf-head"><h2>' + head + "</h2></div>" +
        '<div class="vf-chips" role="list" aria-label="Domain checks for ' + esc(d.host) + '">' +
          rungs +
        "</div>" +
        remedies + when +
        "</div>";
    }).join("");
  }

  // Which mount owns the #instance-domains slot + its poll right now. A newer
  // load (navigation, re-render, attach) bumps the seq, invalidating older
  // in-flight GETs and any pending poll re-arm (the verifySeq guard, applied to
  // a self-limiting setTimeout chain rather than a fixed interval).
  var domainSeq = 0;
  var domainPollTimer = null;

  // The thin DOM mount: fetch the checklist, paint it, and poll every 4s (the
  // /new idiom) while any rung is still pending/active. A 404 (route not
  // deployed yet) / error / non-live box keeps the static Domain rail row —
  // never an error in the rail. ALL logic lives in the pure helpers above;
  // browser-verified only.
  function loadInstanceDomains(bp) {
    var box = $("#instance-domains");
    if (!box) return;
    var seq = ++domainSeq;
    clearTimeout(domainPollTimer);
    api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/domain-status").then(function (r) {
      if (seq !== domainSeq) return; // a newer load owns the slot
      var b = $("#instance-domains");
      if (!b) return;
      if (!r.ok || !r.data) return; // keep the static Domain row on 404/error
      var model = domainStages(r.data, Date.now());
      b.innerHTML = domainChecklistHtml(model, bp);
      if (!model.terminal) {
        clearTimeout(domainPollTimer);
        domainPollTimer = setTimeout(function () {
          if (seq !== domainSeq) return;
          loadInstanceDomains(bp);
        }, 4000);
      }
    });
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

  // stw4-freshness (charter D24): the at-a-glance deploy-freshness model for a
  // site row. PURE + node-pinned. `s.last_deployment` is the SLIM server embed —
  // status/trigger/timestamps ONLY (HONESTY LAW: never content_rev). Returns null
  // for a never-deployed site (nil-honest — no badge invented). While a
  // CONTENT-AUTO rebuild is in flight (queued/building/pushing) the badge pulses
  // amber; every settled row states its status · trigger · when.
  function freshnessModel(s) {
    var d = s && s.last_deployment;
    if (!d || !d.status) return null;
    var inFlight = d.status === "queued" || d.status === "building" || d.status === "pushing";
    var auto = d.trigger === "content-auto";
    var rebuilding = inFlight && auto;
    var when = relTime(d.updated_at || d.inserted_at);
    var triggerWord = auto ? "auto" : "manual";
    var label, dot;
    if (rebuilding) { label = "Rebuilding"; dot = "rebuild"; }
    else if (inFlight) { label = "Deploying"; dot = "deploy"; }
    else if (d.status === "live") { label = "Live"; dot = "up"; }
    else if (d.status === "failed") { label = "Deploy failed"; dot = "down"; }
    else if (d.status === "cancelled") { label = "Canceled"; dot = "unknown"; }
    else { label = d.status.charAt(0).toUpperCase() + d.status.slice(1); dot = "unknown"; }
    return {
      rebuilding: rebuilding,
      inFlight: inFlight,
      trigger: d.trigger || null,
      triggerWord: triggerWord,
      label: label,
      dot: dot,
      when: when,
      // Settled rows caption trigger · when; an in-flight row shows only the
      // trigger word (no stale timestamp under a live pulse).
      meta: inFlight ? triggerWord : (triggerWord + " · " + when),
    };
  }

  // The freshness badge markup for a site row (empty string when never deployed).
  // A DISTINCT slot from the github_webhook_configured "Auto-deploy" capability
  // badge: this states the LAST deploy's outcome/freshness, not the auto-deploy
  // wiring.
  function freshnessBadge(s) {
    var m = freshnessModel(s);
    if (!m) return "";
    var cls = "fresh-badge fresh-badge--" + m.dot + (m.rebuilding ? " is-rebuilding" : "");
    var title = m.rebuilding
      ? "Auto-deploy in progress — a content publish is rebuilding this site"
      : (m.label + " · " + m.meta);
    return '<span class="' + cls + '" title="' + esc(title) + '">' +
      '<span class="fresh-dot" aria-hidden="true"></span>' +
      '<span class="fresh-label">' + esc(m.label) + "</span>" +
      '<span class="fresh-meta">' + esc(m.meta) + "</span>" +
      "</span>";
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
        siteOpenLink(siteLiveUrl(s, bp)) +
        freshnessBadge(s) +
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

  // stw5 (D25): the per-site synchronous-rollback "flash" — the completion state a
  // successful POST /v1/sites/:id/rollback leaves behind so the very next site
  // render can mark the restored row (or show the "rolled back to previous" note)
  // without re-deriving it from the wire. Keyed by site id; self-expiring via TTL
  // so no manual clearing is needed (a fresh deploy that moves current_deployment_id
  // also invalidates a "restored" flash — see siteRollbackFlashView).
  var siteRollbackFlash = {};
  // How long the rollback completion cue lingers on the detail page. Long enough to
  // survive the settling "deployments" SSE refetch + a glance; then the row reads as
  // a plain "Now live" (the restore already settled — no perpetual banner).
  var SITE_ROLLBACK_FLASH_TTL_MS = 45000;
  // D28: the deploy-history read is capped to the most-recent N (the endpoint returns
  // up to 200, but pagination is DEFERRED). Honest bounded list, never "full history".
  var DEPLOY_HISTORY_MAX = 12;

  // opts.quiet skips the full-body "Loading site…" spinner. Used after the
  // optimistic post-promote repaint: the reconciled list is already on screen,
  // so wiping #site-body with a spinner would (a) throw the optimistic paint
  // away before a single frame and (b) flash the whole detail view. Quiet keeps
  // the optimistic list visible until the refetch resolves and repaints to
  // server truth.
  function loadSite(id, opts) {
    currentSiteId = id;
    var box = $("#site-body");
    if (!(opts && opts.quiet)) box.innerHTML = '<div class="loading">Loading site&hellip;</div>';
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
      setShellContextName("site", site.name || domain); // sidebar morph ctx name
      setScopeLabel(parseHash(), shellNavLayer(parseHash()));
      box.innerHTML = siteDetailHtml(site, bp, deployments, domain, previews);
      var d = $("#site-deploy");
      if (d) d.addEventListener("click", function () { confirmDeploy(site, domain); });
      var srb = $("#site-rollback");
      if (srb) srb.addEventListener("click", function () { confirmSiteRollback(site, domain); });
      wireDeployConsoles(box);
      wireDeployActions(box, site, deployments);
      // W4: mount the live six-stage rail for the in-flight deployment (if any),
      // driven by the site.deploy.stage SSE push — not a poll.
      mountDeployRail(box, site, bp, deployments);
      var g = $("#site-github");
      if (g) g.addEventListener("click", function () { openSiteGithub(site, domain); });
      var themeSel = $("#site-theme-select");
      if (themeSel) themeSel.addEventListener("change", function () {
        var val = themeSel.value;
        themeSel.disabled = true;
        api("PATCH", "/v1/sites/" + encodeURIComponent(site.id), siteThemePatchBody(val)).then(function (r) {
          themeSel.disabled = false;
          if (r.ok) {
            site.theme = val;
            toast("Theme set to " + (val || "template default") + " — applies on the next deploy");
          } else {
            themeSel.value = site.theme || "";
            var msg = (r.data && (r.data.error || r.data.detail)) || ("update failed (" + r.status + ")");
            toast("Couldn't set theme: " + String(msg));
          }
        });
      });
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

  // ── Site theme edit (search-template W8) ──────────────────────────────────
  // The console twin of `bp cloud site settings --theme`: a rail-row select that
  // PATCHes /v1/sites/:id and settles on the next deploy. Pure helpers node-pinned.

  var SITE_THEMES = ["evergreen", "ember", "fjord", "charple"];

  // Pure: the <select> options for the theme picker, current value selected.
  function siteThemeOptionsHtml(current) {
    return ['<option value="">Template default</option>']
      .concat(SITE_THEMES.map(function (t) {
        return '<option value="' + esc(t) + '"' + (t === current ? " selected" : "") + ">" +
          esc(t.charAt(0).toUpperCase() + t.slice(1)) + "</option>";
      }))
      .join("");
  }

  // Pure: the PATCH body from a chosen theme value ("" clears the pin → template
  // default; the server treats an empty string as a valid clear).
  function siteThemePatchBody(value) {
    return { theme: value || "" };
  }

  function siteDetailHtml(site, bp, deployments, domain, previews) {
    previews = previews || [];
    var auto = site.github_webhook_configured;
    var repo = site.github_repo
      ? '<span class="mono">' + esc(site.github_repo) + (site.github_branch ? "@" + esc(site.github_branch) : "") + "</span>"
      : "—";
    var sub = (site.framework ? esc(site.framework) : "site") +
      (bp ? ' &middot; on <a href="#instance/' + esc(bp.id) + '">' + esc(bp.name) + "</a>" : "");
    // stw5 (D25): resolve the stored rollback flash against server truth + the clock
    // ONCE, then thread it through the list (restored-row marker) and the banner
    // (deployment_id:null "previous release" note). Stale/expired flashes resolve to
    // null so the panel reads normally.
    var flashView = siteRollbackFlashView(siteRollbackFlash[String(site.id)], site, Date.now());
    var list = deployListHtml(deployments, site.current_deployment_id, flashView);
    var rollbackBanner = deployRollbackBannerHtml(flashView);
    // stw5 (D25): the one-honest-click SITE rollback — offered only when there's a
    // live release AND at least one prior deployment to fall back to. The SERVER owns
    // the final word (a typed refusal is surfaced honestly on click), but gating the
    // affordance here keeps it from being a guaranteed dead-end button.
    var canSiteRollback = !!site.current_deployment_id && (deployments && deployments.length >= 2);
    var deploysHead = '<div class="deploys-head"><h2>Deployments</h2>' +
      (canSiteRollback
        ? '<button class="btn btn-ghost btn-sm" id="site-rollback" type="button">Roll back</button>'
        : "") +
      "</div>";
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
    var live = siteLiveUrl(site, bp);
    var liveLine = live
      ? ' &middot; <a class="site-open" href="' + esc(live) + '" target="_blank" rel="noopener">' + esc(live) + "&nbsp;&#8599;</a>"
      : "";
    return '<div class="detail-head"><div><h1>' + esc(domain) + "</h1>" +
        '<div class="fleet-url">' + sub + liveLine + "</div></div>" +
        '<div class="fleet-badges">' +
          (live ? '<a class="btn btn-ghost btn-sm site-open" href="' + esc(live) + '" target="_blank" rel="noopener">Visit&nbsp;&#8599;</a>' : "") +
          '<button class="btn btn-ghost btn-sm" id="site-github" type="button">' + githubLabel + "</button>" +
          '<button class="btn btn-primary btn-sm" id="site-deploy" type="button">Deploy</button></div></div>' +
      '<div class="detail-grid">' +
        '<div class="detail-main"><div id="deploy-rail-slot"></div>' + deploysHead + rollbackBanner +
          '<div class="deploys" id="site-deploys">' + list + "</div>" +
          previewSection + "</div>" +
        '<aside class="detail-rail"><h2>Details</h2>' +
          railRowCopy("Site ID", site.id) +
          railRow("Framework", site.framework || "—") +
          // W8: the deploy-pinned palette, editable inline — applies next deploy.
          railRowHtml("Theme",
            '<select class="rail-select" id="site-theme-select" aria-label="Deploy theme">' +
              siteThemeOptionsHtml(site.theme || "") + "</select>") +
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
  // dwb-webhook-deploy-artifact-gap (interim): the ONE predicate for the
  // born-failed GitHub-push family — a push conjures a deployment the builder
  // can't run yet (needs the gh-1 App integration), so the CP marks it born-
  // failed. Shared by failureCopy (what to say) and failureTone (how to paint
  // it) so the two can never drift apart. FailureCopy.humanize on the Elixir
  // side maps the raw machine reason to human copy at the JSON boundary, so the
  // client usually already RECEIVES the human string — match a substring
  // present in BOTH the raw form ("github push builds …", pinned by charter D3)
  // and the humanized form ("… can't be built yet …") → idempotent: raw→human
  // and human→human land on one output. Matched case-insensitively with the
  // apostrophe normalized (U+2019 → ') so a byte-level drift in the server copy
  // degrades only the re-mapping (their words show), never the classification.
  function isGithubPushBlocked(reason) {
    if (!reason || typeof reason !== "string") return false;
    var lc = reason.toLowerCase().replace(/\u2019/g, "'");
    return lc.indexOf("github push builds") !== -1 ||
      lc.indexOf("can't be built yet") !== -1 ||
      lc.indexOf("cannot be built yet") !== -1;
  }

  // Map a raw internal builder failure_reason (from builder.go) to human copy,
  // the deploy-side twin of friendly()/ERRORS for API errors. Substring match on
  // the RAW reason; unrecognized reasons pass through verbatim (still esc'd at
  // the call site, so escaping is unchanged).
  function failureCopy(reason) {
    if (!reason) return reason;
    if (isGithubPushBlocked(reason))
      return "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming.";
    if (reason.indexOf("no build source") !== -1)
      return "This site has no build source yet. Connect a repo or run bp deploy.";
    if (reason.indexOf("artifact_url is empty") !== -1 ||
        reason.indexOf("unsupported artifact scheme") !== -1)
      return "The build source couldn't be fetched.";
    return reason;
  }

  // dwb-webhook-deploy / D11: BLOCKED-vs-CRASHED tone. A born-failed GitHub-push
  // deploy is a capability that isn't enabled yet — not a crash. Classify the
  // reason family so the render sites can paint it in a calm amber/informational
  // tone instead of crash-red. Total: null/unknown → crashed.
  function failureTone(reason) {
    return isGithubPushBlocked(reason) ? "blocked" : "crashed";
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
      ? '<div class="deploy-fail' + (failureTone(d.failure_reason) === "blocked" ? " deploy-fail--blocked" : "") + '">' + esc(failureCopy(d.failure_reason)) + "</div>" : "";
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

  // ------------------------------------------- rollback / redeploy (D7 + D25)
  // Both are ONE control-plane primitive: POST /v1/sites/:id/deployments/
  // :dep_id/promote → 201 {deployment}. The server mints a FRESH queued
  // production deployment pinned to the source row's already-built artifact —
  // promote-by-new-deployment, never a pointer flip — so nothing here mutates
  // a row in place and the current deployment stays in history.

  // The URL the promote POST drives. Both ids ride through encodeURIComponent
  // so a hostile/garbled id can never break out of its path segment.
  function promotePath(siteId, depId) {
    return "/v1/sites/" + encodeURIComponent(String(siteId)) +
      "/deployments/" + encodeURIComponent(String(depId)) + "/promote";
  }

  // The short human handle for a deployment's build source, for confirm copy
  // and toasts. Prefers the git sha (what the operator recognizes), then the
  // image tag, then the row id.
  function deployRefLabel(d) {
    if (!d) return "";
    if (d.git_ref) return shortSha(d.git_ref);
    if (d.image_tag) return shortId(d.image_tag);
    return shortId(d.id);
  }

  // Which promote action (if any) a production deployment row offers:
  //   the CURRENT deployment (site.current_deployment_id) → Redeploy;
  //   every PRIOR terminal-live deployment              → Roll back to this.
  // Non-live rows (queued/building/pushing/failed) and branch previews offer
  // nothing — there is no proven artifact to promote. Pure; null = no action.
  function promoteActionFor(d, currentId) {
    if (!d || d.environment === "preview") return null;
    if ((d.status || "") !== "live") return null;
    if (currentId != null && String(d.id) === String(currentId)) {
      return { kind: "redeploy", label: "Redeploy" };
    }
    return { kind: "rollback", label: "Roll back to this" };
  }

  // The mutate-tier confirm copy — one honest consequence sentence per kind
  // (decision 5). `ref` is the short source handle (esc'd by confirmModalHtml).
  function promoteConfirmCopy(kind, ref) {
    if (kind === "redeploy") {
      return {
        title: "Redeploy " + ref + "?",
        consequence: "This creates a new production deployment from the same source (" + ref + "). " +
          "The current deployment keeps serving until the new one is live.",
        confirmLabel: "Redeploy",
        busyLabel: "Redeploying…",
      };
    }
    return {
      title: "Roll back to " + ref + "?",
      consequence: "This creates a new production deployment pinned to " + ref + ". " +
        "The current deployment stays in history.",
      confirmLabel: "Roll back",
      busyLabel: "Rolling back…",
    };
  }

  // Map a failed promote to a human sentence + which SINGLE recovery action the
  // modal offers (decision 25 — never a dead end): "retry" re-runs the POST,
  // "refresh" reloads the deployment list (the state moved under us). Pure.
  function promoteFailure(status, data) {
    var err = data && data.error;
    if (status === 409) {
      return {
        message: "A build for this git ref is already in progress — it has to finish (or fail) first.",
        recovery: "refresh",
      };
    }
    if (status === 404) {
      return { message: "That deployment isn't on this site any more — this list may be stale.", recovery: "refresh" };
    }
    if (status === 422 && err === "not_promotable") {
      return { message: "Branch previews can't be promoted to production.", recovery: "refresh" };
    }
    if (status === 422 && err === "no_build_source") {
      return {
        message: "This deployment has no stored artifact and the site has no connected repo, so there's nothing to rebuild from.",
        recovery: "refresh",
      };
    }
    if (status === 0) {
      return { message: "Couldn't reach the control plane — check your connection.", recovery: "retry" };
    }
    return { message: friendly(data, "The new deployment couldn't be created."), recovery: "retry" };
  }

  // After a promote succeeds the server mints a FRESH queued production
  // deployment (`optimisticRow`). Reconcile it into the on-screen list for an
  // immediate optimistic repaint — BEFORE the "deployments" SSE tick / refetch
  // lands: prepend it, deduped by id so a racing tick can't double it.
  // CRUCIALLY the new row is QUEUED, not live, so the Current chip must STAY on
  // the previously-live deployment; it only migrates to the new row once that
  // build actually goes live (a later refetch). Returns { list, currentId } —
  // currentId is the newest LIVE production row, which the new queued row is
  // never. Pure; harness-tested.
  function promoteReconcile(list, optimisticRow) {
    var rows = Array.isArray(list) ? list.slice() : [];
    if (optimisticRow && optimisticRow.id != null) {
      rows = rows.filter(function (d) { return String(d.id) !== String(optimisticRow.id); });
      rows.unshift(optimisticRow);
    }
    var currentId = null;
    for (var i = 0; i < rows.length; i++) {
      var d = rows[i];
      if ((d.status || "") === "live" && (d.environment || "production") !== "preview") {
        currentId = d.id;
        break;
      }
    }
    return { list: rows, currentId: currentId };
  }

  // The production deployment list markup — shared by the initial site render
  // and the optimistic post-promote repaint so the empty state and the Current
  // chip logic can never drift between the two paint paths.
  function deployListHtml(deployments, currentId, flash) {
    if (!deployments || !deployments.length) {
      return '<div class="empty-state"><h2>No deployments yet</h2><p>Trigger the first build with Deploy.</p></div>';
    }
    // D28: honest capped recent-N. The endpoint returns up to 200 rows but pagination
    // is deferred — show a bounded list + a plain-spoken footer when truncated (never
    // a "full history" claim).
    var rows = deployments.slice(0, DEPLOY_HISTORY_MAX)
      .map(function (d) { return deployRow(d, currentId, flash); }).join("");
    var note = deployments.length > DEPLOY_HISTORY_MAX
      ? '<p class="deploys-note">Showing the ' + DEPLOY_HISTORY_MAX + " most recent deployments.</p>"
      : "";
    return rows + note;
  }

  // Paint a deployment list into its container and (re)wire consoles + promote
  // actions in one step — no dead-button window between the innerHTML swap and
  // the wiring. Used by the optimistic post-promote repaint.
  function renderDeployList(container, site, list, currentId) {
    container.innerHTML = deployListHtml(list, currentId);
    wireDeployConsoles(container);
    wireDeployActions(container, site, list);
  }

  function confirmPromote(site, d, kind, deployments) {
    var copy = promoteConfirmCopy(kind, deployRefLabel(d));
    openConfirmModal({
      tier: "mutate",
      title: copy.title,
      consequence: copy.consequence,
      confirmLabel: copy.confirmLabel,
      busyLabel: copy.busyLabel,
      onConfirm: function (ctl) { runPromote(site, d, kind, ctl, deployments); },
    });
  }

  function runPromote(site, d, kind, ctl, deployments) {
    api("POST", promotePath(site.id, d.id), {}).then(function (r) {
      if (r.status === 201) {
        ctl.succeed();
        toast({
          kind: "success",
          title: kind === "redeploy" ? "Redeploy started" : "Rollback started",
          body: "A new production deployment pinned to " + deployRefLabel(d) + " is queued.",
        });
        // Optimistic repaint: the 201 carries the freshly-minted queued row —
        // reconcile it into the on-screen list so the queued deployment appears
        // instantly (the Current chip stays on the still-live deployment). The
        // loadSite refetch below then reconciles to server truth; the live
        // "deployments" SSE tick repaints again as the build progresses.
        if (String(currentSiteId) === String(site.id)) {
          var optimistic = r.data && r.data.deployment;
          var listBox = $("#site-deploys");
          if (optimistic && listBox) {
            var rec = promoteReconcile(deployments, optimistic);
            renderDeployList(listBox, site, rec.list, rec.currentId);
            // Quiet refetch: the optimistic list is already painted, so don't
            // blow it away with a spinner — let it stand until server truth lands.
            loadSite(site.id, { quiet: true });
          } else {
            loadSite(site.id);
          }
        }
        return;
      }
      var f = promoteFailure(r.status, r.data);
      if (f.recovery === "retry") {
        ctl.fail(f.message, "Try again", function (c) {
          c.busy();
          runPromote(site, d, kind, c, deployments);
        });
      } else {
        ctl.fail(f.message, "Refresh deployments", function () {
          closeModal();
          if (String(currentSiteId) === String(site.id)) loadSite(site.id);
        });
      }
    });
  }

  // Wire every promote button in a freshly rendered deployment list. Re-run
  // after each site render (the list is rebuilt on every live SSE tick).
  function wireDeployActions(scope, site, deployments) {
    var byId = {};
    (deployments || []).forEach(function (d) { byId[String(d.id)] = d; });
    scope.querySelectorAll(".dep-promote").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var d = byId[btn.getAttribute("data-dep-id")];
        if (d) confirmPromote(site, d, btn.getAttribute("data-kind"), deployments);
      });
    });
  }

  // ── stw5 site-level synchronous rollback (charter D25/D28) ─────────────────
  // DISTINCT from the per-row "Roll back to this" promote above (D7): that mints a
  // fresh build (async, drives the six-stage rail) targeting one chosen deployment;
  // THIS flips the whole site back to its previous release in place — SYNCHRONOUS,
  // no rebuild, no stage events, no new Deployment row. The 200 carries the settled
  // state directly; we NEVER poll (the async 202+poll of the INSTANCE rollback,
  // rollbackInstance app.js:~3237, is the named regression trap).

  // Human label for how a deployment shipped. Only rendered when the server sent a
  // trigger; unknown values pass through humanized (_/- → spaces). Pure.
  function deployTriggerLabel(trigger) {
    switch (trigger) {
      case "content-auto": return "auto";
      case "github_webhook":
      case "github-push": return "GitHub push";
      case "manual": return "manual";
      case "cli": return "CLI";
      case "rollback": return "rollback";
      case "promote": return "promote";
      default: return trigger ? String(trigger).replace(/[_-]+/g, " ") : "";
    }
  }

  // The site-rollback POST target. The id rides encodeURIComponent so a hostile id
  // can't break out of its path segment.
  function siteRollbackPath(siteId) {
    return "/v1/sites/" + encodeURIComponent(String(siteId)) + "/rollback";
  }

  // The confirm-modal markup — clones the isu-w6 instance idiom (rollbackConfirmHtml
  // / confirmRollbackInstance) but points at the SITE endpoint. Honest consequence
  // copy: an in-place flip to the previous release, no rebuild, current stays in
  // history (roll-forward stays possible). `domain` is server data → escaped.
  function siteRollbackConfirmHtml(site, domain) {
    return '<h2 class="modal-title" id="modal-title">Roll back ' + esc(domain) + "?</h2>" +
      '<p class="modal-sub">This flips the live site back to its <b>previous release</b> right ' +
        "now &mdash; no rebuild, no waiting. The release you're leaving stays in history, so you " +
        "can roll forward again. To ship a specific earlier build instead, use " +
        "<b>Roll back to this</b> on a deployment below.</p>" +
      '<div class="modal-actions"><button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" type="button" id="site-rollback-go">Roll back</button></div>';
  }

  // Fold the SYNCHRONOUS 200 rollback envelope
  //   {ok, status:'rolled_back', deployment_id, previous_deployment_id, url}
  // into the render flash. Two honest branches keyed off deployment_id:
  //   present → "restored": the server resolved the previous build + flipped
  //     current_deployment_id to it → mark THAT row "Now live — rolled back".
  //   null    → "previous": the build id didn't resolve; current_deployment_id is
  //     UNCHANGED → highlight NO row, name the previous_deployment_id + url instead.
  // Pure; ids coerced to strings for stable equality against row ids.
  function siteRollbackResult(data) {
    data = data || {};
    var dep = data.deployment_id != null ? String(data.deployment_id) : null;
    return {
      kind: dep ? "restored" : "previous",
      deploymentId: dep,
      previousDeploymentId: data.previous_deployment_id != null ? String(data.previous_deployment_id) : null,
      url: typeof data.url === "string" ? data.url : null,
      at: Date.now(),
    };
  }

  // Typed rollback refusals → one honest sentence each (D25). The server owns whether
  // a site CAN roll back; this maps its named refusals so a click never dead-ends in
  // a raw code. Static strings only (no server free-text embedded) except the generic
  // fallback, which routes through friendly(). Reads both {error:"code"} and
  // {error:{code}} envelope shapes.
  function siteRollbackFailure(status, data) {
    var err = (data && data.error) || {};
    var code = typeof err === "string" ? err : err.code;
    if (status === 422 && code === "not_rollbackable") {
      return {
        title: "This site can't be rolled back in place",
        body: "It rebuilds a fresh image on every deploy, so there's no previous release to flip " +
          "back to. Use “Roll back to this” on an earlier deployment to rebuild from it instead.",
      };
    }
    if (status === 422 && code === "no_previous") {
      return {
        title: "Nothing to roll back to",
        body: "This site has only ever had one release — there's no previous release to return to yet.",
      };
    }
    if (status === 409 || code === "rollback_failed") {
      return {
        title: "A deploy is already running",
        body: "Let the in-flight deploy finish, then roll back.",
      };
    }
    return { title: "Couldn't roll back", body: friendly(data, "Please try again in a moment.") };
  }

  // Resolve the stored rollback flash against the current site + clock into what to
  // render — or null when there's nothing to show: no flash, TTL expired, or a
  // "restored" flash whose row is no longer current (a later deploy superseded it).
  // Pure; node-pinned.
  function siteRollbackFlashView(flash, site, now) {
    now = typeof now === "number" ? now : Date.now();
    if (!flash) return null;
    if (flash.at && now - flash.at > SITE_ROLLBACK_FLASH_TTL_MS) return null;
    if (flash.kind === "restored") {
      var curId = (site && site.current_deployment_id != null) ? String(site.current_deployment_id) : null;
      // Only mark the row that is ACTUALLY current now — a newer deploy that moved
      // current_deployment_id makes the "restored" cue stale.
      if (flash.deploymentId == null || flash.deploymentId !== curId) return null;
      return { kind: "restored", deploymentId: flash.deploymentId, at: flash.at };
    }
    return { kind: "previous", previousDeploymentId: flash.previousDeploymentId, url: flash.url, at: flash.at };
  }

  // The deployment_id:null completion banner — the rollback resolved to the previous
  // release WITHOUT a build id (current_deployment_id UNCHANGED), so no row is
  // highlighted; the honest "Rolled back" completion pill + a link to the now-serving
  // URL read here instead. The "restored" branch shows nothing here (its cue is the
  // marked row). `url` is server data → escaped. Pure.
  function deployRollbackBannerHtml(flashView) {
    if (!flashView || flashView.kind !== "previous") return "";
    var link = flashView.url
      ? ' <a href="' + esc(flashView.url) + '" target="_blank" rel="noopener">' +
          esc(flashView.url) + "&nbsp;&#8599;</a>"
      : "";
    return '<div class="deploys-rollback-note" role="status">' +
      '<span class="deploys-rollback-pill">Rolled back</span>' +
      "<span>Rolled back to the previous release." + link + "</span></div>";
  }

  // Open the confirm modal + wire its danger button (the isu-w6 idiom, browser-verified).
  function confirmSiteRollback(site, domain) {
    openModal(siteRollbackConfirmHtml(site, domain));
    var go = $("#site-rollback-go");
    if (go) go.addEventListener("click", function () { runSiteRollback(site, domain, go); });
  }

  // POST /v1/sites/:id/rollback on its SYNCHRONOUS transport. On 200 {ok:true}: stash
  // the flash, show a "Rolled back" completion toast, and quiet-refetch so the history
  // panel settles over the single "deployments" SSE tick (the restored row marker /
  // previous-release banner appear on that repaint). NO six-stage rail — a rollback
  // mints no Deployment row, so mountDeployRail has nothing to mount. A typed refusal
  // is terminal: close + honest toast (never a silent retry, never a poll).
  function runSiteRollback(site, domain, btn) {
    btn = btn || $("#site-rollback-go");
    if (btn) { btn.disabled = true; btn.textContent = "Rolling back…"; }
    api("POST", siteRollbackPath(site.id), {}).then(function (r) {
      if (r.status === 200 && r.data && r.data.ok) {
        closeModal();
        var res = siteRollbackResult(r.data);
        siteRollbackFlash[String(site.id)] = res;
        toast({
          kind: "success", title: "Rolled back",
          body: res.kind === "restored"
            ? "The site is serving its restored release again."
            : "The site is serving the previous release again.",
        });
        if (String(currentSiteId) === String(site.id)) loadSite(site.id, { quiet: true });
        return;
      }
      var copy = siteRollbackFailure(r.status, r.data);
      closeModal();
      toast({ kind: "error", title: copy.title, body: copy.body });
    });
  }

  // ── W4 deploy stage rail (charter D15-D17) ─────────────────────────────────
  // The console's live twin of the /new provisioning timeline: a six-stage rail
  // PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE (PROVISION stays silent),
  // driven by the `site.deploy.stage` SSE push, NOT a poll. It reuses the shared
  // step component (newStepsHtml), the min-dwell pacer (paceSteps/seedPaceLedger)
  // and the region-signature diff so one stage transition never restarts the CSS
  // animations of the stages around it. The pure fold/signature/markup helpers
  // are node-pinned via __bpTestHook; the EventSource wiring + DOM mount below are
  // browser-verified (the harness rule — only string-in/derivation helpers pin).
  var DEPLOY_RAIL_STAGES = ["PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"];
  var DEPLOY_RAIL_LABELS = {
    PLAN: "Plan", BUILD: "Build", STAGE: "Stage",
    HEALTH: "Health check", SWITCH: "Go live", RETIRE: "Retire old",
  };

  // Pure: the engine's per-stage status word → a rail display role (the same
  // vocabulary newStepsHtml renders — ok/failed/active/pending, plus skipped).
  // Unknown/blank → pending, so a lean report never invents progress.
  function deployStageRole(status) {
    switch (status) {
      case "done": return "ok";
      case "failed": return "failed";
      case "running": case "started": return "active";
      case "skipped": return "skipped";
      default: return "pending";
    }
  }

  // Pure: fold a deployment's console narration (deploy.ex console_entry:
  // {stage,status,detail,at}) into a stage→latest map. Non-rail lines are ignored
  // and the LAST entry per stage wins (a stage moves running→done). Seeds the rail
  // from a deployment fetched MID-flight so opening the page lands at the right
  // stage instantly instead of replaying from PLAN. The FIRST entry seen for a
  // stage stamps its `startedAt`; the terminal (done/failed) entry stamps its
  // `finishedAt` — the two `at`s the completed-stage duration reads from (D23).
  // Mirrors buildProvisionRow's entries[0].at start rule.
  function deployRailLedgerFromConsole(arr) {
    var ledger = {};
    (arr || []).forEach(function (e) {
      if (!e || DEPLOY_RAIL_STAGES.indexOf(e.stage) === -1) return;
      var prev = ledger[e.stage];
      var startedAt = prev && prev.startedAt != null ? prev.startedAt
        : (e.at != null ? e.at : null);
      var finishedAt = prev ? prev.finishedAt : null;
      if (e.status === "done" || e.status === "failed") {
        finishedAt = e.at != null ? e.at : finishedAt;
      }
      ledger[e.stage] = {
        status: e.status,
        detail: (typeof e.detail === "string" && e.detail) ? e.detail : "",
        startedAt: startedAt,
        finishedAt: finishedAt,
      };
    });
    return ledger;
  }

  // Pure: the six ordered rail rows from the ledger. A stage with no entry is
  // pending; once ANY stage has failed, the pending stages AFTER it read
  // `skipped` — the build died before reaching them, exactly as deploy.ex's
  // stages/1 folds a failed run, so the rail never shows "pending forever" rows on
  // a dead deploy. Row shape matches the shared step component so it runs through
  // paceSteps + newStepsHtml unchanged.
  function deployRailRows(ledger) {
    ledger = ledger || {};
    var rows = DEPLOY_RAIL_STAGES.map(function (name) {
      var e = ledger[name];
      var role = e ? deployStageRole(e.status) : "pending";
      // A completed stage (done/failed) carries its real duration from the two
      // stamps the ledger folded (start → finish); newStepsHtml renders it via
      // fmtDur. Active/pending stay null — the active-stage live ETA/ring is
      // out of scope this wave (D23), and stepElapsed is total-over-partial so a
      // missing stamp is an honest "—", never a guessed or NaN duration.
      var elapsedMs = (e && (role === "ok" || role === "failed"))
        ? stepElapsed(e.startedAt, e.finishedAt)
        : null;
      return {
        step: name,
        label: DEPLOY_RAIL_LABELS[name] || name,
        role: role,
        elapsedMs: elapsedMs,
        caption: (e && e.detail) || "",
        probes: [],
      };
    });
    var failedIdx = -1;
    for (var i = 0; i < rows.length; i++) { if (rows[i].role === "failed") { failedIdx = i; break; } }
    if (failedIdx >= 0) {
      for (var j = failedIdx + 1; j < rows.length; j++) {
        if (rows[j].role === "pending") rows[j].role = "skipped";
      }
    }
    return rows;
  }

  // Pure: the region signature — the rail <ul> is replaced ONLY when a stage's
  // DISPLAY state actually changed (role/caption/completing dwell), so a
  // same-signature SSE tick or 1s clock tick never rebuilds the list and restarts
  // its animations. Mirrors newStepsSig for the /new screen.
  function deployRailSignature(rows) {
    return (rows || []).map(function (r) {
      return r.step + ":" + r.role + (r.completing ? "*" : "") + ":" + (r.caption || "");
    }).join(",");
  }

  // Pure: the rail's honest headline from the display rows. Live once every stage
  // is done; Failed on any failure (naming the stage that broke — never a dead
  // end); otherwise the active stage's label.
  function deployRailStatus(rows) {
    rows = rows || [];
    var failed = null, active = null, allOk = rows.length > 0;
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      if (r.role === "failed" && !failed) failed = r;
      if (r.role === "active" && !active) active = r;
      if (r.role !== "ok") allOk = false;
    }
    if (failed) return { tone: "failed", text: "Deploy failed at " + failed.label };
    if (allOk) return { tone: "live", text: "Live" };
    if (active) return { tone: "active", text: active.label + "…" };
    return { tone: "active", text: "Starting…" };
  }

  // Pure: the rail markup — a section wrapping the shared step component. opts:
  // { deploymentId, url (copyable when live), failureDetail }. data-rail-sig lets
  // the browser patch it in place by signature.
  function deployRailHtml(rows, opts) {
    opts = opts || {};
    rows = rows || [];
    var st = deployRailStatus(rows);
    var head = '<div class="deploy-rail-head">' +
        '<h2 class="deploy-rail-title">Deploying</h2>' +
        '<span class="deploy-rail-status deploy-rail-status--' + esc(st.tone) + '">' + esc(st.text) + "</span>" +
      "</div>";
    var foot = "";
    if (st.tone === "live" && opts.url) {
      foot = '<div class="deploy-rail-live">' +
        '<a class="site-open" href="' + esc(opts.url) + '" target="_blank" rel="noopener">' + esc(opts.url) + "&nbsp;&#8599;</a>" +
        '<button class="copy-btn" type="button" data-copy="' + esc(opts.url) + '" aria-label="Copy live URL">' + COPY_SVG + "</button>" +
        "</div>";
    } else if (st.tone === "failed" && opts.failureDetail) {
      foot = '<div class="deploy-rail-fail" role="alert">' + esc(opts.failureDetail) + "</div>";
    }
    return '<section class="deploy-rail" data-deploy-rail data-rail-dep="' + esc(String(opts.deploymentId || "")) +
        '" data-rail-sig="' + esc(deployRailSignature(rows)) + '">' +
        head + newStepsHtml(rows) + foot +
      "</section>";
  }

  // Pure: which deployment the rail tracks — the one still in flight
  // (queued/building/pushing). Null when every deployment is terminal (the rail
  // folds away; the deploy list carries the history). Newest-first list → first
  // active row wins.
  function railDeployment(deployments) {
    var arr = deployments || [];
    for (var i = 0; i < arr.length; i++) {
      if (deployIsActive(arr[i].status || "queued")) return arr[i];
    }
    return null;
  }

  // Pure: can we deploy on this instance right now? A deploy mid-provision 422s
  // instance_not_live (the box has no URL yet), so the create modal's Deploy-now
  // checkbox is disabled until the instance is live.
  function instanceCanDeploy(bp) {
    return !!(bp && bp.url);
  }

  // ── Rail state + SSE-driven mount (browser-verified) ───────────────────────
  // Per-deployment: the SSE-fed stage ledger + the min-dwell pace ledger + the
  // last-rendered signature. Keyed by deployment id; survives the site re-renders
  // a coarse deployments tick triggers.
  var deployRailState = {};
  var deployRailCtx = null;   // { siteId, deploymentId, url } for the mounted rail
  var deployRailTicker = null;
  var deployLiveWatch = {};   // site id → live URL to toast once the deploy settles

  function deployRailStateFor(depId) {
    depId = String(depId || "");
    if (!deployRailState[depId]) {
      deployRailState[depId] = { ledger: {}, paceLedger: {}, seeded: false, sig: null };
    }
    return deployRailState[depId];
  }

  // Record one stage transition (from an SSE site.deploy.stage payload) into a
  // deployment's ledger — latest-wins per stage. The stage SSE frame carries no
  // timestamp (server change is out of scope, D23), so a live-observed
  // transition is CLIENT-clock stamped: start on first sight, finish when it
  // settles — and a prior (console-seeded, server-clock) stamp is preserved so a
  // duplicate tick never wipes an already-computed duration.
  function recordDeployStage(depId, stage, status, detail) {
    if (DEPLOY_RAIL_STAGES.indexOf(stage) === -1) return;
    var st = deployRailStateFor(depId);
    var prev = st.ledger[stage];
    var now = Date.now();
    var startedAt = prev && prev.startedAt != null ? prev.startedAt : now;
    var finishedAt = prev ? prev.finishedAt : null;
    if (status === "done" || status === "failed") finishedAt = now;
    st.ledger[stage] = {
      status: status,
      detail: (typeof detail === "string" && detail) ? detail : "",
      startedAt: startedAt,
      finishedAt: finishedAt,
    };
  }

  // Truth fold → min-dwell pacer. seedPaceLedger on FIRST sight so an
  // open-mid-deploy renders already-finished history done instantly; only
  // transitions observed live get the satisfying ≥3s dwell.
  function deployRailDisplayRows(depId) {
    var st = deployRailStateFor(depId);
    var rows = deployRailRows(st.ledger);
    if (!st.seeded) { st.seeded = true; seedPaceLedger(rows, st.paceLedger); }
    return paceSteps(rows, st.paceLedger, Date.now());
  }

  // Render the rail into its slot, region-diffed: replace the DOM only when the
  // paced display signature moved (a dwell expiring IS a change). Zero rebuilds
  // on a no-op tick, so the active-stage spinner never resets.
  function renderDeployRail(slot, depId) {
    if (!slot) return;
    var st = deployRailStateFor(depId);
    var rows = deployRailDisplayRows(depId);
    var sig = deployRailSignature(rows);
    if (st.sig === sig && slot.querySelector && slot.querySelector("[data-deploy-rail]")) return;
    st.sig = sig;
    var failed = rows.filter(function (r) { return r.role === "failed"; })[0];
    slot.innerHTML = deployRailHtml(rows, {
      deploymentId: depId,
      url: (deployRailCtx && String(deployRailCtx.deploymentId) === String(depId)) ? deployRailCtx.url : "",
      failureDetail: failed ? failed.caption : "",
    });
  }

  // Mount the rail for the in-flight deployment (if any) into #deploy-rail-slot.
  // Seeds the ledger from the row's console narration (idempotent, latest-wins) so
  // server truth shows even for events that predate this tab, then renders +
  // starts the dwell ticker. No active deployment → clear the slot, stop the tick.
  function mountDeployRail(scope, site, bp, deployments) {
    var slot = scope && scope.querySelector ? scope.querySelector("#deploy-rail-slot") : null;
    if (!slot) return;
    var dep = railDeployment(deployments);
    if (!dep) { slot.innerHTML = ""; deployRailCtx = null; stopDeployRailTicker(); return; }
    var st = deployRailStateFor(dep.id);
    var seeded = deployRailLedgerFromConsole(dep.console || []);
    Object.keys(seeded).forEach(function (k) { st.ledger[k] = seeded[k]; });
    st.sig = null; // force a paint into the fresh slot
    deployRailCtx = { siteId: site.id, deploymentId: dep.id, url: siteLiveUrl(site, bp) || "" };
    renderDeployRail(slot, dep.id);
    startDeployRailTicker();
  }

  function startDeployRailTicker() {
    if (deployRailTicker) return;
    deployRailTicker = setInterval(tickDeployRail, 1000);
  }
  function stopDeployRailTicker() {
    if (deployRailTicker) { clearInterval(deployRailTicker); deployRailTicker = null; }
  }
  // The 1s dwell tick: expire the min-dwell pacing (completing → done) and sweep
  // the active dot's ring in place. Self-stops when the slot is gone (navigated
  // away) so no orphan timer survives.
  function tickDeployRail() {
    if (!deployRailCtx) { stopDeployRailTicker(); return; }
    var slot = document.querySelector("#deploy-rail-slot");
    if (!slot) { stopDeployRailTicker(); return; }
    var depId = deployRailCtx.deploymentId;
    renderDeployRail(slot, depId);
    tickActiveRing(slot, deployRailRows(deployRailStateFor(depId).ledger));
  }

  // Once the tracked deploy reaches all-done, fire the one-motion "your site is
  // live" toast with the copyable URL — exactly once per watch, from ANY view.
  function maybeDeployLiveToast(siteId, depId) {
    var url = deployLiveWatch[String(siteId)];
    if (!url) return;
    var rows = deployRailRows(deployRailStateFor(depId).ledger);
    var allDone = rows.length && rows.every(function (r) { return r.role === "ok"; });
    if (!allDone) return;
    delete deployLiveWatch[String(siteId)];
    toast({
      kind: "success", title: "Your site is live", body: url, duration: 12000,
      action: {
        label: "Copy URL",
        onClick: function () {
          if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(url);
        },
      },
    });
  }

  // The site.deploy.stage SSE handler (charter D15-D17): record the stage, drive
  // the live rail on the matching detail WITHOUT a full reload (that would restart
  // the animations), and refresh the LIST / instance-overview per-site badges.
  function onDeployStageEvent(v, payload) {
    payload = payload || {};
    if (payload.deployment_id && payload.stage) {
      recordDeployStage(payload.deployment_id, payload.stage, payload.status, payload.detail);
      maybeDeployLiveToast(payload.site_id, payload.deployment_id);
    }
    if (v === "site" && payload.site_id && String(parseHash().id) === String(payload.site_id)) {
      var slot = document.querySelector("#deploy-rail-slot");
      if (slot && deployRailCtx && String(deployRailCtx.deploymentId) === String(payload.deployment_id)) {
        renderDeployRail(slot, payload.deployment_id);
        tickActiveRing(slot, deployRailRows(deployRailStateFor(payload.deployment_id).ledger));
      } else {
        // A deployment we aren't tracking yet (the one-motion chain's fresh build)
        // — reload once to mount its rail; subsequent stages patch in place.
        loadSite(payload.site_id, { quiet: true });
      }
      return;
    }
    // The list + instance Overview show per-site deploy badges — keep them honest.
    if (v === "sites") loadSites();
    else if (v === "instance") reloadInstanceView();
  }

  // One-motion create-and-deploy (charter D18): the create 201 chains straight
  // into POST /v1/sites/:id/deploy (no server deploy_now param — the chain is
  // client-side, so a create still stands alone if the deploy leg fails), drops
  // the user onto the site detail (the live rail), and arms the live-URL toast.
  function createAndDeploy(bp, site) {
    location.hash = "#site/" + encodeURIComponent(site.id);
    deployLiveWatch[String(site.id)] = siteLiveUrl(site, bp) || "";
    toast({ kind: "info", title: "Creating your site", body: "Kicking off the first deploy…", duration: 3000 });
    api("POST", "/v1/sites/" + encodeURIComponent(site.id) + "/deploy", {}).then(function (r) {
      if (r.status === 201) {
        if (String(currentSiteId) === String(site.id)) loadSite(site.id, { quiet: true });
      } else {
        delete deployLiveWatch[String(site.id)];
        toast({
          kind: "error", title: "Couldn't start the first deploy",
          body: friendly(r.data, "The site was created — open it and press Deploy to try again."),
          action: { label: "Open site", onClick: function () { location.hash = "#site/" + encodeURIComponent(site.id); } },
        });
      }
    });
  }

  function deployRow(d, currentId, flash) {
    var st = d.status || "queued";
    // Headline ref: a full 40-char commit sha is noise, not information — show
    // the 7-char short form (full sha on hover). Only hex-sha-shaped refs are
    // shortened; anything else (a tag, a hand-set ref) renders verbatim.
    var isSha = d.git_ref && /^[0-9a-f]{8,64}$/i.test(d.git_ref);
    var ref = d.image_tag ? '<span class="mono">' + esc(shortId(d.image_tag)) + "</span>"
      : d.git_ref ? '<span class="mono"' + (isSha ? ' title="' + esc(d.git_ref) + '"' : "") + ">" +
          esc(isSha ? shortSha(d.git_ref) : d.git_ref) + "</span>"
      : '<span class="dim">' + esc(shortId(d.id)) + "</span>";
    var isCurrent = currentId != null && String(d.id) === String(currentId);
    // stw5 (D25): a synchronous rollback that RESOLVED a build id leaves a "restored"
    // flash. It applies ONLY to the row that is now current (the server flipped
    // current_deployment_id to it) — so the restored row reads as an intentional
    // restore, never as a stale timestamp.
    var rolledBack = isCurrent && flash && flash.kind === "restored" &&
      flash.deploymentId != null && String(flash.deploymentId) === String(d.id);
    var when = d.became_live_at || d.updated_at || d.inserted_at;
    // Git meta the row already carries (D7): branch, trigger (how it shipped), sha
    // (when the headline is an image tag), and WHEN — "live since" once it went live.
    var metaBits = [];
    if (d.branch) metaBits.push(esc(d.branch));
    if (d.trigger) metaBits.push(esc(deployTriggerLabel(d.trigger)));
    if (d.git_ref && d.image_tag) metaBits.push('<span class="mono">' + esc(shortSha(d.git_ref)) + "</span>");
    metaBits.push(esc((st === "live" && d.became_live_at ? "live since " : "") + fmtWhen(when)));
    // The restored row keeps its ORIGINAL became_live_at, so name it a restore or the
    // old time reads as staleness (D25). Static prefix — only the time is server data.
    if (rolledBack) metaBits.push("restored build from " + esc(fmtWhen(d.became_live_at || when)));
    var fail = (st === "failed" && d.failure_reason)
      ? '<div class="deploy-fail' + (failureTone(d.failure_reason) === "blocked" ? " deploy-fail--blocked" : "") + '">' + esc(failureCopy(d.failure_reason)) + "</div>" : "";
    var action = promoteActionFor(d, currentId);
    var actionBtn = action
      ? '<button type="button" class="btn btn-ghost btn-sm dep-promote" data-dep-id="' + esc(d.id) + '" data-kind="' + esc(action.kind) + '">' + esc(action.label) + "</button>"
      : "";
    // "Now live" keys off current_deployment_id equality (isCurrent), NOT status —
    // every history row reads status:"live", so status alone can't tell which one is
    // actually serving traffic. A rolled-back restore names itself.
    var current = isCurrent
      ? '<span class="dep-current' + (rolledBack ? " dep-current--restored" : "") +
          '" title="Production traffic is served from this deployment">' +
          (rolledBack ? "Now live &mdash; rolled back" : "Now live") + "</span>"
      : "";
    var head = '<div class="deploy-head"><div class="deploy-main">' +
        '<div class="deploy-ref">' + ref + current + "</div>" +
        '<div class="deploy-meta">' + metaBits.join(" &middot; ") + "</div>" + fail +
        deployDetailHtml(d, st) +
      "</div>" +
      '<div class="dep-side">' + actionBtn +
        '<span class="dep-pill dep-' + esc(st) + '">' + esc(cap(st)) + "</span></div></div>";
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

  // =========================================================== INVITATION ACCEPT
  // The landing for the accept links router.ex mints
  // (`/#/invitations/accept?token=…`). Unauthed-capable: a logged-out landing
  // PARKS the token in sessionStorage, scrubs it from the address bar, rides
  // the normal login/signup (or OAuth) flow, and the first authed render()
  // resumes the accept. Endpoints:
  //   GET  /v1/invitations/:token  (unauthenticated preview; 404 for any
  //                                 dead/garbage token — no enumeration signal)
  //   POST /v1/invitations/accept  {token} → 200 {team_id} | 404 | 403 | 422
  var INVITE_KEY = "bpcloud.invite";
  function parkedInviteToken() {
    try { return sessionStorage.getItem(INVITE_KEY); } catch (e) { return null; }
  }
  function parkInviteToken(t) {
    try { sessionStorage.setItem(INVITE_KEY, t); } catch (e) {}
  }
  function clearParkedInvite() {
    try { sessionStorage.removeItem(INVITE_KEY); } catch (e) {}
  }

  // ------------------------------------------- "Log in with Barkpark Cloud"
  // An instance's /login page deep-links here carrying its own public origin:
  //   https://barkpark.cloud/#/instance-login?url=https%3A%2F%2Fguerrilla.barkpark.cloud
  // Same park/resume shape as invitations: logged out → park the origin +
  // banner the login card; the first authed render() matches the origin
  // against the user's OWN fleet and rides the existing studio-link mint —
  // authorization never moves client-side, the deep link carries no secret.
  var STUDIO_LOGIN_KEY = "bpcloud.studioLogin";
  function studioLoginFromHash(hash) {
    var m = (hash != null ? hash : location.hash || "").match(/^#\/?instance-login\?url=([^&]+)/);
    return m ? safeDecode(m[1]) : null;
  }
  function parkedStudioLogin() {
    try { return sessionStorage.getItem(STUDIO_LOGIN_KEY); } catch (e) { return null; }
  }
  function parkStudioLogin(u) {
    try { sessionStorage.setItem(STUDIO_LOGIN_KEY, u); } catch (e) {}
  }
  function clearParkedStudioLogin() {
    try { sessionStorage.removeItem(STUDIO_LOGIN_KEY); } catch (e) {}
  }
  // Pure: the https host of an instance origin, or null for anything that
  // does not parse as an https/http URL (a malformed deep link must degrade
  // to "no target", never throw inside render()).
  function studioLoginHost(u) {
    if (typeof u !== "string" || !/^https?:\/\//i.test(u)) return null;
    try { return new URL(u).host || null; } catch (e) { return null; }
  }
  // Pure: which of MY instances is the deep link asking for? Host equality
  // against each barkpark's public url — never a substring match.
  function studioLoginMatch(fleet, instanceUrl) {
    var want = studioLoginHost(instanceUrl);
    if (!want || !Array.isArray(fleet)) return null;
    for (var i = 0; i < fleet.length; i++) {
      if (fleet[i] && studioLoginHost(fleet[i].url) === want) return fleet[i];
    }
    return null;
  }

  // Pure: what the landing shows BEFORE any accept POST.
  //   preview 404 / absent        → "invalid"        (revoked / used / garbage)
  //   preview past its expiry     → "expired"        (landed after the clock ran out)
  //   already on the invited team → "already_member" (nothing to accept)
  //   otherwise                   → "confirm"        (the Join screen)
  function inviteLandingState(previewStatus, preview, me, nowMs) {
    if (previewStatus === 404 || !preview || !preview.team) return "invalid";
    if (preview.expires_at && Date.parse(preview.expires_at) <= nowMs) return "expired";
    if (me && me.team && me.team.slug && preview.team.slug === me.team.slug) return "already_member";
    return "confirm";
  }

  // Pure: the terminal state an accept POST result lands on. The server folds
  // expired/revoked/used into one 404 (no enumeration signal), so "expired" is
  // only claimable when OUR earlier preview carried an expires_at that has
  // since passed — otherwise the honest answer is "invalid" (either/or copy).
  function inviteTerminalFrom(status, data, preview, nowMs) {
    if (status === 200) return "joined";
    if (status === 403) return "wrong_account";
    if (status === 404) {
      if (preview && preview.expires_at && Date.parse(preview.expires_at) <= nowMs) return "expired";
      return "invalid";
    }
    return "error"; // 422 accept_failed / 5xx / anything unexpected → retryable
  }

  // Pure per-state markup. Calm, second-person, zero jargon; every TERMINAL
  // state carries exactly ONE next action (a [data-invite-act] button); the
  // confirm screen additionally offers a quiet "Not now" escape (.invite-skip).
  function inviteStateHtml(state, ctx) {
    ctx = ctx || {};
    var team = ctx.team ? String(ctx.team) : "this team";
    var teamB = "<b>" + esc(team) + "</b>";
    function card(ico, title, copyHtml, actionsHtml) {
      return '<div class="invite-wrap"><div class="invite-card card">' + ico +
        '<h1 class="invite-title">' + esc(title) + "</h1>" +
        '<p class="invite-copy">' + copyHtml + "</p>" +
        '<div class="invite-actions">' + actionsHtml + "</div>" +
        "</div></div>";
    }
    function act(kind, label) {
      return '<button type="button" class="btn btn-primary invite-action" data-invite-act="' +
        esc(kind) + '">' + esc(label) + "</button>";
    }
    var ICO_OK = '<div class="invite-ico invite-ico--ok" aria-hidden="true">✓</div>';
    var ICO_INFO = '<div class="invite-ico invite-ico--info" aria-hidden="true">i</div>';
    var ICO_WARN = '<div class="invite-ico invite-ico--warn" aria-hidden="true">!</div>';
    var ICO_MAIL = '<div class="invite-ico invite-ico--info" aria-hidden="true">✉</div>';

    if (state === "joined") {
      return card(ICO_OK, "You're in",
        "Welcome to " + teamB + ". Everything the team runs is in your dashboard now.",
        act("overview", "Go to Overview"));
    }
    if (state === "already_member") {
      return card(ICO_INFO, "You're already a member",
        "You already belong to " + teamB + " — there's nothing left to accept.",
        act("overview", "Go to Overview"));
    }
    if (state === "expired") {
      return card(ICO_WARN, "This invitation has expired",
        "Invitations only last a limited time, and this one's time ran out. " +
          "Ask the person who invited you to send a fresh one.",
        act("overview", "Go to your dashboard"));
    }
    if (state === "wrong_account") {
      return card(ICO_INFO, "This invitation is for a different email",
        (ctx.email ? "It was sent to <b>" + esc(String(ctx.email)) + "</b>" : "It was sent to a different address") +
          (ctx.meEmail ? ", but you're signed in as <b>" + esc(String(ctx.meEmail)) + "</b>." : ".") +
          " Sign in with the invited address to accept it.",
        act("switch", "Switch account"));
    }
    if (state === "error") {
      return card(ICO_WARN, "Something went wrong",
        "We couldn't accept the invitation just now — nothing has changed. Give it another try.",
        act("retry", "Try again"));
    }
    if (state === "confirm") {
      return card(ICO_MAIL, "Join " + team + "?",
        "You've been invited to join " + teamB +
          (ctx.role ? " as " + esc(String(ctx.role)) : "") + "." +
          (ctx.email ? " This invitation was sent to <b>" + esc(String(ctx.email)) + "</b>." : ""),
        act("join", "Join " + team) +
          '<a class="invite-skip" href="#overview">Not now</a>');
    }
    // "invalid" + any unknown state: the total fallback.
    return card(ICO_WARN, "This invitation isn't valid any more",
      "The link may have been revoked or already used. If you still need access, " +
        "ask the person who invited you to send a new one.",
      act("overview", "Go to your dashboard"));
  }

  function inviteCtx(preview, me) {
    return {
      team: preview && preview.team && preview.team.name,
      role: preview && preview.role,
      email: preview && preview.email,
      meEmail: me && me.user && me.user.email,
    };
  }

  // The invite view lives OUTSIDE index.html's static sections (it's the one
  // view reached from a minted link, not the nav) — created lazily next to the
  // other detail sections so applyRoute's show/hide treats it like any view.
  function ensureInviteView() {
    var sec = document.getElementById("view-invite");
    if (sec) return sec;
    var ref = document.getElementById("view-site");
    if (!ref || !ref.parentNode) return null;
    sec = document.createElement("section");
    sec.id = "view-invite";
    sec.className = "view";
    ref.parentNode.insertBefore(sec, ref.nextSibling);
    return sec;
  }

  var inviteLoadSeq = 0;

  function loadInvite(tokenFromHash) {
    var box = ensureInviteView();
    if (!box) return;
    box.hidden = false;
    // Park the URL token and scrub it from the address bar immediately — the
    // token is a credential; it must not linger in history or a screenshot.
    // (?scen etc. survive: only the fragment is rewritten.)
    var token = tokenFromHash || null;
    if (token) {
      parkInviteToken(token);
      if (typeof history !== "undefined" && history.replaceState) {
        history.replaceState(null, "", location.pathname + location.search + "#invitations/accept");
      }
    } else {
      token = parkedInviteToken();
    }
    if (!token) {
      renderInviteState(box, "invalid", null, null, null);
      return;
    }
    box.innerHTML = '<div class="loading">Checking your invitation&hellip;</div>';
    var seq = ++inviteLoadSeq;
    Promise.all([
      api("GET", "/v1/invitations/" + encodeURIComponent(token), null, { noAuth: true }),
      api("GET", "/v1/me"),
    ]).then(function (res) {
      if (seq !== inviteLoadSeq || currentView() !== "invite") return;
      var pr = res[0];
      var me = res[1].ok ? res[1].data : null;
      var preview = pr.ok ? pr.data : null;
      var state = inviteLandingState(pr.status, preview, me, Date.now());
      renderInviteState(box, state, token, preview, me);
    });
  }

  function renderInviteState(box, state, token, preview, me) {
    // A settled outcome consumes the parked token (a reload must not replay
    // it); wrong_account keeps it — it IS the resume across the account
    // switch — and error keeps it so a retry/reload can try again.
    if (state === "joined" || state === "already_member" || state === "expired" || state === "invalid") {
      clearParkedInvite();
    }
    box.innerHTML = inviteStateHtml(state, inviteCtx(preview, me));
    var skip = box.querySelector(".invite-skip");
    if (skip) skip.addEventListener("click", function () { clearParkedInvite(); });
    var btn = box.querySelector("[data-invite-act]");
    if (!btn) return;
    var act = btn.getAttribute("data-invite-act");
    btn.addEventListener("click", function () {
      if (act === "overview") {
        clearParkedInvite();
        location.hash = "#overview";
        return;
      }
      if (act === "switch") {
        // Keep the parked token: after signing in with the invited address the
        // authed render() resumes the accept automatically.
        clearSession();
        render();
        return;
      }
      if (act === "join" || act === "retry") submitInviteAccept(box, btn, token, preview, me);
    });
  }

  function submitInviteAccept(box, btn, token, preview, me) {
    btn.disabled = true;
    btn.textContent = "Joining…";
    api("POST", "/v1/invitations/accept", { token: token }).then(function (r) {
      if (currentView() !== "invite") return;
      if (r.status === 200) {
        clearParkedInvite();
        // The team roster (and possibly the account's team) changed.
        meCache = null;
        loadMe();
        fleetCache = null;
        renderInviteState(box, "joined", token, preview, me);
        return;
      }
      renderInviteState(box, inviteTerminalFrom(r.status, r.data, preview, Date.now()), token, preview, me);
    });
  }

  // The logged-out companion: a banner on the sign-in card that says what
  // logging in will do with the parked invitation (and fails honestly when the
  // link is already dead, instead of making the user log in to find out).
  function showAuthInviteBanner(token) {
    var loginCard = $("#login-card");
    if (!loginCard) return;
    var slot = document.getElementById("auth-invite");
    if (!slot) {
      slot = document.createElement("div");
      slot.id = "auth-invite";
      slot.className = "auth-invite";
      loginCard.insertBefore(slot, loginCard.firstChild);
    }
    slot.innerHTML = "";
    api("GET", "/v1/invitations/" + encodeURIComponent(token), null, { noAuth: true }).then(function (r) {
      if (!document.getElementById("auth-invite")) return;
      if (r.ok && r.data && r.data.team) {
        slot.innerHTML = '<span class="auth-invite-title">You\'ve been invited to join ' +
          esc(r.data.team.name) + ".</span> Log in — or create an account — with " +
          '<span class="auth-invite-email">' + esc(r.data.email) + "</span> to accept.";
      } else {
        clearParkedInvite();
        slot.innerHTML = "That invitation link isn't valid any more — it may have expired or been revoked. You can still log in.";
      }
    });
  }

  // A parked instance-login landing (logged out): say what signing in will do.
  // Static copy — unlike the invite banner there is nothing to preview server-
  // side, and probing would leak which hosts are managed here.
  function showAuthStudioBanner(instanceUrl) {
    var host = studioLoginHost(instanceUrl);
    var loginCard = $("#login-card");
    if (!loginCard) return;
    if (!host) { clearParkedStudioLogin(); return; }
    var slot = document.getElementById("auth-studio-login");
    if (!slot) {
      slot = document.createElement("div");
      slot.id = "auth-studio-login";
      slot.className = "auth-invite";
      loginCard.insertBefore(slot, loginCard.firstChild);
    }
    slot.innerHTML = '<span class="auth-invite-title">Log in to open Studio on ' +
      esc(host) + ".</span> You'll be sent straight back once you're signed in.";
  }

  // First authed render() after an instance-login landing: match the origin
  // against MY fleet, mint through the existing studio-link route, and send
  // the browser back. Failures degrade to a toast on the normal dashboard —
  // the park is cleared up front so a broken link can't loop every render.
  function resumeStudioLogin(instanceUrl) {
    clearParkedStudioLogin();
    var host = studioLoginHost(instanceUrl);
    if (!host) return;
    ensureFleet().then(function (fleet) {
      if (!fleet) {
        toast({ kind: "error", title: "Couldn't reach your instances", body: "Try again from " + host + "/login." });
        return;
      }
      var bp = studioLoginMatch(fleet, instanceUrl);
      if (!bp) {
        toast({ kind: "error", title: "Instance not linked", body: host + " isn't managed by this account." });
        return;
      }
      api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/studio-link", {}).then(function (r) {
        if (r.status === 200 && r.data && r.data.url) {
          location.replace(r.data.url);
        } else {
          toast({ kind: "error", title: "Couldn't open Studio", body: friendly(r.data, "Try again from the instance page.") });
        }
      });
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

  // A4/D66: ONE launch component, TWO containers. The old #launch view + its gate
  // are gone; launchFlow() renders a name field + submit into ANY container — the
  // empty-fleet welcome runway (inline) or the header modal. We NEVER lead with
  // plan choice (dwb-13: the server auto-starts a free trial); entitlement is
  // discovered on submit — a real 402 folds an inline plan step into the SAME
  // container, stashing the typed name across the Stripe round-trip.
  var LAUNCH_RETURN_KEY = "bp_launch_return"; // mirrors NEW_RETURN_KEY (app.js /new flow)

  // Pure: the trial-aware runway subline, from GET /v1/subscription server truth.
  // An un-entitled / trial / absent subscription reads as the free-trial
  // invitation; an already-entitled paid team gets the plain managed line.
  // PLACEHOLDER copy — final wording is the blueprint's RATIFY item (dwb-13).
  function runwaySubline(sub) {
    if (sub && launchEntitled(sub) && sub.plan !== "trial") {
      return "Fully managed — provisioned in about a minute.";
    }
    return "Free trial — no card required.";
  }

  // Pure: the welcome hero for the empty-fleet runway (A4). One line on what a
  // Barkpark is + the trial-aware subline; launchFlow appends the form + CTA.
  function welcomeHeroHtml(sub) {
    // h2: the runway renders inside a view that already owns the page h1.
    return '<div class="runway-hero">' +
      '<span class="new-eyebrow">Welcome to Barkpark Cloud</span>' +
      '<h2 class="runway-title">Launch your first Barkpark</h2>' +
      '<p class="runway-lead">A Barkpark is a fully-managed headless CMS instance — ' +
        "we provision the server, secure the domain, and keep it running for you.</p>" +
      '<p class="runway-sub">' + esc(runwaySubline(sub)) + "</p>" +
    "</div>";
  }

  // Pure: the post-launch destination. A 201 launch response carries the new
  // instance; route the operator straight to its story (#instance/<id>, A5's
  // pinned envelope) — never #fleet, never a toast-as-navigation. null when the
  // envelope lacks an id (a safe #fleet fallback then applies).
  function launchedHash(body) {
    var id = body && body.barkpark && body.barkpark.id;
    return id ? "#instance/" + encodeURIComponent(id) : null;
  }

  // Pure: the launch-flow state machine (A4/D66) — container-agnostic.
  //   name --submit--> submitting --201--> submitted
  //                                --402--> plan --choosePlan--> checkout
  //                                --error--> name
  // A Stripe round-trip re-enters via "resume" (the stashed name lands at name).
  function launchFlowReducer(state, event) {
    var e = event || {};
    if (e.type === "resume") return "name";
    switch (state) {
      case "name":
        return e.type === "submit" ? "submitting" : state;
      case "submitting":
        if (e.type !== "result") return state;
        if (e.status === 201) return "submitted";
        if (e.status === 402) return "plan";
        return "name"; // any other status → back to the name step
      case "plan":
        return e.type === "choosePlan" ? "checkout" : state;
      default:
        return state;
    }
  }

  function launchFlowShell(inner, opts) {
    return opts.runway
      ? '<div class="runway"><div class="card launch-flow">' + inner + "</div></div>"
      : '<div class="launch-flow">' + inner + "</div>";
  }
  function launchCta(opts) { return opts.runway ? "Create your first Barkpark" : "Launch"; }

  // Mount the launch component into `container`. opts: { runway } for the inline
  // empty-fleet welcome, or { modal, name } for the focus-trapped header modal.
  function launchFlow(container, opts) {
    opts = opts || {};
    if (!container) return;
    renderLaunchName(container, opts);
    // Resolve the trial subline from server truth (runway only) WITHOUT gating the
    // form — the server decides entitlement on submit (a 402 folds the plan step).
    if (opts.runway) {
      if (subLoaded || subError) refreshRunwaySubline(container);
      else loadSubscription().then(function () { refreshRunwaySubline(container); });
    }
  }

  function refreshRunwaySubline(container) {
    if (!container || !container.querySelectorAll) return;
    container.querySelectorAll(".runway-sub").forEach(function (el) {
      el.textContent = runwaySubline(subCache);
    });
  }

  // The component can be mounted in several containers at once (Overview runway,
  // Fleet runway, the modal), so element lookups are container-scoped by CLASS;
  // only the input carries an id — unique per mount — for its <label for>.
  var launchFlowSeq = 0;

  // Provider tab strip for the launch picker. Available providers only; the
  // active one carries aria-pressed="true" (styling reads the attribute, so the
  // class stays static — __css_check E3-safe). "" when nothing is provisionable.
  function launchProviderTabsHtml(activeKind) {
    var avail = PROVIDERS.filter(function (p) { return p.available; });
    if (!avail.length) return "";
    return avail.map(function (p) {
      var on = p.kind === activeKind ? "true" : "false";
      return '<button class="seg-btn" type="button" data-kind="' + esc(p.kind) + '" aria-pressed="' + on + '">' +
        esc(p.name) + "</button>";
    }).join("");
  }

  // Catalog <option> rows (region select), the selected one marked.
  function catalogRegionsHtml(catalog, selected) {
    var regions = (catalog && catalog.regions) || [];
    return regions.map(function (rg) {
      var sel = rg.slug === selected ? " selected" : "";
      return '<option value="' + esc(rg.slug) + '"' + sel + ">" + esc(rg.name || rg.slug) + "</option>";
    }).join("");
  }

  // Size radio rows, each with its normalized spec line + monthly price (the
  // honest 'Price unavailable' when the catalog carries none).
  function catalogSizeRowsHtml(catalog, kind, selectedType, groupName) {
    var types = (catalog && catalog.server_types) || [];
    return types.map(function (t) {
      var checked = t.slug === selectedType ? " checked" : "";
      return '<label class="size-opt">' +
        '<input class="size-opt-radio" type="radio" name="' + esc(groupName) + '" value="' + esc(t.slug) + '"' + checked + " />" +
        '<span class="size-opt-main">' +
          '<span class="size-opt-name">' + esc(t.slug) + "</span>" +
          '<span class="size-opt-spec dim">' + esc(serverTypeLabel(t)) + "</span>" +
        "</span>" +
        '<span class="size-opt-price">' + esc(formatMonthlyPrice(t.monthly_price, kind, catalog && catalog.currency)) + "</span>" +
      "</label>";
    }).join("");
  }

  // The catalog panel for a resolved view state (loading is a transient DOM
  // state handled at the mount). Every branch is an honest state — never a blank
  // panel or a fabricated price.
  function catalogPanelHtml(vs, kind, sel, groupName) {
    var name = esc(providerMeta(kind).name);
    if (vs.state === "ready") {
      var regions = catalogRegionsHtml(vs.catalog, sel && sel.region);
      var sizes = catalogSizeRowsHtml(vs.catalog, kind, sel && sel.server_type, groupName);
      if (!regions || !sizes) {
        return '<p class="launch-catalog-note dim">This ' + name + " account has no regions or sizes to provision into.</p>";
      }
      return '<div class="field"><label class="label">Region</label>' +
          '<select class="form-input launch-region">' + regions + "</select></div>" +
        '<div class="field"><span class="label">Size</span>' +
          '<div class="size-list">' + sizes + "</div></div>";
    }
    if (vs.state === "no_provider") {
      // Provider-honest copy (Decision 17): managed Hetzner launches on the
      // PLATFORM account, so the hetzner tab may promise the managed fallback.
      // Azure is BYO-only — a launch without a connected row 422s at the button —
      // so its copy must say connect-first, never promise a managed instance.
      var lead = kind === "azure"
        ? "Azure instances provision into your own subscription — connect your Azure account to launch here."
        : "Connect a " + name + " account to provision here. Until then we launch a fully-managed instance for you.";
      return '<div class="launch-catalog-empty">' +
        '<p class="dim">' + lead + "</p>" +
        '<button class="btn btn-ghost btn-sm launch-connect-provider" type="button" data-kind="' + esc(kind) + '">Connect ' + name + "</button></div>";
    }
    if (vs.state === "unavailable") {
      return '<p class="launch-catalog-note dim">' + name + "'s catalog is unavailable right now — you can still launch and we'll pick sensible defaults.</p>";
    }
    return '<div class="launch-catalog-empty"><p class="dim">Couldn\'t load the ' + name + " catalog.</p>" +
      '<button class="btn btn-ghost btn-sm launch-catalog-retry" type="button" data-kind="' + esc(kind) + '">Retry</button></div>';
  }

  // Fetch + paint the catalog into the picker's slot, tracking the selection on
  // the container (container._launchHosting) so submit reads region+size back.
  // Browser-coupled (network + events) — the pure builders above are what the
  // node harness pins.
  function mountLaunchCatalog(container, opts, kind, groupName) {
    var slot = container.querySelector(".launch-catalog");
    if (!slot) return;
    container._launchHosting = { provider: kind, region: null, server_type: null };
    slot.innerHTML = '<div class="loading">Loading ' + esc(providerMeta(kind).name) + " catalog&hellip;</div>";
    api("GET", "/v1/providers/" + encodeURIComponent(kind) + "/catalog").then(function (r) {
      // A tab switch mid-flight: ignore a stale response for a provider we left.
      if (!container._launchHosting || container._launchHosting.provider !== kind) return;
      if (!slot.isConnected) return;
      var vs = catalogViewState(r);
      var sel = vs.state === "ready" ? defaultCatalogSelection(vs.catalog) : { region: null, server_type: null };
      container._launchHosting = { provider: kind, region: sel.region, server_type: sel.server_type };
      slot.innerHTML = catalogPanelHtml(vs, kind, sel, groupName);
      wireLaunchCatalog(container, opts, kind, groupName);
    });
  }

  function wireLaunchCatalog(container, opts, kind, groupName) {
    var region = container.querySelector(".launch-region");
    if (region) region.addEventListener("change", function () {
      if (container._launchHosting) container._launchHosting.region = region.value || null;
    });
    container.querySelectorAll(".size-opt-radio").forEach(function (radio) {
      radio.addEventListener("change", function () {
        if (container._launchHosting) container._launchHosting.server_type = radio.value || null;
      });
    });
    var connect = container.querySelector(".launch-connect-provider");
    if (connect) connect.addEventListener("click", function () { openProviderCredential(connect.getAttribute("data-kind")); });
    var retry = container.querySelector(".launch-catalog-retry");
    if (retry) retry.addEventListener("click", function () { mountLaunchCatalog(container, opts, kind, groupName); });
  }

  // Step 1: name + a provider→region+size hosting picker + submit (state "name").
  function renderLaunchName(container, opts) {
    var hero = opts.runway
      ? welcomeHeroHtml(subCache)
      : '<h2 class="modal-title" id="modal-title">Launch a Barkpark</h2>' +
        '<p class="modal-sub">Name it and we provision it — a fresh instance, hosted and run for you.</p>';
    var seq = ++launchFlowSeq;
    var nameId = "launch-flow-name-" + seq;
    var groupName = "launch-size-" + seq;
    var avail = PROVIDERS.filter(function (p) { return p.available; });
    var activeKind = avail.length ? avail[0].kind : null;
    // Static class strings per variant so the CSS checker can resolve every token
    // (no dynamic class-head concat — __css_check E3).
    var submitBtn = opts.runway
      ? '<button class="btn btn-primary btn-lg btn-block" type="submit">' + esc(launchCta(opts)) + "</button>"
      : '<button class="btn btn-primary" type="submit">' + esc(launchCta(opts)) + "</button>";
    var hosting = activeKind
      ? '<div class="launch-hosting"><span class="label">Where to host</span>' +
          '<div class="seg" role="group" aria-label="Hosting provider">' + launchProviderTabsHtml(activeKind) + "</div>" +
          '<div class="launch-catalog" aria-live="polite"></div></div>'
      : "";
    var inner = hero +
      '<form class="launch-form" novalidate>' +
        '<div class="field"><label class="label" for="' + nameId + '">Name</label>' +
          '<input class="form-input" id="' + nameId + '" type="text" placeholder="Production" value="' +
            esc(opts.name || "") + '" required />' +
          '<p class="field-hint dim">A human label for this instance.</p></div>' +
        hosting +
        submitBtn +
      "</form>";
    container.innerHTML = launchFlowShell(inner, opts);
    var form = container.querySelector(".launch-form");
    if (form) form.addEventListener("submit", function (e) { submitLaunchFlow(e, container, opts); });
    // Provider tabs: activate + refetch the catalog for the chosen provider.
    container.querySelectorAll(".seg-btn[data-kind]").forEach(function (tab) {
      tab.addEventListener("click", function () {
        var k = tab.getAttribute("data-kind");
        container.querySelectorAll(".seg-btn[data-kind]").forEach(function (t) {
          t.setAttribute("aria-pressed", t === tab ? "true" : "false");
        });
        mountLaunchCatalog(container, opts, k, groupName);
      });
    });
    if (activeKind) mountLaunchCatalog(container, opts, activeKind, groupName);
    var input = container.querySelector(".launch-form .form-input");
    if (input && opts.modal) input.focus();
  }

  function submitLaunchFlow(e, container, opts) {
    e.preventDefault();
    var input = container.querySelector(".launch-form .form-input");
    var name = (input && input.value || "").trim();
    if (!name) { toast({ kind: "error", title: "A name is required." }); if (input) input.focus(); return; }
    var btn = container.querySelector('.launch-form button[type="submit"]');
    if (btn) { btn.disabled = true; btn.textContent = "Launching…"; }
    // Provider/region/size ride along when the hosting picker resolved a real
    // selection (honored once S6 lands; harmlessly ignored before — a name-only
    // managed launch is unchanged).
    var h = container._launchHosting || {};
    api("POST", "/v1/launch", launchBody(name, h.provider, h.region, h.server_type)).then(function (r) {
      if (r.status === 201) {
        fleetCache = null; // the new instance must show on the next fetch
        try { localStorage.removeItem(LAUNCH_RETURN_KEY); } catch (x) {}
        if (opts.modal) closeModal();
        toast({ kind: "success", title: "Launching " + name, body: "Provisioning your instance." });
        // A4/A5: route to the instance story; #fleet only when the envelope
        // carried no id. Same-hash set fires no hashchange — repaint explicitly.
        var target = launchedHash(r.data) || "#fleet";
        if (location.hash === target) applyRoute();
        else location.hash = target;
        return;
      }
      if (r.status === 402) {
        renderLaunchPlan(container, opts, name); // fold the plan step into the SAME container
        return;
      }
      if (btn) { btn.disabled = false; btn.textContent = launchCta(opts); }
      // Decision 19, launch edition: a 422 like provider_not_connected carries
      // server-owned remediation copy naming the exact fix (connect the provider
      // first) — friendly() provably drops it, so surface it directly.
      var copy = remediationCopy(r.data);
      toast({ kind: "error", title: "Couldn't launch", body: copy || friendly(r.data, "Please try again.") });
    });
  }

  // Step 2 (402): the inline plan fold — reuses TIERS + the checkout hand-off.
  // Stashes the typed name so a success return re-enters the flow prefilled.
  function renderLaunchPlan(container, opts, name) {
    try { localStorage.setItem(LAUNCH_RETURN_KEY, name); } catch (x) {}
    var tiers = TIERS.filter(function (t) { return !t.free; }).map(function (t) {
      return '<div class="new-tier">' +
        '<div class="new-tier-head"><span class="new-tier-name">' + esc(t.name) + "</span>" +
          '<span class="new-tier-price">' + esc(t.price) + '<span class="dim">' + esc(t.per) + "</span></span></div>" +
        '<p class="dim">' + esc(t.note) + "</p>" +
        '<button class="btn btn-primary btn-block new-plan" data-plan="' + esc(t.plan) + '" type="button">Choose ' + esc(t.name) + "</button>" +
      "</div>";
    }).join("");
    var hero = opts.runway
      ? '<span class="new-eyebrow">One more step</span><h2 class="runway-title">Choose a plan to launch</h2>'
      : '<h2 class="modal-title" id="modal-title">Choose a plan to launch</h2>';
    var inner = hero +
      '<p class="dim launch-plan-lead">Your free trial isn\'t available — pick a plan to launch ' +
        esc(name) + ". Cancel anytime.</p>" +
      '<div class="new-tiers">' + tiers + "</div>" +
      '<button class="btn btn-ghost btn-block launch-plan-back" type="button">Back</button>';
    container.innerHTML = launchFlowShell(inner, opts);
    container.querySelectorAll(".new-plan").forEach(function (b) {
      var label = b.textContent; // "Choose <Tier>" — restored after an error
      b.addEventListener("click", function () {
        b.disabled = true; b.textContent = "Opening checkout…";
        api("POST", "/v1/billing/checkout", { plan: b.getAttribute("data-plan") }).then(function (r) {
          if (r.status === 200 && r.data && r.data.checkout_url) { window.location = r.data.checkout_url; }
          else {
            b.disabled = false; b.textContent = label;
            try { localStorage.removeItem(LAUNCH_RETURN_KEY); } catch (x) {}
            toast({ kind: "error", title: "Couldn't open checkout", body: friendly(r.data, "Please try again.") });
          }
        });
      });
    });
    // In the modal the submit button just vanished under the fold — move focus
    // into the new content so keyboard users aren't dropped on <body>.
    if (opts.modal) {
      var firstPlan = container.querySelector(".new-plan");
      if (firstPlan) firstPlan.focus();
    }
    var back = container.querySelector(".launch-plan-back");
    if (back) back.addEventListener("click", function () {
      try { localStorage.removeItem(LAUNCH_RETURN_KEY); } catch (x) {}
      opts.name = name; // restore the typed name on the way back
      renderLaunchName(container, opts);
      if (opts.runway) refreshRunwaySubline(container);
    });
  }

  // Open the launch component in the focus-trapped modal (Overview + Fleet header
  // buttons, and the legacy #launch bookmark). prefillName re-enters a stashed
  // name after a Stripe round-trip.
  function openLaunchModal(prefillName) {
    var body = openModal('<div id="launch-modal-slot"></div>');
    if (!body) return;
    var slot = body.querySelector("#launch-modal-slot") || body;
    launchFlow(slot, { modal: true, name: prefillName || "" });
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
    // v4 sidebar account block (bottom): the USER identity, distinct from the
    // workspace switcher's TEAM identity above it.
    var who = email ? email.split("@")[0] : "Account";
    setText($("#acct-name"), who);
    setText($("#acct-email"), email || "");
    setText($("#acct-avatar"), (who[0] || "B").toUpperCase());
    renderTeamSwitcher(team);
  }

  // The workspace switcher's plan chip — the team's current plan, hidden until
  // the subscription is known (progressive: the Overview landing loads it). Reads
  // activePlan() so a trial reads "Trial", a paid plan its tier name.
  function paintWorkspacePlan() {
    var chip = $("#ws-plan");
    if (!chip) return;
    if (!subLoaded || !subCache) { chip.hidden = true; return; }
    var plan = activePlan();
    setText(chip, plan === "trial" ? "Trial" : planName(plan));
    chip.hidden = false;
  }

  // Team switcher (multi-team accounts): a <select> replaces the static team
  // name when /v1/me lists more than one membership. Choosing a team pins it
  // in localStorage (api() sends it as x-barkpark-team) and reloads — a full
  // reload is deliberate: every cache (fleet, subscription, members) is
  // team-scoped and must repopulate.
  function renderTeamSwitcher(active) {
    var host = $("#account-team");
    var teams = (meCache && meCache.teams) || [];
    if (!host || teams.length < 2) return;
    var activeId = (active && active.id) || "";
    var sel = document.createElement("select");
    sel.id = "team-switcher";
    sel.setAttribute("aria-label", "Switch team");
    sel.style.cssText =
      "background:transparent;border:none;color:inherit;font:inherit;cursor:pointer;max-width:160px";
    teams.forEach(function (t) {
      var o = document.createElement("option");
      o.value = t.id;
      o.textContent = t.name + " (" + t.role + ")";
      if (t.id === activeId) o.selected = true;
      sel.appendChild(o);
    });
    sel.addEventListener("change", function () {
      localStorage.setItem("bp.active-team", sel.value);
      location.reload();
    });
    host.textContent = "";
    host.appendChild(sel);
  }

  function loadMe() {
    setAccountChip(null, null); // immediate placeholder
    applyOperatorGate();        // fail-closed while me is unknown (hidden)
    api("GET", "/v1/me").then(function (r) {
      if (r.ok && r.data) {
        meCache = r.data;
        setAccountChip(r.data.team, r.data.user && r.data.user.email);
        // /v1/me is the operator truth (GR9): flip the sidebar entry on now that
        // platform_operator is known, and refresh the scope label's team name.
        applyOperatorGate();
        setScopeLabel(parseHash(), shellNavLayer(parseHash()));
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
      paintWorkspacePlan(); // the sidebar plan chip follows the real answer
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
  // Epoch (ms) of the last confirmed sign of life on the stream — set on the
  // initial connect/reconnect (onopen) and on every real data frame (onmessage).
  // The heartbeat the server sends every 25s is an SSE COMMENT (": ping"), which
  // EventSource NEVER surfaces to onmessage, so this only advances on genuine
  // invalidations — it is the honest "as of Xs ago" the liveness chip reads.
  var lastEventMs = null;

  // ── Liveness chip (OC6): topbar SSE health dot, honest reconnect ────────────
  // Pure state machine for the topbar dot, driven ONLY by the existing
  // EventSource signals (no second stream, no new SSE type). Three honest states:
  //   reconnecting — onerror fired and we have not recovered (stream is DOWN);
  //   stale        — stream is up but no data frame in LIVE_STALE_MS (we cannot
  //                  PROVE currency, so we say so — a quiet fleet, not a lie);
  //   live         — connected, recently confirmed (or freshly connected).
  // The dot colour tracks up-vs-dropped exactly (green family vs amber); the
  // "as of" label carries recency. Exported + unit-tested at the boundaries.
  var LIVE_STALE_MS = 90000; // 90s of silence → "stale" (well past the 25s heartbeat)
  function liveDotState(evtErrored, lastEventMs, nowMs) {
    if (evtErrored) return "reconnecting";
    if (lastEventMs == null) return "live"; // connected; sparse events ≠ trouble
    if (nowMs - lastEventMs > LIVE_STALE_MS) return "stale";
    return "live";
  }
  // Compact relative freshness for the chip's "as of" label (ms epochs, not ISO,
  // so relTime() doesn't fit). Empty until the first confirmed event.
  function liveFreshness(lastEventMs, nowMs) {
    if (lastEventMs == null) return "";
    var secs = Math.max(0, Math.round((nowMs - lastEventMs) / 1000));
    if (secs < 5) return "just now";
    if (secs < 60) return secs + "s ago";
    var mins = Math.round(secs / 60);
    if (mins < 60) return mins + "m ago";
    var hrs = Math.round(mins / 60);
    return hrs + "h ago";
  }
  var LIVE_CHIP_COPY = { live: "Live", stale: "Live", reconnecting: "Reconnecting…" };
  var LIVE_CHIP_ARIA = {
    live: "Live updates connected", stale: "Live updates connected but quiet",
    reconnecting: "Live updates interrupted, reconnecting",
  };

  // Inject the chip into the persistent topbar exactly once (index.html is frozen
  // this wave, so the SPA owns the node). Idempotent: a re-login reuses it.
  function ensureLivenessChip() {
    if (typeof document === "undefined" || !document.querySelector) return null;
    var existing = document.getElementById("liveness-chip");
    if (existing) return existing;
    var right = document.querySelector(".topbar .topbar-right");
    if (!right) return null;
    var chip = document.createElement("span");
    chip.id = "liveness-chip";
    chip.className = "live-chip";
    chip.setAttribute("role", "status");
    chip.setAttribute("aria-live", "polite");
    chip.innerHTML =
      '<span class="live-dot" aria-hidden="true"></span>' +
      '<span class="live-chip-label"></span>' +
      '<span class="live-chip-ago" aria-hidden="true"></span>';
    right.insertBefore(chip, right.firstChild);
    return chip;
  }

  // Paint the chip from the current stream signals. Cheap + idempotent; called on
  // every state transition AND once per second by the chip ticker (so the "as of"
  // label counts up and a quiet stream ages honestly into "stale").
  function renderLivenessChip() {
    var chip = document.getElementById("liveness-chip");
    if (!chip) return;
    var now = Date.now();
    var state = liveDotState(evtErrored, lastEventMs, now);
    chip.setAttribute("data-state", state);
    var ago = state === "reconnecting" ? "" : liveFreshness(lastEventMs, now);
    var label = chip.querySelector(".live-chip-label");
    if (label) label.textContent = LIVE_CHIP_COPY[state] || "Live";
    var agoEl = chip.querySelector(".live-chip-ago");
    if (agoEl) { agoEl.textContent = ago ? "· " + ago : ""; agoEl.hidden = !ago; }
    // role="status" is a live region: keep the ANNOUNCED name to the stable
    // per-state sentence (changes only on a real transition), so the per-second
    // "as of" tick — aria-hidden in the span — never spams a screen reader. The
    // ticking recency rides the title (a hover tooltip, not an announcement).
    chip.setAttribute("aria-label", LIVE_CHIP_ARIA[state] || "Live updates");
    chip.setAttribute("title",
      (LIVE_CHIP_ARIA[state] || "Live updates") + (ago ? ", last event " + ago : ""));
  }

  // A fresh data frame arrived — snap the dot's one-shot ping so motion signals
  // "data just changed" (never idle decoration; collapses under reduced-motion
  // via CSS). Re-arm by clearing + forcing a reflow so the animation restarts.
  function pingLivenessChip() {
    var chip = document.getElementById("liveness-chip");
    var dot = chip && chip.querySelector ? chip.querySelector(".live-dot") : null;
    if (!dot) return;
    dot.classList.remove("is-ping");
    if (dot.offsetWidth != null) { void dot.offsetWidth; } // reflow → restart
    dot.classList.add("is-ping");
  }

  // One shared 1s interval that ticks the "as of" label and ages a quiet stream
  // into "stale". Dies with the session (closeEvents) — no orphaned timer.
  var chipTicker = null;
  function startChipTicker() {
    if (chipTicker) return;
    renderLivenessChip();
    chipTicker = setInterval(renderLivenessChip, 1000);
  }
  function stopChipTicker() {
    if (chipTicker) { clearInterval(chipTicker); chipTicker = null; }
  }

  function connectEvents() {
    var s = session();
    if (!s || !s.token) return;
    // The chip lives whenever we're authed, even if the stream is already open
    // (a re-render calls connectEvents again) — mount + tick it before the guard.
    ensureLivenessChip();
    startChipTicker();
    if (evtSource) return;
    try {
      evtSource = new EventSource("/v1/events?token=" + encodeURIComponent(s.token));
    } catch (e) { return; }
    evtSource.onopen = function () {
      // First connect (or a recovery after a drop): a confirmed sign of life.
      lastEventMs = Date.now();
      // Only announce a RECONNECT — the initial connect is silent.
      if (evtErrored) {
        evtErrored = false;
        toast({ kind: "success", title: "Live updates reconnected", duration: 2500 });
      }
      renderLivenessChip();
    };
    evtSource.onmessage = function (e) {
      // A real data frame (not the invisible heartbeat comment): the stream is
      // demonstrably current. Stamp it, pulse the dot, refresh the chip.
      lastEventMs = Date.now();
      pingLivenessChip();
      renderLivenessChip();
      var ev;
      try { ev = JSON.parse(e.data); } catch (x) { return; }
      // W4: the stage rail reads the pushed payload (site/deployment/stage), not
      // just the type — the coarse-invalidation handlers ignore the second arg.
      handleLiveEvent(ev && ev.type, ev && ev.payload);
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
      renderLivenessChip(); // dot → amber every retry (cheap + idempotent)
    };
  }

  function closeEvents() {
    if (evtSource) { try { evtSource.close(); } catch (e) {} evtSource = null; }
    evtErrored = false;
    lastEventMs = null;
    stopChipTicker();     // the topbar chip's clock dies with the session
    renderLivenessChip(); // reset to a neutral "live/—" before the shell hides
    stopInstanceTicker(); // C3: no orphaned timeline ticker after logout
  }

  function currentView() { return parseHash().view; }

  // The instance list changed (or an instance's state did): drop the cache and
  // refetch whichever fleet-backed view is on screen.
  function invalidateFleet(v) {
    fleetCache = null; // any cached fleet is now stale
    if (v === "overview") loadOverview();
    else if (v === "fleet") loadFleet(parseHash().filter || null);
    else if (v === "instance") reloadInstanceView();
  }

  // C6: a fleet/sites SSE tick refetches the instance drill-down — but ONLY the
  // Overview tab, which is fleet/sites-derived. The Webhooks tab owns its own
  // data (the instance-API proxy, no SSE confirm) and a remount would clobber an
  // in-flight toggle, an open delivery log, or a chosen dataset. Its header pill
  // going briefly stale is the honest trade (it refreshes on the next tab visit).
  function reloadInstanceView() {
    var h = parseHash();
    if (h.view !== "instance") return;
    if (h.tab === "webhooks") return;
    if (h.tab === "usage") return; // C10: the Usage tab owns its own /usage fetch (like webhooks)
    loadInstance(h.id, h.tab);
  }

  // Registered so the vocabulary stays closed; handled conservatively (same
  // as the unknown-type fallback): don't let a cached fleet outlive the event.
  // Per type, DELIBERATELY no view refetch:
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
        // A4: the welcome runway's trial subline reads the same cache — keep any
        // mounted runway honest when the subscription flips (no-op otherwise).
        refreshRunwaySubline(document);
      });
    },
    sites: function (v) {
      if (v === "sites") loadSites();
      else if (v === "instance") reloadInstanceView();
    },
    deployments: function (v) {
      if (v === "site") loadSite(parseHash().id);
      // W4: the sites LIST and the instance Overview both carry per-site deploy
      // badges — a terminal deploy tick must refresh them too, not only the open
      // detail (the amber-while-rebuilding groundwork).
      else if (v === "sites") loadSites();
      else if (v === "instance") reloadInstanceView();
    },
    // W4 (charter D15-D17): the per-stage deploy push drives the live rail.
    "site.deploy.stage": onDeployStageEvent,
    audit: function (v) {
      // An audited mutation (delete / go-live / site create / member / token /
      // subscription) just landed an event; refresh Activity if it's open, and
      // the instance Timeline tab (C8) — its feed is half audit entries.
      if (v === "activity") loadActivity();
      else if (v === "instance") refreshInstanceTimeline();
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
    members: onMembersEvent, // C10: refresh the Members panel when it's open
    notifications: invalidateConservatively,
    onboarding: invalidateConservatively,
  };

  function handleLiveEvent(type, payload) {
    if (!type) return;
    // dwb-6: during the /new deploy flow a "fleet" tick means the provision state
    // may have advanced — re-check the launched instance's real status.
    if (type === "fleet" && isNewFlow() && newFlowFleetHook) { newFlowFleetHook(); return; }
    var action = TYPE_ACTIONS[type];
    // W4: coarse handlers take (view) and ignore the payload; the stage handler
    // reads it. Passing it unconditionally is safe — the others drop it.
    if (action) { action(currentView(), payload); return; }
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
  // C3: "verify" is the post-provision golden-path gate (charter D45): the
  // provisioner probes the fresh box BETWEEN `content` and `ready`, so it sits
  // there in the display order too. The server does not emit it yet — the SPA
  // renders it forward-compat: it shows as an upcoming pending step until the
  // gate lands, and an UNKNOWN step name (any future addition) renders
  // generically (label = the raw name), never crashing.
  // dwb-17/D10: "freshen" is the go-live freshness FALLBACK — the provisioner
  // fetch+compares against origin/main at the top of the chain and rebuilds
  // when the box is behind, so a fresh instance never boots stale code. It
  // slots between `create` and `secure` (freshen must precede migrate). Warm
  // boxes are freshened BEFORE they enter the pool, so the worker narrates the
  // step only when it actually intervenes (a stale box rebuilding, or a
  // freshness check that degraded) — which is why it is OPTIONAL below: never
  // advertised as a planned/pending phase, appearing in place only when the
  // server reports it. Unknown future step names still render generically in
  // first-seen order — never a crash.
  var SERVER_STEP_ORDER = ["create", "freshen", "secure", "configure", "content", "verify", "ready"];
  // OPTIONAL (conditional) steps: hidden from the checklist/timeline until the
  // server reports a first entry for them (a planned step renders pending from
  // the start, so listing a step the worker may never emit hangs it forever).
  //   * freshen — only narrated when it INTERVENES (stale-box rebuild / degrade);
  //     warm boxes are pre-freshened, so the common assign emits nothing.
  //   * content — the template bootstrap, "skipped when the job carries no
  //     template" (ProvisionJob). A template-less launch never emits it, so it
  //     must not sit as a stuck "Installing your content"; a templated launch
  //     reports it and it slots in between configure and verify.
  var SERVER_STEP_OPTIONAL = { freshen: true, content: true };
  var SERVER_STEP_LABELS = {
    create: "Creating your server",
    freshen: "Updating to the latest Barkpark",
    secure: "Securing your domain",
    configure: "Configuring Barkpark",
    content: "Installing your content",
    verify: "Testing login & Studio",
    ready: "Finishing up"
  };
  // Compact gerunds for the fleet-row chip ("configuring · 1m 42s").
  var SERVER_STEP_SHORT = {
    create: "creating", freshen: "updating", secure: "securing", configure: "configuring",
    content: "installing", verify: "verifying", ready: "finishing"
  };

  // Rough expected duration per phase (ms) — UX pacing, not a promise. Tuned to
  // the warm-pool go-live: create is a pool pop + identity stamp; secure waits
  // on DNS + the ACME certificate (the long pole); configure runs migrate;
  // freshen only ever shows on the fallback rebuild path, where a clean Elixir
  // rebuild is minutes. The active step's dot renders these as a progress ring
  // via stepRingProgress — asymptotic, so a slower-than-estimate phase keeps
  // visibly crawling and the ring NEVER reads complete before the server
  // reports done. Pending rows surface the same numbers as a "~30s" hint, so
  // the user knows the plan's shape up front.
  var SERVER_STEP_EXPECTED_MS = {
    // Provision (instance) steps.
    create: 15000, freshen: 300000, secure: 45000, configure: 35000,
    content: 20000, verify: 15000, ready: 10000,
    // Deploy (site) stages — the shared ring/ETA now fills on the deploy rail
    // too (stw5 backlog). Estimates from live guerrilla deploys: BUILD is the
    // long pole (npm ci + next build / astro build), the rest are seconds. The
    // ring's overdue-crawl (stepRingProgress) keeps a slow build reading
    // "still working", never "stuck", so a conservative estimate is safe.
    PLAN: 3000, BUILD: 120000, STAGE: 8000,
    HEALTH: 18000, SWITCH: 3000, RETIRE: 4000
  };

  // 0..1 ring fill for an active step: linear to 90% across the estimate, then
  // an exponential crawl toward (never onto) 98% — overdue reads "still
  // working", never "done but stuck". null/garbled elapsed → 0, never NaN.
  function stepRingProgress(elapsedMs, expectedMs) {
    if (elapsedMs == null || isNaN(elapsedMs) || elapsedMs < 0 || !expectedMs) return 0;
    var r = elapsedMs / expectedMs;
    if (r <= 1) return 0.9 * r;
    return 0.9 + 0.08 * (1 - Math.exp(1 - r));
  }

  // ── Overall progress (the headline bar) ─────────────────────────────────────
  // The provisioning-ui upgrade: one master bar + "Step N of M · about 40s left"
  // above the per-phase rows, so the user reads the whole run at a glance (the
  // "how much longer" the whole flow was missing). Pure over the PACED display
  // rows so the bar and the checklist never disagree. Each VISIBLE step is
  // weighted by its duration estimate; its contribution is its role fraction
  // (done=1, active=ring, completing≈1 mid-dwell, pending=0). The remaining
  // weight doubles as a rough time-left proxy — honest for the common warm path
  // and, when the freshen rebuild row is showing, correctly says "about 5m left".
  function provisionOverall(rows) {
    rows = rows || [];
    var failed = false, allDone = rows.length > 0, activeIdx = -1;
    var totalW = 0, doneW = 0, etaMs = 0;
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      var w = SERVER_STEP_EXPECTED_MS[r.step] || 15000;
      var frac;
      if (r.role === "failed") { failed = true; frac = 0; }
      else if (r.role === "ok") frac = 1;
      else if (r.completing) { frac = 0.97; if (activeIdx < 0) activeIdx = i; }
      else if (r.role === "active") { frac = stepRingProgress(r.elapsedMs, w); if (activeIdx < 0) activeIdx = i; }
      else frac = 0; // pending
      if (r.role !== "ok") allDone = false;
      totalW += w;
      doneW += w * frac;
      etaMs += w * (1 - frac);
    }
    var pct = totalW ? (doneW / totalW) * 100 : 0;
    return {
      pct: allDone ? 100 : Math.min(Math.round(pct), 99), // never 100 until truly done
      index: activeIdx >= 0 ? activeIdx + 1 : (allDone ? rows.length : Math.min(1, rows.length)),
      count: rows.length,
      etaMs: allDone ? 0 : etaMs,
      done: allDone,
      failed: failed
    };
  }

  function overallSummaryText(o) {
    if (o.failed) return "Setup failed";
    if (o.done) return "All set";
    if (!o.count) return "Starting…";
    return "Step " + o.index + " of " + o.count;
  }
  function overallEtaText(o) {
    if (o.failed) return "";
    if (o.done) return "Ready";
    return (o.etaMs != null && o.etaMs >= 1000) ? "about " + fmtDur(o.etaMs) + " left" : "almost there";
  }

  // The master-bar markup (shared by /new + the instance timeline). data-overall*
  // hooks let the 1s tick patch width/summary/eta in place — no rebuild.
  function provisionOverallHtml(rows) {
    var o = provisionOverall(rows);
    var state = o.failed ? " is-failed" : o.done ? " is-done" : "";
    return '<div class="prov-overall' + state + '" data-overall>' +
      '<div class="prov-overall-track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + o.pct + '">' +
        '<div class="prov-overall-fill" data-overall-fill style="width:' + o.pct + '%"></div>' +
      "</div>" +
      '<div class="prov-overall-meta">' +
        '<span data-overall-summary>' + esc(overallSummaryText(o)) + "</span>" +
        '<span class="prov-overall-eta" data-overall-eta>' + esc(overallEtaText(o)) + "</span>" +
      "</div>" +
    "</div>";
  }

  // Patch the master bar in place from the current display rows (called each 1s
  // tick + on every SSE step change). Null-safe; no-op when the bar isn't mounted.
  function patchProvisionOverall(scope, rows) {
    if (!scope || !scope.querySelector) return;
    var el = scope.querySelector("[data-overall]");
    if (!el) return;
    var o = provisionOverall(rows);
    var fill = el.querySelector("[data-overall-fill]");
    if (fill) fill.style.width = o.pct + "%";
    var track = el.querySelector(".prov-overall-track");
    if (track) track.setAttribute("aria-valuenow", String(o.pct));
    var sum = el.querySelector("[data-overall-summary]");
    if (sum) sum.textContent = overallSummaryText(o);
    var eta = el.querySelector("[data-overall-eta]");
    if (eta) eta.textContent = overallEtaText(o);
    el.className = "prov-overall" + (o.failed ? " is-failed" : o.done ? " is-done" : "");
  }

  // ============================================ C3 PROVISION TIMELINE (one fold)
  // Decisions D47 + D51 + D13. The server serialises bp.provision_steps (an array
  // of {step, status, detail?, at}; status ∈ started|done|failed, a `progress`
  // report updates the in-flight started entry's detail in place) and
  // bp.provision_console ({line, at}) on EVERY fleet row. provisionSteps is the
  // ONE fold that all three mounts render from: the /new progress checklist
  // (newStepsHtml), the instance-detail timeline (timelineHtml), and the fleet
  // chip (provisionChipHtml). Pure + total: a malformed row never throws.

  // Coerce an ISO stamp OR an epoch-ms number to epoch ms; null (never NaN) for
  // anything missing/garbled — the "total over partial" rule for elapsed math.
  function toMs(v) {
    if (typeof v === "number") return isNaN(v) ? null : v;
    if (typeof v === "string") { var t = Date.parse(v); return isNaN(t) ? null : t; }
    return null;
  }

  // Elapsed ms between two stamps (start → end, where end may be `now`). If
  // EITHER is missing/garbled the whole span is null — never a partial or NaN.
  function stepElapsed(startAt, endAt) {
    var a = toMs(startAt), b = toMs(endAt);
    if (a == null || b == null) return null;
    return Math.max(0, b - a);
  }

  // Humanise a duration: null → "—"; <60s → "42s"; <60m → "1m 42s"; else "2h 1m"
  // (A4: hours for the long provisions the timeline occasionally sits through).
  // The <60m arms are byte-identical to the pre-A4 output.
  function fmtDur(ms) {
    if (ms == null || isNaN(ms)) return "—";
    var s = Math.max(0, Math.floor(ms / 1000));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m " + (s % 60) + "s";
    return Math.floor(m / 60) + "h " + (m % 60) + "m";
  }

  // Fold one step's entries into a display row. role precedence failed > ok
  // (done) > active (started) > pending. caption is the in-flight started
  // entry's detail (persists onto a finished step, matching the /new dwb-19
  // trick); probes are the details of the step's `progress` entries (the verify
  // gate's probe checklist). elapsedMs is total-over-partial from the stamps.
  function buildProvisionRow(name, entries, now) {
    var role = "pending", caption = "", probes = [];
    var hasDone = false, hasFailed = false, hasActive = false;
    // The server appends the `started` entry first, so the first entry's stamp is
    // the step's start. If it is missing, elapsed is null (total-over-partial) —
    // we never guess a start from a later entry.
    var startedAt = entries.length ? entries[0].at : null;
    var terminalAt = null;
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i] || {};
      var status = e.status;
      var detail = (typeof e.detail === "string" && e.detail) ? e.detail : "";
      if (status === "failed") { hasFailed = true; terminalAt = e.at; }
      else if (status === "done") { hasDone = true; terminalAt = e.at; }
      else if (status === "started") { hasActive = true; if (detail) caption = detail; }
      else if (status === "progress") { if (detail) probes.push(detail); }
    }
    if (hasFailed) role = "failed";
    else if (hasDone) role = "ok";
    else if (hasActive) role = "active";
    else if (entries.length) role = "active"; // only progress lines → still in flight
    var elapsedMs =
      role === "pending" ? null
        : role === "active" ? stepElapsed(startedAt, now)
          : stepElapsed(startedAt, terminalAt);
    return {
      step: name,
      label: SERVER_STEP_LABELS[name] || name,
      role: role,
      elapsedMs: elapsedMs,
      caption: caption,
      probes: probes
    };
  }

  // Between two steps the worker reports nothing (e.g. the SSH boot wait right
  // after `create done`), so for a stretch every row is done-or-pending and the
  // screen reads STUCK. Mark the first pending row after at least one finished
  // step `next` (role stays "pending" — the chip and the elapsed math are
  // untouched) so the presentations can show honest motion: "the previous step
  // finished, this one is about to report".
  function markNextStep(rows) {
    var busy = rows.some(function (r) { return r.role === "active" || r.role === "failed"; });
    if (busy) return rows;
    var hasDone = false;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].role === "ok") hasDone = true;
      else if (rows[i].role === "pending" && hasDone) { rows[i].next = true; break; }
    }
    return rows;
  }

  // The canonical fold: rows in SERVER_STEP_ORDER (planned steps ALWAYS
  // present, pending if unstarted; OPTIONAL fallback steps only once reported),
  // then any UNKNOWN steps appended in first-seen order.
  function provisionSteps(bp, now) {
    var raw = (bp && bp.provision_steps) || [];
    now = (typeof now === "number") ? now : Date.now();
    var order = SERVER_STEP_ORDER.slice();
    var known = {};
    order.forEach(function (n) { known[n] = true; });
    var byStep = {};
    for (var i = 0; i < raw.length; i++) {
      var s = raw[i];
      if (!s || typeof s.step !== "string") continue;
      if (!byStep[s.step]) byStep[s.step] = [];
      byStep[s.step].push(s);
      if (!known[s.step]) { known[s.step] = true; order.push(s.step); }
    }
    return markNextStep(order
      .filter(function (name) { return !(SERVER_STEP_OPTIONAL[name] && !byStep[name]); })
      .map(function (name) { return buildProvisionRow(name, byStep[name] || [], now); }));
  }

  // Total elapsed since the FIRST valid step stamp (null if none) — the chip +
  // the timeline header clock.
  function provisionTotalMs(bp, now) {
    var raw = (bp && bp.provision_steps) || [];
    now = (typeof now === "number") ? now : Date.now();
    for (var i = 0; i < raw.length; i++) {
      var t = toMs(raw[i] && raw[i].at);
      if (t != null) return Math.max(0, now - t);
    }
    return null;
  }

  // The current-step + total-elapsed summary for the fleet-row chip.
  function provisionChip(bp, now) {
    now = (typeof now === "number") ? now : Date.now();
    var rows = provisionSteps(bp, now);
    var active = null, failed = null;
    for (var i = 0; i < rows.length; i++) {
      if (!active && rows[i].role === "active") active = rows[i];
      if (!failed && rows[i].role === "failed") failed = rows[i];
    }
    var cur = active || failed;
    return {
      label: cur ? (SERVER_STEP_SHORT[cur.step] || cur.label) : "provisioning",
      elapsedMs: provisionTotalMs(bp, now),
      failed: !!failed && !active
    };
  }

  // Fleet-row provisioning cell: "configuring · 1m 42s" (updates on each SSE
  // fleet refetch). Styled with the existing .fleet-url.provisioning tokens.
  function provisionChipHtml(bp, now) {
    var c = provisionChip(bp, now);
    var t = c.elapsedMs != null ? " · " + fmtDur(c.elapsedMs) : "";
    return '<div class="fleet-url provisioning">' + esc(c.label) + t + "</div>";
  }

  // ── THE shared step-rows component (byte-locked in tests) ──────────────────
  // ONE presentation for BOTH provisioning surfaces — the /new progress screen
  // AND the cloud-admin instance timeline render these rows (the class family
  // keeps its historical `new-step` name). The active row's dot doubles as the
  // per-phase loading bar: a conic-gradient ring filled by --p (stepRingProgress
  // over the phase's expected duration), ticked IN PLACE each second via
  // data-ring — never a rebuild. The time column narrates pace: pending "~30s"
  // (the plan), active "12s · ~30s" (live, ticked via data-time), done/failed
  // the real elapsed. A `next` row (see markNextStep) keeps the pending dot but
  // pulses + spins so the between-steps window never reads frozen. The verify
  // gate's probe lines render as a checklist under their step.
  function newStepsHtml(rows) {
    return '<ul class="new-steps">' + rows.map(function (row) {
      var cls = row.role === "ok" ? "done" : row.role === "failed" ? "failed" : row.role === "active" ? "active" : "pending";
      if (row.next) cls += " next";
      // A `completing` row is truth-done but mid-dwell: the tick sweeps its ring
      // to full instead of tracking elapsed (see newTickProgressClock).
      if (row.completing) cls += " completing";
      var dot = row.role === "ok" ? "&#10003;" : row.role === "failed" ? "&#10007;" : "";
      var expected = SERVER_STEP_EXPECTED_MS[row.step];
      var dotAttrs = ' aria-hidden="true"';
      if (row.role === "active") {
        var pct = Math.round(stepRingProgress(row.elapsedMs, expected) * 100);
        if (row.completing) pct = Math.max(pct, 34); // sweep starts visibly, never from empty
        dotAttrs = ' aria-hidden="true" data-ring="' + esc(row.step) + '" style="--p:' + pct + '%"';
      }
      var cap = row.caption || (row.next ? "Starting…" : "");
      var capHtml = cap
        ? '<span class="new-step-detail" data-cap="' + esc(cap) + '">' + esc(cap) + "</span>"
        : "";
      var probesHtml = (row.probes && row.probes.length)
        ? '<ul class="new-step-probes">' + row.probes.map(function (p) {
            return '<li class="new-step-probe">' + esc(p) + "</li>";
          }).join("") + "</ul>"
        : "";
      var time = "";
      if (row.role === "active") time = fmtDur(row.elapsedMs) + (expected ? " · ~" + fmtDur(expected) : "");
      else if (row.role === "pending") time = expected ? "~" + fmtDur(expected) : "";
      else if (row.elapsedMs != null) time = fmtDur(row.elapsedMs);
      var timeHtml = time
        ? '<span class="new-step-time"' + (row.role === "active" ? ' data-time="' + esc(row.step) + '"' : "") + ">" + esc(time) + "</span>"
        : "";
      return '<li class="new-step ' + cls + '" data-step="' + esc(row.step) + '">' +
        '<span class="new-step-dot"' + dotAttrs + ">" + dot + "</span>" +
        '<span class="new-step-body">' +
          '<span class="new-step-label">' + esc(row.label) + "</span>" +
          capHtml +
          probesHtml +
        "</span>" +
        timeHtml +
        (row.role === "active" || row.next ? '<span class="new-step-spin" aria-hidden="true"></span>' : "") +
        "</li>";
    }).join("") + "</ul>";
  }

  // ── Mount 2 presentation: the .bp-timeline component (instance detail) ──────
  // Pure string-builder over rows. opts: { failed, failureDetail }.
  function timelineHtml(rows, opts) {
    opts = opts || {};
    // ONE component (unified-provision-view): the instance timeline renders the
    // exact same rows as /new — ring, pace column, captions, probes, next pulse
    // — via the shared newStepsHtml builder. Only the failure block is timeline-
    // specific (the /new flow has its own failed screen).
    var fail = opts.failed
      ? '<div class="bp-tl-fail" role="alert"><b>Setup failed.</b> ' +
        esc(opts.failureDetail || "Provisioning didn't finish.") + "</div>"
      : "";
    return newStepsHtml(rows || []) + fail;
  }

  // Console body lines (shared with the timeline shell). Empty → a calm caption.
  function consoleTail(lines) {
    var arr = lines || [];
    if (!arr.length) return '<div class="bp-console-line bp-console-empty">No console output yet.</div>';
    return arr.map(function (e) {
      e = e || {};
      var ts = newFmtConsoleTime(e.at);
      return '<div class="bp-console-line">' +
        (ts ? '<span class="bp-console-ts">' + esc(ts) + "</span>" : "") +
        '<span class="bp-console-text">' + esc(e.line) + "</span></div>";
    }).join("");
  }

  // The collapsible dark console shell (uses the --console-* tokens).
  function timelineConsoleHtml(lines, collapsed) {
    return '<div class="bp-console' + (collapsed ? " is-collapsed" : "") + '">' +
      '<button type="button" class="bp-console-toggle" data-tl-console-toggle aria-expanded="' + (collapsed ? "false" : "true") + '">' +
        '<span class="bp-console-caret" aria-hidden="true"></span>Console' +
      "</button>" +
      '<div class="bp-console-body"' + (collapsed ? " hidden" : "") + ">" + consoleTail(lines) + "</div>" +
    "</div>";
  }

  // The provisioning classifiers, mirroring fleetRow/instanceDetailHtml so the
  // timeline shows for exactly the provisioning + provision-failed states.
  function isProvisionFailed(bp) {
    bp = bp || {};
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    return !removing && bp.deprovision_status !== "failed" && !bp.host && bp.provision_status === "failed";
  }
  function isProvisioning(bp) {
    bp = bp || {};
    var removing = bp.deprovision_status === "pending" || bp.deprovision_status === "claimed";
    return !removing && bp.deprovision_status !== "failed" && !bp.host && bp.provision_status !== "failed";
  }

  // ── Instance-side pacing + patch state (unified-provision-view) ─────────────
  // The same min-dwell presentation pacing the /new screen runs, per viewed
  // instance (keyed by bp.id). Seeded on FIRST sight — opening a mid-provision
  // instance renders its finished history done instantly; only transitions
  // observed live get the ≥3s dwell. In-memory: a refresh reseeds. stepsSig /
  // consoleSig are the region-patch caches (see patchInstanceTimeline).
  var instanceTlState = {};

  function instanceTlStateFor(id) {
    id = String(id || "");
    if (!instanceTlState[id]) {
      instanceTlState[id] = { ledger: {}, seeded: false, stepsSig: null, consoleSig: null };
    }
    return instanceTlState[id];
  }

  // The instance timeline's DISPLAY rows: truth fold → min-dwell pacer.
  function instanceDisplayRows(bp) {
    var st = instanceTlStateFor(bp && bp.id);
    var rows = provisionSteps(bp, Date.now());
    if (!st.seeded) {
      st.seeded = true;
      seedPaceLedger(rows, st.ledger);
    }
    return paceSteps(rows, st.ledger, Date.now());
  }

  function instanceStepsSig(bp) {
    return instanceDisplayRows(bp).map(function (r) {
      return r.step + ":" + r.role + (r.completing ? "*" : "") + ":" + (r.caption || "") +
        (r.next ? "+n" : "") + ":" + ((r.probes && r.probes.length) || 0);
    }).join(",");
  }

  function instanceConsoleSig(bp) {
    var lines = (bp && bp.provision_console) || [];
    return lines.length + "|" + (lines.length ? (lines[lines.length - 1].at || "x") : "none");
  }

  // The full instance-detail timeline section: header clock + steps + (failed)
  // verbatim detail & Retry + expandable console. Pure; the ticker + wiring add
  // liveness on top. opts.consoleCollapsed persists the user's toggle.
  // data-tl-bp + data-tl-lc stamp WHAT is mounted so loadInstance's SSE fast
  // path can prove "same instance, same phase" and patch instead of remounting.
  function instanceTimelineHtml(bp, now, opts) {
    opts = opts || {};
    now = (typeof now === "number") ? now : Date.now();
    var failed = isProvisionFailed(bp);
    var rows = instanceDisplayRows(bp);
    var total = provisionTotalMs(bp, now);
    var head = '<div class="bp-tl-head">' +
        '<h2 class="bp-tl-title">' + (failed ? "Setup failed" : "Provisioning") + "</h2>" +
        '<span class="bp-tl-total" data-tl-total>' + (total != null ? fmtDur(total) : "") + "</span>" +
      "</div>";
    var retry = failed
      ? '<button class="btn btn-primary btn-sm bp-tl-retry" type="button" data-tl-retry>Retry setup</button>'
      : "";
    return '<section class="bp-timeline" data-tl data-tl-bp="' + esc((bp && bp.id) || "") +
        '" data-tl-lc="' + (failed ? "failed" : "provisioning") + '">' +
        head +
        provisionOverallHtml(rows) +
        timelineHtml(rows, { failed: failed, failureDetail: bp && bp.provision_error }) +
        retry +
        timelineConsoleHtml((bp && bp.provision_console) || [], !!opts.consoleCollapsed) +
      "</section>";
  }

  // ── Mount 2 liveness: per-step elapsed ticks WITHOUT a remount ──────────────
  var instanceTicker = null;      // setInterval handle for the elapsed clock
  var instanceTickerBp = null;    // the bp the ticker recomputes elapsed against
  var instanceConsoleCollapsed = false; // persists the console toggle across SSE re-renders
  // The console tail is the live truth, and EVERY step/console line broadcast
  // fully remounts #instance-body (fleet SSE → loadInstance). So the scroll
  // state must live OUTSIDE the DOM: pinned to the bottom by default, released
  // when the user scrolls up (same 24px stick rule as the /new console), and
  // re-applied after each remount. Reset when the viewed instance changes.
  var instanceConsoleStick = true;
  var instanceConsoleScrollTop = 0;
  var instanceConsoleFor = null; // bp.id the stick/scroll state belongs to

  function stopInstanceTicker() {
    if (instanceTicker) { clearInterval(instanceTicker); instanceTicker = null; }
    instanceTickerBp = null;
  }

  // The shared per-second ring/time patch for whichever scope holds the active
  // row (the /new screen's body or the instance timeline section). A
  // `completing` (dwelling) row sweeps its ring to full (+34/tick, smoothed by
  // the 0.9s --p transition); a genuinely active row tracks truth elapsed
  // against its estimate. Zero DOM rebuilds.
  function tickActiveRing(scope, truthRows) {
    if (!scope || !scope.querySelector) return;
    var dot = scope.querySelector(".new-step-dot[data-ring]");
    if (!dot) return;
    var li = dot.parentNode;
    if (li && li.className && li.className.indexOf("completing") !== -1) {
      var cur = parseInt(dot.style.getPropertyValue("--p"), 10) || 0;
      dot.style.setProperty("--p", Math.min(100, cur + 34) + "%");
      return;
    }
    var step = dot.getAttribute("data-ring");
    for (var i = 0; i < truthRows.length; i++) {
      if (truthRows[i].step !== step || truthRows[i].role !== "active") continue;
      var expected = SERVER_STEP_EXPECTED_MS[step];
      dot.style.setProperty("--p", Math.round(stepRingProgress(truthRows[i].elapsedMs, expected) * 100) + "%");
      var tEl = scope.querySelector('.new-step-time[data-time="' + step + '"]');
      if (tEl) tEl.textContent = fmtDur(truthRows[i].elapsedMs) + (expected ? " · ~" + fmtDur(expected) : "");
      return;
    }
  }

  // The instance timeline's 1s liveness tick: total clock + the active row's
  // ring/time in place, and — because a dwell EXPIRING is a display change the
  // server never signals — a steps-list rebuild when the paced sig moves.
  // Self-stops if the timeline left the DOM.
  function tickInstanceTimeline() {
    var bp = instanceTickerBp;
    if (!bp) return;
    var section = document.querySelector("[data-tl]");
    if (!section) { stopInstanceTicker(); return; }
    var st = instanceTlStateFor(bp.id);
    var sig = instanceStepsSig(bp);
    if (sig !== st.stepsSig) {
      st.stepsSig = sig;
      var ul = section.querySelector(".new-steps");
      if (ul) ul.outerHTML = newStepsHtml(instanceDisplayRows(bp));
    }
    var total = section.querySelector("[data-tl-total]");
    if (total) { var t = provisionTotalMs(bp, Date.now()); total.textContent = t != null ? fmtDur(t) : ""; }
    tickActiveRing(section, provisionSteps(bp, Date.now()));
    patchProvisionOverall(section, instanceDisplayRows(bp));
  }

  // The SSE fast path (unified-provision-view): a fresh fleet row for the SAME
  // mounted instance in the SAME phase patches the three live regions in place
  // — steps (on paced-sig change), console body (scroll + toggle survive), the
  // total clock — instead of remounting #instance-body, which restarted every
  // animation and flashed "Loading…" on each provisioning step/console line.
  function patchInstanceTimeline(section, bp) {
    var st = instanceTlStateFor(bp.id);
    instanceTickerBp = bp; // the ticker's elapsed math follows the freshest row
    var sig = instanceStepsSig(bp);
    if (sig !== st.stepsSig) {
      st.stepsSig = sig;
      var ul = section.querySelector(".new-steps");
      if (ul) ul.outerHTML = newStepsHtml(instanceDisplayRows(bp));
    }
    var csig = instanceConsoleSig(bp);
    if (csig !== st.consoleSig) {
      st.consoleSig = csig;
      var body = section.querySelector(".bp-console-body");
      if (body) {
        body.innerHTML = consoleTail((bp && bp.provision_console) || []);
        if (instanceConsoleStick && !instanceConsoleCollapsed) body.scrollTop = body.scrollHeight;
      }
    }
    var total = section.querySelector("[data-tl-total]");
    if (total) { var t = provisionTotalMs(bp, Date.now()); total.textContent = t != null ? fmtDur(t) : ""; }
    tickActiveRing(section, provisionSteps(bp, Date.now()));
    patchProvisionOverall(section, instanceDisplayRows(bp));
  }

  function startInstanceTicker(bp) {
    stopInstanceTicker();
    if (!isProvisioning(bp)) return; // a failed/live box has no advancing clock
    instanceTickerBp = bp;
    instanceTicker = setInterval(tickInstanceTimeline, 1000);
  }

  // Wire the timeline's console toggle + Retry within a mounted container. Fully
  // null-safe: it never clears the container (the fake-DOM smoke asserts this).
  function wireInstanceTimeline(root, bp) {
    var section = root && root.querySelector ? root.querySelector("[data-tl]") : null;
    if (!section) return;
    // A full render just painted current state — prime the region-patch caches
    // so the next SSE fast path / tick only touches what actually changes.
    if (bp && bp.id != null) {
      var st = instanceTlStateFor(bp.id);
      st.stepsSig = instanceStepsSig(bp);
      st.consoleSig = instanceConsoleSig(bp);
    }
    var toggle = section.querySelector("[data-tl-console-toggle]");
    if (toggle) toggle.addEventListener("click", function () {
      instanceConsoleCollapsed = !instanceConsoleCollapsed;
      var panel = toggle.parentNode;
      var body = panel && panel.querySelector ? panel.querySelector(".bp-console-body") : null;
      if (body) {
        if (instanceConsoleCollapsed) hide(body);
        else { show(body); if (instanceConsoleStick) body.scrollTop = body.scrollHeight; }
      }
      if (panel && panel.classList) panel.classList.toggle("is-collapsed", instanceConsoleCollapsed);
      toggle.setAttribute("aria-expanded", instanceConsoleCollapsed ? "false" : "true");
    });
    var retry = section.querySelector("[data-tl-retry]");
    if (retry) retry.addEventListener("click", function () { retryInstance(bp, retry); });
    // Console scroll: fresh instance → pin to bottom; then track the user's
    // stick state so the next SSE-driven remount restores their position.
    var cbody = section.querySelector(".bp-console-body");
    if (cbody) {
      var id = bp && bp.id;
      if (instanceConsoleFor !== id) {
        instanceConsoleFor = id;
        instanceConsoleStick = true;
        instanceConsoleScrollTop = 0;
      }
      cbody.addEventListener("scroll", function () {
        instanceConsoleStick = (cbody.scrollHeight - cbody.scrollTop - cbody.clientHeight) < 24;
        instanceConsoleScrollTop = cbody.scrollTop;
      });
      if (!instanceConsoleCollapsed) {
        if (instanceConsoleStick) cbody.scrollTop = cbody.scrollHeight;
        else cbody.scrollTop = instanceConsoleScrollTop;
      }
    }
  }

  // Render + wire + start the ticker for the timeline into a container. Used by
  // loadInstance and by the committed fake-DOM wiring smoke.
  function mountInstanceTimeline(root, bp, now) {
    if (!root) return;
    root.innerHTML = instanceTimelineHtml(bp, now, { consoleCollapsed: instanceConsoleCollapsed });
    wireInstanceTimeline(root, bp);
    startInstanceTicker(bp);
  }

  var newState = null; // {slug, template, id, startedAt, timer, poll, step, bp, serverSteps}
  var newTemplatesCache = null;
  var newAuthMode = "login";
  var newFlowFleetHook = null; // handleLiveEvent() calls this on an SSE "fleet" tick

  // Tolerant pathname match for the real-path screens (/new, /activate). The
  // control plane's Plug.Router serves /activate/ (and //) as the same 200 it
  // serves /activate, so an EXACT pathname === "/activate" check silently misses
  // the trailing-slash spellings — the approve page never renders and the
  // hash-router escape guards bounce the user to the dashboard. Strip trailing
  // slashes, but keep "/" itself as "/" (never collapse the root to "").
  function pathClean(pathname) {
    var p = String(pathname == null ? "" : pathname).replace(/\/+$/, "");
    return p === "" ? "/" : p;
  }
  function isNewFlow() { return pathClean(location.pathname) === "/new"; }
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
      var kind = loginResponseKind(r);
      if (kind === "session") {
        setSession({ token: r.data.token, team_id: r.data.team_id || null }, true);
        renderNewFlow(); // stay on /new — now authed, proceed to Launch
      } else if (kind === "two_factor") {
        // TOTP-enrolled account: render the SAME shared card in place and finish
        // right here — no punt to "/", no round-trip through localStorage.
        showNewTwoFactorCard(r.data.challenge_token);
      } else {
        setText(err, friendly(r.data, "Couldn't sign you in.")); show(err);
      }
    });
  }

  // /new site: mount the shared challenge card into the flow's panel body. On
  // success the session lands (remember=true, like the /new token branch) and
  // renderNewFlow proceeds to Launch; Back returns to the sign-in step.
  function showNewTwoFactorCard(challengeToken) {
    newSetBody(newPanel('<div id="new-twofa"></div>'));
    var root = $("#new-twofa");
    if (!root) { location.href = "/"; return; } // defensive fallback
    mountTwoFactorCard(root, {
      challengeToken: challengeToken,
      onDone: function (sess) {
        setSession({ token: sess.token, team_id: sess.team_id || null }, true);
        renderNewFlow();
      },
      onBack: function () { renderNewFlow(); }
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
    // the SSE-error flag drive the "connection lost" banner. The region sigs
    // (steps/console/banner) let every later render patch ONLY what changed —
    // a clock tick never touches the DOM structure (see newRenderProgress).
    newState.serverConsole = newState.serverConsole || [];
    newState.consoleStick = true;
    newState.consoleCollapsed = false;
    newState.provisionStatus = null;
    newState.lastPollOkAt = Date.now();
    newState.stepsSig = null;
    newState.consoleSig = null;
    newState.bannerSig = null;
    // Presentation pacing (min-dwell) state: the shown-active ledger, the
    // seeded-from-history flag, and the held ready handover.
    newState.paceLedger = {};
    newState.paceSeeded = false;
    newState.readyBp = null;
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

  // The console BODY lines alone — split out so a new line patches just the
  // body element in place (scroll + toggle listeners survive) instead of
  // rebuilding the whole panel.
  function newConsoleBodyHtml() {
    var lines = newDisplayConsole();
    return lines.length
      ? lines.map(function (e) {
          var ts = newFmtConsoleTime(e.at);
          return '<div class="new-console-line">' +
            (ts ? '<span class="new-console-ts">' + esc(ts) + "</span>" : "") +
            '<span class="new-console-text">' + esc(e.line) + "</span></div>";
        }).join("")
      : '<div class="new-console-line dim">Waiting for the first log line…</div>';
  }

  // The dark, monospace, auto-scrolling console panel — VISIBLE BY DEFAULT during
  // provisioning (that's the point), collapsible. Timestamps per line.
  function newConsoleHtml() {
    var body = newConsoleBodyHtml();
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

  // ── Presentation pacing: a minimum dwell per step ───────────────────────────
  // The fast tail steps (content ~0.6s, verify ~0.5s, ready ~0.1s) complete
  // near-instantly server-side, and a checklist that machine-guns three
  // checkmarks after a long phase reads as fake. paceSteps is a DISPLAY-ONLY
  // shim over the truth fold: a step that just finished keeps rendering as
  // active (`completing` — ring sweeping to full) until it has been on screen
  // at least NEW_STEP_MIN_DWELL_MS, and the steps behind it queue as pending
  // and play one at a time. The server narration, the chip, the instance
  // timeline and the failed screen all stay on unpaced truth; ONLY the /new
  // checklist paces. Honesty guards: a FAILED run snaps straight to truth
  // (pacing never delays bad news), and a refresh/resume pre-seeds the ledger
  // (seedPaceLedger) so already-finished history renders done immediately
  // instead of replaying as theatre.
  var NEW_STEP_MIN_DWELL_MS = 3000;

  function paceCopy(row) {
    return {
      step: row.step, label: row.label, role: row.role, elapsedMs: row.elapsedMs,
      caption: row.caption, probes: row.probes, next: row.next, completing: false
    };
  }

  // ledger maps step name → the epoch-ms the display FIRST showed it active
  // (stamped here, on first sight). Mutated in place; the caller owns it.
  function paceSteps(rows, ledger, now) {
    // Failure snaps to truth — every row, immediately, no dwell anywhere.
    if (rows.some(function (r) { return r.role === "failed"; })) {
      return rows.map(paceCopy);
    }
    var out = [], holding = false;
    for (var i = 0; i < rows.length; i++) {
      var r = paceCopy(rows[i]);
      if (holding) {
        // Someone earlier is still on stage — everything later waits its turn.
        if (r.role === "ok" || r.role === "active") {
          r.role = "pending";
          r.caption = "";
          r.elapsedMs = null;
        }
        r.next = false;
      } else if (r.role === "active") {
        if (!ledger[r.step]) ledger[r.step] = now;
        holding = true;
      } else if (r.role === "ok") {
        if (!ledger[r.step]) ledger[r.step] = now;
        if (now - ledger[r.step] < NEW_STEP_MIN_DWELL_MS) {
          r.role = "active";
          r.completing = true; // ring sweeps to full, check lands at dwell end
          holding = true;
        }
      }
      out.push(r);
    }
    // While a paced row is on stage, the between-steps `next` pulse is noise.
    if (holding) out.forEach(function (r) { r.next = false; });
    return out;
  }

  // On resume (refresh mid-provision), everything already finished is history,
  // not news — stamp it as shown-long-ago so it renders done instantly.
  function seedPaceLedger(rows, ledger) {
    rows.forEach(function (r) {
      if (r.role === "ok" || r.role === "failed") ledger[r.step] = ledger[r.step] || -1e15;
    });
  }

  // The /new checklist's display rows: the truth fold run through the pacer.
  // null while the placeholder ("Starting…") is still up.
  function newDisplayRows() {
    var serverSteps = newState.serverSteps || [];
    if (!serverSteps.length) return null;
    newState.paceLedger = newState.paceLedger || {};
    return paceSteps(
      provisionSteps({ provision_steps: serverSteps }, Date.now()),
      newState.paceLedger,
      Date.now()
    );
  }

  // Drained ⇔ no row is mid-dwell — the gate for handing over to the ready
  // screen (newRenderReady must not yank the panel away mid-checkmark).
  function newPacingSettled() {
    var rows = newDisplayRows();
    if (!rows) return true;
    return !rows.some(function (r) { return r.completing; });
  }

  // ── Region signatures: the progress screen patches three regions
  // INDEPENDENTLY, so a change in one never rebuilds (and never restarts the
  // CSS animations of) another. This is the fix for "the animations keep
  // resetting": previously every 4s poll force-rebuilt the whole panel, and any
  // new console line re-mounted the steps list — restarting the active-step
  // spinner and replaying every caption fade. Now:
  //   * steps sig   → the checklist <ul> is replaced only when a step's
  //     DISPLAY state really changed (paced role/caption — a dwell expiring IS
  //     a display change; that re-mount re-plays the dwb-19 caption fade,
  //     deliberately);
  //   * console sig → only the console BODY's innerHTML is patched (the panel
  //     shell, its toggle listener and the scroll state survive);
  //   * banner sig  → the connection-lost banner is inserted/removed alone.
  // The elapsed clock + the active step's ring/time tick in place every second
  // via newTickProgressClock — zero DOM rebuilds on a pure clock tick.
  function newStepsSig() {
    var rows = newDisplayRows();
    if (!rows) return "placeholder";
    return rows.map(function (r) {
      return r.step + ":" + r.role + (r.completing ? "*" : "") + ":" + (r.caption || "") + (r.next ? "+n" : "");
    }).join(",");
  }
  function newConsoleSig() {
    var dc = newDisplayConsole();
    var lastAt = dc.length ? (dc[dc.length - 1].at || "client") : "none";
    return dc.length + "|" + lastAt;
  }

  // The 1s liveness tick, all patched in place: the header elapsed clock, the
  // active step's ring fill (--p) and its live "12s · ~30s" time. Also advances
  // the `next`-row decoration when the active step changes purely by TIME
  // passing is impossible — that's server-driven — so no step DOM is touched.
  function newTickProgressClock() {
    var serverSteps = newState.serverSteps || [];
    var scope = document.querySelector("#new-body");
    var el = scope && scope.querySelector(".new-elapsed");
    if (el) el.textContent = newElapsedSeconds(serverSteps) + "s elapsed";
    // Ring + live time via the SHARED per-second patch (tickActiveRing — the
    // same helper the instance timeline ticks with), plus the master bar.
    var truthRows = provisionSteps({ provision_steps: serverSteps }, Date.now());
    tickActiveRing(scope, truthRows);
    patchProvisionOverall(scope, newDisplayRows() || []);
  }

  // The steps region's markup: the pre-first-event placeholder, else the PACED
  // display fold (truth via provisionSteps, dwell via paceSteps).
  function newProgressStepsHtml() {
    var rows = newDisplayRows();
    if (!rows) {
      // Pre-first-event placeholder: honest "Starting…" (client optimism, bounded
      // to the window before the worker reports its first transition), never a
      // bare spinner.
      return '<ul class="new-steps"><li class="new-step active">' +
        '<span class="new-step-dot" aria-hidden="true"></span>' +
        '<span class="new-step-label">Starting…</span>' +
        '<span class="new-step-spin" aria-hidden="true"></span>' +
        "</li></ul>";
    }
    return newStepsHtml(rows);
  }

  function newRenderProgress(force) {
    if (!newState || newState.step !== "progress") return;
    var stepsSig = newStepsSig();
    var consoleSig = newConsoleSig();
    var bannerSig = newConnLost() ? "lost" : "ok";
    var mounted = document.querySelector("#new-body .new-progress");

    if (!mounted || force) {
      // Full mount — the first render (or an explicit rebuild). Everything after
      // this patches in place.
      newState.stepsSig = stepsSig;
      newState.consoleSig = consoleSig;
      newState.bannerSig = bannerSig;
      // Preserve the user's console scroll across the rebuild when they've
      // scrolled up (not stuck to bottom).
      var prevBody = document.querySelector("#new-body .new-console-body");
      if (prevBody && newState.consoleStick === false) newState.consoleScrollTop = prevBody.scrollTop;
      var title = (newState.template && newState.template.title) || "your Barkpark";
      var mountRows = newDisplayRows();
      newSetBody(newPanel(
        '<div class="new-progress">' +
          newConnBannerHtml() +
          "<h2>Setting up " + esc(title) + "</h2>" +
          '<p class="dim">This usually takes under a minute. <span class="new-elapsed">' + newElapsedSeconds(newState.serverSteps || []) + "s elapsed</span></p>" +
          (mountRows ? provisionOverallHtml(mountRows) : "") +
          newProgressStepsHtml() +
          newConsoleHtml() +
        "</div>"));
      newWireConsole();
      newTickProgressClock();
      return;
    }

    if (stepsSig !== newState.stepsSig) {
      newState.stepsSig = stepsSig;
      var ul = mounted.querySelector(".new-steps");
      // The re-mount replays the dwb-19 caption fade for the changed list —
      // that's the intended "new information" cue.
      if (ul) ul.outerHTML = newProgressStepsHtml();
      // First real steps arrived after the "Starting…" placeholder → the master
      // bar wasn't mounted yet; insert it above the freshly-rendered steps.
      var rows = newDisplayRows();
      if (rows && !mounted.querySelector("[data-overall]")) {
        var stepsEl = mounted.querySelector(".new-steps");
        if (stepsEl) stepsEl.insertAdjacentHTML("beforebegin", provisionOverallHtml(rows));
      }
      patchProvisionOverall(mounted, rows || []);
    }
    if (consoleSig !== newState.consoleSig) {
      newState.consoleSig = consoleSig;
      var body = mounted.querySelector(".new-console-body");
      if (body) {
        body.innerHTML = newConsoleBodyHtml();
        if (newState.consoleStick !== false) body.scrollTop = body.scrollHeight;
      }
    }
    if (bannerSig !== newState.bannerSig) {
      newState.bannerSig = bannerSig;
      var banner = mounted.querySelector(".new-conn-lost");
      if (bannerSig === "lost" && !banner) mounted.insertAdjacentHTML("afterbegin", newConnBannerHtml());
      else if (bannerSig === "ok" && banner) banner.parentNode.removeChild(banner);
    }
    newTickProgressClock();
    // The box is live but the checklist was mid-dwell when the poll saw it —
    // hand over to the ready screen the moment the last check lands.
    if (newState.readyBp && newPacingSettled()) {
      var readyBp = newState.readyBp;
      newState.readyBp = null;
      newRenderReady(readyBp);
    }
  }

  function newCheckStatus(id) {
    api("GET", "/v1/barkparks", null, {}).then(function (r) {
      // dwb-16: a FAILED poll (network error / non-2xx) leaves lastPollOkAt stale
      // so the connection-lost banner can surface if SSE is ALSO down >10s. Never
      // a silent frozen spinner — render UNFORCED: the banner-sig patch shows/
      // hides it honestly, and an unchanged screen is left alone (a forced
      // rebuild here is what used to restart every animation on each poll).
      if (!(r.ok && r.data && r.data.barkparks)) { newRenderProgress(); return; }
      newState.lastPollOkAt = Date.now();
      var bp = r.data.barkparks.filter(function (x) { return String(x.id) === String(id); })[0];
      if (!bp) { newRenderProgress(); return; }
      // Stash the SERVER-reported steps + live console so the progress screen
      // renders real, refresh-durable state (not the old client-side timer).
      newState.serverSteps = bp.provision_steps || [];
      newState.serverConsole = bp.provision_console || [];
      newState.provisionStatus = bp.provision_status || null;
      // First server truth after (re)load: everything ALREADY finished is
      // history — seed the pace ledger so a resume renders it done instantly
      // instead of replaying each old step's dwell as theatre.
      if (!newState.paceSeeded) {
        newState.paceSeeded = true;
        newState.paceLedger = newState.paceLedger || {};
        seedPaceLedger(provisionSteps({ provision_steps: newState.serverSteps }, Date.now()), newState.paceLedger);
      }
      if (bp.host) {
        // Hold the ready screen until the paced checklist finishes its last
        // dwell — yanking the panel away mid-checkmark undoes the pacing.
        // newRenderProgress's tick hands over the moment pacing settles.
        if (newPacingSettled()) { newRenderReady(bp); }
        else { newState.readyBp = bp; newRenderProgress(); }
      }
      else if (bp.provision_status === "failed") { newRenderFailed(bp); }
      else { newRenderProgress(); } // still provisioning — patch whatever changed
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

  // The {key, value} pairs the Vercel form needs, in template order — only keys
  // the bootstrap resolved a value for. Powers the per-field "Copy value" rows.
  function vercelEnvRows(tpl, boot) {
    if (!boot || !boot.env) return [];
    var keys = (tpl && tpl.env_keys && tpl.env_keys.length) ? tpl.env_keys : Object.keys(boot.env);
    return keys.filter(function (k) { return boot.env[k] != null; })
      .map(function (k) { return { key: k, value: String(boot.env[k]) }; });
  }

  // ── Guided FALLBACK (no platform token) ────────────────────────────────────
  // Without a VERCEL_PLATFORM_TOKEN the one-click claim flow is off, so the user
  // deploys via vercel.com/new/clone — whose form has EMPTY value fields (Vercel
  // forbids values in the URL; ours are secret anyway). The old fallback put the
  // Deploy button ABOVE a copy-all block, so people clicked Deploy first, hit the
  // empty form, and got lost. This makes it a clear guided step: the values come
  // FIRST, one "Copy value" button per field (matching Vercel's field-by-field
  // form), and only THEN the Deploy button — framed so the empty fields are
  // expected. Values aren't shown inline (they carry the read token); the button
  // copies the real value. "Copy all as .env" serves Vercel's paste-.env box.
  function vercelFallbackHtml(tpl, boot, clone, dotenv) {
    var rows = vercelEnvRows(tpl, boot);
    var n = rows.length;
    var rowsHtml = rows.map(function (r) {
      return '<li class="new-env-row"><span class="mono new-env-key">' + esc(r.key) + "</span>" +
        '<button class="btn btn-ghost btn-sm" type="button" data-copy="' + esc(r.value) +
        '" aria-label="Copy the ' + esc(r.key) + ' value">Copy value</button></li>';
    }).join("");
    return '<div class="new-vercel-guide">' +
      '<div class="new-env-head"><span>Deploy to Vercel</span>' +
        (dotenv ? '<button class="btn btn-ghost btn-sm" type="button" data-copy="' + esc(dotenv) + '">Copy all as .env</button>' : "") +
      "</div>" +
      '<p class="new-fineprint dim">Vercel will ask for ' + n + " environment variable" + (n === 1 ? "" : "s") +
        ". Copy each value here and paste it into the matching field on Vercel — or “Copy all as .env” and paste the whole block. Treat them as secret.</p>" +
      (rowsHtml ? '<ol class="new-env-rows">' + rowsHtml + "</ol>" : "") +
      '<a class="btn btn-block btn-vercel" id="new-vercel" href="' + esc(clone) + '" target="_blank" rel="noopener">Deploy to Vercel</a>' +
    "</div>";
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

  // A4: the ONE ready-panel renderer, shared by the /new flow AND the in-shell
  // provision→live fold. Core = "<name> is ready" + Open Studio primary + a
  // secondary "View" affordance; opts.extra is appended inside .new-actions
  // (the /new github + Vercel buttons) and opts.tail after it (the /new env +
  // go-live blocks). studioBtnId / viewBtnId / viewHref parametrise wiring so a
  // single markup serves both mounts; opts.demoteHeading renders the title as h2
  // for the in-shell fold (the instance header owns that page's h1) while /new —
  // a standalone page — keeps the h1. Pure: no globals, safe in the vm harness.
  function readyHeroHtml(bp, opts) {
    opts = opts || {};
    bp = bp || {};
    var tag = opts.demoteHeading ? "h2" : "h1";
    var studioBtn = '<button class="btn btn-primary btn-block" id="' +
      esc(opts.studioBtnId || "ready-open-studio") + '" type="button">Open Studio</button>';
    var view = opts.viewBtnId
      ? '<button class="btn btn-ghost btn-block" id="' + esc(opts.viewBtnId) + '" type="button">' + esc(opts.viewLabel || "View details") + "</button>"
      : opts.viewHref
        ? '<a class="btn btn-ghost btn-block" href="' + esc(opts.viewHref) + '">' + esc(opts.viewLabel || "View details") + "</a>"
        : "";
    return '<div class="new-ready">' +
      '<span class="new-eyebrow ok">Live</span>' +
      "<" + tag + ' class="new-title">' + esc(bp.name) + " is ready</" + tag + ">" +
      '<p class="new-desc">Your managed Barkpark is up' + (bp.url ? ' at <span class="mono">' + esc(bp.url) + "</span>" : "") + ".</p>" +
      '<div class="new-actions">' +
        studioBtn +
        (opts.extra || "") +
        view +
      "</div>" +
      (opts.tail || "") +
    "</div>";
  }

  // ── Zero-paste Vercel handoff (task-4e4a53b101a97051) ──────────────────────
  // When the control plane has a platform token, the "Deploy to Vercel" button
  // POSTs /vercel-deploy: WE deploy the template with every env value already
  // installed server-side, then render the claim link
  // (vercel.com/claim-deployment?code=…) — the user claims the fully configured
  // project into their account. Zero pasting; secrets never ride a URL. When
  // the token is absent (vercel.configured false) the classic /new/clone +
  // copy-block flow renders instead and keeps working forever.

  // The claim link markup for an already-deployed instance with a FRESH code.
  // returnUrl brings the user back to this instance after the transfer.
  function vercelClaimLinkHtml(vercel, bp) {
    var ret = location.origin + "/#instance/" + ((bp && bp.id) || "");
    var href = vercel.claim_url + "&returnUrl=" + encodeURIComponent(ret);
    return '<a class="btn btn-block btn-vercel" id="new-vercel-claim-link" href="' + esc(href) + '" target="_blank" rel="noopener">Claim your deployment on Vercel</a>' +
      (vercel.deployment_url
        ? '<p class="new-fineprint dim">Live at <a class="mono" href="' + esc(vercel.deployment_url) + '" target="_blank" rel="noopener">' + esc(vercel.deployment_url) + "</a> — claim it to make it yours.</p>"
        : "");
  }

  // The whole one-click area: "" when the feature is off (caller falls back to
  // the clone-URL flow); a claim link when a fresh code exists; else the deploy
  // button (which also RE-MINTS a stale code — same POST).
  function vercelClaimHtml(vercel, bp) {
    if (!vercel || !vercel.configured) return "";
    var inner;
    if (vercel.claim_url) {
      inner = vercelClaimLinkHtml(vercel, bp);
    } else {
      var label = vercel.deployed ? "Get your Vercel claim link" : "Deploy your site to Vercel";
      inner = '<button class="btn btn-block btn-vercel" id="new-vercel-claim" type="button">' + esc(label) + "</button>" +
        '<p class="new-fineprint dim">One click — we deploy it with every environment variable already set; you just claim it into your Vercel account.</p>';
    }
    return '<div id="new-vercel-area">' + inner + "</div>";
  }

  function newReadyHtml(bp, boot, gh) {
    var tpl = newState.template;
    var clone = vercelCloneUrl(tpl, boot);
    var dotenv = envDotenv(tpl, boot);
    var oneClick = vercelClaimHtml((boot && boot.vercel) || null, bp);

    // extra sits in the hero's action row; tail below it. With the platform token
    // (oneClick) the deploy is a single button + the env block is a keep-these
    // reference. WITHOUT it, the guided fallback carries the Deploy button AFTER
    // the values, so people copy first and the empty Vercel form is expected.
    var extra, vercelBlock;
    if (oneClick) {
      extra = newGithubHtml(tpl, gh) + oneClick;
      vercelBlock = dotenv
        ? '<div class="new-env"><div class="new-env-head"><span>Environment variables</span>' +
            '<button class="btn btn-ghost btn-sm" type="button" data-copy="' + esc(dotenv) + '">Copy all</button></div>' +
            '<pre class="new-env-body">' + esc(dotenv) + "</pre>" +
            '<p class="new-fineprint dim">Your Vercel deployment already has these set — keep them for local development. Treat them as secret.</p></div>'
        : "";
    } else {
      extra = newGithubHtml(tpl, gh);
      vercelBlock = dotenv
        ? vercelFallbackHtml(tpl, boot, clone, dotenv)
        : '<a class="btn btn-block btn-vercel" id="new-vercel" href="' + esc(clone) + '" target="_blank" rel="noopener">Deploy your site to Vercel</a>';
    }

    var tail = vercelBlock +
      '<div class="new-golive"><label class="label" for="new-site-url">Once deployed, tell us your site URL</label>' +
        '<div class="new-golive-row"><input class="form-input" id="new-site-url" type="url" placeholder="https://your-site.vercel.app" />' +
        '<button class="btn btn-primary" id="new-site-url-btn" type="button">Wire revalidation</button></div>' +
        '<p class="new-fineprint dim">This activates instant content updates: edits in Studio refresh your live site.</p></div>';
    return readyHeroHtml(bp, {
      studioBtnId: "new-open-studio",
      viewHref: "/#instance/" + bp.id,
      viewLabel: "View instance",
      extra: extra,
      tail: tail,
    });
  }

  function newWireReady(bp, boot, gh) {
    var os = $("#new-open-studio");
    if (os) os.addEventListener("click", function () { openStudio(bp.id, os); });
    var sb = $("#new-site-url-btn");
    if (sb) sb.addEventListener("click", function () { newSubmitSiteUrl(bp.id, sb); });
    var gc = $("#new-gh-create");
    if (gc) gc.addEventListener("click", function () { newCreateRepo(bp, boot, gh, gc); });
    var vc = $("#new-vercel-claim");
    if (vc) vc.addEventListener("click", function () { newVercelDeploy(bp, vc); });
  }

  // The one-click deploy: POST /vercel-deploy (idempotent — an existing project
  // only re-mints the claim code), then swap the area for the claim link in
  // place. Errors re-arm the button with an honest toast.
  function newVercelDeploy(bp, btn) {
    btn.disabled = true;
    btn.textContent = "Deploying to Vercel…";
    api("POST", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/vercel-deploy", {}).then(function (r) {
      if (r.ok && r.data && r.data.vercel && r.data.vercel.claim_url) {
        var area = $("#new-vercel-area");
        if (area) area.innerHTML = vercelClaimLinkHtml(r.data.vercel, bp);
        toast({ kind: "success", title: "Deployed to Vercel", body: "Claim it to move it into your account." });
        return;
      }
      btn.disabled = false;
      btn.textContent = "Deploy your site to Vercel";
      if (r.status === 409) {
        toast({ kind: "error", title: "Nothing to deploy yet", body: "This instance has no content bootstrap." });
      } else if (r.status === 422) {
        toast({ kind: "error", title: "This template isn't deployable", body: "It has no standalone app to deploy." });
      } else {
        toast({ kind: "error", title: "Couldn't deploy to Vercel", body: friendly(r.data, "Please try again.") });
      }
    });
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

  // ══════════════════════════════════════════════════════════════════════════
  // ── C10: Members settings panel + Usage instance sub-tab ──────────────────
  // ONE app.js slice (charter D13). The Usage tab (the 4th instance sub-tab,
  // registered in INSTANCE_TABS above) consumes the C9 usage endpoint
  // GET /v1/barkparks/:id/usage (#1034) — the fixed meter vocabulary shaped by
  // BarkparkCloud.Usage.compose/1, plus seats.pending_invitations. The Members
  // panel is a Settings view (registered in SETTINGS_VIEWS above) over the six
  // team member/invitation routes under /v1/teams/:id/. It wires into the
  // existing TYPE_ACTIONS.members consumer (onMembersEvent). Append-only: this
  // region does NOT touch the rollback / liveness / coherence regions.
  // ══════════════════════════════════════════════════════════════════════════

  // ── Usage sub-tab ───────────────────────────────────────────────────────────
  // The fixed meter vocabulary + render order (mirrors Usage.compose/1). Each
  // spec names the meter key, its human label, and how to format a real number.
  var USAGE_METERS = [
    { key: "instances", label: "Instances", fmt: "count" },
    { key: "seats", label: "Team members", fmt: "count" },
    { key: "documents", label: "Documents", fmt: "count" },
    { key: "datasets", label: "Datasets", fmt: "count" },
    { key: "webhooks", label: "Webhooks", fmt: "count" },
    { key: "db_size", label: "Database size", fmt: "bytes" },
    { key: "disk", label: "Disk used", fmt: "percent" },
    // Machine meters (OC23/OC26): cpu/ram are percents with a true 0-100 bar;
    // req_per_s / p95_ms are rate/latency signals — bar-less, tinted from OC25
    // over_at. Grouped after disk (the host-capacity block), flow meters last.
    { key: "cpu", label: "CPU", fmt: "percent" },
    { key: "ram", label: "RAM", fmt: "percent" },
    { key: "req_per_s", label: "Req/s", fmt: "rate" },
    { key: "p95_ms", label: "p95 latency", fmt: "ms" },
    { key: "api_requests", label: "API requests", fmt: "count" },
    { key: "bandwidth", label: "Bandwidth", fmt: "bytes" }
  ];

  // Pure: humanize a byte count (base-1024). A non-number is echoed as-is so a
  // caller never crashes on a surprise shape.
  function c10FmtBytes(n) {
    if (typeof n !== "number" || !isFinite(n) || n < 0) return String(n);
    var units = ["B", "KB", "MB", "GB", "TB"];
    var i = 0, v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (i === 0 ? String(v) : v.toFixed(1)) + " " + units[i];
  }

  function c10FmtValue(fmt, value) {
    if (fmt === "bytes") return c10FmtBytes(value);
    if (fmt === "percent") return Math.round(value) + "%";
    if (fmt === "ms") return Math.round(value) + " ms";
    // rate: one decimal, trailing ".0" trimmed (12 → "12/s", 12.45 → "12.5/s").
    if (fmt === "rate") return (Math.round(value * 10) / 10) + "/s";
    return String(value); // count
  }

  // Pure: the display model for ONE meter. `value === "unmetered"` (or any
  // non-number) renders the designed "Not yet metered" state — never a fake
  // zero, never an error. `measured_at` nil renders as a LIVE read ("live"),
  // NOT an error (acceptance criterion 2); a present measured_at renders
  // "as of <relTime>". The seats meter's pending_invitations rides along.
  function usageMeterDisplay(spec, meter, history) {
    meter = meter || {};
    var unmetered = meter.value === "unmetered" || typeof meter.value !== "number";
    var value = unmetered ? "Not yet metered" : c10FmtValue(spec.fmt, meter.value);
    var freshness = unmetered ? "" : (meter.measured_at ? "as of " + relTime(meter.measured_at) : "live");
    var pending = spec.key === "seats" && typeof meter.pending_invitations === "number" && meter.pending_invitations > 0
      ? meter.pending_invitations + " pending invitation" + (meter.pending_invitations === 1 ? "" : "s")
      : "";
    // OC25 — the threshold state, computed independent of whether a bar draws.
    // "over" when the value reaches over_at OR the quota ceiling (both inclusive,
    // mirroring the create-time guard); "warn" once it crosses warn_at; "ok" for a
    // metered meter that carries ANY threshold but has tripped none. A meter with
    // no threshold at all (a plain count) has no state (null → no tint). This lets
    // a bar-less rate/latency meter (req_per_s / p95_ms — quota nil, warn_at +
    // over_at set) still tint the row, honestly, without a bar to nowhere.
    var hasThreshold = typeof meter.over_at === "number" ||
      typeof meter.warn_at === "number" ||
      (typeof meter.quota === "number" && meter.quota > 0);
    var state = null;
    if (!unmetered && hasThreshold) {
      var over = (typeof meter.over_at === "number" && meter.value >= meter.over_at) ||
        (typeof meter.quota === "number" && meter.quota > 0 && meter.value >= meter.quota);
      var warn = typeof meter.warn_at === "number" && meter.value >= meter.warn_at;
      state = over ? "over" : warn ? "warn" : "ok";
    }
    // OC7 — the quota bar model. A bar is drawn ONLY when a real ceiling is
    // present (numeric quota > 0) AND the meter reports a real number; a nil/zero
    // quota is an honest "unlimited" — no bar, no fake ceiling. cpu/ram/disk carry
    // the physical 100 ceiling → a true 0-100 bar; req_per_s / p95_ms have no
    // quota → no bar (their state still tints the row). pct clamps at 100 so an
    // over-limit meter fills the whole track rather than overflowing it. The tone
    // is the shared OC25 state.
    var bar = null;
    if (!unmetered && typeof meter.quota === "number" && meter.quota > 0) {
      var pct = Math.min(100, Math.round((meter.value / meter.quota) * 100));
      bar = { pct: pct, tone: state, quota: c10FmtValue(spec.fmt, meter.quota), quotaText: value + " / " + c10FmtValue(spec.fmt, meter.quota) };
    }
    // Wave 4 (OC19): the 14-day sparkline values, threaded in from /usage/history.
    // `spark` is the value|null array fed VERBATIM to sparklineSvg (a null is a
    // GAP — the stroke breaks, never a fake zero, D48/D51). It stays null unless
    // the series carries at least one real number, so an absent / all-null history
    // renders NO spark chrome (honest absence — progressive fill, not a placeholder
    // line). `history` is optional: today's two-arg callers (the strip) get null.
    var spark = (Array.isArray(history) && history.some(function (v) { return typeof v === "number" && isFinite(v); }))
      ? history.slice()
      : null;
    return { key: spec.key, label: spec.label, unmetered: unmetered, value: value, freshness: freshness, pending: pending, state: state, bar: bar, spark: spark };
  }

  function usageMeterHtml(spec, meter, history) {
    var d = usageMeterDisplay(spec, meter, history);
    var sub = [d.freshness, d.pending].filter(Boolean).join(" · ");
    // Wave 4 (OC19): the quiet 14-day trend. Rendered ONLY when the meter has real
    // numeric history — an absent/all-null series draws nothing (honest absence).
    // sparklineSvg is reused VERBATIM (currentColor, null-is-gap, isolated-point
    // dot, flat-midline all already pinned there); the .usage-spark wrapper tints
    // it (muted, or the row's quota tone) and sizes it ~120×32.
    var sparkHtml = d.spark
      ? '<div class="usage-spark">' + sparklineSvg(d.spark, { width: 240, height: 44, area: true }) + "</div>"
      : "";
    // The quota bar (when present) lives under the meter name. Manage-plan is the
    // ONE recovery action (D25) for the BILLING quota meter's over state — the
    // instances ceiling routes to Settings billing. A physical meter over its
    // wall (cpu/ram/disk at 90%+) is a capacity signal, not a billing dead-end, so
    // it tints red without a "Manage plan" link that would do nothing for it.
    var barHtml = "";
    if (d.bar) {
      var manage = d.bar.tone === "over" && d.key === "instances"
        ? '<a class="usage-bar-action" href="#settings/billing">Manage plan</a>'
        : "";
      var quotaCls = d.bar.tone === "ok" ? "usage-bar-quota dim" : "usage-bar-quota";
      barHtml =
        '<div class="usage-bar usage-bar--' + d.bar.tone + '" role="progressbar" aria-label="' + esc(d.label) + ' quota" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + d.bar.pct + '" aria-valuetext="' + esc(d.bar.quotaText) + '">' +
          '<span class="usage-bar-fill" style="width:' + d.bar.pct + '%"></span>' +
        "</div>" +
        '<div class="usage-bar-meta token-meta">' +
          '<span class="' + quotaCls + '">' + esc(d.bar.quotaText) + "</span>" +
          manage +
        "</div>";
    }
    // The row tint follows the OC25 state (not the bar) so a bar-less rate/latency
    // meter over its threshold reddens the value badge too. "ok" carries no tint —
    // only warn/over colour the row (a healthy meter reads neutral).
    // The tone modifier is ALWAYS present (mirrors statusPill's role) so the
    // static head reads "usage-card usage-card--" for the CSS checker; "ok" is the
    // untinted neutral (no rule needed), warn/over carry the S4 role tint.
    var toneCls = d.state === "warn" || d.state === "over" ? d.state : "ok";
    var valueHtml = d.unmetered
      ? '<span class="dim">' + esc(d.value) + "</span>"
      : "<strong>" + esc(d.value) + "</strong>";
    // C10 stat card (mirrors .metric-card): the label + headline value on one
    // row, the freshness sub, the hero (area-filled) sparkline, then the quota
    // bar when a real ceiling exists. One tone vocabulary (warn/over) tints the
    // value, the spark (currentColor) and the bar through --usage-card-- .
    return '<div class="usage-card usage-card--' + toneCls + '">' +
      '<div class="usage-card-head">' +
        '<span class="usage-card-label">' + esc(d.label) + "</span>" +
        '<span class="usage-card-value">' + valueHtml + "</span>" +
      "</div>" +
      (sub ? '<div class="usage-card-sub">' + esc(sub) + "</div>" : "") +
      sparkHtml +
      barHtml +
      "</div>";
  }

  // Pure: normalise the /usage/history envelope to its meter→points `series` map.
  // S1 carries `series` at top level (mirroring the Metrics shape); a defensive
  // `usage_history` wrapper is tolerated so a backend top-level-key change never
  // silently blanks every sparkline. Garbage → {} (the grid then draws bar-less,
  // exactly as before history landed).
  function usageHistorySeries(payload) {
    payload = payload || {};
    var wrap = (payload.usage_history && typeof payload.usage_history === "object") ? payload.usage_history : payload;
    return (wrap && typeof wrap.series === "object" && wrap.series) ? wrap.series : {};
  }

  // Pure: one meter's history as a value|null array for sparklineSvg. A missing
  // meter / non-array → []; each point's non-finite value → null (a GAP, never a
  // fake zero — D48/D51). Order is preserved oldest→newest (the envelope's order).
  function usageHistoryValues(series, meterKey) {
    var raw = (series && typeof series === "object" && Array.isArray(series[meterKey])) ? series[meterKey] : [];
    return raw.map(function (p) {
      p = p || {};
      return (typeof p.value === "number" && isFinite(p.value)) ? p.value : null;
    });
  }

  // Pure: the whole meter grid from a /usage `meters` object. A missing meter
  // degrades to the unmetered state (usageMeterDisplay tolerates absent input),
  // so the grid is always fully present. `series` (optional; the /usage/history
  // map) threads each meter's 14-day trend — absent (before history lands / on a
  // failed fetch) → today's bar-less grid, unchanged (progressive fill).
  function usageMetersHtml(meters, series) {
    meters = meters || {};
    return '<div class="usage-grid">' + USAGE_METERS.map(function (spec) {
      return usageMeterHtml(spec, meters[spec.key], series ? usageHistoryValues(series, spec.key) : null);
    }).join("") + "</div>";
  }

  // The loading skeleton — a hung box can hold /usage ~15s (D51), so the tab
  // shows this the whole time rather than a blank panel (acceptance criterion 2).
  function usageTabShellHtml() {
    return '<div class="fleet-body" aria-live="polite"><div class="loading">Loading usage&hellip;</div></div>';
  }

  // Pure: honest human copy for a failed /usage fetch — never a dead spinner.
  function usageFailureCopy(status) {
    if (status === 404) return "This instance isn't in your team, or has been removed.";
    return "We couldn't load usage for this instance — it may be starting up. Retry in a moment.";
  }

  function usageErrorHtml(status) {
    return '<div class="empty-state"><h2>Couldn\'t load usage</h2><p>' +
      esc(usageFailureCopy(status)) +
      '</p><p><button class="btn btn-primary btn-sm" data-usage-retry type="button">Retry</button></p></div>';
  }

  // The 14-day sparklines default to one point per ~6h (OC19: default 56, cap 200).
  var USAGE_HISTORY_POINTS = 56;

  // Mount the Usage tab into the instance tabpanel: paint the skeleton, fetch
  // /usage, then swap in the meter grid — or an honest, retryable error state.
  // PROGRESSIVE FILL (Wave 4 / OC19): a SECOND fetch to /usage/history runs in
  // PARALLEL; the meters render exactly as today the moment /usage lands, and the
  // per-meter sparklines fill in when history lands. Before history lands — or if
  // it fails / 404s (an older control plane) — NO spark markup renders (honest
  // absence, never a spinner or a placeholder line). Either fetch order is safe:
  // paint() only draws once /usage has landed, threading whatever history it has.
  function mountUsageTab(panel, bp) {
    // Defensive re-acquire by id: the caller passes the freshly-rendered tabpanel,
    // but a lost ref still resolves through getElementById — so the meter wall
    // renders (and stays observable to the preview harness) rather than no-op.
    if (!panel && typeof document !== "undefined" && document.getElementById) panel = document.getElementById("instance-tabpanel");
    if (!panel) return;
    panel.innerHTML = usageTabShellHtml();
    // The skeleton's .fleet-body is the swap target in the live DOM; if a harness
    // can't resolve the sub-query, fall back to the panel itself (same element the
    // grid would land in).
    var box = panel.querySelector(".fleet-body") || panel;
    var meters = null;   // set when /usage lands; null keeps the skeleton up
    var series = null;   // set when /usage/history lands; null → bar-less grid
    function paint() {
      if (!box || box.isConnected === false) return; // navigated away mid-flight
      if (!meters) return; // meters not in yet — leave the skeleton (or error) untouched
      box.innerHTML = usageMetersHtml(meters, series);
    }
    api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/usage").then(function (r) {
      if (!box || box.isConnected === false) return; // navigated away mid-flight
      if (r.ok && r.data && r.data.usage && r.data.usage.meters) {
        meters = r.data.usage.meters;
        paint();
        return;
      }
      box.innerHTML = usageErrorHtml(r.status);
      var retry = box.querySelector("[data-usage-retry]");
      if (retry) retry.addEventListener("click", function () { mountUsageTab(panel, bp); });
    });
    // The history fetch is best-effort garnish: a failure/404 leaves `series` null
    // so the meters simply stay bar-less. It never surfaces its own error state.
    api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/usage/history?points=" + USAGE_HISTORY_POINTS).then(function (r) {
      if (!box || box.isConnected === false) return;
      if (!r.ok || !r.data) return; // honest absence — no spark markup
      series = usageHistorySeries(r.data);
      paint(); // re-render with sparks iff /usage has already landed (paint guards)
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ── Wave 3 (OC16/OC18/OC6): Overview fleet usage strip ────────────────────
  // Open Overview and the WHOLE fleet's usage answers instantly — from CACHED
  // sampler rows, NEVER a live per-instance fan-out (the ~15s hang disqualifies
  // it, charter OC10/OC18). This region reads GET /v1/usage/summary (the pure
  // sampler read shaped by BarkparkCloud.Usage) and paints: one team-level
  // instances quota bar (reusing the C10 renderer, so ok/warn/over tones + the
  // over-state Manage-plan recovery come for free) plus one compact cell per
  // instance with its headline meters DOCS · DB · DISK · SEATS, each stamped with
  // its OWN sample freshness. A null measured_at is the honest "no sample yet" —
  // never a fake zero, never fake-fresh. Refresh rides the EXISTING `fleet` SSE
  // (TYPE_ACTIONS.fleet → invalidateFleet re-runs loadOverview), so ZERO new SSE
  // vocabulary (OC6/D2). Append-only: does not touch the C10 / Metrics regions.
  // ══════════════════════════════════════════════════════════════════════════

  // The headline meters shown per instance cell (a subset of the meter set), in
  // the charter's order: DOCS · DB · DISK · SEATS · CPU · RAM (OC18/OC27). The
  // count/byte meters pull their number format from the shared USAGE_METERS spec
  // so a formatting change can never drift between the strip and the Usage tab.
  // The MACHINE meters (cpu/ram — the on-box agent's capacity beat) pin
  // their own `fmt: "percent"` on the headline entry: they land in the shared
  // vocabulary via the machine-meters slice, and the headline fmt keeps the strip
  // formatting them correctly regardless of that spec's presence. An un-armed box
  // (no agent) has no cpu/ram meter → the cell renders the honest dimmed "—", the
  // same "never a fake zero" state a quiet pipe gets (4 of 5 fleet boxes carry no
  // agent today — that dimmed cell is CORRECT, not a bug).
  var FLEET_STRIP_METERS = [
    { key: "documents", label: "Docs" },
    { key: "db_size", label: "DB" },
    { key: "disk", label: "Disk" },
    { key: "seats", label: "Seats" },
    { key: "cpu", label: "CPU", fmt: "percent" },
    { key: "ram", label: "RAM", fmt: "percent" }
  ];

  function fleetStripSpecFor(key) {
    for (var i = 0; i < USAGE_METERS.length; i++) if (USAGE_METERS[i].key === key) return USAGE_METERS[i];
    return { key: key, label: key, fmt: "count" };
  }

  // Resolve the display spec for a headline ENTRY. The label/fmt come from the
  // shared USAGE_METERS vocabulary, but a headline entry may PIN its own fmt (the
  // machine meters carry fmt:"percent") — that wins, so the strip formats a
  // percent meter correctly even independent of the vocab spec. The tone/quota
  // math in usageMeterDisplay reads the envelope's quota/warn_at, so the physical
  // ceilings the sampler stamps light the worst-state fold for free (OC22).
  function fleetHeadlineSpec(h) {
    var spec = fleetStripSpecFor(h.key);
    return h.fmt ? { key: spec.key, label: spec.label, fmt: h.fmt } : spec;
  }

  // Fold the quota tones of a row's headline cells to the worst present:
  // over > warn > ok. Returns null when no headline cell carries a quota bar
  // (nothing to accent). Since wave 5 the machine meters cpu/ram and disk carry
  // real physical ceilings (100 / warn 70 / over 90), so an armed hot box folds
  // to over/warn here; the billing meters (documents/db_size/seats) stay bar-less
  // until plan truth lands (cloud-console-billing-live-gate), and the fold lights
  // up for them too the moment a ceiling arrives.
  function fleetStripWorst(meters) {
    var order = { ok: 1, warn: 2, over: 3 };
    var worst = null;
    FLEET_STRIP_METERS.forEach(function (h) {
      var d = usageMeterDisplay(fleetHeadlineSpec(h), (meters || {})[h.key]);
      if (d.bar && (worst === null || order[d.bar.tone] > order[worst])) worst = d.bar.tone;
    });
    return worst;
  }

  // Pure: the strip's whole display model from the /v1/usage/summary `usage`
  // object { team, instances }. teamMeter is the raw team.instances meter (fed
  // straight to the shared usageMeterHtml). Each row carries its headline cells +
  // its own sample freshness; a null measured_at → noSample (the honest "no
  // sample yet" cell — an unmetered envelope with a real absence, not a zero).
  function fleetStripModel(usage) {
    usage = usage || {};
    var team = usage.team || {};
    var teamMeter = team.instances || null;
    var list = Array.isArray(usage.instances) ? usage.instances : [];
    var rows = list.map(function (inst) {
      inst = inst || {};
      var meters = inst.meters || {};
      var measuredAt = inst.measured_at || null;
      var noSample = !measuredAt;
      var cells = FLEET_STRIP_METERS.map(function (h) {
        var d = usageMeterDisplay(fleetHeadlineSpec(h), meters[h.key]);
        // A compact cell shows a short em-dash for an unmetered meter rather than
        // the full "Not yet metered" sentence the Usage tab uses.
        return { key: h.key, label: h.label, value: d.unmetered ? "—" : d.value, unmetered: d.unmetered };
      });
      return {
        id: inst.id != null ? String(inst.id) : "",
        label: inst.name || inst.slug || inst.host || "Instance",
        measured_at: measuredAt,
        asOf: measuredAt ? relTime(measuredAt) : null,
        noSample: noSample,
        cells: cells,
        worstState: noSample ? null : fleetStripWorst(meters)
      };
    });
    var teamDisplay = teamMeter ? usageMeterDisplay(fleetStripSpecFor("instances"), teamMeter) : null;
    return {
      teamMeter: teamMeter,
      // Surfaces the team bar's quota tone for a headline test without HTML.
      teamState: teamDisplay && teamDisplay.bar ? teamDisplay.bar.tone : null,
      rows: rows
    };
  }

  // Pure: one instance cell. Native <a href="#instance/<id>/usage"> so the click
  // is a plain hash navigation (no JS wiring, mirroring rollupCard). A no-sample
  // instance renders the honest empty cell, never a wall of dashes.
  function fleetStripCellHtml(row) {
    var href = "#instance/" + encodeURIComponent(row.id) + "/usage";
    if (row.noSample) {
      return '<a class="fleet-usage-cell fleet-usage-cell--nosample" href="' + href + '">' +
        '<div class="fleet-usage-cell-name">' + esc(row.label) + "</div>" +
        '<div class="fleet-usage-cell-empty">No sample yet</div>' +
      "</a>";
    }
    var metrics = row.cells.map(function (c) {
      return '<span class="fleet-usage-metric">' +
        '<span class="fleet-usage-metric-k">' + esc(c.label) + "</span>" +
        '<span class="fleet-usage-metric-v' + (c.unmetered ? " dim" : "") + '">' + esc(c.value) + "</span>" +
      "</span>";
    }).join("");
    var toneCls = row.worstState && row.worstState !== "ok" ? " fleet-usage-cell--" + row.worstState : "";
    return '<a class="fleet-usage-cell' + toneCls + '" href="' + href + '">' +
      '<div class="fleet-usage-cell-name">' + esc(row.label) + "</div>" +
      '<div class="fleet-usage-cell-metrics">' + metrics + "</div>" +
      '<div class="fleet-usage-cell-asof token-meta dim">as of ' + esc(row.asOf) + "</div>" +
    "</a>";
  }

  // Pure: the whole strip. The team quota bar reuses usageMeterHtml with the
  // `instances` spec — identical ok/warn/over tones and the over-state
  // Manage-plan recovery (D25). No teamMeter → no bar (honest, never a fake).
  function fleetStripHtml(model) {
    var teamBar = model.teamMeter ? usageMeterHtml(fleetStripSpecFor("instances"), model.teamMeter) : "";
    var cells = model.rows.map(fleetStripCellHtml).join("");
    return '<section class="fleet-usage-strip" aria-label="Fleet usage">' +
      '<div class="overview-sub"><h2>Fleet usage</h2></div>' +
      teamBar +
      '<div class="fleet-usage-grid">' + cells + "</div>" +
    "</section>";
  }

  // Mount the strip into its Overview container via its OWN async fetch of the
  // cached summary — NEVER a per-instance /usage call from Overview. Like the
  // activity digest, a failed or empty read hides the strip rather than scaring
  // the operator: Overview's primary content (the attention queue) stands alone,
  // and the per-instance Usage tab is where a real failure gets full recovery.
  function loadFleetUsageStrip() {
    var box = $("#overview-fleet-usage");
    if (!box) return;
    box.innerHTML = '<div class="fleet-usage-strip fleet-usage-loading">Loading fleet usage&hellip;</div>';
    api("GET", "/v1/usage/summary").then(function (r) {
      box = $("#overview-fleet-usage");
      if (!box) return; // navigated away mid-flight
      if (!r.ok || !r.data || !r.data.usage) { box.innerHTML = ""; return; }
      var model = fleetStripModel(r.data.usage);
      if (!model.rows.length && !model.teamMeter) { box.innerHTML = ""; return; }
      box.innerHTML = fleetStripHtml(model);
    });
  }

  // ── Metrics tab (S12: the on-box agent vitals beat) ─────────────────────────
  // The Metrics tab renders the monitoring truth the on-box agent reports (charter
  // Decision 13/32): CPU / memory / disk / load sparklines over a rolling window +
  // a service-health rollup. Consumers NEVER compute — the control plane rolls the
  // window and hands this surface a ready envelope:
  //
  //   {ok, collected_at, instance:{id,host,provider},
  //    beat:{last_seen_at, age_seconds, status: live|stale|absent},
  //    points, series:{cpu|mem|disk|load: [{at, value|null}] oldest-to-newest},
  //    service_health:{pass, total, failing:[]}}
  //
  // The pure fold (metricsSeries) + the SVG sparkline string helper (sparklineSvg)
  // are the node-pinned surface; the DOM mount + 4s poll are browser-verified.

  // The four vitals we plot, in render order. `role` is a status-role name whose
  // colour reads through the S4 role vars (.metric--<role> in app.css → var(--…));
  // NO new hex is introduced. `unit` shapes the headline value; a percent metric
  // rounds to a whole number, load carries no unit.
  var METRIC_SPECS = [
    { key: "cpu", label: "CPU", unit: "%", role: "info" },
    { key: "mem", label: "Memory", unit: "%", role: "ok" },
    { key: "disk", label: "Disk", unit: "%", role: "warn" },
    { key: "load", label: "Load", unit: "", role: "info" },
  ];

  // Pure: an honest human age from the beat's age_seconds. Deterministic (no
  // Date.now dependency — the server already computed the age at collection), so
  // the reducer is node-pinnable. A negative/absent/garbage age → "".
  function metricsAgeText(ageSeconds) {
    if (typeof ageSeconds !== "number" || !isFinite(ageSeconds) || ageSeconds < 0) return "";
    var s = Math.floor(ageSeconds);
    if (s < 60) return s + "s ago";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    var h = Math.floor(m / 60);
    if (h < 24) return h + "h ago";
    return Math.floor(h / 24) + "d ago";
  }

  // Pure: the render-ready model for the whole Metrics tab. TOTAL over any
  // payload (null / garbage never throws — the tab must degrade, never
  // white-screen). The beat status drives the honest state: `absent` (no beat
  // ever) → the "waiting for first beat" panel, NEVER a zeroed chart; `stale`
  // (beat gone quiet) → the last-known series flagged "last seen Xm ago"; `live`
  // → the normal read. Each metric carries its points with nulls PRESERVED (a
  // dropped/missing sample is a gap, not a zero) plus `current` = the latest
  // non-null value (null when the whole series is holes).
  function metricsSeries(payload) {
    payload = payload || {};
    var beat = payload.beat || {};
    var status = (beat.status === "live" || beat.status === "stale" || beat.status === "absent")
      ? beat.status : "absent";
    var inst = payload.instance || {};
    var health = payload.service_health || {};
    var series = payload.series || {};
    var metrics = METRIC_SPECS.map(function (spec) {
      var raw = Array.isArray(series[spec.key]) ? series[spec.key] : [];
      var points = raw.map(function (p) {
        p = p || {};
        var v = (typeof p.value === "number" && isFinite(p.value)) ? p.value : null;
        return { at: typeof p.at === "string" ? p.at : "", value: v };
      });
      var values = points.map(function (p) { return p.value; });
      var current = null;
      for (var i = values.length - 1; i >= 0; i--) {
        if (values[i] !== null) { current = values[i]; break; }
      }
      return {
        key: spec.key, label: spec.label, unit: spec.unit, role: spec.role,
        points: points, values: values, current: current,
        hasData: values.some(function (v) { return v !== null; }),
      };
    });
    var failing = Array.isArray(health.failing)
      ? health.failing.filter(function (x) { return typeof x === "string"; })
      : [];
    return {
      ok: !!payload.ok,
      status: status,
      absent: status === "absent",
      stale: status === "stale",
      live: status === "live",
      host: typeof inst.host === "string" ? inst.host : "",
      provider: typeof inst.provider === "string" ? inst.provider : "",
      ageSeconds: typeof beat.age_seconds === "number" ? beat.age_seconds : null,
      lastSeenAt: typeof beat.last_seen_at === "string" ? beat.last_seen_at : null,
      lastSeenText: metricsAgeText(beat.age_seconds),
      metrics: metrics,
      health: {
        pass: typeof health.pass === "number" ? health.pass : null,
        total: typeof health.total === "number" ? health.total : null,
        failing: failing,
      },
    };
  }

  // Pure: a self-contained inline SVG sparkline STRING from a values array (each
  // entry a number OR null). Normalised to the series' own min..max, so the shape
  // reads regardless of the absolute scale. GAPS, NOT ZEROS: a null breaks the
  // stroke — the line is drawn as one polyline per contiguous run of real values
  // (an isolated island renders a dot), so a missing sample never draws a point at
  // the baseline. Colour is `currentColor` (inherited from the metric's role
  // class) — the helper introduces no colour of its own. Empty / all-null → an
  // empty chart frame (never a fabricated flat line). A flat series draws along
  // the mid-line (the divide-by-zero guard), never at y=0.
  function sparklineSvg(values, opts) {
    opts = opts || {};
    var w = typeof opts.width === "number" ? opts.width : 160;
    var h = typeof opts.height === "number" ? opts.height : 36;
    var pad = 3;
    var vals = Array.isArray(values) ? values : [];
    var nums = [];
    for (var k = 0; k < vals.length; k++) {
      if (typeof vals[k] === "number" && isFinite(vals[k])) nums.push(vals[k]);
    }
    var frame = '<svg class="spark" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h +
      '" preserveAspectRatio="none" role="img" aria-hidden="true">';
    if (nums.length === 0) return frame + "</svg>"; // nothing real to draw
    var min = Math.min.apply(null, nums), max = Math.max.apply(null, nums);
    var span = max - min;
    var innerW = w - pad * 2, innerH = h - pad * 2;
    var n = vals.length;
    function rnd(x) { return Math.round(x * 10) / 10; }
    function px(i) { return rnd(n <= 1 ? pad + innerW / 2 : pad + (i / (n - 1)) * innerW); }
    function py(v) { return rnd(span <= 0 ? pad + innerH / 2 : pad + innerH - ((v - min) / span) * innerH); }
    // Split into contiguous runs of real values; a null closes the current run.
    var runs = [], cur = [];
    for (var i = 0; i < n; i++) {
      var v = vals[i];
      if (typeof v === "number" && isFinite(v)) {
        cur.push({ x: px(i), y: py(v) });
      } else if (cur.length) {
        runs.push(cur); cur = [];
      }
    }
    if (cur.length) runs.push(cur);
    // Optional soft area fill under each run (opts.area) — a token-neutral
    // currentColor wash at low opacity, drawn BEHIND the stroke so the line still
    // reads crisp. Uses <path d> (never <polygon points>) so the run-counting
    // sparkline tests are unaffected; a single-point run draws no area (its dot
    // stands alone). Off by default — only the C10/S12 stat cards opt in.
    var area = "";
    if (opts.area) {
      var baseY = rnd(h - pad);
      area = runs.map(function (run) {
        if (run.length < 2) return "";
        var d = "M" + run[0].x + "," + baseY +
          run.map(function (p) { return " L" + p.x + "," + p.y; }).join("") +
          " L" + run[run.length - 1].x + "," + baseY + " Z";
        return '<path d="' + d + '" fill="currentColor" fill-opacity="0.13" stroke="none"/>';
      }).join("");
    }
    var body = runs.map(function (run) {
      if (run.length === 1) {
        return '<circle cx="' + run[0].x + '" cy="' + run[0].y + '" r="1.5" fill="currentColor"/>';
      }
      var pts = run.map(function (p) { return p.x + "," + p.y; }).join(" ");
      return '<polyline points="' + pts + '" fill="none" stroke="currentColor" stroke-width="1.5" ' +
        'stroke-linejoin="round" stroke-linecap="round"/>';
    }).join("");
    return frame + area + body + "</svg>";
  }

  // Pure: the headline value string for one metric card. A holes-only series → the
  // honest em-dash (never a fake 0); a percent rounds to a whole number, load
  // keeps two decimals.
  function metricsValueText(m) {
    if (!m || m.current === null || typeof m.current !== "number") return "—";
    if (m.unit === "%") return Math.round(m.current) + "%";
    var r = Math.round(m.current * 100) / 100;
    return String(r) + (m.unit ? " " + m.unit : "");
  }

  // Pure: one metric card — headline value + label + the role-tinted sparkline.
  function metricsCardHtml(m) {
    var spark = sparklineSvg(m.values, { width: 180, height: 40, area: true });
    return '<div class="metric-card metric--' + esc(m.role) + '">' +
      '<div class="metric-head"><span class="metric-label">' + esc(m.label) + "</span>" +
      '<span class="metric-value">' + esc(metricsValueText(m)) + "</span></div>" +
      '<div class="metric-spark">' + spark + "</div></div>";
  }

  // Pure: the service-health rollup line. Absent counts → hidden (never "0/0").
  function metricsHealthHtml(health) {
    health = health || {};
    if (typeof health.pass !== "number" || typeof health.total !== "number" || health.total <= 0) return "";
    var failing = Array.isArray(health.failing) ? health.failing : [];
    var tone = failing.length ? "warn" : "up";
    var line = badge("Health " + health.pass + "/" + health.total, tone);
    var detail = failing.length
      ? '<span class="token-meta dim">failing: ' + esc(failing.join(", ")) + "</span>"
      : "";
    return '<div class="metrics-health fleet-row"><div class="fleet-main">' +
      '<div class="fleet-name">Service health</div>' + detail + "</div>" +
      '<div class="fleet-badges">' + line + "</div></div>";
  }

  // Pure: the freshness / stale banner above the grid.
  function metricsHeadHtml(model) {
    if (model.stale) {
      return '<div class="metrics-stale" role="status">Agent offline — showing the last known readings' +
        (model.lastSeenText ? " (last seen " + esc(model.lastSeenText) + ")" : "") + ".</div>";
    }
    return '<div class="metrics-fresh token-meta dim">Live' +
      (model.lastSeenText ? " · last beat " + esc(model.lastSeenText) : "") + "</div>";
  }

  // Pure: the whole tab body from a metricsSeries model. `absent` (no beat ever)
  // shows the honest waiting panel — NEVER a zeroed chart.
  function metricsPanelHtml(model) {
    if (!model || model.absent) {
      return '<div class="empty-state"><h2>Waiting for the first beat</h2>' +
        "<p>This instance hasn't reported vitals yet. The on-box agent checks in about once a " +
        "minute — metrics appear here as soon as the first beat lands.</p></div>";
    }
    var grid = model.metrics.map(metricsCardHtml).join("");
    return metricsHeadHtml(model) +
      '<div class="metrics-grid">' + grid + "</div>" +
      metricsHealthHtml(model.health);
  }

  // The loading skeleton — the first metrics fetch can lag a cold roll-up, so the
  // tab shows this rather than a blank panel.
  function metricsTabShellHtml() {
    return '<div class="fleet-body metrics-body" aria-live="polite"><div class="loading">Loading metrics&hellip;</div></div>';
  }

  // Pure: honest human copy for a failed /metrics fetch — never a dead spinner.
  function metricsFailureCopy(status) {
    if (status === 404) return "This instance isn't in your team, or has been removed.";
    return "We couldn't load metrics for this instance — it may be starting up. Retry in a moment.";
  }

  function metricsErrorHtml(status) {
    return '<div class="empty-state"><h2>Couldn\'t load metrics</h2><p>' +
      esc(metricsFailureCopy(status)) +
      '</p><p><button class="btn btn-primary btn-sm" data-metrics-retry type="button">Retry</button></p></div>';
  }

  // How many points to request — 30 samples × the ~60s beat ≈ a 30-minute window.
  var METRICS_POINTS = 30;

  // Which mount owns the Metrics tab + its poll right now. A newer mount (tab
  // switch, instance nav) bumps the seq, invalidating older in-flight GETs and any
  // pending poll re-arm — the loadInstanceDomains idiom (a self-limiting setTimeout
  // chain, not a fixed interval), but here the poll never terminates: monitoring is
  // continuous, so it re-arms every 4s while the tab stays mounted. 4s is the
  // REFRESH cadence; the DATA cadence is the 60s beat (the CP rolls the window).
  var metricsSeq = 0;
  var metricsPollTimer = null;
  function mountMetricsTab(panel, bp) {
    if (!panel) return;
    panel.innerHTML = metricsTabShellHtml();
    var seq = ++metricsSeq;
    clearTimeout(metricsPollTimer);
    function tick() {
      api("GET", "/v1/barkparks/" + encodeURIComponent(bp.id) + "/metrics?points=" + METRICS_POINTS).then(function (r) {
        if (seq !== metricsSeq) return; // a newer mount owns the tab
        var box = panel.querySelector(".metrics-body");
        if (!box || box.isConnected === false) return; // navigated away mid-flight
        if (!r.ok || !r.data) {
          box.innerHTML = metricsErrorHtml(r.status);
          var retry = box.querySelector("[data-metrics-retry]");
          if (retry) retry.addEventListener("click", function () { mountMetricsTab(panel, bp); });
          return; // a hard error stops the poll until the operator retries
        }
        box.innerHTML = metricsPanelHtml(metricsSeries(r.data));
        clearTimeout(metricsPollTimer);
        metricsPollTimer = setTimeout(function () {
          if (seq !== metricsSeq) return;
          tick();
        }, 4000);
      });
    }
    tick();
  }

  // ── Members panel (Settings view) ───────────────────────────────────────────
  var ROLE_LABELS = { owner: "Owner", admin: "Admin", member: "Member" };

  // Pure: the roles the acting user may ASSIGN (anti-escalation is enforced
  // server-side; this only shapes the menu + hides controls a member can't use).
  function assignableRoles(actorRole) {
    if (actorRole === "owner") return ["owner", "admin", "member"];
    if (actorRole === "admin") return ["admin", "member"];
    return [];
  }

  // The current team + the actor's role, read from the /v1/me cache the account
  // chip already loads. null when teamless (the panel shows a "no team" state).
  function membersContext() {
    var me = meCache;
    if (me && me.team && me.team.id) {
      return { teamId: me.team.id, role: me.role || "member", userId: me.user && me.user.id };
    }
    return null;
  }

  // Pure: honest human copy for a failed members/invitations fetch.
  function membersFailureCopy(status) {
    if (status === 0) return "Network error — is the control plane reachable? Retry in a moment.";
    if (status === 403) return "You don't have permission to view this team's members.";
    return "We couldn't load your team's members. Retry in a moment.";
  }

  function membersErrorHtml(status) {
    return '<div class="empty-state"><h2>Couldn\'t load members</h2><p>' +
      esc(membersFailureCopy(status)) +
      '</p><p><button class="btn btn-primary btn-sm" data-members-retry type="button">Retry</button></p></div>';
  }

  // Pure: one member row. The current user is tagged "(you)" and never carries
  // manage controls (you can't demote/remove yourself here); non-managers see
  // no controls at all.
  function memberRowHtml(m, ctx) {
    var canManage = assignableRoles(ctx.role).length > 0;
    var isSelf = ctx.userId != null && String(m.user_id) === String(ctx.userId);
    var actions = (canManage && !isSelf)
      ? '<button class="btn btn-ghost btn-sm" data-member-role="' + esc(m.user_id) +
          '" data-role="' + esc(m.role) + '" data-email="' + esc(m.email) + '" type="button">Change role</button>' +
        '<button class="btn btn-ghost btn-sm" data-member-remove="' + esc(m.user_id) +
          '" data-email="' + esc(m.email) + '" type="button">Remove</button>'
      : "";
    return '<div class="fleet-row">' +
      '<div class="fleet-main"><div class="fleet-name">' + esc(m.email) +
        (isSelf ? ' <span class="dim">(you)</span>' : "") + "</div>" +
        '<div class="token-meta dim">joined ' + esc(relTime(m.joined_at)) + "</div></div>" +
      '<div class="fleet-badges">' + badge(ROLE_LABELS[m.role] || m.role, "up") + actions + "</div></div>";
  }

  // Pure: one pending-invitation row.
  function invitationRowHtml(inv, ctx) {
    var canManage = assignableRoles(ctx.role).length > 0;
    var action = canManage
      ? '<button class="btn btn-ghost btn-sm" data-invite-revoke="' + esc(inv.id) +
          '" data-email="' + esc(inv.email) + '" type="button">Revoke</button>'
      : "";
    return '<div class="fleet-row">' +
      '<div class="fleet-main"><div class="fleet-name">' + esc(inv.email) + "</div>" +
        '<div class="token-meta dim">invited as ' + esc(ROLE_LABELS[inv.role] || inv.role) +
          " &middot; expires " + esc(fmtTokenDate(inv.expires_at)) + "</div></div>" +
      '<div class="fleet-badges">' + badge("Pending", "warn") + action + "</div></div>";
  }

  // Pure: the whole panel body — members section + (for managers) a pending-
  // invitations section. Empty member lists never happen (you're always a
  // member), but the invitations block collapses to a quiet line when empty.
  function membersPanelHtml(members, invitations, ctx) {
    var canManage = assignableRoles(ctx.role).length > 0;
    var out = "";
    out += members.map(function (m) { return memberRowHtml(m, ctx); }).join("");
    if (canManage) {
      out += '<h2 class="fleet-name" style="margin:20px 0 8px">Pending invitations</h2>';
      out += invitations.length
        ? invitations.map(function (inv) { return invitationRowHtml(inv, ctx); }).join("")
        : '<p class="dim">No pending invitations.</p>';
    }
    return out;
  }

  // Load the Members panel: resolve the team context (from /v1/me, fetching it
  // if the cache is cold), then fetch the member + invitation lists.
  function loadMembers() {
    var box = $("#members-body");
    if (!box) return;
    box.innerHTML = '<div class="loading">Loading members&hellip;</div>';
    var invite = $("#members-invite");
    if (invite) invite.hidden = true; // shown only once we know the actor can manage
    var ctx = membersContext();
    if (ctx) { fetchMembers(ctx); return; }
    api("GET", "/v1/me").then(function (r) {
      if (r.ok && r.data) meCache = r.data;
      var c = membersContext();
      if (!c) {
        box.innerHTML = '<div class="empty-state"><h2>No team yet</h2>' +
          "<p>Your account isn't part of a team, so there are no members to manage.</p></div>";
        return;
      }
      fetchMembers(c);
    });
  }

  function fetchMembers(ctx) {
    var box = $("#members-body");
    if (!box) return;
    var t = encodeURIComponent(ctx.teamId);
    var canManage = assignableRoles(ctx.role).length > 0;
    // Invitations are admin-gated — a plain member would just 403, so skip the
    // call and treat the list as empty (they see no invitations section anyway).
    var invitesReq = canManage
      ? api("GET", "/v1/teams/" + t + "/invitations")
      : Promise.resolve({ ok: true, data: { invitations: [] } });
    Promise.all([api("GET", "/v1/teams/" + t + "/members"), invitesReq]).then(function (res) {
      if (box.isConnected === false) return;
      var mr = res[0], ir = res[1];
      if (!mr.ok) {
        box.innerHTML = membersErrorHtml(mr.status);
        var rb = box.querySelector("[data-members-retry]");
        if (rb) rb.addEventListener("click", loadMembers);
        return;
      }
      var members = (mr.data && mr.data.members) || [];
      var invitations = (ir.ok && ir.data && ir.data.invitations) || [];
      var invite = $("#members-invite");
      if (invite) invite.hidden = !canManage;
      box.innerHTML = membersPanelHtml(members, invitations, ctx);
      wireMembersPanel(box, ctx);
    });
  }

  function wireMembersPanel(box, ctx) {
    box.querySelectorAll("[data-member-role]").forEach(function (b) {
      b.addEventListener("click", function () {
        openRoleModal(ctx, b.getAttribute("data-member-role"), b.getAttribute("data-email"), b.getAttribute("data-role"));
      });
    });
    box.querySelectorAll("[data-member-remove]").forEach(function (b) {
      b.addEventListener("click", function () {
        confirmRemoveMember(ctx, b.getAttribute("data-member-remove"), b.getAttribute("data-email"));
      });
    });
    box.querySelectorAll("[data-invite-revoke]").forEach(function (b) {
      b.addEventListener("click", function () {
        confirmRevokeInvite(ctx, b.getAttribute("data-invite-revoke"), b.getAttribute("data-email"));
      });
    });
  }

  // Invite: email + role → POST /v1/teams/:id/invitations. On 201 the accept_url
  // is surfaced as the operator copy-paste fallback (the invitee is also mailed
  // it server-side).
  function openInviteModal(ctx) {
    var roles = assignableRoles(ctx.role);
    if (!roles.length) return;
    var opts = roles.map(function (r) {
      return '<option value="' + esc(r) + '"' + (r === "member" ? " selected" : "") + ">" + esc(ROLE_LABELS[r]) + "</option>";
    }).join("");
    openModal(
      '<h2 class="modal-title" id="modal-title">Invite a team member</h2>' +
      '<p class="modal-sub">They\'ll be emailed an invitation link. You can also copy it here.</p>' +
      '<div class="field"><label class="label" for="invite-email">Email</label>' +
        '<input class="form-input" id="invite-email" type="email" placeholder="teammate@example.com" /></div>' +
      '<div class="field"><label class="label" for="invite-role">Role</label>' +
        '<select class="form-input" id="invite-role">' + opts + "</select></div>" +
      '<div class="modal-actions"><button class="btn btn-primary btn-block" id="invite-submit" type="button">Send invitation</button></div>'
    );
    $("#invite-submit").addEventListener("click", function () { submitInvite(ctx); });
    $("#invite-email").focus();
  }

  function submitInvite(ctx) {
    var email = ($("#invite-email").value || "").trim();
    var role = $("#invite-role").value;
    if (!email) { toast({ kind: "error", title: "Enter an email address." }); return; }
    var btn = $("#invite-submit");
    btn.disabled = true;
    btn.textContent = "Sending…";
    api("POST", "/v1/teams/" + encodeURIComponent(ctx.teamId) + "/invitations", { email: email, role: role }).then(function (r) {
      if (r.status === 201 && r.data && r.data.invitation) {
        revealInvite(r.data.accept_url, email);
        loadMembers();
      } else {
        btn.disabled = false;
        btn.textContent = "Send invitation";
        toast({ kind: "error", title: "Couldn't send invitation", body: friendly(r.data, "Check the address and try again.") });
      }
    });
  }

  // The copy-paste fallback after a successful invite — the accept link once,
  // with a copy button (the invitee is also emailed it).
  function revealInvite(url, email) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Invitation sent</h2>' +
      '<p class="modal-sub">We emailed <b>' + esc(email) + "</b> an invitation. You can also share this link:</p>" +
      '<div class="field"><input class="form-input" id="invite-link" type="text" readonly value="' + esc(url || "") + '" /></div>' +
      '<div class="modal-actions">' +
        '<button class="btn btn-ghost" id="invite-copy" type="button">Copy link</button>' +
        '<button class="btn btn-primary" type="button" data-close>Done</button>' +
      "</div>"
    );
    var copy = $("#invite-copy");
    if (copy) copy.addEventListener("click", function () {
      var input = $("#invite-link");
      if (input) input.select();
      if (navigator.clipboard && navigator.clipboard.writeText && url) {
        navigator.clipboard.writeText(url).then(
          function () { toast({ kind: "success", title: "Link copied", duration: 2000 }); },
          function () { toast({ kind: "error", title: "Couldn't copy — select and copy manually." }); }
        );
      }
    });
  }

  // Change role: PATCH /v1/teams/:id/members/:user_id {role}.
  function openRoleModal(ctx, userId, email, currentRole) {
    var roles = assignableRoles(ctx.role);
    if (!roles.length) return;
    var opts = roles.map(function (r) {
      return '<option value="' + esc(r) + '"' + (r === currentRole ? " selected" : "") + ">" + esc(ROLE_LABELS[r]) + "</option>";
    }).join("");
    openModal(
      '<h2 class="modal-title" id="modal-title">Change role</h2>' +
      '<p class="modal-sub">Set the team role for <b>' + esc(email || "this member") + "</b>.</p>" +
      '<div class="field"><label class="label" for="role-select">Role</label>' +
        '<select class="form-input" id="role-select">' + opts + "</select></div>" +
      '<div class="modal-actions">' +
        '<button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-primary" id="role-submit" type="button">Save role</button>' +
      "</div>"
    );
    $("#role-submit").addEventListener("click", function () {
      var role = $("#role-select").value;
      var btn = $("#role-submit");
      btn.disabled = true;
      btn.textContent = "Saving…";
      api("PATCH", "/v1/teams/" + encodeURIComponent(ctx.teamId) + "/members/" + encodeURIComponent(userId), { role: role }).then(function (r) {
        closeModal();
        if (r.ok) toast({ kind: "success", title: "Role updated" });
        else toast({ kind: "error", title: "Couldn't change role", body: friendly(r.data) });
        loadMembers();
      });
    });
  }

  // Remove a member: DELETE /v1/teams/:id/members/:user_id.
  function confirmRemoveMember(ctx, userId, email) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Remove member?</h2>' +
      '<p class="modal-sub">Removing <b>' + esc(email || "this member") + "</b> ends their access to the team immediately.</p>" +
      '<div class="modal-actions">' +
        '<button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" id="member-remove-go" type="button">Remove</button>' +
      "</div>"
    );
    $("#member-remove-go").addEventListener("click", function () {
      var btn = $("#member-remove-go");
      btn.disabled = true;
      btn.textContent = "Removing…";
      api("DELETE", "/v1/teams/" + encodeURIComponent(ctx.teamId) + "/members/" + encodeURIComponent(userId)).then(function (r) {
        closeModal();
        if (r.ok) toast({ kind: "success", title: "Member removed" });
        else toast({ kind: "error", title: "Couldn't remove member", body: friendly(r.data) });
        loadMembers();
      });
    });
  }

  // Revoke a pending invitation: DELETE /v1/teams/:id/invitations/:inv_id.
  function confirmRevokeInvite(ctx, invId, email) {
    openModal(
      '<h2 class="modal-title" id="modal-title">Revoke invitation?</h2>' +
      '<p class="modal-sub">The invitation for <b>' + esc(email || "this address") + "</b> will stop working.</p>" +
      '<div class="modal-actions">' +
        '<button class="btn" type="button" data-close>Cancel</button>' +
        '<button class="btn btn-danger" id="invite-revoke-go" type="button">Revoke</button>' +
      "</div>"
    );
    $("#invite-revoke-go").addEventListener("click", function () {
      var btn = $("#invite-revoke-go");
      btn.disabled = true;
      btn.textContent = "Revoking…";
      api("DELETE", "/v1/teams/" + encodeURIComponent(ctx.teamId) + "/invitations/" + encodeURIComponent(invId)).then(function (r) {
        closeModal();
        if (r.ok) toast({ kind: "success", title: "Invitation revoked" });
        else toast({ kind: "error", title: "Couldn't revoke invitation", body: friendly(r.data) });
        loadMembers();
      });
    });
  }

  // TYPE_ACTIONS.members consumer: a live members broadcast (invite / revoke /
  // role change / removal — possibly from another tab) refetches the Members
  // panel when it's the open view; otherwise it stays conservative (drop the
  // fleet cache, like the other settings ticks).
  function onMembersEvent(v) {
    fleetCache = null;
    if (v === "members") loadMembers();
  }

  // =========================================================== DEVICE LOGIN (/activate)
  // The browser half of `bp login`'s copy-link device flow (bp-login-ux W1,
  // charter decisions 5/6/10). `bp` prints https://barkpark.cloud/activate + an
  // XXXX-XXXX code and polls; the user opens that URL, we confirm WHICH machine
  // is asking (client_name / ip / user-agent), and an EXPLICIT Approve stamps
  // the request so the CLI poll can mint a session. NEVER auto-approve — a page
  // load must not authorize a device (login-CSRF defense, charter D5/D6).
  //
  // Endpoint contract (FROZEN in charter decision 10; owned by task
  // bp-login-ux-w1-cloud-device-auth — build against it even while S1 is unmerged):
  //   POST /v1/auth/device/inspect {user_code}  (Bearer) → 200 {client_name,
  //        ip_address, user_agent, expires_at} | 404 {error:"expired_or_invalid"}
  //   POST /v1/auth/device/approve {user_code}  (Bearer) → 200 {ok:true} | 404
  //   POST /v1/auth/device/deny    {user_code}  (Bearer) → 200 {ok:true} | 404
  //
  // Logged-out landings ride the invitation/instance-login precedent verbatim:
  // park the code in sessionStorage, scrub ?code= from the address bar, banner
  // the standard login card, and resume on the first authed render() — so 2FA
  // and OAuth are handled by the ordinary web login for free.
  var ACTIVATE_KEY = "bpcloud.activate";
  // charter D7: the unambiguous CSPRNG alphabet the control plane draws user_codes
  // from (no 0/1/I/L/O/U). Input normalization folds to exactly this set.
  var ACTIVATE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";

  // Pure: fold raw user input into the canonical user_code. Uppercase, drop
  // separators + anything outside the alphabet, cap at 8, render as XXXX-XXXX.
  // Sub-8 input keeps a live dash after the 4th char so typing reads naturally;
  // a complete code is the exact string the terminal printed and the wire form.
  function normalizeUserCode(raw) {
    var up = String(raw == null ? "" : raw).toUpperCase();
    var kept = "";
    for (var i = 0; i < up.length && kept.length < 8; i++) {
      if (ACTIVATE_ALPHABET.indexOf(up.charAt(i)) !== -1) kept += up.charAt(i);
    }
    if (kept.length <= 4) return kept;
    return kept.slice(0, 4) + "-" + kept.slice(4);
  }
  // Pure: a complete, sendable code is exactly 8 alphabet chars.
  function userCodeComplete(code) {
    return normalizeUserCode(code).replace("-", "").length === 8;
  }
  // Pure: pull + normalize the ?code= prefill out of a location.search string.
  // Malformed queries degrade to "" — never throw inside render().
  function activateCodeFromSearch(search) {
    var params;
    try { params = new URLSearchParams(search || ""); }
    catch (e) { return ""; }
    return normalizeUserCode(params.get("code") || "");
  }
  // Pure: fold an inspect/approve/deny response into a view state. The server
  // folds expired/unknown/consumed/denied into ONE opaque 404 (no enumeration
  // signal), so 404 → "gone"; a 200 with a body → "confirm"; else retryable.
  function activateInspectState(status, data) {
    if (status === 404) return "gone";
    if (status === 429) return "rate_limited"; // limiter tripped — honest, paused retry
    if (status === 200 && data) return "confirm";
    return "error";
  }
  // Pure: humane countdown to the code's expiry. Past/absent/unparseable → "".
  function activateExpiryText(expiresAt, nowMs) {
    if (!expiresAt) return "";
    var ms = Date.parse(expiresAt) - nowMs;
    if (isNaN(ms)) return "";
    if (ms <= 0) return "expired";
    var mins = Math.floor(ms / 60000);
    var secs = Math.floor((ms % 60000) / 1000);
    return mins > 0 ? "expires in " + mins + "m " + secs + "s" : "expires in " + secs + "s";
  }

  function isActivateFlow() { return pathClean(location.pathname) === "/activate"; }
  function activateCodePrefill() { return activateCodeFromSearch(location.search); }
  function parkedActivateCode() {
    try { return sessionStorage.getItem(ACTIVATE_KEY); } catch (e) { return null; }
  }
  function parkActivateCode(c) {
    try { sessionStorage.setItem(ACTIVATE_KEY, c); } catch (e) {}
  }
  function clearParkedActivateCode() {
    try { sessionStorage.removeItem(ACTIVATE_KEY); } catch (e) {}
  }

  function showActivateScreen() {
    hide($("#auth-screen"));
    hide($("#app-shell"));
    hide($("#new-screen"));
    show($("#activate-screen"));
  }
  function activateSetBody(html) { var b = $("#activate-body"); if (b) b.innerHTML = html; }
  function activatePanel(inner) { return '<div class="new-card card">' + inner + "</div>"; }
  function activateHead(title, desc) {
    return '<span class="new-eyebrow">Barkpark Cloud · Device sign-in</span>' +
      '<h1 class="new-title">' + esc(title) + "</h1>" +
      (desc ? '<p class="new-desc">' + desc + "</p>" : "");
  }
  function activateCodeChip(code) {
    return '<div class="rail-row"><span class="k">Code</span>' +
      '<span class="v" style="font-size:15px;letter-spacing:0.12em">' + esc(code) + "</span></div>";
  }

  // The authed approve page. Reads the ?code= prefill (parks + scrubs it — a
  // shareable secret must not linger in history), then either inspects a
  // complete parked code or shows the manual entry form.
  function renderActivateApprove() {
    showActivateScreen();
    var prefill = activateCodePrefill();
    if (prefill) parkActivateCode(prefill);
    // Scrub the code + any cosmetic hash the login round-trip left behind.
    if (typeof history !== "undefined" && history.replaceState) {
      history.replaceState(null, "", "/activate");
    }
    var code = parkedActivateCode() || "";
    if (userCodeComplete(code)) activateInspect(normalizeUserCode(code));
    else renderActivateEntry(code);
  }

  // Manual code entry (no/partial prefill, or "enter a different code").
  function renderActivateEntry(prefill) {
    activateSetBody(activatePanel(
      activateHead("Approve a device sign-in",
        "Enter the code shown in your terminal to approve <b>bp</b> signing in on this account.") +
      '<form id="activate-form" novalidate>' +
        '<div class="field"><label class="label" for="activate-code">Code</label>' +
          '<input class="form-input" id="activate-code" type="text" inputmode="text" autocomplete="off" ' +
          'autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX" ' +
          'style="font-family:var(--mono);letter-spacing:0.12em" value="' + esc(normalizeUserCode(prefill || "")) + '" /></div>' +
        '<p class="form-error" id="activate-error" role="alert" hidden></p>' +
        '<button class="btn btn-primary btn-block" id="activate-continue" type="submit">Continue</button>' +
      "</form>"
    ));
    var input = $("#activate-code");
    if (input) {
      // Live-normalize as the user types/pastes (dash + uppercase + valid chars).
      input.addEventListener("input", function () {
        var norm = normalizeUserCode(input.value);
        if (norm !== input.value) input.value = norm;
      });
      input.focus();
    }
    var form = $("#activate-form");
    if (form) form.addEventListener("submit", function (e) {
      e.preventDefault();
      var err = $("#activate-error");
      hide(err);
      var code = normalizeUserCode(($("#activate-code") || {}).value || "");
      if (!userCodeComplete(code)) { setText(err, "Enter the full 8-character code."); show(err); return; }
      parkActivateCode(code);
      activateInspect(code);
    });
  }

  // POST inspect (Bearer) → the confirm screen (or gone/error).
  function activateInspect(code) {
    activateSetBody(activatePanel(activateHead("Checking the request…", "") +
      '<div class="loading">Looking up <span style="font-family:var(--mono)">' + esc(code) + "</span>&hellip;</div>"));
    api("POST", "/v1/auth/device/inspect", { user_code: code }).then(function (r) {
      var state = activateInspectState(r.status, r.data);
      if (state === "confirm") { renderActivateConfirm(code, r.data); return; }
      if (state === "gone") { renderActivateResult("gone"); return; }
      if (state === "rate_limited") { renderActivateRateLimited(code); return; }
      renderActivateError(code, r.data);
    });
  }

  // The confirmation screen — WHICH machine is asking + explicit Approve/Deny.
  function renderActivateConfirm(code, data) {
    data = data || {};
    var expiry = activateExpiryText(data.expires_at, Date.now());
    var rows =
      activateCodeChip(code) +
      '<div class="rail-row"><span class="k">Device</span><span class="v plain">' +
        esc(data.client_name || "Unknown device") + "</span></div>" +
      (data.ip_address ? '<div class="rail-row"><span class="k">IP address</span><span class="v">' + esc(data.ip_address) + "</span></div>" : "") +
      (data.user_agent ? '<div class="rail-row"><span class="k">Client</span><span class="v plain">' + esc(data.user_agent) + "</span></div>" : "") +
      (expiry ? '<div class="rail-row"><span class="k">Expiry</span><span class="v plain">' + esc(expiry) + "</span></div>" : "");
    activateSetBody(activatePanel(
      activateHead("Approve this sign-in?",
        "A device is asking to sign in to your Barkpark Cloud account. Approve it only if you started this from your terminal.") +
      '<div class="activate-rail">' + rows + "</div>" +
      '<button class="btn btn-primary btn-block" id="activate-approve" type="button" style="margin-top:16px">Approve sign-in</button>' +
      '<button class="btn btn-ghost btn-block" id="activate-deny" type="button" style="margin-top:8px">Deny</button>' +
      '<p class="new-fineprint dim" style="margin-top:12px">Approving lets this device act as you until you revoke it. Didn\'t start this? Deny — nothing is shared.</p>'
    ));
    var approve = $("#activate-approve");
    var deny = $("#activate-deny");
    if (approve) approve.addEventListener("click", function () { submitActivateDecision(code, "approve", approve, deny); });
    if (deny) deny.addEventListener("click", function () { submitActivateDecision(code, "deny", approve, deny); });
  }

  function submitActivateDecision(code, decision, approveBtn, denyBtn) {
    if (approveBtn) approveBtn.disabled = true;
    if (denyBtn) denyBtn.disabled = true;
    var active = decision === "approve" ? approveBtn : denyBtn;
    if (active) active.textContent = decision === "approve" ? "Approving…" : "Denying…";
    api("POST", "/v1/auth/device/" + decision, { user_code: code }).then(function (r) {
      if (r.status === 200) { renderActivateResult(decision === "approve" ? "approved" : "denied"); return; }
      if (r.status === 404) { renderActivateResult("gone"); return; }
      // Transient/rate-limited failure — nothing changed; re-arm and explain.
      if (approveBtn) { approveBtn.disabled = false; approveBtn.textContent = "Approve sign-in"; }
      if (denyBtn) { denyBtn.disabled = false; denyBtn.textContent = "Deny"; }
      if (r.status === 429) {
        // Honest: the limiter tripped, not a network failure. Nothing changed —
        // the buttons are re-armed so the user can retry after a moment.
        toast({ kind: "error", title: "Too many attempts",
          body: "You're going a little fast — wait a moment, then " + decision + " again. Nothing changed." });
        return;
      }
      toast({ kind: "error", title: "Couldn't reach the server", body: friendly(r.data, "Nothing changed — please try again.") });
    });
  }

  // Terminal states. Each consumes the parked code (a reload must not replay it).
  function renderActivateResult(state) {
    clearParkedActivateCode();
    var dashboard = '<a class="btn btn-ghost btn-block" href="/" style="margin-top:8px">Go to your dashboard</a>';
    if (state === "approved") {
      activateSetBody(activatePanel(
        '<span class="new-eyebrow ok">✓ Approved</span>' +
        '<h1 class="new-title">You\'re signed in</h1>' +
        '<p class="new-desc">Return to your terminal — <b>bp</b> is finishing sign-in and will connect automatically. You can close this tab.</p>' +
        dashboard));
      return;
    }
    if (state === "denied") {
      activateSetBody(activatePanel(
        activateHead("Request denied", "Nothing was shared and no device was signed in. You can safely close this tab.") +
        dashboard));
      return;
    }
    // "gone": expired / unknown / already used.
    activateSetBody(activatePanel(
      activateHead("This code has expired or was already used",
        "Device codes are single-use and short-lived. Start again from your terminal, then enter the fresh code here.") +
      '<button class="btn btn-primary btn-block" id="activate-retry" type="button">Enter a different code</button>' +
      dashboard));
    var retry = $("#activate-retry");
    if (retry) retry.addEventListener("click", function () { renderActivateEntry(""); });
  }

  // A transient (non-404) inspect failure: retryable, code preserved.
  function renderActivateError(code, data) {
    activateSetBody(activatePanel(
      activateHead("Something went wrong",
        "We couldn't check that code just now — nothing has changed. Give it another try.") +
      '<button class="btn btn-primary btn-block" id="activate-again" type="button">Try again</button>' +
      '<button class="btn btn-ghost btn-block" id="activate-other" type="button" style="margin-top:8px">Enter a different code</button>'));
    var again = $("#activate-again");
    var other = $("#activate-other");
    if (again) again.addEventListener("click", function () { activateInspect(code); });
    if (other) other.addEventListener("click", function () { renderActivateEntry(""); });
  }

  // 429 on inspect: the limiter tripped. Honest copy, and the retry is PAUSED —
  // the button stays disabled through a short countdown so a tap can't instantly
  // re-fire inspect and re-trip the limiter (the old generic "error" screen let
  // Try-again fire immediately). Code preserved; "Enter a different code" is a
  // deliberate navigation, not an auto-retry, so it stays live.
  var ACTIVATE_RATE_WAIT_S = 15;
  function renderActivateRateLimited(code) {
    activateSetBody(activatePanel(
      activateHead("Too many attempts",
        "You've made a few requests in quick succession. Wait a moment, then try again — nothing has changed.") +
      '<button class="btn btn-primary btn-block" id="activate-again" type="button" disabled>' +
        "Try again in " + ACTIVATE_RATE_WAIT_S + "s</button>" +
      '<button class="btn btn-ghost btn-block" id="activate-other" type="button" style="margin-top:8px">Enter a different code</button>'));
    var again = $("#activate-again");
    var other = $("#activate-other");
    if (other) other.addEventListener("click", function () { renderActivateEntry(""); });
    if (again) {
      var left = ACTIVATE_RATE_WAIT_S;
      var tick = setInterval(function () {
        left -= 1;
        if (left <= 0) {
          clearInterval(tick);
          again.disabled = false;
          again.textContent = "Try again";
        } else {
          again.textContent = "Try again in " + left + "s";
        }
      }, 1000);
      again.addEventListener("click", function () { if (!again.disabled) activateInspect(code); });
    }
  }

  // The logged-out companion: a banner on the sign-in card saying what logging
  // in will do. Static copy — inspect needs auth, and probing would leak nothing
  // useful anyway (the code is a bearer-approvable secret, not a lookup key).
  function showAuthActivateBanner(code) {
    var loginCard = $("#login-card");
    if (!loginCard) return;
    var slot = document.getElementById("auth-activate");
    if (!slot) {
      slot = document.createElement("div");
      slot.id = "auth-activate";
      slot.className = "auth-invite";
      loginCard.insertBefore(slot, loginCard.firstChild);
    }
    slot.innerHTML = '<span class="auth-invite-title">Approve a device sign-in.</span> ' +
      "Log in — or create an account — to approve <b>bp</b> signing in" +
      (userCodeComplete(code) ? ' with code <span class="auth-invite-email">' + esc(normalizeUserCode(code)) + "</span>." : ".");
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

    // bp-login-ux: a device-login (/activate) round-trip through OAuth lands
    // back at the callback's fixed "/" with the user_code still parked — bounce
    // straight back to the approve page, now authed. (Email+password login stays
    // on /activate and is caught by the authed intercept just below.)
    if (didOAuth && parkedActivateCode() && session() && session().token) {
      location.href = "/activate";
      return;
    }

    // The /new deploy flow owns the whole screen when we're on that path.
    if (isNewFlow()) { renderNewFlow(); return; }

    // The /activate device-login approve page owns the whole screen once signed
    // in. Logged out, we fall through to the auth screen — the banner + park
    // below rides the normal web login (incl 2FA/OAuth), and this intercept
    // fires on the first authed render() to resume the approve.
    if (isActivateFlow() && session() && session().token) { renderActivateApprove(); return; }

    var s = session();
    if (!s || !s.token) {
      closeEvents();
      meCache = null;
      subCache = null;
      subLoaded = false;
      subError = false;
      hide($("#app-shell"));
      show($("#auth-screen"));
      // A partial 2FA challenge is abandoned by any fresh logged-out render
      // (switch-account, Back, reload): the closure token is gone, so restore
      // the login form and drop the stale card.
      hide($("#twofa-card"));

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
        // An invitation accept link (#/invitations/accept?token=…) landed while
        // logged out: park the token (sessionStorage), scrub it from the URL,
        // and say what logging in will do. The first authed render() resumes.
        var inviteTok = parseInviteToken(location.hash);
        if (inviteTok) {
          parkInviteToken(inviteTok);
          if (typeof history !== "undefined" && history.replaceState) {
            history.replaceState(null, "", location.pathname + location.search);
          }
          showAuthInviteBanner(inviteTok);
        } else if (parkedInviteToken()) {
          // e.g. back on the sign-in screen after "Switch account".
          showAuthInviteBanner(parkedInviteToken());
        }
        // An instance-login deep link (#/instance-login?url=…) landed while
        // logged out: park the origin, scrub it from the address bar, and say
        // what signing in will do. The first authed render() resumes it.
        var studioLoginUrl = studioLoginFromHash(location.hash);
        if (studioLoginUrl) {
          parkStudioLogin(studioLoginUrl);
          if (typeof history !== "undefined" && history.replaceState) {
            history.replaceState(null, "", location.pathname + location.search);
          }
          showAuthStudioBanner(studioLoginUrl);
        } else if (parkedStudioLogin()) {
          showAuthStudioBanner(parkedStudioLogin());
        }
        // A device-login deep link (/activate?code=…) landed while logged out:
        // park the code, scrub ?code= from the address bar (it's a bearer-
        // approvable secret), and banner what signing in will do. The first
        // authed render() resumes the approve — riding 2FA/OAuth for free.
        if (isActivateFlow()) {
          var actCode = activateCodePrefill();
          if (actCode) parkActivateCode(actCode);
          if (typeof history !== "undefined" && history.replaceState) {
            history.replaceState(null, "", "/activate");
          }
          showAuthActivateBanner(parkedActivateCode() || "");
        }
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
    // the URL to #billing and shows the right state. Capture the flag FIRST
    // (handleCheckoutReturn clears the query) so the launch-flow resume below can
    // tell success from cancel.
    var checkout = checkoutFlag();
    var fromCheckout = handleCheckoutReturn();

    // Invitation resume: a parked accept token (a logged-out landing that just
    // came through login / signup / OAuth) outranks whatever hash the
    // round-trip left behind — the user's intent was "accept this invite".
    // EXCEPT an explicit drill-down deep link (#site/…, #instance/…): someone
    // who just opened a specific resource asked for THAT; an undecided invite
    // stays parked and resumes on the next plain boot instead of hijacking it.
    // Instance-login resume: a pending "Log in with Barkpark Cloud" handoff —
    // on the hash if the user arrived already signed in, parked if it rode
    // through login/signup/OAuth. On success location.replace() leaves the
    // dashboard entirely; failures toast over the normal render below.
    var pendingStudioLogin = studioLoginFromHash(location.hash) || parkedStudioLogin();
    if (pendingStudioLogin) {
      if (studioLoginFromHash(location.hash) &&
          typeof history !== "undefined" && history.replaceState) {
        history.replaceState(null, "", location.pathname + location.search);
      }
      resumeStudioLogin(pendingStudioLogin);
    }

    var preInviteView = parseHash().view;
    if (parkedInviteToken() && preInviteView !== "invite" &&
        preInviteView !== "site" && preInviteView !== "instance") {
      location.hash = "#invitations/accept";
    }

    // Validate the route. Accept tab views and BOTH drill-downs (#instance/…,
    // #site/…) — the old guard reset a site deep-link to #fleet on reload.
    var r = parseHash();
    if (!fromCheckout && VIEWS.indexOf(r.view) === -1 && DETAIL_VIEWS.indexOf(r.view) === -1) {
      location.hash = "#overview";
    }
    applyRoute();

    // A4/D66 launch-flow resume: the inline plan step stashed the typed name
    // before the Stripe round-trip. On ANY checkout return, consume the stash; on
    // a success return reopen the launch modal prefilled so the user finishes in
    // one click (mirrors pendingNew for the /new flow).
    if (checkout) {
      var launchResume = null;
      try { launchResume = localStorage.getItem(LAUNCH_RETURN_KEY); } catch (e) {}
      if (launchResume != null) {
        try { localStorage.removeItem(LAUNCH_RETURN_KEY); } catch (e) {}
        if (checkout === "success") openLaunchModal(launchResume);
      }
    }
  }

  // =========================================================== COMMAND PALETTE (Cmd+K)
  // A fleet-wide launcher: every instance, site, and view two keystrokes away.
  // (metaKey||ctrlKey)+K opens a centered modal whose first focusable is a search
  // input; typing fuzzy-filters a ranked registry of nav destinations, live
  // instances, sites, and safe actions; ArrowUp/Down move the selection and Enter
  // runs it. It REUSES the shared openModal focus-trap seam — Escape + Tab are
  // already handled by the modal keydown at wireModal(), so this block only adds
  // the input re-render + Arrow/Enter. Instances come from the fleet cache
  // (ensureFleet at open) and sites from a GET /v1/sites kicked at open; both fill
  // in when they land, so the palette opens INSTANTLY on the static + instances
  // rows. Every pure helper (registry builder, fuzzy match, filter/rank, selection
  // reducer) is node-pinned via __bpTestHook. Mirrors the SHAPE of the paper-editor
  // command palette (fuzzy subsequence over label+group) but is fresh vanilla — that
  // one is TipTap-bound and not importable.

  // Pure: case-insensitive subsequence match — every char of the query appears, in
  // order, somewhere in the haystack (gaps allowed). Empty query passes everything.
  function paletteFuzzy(query, hay) {
    var q = String(query == null ? "" : query).trim().toLowerCase();
    if (!q) return true;
    var h = String(hay == null ? "" : hay).toLowerCase();
    var qi = 0;
    for (var hi = 0; hi < h.length && qi < q.length; hi++) {
      if (h[hi] === q[qi]) qi++;
    }
    return qi === q.length;
  }

  // Pure: filter + rank a registry by the query over `label + " " + group`. Empty
  // query → the registry unchanged (order-preserving). A non-empty query keeps only
  // subsequence matches, then STABLE-sorts by match quality: a haystack that
  // contains the query as a contiguous SUBSTRING outranks a mere subsequence, and an
  // earlier substring hit outranks a later one. Registry order breaks every tie, so
  // grouped rows stay grouped. Never throws; tolerates missing label/group.
  function paletteFilter(items, query) {
    items = items || [];
    var q = String(query == null ? "" : query).trim().toLowerCase();
    if (!q) return items.slice();
    var scored = [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var hay = (String((it && it.label) || "") + " " + String((it && it.group) || "")).toLowerCase();
      if (!paletteFuzzy(q, hay)) continue;
      var idx = hay.indexOf(q);
      scored.push({ it: it, score: idx === -1 ? 1e9 : idx, ord: i });
    }
    scored.sort(function (a, b) { return a.score - b.score || a.ord - b.ord; });
    return scored.map(function (s) { return s.it; });
  }

  // Pure: the selection-index reducer. Move the highlighted row over `count` rows
  // on "up"/"down" (WRAPPING), snap to ends on "home"/"end"; any other dir just
  // clamps the current index into range. count 0 → -1 (nothing selectable). Never
  // throws — an out-of-range index resets to the first row.
  function paletteMoveIndex(index, count, dir) {
    count = count | 0;
    if (count <= 0) return -1;
    var i = index | 0;
    if (i < 0 || i >= count) i = 0;
    if (dir === "down") return (i + 1) % count;
    if (dir === "up") return (i - 1 + count) % count;
    if (dir === "home") return 0;
    if (dir === "end") return count - 1;
    return i;
  }

  // Nav run(): close the palette, then route. A same-hash set fires no hashchange,
  // so re-apply the route explicitly (mirrors the launch-resume repaint seam).
  function paletteNavRun(target) {
    return function () {
      closeModal();
      if (location.hash === target) applyRoute();
      else location.hash = target;
    };
  }

  var PAL_SETTINGS_LABEL = {
    billing: "Billing", providers: "Providers",
    notifications: "Notifications", tokens: "Tokens", members: "Members",
  };

  // Pure: the STATIC nav registry — the frozen IA (D17) plus the three Fleet lenses
  // and every registered Settings view. `run` closes over paletteNavRun; the label
  // + group + kind are inspectable without invoking it.
  function paletteNavItems() {
    var nav = [
      { id: "nav-overview", label: "Overview", group: "Go to", target: "#overview" },
      { id: "nav-fleet", label: "Fleet", group: "Go to", target: "#fleet" },
      { id: "nav-fleet-attention", label: "Fleet · needs attention", group: "Go to", target: "#fleet/attention" },
      { id: "nav-fleet-inflight", label: "Fleet · in flight", group: "Go to", target: "#fleet/inflight" },
      { id: "nav-fleet-healthy", label: "Fleet · healthy", group: "Go to", target: "#fleet/healthy" },
      { id: "nav-sites", label: "Sites", group: "Go to", target: "#sites" },
      { id: "nav-activity", label: "Activity", group: "Go to", target: "#activity" },
    ];
    SETTINGS_VIEWS.forEach(function (v) {
      nav.push({ id: "nav-settings-" + v, label: "Settings · " + (PAL_SETTINGS_LABEL[v] || v),
        group: "Settings", target: "#settings/" + v });
    });
    return nav.map(function (n) {
      return { id: n.id, label: n.label, group: n.group, kind: "nav", run: paletteNavRun(n.target) };
    });
  }

  // Pure: the safe-action registry — existing functions ONLY (no new behavior). The
  // launch/account actions open their own modal (openModal replaces the palette body
  // in place); the theme toggle has no modal, so it closes the palette itself.
  function paletteActionItems() {
    return [
      { id: "act-launch", label: "Launch a new instance", group: "Actions", hint: "New", kind: "action",
        run: function () { openLaunchModal(); } },
      { id: "act-theme", label: "Toggle light / dark theme", group: "Actions", kind: "action",
        run: function () { toggleTheme(); closeModal(); } },
      { id: "act-account", label: "Account & sessions", group: "Actions", kind: "action",
        run: function () { openAccountModal(); } },
    ];
  }

  // Pure: instance rows from the fleet list — label = display name, hint = the ONE
  // status pill's label (statusOf), run drills into #instance/<id>.
  function paletteInstanceItems(list) {
    return (list || []).map(function (bp) {
      return {
        id: "inst-" + String(bp && bp.id),
        label: String((bp && (bp.name || bp.slug || bp.id)) || "instance"),
        group: "Instances",
        hint: statusOf(bp).label,
        kind: "nav",
        run: paletteNavRun("#instance/" + encodeURIComponent(String(bp && bp.id))),
      };
    });
  }

  // Pure: site rows — label = primary domain (slug/name/id fallbacks), hint = the
  // framework, run drills into #site/<id>.
  function paletteSiteItems(list) {
    return (list || []).map(function (s) {
      var domain = (s && s.domains && s.domains[0]) || (s && (s.slug || s.name)) || String(s && s.id);
      return {
        id: "site-" + String(s && s.id),
        label: String(domain),
        group: "Sites",
        hint: s && s.framework ? String(s.framework) : "site",
        kind: "nav",
        run: paletteNavRun("#site/" + encodeURIComponent(String(s && s.id))),
      };
    });
  }

  // Pure: the full registry for a data snapshot. Order = static nav, actions,
  // instances, sites — so the palette paints a complete slate the instant it opens
  // (static + cached instances) and sites slot in when their fetch lands.
  function paletteRegistry(data) {
    data = data || {};
    return paletteNavItems()
      .concat(paletteActionItems())
      .concat(paletteInstanceItems(data.instances))
      .concat(paletteSiteItems(data.sites));
  }

  function paletteRowsHtml(items, index) {
    if (!items.length) return '<div class="cmdk-empty">No matches</div>';
    return items.map(function (it, i) {
      var active = i === index;
      return '<div class="cmdk-row' + (active ? " is-active" : "") + '" role="option"' +
        ' id="cmdk-row-' + i + '" data-i="' + i + '"' + (active ? ' aria-selected="true"' : "") + ">" +
        '<span class="cmdk-row-label">' + esc(it.label) + "</span>" +
        '<span class="cmdk-row-meta">' +
          (it.hint ? '<span class="cmdk-row-hint">' + esc(it.hint) + "</span>" : "") +
          '<span class="cmdk-row-group">' + esc(it.group || "") + "</span>" +
        "</span>" +
      "</div>";
    }).join("");
  }

  function paletteBodyHtml() {
    return '<div class="cmdk">' +
      '<div class="cmdk-search-wrap">' +
        '<input class="cmdk-search" id="cmdk-input" type="text" role="combobox"' +
        ' aria-expanded="true" aria-controls="cmdk-list" aria-activedescendant=""' +
        ' autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"' +
        ' placeholder="Search instances, sites, and actions…" aria-label="Command palette search" />' +
      "</div>" +
      '<div class="cmdk-list" id="cmdk-list" role="listbox" aria-label="Commands"></div>' +
      '<div class="cmdk-foot">' +
        '<span class="cmdk-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate</span>' +
        '<span class="cmdk-hint"><kbd>↵</kbd> select</span>' +
        '<span class="cmdk-hint"><kbd>esc</kbd> close</span>' +
      "</div>" +
    "</div>";
  }

  // Generation guard: a second open supersedes the first, so a late ensureFleet /
  // sites resolve from a stale palette never repaints the live one.
  var paletteGen = 0;

  function openCommandPalette() {
    var root = document.getElementById("modal-root");
    if (root && !root.hidden) return; // one modal root — never stack over an open dialog
    var gen = ++paletteGen;

    // Instant slate: static nav + actions + whatever fleet is already cached.
    var data = { instances: Array.isArray(fleetCache) ? fleetCache : [], sites: [] };
    var items = paletteRegistry(data);
    var visible = items.slice();
    var index = items.length ? 0 : -1;

    var body = openModal(paletteBodyHtml());
    if (!body) return;
    var input = document.getElementById("cmdk-input");
    var listEl = document.getElementById("cmdk-list");
    if (!input || !listEl) return;

    function alive() {
      if (gen !== paletteGen) return false;
      var r = document.getElementById("modal-root");
      return !!(r && !r.hidden);
    }
    function repaint() {
      visible = paletteFilter(items, input.value);
      index = paletteMoveIndex(index, visible.length, null); // clamp into the new range
      listEl.innerHTML = paletteRowsHtml(visible, index);
      input.setAttribute("aria-activedescendant", index >= 0 ? "cmdk-row-" + index : "");
      var activeRow = listEl.querySelector(".cmdk-row.is-active");
      if (activeRow && activeRow.scrollIntoView) activeRow.scrollIntoView({ block: "nearest" });
    }
    function rebuild() {
      if (!alive()) return;
      items = paletteRegistry(data);
      repaint();
    }
    function runSelected() {
      var it = visible[index];
      if (it && typeof it.run === "function") it.run();
    }

    repaint();

    input.addEventListener("input", function () { index = 0; repaint(); });
    // Arrow/Enter live on the modal body; Escape + Tab stay owned by wireModal().
    body.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); index = paletteMoveIndex(index, visible.length, "down"); repaint(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); index = paletteMoveIndex(index, visible.length, "up"); repaint(); }
      else if (e.key === "Home" && !input.value) { e.preventDefault(); index = paletteMoveIndex(index, visible.length, "home"); repaint(); }
      else if (e.key === "End" && !input.value) { e.preventDefault(); index = paletteMoveIndex(index, visible.length, "end"); repaint(); }
      else if (e.key === "Enter") { e.preventDefault(); runSelected(); }
    });
    listEl.addEventListener("click", function (e) {
      var row = e.target.closest && e.target.closest(".cmdk-row[data-i]");
      if (!row) return;
      var it = visible[parseInt(row.getAttribute("data-i"), 10)];
      if (it && typeof it.run === "function") it.run();
    });

    // Fill instances in when the fleet wasn't cached, and sites always (no cache
    // exists). Both re-render on arrival; a failed load simply omits that group —
    // the palette stays usable for everything else (never a dead spinner).
    if (!data.instances.length) {
      ensureFleet().then(function (list) {
        if (Array.isArray(list) && list.length) { data.instances = list; rebuild(); }
      });
    }
    api("GET", "/v1/sites").then(function (r) {
      data.sites = (r.ok && r.data && r.data.sites) || [];
      rebuild();
    });
  }

  // =========================================================== WIRE-UP
  function init() {
    initTheme();
    initBpTheme();
    renderThemePicker(); // v4: the identity <select> is generated from BP_THEMES
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
    var bpPicker = $("#bp-theme-picker");
    if (bpPicker) bpPicker.addEventListener("change", function () { selectBpTheme(bpPicker.value); });
    $("#acct-btn").addEventListener("click", openAccountModal);
    // v4 sidebar: the workspace switcher opens the same Account modal (team +
    // sessions live there); Find/⌘K opens the EXISTING command palette (never a
    // fork — reuses openCommandPalette's #modal-root machinery).
    var wsSwitch = $("#ws-switch");
    if (wsSwitch) wsSwitch.addEventListener("click", openAccountModal);
    var navFind = $("#nav-find");
    if (navFind) navFind.addEventListener("click", openCommandPalette);
    // v4 topbar: the instance-scope dropdown (a fleet jumper over the router).
    var scopeSwitch = $("#scope-switch");
    if (scopeSwitch) scopeSwitch.addEventListener("click", function (e) {
      e.stopPropagation();
      toggleScopeMenu();
    });
    // Outside-click closes the scope dropdown (mirrors the .nav-menu handler).
    document.addEventListener("click", function (e) {
      var menu = $("#scope-menu");
      if (menu && !menu.hidden && !(e.target.closest && e.target.closest(".topbar-scope"))) {
        toggleScopeMenu(false);
      }
    });

    // Views. A4/D66: Launch is an ACTION — the Overview and Fleet header buttons
    // open the launch component in the focus-trapped modal.
    var ovLaunch = $("#overview-launch");
    if (ovLaunch) ovLaunch.addEventListener("click", function () { openLaunchModal(); });
    var flLaunch = $("#fleet-launch");
    if (flLaunch) flLaunch.addEventListener("click", function () { openLaunchModal(); });
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
    $("#provider-add").addEventListener("click", openProviderPicker);
    $("#provider-add-empty").addEventListener("click", openProviderPicker);
    $("#token-add").addEventListener("click", openTokenModal);
    // C10: the Members panel's invite button — reads the team context at click.
    var membersInvite = $("#members-invite");
    if (membersInvite) membersInvite.addEventListener("click", function () {
      var c = membersContext();
      if (c) openInviteModal(c);
    });

    window.addEventListener("hashchange", function () {
      if (isNewFlow()) return; // the /new deploy flow is path+query driven, not hash-routed
      if (isActivateFlow()) return; // the /activate device-login screen is real-path, not hash-routed
      if (session() && session().token) applyRoute();
    });

    // Cmd/Ctrl+K — the global command palette. preventDefault is UNCONDITIONAL for
    // the combo (Ctrl+K is readline kill-line inside inputs — never let it fire);
    // opening then no-ops while any modal is open (one modal root), before sign-in,
    // and on the real-path /new + /activate screens (which render outside the shell).
    document.addEventListener("keydown", function (e) {
      if ((e.key === "k" || e.key === "K") && (e.metaKey || e.ctrlKey) && !e.altKey) {
        e.preventDefault();
        var mroot = document.getElementById("modal-root");
        if (mroot && !mroot.hidden) return;
        if (isNewFlow() || isActivateFlow()) return;
        if (!(session() && session().token)) return;
        openCommandPalette();
      }
    });

    // /new screen has its own theme toggle (it renders outside the app shell).
    var newTheme = $("#new-theme-toggle");
    if (newTheme) newTheme.addEventListener("click", toggleTheme);
    // /activate screen likewise renders outside the app shell — its own toggle.
    var activateTheme = $("#activate-theme-toggle");
    if (activateTheme) activateTheme.addEventListener("click", toggleTheme);

    render();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // >>> BEGIN coherence-helpers — MIRRORED VERBATIM into __preview__/coherence.html.
  //     Drift is a test failure (see __app.test.mjs "coherence helper block is
  //     byte-identical in app.js and coherence.html"). Depends only on esc(),
  //     which is in scope in both files. Pure: no DOM, no globals. These back the
  //     S5 four-surface coherence harness — the human sign-off gate for the
  //     Unified Aesthetic. >>>
  var COHERENCE_TOKENS = [
    "--primary", "--primary-fg", "--accent",
    "--ok", "--warn", "--danger", "--info",
    "--bg", "--surface", "--text", "--muted-text", "--border",
  ];

  // The four lifecycle roles the TUI golden fixtures colorize, mapped to the one
  // token vocabulary. "ok" is health-green; danger/warn/info round it out.
  var COHERENCE_ROLES = ["info", "warn", "ok", "danger"];

  // light/dark is a single bit — flip it. Kept a function so the toggle and the
  // tests share one definition of "the other theme".
  function coherenceNextTheme(cur) {
    return cur === "dark" ? "light" : "dark";
  }

  // Stamp data-theme on every pane root so ONE toggle cascades to all surfaces —
  // including a same-origin iframe's documentElement. Roots may be null (an
  // iframe still loading, an absent pane): those are skipped, never thrown on.
  // Returns the count actually stamped (honest: 0 while nothing is mounted yet).
  function coherenceStampTheme(theme, roots) {
    var stamped = 0;
    (roots || []).forEach(function (root) {
      if (!root) return;
      if (typeof root.setAttribute === "function") {
        root.setAttribute("data-theme", theme);
        stamped++;
      } else if (root.dataset) {
        root.dataset.theme = theme;
        stamped++;
      }
    });
    return stamped;
  }

  // Build the token-manifest rows from a live reader (browser: a closure over
  // getComputedStyle(root).getPropertyValue). Never hand-copies a hex — an
  // unresolved var surfaces as { empty: true } so a missing token reads as a
  // gap, not a fabricated color.
  function coherenceTokenRows(readVar, names) {
    var list = names || COHERENCE_TOKENS;
    return list.map(function (name) {
      var raw = readVar ? readVar(name) : "";
      var value = String(raw == null ? "" : raw).trim();
      return { name: name, value: value, empty: value === "" };
    });
  }

  // Transform a committed TUI golden fixture (taskboard/pdrender styleguide .txt)
  // into styled <pre> HTML: escape everything, then paint the emitted lifecycle
  // role words with .bp-lc-<role> (the shared token classes) and wrap each
  // #rrggbb cell in a color chip. Deterministic + escaping-safe so the terminal
  // surface shows on-screen in the same vocabulary as the other three.
  function coherenceFixtureToHtml(text) {
    var out = esc(text == null ? "" : text);
    out = out.replace(/\b(info|warn|ok|danger)\b/g, function (word) {
      return '<span class="bp-lc-' + word + '">' + word + "</span>";
    });
    out = out.replace(/#[0-9a-fA-F]{6}\b/g, function (hex) {
      return '<span class="bp-lc-hex" style="--hex:' + hex + '">' + hex + "</span>";
    });
    return out;
  }
  // <<< END coherence-helpers <<<

  // scaffy:zone console-helpers (ensure-console-hook-zones) -- stable head
  // anchor for NEW node-pinned pure helpers: declare your `function name(...)`
  // DIRECTLY BELOW this comment. Position is semantics-free by construction:
  // declarations are scoped to the enclosing IIFE and the __bpTestHook call
  // below runs at eval tail, so a helper landing here is visible to the hook
  // and to every earlier call site (hoisting). Keep helpers PURE (no DOM, no
  // fetch, no EventSource) -- the house law stamped on every hook group: pure
  // helpers node-pinned, DOM mounts browser-verified. Sweeps: move this
  // comment only whole, on its own lines. MARK:zone-console-helpers

  // Test-only escape hatch (same pattern as the sheet-grid hook): a node:vm
  // harness (__app.test.mjs) sets __bpTestHook to grab the pure helpers. Absent
  // in a real browser, so this is a no-op in production.
  if (typeof globalThis !== "undefined" && typeof globalThis.__bpTestHook === "function") {
    globalThis.__bpTestHook({
      esc: esc, safeDecode: safeDecode, parseHash: parseHash, relTime: relTime,
      // search-template W2 (D8): create-site modal pure helpers.
      siteKindFor: siteKindFor, siteTemplateOptions: siteTemplateOptions,
      siteCreateBody: siteCreateBody,
      // search-template W8: site theme-edit pure helpers.
      siteThemeOptionsHtml: siteThemeOptionsHtml, siteThemePatchBody: siteThemePatchBody,
      // "Log in with Barkpark Cloud" (instance-login deep link): parse + match.
      studioLoginFromHash: studioLoginFromHash, studioLoginHost: studioLoginHost,
      studioLoginMatch: studioLoginMatch,
      // bp-login-ux W3 — shared two-factor challenge card (decision 39): the two
      // pure classifiers (login-response kind + challenge outcome), the card
      // markup, the error copy, and the mount seam (driven with a stubbed fetch,
      // mountTimelineTab-style). The challenge_token stays in the mount closure.
      loginResponseKind: loginResponseKind, twoFactorChallengeOutcome: twoFactorChallengeOutcome,
      twoFactorCardHtml: twoFactorCardHtml, twoFactorErrorCopy: twoFactorErrorCopy,
      mountTwoFactorCard: mountTwoFactorCard, twoFactorRateWaitS: TFA_RATE_WAIT_S,
      // bp-login-ux W1 — /activate device-login approve page pure helpers.
      normalizeUserCode: normalizeUserCode, userCodeComplete: userCodeComplete,
      activateCodeFromSearch: activateCodeFromSearch, activateInspectState: activateInspectState,
      activateExpiryText: activateExpiryText, activateAlphabet: ACTIVATE_ALPHABET,
      // bp-login-ux W2 — tolerant real-path matcher (trailing-slash safe) + the
      // two predicates it backs, so the harness can pin /activate/ ≡ /activate.
      pathClean: pathClean, isActivateFlow: isActivateFlow, isNewFlow: isNewFlow,
      // bp-login-ux W3 (decision 40) — the /activate render functions, exported so
      // __app.test.mjs can DOM-test each state via the fakeDom() swap idiom. The
      // click-driven approved/denied terminals aren't smokeable (smoke's click() is
      // inert), so renderActivateResult('approved'|'denied') is called directly.
      renderActivateEntry: renderActivateEntry, renderActivateConfirm: renderActivateConfirm,
      renderActivateResult: renderActivateResult, renderActivateError: renderActivateError,
      renderActivateRateLimited: renderActivateRateLimited,
      failureCopy: failureCopy, failureTone: failureTone, liveEventTypes: Object.keys(TYPE_ACTIONS),
      // C2/D45: the /new timeline's step vocabulary — pinned against the Go
      // worker's report vocabulary + the ProvisionJob @steps whitelist.
      serverStepOrder: SERVER_STEP_ORDER, serverStepLabels: SERVER_STEP_LABELS,
      // Progress-polish: per-phase pacing (ring estimates), the fallback-step
      // set, and the between-steps `next` marker.
      serverStepExpectedMs: SERVER_STEP_EXPECTED_MS, serverStepOptional: SERVER_STEP_OPTIONAL,
      stepRingProgress: stepRingProgress, markNextStep: markNextStep,
      SERVER_STEP_EXPECTED_MS: SERVER_STEP_EXPECTED_MS,
      // Presentation pacing (min-dwell): pure display shim + the resume seed.
      paceSteps: paceSteps, seedPaceLedger: seedPaceLedger,
      newStepMinDwellMs: NEW_STEP_MIN_DWELL_MS,
      // Overall master bar (provisioning-ui upgrade): pure model + markup.
      provisionOverall: provisionOverall, provisionOverallHtml: provisionOverallHtml,
      // Zero-paste Vercel handoff (task-4e4a53b101a97051): the claim-area builders.
      vercelClaimHtml: vercelClaimHtml, vercelClaimLinkHtml: vercelClaimLinkHtml,
      vercelCloneUrl: vercelCloneUrl,
      // Guided fallback (no platform token): per-field copy + Deploy.
      vercelFallbackHtml: vercelFallbackHtml, vercelEnvRows: vercelEnvRows,
      deployIsActive: deployIsActive, deployIsPreClaim: deployIsPreClaim,
      deployDetailHtml: deployDetailHtml, deployConsoleHtml: deployConsoleHtml,
      // A4 onboarding narrative (D56/D57/D60/D66): the launch component + runway +
      // ready-fold pure helpers.
      wantsLaunchFlow: wantsLaunchFlow, runwaySubline: runwaySubline,
      welcomeHeroHtml: welcomeHeroHtml, launchedHash: launchedHash,
      launchFlowReducer: launchFlowReducer, readyFoldTrigger: readyFoldTrigger,
      readyHeroHtml: readyHeroHtml, railValue: railValue,
      // S7 (azure-hetzner hosting parity): the Azure card + verified-connect +
      // priced neutral launch-catalog pure helpers. Every branch a node-pinned
      // pure function; the DOM mount (mountLaunchCatalog) is browser-verified.
      providerChipHtml: providerChipHtml, instanceLifecycleClass: instanceLifecycleClass,
      azureFieldsValid: azureFieldsValid, providerCredBody: providerCredBody,
      // friendly is exported so the harness can PROVE it drops .remediation (the
      // connect sheet must never route the server copy through it).
      remediationCopy: remediationCopy, friendly: friendly, formatMonthlyPrice: formatMonthlyPrice,
      catalogViewState: catalogViewState, serverTypeLabel: serverTypeLabel,
      defaultCatalogSelection: defaultCatalogSelection, launchBody: launchBody,
      launchProviderTabsHtml: launchProviderTabsHtml, catalogRegionsHtml: catalogRegionsHtml,
      catalogSizeRowsHtml: catalogSizeRowsHtml, catalogPanelHtml: catalogPanelHtml,
      azureFieldKeys: AZURE_FIELDS.map(function (f) { return f.key; }),
      availableProviderKinds: PROVIDERS.filter(function (p) { return p.available; }).map(function (p) { return p.kind; }),
      // S11b (azure-hetzner hosting): the console lifecycle action-row pure
      // helpers — the S4 pill state mapper, the conduit-driven action model, its
      // render, the fleet infra line, the row gate, and the optimistic reducer.
      // The DOM mount (wireLifecycleActions/runDecommission) is browser-verified.
      lifecyclePillState: lifecyclePillState, lifecyclePill: lifecyclePill,
      fleetInfraLine: fleetInfraLine, showLifecycleRow: showLifecycleRow,
      lifecycleActionsModel: lifecycleActionsModel, lifecycleActionRowHtml: lifecycleActionRowHtml,
      lifecycleOptimistic: lifecycleOptimistic, lifecycleVerbs: LIFECYCLE_VERBS.map(function (v) { return v.verb; }),
      // isu-w5 console operator update panel: the per-instance update-truth
      // derivations + the 409 pin-force flow + the fleet rollout banner. All pure
      // (node-pinned); the DOM mounts (wireUpdatePanel/openPinModal/loadFleetRollout)
      // are browser-verified. Every helper degrades gracefully against an older CP.
      hasAutoupdatePolicy: hasAutoupdatePolicy, updateBadge: updateBadge,
      lastCheckedText: lastCheckedText, autoupdatePolicyLabel: autoupdatePolicyLabel,
      autoupdateActions: autoupdateActions, updateConflict: updateConflict,
      updateConflictCopy: updateConflictCopy, forceUpdateBody: forceUpdateBody,
      updatePanelHtml: updatePanelHtml, fleetRolloutBanner: fleetRolloutBanner,
      fleetRolloutBannerHtml: fleetRolloutBannerHtml,
      // isu-w6 console instance-rollback: the confirm-modal HTML builder + the
      // typed-conflict copy classifier. Both pure (node-pinned); the DOM mounts
      // (confirmRollbackInstance/rollbackInstance, wired via wireUpdatePanel) are
      // browser-verified. rollbackConfirmHtml escapes the server-supplied name.
      rollbackConfirmHtml: rollbackConfirmHtml, rollbackConflictCopy: rollbackConflictCopy,
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
      // Theme IDENTITY picker (D36): normalize (unknown → evergreen) + the DOM
      // stamp (returns the applied id). The known-theme list is pinned too.
      normalizeBpTheme: normalizeBpTheme, applyBpTheme: applyBpTheme,
      bpThemes: BP_THEMES.slice(),
      // C3 provisioning timeline: the one fold + its three presentations + the
      // fake-DOM mount seam (the wiring smoke drives mountInstanceTimeline).
      provisionSteps: provisionSteps, stepElapsed: stepElapsed, fmtDur: fmtDur,
      provisionTotalMs: provisionTotalMs, provisionChip: provisionChip,
      newStepsHtml: newStepsHtml, timelineHtml: timelineHtml, consoleTail: consoleTail,
      instanceTimelineHtml: instanceTimelineHtml, mountInstanceTimeline: mountInstanceTimeline,
      // C6 instance-workspace tabs + the Webhooks tab (charter D49/D46/D51/D18/D5).
      instanceTabOf: instanceTabOf, instanceTabs: INSTANCE_TABS.slice(),
      instanceDetailHtml: instanceDetailHtml, instanceTabStripHtml: instanceTabStripHtml,
      webhookCliChip: webhookCliChip, cliChipHtml: cliChipHtml,
      webhookEventsHtml: webhookEventsHtml, webhookBannerHtml: webhookBannerHtml,
      webhookCardHtml: webhookCardHtml, deliveryTone: deliveryTone,
      deliveryRowHtml: deliveryRowHtml, hookToggleState: hookToggleState,
      webhookErrorHtml: webhookErrorHtml, webhookMutationError: webhookMutationError,
      whPath: whPath, webhooksTabShellHtml: webhooksTabShellHtml, mountWebhooksTab: mountWebhooksTab,
      // w6 (OC25): full webhook edit — the pre-fill form + the PUT-body builder.
      webhookEventPickHtml: webhookEventPickHtml, webhookEditFormHtml: webhookEditFormHtml,
      webhookEditBody: webhookEditBody,
      // cloud-console-spa-interaction-harness — existing action seams only.
      // The hook guard above is absent in browsers, so exporting these references
      // adds no production branch and leaves every route/wire contract unchanged.
      wireWebhookCard: wireWebhookCard, toggleWebhook: toggleWebhook,
      rotateWebhook: rotateWebhook, openEditWebhookModal: openEditWebhookModal,
      submitEditWebhook: submitEditWebhook, confirmDeleteWebhook: confirmDeleteWebhook,
      deleteWebhook: deleteWebhook, loadDeliveries: loadDeliveries,
      replayDelivery: replayDelivery,
      // Zero-broken-promises slice (charter D5/D7/D25/D26): the shared confirm
      // modal (pure state machine + focus-trap seam), the promote grammar
      // (rollback/redeploy), and the invitation-accept landing.
      confirmModalInit: confirmModalInit, confirmModalReduce: confirmModalReduce,
      confirmModalArmed: confirmModalArmed, confirmModalTypedMatch: confirmModalTypedMatch,
      confirmModalHtml: confirmModalHtml, trapTarget: trapTarget,
      promotePath: promotePath, promoteActionFor: promoteActionFor,
      promoteConfirmCopy: promoteConfirmCopy, promoteFailure: promoteFailure,
      deployRefLabel: deployRefLabel, deployRow: deployRow,
      // Rollback endgame: the post-promote reconcile (Current chip stays put
      // until the new build is live) + the loadInstanceSites stale-paint guard.
      promoteReconcile: promoteReconcile, deployListHtml: deployListHtml,
      staleGuard: staleGuard,
      // stw5 (charter D25/D28): the SITE-level synchronous rollback (distinct from the
      // per-row async promote) + the capped deploy-history render. Only the PURE
      // path/fold/copy/markup helpers are node-pinned; confirmSiteRollback /
      // runSiteRollback (openModal + api + toast) are browser-verified.
      siteRollbackPath: siteRollbackPath, siteRollbackConfirmHtml: siteRollbackConfirmHtml,
      siteRollbackResult: siteRollbackResult, siteRollbackFailure: siteRollbackFailure,
      siteRollbackFlashView: siteRollbackFlashView, deployRollbackBannerHtml: deployRollbackBannerHtml,
      deployTriggerLabel: deployTriggerLabel,
      // W4 (charter D15-D17/D18): the SSE-driven deploy stage rail + one-motion
      // create-and-deploy. Only the PURE fold/signature/status/markup helpers are
      // node-pinned; the EventSource wiring + DOM mount are browser-verified.
      deployStageRole: deployStageRole, deployRailLedgerFromConsole: deployRailLedgerFromConsole,
      deployRailRows: deployRailRows, deployRailSignature: deployRailSignature,
      deployRailStatus: deployRailStatus, deployRailHtml: deployRailHtml,
      railDeployment: railDeployment, instanceCanDeploy: instanceCanDeploy,
      deployRailStages: DEPLOY_RAIL_STAGES.slice(),
      // stw4-freshness (charter D24): the site-row deploy-freshness badge — pure
      // model + markup. Amber-pulse only while a content-auto rebuild is in
      // flight; nil-honest for a never-deployed site.
      freshnessModel: freshnessModel, freshnessBadge: freshnessBadge,
      parseInviteToken: parseInviteToken, inviteLandingState: inviteLandingState,
      inviteTerminalFrom: inviteTerminalFrom, inviteStateHtml: inviteStateHtml,
      // C8 instance Timeline + golden-path verify chips (charter D10/D18/D25/D33/D53).
      mergeTimeline: mergeTimeline, auditMirrorsEvent: auditMirrorsEvent,
      tlvEntryTitle: tlvEntryTitle, tlvRowHtml: tlvRowHtml, tlvDetailHtml: tlvDetailHtml,
      timelineFeedHtml: timelineFeedHtml, timelineTabShellHtml: timelineTabShellHtml,
      mountTimelineTab: mountTimelineTab,
      latestVerifyOf: latestVerifyOf, probeChipsModel: probeChipsModel,
      verifySummaryText: verifySummaryText, verifyChipHtml: verifyChipHtml,
      verifyCardHtml: verifyCardHtml, verifyNoteHtml: verifyNoteHtml,
      verifyProbes: VERIFY_PROBES.map(function (p) { return { name: p.name, label: p.label }; }),
      // S13 (azure-hetzner hosting): the per-host domain DNS/TLS checklist. Only
      // the pure fold (domainStages) + its render are node-pinned; the DOM mount
      // (loadInstanceDomains) + 4s poll are browser-verified.
      domainStages: domainStages, domainStageRows: domainStageRows,
      domainChecklistHtml: domainChecklistHtml, domainRungChip: domainRungChip,
      domainKindChip: domainKindChip,
      // S12 (azure-hetzner hosting): the Metrics tab. Only the pure fold
      // (metricsSeries) + the string-returning SVG sparkline (sparklineSvg) + the
      // render helpers are node-pinned; the DOM mount (mountMetricsTab) + 4s poll
      // are browser-verified.
      metricsSeries: metricsSeries, sparklineSvg: sparklineSvg,
      metricsAgeText: metricsAgeText, metricsValueText: metricsValueText,
      metricsPanelHtml: metricsPanelHtml, metricsCardHtml: metricsCardHtml,
      metricsHealthHtml: metricsHealthHtml, metricsKeys: METRIC_SPECS.map(function (s) { return s.key; }),
      // S14 (azure-hetzner hosting): the archives panel. Only the pure projection
      // (archivesModel) + its render helpers are node-pinned; the DOM mount
      // (loadArchives) is browser-verified.
      archivesModel: archivesModel, archiveRowHtml: archiveRowHtml,
      archivesPanelHtml: archivesPanelHtml,
      // azh-w7: the console Resurrect flow. Only the pure request/outcome/sheet
      // builders are node-pinned; the modal mount (openResurrectModal) + its
      // hand-off to the /new step feed are browser-verified.
      resurrectRequestBody: resurrectRequestBody, resurrectOutcome: resurrectOutcome,
      resurrectModalHtml: resurrectModalHtml,
      // Liveness chip (OC6): topbar SSE health dot + honest "as of" freshness.
      // Pure state helpers + the DOM seams (fake-DOM smoke drives the mount/paint,
      // the same way mountInstanceTimeline is exercised — real browser is live).
      liveDotState: liveDotState, liveFreshness: liveFreshness,
      liveStaleMs: LIVE_STALE_MS,
      ensureLivenessChip: ensureLivenessChip, renderLivenessChip: renderLivenessChip,
      // S5 four-surface coherence harness (__preview__/coherence.html): the pure
      // theme-propagation / token-manifest / fixture-transform helpers. The block
      // is mirrored verbatim into that page; a drift test pins the two copies.
      coherenceNextTheme: coherenceNextTheme, coherenceStampTheme: coherenceStampTheme,
      coherenceTokenRows: coherenceTokenRows, coherenceFixtureToHtml: coherenceFixtureToHtml,
      coherenceTokens: COHERENCE_TOKENS.slice(), coherenceRoles: COHERENCE_ROLES.slice(),
      // C10: Members settings panel + Usage instance sub-tab. Pure helpers the
      // node harness drives directly (the DOM mount/wiring is browser-verified).
      usageMeters: USAGE_METERS.map(function (m) { return { key: m.key, label: m.label, fmt: m.fmt }; }),
      c10FmtBytes: c10FmtBytes, usageMeterDisplay: usageMeterDisplay,
      usageMeterHtml: usageMeterHtml, usageMetersHtml: usageMetersHtml,
      // Wave 4 (OC19): the 14-day sparkline read path. usageHistorySeries
      // normalises the /usage/history envelope; usageHistoryValues extracts one
      // meter's value|null array for sparklineSvg (null-is-gap preserved).
      usageHistorySeries: usageHistorySeries, usageHistoryValues: usageHistoryValues,
      usageTabShellHtml: usageTabShellHtml, usageFailureCopy: usageFailureCopy,
      assignableRoles: assignableRoles, membersFailureCopy: membersFailureCopy,
      memberRowHtml: memberRowHtml, invitationRowHtml: invitationRowHtml,
      membersPanelHtml: membersPanelHtml,
      // Wave 3 (OC16/OC18): the Overview fleet usage strip. Pure model + render
      // helpers node-pinned; the DOM mount (loadFleetUsageStrip) is browser-
      // verified. fleetStripModel does the headline-subset selection + worst-state
      // fold; the strip meter subset is exported so the harness pins its names.
      fleetStripMeters: FLEET_STRIP_METERS.map(function (m) { return m.key; }),
      fleetStripModel: fleetStripModel, fleetStripWorst: fleetStripWorst,
      fleetStripCellHtml: fleetStripCellHtml, fleetStripHtml: fleetStripHtml,
      // OC7: the registered Settings views, so the quota bar's "Manage plan"
      // recovery route can be proved to land on a real view (never a dead end).
      settingsViews: SETTINGS_VIEWS.slice(),
      // Cmd+K command palette (wave 3): pure registry builder + fuzzy match +
      // filter/rank + selection reducer. The DOM mount (openCommandPalette) and its
      // Cmd/Ctrl+K keydown are browser-verified; these helpers are node-pinned.
      paletteFuzzy: paletteFuzzy, paletteFilter: paletteFilter,
      paletteMoveIndex: paletteMoveIndex, paletteNavItems: paletteNavItems,
      paletteActionItems: paletteActionItems, paletteInstanceItems: paletteInstanceItems,
      paletteSiteItems: paletteSiteItems, paletteRegistry: paletteRegistry,
      // scaffy:zone console-hook-map (ensure-console-hook-zones) -- stable
      // tail anchor for NEW hook entries: add `name: name,` DIRECTLY BELOW
      // this comment (trailing comma -- house style keeps one on every entry,
      // so the append is separator-safe; object keys are order-free; a comment
      // line is legal inside an object literal). Only reference helpers
      // declared above -- this object is built once, at eval tail. Sweeps:
      // move this comment only whole, on its own lines. MARK:zone-console-hook-map
      // gr-w3 v4 shell: the reset-route extractor (GR13 — was unexported), the
      // context-morph enum + fail-closed operator gate (both PURE, node-pinned;
      // the DOM appliers applyShellNav/applyOperatorGate are browser+smoke-driven),
      // the ctx-dot colour map, and the generated-identity picker projection (GR12).
      resetTokenFromHash: resetTokenFromHash,
      shellNavLayer: shellNavLayer,
      operatorVisible: operatorVisible,
      ctxDotColor: ctxDotColor,
      bpThemeLabel: bpThemeLabel,
      bpThemeOptions: bpThemeOptions,
    });
  }
})();
