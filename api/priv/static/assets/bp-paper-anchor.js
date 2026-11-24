// bp-paper-anchor.js: an outside link to a legacy body's anchor still lands
// (task-52d612bdb8ff6cb3).
//
// The sanitizer moves every stored id (and an `a`'s name) in a legacy body
// into the body's own namespace, `bp-anchor-<id>`, so a stored id can never
// take a page element's place (HtmlSanitizer.Anchors). Links inside the body
// move with it. A link from outside, `/papers/x#intro`, does not: this asset
// lands it on `bp-anchor-intro` when nothing on the page is `#intro`.
//
// It only scrolls. A hash that already names an element is the browser's to
// land, so a page id is never redirected into the body. Loaded `defer` at the
// bottom of the reader layout (Golden Rule 4), same-origin (CSP 'self').
(function () {
  "use strict";

  var PREFIX = "bp-anchor-";

  function fragment(hash) {
    var raw = String(hash || "").replace(/^#/, "");
    try {
      return decodeURIComponent(raw);
    } catch (_e) {
      return raw;
    }
  }

  // The element `hash` should land on when the browser could not, or null.
  function target(hash) {
    var id = fragment(hash);
    if (id === "" || id.indexOf(PREFIX) === 0) return null;
    if (document.getElementById(id) || document.getElementsByName(id).length) return null;

    var moved = document.getElementById(PREFIX + id);
    if (moved) return moved;

    var named = document.getElementsByName(PREFIX + id);
    for (var i = 0; i < named.length; i++) {
      if (named[i].tagName === "A") return named[i];
    }
    return null;
  }

  function land() {
    var el = target(window.location.hash);
    if (el && typeof el.scrollIntoView === "function") el.scrollIntoView();
  }

  window.addEventListener("hashchange", land);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", land);
  else land();

  window.BarkparkPaperAnchor = { target: target, land: land };
})();
