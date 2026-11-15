// bp-desk-field-actions.js: the browser half of a field's "Field actions"
// menu on the desk (`BarkparkWeb.Studio.Desk.FieldActions`).
//
// COPY. The menu's "Copy field" sends `desk-field-copy` itself (phx-click).
// The server answers with `desk:field-copied`: the field's value as the
// three clipboard types (Sanity's item as JSON under a web custom type, the
// same in text/html, the words in text/plain), or `empty`, the words that
// refuse an empty field. Only the browser can write the clipboard, and some
// browsers only inside the click, so the write starts in the click with a
// promise for each type and the answer settles them. An empty field rejects
// them: the clipboard keeps what it held.
//
// The words are shown in a toast on the page's body (`.dk-field-toast`,
// `Desk.DocStyle`): a status, or an alert when something was refused.
//
// A document-level listener, no phx-hook, as bp-array-focus.js.
(function () {
  "use strict";

  var SANITY_TYPE = "web application/vnd.sanity-clipboard-item+json";
  // How long the server may take to answer a copy.
  var ANSWER_MS = 5000;
  var TOAST_MS = 5000;

  var pending = null;
  var toastTimer = null;

  function toast(tone, title, description) {
    var doc = window.document;
    var el = doc.querySelector(".dk-field-toast");
    if (!el) {
      el = doc.createElement("div");
      el.className = "dk-field-toast";
      el.setAttribute("popover", "manual");
      doc.body.appendChild(el);
    }
    el.setAttribute("data-tone", tone);
    el.setAttribute("role", tone === "critical" ? "alert" : "status");
    // Shown first, then filled: the change is what a screen reader reads.
    if (el.showPopover && !el.matches(":popover-open")) el.showPopover();
    el.textContent = "";
    var strong = doc.createElement("strong");
    strong.textContent = title;
    el.appendChild(strong);
    if (description) {
      var span = doc.createElement("span");
      span.textContent = description;
      el.appendChild(span);
    }
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      el.textContent = "";
      if (el.hidePopover && el.matches(":popover-open")) el.hidePopover();
    }, TOAST_MS);
  }

  function blob(type, body) {
    return new Blob([body], { type: type.replace(/^web /, "") });
  }

  // The three types at once; a browser without web custom types gets the
  // item in text/html, as Sanity's; one without `write`, the words.
  function writeAll(copy) {
    var clipboard = window.navigator.clipboard;
    if (!clipboard) return Promise.reject(new Error("no clipboard"));
    var plain = function () {
      return clipboard.writeText(copy.text);
    };
    if (!clipboard.write || typeof window.ClipboardItem !== "function") return plain();
    var two = { "text/html": blob("text/html", copy.html), "text/plain": blob("text/plain", copy.text) };
    var three = { "text/html": two["text/html"], "text/plain": two["text/plain"] };
    three[SANITY_TYPE] = blob(SANITY_TYPE, copy.json);
    var write = function (types) {
      try {
        return clipboard.write([new window.ClipboardItem(types)]);
      } catch (error) {
        return Promise.reject(error);
      }
    };
    return write(three).catch(function () {
      return write(two).catch(plain);
    });
  }

  // In the click: a write whose three types wait for the server's answer.
  function startCopy(item) {
    if (pending) pending.reject(new Error("superseded"));
    var answer = { field: item.getAttribute("data-desk-field-copy"), failed: failedWords(item) };
    var data = new Promise(function (resolve, reject) {
      answer.resolve = resolve;
      answer.reject = reject;
    });
    // Settled by hand below; never an unhandled rejection.
    data.catch(function () {});
    answer.timer = window.setTimeout(function () {
      if (pending === answer) pending = null;
      answer.reject(new Error("no answer"));
    }, ANSWER_MS);
    answer.written = null;
    var clipboard = window.navigator.clipboard;
    if (clipboard && clipboard.write && typeof window.ClipboardItem === "function") {
      try {
        // A refused copy rejects all three; the write reads only the first.
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

  function failedWords(item) {
    var menu = item.closest("[data-desk-copy-failed]");
    return menu ? menu.getAttribute("data-desk-copy-failed") : "";
  }

  // The server's answer to the copy in flight.
  function finishCopy(detail) {
    var answer = pending;
    if (!answer || !detail || detail.field !== answer.field) return;
    pending = null;
    window.clearTimeout(answer.timer);
    if (detail.empty) {
      answer.reject(new Error("empty"));
      toast("caution", detail.empty);
      return;
    }
    answer.resolve(detail);
    // The write begun in the click, else (it was refused, or never begun) one now.
    var written = answer.written || Promise.reject(new Error("not begun"));
    written
      .catch(function () {
        return writeAll(detail);
      })
      .catch(function () {
        if (answer.failed) toast("critical", answer.failed);
      });
  }

  window.document.addEventListener(
    "click",
    function (event) {
      var item = event.target && event.target.closest ? event.target.closest("[data-desk-field-copy]") : null;
      if (item && !item.disabled) startCopy(item);
    },
    true
  );

  window.addEventListener("phx:desk:field-copied", function (event) {
    finishCopy(event.detail);
  });

  window.BarkparkDeskFieldActions = { toast: toast, writeAll: writeAll };
})();
