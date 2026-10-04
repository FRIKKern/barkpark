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

  var Hook = {
    mounted: function () {
      var self = this;
      this._sync();

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
        hidden.dispatchEvent(new Event("input", { bubbles: true }));
      };

      this.el.addEventListener("input", this._onPicker);
      this.el.addEventListener("change", this._onPicker);
    },

    updated: function () {
      this._sync();
    },

    destroyed: function () {
      this.el.removeEventListener("input", this._onPicker);
      this.el.removeEventListener("change", this._onPicker);
    },

    _hidden: function () {
      return this.el.querySelector("input[data-datetime-value]");
    },

    _picker: function () {
      return this.el.querySelector('input[type="datetime-local"]');
    },

    // Show the stored value in local time, unless the editor is typing.
    _sync: function () {
      var picker = this._picker();
      var hidden = this._hidden();
      if (!picker || !hidden) return;
      if (typeof document !== "undefined" && document.activeElement === picker) return;
      picker.value = toLocalInput(hidden.value);
    }
  };

  root.BarkparkDatetime = { toLocalInput: toLocalInput, toInstant: toInstant };
  root.BarkparkDatetimeFieldHook = Hook;
})(typeof window !== "undefined" ? window : globalThis);
