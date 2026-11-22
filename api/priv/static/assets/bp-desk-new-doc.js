// The desk navbar's Create new document (Desk.NewDocMenu.picker), as the
// TanStack Studio's TypePicker (NewDocMenu.tsx, J37): a "Search document types"
// combobox over the ways to start.
//
// - Typing keeps the ways whose title holds the text (any case, trimmed); with
//   none left the list gives way to "No results for <text>".
// - Nothing is lit until an arrow key moves, so Enter opens nothing by
//   accident; ArrowDown and ArrowUp light the next or previous shown way
//   (aria-selected, aria-activedescendant), and Enter opens the lit one.
// - The pointer lights the way under it, as Sanity's.
// - Focus that leaves the open list for nothing (a press on no control, the
//   window losing the focus) or for outside it by Tab closes the list and goes
//   back to "+", as TanStack's; Shift+Tab onto "+" keeps it open.
// - Each time the list opens it starts over: the box empty, every way shown,
//   nothing lit, the focus in the box (the popover's autofocus).
//
// It runs once a page, from the desk hook's loader; everything is delegated
// from the document, so a page drawn after it loaded works the same.
(function () {
  if (window.BarkparkDeskNewDoc) return;

  var PICKER = "dk-new-doc";

  var parts = function (picker) {
    return {
      find: picker.querySelector("[data-desk-new-doc-find]"),
      list: picker.querySelector('[role="listbox"]'),
      empty: picker.querySelector(".dk-new-doc-empty"),
      query: picker.querySelector("[data-desk-new-doc-query]"),
      options: Array.prototype.slice.call(picker.querySelectorAll('[role="option"]')),
    };
  };
  var shown = function (p) {
    return p.options.filter(function (o) {
      return !o.hidden;
    });
  };
  var light = function (p, option) {
    p.options.forEach(function (o) {
      o.setAttribute("aria-selected", o === option ? "true" : "false");
    });
    if (option) {
      p.find.setAttribute("aria-activedescendant", option.id);
      if (option.scrollIntoView) option.scrollIntoView({ block: "nearest" });
    } else {
      p.find.removeAttribute("aria-activedescendant");
    }
  };
  var lit = function (p) {
    return shown(p).filter(function (o) {
      return o.getAttribute("aria-selected") === "true";
    })[0];
  };
  var filter = function (p) {
    var text = (p.find.value || "").trim().toLowerCase();
    p.options.forEach(function (o) {
      o.hidden = text !== "" && o.textContent.trim().toLowerCase().indexOf(text) < 0;
    });
    var any = shown(p).length > 0;
    p.list.hidden = !any;
    if (p.empty) p.empty.hidden = any;
    if (p.query) p.query.textContent = p.find.value || "";
    p.find.setAttribute("aria-expanded", any ? "true" : "false");
    light(p, null);
  };
  var picker = function (el) {
    return el && el.closest ? el.closest("#" + PICKER) : null;
  };

  var onInput = function (e) {
    var box = picker(e.target);
    if (box && e.target.hasAttribute("data-desk-new-doc-find")) filter(parts(box));
  };

  var onKey = function (e) {
    var box = picker(e.target);
    if (!box || !e.target.hasAttribute("data-desk-new-doc-find")) return;
    var p = parts(box);
    var list = shown(p);
    var at = list.indexOf(lit(p));
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!list.length) return;
      var next = e.key === "ArrowDown" ? Math.min(at + 1, list.length - 1) : Math.max(at - 1, 0);
      light(p, list[next]);
    } else if (e.key === "Enter" && at >= 0) {
      e.preventDefault();
      list[at].click();
    }
  };

  var onPointer = function (e) {
    var option = e.target.closest ? e.target.closest('[role="option"]') : null;
    var box = picker(option);
    if (box && !option.hidden) light(parts(box), option);
  };

  // TanStack's picker closes when the focus leaves for outside its wrapper,
  // which holds "+" and the list, and hands the focus back to "+". Here a
  // press on no control in the open list (the padding round the box, the "No
  // results" note, the gaps between ways), the window losing the focus, and a
  // Tab past the list all left it open. Each now closes it and focuses "+"
  // within the blur, so the focus never rests on the page body. Shift+Tab onto
  // "+" keeps it open, as TanStack's. A press on the list's scroll bar moves no
  // focus. A press on a control outside is the browser's light dismiss. A
  // LiveView patch that moves the box blurs it and puts the focus back before
  // its script ends: the check for a blur to nothing waits for that (a
  // microtask), and a box holding the focus again is left open.
  var invoker = function () {
    return document.querySelector('[popovertarget="' + PICKER + '"]:not([popovertargetaction])');
  };
  var close = function (box, tabbedTo) {
    if (!box.isConnected || !box.matches(":popover-open")) return;
    box.hidePopover();
    var plus = invoker();
    if (!plus) return;
    plus.focus();
    // Where the browser lets Tab's move land after the blur, "+" takes it back.
    if (tabbedTo)
      queueMicrotask(function () {
        if (document.activeElement === tabbedTo) plus.focus();
      });
  };
  var tabbing = null;
  var onTab = function (e) {
    if (e.key !== "Tab") return;
    tabbing = picker(e.target);
    setTimeout(function () {
      tabbing = null;
    }, 0);
  };
  var onLeave = function (e) {
    var box = picker(e.target);
    if (!box || !box.matches(":popover-open")) return;
    var to = e.relatedTarget;
    if (to) {
      if (tabbing === box && !box.contains(to) && to !== invoker()) close(box, to);
      return;
    }
    if (!document.hasFocus()) return close(box);
    queueMicrotask(function () {
      if (!box.contains(document.activeElement)) close(box);
    });
  };

  // The start-over is made in `beforetoggle`, which runs before the list is
  // drawn. `toggle` is queued and can come after the first keys typed into the
  // autofocused box, and would then wipe them. Neither bubbles: both are
  // listened for in the capture phase. `toggle` only makes sure of the focus.
  var opening = function (e) {
    if (!e.target || e.target.id !== PICKER || e.newState !== "open") return null;
    var p = parts(e.target);
    return p.find && p.list ? p : null;
  };
  var onBeforeToggle = function (e) {
    var p = opening(e);
    if (!p) return;
    p.find.value = "";
    filter(p);
  };
  var onToggle = function (e) {
    var p = opening(e);
    if (p && document.activeElement !== p.find && e.target.matches(":popover-open")) p.find.focus();
  };

  document.addEventListener("input", onInput);
  document.addEventListener("keydown", onKey);
  document.addEventListener("pointerover", onPointer);
  document.addEventListener("focusout", onLeave);
  document.addEventListener("keydown", onTab);
  document.addEventListener("beforetoggle", onBeforeToggle, true);
  document.addEventListener("toggle", onToggle, true);

  window.BarkparkDeskNewDoc = { filter: filter, parts: parts };
})();
