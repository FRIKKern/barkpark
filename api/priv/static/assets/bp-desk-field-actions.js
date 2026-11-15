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
// PASTE. Only the browser can read the clipboard, and only the server may
// write the document. So "Paste field" reads the clipboard first: Sanity's
// item under its web custom type, else the one in text/html. Anything else
// is "Nothing to paste". The item's JSON is then put on the menu item as
// `phx-value-clip` and the click is handed on, so LiveView sends
// `desk-field-paste` with it. The server checks it against the field's
// schema and saves it as a typed edit, or answers `desk:field-toast` with
// the words that refuse it. Nothing is written to the form here.
//
// A browser that refuses to let a page read the clipboard pastes the last
// field copied in this browser (kept in localStorage), as the TanStack
// Studio does.
//
// The words are shown in a toast on the page's body (`.dk-field-toast`,
// `Desk.DocStyle`): a status, or an alert when something was refused. A
// copy that lands, and a paste handed to the server, take an earlier toast
// down: its words were about something else. A copy the server never
// answers says it failed.
//
// A document-level listener, no phx-hook, as bp-array-focus.js. Only the
// desk needs it, so bp-desk.js loads it when the desk mounts (the address is
// on the desk's root, `data-desk-field-actions`); the root layout has no
// script tag for it.
(function () {
  "use strict";

  var SANITY_TYPE = "web application/vnd.sanity-clipboard-item+json";
  // How long the server may take to answer a copy.
  var ANSWER_MS = 5000;
  var TOAST_MS = 5000;

  // The last field copied here, for a browser that cannot read the clipboard.
  var KEPT = "barkpark.desk.field-clip";
  // More than the server takes (`FieldPaste`): not sent at all.
  var MAX_CLIP = 262144;

  var pending = null;
  var toastTimer = null;
  // The click handed on to LiveView is this script's own.
  var passing = false;

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

  function hideToast() {
    var el = window.document.querySelector(".dk-field-toast");
    window.clearTimeout(toastTimer);
    if (!el) return;
    el.textContent = "";
    if (el.hidePopover && el.matches(":popover-open")) el.hidePopover();
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
    // No answer (the server is away): the copy did not happen, and says so.
    answer.timer = window.setTimeout(function () {
      if (pending === answer) pending = null;
      answer.reject(new Error("no answer"));
      if (answer.failed) toast("critical", answer.failed);
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
    keep(detail.json);
    // An earlier refusal ("Empty value…") is not this copy's.
    hideToast();
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

  function keep(json) {
    try {
      window.localStorage.setItem(KEPT, json);
    } catch (_error) {
      /* private mode: the system clipboard still has it */
    }
  }

  function kept() {
    try {
      return window.localStorage.getItem(KEPT);
    } catch (_error) {
      return null;
    }
  }

  // The text when it is a Sanity clipboard item, else null.
  function sanityItem(json) {
    try {
      var item = JSON.parse(json);
      return item && item.type === "sanityClipboardItem" ? json : null;
    } catch (_error) {
      return null;
    }
  }

  function fromBase64(text) {
    var bytes = Uint8Array.from(window.atob(text), function (c) {
      return c.charCodeAt(0);
    });
    return new TextDecoder().decode(bytes);
  }

  function textOf(item, type) {
    return item.getType(type).then(function (body) {
      return body.text();
    });
  }

  // One clipboard item's Sanity item: under its own type, else in text/html.
  function itemJson(item) {
    var types = Array.prototype.slice.call(item.types || []);
    var own = types.indexOf(SANITY_TYPE) >= 0 ? textOf(item, SANITY_TYPE).then(sanityItem) : Promise.resolve(null);
    return own.then(function (json) {
      if (json || types.indexOf("text/html") < 0) return json;
      return textOf(item, "text/html").then(function (html) {
        var found = /data-sanity-clipboard-base64="([^"]+)"/.exec(html);
        try {
          return found ? sanityItem(fromBase64(found[1])) : null;
        } catch (_error) {
          return null;
        }
      });
    });
  }

  // What the system clipboard holds now, as a Sanity item's JSON, or null.
  function readClip() {
    var clipboard = window.navigator.clipboard;
    if (!clipboard || !clipboard.read) return Promise.resolve(kept());
    return clipboard.read().then(
      function (items) {
        var list = Array.prototype.slice.call(items || []);
        var next = function (at) {
          if (at >= list.length) return null;
          return itemJson(list[at]).then(function (json) {
            return json || next(at + 1);
          });
        };
        return next(0);
      },
      function (error) {
        // Refused outright: this browser's own copy. An empty or unreadable
        // clipboard is nothing to paste.
        var refused = !(window.DOMException && error instanceof window.DOMException) || error.name === "NotAllowedError";
        return refused ? kept() : null;
      }
    );
  }

  // The click is held back, the clipboard read, and the click handed on with
  // the item on it. The menu closes by itself: the click's default is kept.
  function startPaste(item, event) {
    event.stopPropagation();
    readClip()
      .catch(function () {
        return null;
      })
      .then(function (json) {
        if (!json) return toast("default", item.getAttribute("data-desk-nothing") || "");
        if (json.length > MAX_CLIP) return toast("critical", item.getAttribute("data-desk-invalid") || "");
        if (!item.isConnected) return;
        hideToast();
        item.setAttribute("phx-value-clip", json);
        passing = true;
        try {
          item.click();
        } finally {
          passing = false;
          item.removeAttribute("phx-value-clip");
        }
      });
  }

  window.document.addEventListener(
    "click",
    function (event) {
      if (passing || !event.target || !event.target.closest) return;
      var copy = event.target.closest("[data-desk-field-copy]");
      if (copy && !copy.disabled) return startCopy(copy);
      var paste = event.target.closest("[data-desk-field-paste]");
      if (paste && !paste.disabled) startPaste(paste, event);
    },
    true
  );

  window.addEventListener("phx:desk:field-toast", function (event) {
    var detail = event.detail || {};
    if (detail.title) toast(detail.tone === "critical" ? "critical" : "default", detail.title, detail.description);
  });

  window.addEventListener("phx:desk:field-copied", function (event) {
    finishCopy(event.detail);
  });

  window.BarkparkDeskFieldActions = { toast: toast, writeAll: writeAll, readClip: readClip };
})();
