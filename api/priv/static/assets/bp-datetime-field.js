/*
 * bp-datetime-field.js — Studio datetime fields save a UTC instant.
 *
 * Owner ruling #46 (task-6a953e4a9ef729a6). The browser's <input
 * type="datetime-local"> carries no time zone, so Studio used to store what
 * the editor typed ("2026-10-03T10:30"). A site reading that with `new Date()`
 * used its own server's zone: an Oslo editor's 10:30 published at 12:30.
 *
 * The field now renders as a wrapper (phx-hook="BarkparkDatetimeField") with
 * two controls:
 *   - a HIDDEN input [data-datetime-value] that carries the name and the
 *     stored value, and is the only thing the form posts;
 *   - a NAMELESS datetime-local picker the editor sees, in local wall time.
 *
 * On input the picker's local value is converted to an ISO instant ending in
 * "Z" and written to the hidden input, which then fires the `input` event the
 * form's phx-change autosave listens for. A stored instant is shown in the
 * editor's local time. A stored value with no zone (written before this
 * change) is shown as written; it becomes an instant only when edited.
 *
 * The form posts that `input` after the hidden input's phx-debounce. Until
 * then the edit lives only in the hidden input's `value`, and a hidden
 * input's value is its attribute: any LiveView patch of the form in that
 * window (another editor's save) wrote the server's old value back, the
 * focused picker kept showing the new time, and the post carried the old one
 * (task-2be7cd2bd845c2da). So the hook holds the value it wrote and puts it
 * back after a patch, until the server shows a new value for the field
 * (`data-value`: the saved edit, or another editor's) or another document
 * (`data-doc`). A wrapper that does not name its document holds nothing.
 *
 * In the desk the picker is a text box ("2026-09-06 11:00") with a calendar
 * button (`Fields.DeskDatetime`, the TanStack Studio's DateTimeInput); the
 * hook's text mode commits a typed date on Enter or blur and opens the
 * calendar (bp-desk-datepicker.js). The hidden input is the same.
 *
 * Loaded with `defer` at the bottom of <body> (never <head>, Golden Rule 4);
 * the inline Hooks map delegates to `window.BarkparkDatetimeFieldHook` once it
 * exists. Pure functions are exported for the node test in
 * api/test/barkpark_web/components/datetime_field_js_test.exs.
 */
