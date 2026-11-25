// bp-studio-leave.js — Studio asks before it leaves a held field
// (task-c4b59891f88686e0).
//
// A field held under the conflict banner keeps A's words in the form,
// unsaved. The desk asks from its pane (`Desk.LeaveGuard`, bp-desk-leave.js).
// Studio's editor form carries the same question as `data-studio-held`
// (`LeaveGuard.message/1`, naming the held fields) while anything is held:
//
//   - a link that leaves the document asks with `confirm`; Cancel keeps the
//     page where it is. A link to the page's own path keeps the document
//     and goes on. A link inside the form, a new-tab click and a hash link
//     go on too;
//   - the tab's close or reload asks (`beforeunload`; the browser words it).
//
// Nothing held, nothing asked. A document-level listener, no phx-hook: the
// form is redrawn on every patch.
(function () {
  if (window.BarkparkStudioLeave) return;

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
    return !(url.origin === window.location.origin && url.pathname === window.location.pathname);
  }

  function onClick(e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!link || !leaves(link)) return;
    var message = held();
    if (!message || window.confirm(message)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  function onUnload(e) {
    var message = held();
    if (!message) return undefined;
    e.preventDefault();
    e.returnValue = message;
    return message;
  }

  document.addEventListener("click", onClick, true);
  window.addEventListener("beforeunload", onUnload);
  window.BarkparkStudioLeave = { held: held };
})();
