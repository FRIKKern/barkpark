// bp-asset-explorer-usage.js: the "Used in" list in the Studio media
// library's asset inspector (bp-asset-explorer). It names each document that
// uses the selected file, with its type and whether the draft or the
// published version uses it, and links each one to the document in the
// Studio. A file nothing uses says so.
//
// Loaded before bp-asset-explorer.js, whose asset inspector calls
// load(explorer, asset) each time it shows an asset. It adds no server power:
// the one request is GET …/:id/usage through the explorer's own _mediaBase()
// and _headers(), and the server answers only with documents this caller may
// read (Barkpark.Media.Usage).
//
// The links go under the explorer's data-studio-path (the dataset's Studio
// root, `…/d/<dataset>/studio`) as `<root>/<type>/<id>`, the path a desk
// document opens at. Without that attribute the titles are listed as text.
(function () {
  "use strict";

  function h(tag, text, css) {
    var el = document.createElement(tag);
    if (text != null) el.textContent = text;
    if (css) el.style.cssText = css;
    return el;
  }

  function docLink(ex, doc) {
    var root = ex.getAttribute("data-studio-path");
    var title = doc.title || doc.id;
    if (!root || !doc.type || !doc.id) return h("span", title);
    var a = h("a", title);
    a.className = "bp-ae-usage-link";
    a.href = root + "/" + encodeURIComponent(doc.type) + "/" + encodeURIComponent(doc.id);
    return a;
  }

  function state(ex, doc) {
    return doc.published ? ex._t("Published") : ex._t("Draft");
  }

  function render(ex, section, result) {
    var docs = (result && result.documents) || [];
    var total = (result && typeof result.total === "number" && result.total) || docs.length;
    var body = section.querySelector(".bp-ae-usage-body");
    body.textContent = "";

    if (!docs.length) {
      body.appendChild(h("p", ex._t("Not used anywhere"), "margin: 2px 0 0; color: var(--fg-dim);"));
      return;
    }

    var list = h("ul", null, "list-style: none; margin: 2px 0 0; padding: 0;");
    list.className = "bp-ae-usage-list";
    docs.forEach(function (doc) {
      var li = h("li", null, "margin: 0 0 6px;");
      li.setAttribute("data-usage-id", doc.id);
      li.appendChild(docLink(ex, doc));
      li.appendChild(
        h("span", " · " + (doc.type || "") + " · " + state(ex, doc), "color: var(--fg-dim);")
      );
      list.appendChild(li);
    });
    body.appendChild(list);

    if (total > docs.length) {
      body.appendChild(
        h(
          "p",
          ex._t("Showing the first %{shown} of %{total}.", { shown: docs.length, total: total }),
          "margin: 0; color: var(--fg-dim);"
        )
      );
    }
  }

  async function load(ex, asset) {
    var host = ex._inspectorBody;
    if (!host || !asset || !asset._blobId) return;
    // The inspector moved on to another asset while it read this one's detail.
    if (ex._selected && ex._selected !== asset) return;
    host.querySelectorAll(".bp-ae-usage").forEach(function (old) {
      old.remove();
    });

    var section = h("section", null, "font-size: var(--text-xs); margin: 0 0 16px;");
    section.className = "bp-ae-usage";
    var heading = h("h3", ex._t("Used in"), "font-size: inherit; font-weight: 500; margin: 0; color: var(--fg-dim);");
    heading.id = "bp-ae-usage-" + String(asset._blobId).replace(/[^A-Za-z0-9_-]/g, "");
    section.setAttribute("aria-labelledby", heading.id);
    var body = h("div", null);
    body.className = "bp-ae-usage-body";
    body.setAttribute("aria-live", "polite");
    body.appendChild(h("p", ex._t("Checking where this file is used…"), "margin: 2px 0 0; color: var(--fg-dim);"));
    section.append(heading, body);

    var after = host.querySelector(".bp-ae-relations") || host.querySelector(".bp-ae-meta");
    if (after) after.after(section);
    else host.appendChild(section);

    try {
      var r = await fetch(ex._mediaBase() + "/" + encodeURIComponent(asset._blobId) + "/usage", {
        credentials: "same-origin",
        headers: ex._headers()
      });
      if (!r.ok) throw new Error("usage " + r.status);
      var data = await r.json();
      // Another asset was selected while this one was read: its inspector,
      // and this section with it, is gone.
      if (!section.isConnected) return;
      render(ex, section, data && data.result);
    } catch (_e) {
      if (!section.isConnected) return;
      body.textContent = "";
      body.appendChild(h("p", ex._t("Could not check where this file is used"), "margin: 2px 0 0;"));
    }
  }

  window.BpAssetExplorerUsage = { load: load };
})();
