// The desk navbar's menus (Desk.UserMenu, Desk.HelpMenu), as the TanStack
// Studio's Navbar.tsx: the appearance radios, the help menu's two dialogs and
// its "New version available". The menus open and close as popovers by
// themselves; this script does what a popover cannot. It runs once a page,
// from the help menu's script tag or from the desk hook's loader.
(function () {
  if (window.BarkparkDeskNavbar) return;

  var KEY = "barkpark_theme";
  var EVERY_MS = 60000;

  // The appearance: one stored in localStorage ("light" or "dark"), else
  // the system's (none stored), as the head's pre-paint script reads it.
  var stored = function () {
    try {
      return localStorage.getItem(KEY);
    } catch (_e) {
      return null;
    }
  };
  var systemTheme = function () {
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  };
  var appearance = function () {
    var value = stored();
    return value === "light" || value === "dark" ? value : "system";
  };
  var checkAppearance = function (doc) {
    var now = appearance();
    doc.querySelectorAll("[data-desk-appearance]").forEach(function (item) {
      item.setAttribute("aria-checked", item.getAttribute("data-desk-appearance") === now ? "true" : "false");
    });
  };
  var setAppearance = function (doc, value) {
    try {
      if (value === "system") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, value);
    } catch (_e) {}
    doc.documentElement.dataset.theme = value === "system" ? systemTheme() : value;
    checkAppearance(doc);
  };

  // A build's short name, as the menu shows it: its commit ("8c7f965").
  var buildName = function (build) {
    return String(build).split("-")[0].slice(0, 7);
  };

  var help = function (doc) {
    return doc.getElementById("dk-help");
  };

  // The server runs `next`, not this page's build: the dot, the tip, and
  // the version item reloads.
  var announce = function (doc, next) {
    var wrap = help(doc);
    if (!wrap) return;
    var button = wrap.querySelector("#help-menu");
    var dot = wrap.querySelector(".update-dot");
    var state = wrap.querySelector("[data-desk-version-state]");
    var item = wrap.querySelector("[data-desk-version]");
    var build = wrap.getAttribute("data-build") || "";
    if (!next || next === build) {
      wrap.removeAttribute("data-next");
      return;
    }
    wrap.setAttribute("data-next", next);
    if (button) button.setAttribute("data-tip", wrap.getAttribute("data-desk-new-version"));
    if (dot) dot.hidden = false;
    if (item) item.setAttribute("data-update", "");
    if (state) {
      state.textContent =
        buildName(next) === buildName(build)
          ? wrap.getAttribute("data-desk-reload")
          : wrap.getAttribute("data-desk-reload-to").replace("%{version}", buildName(next));
    }
  };

  var ask = function (doc) {
    if (!help(doc) || !window.fetch) return;
    fetch("/api/version", { cache: "no-store", credentials: "same-origin" })
      .then(function (r) {
        return r.ok ? r.json() : null;
      })
      .then(function (v) {
        if (v && typeof v.build === "string" && v.build) announce(doc, v.build);
      })
      .catch(function () {}); // offline or refused: ask again later
  };

  var openDialog = function (doc, from, id) {
    var menu = from.closest("[popover]");
    if (menu && menu.matches(":popover-open")) menu.hidePopover();
    var dialog = doc.getElementById(id);
    if (dialog && !dialog.open) dialog.showModal();
  };

  var onClick = function (e) {
    var doc = e.currentTarget;
    var target = e.target;
    if (!target || !target.closest) return;

    var radio = target.closest("[data-desk-appearance]");
    if (radio) {
      setAppearance(doc, radio.getAttribute("data-desk-appearance"));
      var menu = radio.closest("[popover]");
      if (menu && menu.matches(":popover-open")) menu.hidePopover();
      return;
    }

    var version = target.closest("[data-desk-version]");
    if (version) {
      var wrap = help(doc);
      if (wrap && wrap.getAttribute("data-next")) {
        version.disabled = true;
        var state = wrap.querySelector("[data-desk-version-state]");
        if (state) state.textContent = wrap.getAttribute("data-desk-reloading");
        // Edits save as they are typed; anything still on its way goes first.
        var wait = function (tries) {
          if (tries > 0 && typeof window.__savesPending === "function" && window.__savesPending()) {
            setTimeout(function () { wait(tries - 1); }, 100);
          } else {
            window.location.reload();
          }
        };
        wait(50);
      } else {
        openDialog(doc, version, "dk-version-dialog");
      }
      return;
    }

    var opener = target.closest("[data-desk-dialog]");
    if (opener) return openDialog(doc, opener, opener.getAttribute("data-desk-dialog"));

    var close = target.closest("[data-desk-dialog-close]");
    if (close) {
      var dialog = close.closest("dialog");
      if (dialog) dialog.close();
      return;
    }

    // A click on the backdrop (the dialog itself, outside its box) closes it.
    if (target.matches && target.matches("dialog.dk-nav-dialog[open]")) {
      var box = target.getBoundingClientRect();
      var inside = e.clientX >= box.left && e.clientX <= box.right && e.clientY >= box.top && e.clientY <= box.bottom;
      if (!inside) target.close();
    }
  };

  var start = function (doc) {
    checkAppearance(doc);
    // The menu is drawn again by a live navigation: checked when it opens.
    doc.addEventListener("toggle", function (e) {
      if (e.target && e.target.id === "dk-user-menu" && e.newState === "open") checkAppearance(doc);
    }, true);
    doc.addEventListener("click", onClick);
    ask(doc);
    setInterval(function () { ask(doc); }, EVERY_MS);
    var visible = function () {
      if (doc.visibilityState === "visible") ask(doc);
    };
    window.addEventListener("focus", visible);
    doc.addEventListener("visibilitychange", visible);
    // The system's appearance changes while System is in use: follow it.
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (appearance() === "system") doc.documentElement.dataset.theme = systemTheme();
    });
  };

  window.BarkparkDeskNavbar = { buildName: buildName, announce: announce, appearance: appearance };
  start(document);
})();
