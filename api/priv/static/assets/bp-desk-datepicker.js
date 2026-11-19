// bp-desk-datepicker.js: a date-time field's calendar on the desk, as the
// TanStack Studio's DatePicker (barkpark-studio
// app/src/components/DateTimeInput.tsx), Sanity's (J31).
//
// A dialog under the field: a month select, the year between a previous-
// and a next-year button, a grid of days, and a foot with the time and "Set
// to current time". The grid is one Tab stop: the day that has the focus.
// Arrows move a day or a week, Enter or Space picks it, a click picks the
// day clicked. A picked day keeps the time shown in the foot; a time typed
// there moves the picked instant. Tab stays in the dialog. Escape, or a
// click outside, closes it and gives the focus back to its button.
//
// The dialog opens on the selected day (else today) with the focus on it.
// A day is named as TanStack names it: `Sun Sep 06 2026` in English, the
// long date in Norwegian. Month and day names come from the browser's Intl,
// in the studio's language; the week starts on Monday in Norwegian.
//
// `open(opts)` is called by the field's hook (bp-datetime-field.js) with:
// `box` (the element the dialog sits under), `host` (where it is put, inside
// the field's phx-update="ignore" part), `button`, `value` (a Date or null),
// `locale`, `strings`, `onPick(date)`. `toggle(opts)` opens or closes.
(function () {
  "use strict";

  if (window.BarkparkDatePicker) return;

  var current = null;
  var FOCUSABLE = "input, select, textarea, button, a[href], label, summary, [tabindex], [contenteditable]";

  function pad(n) { return String(n).padStart(2, "0"); }
  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }
  function addDays(d, n) { return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n); }
  function day(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }
  function tag(locale) { return /^nb/i.test(locale || "") ? "nb-NO" : "en-US"; }
  function weekStart(locale) { return /^nb/i.test(locale || "") ? 1 : 0; }
  function title(s) { s = String(s).replace(/\.$/, ""); return s.charAt(0).toUpperCase() + s.slice(1); }

  function monthNames(locale) {
    var f = new Intl.DateTimeFormat(tag(locale), { month: "long" });
    var out = [];
    for (var m = 0; m < 12; m++) out.push(title(f.format(new Date(2026, m, 1))));
    return out;
  }

  // Short day names from the week's first day (2023-01-01 was a Sunday).
  function dayNames(locale) {
    var f = new Intl.DateTimeFormat(tag(locale), { weekday: "short" });
    var out = [];
    for (var i = 0; i < 7; i++) out.push(title(f.format(new Date(2023, 0, 1 + ((i + weekStart(locale)) % 7)))));
    return out;
  }

  function dayLabel(d, locale) {
    if (!/^nb/i.test(locale || "")) return d.toDateString();
    return d.toLocaleDateString("nb-NO", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  }

  function el(doc, name, attrs, text) {
    var node = doc.createElement(name);
    Object.keys(attrs || {}).forEach(function (k) { node.setAttribute(k, attrs[k]); });
    if (text != null) node.textContent = text;
    return node;
  }

  function chevron(doc, d) {
    var svg = doc.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", "25"); svg.setAttribute("height", "25"); svg.setAttribute("viewBox", "0 0 25 25");
    svg.setAttribute("fill", "none"); svg.setAttribute("stroke", "currentColor"); svg.setAttribute("stroke-width", "1.2");
    svg.setAttribute("aria-hidden", "true");
    var path = doc.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", d);
    svg.appendChild(path);
    return svg;
  }

  function open(opts) {
    if (current) close(false);
    var doc = opts.host.ownerDocument;
    var s = opts.strings || {};
    var now = new Date();
    var st = {
      opts: opts,
      value: opts.value ? day(opts.value) : null,
      focused: opts.value ? day(opts.value) : day(now),
      time: opts.value ? pad(opts.value.getHours()) + ":" + pad(opts.value.getMinutes()) : pad(now.getHours()) + ":" + pad(now.getMinutes())
    };

    var root = el(doc, "div", { class: "popover datepicker", role: "dialog", "aria-label": s.select_date || "Select date" });
    var head = el(doc, "div", { class: "dp-head" });
    var monthBox = el(doc, "span", { class: "dp-month" });
    var month = el(doc, "select", { "aria-label": s.month || "Month" });
    monthNames(opts.locale).forEach(function (name, i) { month.appendChild(el(doc, "option", { value: String(i) }, name)); });
    monthBox.appendChild(month);
    monthBox.appendChild(chevron(doc, "M17 10.5L12.5 15L8 10.5"));
    var prev = el(doc, "button", { type: "button", class: "icon-btn", "aria-label": s.prev_year || "Go to previous year" });
    prev.appendChild(chevron(doc, "M14.5 17L10 12.5L14.5 8"));
    var year = el(doc, "input", { class: "dp-year", inputmode: "numeric", "aria-label": s.year || "Year" });
    var next = el(doc, "button", { type: "button", class: "icon-btn", "aria-label": s.next_year || "Go to next year" });
    next.appendChild(chevron(doc, "M10.5 8L15 12.5L10.5 17"));
    [monthBox, prev, year, next].forEach(function (n) { head.appendChild(n); });
    var grid = el(doc, "div", { class: "dp-grid" });
    var foot = el(doc, "div", { class: "dp-foot" });
    var timeBox = el(doc, "span", { class: "dp-time" });
    var time = el(doc, "input", { type: "time", step: "60", "aria-label": s.select_time || "Select time" });
    timeBox.appendChild(time);
    var nowBtn = el(doc, "button", { type: "button", class: "btn-text" }, s.now || "Set to current time");
    foot.appendChild(timeBox);
    foot.appendChild(nowBtn);
    root.appendChild(head);
    root.appendChild(grid);
    root.appendChild(foot);
    st.root = root; st.grid = grid; st.month = month; st.year = year; st.time_input = time;
    time.value = st.time;

    var at = function (d) {
      var m = /^(\d{1,2}):(\d{2})$/.exec(st.time) || [0, 0, 0];
      return new Date(d.getFullYear(), d.getMonth(), d.getDate(), Number(m[1]), Number(m[2]));
    };
    var pick = function (d) {
      st.value = day(d);
      st.focused = day(d);
      draw(st, true);
      opts.onPick(at(d));
    };
    var moveTo = function (d) { st.focused = day(d); draw(st, true); };

    month.addEventListener("change", function () {
      moveTo(new Date(st.focused.getFullYear(), Number(month.value), Math.min(st.focused.getDate(), 28)));
      month.focus();
    });
    prev.addEventListener("click", function () { moveTo(new Date(st.focused.getFullYear() - 1, st.focused.getMonth(), Math.min(st.focused.getDate(), 28))); prev.focus(); });
    next.addEventListener("click", function () { moveTo(new Date(st.focused.getFullYear() + 1, st.focused.getMonth(), Math.min(st.focused.getDate(), 28))); next.focus(); });
    year.addEventListener("input", function () {
      if (/^\d{4}$/.test(year.value)) {
        st.focused = new Date(Number(year.value), st.focused.getMonth(), Math.min(st.focused.getDate(), 28));
        draw(st, false);
      }
    });
    grid.addEventListener("click", function (e) {
      var b = e.target.closest ? e.target.closest("button[data-day]") : null;
      if (b && !b.disabled) pick(new Date(Number(b.getAttribute("data-day"))));
    });
    grid.addEventListener("keydown", function (e) {
      var step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[e.key];
      if (step) { e.preventDefault(); moveTo(addDays(st.focused, step)); }
      else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(st.focused); }
    });
    time.addEventListener("input", function () {
      st.time = time.value;
      var m = /^(\d{1,2}):(\d{2})$/.exec(time.value);
      if (m && st.value && Number(m[1]) < 24 && Number(m[2]) < 60) opts.onPick(at(st.value));
    });
    time.addEventListener("keydown", function (e) { if (e.key === "Enter") e.preventDefault(); });
    nowBtn.addEventListener("click", function () {
      var n = new Date();
      n.setSeconds(0, 0);
      st.time = pad(n.getHours()) + ":" + pad(n.getMinutes());
      time.value = st.time;
      st.value = day(n);
      st.focused = day(n);
      draw(st, false);
      opts.onPick(n);
    });
    root.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        close(true);
      } else if (e.key === "Tab") {
        trap(root, e);
      }
    });
    // A press outside closes it and gives the focus back to the button. On a
    // spot that takes no focus, the press's own default then moved the focus
    // to <body>, so that default is stopped; a press on a control or a label
    // moves the focus there, as it would anyway.
    st.away = function (e) {
      if (root.contains(e.target) || opts.button.contains(e.target)) return;
      close(true);
      if (!(e.target.closest && e.target.closest(FOCUSABLE))) e.preventDefault();
    };
    doc.addEventListener("mousedown", st.away, true);

    opts.host.appendChild(root);
    opts.button.setAttribute("aria-expanded", "true");
    current = st;
    draw(st, true);
    return st;
  }

  // Tab and Shift+Tab go round the dialog's controls.
  function trap(root, e) {
    var items = Array.prototype.filter.call(
      root.querySelectorAll("select, input, button"),
      function (n) { return !n.disabled && n.tabIndex !== -1; }
    );
    if (!items.length) return;
    var first = items[0];
    var last = items[items.length - 1];
    var at = root.ownerDocument.activeElement;
    if (e.shiftKey && at === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus(); }
  }

  // Whole weeks from the week's first day on or before the 1st.
  function draw(st, focus) {
    var doc = st.root.ownerDocument;
    var locale = st.opts.locale;
    var f = st.focused;
    var today = day(new Date());
    st.month.value = String(f.getMonth());
    if (doc.activeElement !== st.year) st.year.value = String(f.getFullYear());
    var first = new Date(f.getFullYear(), f.getMonth(), 1);
    var lead = (first.getDay() - weekStart(locale) + 7) % 7;
    var start = addDays(first, -lead);
    var inMonth = new Date(f.getFullYear(), f.getMonth() + 1, 0).getDate();
    var count = Math.ceil((lead + inMonth) / 7) * 7;
    var grid = st.grid;
    while (grid.firstChild) grid.removeChild(grid.firstChild);
    dayNames(locale).forEach(function (n) { grid.appendChild(el(doc, "span", { class: "dp-weekday" }, n)); });
    var focusEl = null;
    for (var i = 0; i < count; i++) {
      var d = addDays(start, i);
      var selected = !!st.value && sameDay(d, st.value);
      var isFocused = sameDay(d, f);
      var b = el(doc, "button", {
        type: "button",
        "aria-label": dayLabel(d, locale),
        "aria-pressed": String(selected),
        "data-day": String(d.getTime()),
        "data-focused": String(isFocused),
        tabindex: isFocused ? "0" : "-1"
      }, String(d.getDate()));
      if (d.getMonth() !== f.getMonth()) b.setAttribute("data-outside", "");
      if (sameDay(d, today)) b.setAttribute("data-today", "");
      if (selected) b.setAttribute("data-selected", "");
      grid.appendChild(b);
      if (isFocused) focusEl = b;
    }
    if (focus && focusEl) focusEl.focus();
  }

  function close(refocus) {
    var st = current;
    if (!st) return;
    current = null;
    st.root.ownerDocument.removeEventListener("mousedown", st.away, true);
    st.opts.button.setAttribute("aria-expanded", "false");
    if (st.root.parentNode) st.root.parentNode.removeChild(st.root);
    if (refocus) st.opts.button.focus();
  }

  function toggle(opts) {
    if (current && current.opts.button === opts.button) return close(true);
    return open(opts);
  }

  window.BarkparkDatePicker = {
    open: open,
    toggle: toggle,
    close: close,
    isOpen: function () { return !!current; },
    dayLabel: dayLabel
  };
})();
