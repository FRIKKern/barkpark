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
// - Each time the list opens it starts over: the box empty, every way shown,
//   nothing lit, the focus in the box.
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

  // `toggle` does not bubble: listened for in the capture phase.
  var onToggle = function (e) {
    if (!e.target || e.target.id !== PICKER || e.newState !== "open") return;
    var p = parts(e.target);
    if (!p.find || !p.list) return;
    p.find.value = "";
    filter(p);
    p.find.focus();
  };

  document.addEventListener("input", onInput);
  document.addEventListener("keydown", onKey);
  document.addEventListener("pointerover", onPointer);
  document.addEventListener("toggle", onToggle, true);

  window.BarkparkDeskNewDoc = { filter: filter, parts: parts };
})();
