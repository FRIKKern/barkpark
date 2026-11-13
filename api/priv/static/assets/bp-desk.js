// bp-desk.js — the desk slice's browser half (/papers/desk-vertical-slice).
//
// The desk slice (BarkparkWeb.Studio.DeskLive) navigates by link: every row is
// an <a> LiveView patches. A patch needs the server, so on its own a click
// shows nothing until the answer lands. This hook makes the click itself
// visible, the way the TanStack Studio's client router does:
//
//   * CLICK  — the row is marked current and an empty pane frame is drawn at
//              once; panes the click closes are hidden. No network in that
//              path. The server's patch then replaces the frame. A reference
//              link and a search hit are answered the same way.
//   * INTENT — hovering or focusing a row asks the server to read the pane it
//              opens ("warm"), so the click that follows opens it with data.
//   * LAYOUT — panes that do not fit collapse to 51 px strips, by the rule the
//              TanStack Studio uses (Sanity's own, see collapsed() below), from
//              the width the browser measures. A click on a strip opens it.
//   * NARROW — below 600 px the desk shows one pane, the last, and its close
//              link reads as Back (Sanity's and the TanStack Studio's rule).
//              The same when the last pane cannot have its minimum width
//              beside the strips of all the others.
//   * RESIZE — a separator after each open pane drags to widen or narrow it,
//              never under its 320 px minimum; ArrowLeft / ArrowRight on it
//              move it 16 px (the TanStack Studio's PaneResizer).
//   * KEYS   — in a list, ArrowDown / ArrowUp move from row to row and Home /
//              End jump to the first / last (Sanity's list keys). Enter is the
//              link's own. A list is one Tab stop: Tab from a row leaves the
//              list. A row that had the focus when it was followed gets it
//              back if the patch dropped it; a pane that opened from its strip
//              or took the place of a closed one gets the focus itself.
//              Cmd+K / Ctrl+K go to the search box.
//   * TIPS   — a close link, a strip and the separator say what they do in a
//              small label, 400 ms after the pointer rests on them or the
//              keyboard reaches them (the TanStack Studio's Tip.tsx). It
//              goes on leave, blur, Escape, a press, a scroll, and with its
//              control or the URL. Anything in the desk marked data-tip="…"
//              (and data-tip-keys="Ctrl+K") gets one too, with no script.
//
// Nothing here decides where a link goes: the href is the server's, and a
// modifier click (new tab, new window) is left to the browser untouched.
//
// Registered as Hooks.Desk on #desk-panes (root.html.heex).
(function () {
  "use strict";

  var ROW = "a[data-desk-row]";
  // The other links that open panes: a reference in a document (it opens the
  // target as the next pane) and a search hit (it opens a whole chain).
  var REF = "a[data-desk-ref]";
  var HIT = "a[data-desk-hit]";
  var OPENER = ROW + ", " + REF;
  var WARM_DELAY_MS = 80;
  var WARM_FORGET_MS = 30000;
  var GIVE_UP_MS = 10000;
  // The edit pane's "…" document-actions buttons (header, footer), and how
  // long a pressed document action waits for its answer to move the focus.
  var DOC_MENU_BUTTON = 'button[aria-haspopup="menu"][id$="-actions-button"]';
  var PRESS_MS = 30000;
  function actionOf(btn) {
    return (btn.getAttribute("phx-click") || "") + "|" + (btn.getAttribute("aria-label") || btn.textContent.trim());
  }

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
      // A strip reads its title alone: every control in its header goes too.
      pane + " > :not(.pane-header), " + pane + " > .pane-header > :not(.pane-header-title), " + pane + " .dk-close { display: none; }\n" +
      pane + " > .pane-header { height: 100%; min-height: 0; padding: 16px 0; border-bottom: 0; justify-content: flex-start; writing-mode: vertical-rl; }\n" +
      // The editor pane has no header of its own: its strip reads its title.
      pane + '[data-pane-editing]::before { content: attr(data-desk-name); display: block; padding: 16px 0; margin: 0 auto; writing-mode: vertical-rl; font-weight: 600; font-size: var(--text-sm); white-space: nowrap; }\n'
    );
  }

  // Below this width the desk shows one pane (Sanity: the pane layout's
  // minimum; barkpark-studio app/src/lib/layout.ts NARROW).
  var NARROW = 600;
  var PANE_MIN = 320;
  var EDGE = 6;

  // One pane on screen: every other pane is hidden, and the pane's own close
  // link (the URL without it) moves to the front and reads as Back.
  function narrowRules(last) {
    var pane = '#desk-panes > [data-pane-index="' + last + '"]';
    return (
      aloneRules(last) +
      pane + " > .pane-header { justify-content: flex-start; gap: 8px; }\n" +
      pane + " .dk-close { order: -1; padding-left: 0; }\n" +
      pane + ' .dk-close::before { content: "\\2190"; }\n' +
      pane + " .dk-close > span { display: none; }\n"
    );
  }

  // One pane shown, the whole width: the narrow layout's, and focus mode's
  // (J26: the server marks the desk and its focused pane).
  function aloneRules(index) {
    var pane = '#desk-panes > [data-pane-index="' + index + '"]';
    return (
      "#desk-panes > [data-pane-index] { display: none; }\n" +
      pane + " { display: flex; width: 100%; min-width: 0; flex: 1 1 auto; }\n"
    );
  }

  // A pane the editor dragged to a width of their own, and the edge to drag.
  function widthRules(index, px) {
    var pane = '#desk-panes > [data-pane-index="' + index + '"]:not([data-desk-leaving])';
    return pane + " { width: " + px + "px; min-width: " + px + "px; flex: 0 0 " + px + "px; }\n";
  }

  // The Studio shell hides every pane but one in its phone bucket (under 640
  // px, and up to 672 while the window widens). The desk lays its own panes
  // out from 600 px up, so there they are shown again; without this the desk
  // is blank from 600 to 639 px.
  var PHONE_RULES = 'html[data-width-bucket="phone"] #desk-panes > [data-pane-index]:not([data-desk-leaving]) { display: flex; }\n';

  // The separator: no room of its own (it lies over the two pane edges).
  var RESIZER = "pane-resizer";
  var STEP = 16;
  var EDGE_RULES =
    "#desk-panes > ." + RESIZER + " { position: relative; z-index: 3; flex: 0 0 " + EDGE + "px; width: " + EDGE + "px; margin: 0 -" + EDGE / 2 +
    "px; cursor: col-resize; touch-action: none; }\n" +
    "#desk-panes > ." + RESIZER + ":focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }\n" +
    // A pane that holds the focus itself (opened from its strip, or in place of a closed one).
    "#desk-panes > [data-pane-index]:focus:not(:focus-visible) { outline: none; }\n" +
    "#desk-panes > [data-pane-index]:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }\n";

  function resizer(doc, label) {
    var el = doc.createElement("div");
    el.className = RESIZER;
    el.setAttribute("role", "separator");
    el.setAttribute("aria-orientation", "vertical");
    el.setAttribute("aria-label", label);
    el.setAttribute("aria-valuemin", String(PANE_MIN));
    el.setAttribute("tabindex", "0");
    el.setAttribute("data-tip", label);
    el.setAttribute("data-tip-side", "right");
    return el;
  }

  function set(el, name, value) {
    if (el.getAttribute(name) !== value) el.setAttribute(name, value);
  }

  // A pane is never narrower than its minimum, nor wider than the desk less
  // what the other panes need (a strip its 51 px, an open pane the width it
  // was given or its minimum): widening one never pushes another off screen.
  function clampWidth(root, pane, px, widths) {
    var rest = 0;
    panes(root).forEach(function (el) {
      if (el === pane || el.hasAttribute("data-desk-leaving")) return;
      rest += el.hasAttribute("data-pane-collapsed") ? STRIP : widths[el.id] || MIN[el.getAttribute("data-pane-kind")] || MIN.list;
    });
    var room = root.clientWidth ? Math.max(PANE_MIN, root.clientWidth - rest) : Infinity;
    return Math.max(PANE_MIN, Math.min(Math.round(px), room));
  }

  // One separator after each open pane but the last; none anywhere else. A
  // LiveView patch that re-draws the panes drops them, and the next layout
  // puts them back.
  function placeResizers(root, open, widths) {
    Array.prototype.slice.call(root.children).forEach(function (el) {
      if (el.classList.contains(RESIZER) && open.indexOf(el.previousElementSibling) < 0) root.removeChild(el);
    });
    open.forEach(function (pane) {
      var next = pane.nextElementSibling;
      if (!next || !next.classList.contains(RESIZER)) {
        next = resizer(root.ownerDocument, root.getAttribute("data-desk-resize") || "Resize pane");
        root.insertBefore(next, pane.nextSibling);
      }
      var now = widths[pane.id] || Math.round(pane.getBoundingClientRect().width) || PANE_MIN;
      set(next, "aria-valuenow", String(now));
      var max = clampWidth(root, pane, Infinity, widths);
      set(next, "aria-valuemax", String(max === Infinity ? now : Math.max(now, max)));
    });
  }

  // A strip says what a press on it does; the name the server gave the pane
  // is kept beside it and put back when the pane opens.
  function nameStrip(root, el, strip) {
    var kept = el.getAttribute("data-desk-name");
    if (strip) {
      if (kept === null) {
        var title = el.querySelector(".pane-header-title");
        kept = el.getAttribute("aria-label") || (title ? title.textContent.trim() : "");
        el.setAttribute("data-desk-name", kept);
      }
      set(el, "aria-label", (root.getAttribute("data-desk-expand") || "Expand %{title}").replace("%{title}", kept));
      set(el, "aria-expanded", "false");
      set(el, "data-tip", el.getAttribute("aria-label"));
      set(el, "data-tip-side", "right");
    } else if (kept !== null) {
      // An open pane is no control: a row in it must not show the strip's tip.
      el.removeAttribute("data-tip");
      el.removeAttribute("data-tip-side");
      if (kept) el.setAttribute("aria-label", kept);
      else el.removeAttribute("aria-label");
      el.removeAttribute("data-desk-name");
      el.removeAttribute("aria-expanded");
    }
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
  function layout(root, focus, widths) {
    widths = widths || {};
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
    // One pane under the narrow width, as the TanStack Studio. Above it a
    // document beside the strips takes what is left, under its 600 px too
    // (640 px: two strips and a 538 px document); the sheet lets it shrink.
    var narrow = width > 0 && shown.length > 0 && width < NARROW;
    // Focus mode: the focused pane alone, nothing a strip, no dividers.
    var alone = root.hasAttribute("data-focus-mode")
      ? shown.filter(function (el) {
          return el.hasAttribute("data-desk-focused");
        })[0]
      : null;
    var flags = width > 0 && !narrow && !alone ? collapsed(kinds, width, at) : kinds.map(function () { return false; });
    var css = TIP_RULES;

    if (narrow) {
      if (!root.hasAttribute("data-narrow")) root.setAttribute("data-narrow", "");
      css += narrowRules((alone || shown[shown.length - 1]).getAttribute("data-pane-index"));
    } else if (alone) {
      root.removeAttribute("data-narrow");
      css += aloneRules(alone.getAttribute("data-pane-index"));
    } else {
      root.removeAttribute("data-narrow");
      css += EDGE_RULES + PHONE_RULES;
      shown.forEach(function (el, i) {
        if (!flags[i] && widths[el.id]) css += widthRules(el.getAttribute("data-pane-index"), widths[el.id]);
      });
    }

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
        // A strip opened by keyboard has the focus. With no tabindex it could
        // not hold it and the browser would hand the focus to <body>.
        if (root.ownerDocument.activeElement === el) el.setAttribute("tabindex", "-1");
        else el.removeAttribute("tabindex");
        el.removeAttribute("role");
      }
      nameStrip(root, el, flags[i]);
    });

    placeResizers(
      root,
      narrow || alone
        ? []
        : shown.filter(function (el, i) {
            return !flags[i] && i < shown.length - 1;
          }),
      widths
    );

    var sheet = styleSheet(root.ownerDocument);
    if (sheet.textContent !== css) sheet.textContent = css;
    return flags;
  }

  // The tip: the words in the popover colours, a hairline and a shadow, as the
  // shell's own popovers. It is never in the way of the pointer.
  var TIP_ID = "bp-desk-tip";
  var TIP_DELAY_MS = 400;
  var TIP_GAP = 4;
  var TIPPED = "[data-tip], a.dk-close";
  var TIP_RULES =
    "#" + TIP_ID + ".hover-tip { position: fixed; z-index: 300; display: flex; max-width: 280px; padding: 3px 8px; border-radius: 3px; " +
    "background: var(--bg-popover, var(--bg)); color: var(--fg); box-shadow: 0 0 0 1px var(--border), 0 2px 8px hsl(var(--bp-shadow-hsl) / 0.2); " +
    "font-size: 13px; line-height: 19px; pointer-events: none; white-space: nowrap; }\n" +
    "#" + TIP_ID + " .tip-line { display: flex; align-items: center; gap: 8px; }\n" +
    "#" + TIP_ID + " .keys { display: inline-flex; gap: 2px; }\n" +
    "#" + TIP_ID + " kbd { height: 15px; font: inherit; font-size: 10px; line-height: 15px; font-weight: 600; padding: 0 4px; border-radius: 3px; " +
    "box-shadow: inset 0 0 0 1px var(--border); color: var(--fg-muted); }\n" +
    "@media (forced-colors: active) { #" + TIP_ID + " { outline: 1px solid CanvasText; } }\n";

  // The control a tip belongs to. A close link names itself in aria-label:
  // its tip reads the same words.
  function tipAnchor(root, target) {
    var el = target && target.closest ? target.closest(TIPPED) : null;
    if (!el || !root.contains(el)) return null;
    if (!el.hasAttribute("data-tip") && el.getAttribute("aria-label")) el.setAttribute("data-tip", el.getAttribute("aria-label"));
    return el.getAttribute("data-tip") ? el : null;
  }

  // The tip's id on the control's aria-describedby, beside any of its own.
  function describe(anchor, on) {
    var ids = (anchor.getAttribute("aria-describedby") || "").split(/\s+/).filter(function (id) {
      return id && id !== TIP_ID;
    });
    if (on) ids.push(TIP_ID);
    if (ids.length) set(anchor, "aria-describedby", ids.join(" "));
    else anchor.removeAttribute("aria-describedby");
  }

  function drawTip(doc, anchor, y) {
    var tip = doc.getElementById(TIP_ID) || doc.createElement("span");
    var text = anchor.getAttribute("data-tip");
    var keys = anchor.getAttribute("data-tip-keys");
    var line = doc.createElement("span");
    tip.id = TIP_ID;
    tip.className = "hover-tip";
    tip.setAttribute("role", "tooltip");
    tip.textContent = "";
    tip.style.position = "fixed";
    line.className = "tip-line";
    line.appendChild(doc.createTextNode(text));
    if (keys) {
      var caps = doc.createElement("span");
      caps.className = "keys";
      keys.split("+").forEach(function (k) {
        var kbd = doc.createElement("kbd");
        kbd.textContent = k;
        caps.appendChild(kbd);
      });
      line.appendChild(caps);
    }
    tip.appendChild(line);
    doc.body.appendChild(tip);
    placeTip(tip, anchor, y);
    // A tip that only says the control's name is not read a second time
    // (Tip.tsx's IconTips); one that says more describes it.
    var name = anchor.getAttribute("aria-label") || anchor.textContent.trim();
    if (keys || text !== name) describe(anchor, true);
  }

  // 4 px under the control and centred on it, over it near the bottom of the
  // window (Sanity's). A strip and the separator run the pane's height: there
  // the tip sits beside them, level with the pointer. Always 4 px inside.
  function placeTip(tip, anchor, y) {
    var at = anchor.getBoundingClientRect();
    var size = tip.getBoundingClientRect();
    var w = size.width || tip.offsetWidth;
    var h = size.height || tip.offsetHeight;
    var left = at.left + at.width / 2 - w / 2;
    var top = at.bottom + 80 >= window.innerHeight ? at.top - TIP_GAP - h : at.bottom + TIP_GAP;
    if (anchor.getAttribute("data-tip-side") === "right") {
      left = at.right + TIP_GAP;
      top = (y === null ? at.top + 16 + h / 2 : y) - h / 2;
    }
    tip.style.left = Math.max(TIP_GAP, Math.min(left, window.innerWidth - TIP_GAP - w)) + "px";
    tip.style.top = Math.max(TIP_GAP, Math.min(top, window.innerHeight - TIP_GAP - h)) + "px";
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
    if (row.matches(ROW)) row.classList.toggle("selected", on);
    if (on) row.setAttribute("aria-current", "true");
    else row.removeAttribute("aria-current");
  }

  // An empty pane, shaped like the one the server draws while its read runs.
  function skeleton(doc, index, kind, title) {
    var pane = doc.createElement("section");
    pane.className = "pane-column dk-pane pane " + (kind || "list") + (kind === "doc" ? " dk-doc" : "");
    pane.setAttribute("data-desk-skeleton", "");
    if (title) pane.setAttribute("aria-label", title);
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
    var previous = pane.querySelector(ROW + '[aria-current="true"], ' + REF + '[aria-current="true"]');

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

    var frames = [];
    if (!wasCurrent) {
      // A reference always opens a document; a row says what it opens.
      var kind = row.getAttribute("data-desk-opens") || "doc";
      frames.push(skeleton(root.ownerDocument, index + 1, kind, label(row)));
      root.insertBefore(frames[0], pane.nextSibling);
    }

    return { row: row, previous: previous, wasCurrent: wasCurrent, leaving: leaving, frames: frames, href: row.href };
  }

  function label(link) {
    var own = link.querySelector(".pane-item-label");
    // The label's own text: a second line under it (the type) is not the title.
    var first = own && own.firstChild && own.firstChild.nodeType === 3 ? own.firstChild.textContent.trim() : "";
    return first || (own || link).textContent.trim();
  }

  // The pane chain a desk URL names, one entry per pane after the first.
  function chainOf(href) {
    try {
      var path = decodeURI(new URL(href, window.location.href).pathname);
      var at = path.indexOf("/_desk/");
      return at < 0 ? [] : path.slice(at + 7).split(";");
    } catch (_e) {
      return null;
    }
  }

  // A search hit opens a whole chain: the panes it shares with the page stay,
  // the rest leave, and one frame is drawn for each pane still to come (the
  // last is the document, titled from the hit).
  function paintAheadHit(root, hit) {
    var to = chainOf(hit.href);
    var from = chainOf(window.location.href);
    if (!to || !from || !to.length || samePage(hit)) return null;

    var same = 0;
    while (same < to.length && same < from.length && to[same] === from[same]) same++;

    var all = panes(root);
    var leaving = all.filter(function (el) {
      return Number(el.getAttribute("data-pane-index")) > same;
    });
    var kept = all.filter(function (el) {
      return Number(el.getAttribute("data-pane-index")) <= same;
    });
    if (!kept.length) return null;
    leaving.forEach(function (el) {
      el.setAttribute("data-desk-leaving", "");
    });

    var frames = [];
    var after = kept[kept.length - 1];
    for (var i = same + 1; i <= to.length; i++) {
      var last = i === to.length;
      var frame = skeleton(root.ownerDocument, i, last ? "doc" : "list", last ? label(hit) : "");
      root.insertBefore(frame, after.nextSibling);
      after = frame;
      frames.push(frame);
    }

    // The hits are put away with the click, as the server does on the patch.
    var box = hit.closest("#desk-search-hits");
    if (box) {
      box.setAttribute("data-desk-leaving", "");
      leaving.push(box);
    }

    return { row: null, previous: null, wasCurrent: true, leaving: leaving, frames: frames, href: hit.href };
  }

  // The search box's lit hit (J19). The keys move it here, at once and with
  // nothing sent; the server draws the first hit lit with each new set of
  // hits, and Enter sends the form's `lit` field (`DeskLive`).
  function searchParts(doc) {
    var list = doc.getElementById("desk-search-options");
    return {
      box: doc.getElementById("desk-search-input"),
      field: doc.getElementById("desk-search-lit"),
      options: list ? Array.prototype.slice.call(list.querySelectorAll('[role="option"]')) : []
    };
  }

  // Which hits these are: a patch with other hits starts the light again.
  function hitsKey(parts) {
    return parts.options
      .map(function (o) {
        return o.getAttribute("href");
      })
      .join("\n");
  }

  // Only what differs is written: the observer that calls this sees its writes.
  function light(parts, at) {
    parts.options.forEach(function (o, i) {
      var on = String(i === at);
      if (o.getAttribute("aria-selected") !== on) o.setAttribute("aria-selected", on);
    });
    var lit = parts.options[at];
    if (parts.box && lit && parts.box.getAttribute("aria-activedescendant") !== lit.id) parts.box.setAttribute("aria-activedescendant", lit.id);
    if (parts.field && parts.field.value !== String(at)) parts.field.value = String(at);
  }

  // The patch landed (the server's panes are in), or it never did.
  function settle(ahead, landed) {
    if (!ahead) return;
    ahead.frames.forEach(function (frame) {
      if (frame.parentNode) frame.parentNode.removeChild(frame);
    });
    ahead.leaving.forEach(function (el) {
      el.removeAttribute("data-desk-leaving");
    });
    if (!landed && ahead.row) {
      if (!ahead.wasCurrent && ahead.row.isConnected) setCurrent(ahead.row, false);
      if (ahead.previous && ahead.previous.isConnected) setCurrent(ahead.previous, true);
    }
  }

  var TABBABLE =
    'a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  // A list is one Tab stop (Sanity's, as the TanStack Studio ports it): Tab
  // from a row goes to the first control after the pane's rows, Shift+Tab to
  // the last one before them. Past the last control the focus leaves for the
  // page, and the next Tab starts at its top.
  function leaveList(e, pane) {
    var doc = pane.ownerDocument;
    var rows = Array.prototype.slice.call(pane.querySelectorAll(ROW));
    var edge = e.shiftKey ? rows[0] : rows[rows.length - 1];
    var all = Array.prototype.filter.call(doc.querySelectorAll(TABBABLE), function (el) {
      return el.tabIndex >= 0 && el.getClientRects().length && rows.indexOf(el) < 0;
    });
    var after = function (el) {
      return !!(edge.compareDocumentPosition(el) & 4);
    };
    var to = e.shiftKey ? all.filter(function (el) { return !after(el); }).pop() : all.filter(after)[0];
    e.preventDefault();
    if (to) return to.focus();
    var end = doc.createElement("span");
    end.tabIndex = -1;
    doc.body.appendChild(end);
    end.focus({ preventScroll: true });
    doc.body.removeChild(end);
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

      // Widths the editor dragged, by pane id: they last as long as the pane.
      hook._widths = {};
      hook._drag = null;

      hook._onPointerDown = function (e) {
        var handle = e.target.closest ? e.target.closest("." + RESIZER) : null;
        var pane = handle && handle.parentNode === root ? handle.previousElementSibling : null;
        if (e.button !== 0 || !pane || !pane.id) return;
        e.preventDefault();
        hook._drag = { id: pane.id, x: e.clientX, width: pane.getBoundingClientRect().width };
        window.addEventListener("pointermove", hook._onPointerMove);
        window.addEventListener("pointerup", hook._onPointerUp);
        window.addEventListener("pointercancel", hook._onPointerUp);
      };
      // ArrowLeft / ArrowRight on the separator: 16 px a press.
      hook._onResizeKey = function (e) {
        var handle = e.target.classList && e.target.classList.contains(RESIZER) ? e.target : null;
        var step = { ArrowLeft: -STEP, ArrowRight: STEP }[e.key];
        var pane = handle && handle.previousElementSibling;
        if (!step || !pane || !pane.id || e.altKey || e.metaKey || e.ctrlKey) return;
        e.preventDefault();
        var from = hook._widths[pane.id] || pane.getBoundingClientRect().width || PANE_MIN;
        hook._widths[pane.id] = clampWidth(root, pane, from + step, hook._widths);
        hook._layout();
      };
      hook._onPointerMove = function (e) {
        var drag = hook._drag;
        if (!drag) return;
        var dragged = root.ownerDocument.getElementById(drag.id);
        if (!dragged) return;
        hook._widths[drag.id] = clampWidth(root, dragged, drag.width + e.clientX - drag.x, hook._widths);
        hook._layout();
      };
      hook._onPointerUp = function () {
        hook._drag = null;
        window.removeEventListener("pointermove", hook._onPointerMove);
        window.removeEventListener("pointerup", hook._onPointerUp);
        window.removeEventListener("pointercancel", hook._onPointerUp);
        // Forget panes that are gone.
        Object.keys(hook._widths).forEach(function (id) {
          if (!root.ownerDocument.getElementById(id)) delete hook._widths[id];
        });
      };
      root.addEventListener("pointerdown", hook._onPointerDown);
      root.addEventListener("keydown", hook._onResizeKey);

      // A strip the editor opened keeps the focus until the URL changes.
      hook._focus = null;
      hook._layout = function () {
        if (hook._focus && hook._focus.path !== window.location.pathname) hook._focus = null;
        var flags = layout(root, hook._focus ? hook._focus.index : null, hook._widths);
        // A focused strip the layout itself opened (the window widened) was
        // lent a tabindex there: the pane holds it as an opened strip does,
        // so it is taken back when the focus leaves.
        var lent = root.ownerDocument.activeElement;
        if (!hook._held && lent && lent.parentNode === root && lent.getAttribute("tabindex") === "-1" && lent.hasAttribute("data-pane-index") && !lent.hasAttribute("data-pane-collapsed")) {
          hook._held = { path: window.location.pathname, index: lent.getAttribute("data-pane-index") };
        }
        if (hook._keepHeld) hook._keepHeld();
        if (hook._keepSeparator) hook._keepSeparator();
        // A strip that opened is no control: its tip goes. Any other shown tip
        // follows its control (a separator moved by the keys).
        var tip = hook._tip && hook._tip.anchor ? hook._tip : null;
        var tipEl = tip && !tip.timer ? root.ownerDocument.getElementById(TIP_ID) : null;
        if (tip && !tip.anchor.getAttribute("data-tip")) hook._hideTip();
        else if (tipEl) placeTip(tipEl, tip.anchor, tip.y);
        return flags;
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
        // The strip was the focus (a button); the pane it became takes it.
        hook._holdPane(pane);
      };

      // The focus on a pane itself, kept through the patches that rewrite its
      // attributes, until the editor moves it or the URL changes.
      hook._held = null;
      hook._holdPane = function (pane) {
        if (!pane) return;
        hook._held = { path: window.location.pathname, index: pane.getAttribute("data-pane-index") };
        if (pane.getAttribute("tabindex") === null) pane.setAttribute("tabindex", "-1");
        pane.focus({ preventScroll: true });
      };
      // The pane lets go: the tabindex it was lent to hold the focus goes
      // with it, so an open pane is not left a focus target of its own.
      hook._release = function () {
        var held = hook._held;
        hook._held = null;
        if (!held) return;
        panes(root).forEach(function (el) {
          var lent = el.getAttribute("data-pane-index") === held.index && el.getAttribute("tabindex") === "-1";
          if (lent && !el.hasAttribute("data-pane-collapsed")) el.removeAttribute("tabindex");
        });
      };
      hook._keepHeld = function () {
        var held = hook._held;
        var doc = root.ownerDocument;
        if (!held) return;
        if (held.path !== window.location.pathname) {
          hook._release();
          return;
        }
        var pane = panes(root).filter(function (el) {
          return el.getAttribute("data-pane-index") === held.index && !el.hasAttribute("data-desk-leaving");
        })[0];
        if (doc.activeElement && doc.activeElement !== doc.body) {
          if (doc.activeElement !== pane) hook._release();
          return;
        }
        if (!pane) return;
        if (pane.getAttribute("tabindex") === null) pane.setAttribute("tabindex", "-1");
        pane.focus({ preventScroll: true });
      };
      // A patch that re-draws the panes drops the separators, and the focused
      // one with them: the one put back in its place takes the focus again.
      hook._sep = null;
      hook._keepSeparator = function () {
        var doc = root.ownerDocument;
        if (!hook._sep || (doc.activeElement && doc.activeElement !== doc.body)) return;
        var pane = doc.getElementById(hook._sep);
        var next = pane && pane.parentNode === root ? pane.nextElementSibling : null;
        if (next && next.classList.contains(RESIZER)) next.focus({ preventScroll: true });
        else hook._sep = null;
      };
      // The editor moved the focus, or pressed somewhere: the pane lets go.
      hook._letGo = function (e) {
        var on = e.target && e.target.classList && e.target.classList.contains(RESIZER) && e.target.parentNode === root;
        hook._sep = on && e.target.previousElementSibling ? e.target.previousElementSibling.id : null;
        var held = hook._held;
        if (!held) return;
        var own = e.type === "focusin" && e.target.parentNode === root && e.target.getAttribute("data-pane-index") === held.index;
        if (!own) hook._release();
      };

      hook._onClick = function (e) {
        var hit = e.currentTarget !== root;
        var row = e.target.closest ? e.target.closest(hit ? HIT : OPENER) : null;
        if (!row || root.contains(row) === hit || !plainClick(e)) return;
        hook._refocus = !hit && root.ownerDocument.activeElement === row ? row.getAttribute("href") : null;
        // The click before this one has not landed: its answer is still to
        // come, and is not this click's (see _onLoaded).
        if (hook._ahead) {
          hook._earlier += 1;
          hook._settle(true);
        }
        hook._ahead = hit ? paintAheadHit(root, row) : paintAhead(root, row);
        if (!hook._ahead) return;
        hook._layout();
        hook._giveUp = window.setTimeout(hook._onLoaded, GIVE_UP_MS);
      };

      // Clicks painted while an earlier one was still on its way. Each of
      // those still gets its own page-loading-stop, with the URL not yet this
      // click's; that is no sign this click failed, so its frame stays. The
      // give-up timer (no event) always settles.
      hook._earlier = 0;
      hook._onLoaded = function (e) {
        if (hook._ahead) {
          var landed = new URL(hook._ahead.href).pathname === window.location.pathname;
          if (!landed && e && hook._earlier > 0) {
            hook._earlier -= 1;
            return;
          }
          hook._settle(landed);
        }
        hook._earlier = 0;
        hook._giveFocusBack();
      };

      // Following a row re-draws panes, and a re-drawn row loses the focus to
      // <body>. The row with the same href takes it back; a focus the patch
      // placed somewhere on purpose is left alone.
      hook._refocus = null;
      hook._giveFocusBack = function () {
        var href = hook._refocus;
        hook._refocus = null;
        var doc = root.ownerDocument;
        var moved = hook._path !== window.location.pathname;
        hook._path = window.location.pathname;
        var inside = hook._wasInside;
        hook._wasInside = false;
        if (doc.activeElement && doc.activeElement !== doc.body) return;
        var again =
          href &&
          Array.prototype.filter.call(root.querySelectorAll(OPENER), function (a) {
            return a.getAttribute("href") === href;
          })[0];
        if (again) return again.focus({ preventScroll: true });
        // The focused control went with its pane (a close link, a reference in
        // a pane that closed): the last pane takes the focus, so the keyboard
        // stays in the desk. Only when the keyboard had it there before.
        if (moved && inside) {
          var left = panes(root).filter(function (el) {
            return !el.hasAttribute("data-desk-leaving");
          });
          hook._holdPane(left[left.length - 1]);
        }
      };
      // Whether the focus was on a link of the desk when it was followed (a
      // mouse click focuses the link too).
      hook._path = window.location.pathname;
      hook._wasInside = false;
      hook._noteFocus = function (e) {
        var link = e.target.closest ? e.target.closest("a[href]") : null;
        if (e.type === "keydown" && e.key !== "Enter") return;
        hook._wasInside = !!link && root.ownerDocument.activeElement === link;
      };

      // A document action pressed from the keyboard that the answer takes
      // away, disables or turns into another (the patch makes Publish the
      // Unpublish button, focus and all: a second Enter unpublished) hands
      // the focus to the edit pane's last "…", the one Sanity puts beside
      // Publish. Anything that took the focus meanwhile keeps it.
      hook._pressed = null;
      hook._notePress = function (e) {
        if (e.key !== "Enter" && e.key !== " ") return;
        var doc = root.ownerDocument;
        var btn = e.target.closest ? e.target.closest("[data-pane-editing] bp-overflow-menu button") : null;
        if (!btn || !root.contains(btn) || doc.activeElement !== btn) return;
        hook._pressed = { btn: btn, pane: btn.closest("[data-pane-editing]"), was: actionOf(btn) };
        window.clearTimeout(hook._pressTimer);
        hook._pressTimer = window.setTimeout(function () {
          hook._pressed = null;
          hook._pressWatch.disconnect();
        }, PRESS_MS);
        hook._pressWatch.observe(root, { subtree: true, childList: true, attributes: true, attributeFilter: ["disabled", "aria-label", "phx-click"] });
      };
      hook._keepPressed = function () {
        var p = hook._pressed;
        var doc = root.ownerDocument;
        var at = doc.activeElement;
        if (p && at && at !== doc.body && at !== p.btn) p = null;
        if (p && p.btn.isConnected && !p.btn.disabled && actionOf(p.btn) === p.was) return;
        hook._pressed = null;
        hook._pressWatch.disconnect();
        if (!p) return;
        var menus = p.pane.isConnected ? p.pane.querySelectorAll(DOC_MENU_BUTTON) : [];
        if (menus.length) menus[menus.length - 1].focus({ preventScroll: true });
      };
      hook._pressWatch = new window.MutationObserver(hook._keepPressed);

      hook._onKey = function (e) {
        var row = e.target.closest ? e.target.closest(ROW) : null;
        if (!row || !root.contains(row) || e.metaKey || e.ctrlKey || e.altKey) return;
        var pane = paneOf(root, row);
        if (!pane) return;
        if (e.key === "Tab") return leaveList(e, pane);
        var step = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity }[e.key];
        if (step === undefined || e.shiftKey) return;
        var rows = Array.prototype.slice.call(pane.querySelectorAll(ROW));
        var to = Math.min(rows.length - 1, Math.max(0, rows.indexOf(row) + step));
        e.preventDefault();
        if (step !== 1 || !hook._owed || hook._owed.row !== row) hook._forgive();
        // J41: past the last row of a list that is reading more (its
        // `.dk-list-more` room is there), the steps are owed and taken once
        // the rows land, as on a loaded list.
        if (rows[to] === row && step === 1 && pane.querySelector(".dk-list-more")) return hook._owe(row);
        if (rows[to] === row) return;
        hook._step(rows[to]);
      };
      hook._step = function (to) {
        to.focus({ preventScroll: true });
        if (to.scrollIntoView) to.scrollIntoView({ block: "nearest" });
      };
      // A held key owes no more than this; the focus leaving the row owes none.
      var OWED_MAX = 50;
      hook._owed = null;
      hook._forgive = function () {
        if (hook._owed) {
          hook._owed.watch.disconnect();
          hook._owed.row.removeEventListener("focusout", hook._forgive);
        }
        hook._owed = null;
      };
      hook._owe = function (row) {
        var list = row.closest('[role="list"]');
        if (!list) return;
        if (!hook._owed) {
          var watch = new window.MutationObserver(function () {
            var owed = hook._owed;
            var rows = Array.prototype.slice.call(list.querySelectorAll(ROW));
            var at = rows.indexOf(owed.row);
            if (at < 0 || at === rows.length - 1) return;
            hook._forgive();
            if (root.ownerDocument.activeElement === owed.row) hook._step(rows[Math.min(rows.length - 1, at + owed.steps)]);
          });
          watch.observe(list, { childList: true });
          row.addEventListener("focusout", hook._forgive);
          hook._owed = { row: row, steps: 0, watch: watch };
        }
        hook._owed.steps = Math.min(OWED_MAX, hook._owed.steps + 1);
      };

      hook._onIntent = function (e) {
        var row = e.target.closest ? e.target.closest(ROW) : null;
        if (!row || !root.contains(row) || row.getAttribute("aria-current") === "true") return;
        // A finger does not hover: its pointerover is the tap itself.
        if (e.pointerType === "touch") return;
        var href = row.getAttribute("href");
        if (!href || hook._warmed[href]) return;
        window.clearTimeout(hook._warmTimer);
        hook._warmTimer = window.setTimeout(function () {
          if (!row.isConnected || !row.matches(":hover, :focus")) return;
          // Followed in the meantime (a quick click, a tap): the pane is being read already.
          if (row.getAttribute("aria-current") === "true") return;
          hook._warmed[href] = true;
          window.setTimeout(function () {
            delete hook._warmed[href];
          }, WARM_FORGET_MS);
          hook.pushEvent("warm", { href: href });
        }, WARM_DELAY_MS);
      };

      // The desk's popover menus (the edit pane's Share and "…", a list's
      // "List options"): opened, the first item has the focus and the button
      // says it is expanded; the arrows move between the items; Tab leaves it
      // closed. Escape and a click outside are the popover's own, and both
      // give the focus back to the button.
      var MENU = ".dk-doc-menu-list[popover], .dk-list-menu[popover]";
      var MENU_ITEM = '[role="menuitem"]:not([disabled]), [role="menuitemradio"]:not([disabled])';
      hook._onDocMenu = function (e) {
        var menu = e.target;
        if (!menu.matches || !menu.matches(MENU)) return;
        var open = e.newState === "open";
        var button = root.ownerDocument.getElementById(menu.id + "-button");
        if (button) button.setAttribute("aria-expanded", open ? "true" : "false");
        var first = menu.querySelector(MENU_ITEM);
        if (open && first) first.focus();
      };
      hook._onDocMenuKey = function (e) {
        var menu = e.target.closest ? e.target.closest(MENU) : null;
        if (!menu || e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === "Tab") return menu.hidePopover();
        var step = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity }[e.key];
        if (step === undefined) return;
        var items = Array.prototype.slice.call(menu.querySelectorAll(MENU_ITEM));
        if (!items.length) return;
        e.preventDefault();
        var at = items.indexOf(root.ownerDocument.activeElement);
        var to = Math.abs(step) === Infinity ? (step < 0 ? 0 : items.length - 1) : (at + step + items.length) % items.length;
        items[to].focus();
      };

      // A list is one Tab stop coming in, too: Tab or Shift+Tab that would
      // land on one of its rows from outside them lands on its selected row
      // (its first when none is), never on its last (leaveList is the way out).
      hook._onEnterList = function (e) {
        if (e.key !== "Tab" || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        var from = e.target;
        if (!from || !from.matches || from.matches(ROW)) return;
        var all = Array.prototype.filter.call(root.ownerDocument.querySelectorAll(TABBABLE), function (el) {
          return el.tabIndex >= 0 && el.getClientRects().length;
        });
        var at = all.indexOf(from);
        var next = at < 0 ? null : all[at + (e.shiftKey ? -1 : 1)];
        if (!next || !next.matches(ROW) || !root.contains(next)) return;
        var pane = next.closest("[data-pane-index]");
        var to = pane && (pane.querySelector(ROW + ".selected") || pane.querySelector(ROW));
        if (!to || to === next) return;
        e.preventDefault();
        to.focus();
      };

      // The search box's light: kept for the hits it was moved over.
      hook._search = { key: "", at: 0 };
      hook._relight = function () {
        var parts = searchParts(root.ownerDocument);
        var key = hitsKey(parts);
        if (key !== hook._search.key) hook._search = { key: key, at: 0 };
        else if (parts.options.length) light(parts, hook._search.at);
      };
      hook._relight();
      var searchArea = root.ownerDocument.querySelector(".dk-search");
      if (searchArea && window.MutationObserver) {
        hook._searchMarks = new window.MutationObserver(hook._relight);
        hook._searchMarks.observe(searchArea, {
          subtree: true,
          childList: true,
          attributes: true,
          attributeFilter: ["aria-selected", "aria-activedescendant", "value"]
        });
      }

      // Cmd+K / Ctrl+K: the search box, unless something else took the key.
      // In the box, ArrowDown and ArrowUp move the lit hit, and Enter's form
      // carries it.
      hook._onSearchKey = function (e) {
        var inBox = e.target && e.target.id === "desk-search-input";
        if (inBox && !e.altKey && !e.metaKey && !e.ctrlKey && (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Enter")) {
          var parts = searchParts(root.ownerDocument);
          if (!parts.options.length) return;
          if (hitsKey(parts) !== hook._search.key) hook._search = { key: hitsKey(parts), at: 0 };
          if (e.key !== "Enter") {
            e.preventDefault();
            var to = hook._search.at + (e.key === "ArrowDown" ? 1 : -1);
            hook._search.at = Math.max(0, Math.min(parts.options.length - 1, to));
            var lit = parts.options[hook._search.at];
            if (lit.scrollIntoView) lit.scrollIntoView({ block: "nearest" });
          }
          light(parts, hook._search.at);
          return;
        }
        if (e.defaultPrevented || !(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey || String(e.key).toLowerCase() !== "k") return;
        var box = root.ownerDocument.getElementById("desk-search-input");
        if (!box) return;
        e.preventDefault();
        box.focus();
        if (box.select) box.select();
      };

      // The draft in the editor was discarded elsewhere (`Desk.Discarded`):
      // the event comes after the patch that put the published version in the
      // form. The patch leaves the focused field as typed, so it is set from
      // the published values; then the page hears that this browser has the
      // new form, and takes its saves again.
      hook._onDiscarded = function (payload) {
        // The answer goes whatever the value step does: until it arrives the
        // page drops every save from this form.
        try {
          var at = root.ownerDocument.activeElement;
          var values = (payload && payload.values) || {};
          if (at && at.form && at.form.id === "editor-form" && root.contains(at.form) && at.name &&
              Object.prototype.hasOwnProperty.call(values, at.name) && at.type !== "checkbox" && at.type !== "radio") {
            at.value = values[at.name];
          }
        } finally {
          hook.pushEvent("desk-discard-seen", {});
        }
      };
      if (hook.handleEvent) hook.handleEvent("desk:discarded", hook._onDiscarded);
      // B11: closing the tab asks first while an edit in the editor has not
      // reached the server: typed and not yet sent (the field's debounce),
      // sent and not yet answered (LiveView marks the form with
      // `data-phx-ref-loading` until the reply), or answered with a failed
      // save (the edit pane's `data-desk-save`, the server's save token).
      // A change LiveView sends carries the whole form as it is then, so its
      // going out pays what was typed before it. The layout's own
      // beforeunload still hands the focused field's change to the socket.
      hook._typed = false;
      var editForm = function () {
        return root.querySelector("[data-pane-editing] form#editor-form");
      };
      // A field of the document only (named doc[...]): a widget's own box
      // (the reference picker's search) never goes through the form, and
      // would otherwise ask for ever.
      hook._onTyped = function (e) {
        var t = e.target;
        var form = t && t.closest ? t.closest("form#editor-form") : null;
        if (form && root.contains(form) && typeof t.name === "string" && t.name.indexOf("doc[") === 0) hook._typed = true;
      };
      hook._sending = new window.MutationObserver(function (changes) {
        changes.forEach(function (change) {
          if (change.target.id === "editor-form" && change.target.hasAttribute("data-phx-ref-loading")) hook._typed = false;
        });
      });
      hook._sending.observe(root, { subtree: true, attributes: true, attributeFilter: ["data-phx-ref-loading"] });
      hook._owes = function () {
        var form = editForm();
        if (!form) return false;
        var pane = form.closest("[data-pane-editing]");
        return hook._typed || form.hasAttribute("data-phx-ref-loading") ||
          (!!pane && pane.getAttribute("data-desk-save") === "Save failed");
      };
      hook._onUnload = function (e) {
        if (!hook._owes()) return;
        e.preventDefault();
        e.returnValue = "";
      };
      root.addEventListener("input", hook._onTyped, true);
      window.addEventListener("beforeunload", hook._onUnload);

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
      hook._marks = new window.MutationObserver(function (changes) {
        // The desk's own marks only: the editor inside a pane changes its own.
        var ours = changes.some(function (change) {
          return change.target === root || change.target.parentNode === root;
        });
        if (ours) hook._layout();
      });
      hook._marks.observe(root, { subtree: true, attributes: true, attributeFilter: ["data-pane-collapsed", "data-narrow", "tabindex", "data-focus-mode", "data-desk-focused"] });
      hook._layout();

      root.addEventListener("click", hook._noteFocus, true);
      root.addEventListener("keydown", hook._noteFocus, true);
      root.addEventListener("keydown", hook._notePress, true);
      root.ownerDocument.addEventListener("focusin", hook._letGo);
      root.ownerDocument.addEventListener("pointerdown", hook._letGo, true);
      root.addEventListener("click", hook._onClick);
      // The search box sits beside the panes, not in them.
      root.ownerDocument.addEventListener("click", hook._onClick);
      root.ownerDocument.addEventListener("keydown", hook._onSearchKey);
      root.ownerDocument.addEventListener("keydown", hook._onEnterList);
      root.addEventListener("keydown", hook._onKey);
      // `toggle` does not bubble: caught on the way down.
      root.addEventListener("toggle", hook._onDocMenu, true);
      root.addEventListener("keydown", hook._onDocMenuKey);
      root.addEventListener("pointerover", hook._onIntent);
      root.addEventListener("focusin", hook._onIntent);
      window.addEventListener("phx:page-loading-stop", hook._onLoaded);

      // TIPS. `quiet` is a control whose tip was put away (Escape, a press):
      // it stays away until the pointer or the focus leaves that control.
      hook._tip = { anchor: null, timer: 0, path: null, y: null, quiet: null };
      hook._hideTip = function (quiet) {
        var tip = hook._tip;
        window.clearTimeout(tip.timer);
        tip.timer = 0;
        hook._tipGone.disconnect();
        if (tip.anchor) describe(tip.anchor, false);
        tip.quiet = quiet ? tip.anchor : null;
        tip.anchor = null;
        var el = root.ownerDocument.getElementById(TIP_ID);
        if (el) el.parentNode.removeChild(el);
      };
      hook._showTip = function (e) {
        // A finger does not hover: its pointerover is the tap itself.
        if (e.pointerType === "touch") return;
        var tip = hook._tip;
        var anchor = tipAnchor(root, e.target);
        if (!anchor || anchor === tip.anchor || anchor === tip.quiet) return;
        // The focus a click gives is not keyboard focus (Tip.tsx).
        if (e.type === "focusin" && !anchor.matches(":focus-visible")) return;
        hook._hideTip();
        tip.anchor = anchor;
        tip.path = window.location.pathname;
        tip.y = e.type === "focusin" ? null : e.clientY;
        tip.timer = window.setTimeout(function () {
          tip.timer = 0;
          if (!anchor.isConnected || tip.path !== window.location.pathname) return hook._hideTip();
          drawTip(root.ownerDocument, anchor, tip.y);
          hook._tipGone.observe(root, { childList: true, subtree: true });
        }, TIP_DELAY_MS);
      };
      // The pointer or the focus left the control (not for one of its own parts).
      hook._leaveTip = function (e) {
        var tip = hook._tip;
        var from = tip.anchor || tip.quiet;
        if (!from || !from.contains(e.target) || (e.relatedTarget && from.contains(e.relatedTarget))) return;
        if (tip.anchor === from) hook._hideTip();
        tip.quiet = null;
      };
      hook._putTipAway = function (e) {
        if (e.type === "keydown" && e.key !== "Escape") return;
        if (hook._tip.anchor || e.type !== "keydown") hook._hideTip(true);
      };
      // The control left the page (its pane closed), or the URL moved on.
      hook._tipGone = new window.MutationObserver(function () {
        if (hook._tip.anchor && !hook._tip.anchor.isConnected) hook._hideTip();
      });
      hook._tipUrl = function () {
        if (hook._tip.anchor && hook._tip.path !== window.location.pathname) hook._hideTip();
      };
      root.addEventListener("pointerover", hook._showTip);
      root.addEventListener("focusin", hook._showTip);
      root.addEventListener("pointerout", hook._leaveTip);
      root.addEventListener("focusout", hook._leaveTip);
      root.ownerDocument.addEventListener("keydown", hook._putTipAway);
      root.ownerDocument.addEventListener("pointerdown", hook._putTipAway, true);
      root.ownerDocument.addEventListener("click", hook._putTipAway, true);
      window.addEventListener("scroll", hook._putTipAway, true);
      window.addEventListener("popstate", hook._tipUrl);
      window.addEventListener("phx:page-loading-stop", hook._tipUrl);

      // A NEW DOCUMENT'S FIRST FIELD. The desk names a field's input by its
      // bare path (`id="title"`), where the page's `bpFocusNewDoc`
      // (root.html.heex) looks for `doc-field-<id>-…`. After a "+" create the
      // new document's first field takes the focus here, on the same terms:
      // wait up to 4 s for its editor, skip hidden, read-only and disabled
      // fields, and stop at the user's first key or press.
      hook._focusNewDoc = function (e) {
        var id = e.detail && e.detail.id;
        if (!id) return;
        var doc = root.ownerDocument;
        var stop = Date.now() + 4000;
        var interrupted = false;
        var interrupt = function () {
          interrupted = true;
        };
        var done = function () {
          doc.removeEventListener("keydown", interrupt, true);
          doc.removeEventListener("pointerdown", interrupt, true);
        };
        doc.addEventListener("keydown", interrupt, true);
        doc.addEventListener("pointerdown", interrupt, true);
        var attempt = function () {
          if (interrupted || !root.isConnected) return done();
          var pane = root.querySelector("[data-pane-editing]");
          // The edit pane's id is its view's plus "-editor" (`DeskLive`).
          var tail = pane ? pane.id.replace(/-editor$/, "").slice(-id.length - 1) : "";
          var mine = tail === ":" + id || tail === ";" + id;
          var fields = mine ? pane.querySelectorAll("#editor-form .field input, #editor-form .field textarea, #editor-form .field select") : [];
          var field = Array.prototype.find.call(fields, function (el) {
            return el.type !== "hidden" && !el.disabled && !el.readOnly && !el.closest("[hidden]");
          });
          if (field) {
            field.focus();
            return done();
          }
          if (Date.now() < stop) window.setTimeout(attempt, 100);
          else done();
        };
        attempt();
      };
      window.addEventListener("phx:bp:focus-new-doc", hook._focusNewDoc);

      // "Share document": an item with `data-desk-copy` puts its text on the
      // clipboard (a path gets the page's origin in front) and the menu's
      // toast says so, or says the copy failed. The browser's clipboard, or
      // the old `execCommand` where it has none (a page not on https).
      hook._onCopy = function (e) {
        var item = e.target.closest ? e.target.closest("[data-desk-copy]") : null;
        if (!item || !root.contains(item)) return;
        var text = item.getAttribute("data-desk-copy");
        if (item.hasAttribute("data-desk-copy-origin")) text = window.location.origin + text;
        var menu = item.closest("[popover]");
        var toast = menu && menu.parentNode.querySelector(".dk-toast");
        var say = function (ok) {
          if (!toast) return;
          window.clearTimeout(hook._toastTimer);
          // Shown first, then filled: the change is what a screen reader reads.
          if (toast.showPopover && !toast.matches(":popover-open")) toast.showPopover();
          toast.textContent = ok ? item.getAttribute("data-desk-copied") : menu.getAttribute("data-desk-copy-failed");
          hook._toastTimer = window.setTimeout(function () {
            toast.textContent = "";
            if (toast.hidePopover && toast.matches(":popover-open")) toast.hidePopover();
          }, 4000);
        };
        var fallback = function () {
          var back = root.ownerDocument.activeElement;
          var area = root.ownerDocument.createElement("textarea");
          area.value = text;
          area.setAttribute("readonly", "");
          area.style.position = "fixed";
          area.style.opacity = "0";
          root.ownerDocument.body.appendChild(area);
          area.select();
          var ok = false;
          try {
            ok = root.ownerDocument.execCommand("copy");
          } catch (_err) {
            ok = false;
          }
          area.remove();
          if (back && back.isConnected && back.focus) back.focus();
          say(ok);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () {
            say(true);
          }, fallback);
        } else {
          fallback();
        }
      };
      root.addEventListener("click", hook._onCopy);

      // The Inspect dialog (desk/inspect_dialog.ex). Ctrl+Alt+I while a
      // document is open asks the page for it (by the key's place: Alt changes
      // the letter on a Mac); the page puts `inspect=on` in the URL, and it
      // opens as a modal when it is mounted. Escape or its close
      // button closes it, which tells the page, and the browser gives the
      // focus back to where it was. Its two tabs switch here, by click or
      // the arrow keys.
      hook._onInspectKey = function (e) {
        if (!e.ctrlKey || !e.altKey || e.metaKey || e.shiftKey || e.code !== "KeyI") return;
        // As soon as a document is open, wherever the focus is: a click on
        // a list row leaves it on the row (Sanity's, keyboard:158).
        if (!root.querySelector("[data-pane-editing]")) return;
        e.preventDefault();
        hook.pushEvent("desk-inspect", { open: true });
      };
      hook._onShowModal = function (e) {
        var dialog = e.target;
        if (dialog.matches && dialog.matches("dialog[data-desk-inspect]") && !dialog.open) dialog.showModal();
      };
      hook._onInspectClose = function (e) {
        if (e.target.matches && e.target.matches("dialog[data-desk-inspect]")) hook.pushEvent("desk-inspect", { open: false });
      };
      hook._inspectTab = function (tab) {
        var tabs = Array.prototype.slice.call(tab.parentNode.querySelectorAll("[data-desk-inspect-tab]"));
        tabs.forEach(function (t) {
          var on = t === tab;
          t.setAttribute("aria-selected", on ? "true" : "false");
          if (on) t.removeAttribute("tabindex");
          else t.setAttribute("tabindex", "-1");
          var panel = root.ownerDocument.getElementById(t.getAttribute("aria-controls"));
          if (panel) panel.hidden = !on;
        });
        tab.focus();
      };
      hook._onInspectTab = function (e) {
        var tab = e.target.closest ? e.target.closest("[data-desk-inspect-tab]") : null;
        if (!tab) return;
        if (e.type === "click") return hook._inspectTab(tab);
        var step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
        if (!step) return;
        e.preventDefault();
        var tabs = Array.prototype.slice.call(tab.parentNode.querySelectorAll("[data-desk-inspect-tab]"));
        hook._inspectTab(tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length]);
      };
      root.addEventListener("keydown", hook._onInspectKey);
      root.addEventListener("desk:show-modal", hook._onShowModal);
      // `close` does not bubble: caught on the way down.
      root.addEventListener("close", hook._onInspectClose, true);
      root.addEventListener("click", hook._onInspectTab);
      root.addEventListener("keydown", hook._onInspectTab);
    },

    destroyed: function () {
      var root = this.el;
      window.clearTimeout(this._giveUp);
      window.clearTimeout(this._warmTimer);
      if (this._raf) (window.cancelAnimationFrame || window.clearTimeout)(this._raf);
      if (this._resize) this._resize.disconnect();
      this._panes.disconnect();
      this._marks.disconnect();
      this._forgive();
      this._sending.disconnect();
      root.removeEventListener("input", this._onTyped, true);
      window.removeEventListener("beforeunload", this._onUnload);
      var sheet = root.ownerDocument.getElementById("bp-desk-layout");
      if (sheet) sheet.textContent = "";
      root.removeEventListener("pointerdown", this._onPointerDown);
      window.removeEventListener("pointermove", this._onPointerMove);
      window.removeEventListener("pointerup", this._onPointerUp);
      root.removeAttribute("data-narrow");
      root.removeEventListener("click", this._openStrip, true);
      root.removeEventListener("keydown", this._openStrip, true);
      window.removeEventListener("resize", this._queueLayout);
      root.removeEventListener("click", this._onClick);
      root.removeEventListener("click", this._noteFocus, true);
      root.removeEventListener("keydown", this._noteFocus, true);
      root.removeEventListener("keydown", this._notePress, true);
      window.clearTimeout(this._pressTimer);
      this._pressWatch.disconnect();
      root.ownerDocument.removeEventListener("focusin", this._letGo);
      root.ownerDocument.removeEventListener("pointerdown", this._letGo, true);
      root.removeEventListener("keydown", this._onResizeKey);
      root.ownerDocument.removeEventListener("click", this._onClick);
      root.ownerDocument.removeEventListener("keydown", this._onSearchKey);
      root.ownerDocument.removeEventListener("keydown", this._onEnterList);
      if (this._searchMarks) this._searchMarks.disconnect();
      window.removeEventListener("pointercancel", this._onPointerUp);
      Array.prototype.slice.call(root.children).forEach(function (el) {
        if (el.classList.contains(RESIZER)) root.removeChild(el);
      });
      root.removeEventListener("keydown", this._onKey);
      root.removeEventListener("toggle", this._onDocMenu, true);
      root.removeEventListener("keydown", this._onDocMenuKey);
      root.removeEventListener("pointerover", this._onIntent);
      root.removeEventListener("focusin", this._onIntent);
      window.removeEventListener("phx:page-loading-stop", this._onLoaded);
      this._hideTip();
      root.removeEventListener("pointerover", this._showTip);
      root.removeEventListener("focusin", this._showTip);
      root.removeEventListener("pointerout", this._leaveTip);
      root.removeEventListener("focusout", this._leaveTip);
      root.ownerDocument.removeEventListener("keydown", this._putTipAway);
      root.ownerDocument.removeEventListener("pointerdown", this._putTipAway, true);
      root.ownerDocument.removeEventListener("click", this._putTipAway, true);
      window.removeEventListener("scroll", this._putTipAway, true);
      window.removeEventListener("popstate", this._tipUrl);
      window.removeEventListener("phx:page-loading-stop", this._tipUrl);
      window.removeEventListener("phx:bp:focus-new-doc", this._focusNewDoc);
      root.removeEventListener("click", this._onCopy);
      root.removeEventListener("keydown", this._onInspectKey);
      root.removeEventListener("desk:show-modal", this._onShowModal);
      root.removeEventListener("close", this._onInspectClose, true);
      root.removeEventListener("click", this._onInspectTab);
      root.removeEventListener("keydown", this._onInspectTab);
      window.clearTimeout(this._toastTimer);
    },
  };
})();
