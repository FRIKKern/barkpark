// bp-studio-leave.js — Studio asks before it leaves a held field
// (task-c4b59891f88686e0).
//
// A field held under the conflict banner keeps A's words in the form,
// unsaved. The desk asks from its pane (`Desk.LeaveGuard`, bp-desk-leave.js).
// Studio's editor form carries the same question as `data-studio-held`
// (`LeaveGuard.message/1`, naming the held fields) while anything is held:
//
//   - a plain click on a link to another place on this site is held back
//     before the URL moves and handed to the server: the bridge button
//     (`#studio-leave-ask`, `LeaveAsk.bridge/1`) is given the link's path
//     and its LiveView kind (`data-phx-link`) and clicked, so the server
//     asks with the desk's dialog (`LeaveAsk.link/2`, task-5b4914f1b5f21594)
//     or lets it go. A link to the page's own path keeps the document and
//     goes on, and so do a link inside the form, a new-tab or modified
//     click, a hash link and a link to another site (the tab's
//     `beforeunload` asks for that one);
//   - the dialog's own Leave (`data-desk-leave-go`) goes on, and its unload
//     does not ask again: a full-page link asked twice (#28836 r1 review);
//   - the tab's close or reload asks (`beforeunload`; the browser words it).
//
// List rows, crumbs and New document are `phx-click` buttons: the server
// asks for those too (`StudioLive.LeaveAsk`).
//
// Nothing held, nothing asked. A document-level listener, no phx-hook: the
// form is redrawn on every patch.
(function () {
  if (window.BarkparkStudioLeave) return;

  // When the dialog's Leave was pressed; its own unload does not ask.
  var leftAt = 0;

  function held() {
    var form = document.querySelector("form#editor-form[data-studio-held]");
    return form ? form.getAttribute("data-studio-held") : null;
  }

  function leaves(link) {
    if (link.closest("#editor-form")) return false;
    if (link.target && link.target !== "_self") return false;
    if (link.hasAttribute("download")) return false;
    var href = link.getAttribute("href");
    if (!href || href.charAt(0) === "#") return false;
    var url;
    try {
      url = new URL(href, window.location.href);
    } catch (_e) {
      return false;
    }
    if (url.origin !== window.location.origin) return false;
    return url.pathname !== window.location.pathname ? url : false;
  }

  function onClick(e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!link) return;
    if (link.hasAttribute("data-desk-leave-go")) {
      leftAt = Date.now();
      return;
    }
    var url = leaves(link);
    if (!url || !held()) return;
    var bridge = document.getElementById("studio-leave-ask");
    if (!bridge) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    bridge.setAttribute("phx-value-href", url.pathname + url.search + url.hash);
    bridge.setAttribute("phx-value-kind", link.getAttribute("data-phx-link") || "");
    bridge.click();
  }

  function onUnload(e) {
    var message = held();
    if (!message || Date.now() - leftAt < 2000) return undefined;
    e.preventDefault();
    e.returnValue = message;
    return message;
  }

  document.addEventListener("click", onClick, true);
  window.addEventListener("beforeunload", onUnload);
  window.BarkparkStudioLeave = { held: held };
})();
