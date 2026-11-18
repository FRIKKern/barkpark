// bp-desk-doc-clip.js: the browser half of the header "…" menu's "Copy
// document" and "Paste document" on the desk (`BarkparkWeb.Studio.Desk.DocClip`).
//
// COPY. The item sends `desk-doc-copy` itself (phx-click). The server answers
// with `desk:doc-copied`: the document as the three clipboard types (Sanity's
// item as JSON under a web custom type, the same in text/html, the words in
// text/plain), or `empty`, the words that refuse a document with nothing in
// it. Only the browser can write the clipboard, and some browsers only inside
// the click, so the write starts in the click with a promise for each type
// and the answer settles them, as a field's Copy does
// (bp-desk-field-actions.js). A refused copy leaves the clipboard as it was.
//
// PASTE. The click is held back and the clipboard read (the field script's
// `readClip`: Sanity's item, or null for anything else). The item's JSON and
// the open form's document mark are put on the menu item and the click is
// handed on, so LiveView sends `desk-doc-paste` with them. The server reads
// the item against the document's schema and writes what fits, or answers
// `desk:field-toast` with the words that refuse it. Nothing is written to the
// form here.
//
// The toast, the clipboard write and the clipboard read are the field
// script's (`window.BarkparkDeskFieldActions`), which the desk loads with
// this one. bp-desk.js loads it when the desk mounts (the address is on the
// desk's root, `data-desk-doc-clip`).
(function () {
  "use strict";

  var SANITY_TYPE = "web application/vnd.sanity-clipboard-item+json";
  // How long the server may take to answer a copy.
  var ANSWER_MS = 5000;
  // More than the server takes (`DocClip`): not sent at all.
  var MAX_CLIP = 1048576;

  var pending = null;
  // The click handed on to LiveView is this script's own.
  var passing = false;

  function fields() {
    return window.BarkparkDeskFieldActions || null;
  }

  function toast(tone, title, description) {
    var api = fields();
    if (api && title) api.toast(tone, title, description);
  }

  function blob(type, body) {
    return new Blob([body], { type: type.replace(/^web /, "") });
  }

  // In the click: a write whose three types wait for the server's answer.
  function startCopy(item) {
    if (pending) pending.reject(new Error("superseded"));
    var answer = { failed: item.getAttribute("data-desk-copy-failed") || "" };
    var data = new Promise(function (resolve, reject) {
      answer.resolve = resolve;
      answer.reject = reject;
    });
    data.catch(function () {});
    answer.timer = window.setTimeout(function () {
      if (pending === answer) pending = null;
      answer.reject(new Error("no answer"));
      toast("critical", answer.failed);
    }, ANSWER_MS);
    answer.written = null;
    var clipboard = window.navigator.clipboard;
    if (clipboard && clipboard.write && typeof window.ClipboardItem === "function") {
      try {
        var part = function (type, key) {
          var body = data.then(function (copy) {
            return blob(type, copy[key]);
          });
          body.catch(function () {});
          return body;
        };
        var types = { "text/html": part("text/html", "html"), "text/plain": part("text/plain", "text") };
        types[SANITY_TYPE] = part(SANITY_TYPE, "json");
        answer.written = clipboard.write([new window.ClipboardItem(types)]);
        answer.written.catch(function () {});
      } catch (_error) {
        answer.written = null;
      }
    }
    pending = answer;
  }

  function finishCopy(detail) {
    var answer = pending;
    if (!answer || !detail) return;
    pending = null;
    window.clearTimeout(answer.timer);
    if (detail.empty) {
      answer.reject(new Error("empty"));
      toast("caution", detail.empty);
      return;
    }
    answer.resolve(detail);
    var written = answer.written || Promise.reject(new Error("not begun"));
    written
      .catch(function () {
        var api = fields();
        return api ? api.writeAll(detail) : Promise.reject(new Error("no field script"));
      })
      .catch(function () {
        toast("critical", answer.failed);
      });
  }

  // The click is held back, the clipboard read, and the click handed on with
  // the item on it. The paste names the document of the form it was pressed
  // in, read now: the server refuses a paste pressed in another (`PostIdentity`).
  function startPaste(item, event) {
    event.stopPropagation();
    var api = fields();
    var form = window.document.getElementById("editor-form");
    var doc = form ? form.getAttribute("phx-value-_bp_doc") : null;
    var read = api ? api.readClip() : Promise.reject(new Error("no field script"));
    read.then(
      function (json) {
        if (!json) return toast("default", item.getAttribute("data-desk-nothing"));
        if (json.length > MAX_CLIP) return toast("critical", item.getAttribute("data-desk-invalid"));
        if (!item.isConnected) return;
        item.setAttribute("phx-value-clip", json);
        if (doc) item.setAttribute("phx-value-_bp_doc", doc);
        passing = true;
        try {
          item.click();
        } finally {
          passing = false;
          item.removeAttribute("phx-value-clip");
          item.removeAttribute("phx-value-_bp_doc");
        }
      },
      function () {
        toast("critical", item.getAttribute("data-desk-denied"));
      }
    );
  }

  window.document.addEventListener(
    "click",
    function (event) {
      if (passing || !event.target || !event.target.closest) return;
      var copy = event.target.closest("[data-desk-doc-copy]");
      if (copy && !copy.disabled) return startCopy(copy);
      var paste = event.target.closest("[data-desk-doc-paste]");
      if (paste && !paste.disabled) startPaste(paste, event);
    },
    true
  );

  window.addEventListener("phx:desk:doc-copied", function (event) {
    finishCopy(event.detail);
  });

  window.BarkparkDeskDocClip = { startCopy: startCopy };
})();
