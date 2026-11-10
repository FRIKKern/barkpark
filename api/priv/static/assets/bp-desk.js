// bp-desk.js — the desk slice's browser half (/papers/desk-vertical-slice).
//
// The desk slice (BarkparkWeb.Studio.DeskLive) navigates by link: every row is
// an <a> LiveView patches. A patch needs the server, so on its own a click
// shows nothing until the answer lands. This hook makes the click itself
// visible, the way the TanStack Studio's client router does:
//
//   * CLICK  — the row is marked current and an empty pane frame is drawn at
//              once; panes the click closes are hidden. No network in that
//              path. The server's patch then replaces the frame.
//   * INTENT — hovering or focusing a row asks the server to read the pane it
//              opens ("warm"), so the click that follows opens it with data.
//   * LAYOUT — panes that do not fit collapse to 51 px strips, by the rule the
//              TanStack Studio uses (Sanity's own, see collapsed() below), from
//              the width the browser measures. A click on a strip opens it.
//
// Nothing here decides where a link goes: the href is the server's, and a
// modifier click (new tab, new window) is left to the browser untouched.
//
// Registered as Hooks.Desk on #desk-panes (root.html.heex).
(function () {
  "use strict";

  var ROW = "a[data-desk-row]";
  var WARM_DELAY_MS = 80;
  var WARM_FORGET_MS = 30000;
  var GIVE_UP_MS = 10000;

  // Which panes collapse to strips. Sanity's own algorithm
  // (structure/components/pane/paneLayoutController.ts, _notifyObservers), as
  // the TanStack Studio ports it (barkpark-studio app/src/lib/layout.ts), so
  // both studios collapse the same panes at every width:
  //  - visit the focused pane first (it never collapses), then the rest right
  //    to left;
  //  - start from the width left after giving every other pane a 51 px strip;
  //  - a pane collapses when its min width exceeds what is left; an open pane
  //    uses (min - 51) of it, a collapsed one 51 more (Sanity's accounting,
  //    kept exact).
  // Ported from Sanity (MIT, Copyright (c) 2016 - 2026 Sanity.io).
  var STRIP = 51;
  var MIN = { types: 320, menu: 320, list: 320, doc: 600 };

  function collapsed(kinds, width, focus) {
    var n = kinds.length;
    if (focus === undefined || focus === null || focus < 0 || focus >= n) focus = n - 1;
    var order = [focus];
    for (var k = n - 1; k >= 0; k--) if (k !== focus) order.push(k);
    var out = kinds.map(function () {
      return false;
    });
    var remaining = width - (n - 1) * STRIP;
    order.forEach(function (i) {
      var min = MIN[kinds[i]] || MIN.list;
      out[i] = i !== focus && min > remaining;
      remaining -= out[i] ? STRIP : min - STRIP;
    });
    return out;
  }

  // The rules for one collapsed pane, by its index: a stylesheet, not
  // attributes, because a LiveView patch rewrites a pane's attributes and a
  // rule keyed on the server's own data-pane-index survives it.
  function stripRules(index) {
    var pane = '#desk-panes > [data-pane-index="' + index + '"]:not([data-desk-leaving])';
    return (
      pane + " { width: " + STRIP + "px; min-width: " + STRIP + "px; flex: 0 0 " + STRIP + "px; cursor: pointer; overflow: hidden; }\n" +
      pane + " > .pane-body, " + pane + " .dk-close { display: none; }\n" +
      pane + " > .pane-header { height: 100%; min-height: 0; padding: 16px 0; border-bottom: 0; justify-content: flex-start; writing-mode: vertical-rl; }\n"
    );
  }

  function styleSheet(doc) {
    var el = doc.getElementById("bp-desk-layout");
    if (!el) {
      el = doc.createElement("style");
      el.id = "bp-desk-layout";
      doc.head.appendChild(el);
    }
    return el;
  }

  // Lay the panes out for the width they have. `focus` is the index of a pane
  // the editor opened from its strip (null: the last pane).
  function layout(root, focus) {
    var shown = panes(root).filter(function (el) {
      return !el.hasAttribute("data-desk-leaving");
    });
    var kinds = shown.map(function (el) {
      return el.getAttribute("data-pane-kind");
    });
    var at = shown.findIndex(function (el) {
      return focus !== null && Number(el.getAttribute("data-pane-index")) === focus;
    });
    // No width yet (the desk is not laid out): nothing collapses.
    var width = root.clientWidth;
    var flags = width > 0 ? collapsed(kinds, width, at) : kinds.map(function () { return false; });
    var css = "";

    shown.forEach(function (el, i) {
      if (flags[i]) {
        css += stripRules(el.getAttribute("data-pane-index"));
        if (!el.hasAttribute("data-pane-collapsed")) {
          el.setAttribute("data-pane-collapsed", "");
          el.setAttribute("tabindex", "0");
          el.setAttribute("role", "button");
        }
      } else if (el.hasAttribute("data-pane-collapsed")) {
        el.removeAttribute("data-pane-collapsed");
        el.removeAttribute("tabindex");
        el.removeAttribute("role");
      }
    });

    var sheet = styleSheet(root.ownerDocument);
    if (sheet.textContent !== css) sheet.textContent = css;
    return flags;
  }

  function paneOf(root, el) {
    var pane = el.closest("[data-pane-index]");
    return pane && pane.parentNode === root ? pane : null;
  }

  function panes(root) {
    return Array.prototype.filter.call(root.children, function (el) {
      return el.hasAttribute("data-pane-index");
    });
  }

  function plainClick(e) {
    return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey && !e.defaultPrevented;
  }

  function samePage(row) {
    try {
      return new URL(row.href, window.location.href).pathname === window.location.pathname;
    } catch (_e) {
      return true;
    }
  }

  function setCurrent(row, on) {
    row.classList.toggle("selected", on);
    if (on) row.setAttribute("aria-current", "true");
    else row.removeAttribute("aria-current");
  }

  // An empty pane, shaped like the one the server draws while its read runs.
  function skeleton(doc, index, kind, title) {
    var pane = doc.createElement("section");
    pane.className = "pane-column dk-pane" + (kind === "doc" ? " dk-doc" : "");
    pane.setAttribute("data-desk-skeleton", "");
    pane.setAttribute("data-pane-index", String(index));
    pane.setAttribute("data-pane-kind", kind || "list");
    pane.setAttribute("aria-busy", "true");

    var header = doc.createElement("div");
    header.className = "pane-header";
    var name = doc.createElement("span");
    name.className = "pane-header-title";
    name.textContent = title;
    header.appendChild(name);

    var body = doc.createElement("div");
    body.className = "pane-body";
    var bones = doc.createElement("div");
    bones.className = "dk-skeleton";
    bones.setAttribute("aria-hidden", "true");
    for (var i = 0; i < 6; i++) {
      var item = doc.createElement("div");
      item.className = "pane-item";
      var bone = doc.createElement("span");
      bone.className = "dk-bone";
      item.appendChild(bone);
      bones.appendChild(item);
    }
    body.appendChild(bones);

    pane.appendChild(header);
    pane.appendChild(body);
    return pane;
  }

  // Draw what the click will lead to. Returns what it changed, so it can be
  // put back if the navigation never lands.
  function paintAhead(root, row) {
    var pane = paneOf(root, row);
    if (!pane || samePage(row)) return null;

    var index = Number(pane.getAttribute("data-pane-index"));
    var wasCurrent = row.getAttribute("aria-current") === "true";
    var previous = pane.querySelector(ROW + '[aria-current="true"]');

    if (previous && previous !== row) setCurrent(previous, false);
    setCurrent(row, true);

    // The row's own pane (index + 1) stays when the row was already open;
    // everything right of what stays is closed by this click.
    var keep = wasCurrent ? index + 1 : index;
    var leaving = panes(root).filter(function (el) {
      return Number(el.getAttribute("data-pane-index")) > keep;
    });
    leaving.forEach(function (el) {
      el.setAttribute("data-desk-leaving", "");
    });

    var frame = null;
    if (!wasCurrent) {
      var label = row.querySelector(".pane-item-label");
      frame = skeleton(root.ownerDocument, index + 1, row.getAttribute("data-desk-opens"), (label || row).textContent.trim());
      root.insertBefore(frame, pane.nextSibling);
    }

    return { row: row, previous: previous, wasCurrent: wasCurrent, leaving: leaving, frame: frame, href: row.href };
  }

  // The patch landed (the server's panes are in), or it never did.
  function settle(ahead, landed) {
    if (!ahead) return;
    if (ahead.frame && ahead.frame.parentNode) ahead.frame.parentNode.removeChild(ahead.frame);
    ahead.leaving.forEach(function (el) {
      el.removeAttribute("data-desk-leaving");
    });
    if (!landed) {
      if (!ahead.wasCurrent && ahead.row.isConnected) setCurrent(ahead.row, false);
      if (ahead.previous && ahead.previous.isConnected) setCurrent(ahead.previous, true);
    }
  }

  // For the host test: the rule itself, with no page around it.
  window.BarkparkDeskLayout = { collapsed: collapsed, layout: layout };

  window.BarkparkDesk = {
    mounted: function () {
      var hook = this;
      var root = this.el;
      hook._ahead = null;
      hook._warmed = {};

      hook._settle = function (landed) {
        var ahead = hook._ahead;
        hook._ahead = null;
        window.clearTimeout(hook._giveUp);
        settle(ahead, landed);
        hook._layout();
      };

      // A strip the editor opened keeps the focus until the URL changes.
      hook._focus = null;
      hook._layout = function () {
        if (hook._focus && hook._focus.path !== window.location.pathname) hook._focus = null;
        return layout(root, hook._focus ? hook._focus.index : null);
      };
      hook._queueLayout = function () {
        if (hook._raf) return;
        hook._raf = (window.requestAnimationFrame || window.setTimeout)(function () {
          hook._raf = 0;
          hook._layout();
        });
      };

      hook._openStrip = function (e) {
        var pane = e.target.closest ? e.target.closest("[data-pane-collapsed]") : null;
        if (!pane || pane.parentNode !== root) return;
        if (e.type === "keydown" && (e.target !== pane || (e.key !== "Enter" && e.key !== " "))) return;
        e.preventDefault();
        e.stopPropagation();
        hook._focus = { path: window.location.pathname, index: Number(pane.getAttribute("data-pane-index")) };
        hook._layout();
      };

      hook._onClick = function (e) {
        var row = e.target.closest ? e.target.closest(ROW) : null;
        if (!row || !root.contains(row) || !plainClick(e)) return;
        if (hook._ahead) hook._settle(true);
        hook._ahead = paintAhead(root, row);
        if (!hook._ahead) return;
        hook._layout();
        hook._giveUp = window.setTimeout(hook._onLoaded, GIVE_UP_MS);
      };

      hook._onLoaded = function () {
        if (!hook._ahead) return;
        hook._settle(new URL(hook._ahead.href).pathname === window.location.pathname);
      };

      hook._onIntent = function (e) {
        var row = e.target.closest ? e.target.closest(ROW) : null;
        if (!row || !root.contains(row) || row.getAttribute("aria-current") === "true") return;
        var href = row.getAttribute("href");
        if (!href || hook._warmed[href]) return;
        window.clearTimeout(hook._warmTimer);
        hook._warmTimer = window.setTimeout(function () {
          if (!row.isConnected || !row.matches(":hover, :focus")) return;
          hook._warmed[href] = true;
          window.setTimeout(function () {
            delete hook._warmed[href];
          }, WARM_FORGET_MS);
          hook.pushEvent("warm", { href: href });
        }, WARM_DELAY_MS);
      };

      // Capture: a click on a strip opens the strip, and is not a row click.
      root.addEventListener("click", hook._openStrip, true);
      root.addEventListener("keydown", hook._openStrip, true);
      window.addEventListener("resize", hook._queueLayout);
      if (window.ResizeObserver) {
        hook._resize = new window.ResizeObserver(hook._queueLayout);
        hook._resize.observe(root);
      }
      // The server adds and removes panes, and a patch rewrites a pane's
      // attributes: lay out again whenever either happens.
      hook._panes = new window.MutationObserver(hook._layout);
      hook._panes.observe(root, { childList: true });
      hook._marks = new window.MutationObserver(hook._layout);
      hook._marks.observe(root, { subtree: true, attributes: true, attributeFilter: ["data-pane-collapsed"] });
      hook._layout();

      root.addEventListener("click", hook._onClick);
      root.addEventListener("pointerover", hook._onIntent);
      root.addEventListener("focusin", hook._onIntent);
      window.addEventListener("phx:page-loading-stop", hook._onLoaded);
    },

    destroyed: function () {
      var root = this.el;
      window.clearTimeout(this._giveUp);
      window.clearTimeout(this._warmTimer);
      if (this._raf) (window.cancelAnimationFrame || window.clearTimeout)(this._raf);
      if (this._resize) this._resize.disconnect();
      this._panes.disconnect();
      this._marks.disconnect();
      var sheet = root.ownerDocument.getElementById("bp-desk-layout");
      if (sheet) sheet.textContent = "";
      root.removeEventListener("click", this._openStrip, true);
      root.removeEventListener("keydown", this._openStrip, true);
      window.removeEventListener("resize", this._queueLayout);
      root.removeEventListener("click", this._onClick);
      root.removeEventListener("pointerover", this._onIntent);
      root.removeEventListener("focusin", this._onIntent);
      window.removeEventListener("phx:page-loading-stop", this._onLoaded);
    },
  };
})();
