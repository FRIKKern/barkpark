// The desk navbar's menus (Desk.UserMenu, Desk.HelpMenu, Desk.ScopeSwitch,
// Desk.PerspectivePicker, Desk.WhoMenu, Desk.NavDrawer), as the TanStack Studio's Navbar.tsx:
// the appearance radios, the help menu's two dialogs and its "New version
// available", the perspective menu, who is here and the phone drawer. The menus open and close as popovers by
// themselves; this script does what a popover cannot. It runs once a page,
// from the help menu's script tag or from the desk hook's loader.
(function () {
  if (window.BarkparkDeskNavbar) return;

  var KEY = "barkpark_theme";
  var EVERY_MS = 60000;
  // The navbar's menus by keyboard, one rule for all, as TanStack's menus
  // (focus-scope.ts, `menu`): opened, an item has the focus (`start`, else
  // the first); ArrowDown, ArrowUp, Home and End move between the items one
  // can use; Tab leaves the menu closed and moves on, as the desk's doc menus
  // do. Escape and a click outside are the popover's own, and give the focus
  // back to the button. An item in use but kept for its tip (aria-disabled)
  // and someone in no document (disabled) are skipped.
  var MENU_ITEM = '[role^="menuitem"]:not([disabled]):not([aria-disabled="true"])';
  var MENUS = {
    "dk-perspective-menu": '[aria-checked="true"]',
    "dk-who-menu": null,
    "dk-help-menu": null,
    "dk-user-menu": null
  };
  var navMenu = function (el) {
    var menu = el && el.closest ? el.closest("[popover][role=menu]") : null;
    return menu && Object.prototype.hasOwnProperty.call(MENUS, menu.id) ? menu : null;
  };
  var menuItems = function (menu) {
    return Array.prototype.slice.call(menu.querySelectorAll(MENU_ITEM));
  };
  var openMenu = function (menu) {
    var start = MENUS[menu.id];
    var to = (start && menu.querySelector(start)) || menuItems(menu)[0];
    if (to) to.focus();
  };
  var menuKey = function (doc, e) {
    var menu = navMenu(e.target);
    if (!menu || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "Tab") return menu.hidePopover();
    var step = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity }[e.key];
    if (step === undefined) return;
    var items = menuItems(menu);
    if (!items.length) return;
    e.preventDefault();
    var at = items.indexOf(doc.activeElement);
    var to = Math.abs(step) === Infinity ? (step < 0 ? 0 : items.length - 1) : (at + step + items.length) % items.length;
    items[to].focus();
  };

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
    // The user menu's are radios (aria-checked), the drawer's pressed buttons.
    doc.querySelectorAll("[data-desk-appearance]").forEach(function (item) {
      var state = item.hasAttribute("aria-pressed") ? "aria-pressed" : "aria-checked";
      item.setAttribute(state, item.getAttribute("data-desk-appearance") === now ? "true" : "false");
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

  // The drawer (Desk.NavDrawer): a modal dialog, so Escape shuts it and the
  // browser gives the focus back to "Open menu". A modal dialog alone lets Tab
  // stop on the dialog box and then leave the page, so Tab and Shift+Tab wrap
  // between its first and last control, as TanStack's focus scope does.
  var drawer = function (doc) {
    return doc.getElementById("dk-drawer");
  };
  var drawerStops = function (d) {
    return Array.prototype.filter.call(d.querySelectorAll("a[href], button:not([disabled]), input:not([disabled]), [tabindex]"), function (el) {
      return el.tabIndex >= 0 && el.getClientRects().length > 0;
    });
  };
  var trapDrawer = function (doc, e) {
    var d = drawer(doc);
    if (e.key !== "Tab" || !d || !d.open) return;
    var list = drawerStops(d);
    if (!list.length) return;
    var first = list[0];
    var last = list[list.length - 1];
    var at = doc.activeElement;
    if (!d.contains(at) || at === d) {
      e.preventDefault();
      (e.shiftKey ? last : first).focus();
    } else if (e.shiftKey && at === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && at === last) {
      e.preventDefault();
      first.focus();
    }
  };
  var closeDrawer = function (doc) {
    var d = drawer(doc);
    if (d && d.open) d.close();
  };

  var onDrawer = function (doc, target, e) {
    if (target.closest("[data-desk-drawer-open]")) {
      var d = drawer(doc);
      if (d && !d.open) {
        checkAppearance(doc);
        // The drawer is the page's to keep (phx-update="ignore"): its Tasks
        // button reads the bar's, which the server keeps pressed or not.
        var tasks = d.querySelector("[data-desk-drawer-tasks]");
        var bar = doc.getElementById("dk-tasks-btn");
        if (tasks && bar) tasks.setAttribute("aria-pressed", bar.getAttribute("aria-pressed") || "false");
        d.showModal();
        var opener = doc.getElementById("dk-drawer-open");
        if (opener) opener.setAttribute("aria-expanded", "true");
      }
      return true;
    }
    if (target.closest("[data-desk-drawer-close]") || target.closest("[data-desk-drawer-pick]")) {
      closeDrawer(doc);
      return true;
    }
    // Help and resources: the navbar's own help menu, once the drawer is shut.
    if (target.closest("[data-desk-drawer-help]")) {
      closeDrawer(doc);
      var menu = doc.getElementById("dk-help-menu");
      if (menu && menu.showPopover && !menu.matches(":popover-open")) menu.showPopover();
      return true;
    }
    // A press on the backdrop (the dialog itself, outside its box) shuts it.
    if (target.id === "dk-drawer" && target.open) {
      var box = target.getBoundingClientRect();
      var inside = e.clientX >= box.left && e.clientX <= box.right && e.clientY >= box.top && e.clientY <= box.bottom;
      if (!inside) target.close();
      return true;
    }
    return false;
  };

  var onClick = function (e) {
    var doc = e.currentTarget;
    var target = e.target;
    if (!target || !target.closest) return;

    // A perspective picked (Desk.PerspectivePicker): its link patches the
    // page; the menu closes at once.
    var pick = target.closest("[data-desk-perspective]");
    if (pick) {
      var list = pick.closest("[popover]");
      if (list && list.matches(":popover-open")) list.hidePopover();
      return;
    }

    // A person picked in who is here (Desk.WhoMenu): their document opens and
    // the menu closes at once, as TanStack's row (onDone).
    var person = target.closest("#dk-who-menu .who-row");
    if (person) {
      var people = person.closest("[popover]");
      if (people && people.matches(":popover-open")) people.hidePopover();
      return;
    }

    var radio = target.closest("[data-desk-appearance]");
    if (radio) {
      // The drawer's stay open, as TanStack's: the change shows at once.
      setAppearance(doc, radio.getAttribute("data-desk-appearance"));
      var menu = radio.closest("[popover]");
      if (menu && menu.matches(":popover-open")) menu.hidePopover();
      return;
    }

    // A place picked in the switcher (Desk.ScopeSwitch): its card closes at
    // once; the server goes there, or says it cannot.
    var place = target.closest(".scope-place");
    if (place) {
      var card = place.closest("[popover]");
      if (card && card.matches(":popover-open")) card.hidePopover();
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

    if (onDrawer(doc, target, e)) return;

    // Its own attribute: `data-desk-dialog` marks the desk's document dialogs.
    var opener = target.closest("[data-desk-nav-dialog]");
    if (opener) return openDialog(doc, opener, opener.getAttribute("data-desk-nav-dialog"));

    var close = target.closest("[data-desk-nav-dialog-close]");
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
      // A navbar menu opens on an item: the perspective in use, else the first.
      if (e.newState === "open" && e.target && MENUS.hasOwnProperty(e.target.id)) openMenu(e.target);
    }, true);
    doc.addEventListener("keydown", function (e) { trapDrawer(doc, e); }, true);
    doc.addEventListener("keydown", function (e) { menuKey(doc, e); });
    doc.addEventListener("click", onClick);
    // The drawer shut (Escape, Close menu, a tool, the backdrop): its button says so.
    doc.addEventListener("close", function (e) {
      if (!e.target || e.target.id !== "dk-drawer") return;
      var opener = doc.getElementById("dk-drawer-open");
      if (opener) opener.setAttribute("aria-expanded", "false");
    }, true);
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