(function (root) {
  "use strict";

  function pad(n) {
    return String(n).padStart(2, "0");
  }

  var NAIVE = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?)?$/;
  var ZONED = /(?:[zZ]|[+-]\d{2}:?\d{2})$/;
  var LOCAL = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/;

  // Stored value -> the datetime-local picker's value (local wall time).
  function toLocalInput(stored) {
    if (stored == null) return "";
    var s = String(stored).trim();
    if (s === "") return "";

    var naive = s.match(NAIVE);
    if (naive) return naive[1] + "T" + (naive[2] || "00:00");
    if (!ZONED.test(s)) return "";

    var d = new Date(s);
    if (isNaN(d.getTime())) return "";

    return (
      d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) +
      "T" + pad(d.getHours()) + ":" + pad(d.getMinutes())
    );
  }

  // The picker's local value -> an ISO 8601 instant in UTC ("...Z").
  function toInstant(local) {
    if (local == null) return "";
    var m = String(local).trim().match(LOCAL);
    if (!m) return "";

    var d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0));
    if (isNaN(d.getTime())) return "";

    return d.toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  // The desk's text box (`Fields.DeskDatetime`), the TanStack Studio's
  // DateTimeInput: the stored value as local "YYYY-MM-DD HH:mm"; typed text
  // back to a Date, or null when it does not read as one.
  var TYPED = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{1,2}):(\d{2})$/;

  function toText(stored) {
    return toLocalInput(stored).replace("T", " ");
  }

  function fromText(text) {
    var m = String(text).trim().match(TYPED);
    if (!m) return null;
    var d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
    if (isNaN(d.getTime()) || d.getMonth() !== +m[2] - 1 || d.getDate() !== +m[3] || +m[4] > 23) return null;
    return d;
  }

  function stringsOf(el) {
    try {
      return JSON.parse(el.getAttribute("data-strings") || "{}");
    } catch (_e) {
      return {};
    }
  }

  var Hook = {
    mounted: function () {
      var self = this;
      this._sync();
      if (this._text()) return this._mountText();

      // Stop the picker's own events at the wrapper: it is nameless, and the
      // form must only ever see the hidden input's value.
      this._onPicker = function (e) {
        if (!e.target.matches || !e.target.matches('input[type="datetime-local"]')) return;
        e.stopPropagation();
        if (e.type !== "input" && e.type !== "change") return;

        var hidden = self._hidden();
        if (!hidden) return;
        var next = toInstant(e.target.value);
        if (hidden.value === next) return;
        hidden.value = next;
        self._hold(next);
        hidden.dispatchEvent(new Event("input", { bubbles: true }));
      };

      this.el.addEventListener("input", this._onPicker);
      this.el.addEventListener("change", this._onPicker);
    },

    updated: function () {
      this._keep();
      this._sync();
    },

    destroyed: function () {
      this.el.removeEventListener("input", this._onPicker);
      this.el.removeEventListener("change", this._onPicker);
      if (this._offText) this._offText();
    },

    _text: function () {
      return this.el.querySelector("input[data-datetime-text]");
    },

    // The desk's box: typing stays in the box (the form posts nothing); Enter
    // or leaving the box commits it when it reads as a date (empty clears),
    // else the box is marked and says the format. The calendar button opens
    // the picker (bp-desk-datepicker.js); a picked day commits at once. The
    // instant is stored as the TanStack Studio stores it (toISOString).
    _mountText: function () {
      var self = this;
      var text = this._text();
      var button = this.el.querySelector("button[data-datetime-open]");
      var error = this.el.querySelector("[data-datetime-error]");
      var strings = stringsOf(this.el);
      var now = new Date();
      text.placeholder = (strings.example || "e.g. %{example}").replace(
        "%{example}",
        toText(now.toISOString())
      );

      var mark = function (bad) {
        if (bad) {
          self.el.setAttribute("data-invalid", "");
          text.setAttribute("aria-invalid", "true");
        } else {
          self.el.removeAttribute("data-invalid");
          text.removeAttribute("aria-invalid");
        }
        if (error) {
          error.hidden = !bad;
          error.textContent = bad ? (strings.invalid || "Not a valid date. Use the format %{format}.").replace("%{format}", "2026-09-06 11:00") : "";
        }
      };
      // Only what was typed is written: a box that was only focused shows
      // what the server holds (`_sync`), so leaving it never writes back a
      // value another editor has changed since.
      var commit = function () {
        var hidden = self._hidden();
        if (!hidden || text.readOnly || !self._typed) return;
        if (text.value === toText(hidden.value)) return (self._typed = false), mark(false);
        if (text.value.trim() === "") return (self._typed = false), mark(false), self._set("");
        var d = fromText(text.value);
        if (!d) return mark(true);
        self._typed = false;
        mark(false);
        self._set(d.toISOString());
      };
      // Only the hidden input's own event reaches the form: the box's and
      // the calendar's controls (month, year, time) are nameless.
      var onInput = function (e) {
        if (e.target === self._hidden()) return;
        e.stopPropagation();
        if (e.target === text) {
          self._typed = true;
          mark(false);
        }
      };
      var onKey = function (e) {
        if (e.target === text && e.key === "Enter") {
          e.preventDefault();
          commit();
        }
      };
      var onOut = function (e) {
        if (e.target === text) commit();
      };
      var onClick = function () {
        var picker = root.BarkparkDatePicker;
        var hidden = self._hidden();
        if (!picker || !hidden) return;
        var stored = hidden.value ? new Date(hidden.value) : null;
        picker.toggle({
          box: text.parentNode,
          host: text.parentNode.parentNode,
          button: button,
          value: stored && !isNaN(stored.getTime()) ? stored : null,
          locale: self.el.getAttribute("data-locale") || "en",
          strings: strings,
          onPick: function (d) {
            self._typed = false;
            mark(false);
            self._set(d.toISOString());
          }
        });
      };
      this.el.addEventListener("input", onInput);
      this.el.addEventListener("change", onInput);
      this.el.addEventListener("keydown", onKey);
      this.el.addEventListener("focusout", onOut);
      if (button) button.addEventListener("click", onClick);
      this._offText = function () {
        self.el.removeEventListener("input", onInput);
        self.el.removeEventListener("change", onInput);
        self.el.removeEventListener("keydown", onKey);
        self.el.removeEventListener("focusout", onOut);
        if (button) button.removeEventListener("click", onClick);
        if (root.BarkparkDatePicker && root.BarkparkDatePicker.isOpen()) root.BarkparkDatePicker.close(false);
      };
    },

    // Write a value: the hidden input posts it, the box shows it.
    _set: function (value) {
      var hidden = this._hidden();
      var text = this._text();
      if (!hidden) return;
      if (text) text.value = toText(value);
      if (hidden.value === value) return;
      hidden.value = value;
      this._hold(value);
      hidden.dispatchEvent(new Event("input", { bubbles: true }));
    },

    _hidden: function () {
      return this.el.querySelector("input[data-datetime-value]");
    },

    _picker: function () {
      return this.el.querySelector('input[type="datetime-local"]');
    },

    // Remember an edit the form has not posted yet, with the server value
    // and the document it was made on.
    _hold: function (value) {
      var doc = this.el.getAttribute("data-doc");
      var base = this.el.getAttribute("data-value") || "";
      this._held = doc && value !== base ? { value: value, base: base, doc: doc } : null;
    },

    // After a patch: the held edit goes back into the hidden input when the
    // server still shows the same value for the same document.
    _keep: function () {
      var held = this._held;
      if (!held) return;
      var hidden = this._hidden();
      var same =
        this.el.getAttribute("data-doc") === held.doc &&
        (this.el.getAttribute("data-value") || "") === held.base;
      if (!hidden || !same) {
        this._held = null;
        return;
      }
      if (hidden.value !== held.value) hidden.value = held.value;
    },

    // Show the stored value in local time, unless the editor is typing. A
    // box that has the focus but no typing shows a new value from the server
    // too (another editor's), as the TanStack Studio's does.
    _sync: function () {
      var text = this._text && this._text();
      var hidden = this._hidden();
      if (text && hidden) {
        if (typeof document === "undefined" || document.activeElement !== text || !this._typed)
          text.value = toText(hidden.value);
        return;
      }
      var picker = this._picker();
      if (!picker || !hidden) return;
      if (typeof document !== "undefined" && document.activeElement === picker) return;
      picker.value = toLocalInput(hidden.value);
    }
  };

  // Fill the pickers of the static render before LiveView connects
  // (task-cf45242ef3477fba). Hooks run only on the connected render, and on
  // gyl a document's connected mount comes seconds after the form is drawn,
  // so the event dates read empty until then. Only an empty, unfocused picker
  // is filled; the hook takes over once it mounts.
  function fillStatic(doc) {
    var wrappers = doc.querySelectorAll(".bp-datetime-field");
    for (var i = 0; i < wrappers.length; i++) {
      var picker = wrappers[i].querySelector('input[type="datetime-local"], input[data-datetime-text]');
      var hidden = wrappers[i].querySelector("input[data-datetime-value]");
      if (!picker || !hidden || picker.value !== "" || doc.activeElement === picker) continue;
      picker.value = picker.type === "text" ? toText(hidden.value) : toLocalInput(hidden.value);
    }
  }

  root.BarkparkDatetime = {
    toLocalInput: toLocalInput,
    toInstant: toInstant,
    toText: toText,
    fromText: fromText,
    fillStatic: fillStatic
  };
  root.BarkparkDatetimeFieldHook = Hook;

  if (typeof document !== "undefined" && document.querySelectorAll) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () { fillStatic(document); }, { once: true });
    } else {
      fillStatic(document);
    }
  }
})(typeof window !== "undefined" ? window : globalThis);
