// bp-desk-lang-tabs.js: the keys of a localizedText field's language tabs
// on the desk (`BarkparkWeb.Components.Fields.LocalizedTabs`), as the
// TanStack Studio's LocalizedTextInput (barkpark-studio
// app/src/components/NativeInputs.tsx), a WAI-ARIA tablist.
//
// On a tab: ArrowRight and ArrowLeft move to the next and the previous
// language, round; Home and End to the first and the last. The tab moved to
// is clicked, so it is selected by its own click (a Phoenix.LiveView.JS
// command, which outlives the server's redraws), and takes the focus.
//
// A document-level listener, no phx-hook: bp-desk.js loads it when the desk
// mounts (the address is on the desk's root, `data-desk-lang-tabs`).
(function () {
  "use strict";

  if (window.BarkparkDeskLangTabs) return;

  var TAB = '.lang-tabs > [role="tab"]';

  function target(tabs, i, key) {
    var last = tabs.length - 1;
    if (key === "ArrowRight") return tabs[i === last ? 0 : i + 1];
    if (key === "ArrowLeft") return tabs[i === 0 ? last : i - 1];
    if (key === "Home") return tabs[0];
    if (key === "End") return tabs[last];
    return null;
  }

  function onKey(e) {
    var t = e.target;
    if (e.altKey || e.ctrlKey || e.metaKey || !t || !t.matches || !t.matches(TAB)) return;
    var tabs = Array.prototype.slice.call(t.parentNode.querySelectorAll(':scope > [role="tab"]'));
    var next = target(tabs, tabs.indexOf(t), e.key);
    if (!next) return;
    e.preventDefault();
    next.click();
    next.focus();
  }

  document.addEventListener("keydown", onKey);

  window.BarkparkDeskLangTabs = { target: target };
})();
