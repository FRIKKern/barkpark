// bp-modal-focus.js: the ONE focus manager for Studio's modal dialogs
// (task-0ad7fed4370a5978; made shared by the run-8 dialog sweep). Both the
// Studio root layout and the paper (bulldocs) layout register it as the
// `ModalFocus` LiveView hook. On mount it focuses [data-modal-focus] /
// [autofocus] or the first control, keeps Tab and Shift+Tab inside, and on
// close gives focus back to the trigger. Escape stays with each dialog
// (`phx-window-keydown` + `phx-key="escape"`), which reaches it from anywhere.
// Every aria-modal dialog in api/lib carries this hook; modal_focus_guard_test
// fails when one does not. Loaded NON-DEFER at the bottom of <body>, before
// the layouts build their hook maps (Golden Rule #4: never in <head>).
(function () {
  "use strict";

  // The last element focused OUTSIDE any aria-modal dialog. A dialog whose own
  // parent hook moves focus inside before this hook mounts (the chat palette's
  // ChatPalette focuses its input) still knows where it was opened from.
  var lastOutside = null;
  document.addEventListener(
    "focusin",
    function (e) {
      var t = e.target;
      if (t && t.closest && !t.closest('[aria-modal="true"]')) lastOutside = t;
    },
    true
  );
  window.BarkparkModalFocus = {
    mounted() {
      const a = document.activeElement;
      const dialog = this.el.closest('[aria-modal="true"]') || this.el;
      const inside = a && dialog.contains(a);
      this._returnTo = inside ? lastOutside : a && a !== document.body ? a : null;
      this._returnId = this._returnTo && this._returnTo.id;
      // A trigger with no id is re-found by what it does and says: its
      // phx-click and its aria-label (a restore re-renders the editor header,
      // so the Historikk button is a NEW node by the time the dialog closes).
      this._returnClick = this._returnTo && this._returnTo.getAttribute("phx-click");
      this._returnLabel = this._returnTo && this._returnTo.getAttribute("aria-label");
      this._focusIn();
      this._onKey = (e) => {
        if (e.key !== "Tab") return;
        const list = this._focusables();
        if (!list.length) return;
        const first = list[0];
        const last = list[list.length - 1];
        const active = document.activeElement;
        if (!this.el.contains(active)) {
          e.preventDefault();
          (e.shiftKey ? last : first).focus();
        } else if (e.shiftKey && active === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && active === last) {
          e.preventDefault();
          first.focus();
        }
      };
      document.addEventListener("keydown", this._onKey, true);
    },
    // A re-render can remove the focused control (e.g. the share sheet
    // swapping its form for the minted link); land inside again.
    updated() {
      if (!this.el.contains(document.activeElement)) this._focusIn();
    },
    destroyed() {
      document.removeEventListener("keydown", this._onKey, true);
      let back = this._returnTo;
      if (back && !back.isConnected && this._returnId) back = document.getElementById(this._returnId);
      if (back && !back.isConnected && this._returnClick) {
        const click = this._returnClick;
        const label = this._returnLabel;
        back = Array.from(document.querySelectorAll("[phx-click]")).find(
          (el) => el.getAttribute("phx-click") === click && el.getAttribute("aria-label") === label
        ) || back;
      }
      if (back && back.isConnected) back.focus();
    },
    _focusIn() {
      const target =
        this.el.querySelector("[data-modal-focus], [autofocus]") || this._focusables()[0];
      if (target) target.focus();
    },
    _focusables() {
      return Array.from(
        this.el.querySelectorAll(
          'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), [contenteditable="true"]'
        )
      ).filter((el) => !el.closest("[hidden]"));
    }
  };
})();
