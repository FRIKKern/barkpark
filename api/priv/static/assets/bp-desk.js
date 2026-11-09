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
      };

      hook._onClick = function (e) {
        var row = e.target.closest ? e.target.closest(ROW) : null;
        if (!row || !root.contains(row) || !plainClick(e)) return;
        if (hook._ahead) hook._settle(true);
        hook._ahead = paintAhead(root, row);
        if (!hook._ahead) return;
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

      root.addEventListener("click", hook._onClick);
      root.addEventListener("pointerover", hook._onIntent);
      root.addEventListener("focusin", hook._onIntent);
      window.addEventListener("phx:page-loading-stop", hook._onLoaded);
    },

    destroyed: function () {
      var root = this.el;
      window.clearTimeout(this._giveUp);
      window.clearTimeout(this._warmTimer);
      root.removeEventListener("click", this._onClick);
      root.removeEventListener("pointerover", this._onIntent);
      root.removeEventListener("focusin", this._onIntent);
      window.removeEventListener("phx:page-loading-stop", this._onLoaded);
    },
  };
})();
