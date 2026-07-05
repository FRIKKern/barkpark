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
  // a SETTINGS cluster (billing/providers/notifications/tokens). "launch" is no
  // longer a view at all (A4/D66): it is the launchFlow() component, opened in a
  // modal or rendered as the empty-fleet welcome runway. Its old #launch bookmark
  // remaps to Overview (legacyRoute) and auto-opens the flow (wantsLaunchFlow).
  var VIEWS = ["overview", "fleet", "sites", "billing", "providers", "notifications", "tokens", "activity"];
  var SETTINGS_VIEWS = ["billing", "providers", "notifications", "tokens"];

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
  var INSTANCE_TABS = ["overview", "timeline", "webhooks"];
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
            ? provisionChipHtml(bp, Date.now()) // C3: "configuring · 1m 42s"
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
      body.innerHTML = bar + shown.map(fleetRow).join("");
      wireFleetRows(body);
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
  function loadInstance(id, tab) {
    var seq = ++instanceLoadSeq;
    // Default the tab from the current route when a caller omits it (SSE retry,
    // post-mutation reload), but never trust a foreign view's tab.
    if (tab === undefined) {
      var h = parseHash();
      tab = h.view === "instance" ? h.tab : INSTANCE_TAB_DEFAULT;
    }
    tab = instanceTabOf(tab);
    stopInstanceTicker(); // the DOM the ticker updates is about to be replaced
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
      // A4 ready fold: if we watched this box provisioning and it's now live, show
      // the ready panel. The flag is consumed on the operator's DISMISS (View
      // details), not on render — going live fires several SSE ticks in quick
      // succession (agent connect, health flip) and each one repaints this view;
      // consuming on render would blink the celebration away before it's read.
      var lc = instanceLifecycle(bp);
      if (lc.provisioning || lc.failed) provisioningSeen[bp.id] = true;
      var showReady = tab === "overview" && readyFoldTrigger(bp) && !!provisioningSeen[bp.id];
      box.innerHTML = instanceDetailHtml(bp, tab, { ready: showReady });
      wireInstanceActions(bp);
      var panel = box.querySelector("#instance-tabpanel");
      if (tab === "webhooks") {
        mountWebhooksTab(panel, bp);
      } else if (tab === "timeline") {
        mountTimelineTab(panel, bp); // C8: the merged events+audit incident home
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
      } else {
        // Overview: the C3 provisioning timeline + sites + rail, wired exactly as
        // before (the tab seam only wraps the SAME render in a panel).
        wireInstanceTimeline(box, bp);   // C3: console toggle + Retry
        startInstanceTicker(bp);         // C3: live per-step elapsed (tick, no remount)
        loadInstanceSites(bp);
        loadInstanceVerify(bp);          // C8: golden-path verify chips (host-set boxes)
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
    return instanceHeaderHtml(bp) +
      instanceTabStripHtml(bp, tab) +
      '<div id="instance-tabpanel" class="inst-tabpanel">' +
        (tab === "overview" ? instanceOverviewHtml(bp, opts) : "") +
      "</div>";
  }

  // The a11y tab strip (charter D49 + the #991 pattern): plain in-app anchors so
  // Back/deep-links/copy work, the active one carrying aria-current="page"; the
  // house focus-visible ring is applied in app.css.
  function instanceTabStripHtml(bp, tab) {
    tab = instanceTabOf(tab);
    var labels = { overview: "Overview", timeline: "Timeline", webhooks: "Webhooks" };
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
            : '<div class="fleet-url">' + esc(bp.url) + "</div>";

    // The header collapses to ONE pill (charter decision 6). The health / agent
    // breakdown that USED to be badge-soup now lives only in the Details rail.
    var badges = statusPill(bp);

    // isu-6: live + behind → offer the one-click update alongside Open Studio.
    var updateBtn = lc.live && bp.update_state === "behind"
      ? '<button class="btn btn-primary btn-sm" id="inst-update" type="button">' +
          esc(bp.update_latest_release ? "Update to " + vRel(bp.update_latest_release) : "Update") + "</button>"
      : "";

    var actions =
      lc.removing
        ? ""
        : lc.removeFailed
          ? '<button class="btn btn-primary btn-sm" id="inst-remove-retry" type="button">Retry removal</button>'
          : lc.failed
            ? '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>' // Retry lives in the timeline (data-tl-retry)
            : bp.host
              ? updateBtn +
                '<button class="btn btn-primary btn-sm" id="inst-open-studio" type="button">Open Studio</button>' +
                '<button class="btn btn-ghost btn-sm" id="inst-remove" type="button">Remove</button>'
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

    var updateRail = bp.update_state === "behind"
      ? vRel(bp.update_running_release) + " → " + vRel(bp.update_latest_release) + " available"
      : bp.update_state === "current"
        ? "up to date (" + vRel(bp.update_running_release) + ")"
        : "—";

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
    return timeline + verifySlot +
      '<div class="detail-grid">' +
        '<div class="detail-main">' + (hasHost ? "<h2>Sites</h2>" : "") +
          '<div id="instance-sites">' + (hasHost ? '<div class="loading">Loading sites&hellip;</div>' : "") + "</div></div>" +
        '<aside class="detail-rail"><h2>Details</h2>' +
          railRowCopy("ID", bp.id) +
          railRowCopy("Host", bp.host || "—") +
          railRow("Mode", bp.mode || "—") +
          railRow("Health", railValue(cap(health), hasHost)) +
          railRow("Agent", railValue(cap(agent), hasHost)) +
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

  function loadInstanceSites(bp) {
    api("GET", "/v1/sites").then(function (r) {
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
    var listBox = root && root.querySelector ? root.querySelector(".wh-list") : null;
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

  function openCreateWebhookModal(root, bp, ds) {
    var events = ["create", "update", "publish", "unpublish", "delete", "discardDraft", "patch"];
    openModal(
      '<h2 class="modal-title" id="modal-title">New webhook</h2>' +
      '<p class="modal-sub">Deliver document mutation events on <b>' + esc(ds) + "</b> to an HTTPS endpoint.</p>" +
      '<form id="wh-create-form" class="wh-form">' +
        '<label class="label" for="wh-c-name">Name</label>' +
        '<input class="form-input" id="wh-c-name" required autocomplete="off">' +
        '<label class="label" for="wh-c-url">Payload URL</label>' +
        '<input class="form-input" id="wh-c-url" type="url" placeholder="https://example.com/hooks" required autocomplete="off" spellcheck="false">' +
        '<span class="label">Events <span class="muted">(none = all)</span></span>' +
        '<div class="wh-events-pick">' + events.map(function (e) {
          return '<label class="wh-event-opt"><input type="checkbox" class="wh-event-cb" value="' + esc(e) + '"> ' + esc(e) + "</label>";
        }).join("") + "</div>" +
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
      wireDeployActions(box, site, deployments);
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
      ? deployments.map(function (d) { return deployRow(d, site.current_deployment_id); }).join("")
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

  function confirmPromote(site, d, kind) {
    var copy = promoteConfirmCopy(kind, deployRefLabel(d));
    openConfirmModal({
      tier: "mutate",
      title: copy.title,
      consequence: copy.consequence,
      confirmLabel: copy.confirmLabel,
      busyLabel: copy.busyLabel,
      onConfirm: function (ctl) { runPromote(site, d, kind, ctl); },
    });
  }

  function runPromote(site, d, kind, ctl) {
    api("POST", promotePath(site.id, d.id), {}).then(function (r) {
      if (r.status === 201) {
        ctl.succeed();
        toast({
          kind: "success",
          title: kind === "redeploy" ? "Redeploy started" : "Rollback started",
          body: "A new production deployment pinned to " + deployRefLabel(d) + " is queued.",
        });
        // The live "deployments" SSE tick repaints too; refetch immediately so
        // the queued row appears without waiting on the broadcast round-trip.
        if (String(currentSiteId) === String(site.id)) loadSite(site.id);
        return;
      }
      var f = promoteFailure(r.status, r.data);
      if (f.recovery === "retry") {
        ctl.fail(f.message, "Try again", function (c) {
          c.busy();
          runPromote(site, d, kind, c);
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
        if (d) confirmPromote(site, d, btn.getAttribute("data-kind"));
      });
    });
  }

  function deployRow(d, currentId) {
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
    var when = d.became_live_at || d.updated_at || d.inserted_at;
    // Git meta the row already carries (D7): branch, sha (when the headline is
    // an image tag), and WHEN — "live since" once the row went live.
    var metaBits = [];
    if (d.branch) metaBits.push(esc(d.branch));
    if (d.git_ref && d.image_tag) metaBits.push('<span class="mono">' + esc(shortSha(d.git_ref)) + "</span>");
    metaBits.push(esc((st === "live" && d.became_live_at ? "live since " : "") + fmtWhen(when)));
    var fail = (st === "failed" && d.failure_reason)
      ? '<div class="deploy-fail' + (failureTone(d.failure_reason) === "blocked" ? " deploy-fail--blocked" : "") + '">' + esc(failureCopy(d.failure_reason)) + "</div>" : "";
    var action = promoteActionFor(d, currentId);
    var actionBtn = action
      ? '<button type="button" class="btn btn-ghost btn-sm dep-promote" data-dep-id="' + esc(d.id) + '" data-kind="' + esc(action.kind) + '">' + esc(action.label) + "</button>"
      : "";
    var current = isCurrent
      ? '<span class="dep-current" title="Production traffic is served from this deployment">Current</span>'
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

  // Step 1: the name field + submit (state "name").
  function renderLaunchName(container, opts) {
    var hero = opts.runway
      ? welcomeHeroHtml(subCache)
      : '<h2 class="modal-title" id="modal-title">Launch a Barkpark</h2>' +
        '<p class="modal-sub">Name it and we provision it — a fresh instance, hosted and run for you.</p>';
    var nameId = "launch-flow-name-" + (++launchFlowSeq);
    // Static class strings per variant so the CSS checker can resolve every token
    // (no dynamic class-head concat — __css_check E3).
    var submitBtn = opts.runway
      ? '<button class="btn btn-primary btn-lg btn-block" type="submit">' + esc(launchCta(opts)) + "</button>"
      : '<button class="btn btn-primary" type="submit">' + esc(launchCta(opts)) + "</button>";
    var inner = hero +
      '<form class="launch-form" novalidate>' +
        '<div class="field"><label class="label" for="' + nameId + '">Name</label>' +
          '<input class="form-input" id="' + nameId + '" type="text" placeholder="Production" value="' +
            esc(opts.name || "") + '" required />' +
          '<p class="field-hint dim">A human label for this instance.</p></div>' +
        submitBtn +
      "</form>";
    container.innerHTML = launchFlowShell(inner, opts);
    var form = container.querySelector(".launch-form");
    if (form) form.addEventListener("submit", function (e) { submitLaunchFlow(e, container, opts); });
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
    api("POST", "/v1/launch", { name: name }).then(function (r) {
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
      toast({ kind: "error", title: "Couldn't launch", body: friendly(r.data, "Please try again.") });
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
    loadInstance(h.id, h.tab);
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
    },
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
  // Fallback steps: hidden from the checklist/timeline until the server reports
  // a first entry for them (a planned step renders pending from the start).
  var SERVER_STEP_OPTIONAL = { freshen: true };
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
    create: 15000, freshen: 300000, secure: 45000, configure: 35000,
    content: 20000, verify: 15000, ready: 10000
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

  // ── Mount 1 presentation: the /new checklist markup (byte-locked in tests) ──
  // The active row's dot doubles as the per-phase loading bar: a conic-gradient
  // ring filled by --p (stepRingProgress over the phase's expected duration),
  // ticked IN PLACE each second via data-ring — never a rebuild. The time
  // column narrates pace: pending "~30s" (the plan), active "12s · ~30s" (live,
  // ticked via data-time), done/failed the real elapsed. A `next` row (see
  // markNextStep) keeps the pending dot but pulses + spins so the between-steps
  // window never reads frozen.
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
    var items = (rows || []).map(function (row) {
      var mark = row.role === "ok" ? "&#10003;" : row.role === "failed" ? "&#10007;" : "";
      var elapsed = '<span class="bp-tl-elapsed" data-step="' + esc(row.step) + '">' +
        (row.elapsedMs != null ? fmtDur(row.elapsedMs) : "") + "</span>";
      var capText = row.caption || (row.next ? "Starting…" : "");
      var cap = capText ? '<div class="bp-tl-caption">' + esc(capText) + "</div>" : "";
      var probes = (row.probes && row.probes.length)
        ? '<ul class="bp-tl-probes">' + row.probes.map(function (p) {
            return '<li class="bp-tl-probe">' + esc(p) + "</li>";
          }).join("") + "</ul>"
        : "";
      // A `next` row spins too — the between-steps window shows motion here as
      // well, dimmed by the --next class so it reads "about to", not "running".
      var spin = (row.role === "active" || row.next) ? '<span class="bp-tl-spin" aria-hidden="true"></span>' : "";
      return '<li class="bp-tl-step bp-tl-step--' + esc(row.role) + (row.next ? " bp-tl-step--next" : "") + '">' +
          '<span class="bp-tl-dot" aria-hidden="true">' + mark + "</span>" +
          '<div class="bp-tl-body">' +
            '<div class="bp-tl-line"><span class="bp-tl-label">' + esc(row.label) + "</span>" + elapsed + "</div>" +
            cap + probes +
          "</div>" + spin +
        "</li>";
    }).join("");
    var fail = opts.failed
      ? '<div class="bp-tl-fail" role="alert"><b>Setup failed.</b> ' +
        esc(opts.failureDetail || "Provisioning didn't finish.") + "</div>"
      : "";
    return '<ol class="bp-tl-steps">' + items + "</ol>" + fail;
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

  // The full instance-detail timeline section: header clock + steps + (failed)
  // verbatim detail & Retry + expandable console. Pure; the ticker + wiring add
  // liveness on top. opts.consoleCollapsed persists the user's toggle.
  function instanceTimelineHtml(bp, now, opts) {
    opts = opts || {};
    now = (typeof now === "number") ? now : Date.now();
    var failed = isProvisionFailed(bp);
    var rows = provisionSteps(bp, now);
    var total = provisionTotalMs(bp, now);
    var head = '<div class="bp-tl-head">' +
        '<h2 class="bp-tl-title">' + (failed ? "Setup failed" : "Provisioning") + "</h2>" +
        '<span class="bp-tl-total" data-tl-total>' + (total != null ? fmtDur(total) : "") + "</span>" +
      "</div>";
    var retry = failed
      ? '<button class="btn btn-primary btn-sm bp-tl-retry" type="button" data-tl-retry>Retry setup</button>'
      : "";
    return '<section class="bp-timeline" data-tl>' +
        head +
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

  // Update only the elapsed text nodes (never rebuild) so the console scroll +
  // the expand state survive; self-stops if the timeline left the DOM.
  function tickInstanceTimeline() {
    var bp = instanceTickerBp;
    if (!bp) return;
    var section = document.querySelector("[data-tl]");
    if (!section) { stopInstanceTicker(); return; }
    var now = Date.now();
    var byStep = {};
    provisionSteps(bp, now).forEach(function (r) { byStep[r.step] = r.elapsedMs; });
    section.querySelectorAll(".bp-tl-elapsed").forEach(function (el) {
      var step = el.getAttribute("data-step");
      if (Object.prototype.hasOwnProperty.call(byStep, step)) {
        el.textContent = byStep[step] != null ? fmtDur(byStep[step]) : "";
      }
    });
    var total = section.querySelector("[data-tl-total]");
    if (total) { var t = provisionTotalMs(bp, now); total.textContent = t != null ? fmtDur(t) : ""; }
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
    var el = document.querySelector("#new-body .new-elapsed");
    if (el) el.textContent = newElapsedSeconds(serverSteps) + "s elapsed";
    var dot = document.querySelector("#new-body .new-step-dot[data-ring]");
    if (!dot) return;
    var li = dot.parentNode;
    if (li && li.className && li.className.indexOf("completing") !== -1) {
      // A dwelling (truth-done) step: sweep the ring to full over the dwell —
      // the satisfying "circle closes, check lands" beat. +34/tick ≈ full in 3s;
      // the 0.9s --p transition smooths the jumps into a continuous sweep.
      var cur = parseInt(dot.style.getPropertyValue("--p"), 10) || 0;
      dot.style.setProperty("--p", Math.min(100, cur + 34) + "%");
      return;
    }
    var step = dot.getAttribute("data-ring");
    var rows = provisionSteps({ provision_steps: serverSteps }, Date.now());
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].step !== step || rows[i].role !== "active") continue;
      var expected = SERVER_STEP_EXPECTED_MS[step];
      dot.style.setProperty("--p", Math.round(stepRingProgress(rows[i].elapsedMs, expected) * 100) + "%");
      var t = document.querySelector('#new-body .new-step-time[data-time="' + step + '"]');
      if (t) t.textContent = fmtDur(rows[i].elapsedMs) + (expected ? " · ~" + fmtDur(expected) : "");
      return;
    }
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
      newSetBody(newPanel(
        '<div class="new-progress">' +
          newConnBannerHtml() +
          "<h2>Setting up " + esc(title) + "</h2>" +
          '<p class="dim">This usually takes under a minute. <span class="new-elapsed">' + newElapsedSeconds(newState.serverSteps || []) + "s elapsed</span></p>" +
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
    var extra = newGithubHtml(tpl, gh) +
      '<a class="btn btn-block btn-vercel" id="new-vercel" href="' + esc(clone) + '" target="_blank" rel="noopener">Deploy your site to Vercel</a>';
    var tail = envBlock +
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
      failureCopy: failureCopy, failureTone: failureTone, liveEventTypes: Object.keys(TYPE_ACTIONS),
      // C2/D45: the /new timeline's step vocabulary — pinned against the Go
      // worker's report vocabulary + the ProvisionJob @steps whitelist.
      serverStepOrder: SERVER_STEP_ORDER, serverStepLabels: SERVER_STEP_LABELS,
      // Progress-polish: per-phase pacing (ring estimates), the fallback-step
      // set, and the between-steps `next` marker.
      serverStepExpectedMs: SERVER_STEP_EXPECTED_MS, serverStepOptional: SERVER_STEP_OPTIONAL,
      stepRingProgress: stepRingProgress, markNextStep: markNextStep,
      // Presentation pacing (min-dwell): pure display shim + the resume seed.
      paceSteps: paceSteps, seedPaceLedger: seedPaceLedger,
      newStepMinDwellMs: NEW_STEP_MIN_DWELL_MS,
      deployIsActive: deployIsActive, deployIsPreClaim: deployIsPreClaim,
      deployDetailHtml: deployDetailHtml, deployConsoleHtml: deployConsoleHtml,
      // A4 onboarding narrative (D56/D57/D60/D66): the launch component + runway +
      // ready-fold pure helpers.
      wantsLaunchFlow: wantsLaunchFlow, runwaySubline: runwaySubline,
      welcomeHeroHtml: welcomeHeroHtml, launchedHash: launchedHash,
      launchFlowReducer: launchFlowReducer, readyFoldTrigger: readyFoldTrigger,
      readyHeroHtml: readyHeroHtml, railValue: railValue,
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
      // Zero-broken-promises slice (charter D5/D7/D25/D26): the shared confirm
      // modal (pure state machine + focus-trap seam), the promote grammar
      // (rollback/redeploy), and the invitation-accept landing.
      confirmModalInit: confirmModalInit, confirmModalReduce: confirmModalReduce,
      confirmModalArmed: confirmModalArmed, confirmModalTypedMatch: confirmModalTypedMatch,
      confirmModalHtml: confirmModalHtml, trapTarget: trapTarget,
      promotePath: promotePath, promoteActionFor: promoteActionFor,
      promoteConfirmCopy: promoteConfirmCopy, promoteFailure: promoteFailure,
      deployRefLabel: deployRefLabel, deployRow: deployRow,
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
    });
  }
})();
