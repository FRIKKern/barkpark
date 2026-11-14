// bp-asset-explorer-bulk.js: select many files in the Studio media library
// (bp-asset-explorer), then delete them, add them to a folder or take them out
// of one, and upload by dropping files on the grid.
//
// Loaded before bp-asset-explorer.js, whose connectedCallback calls
// attach(explorer) once. It adds no server power: every request goes through
// the explorer's own _mediaBase() and _headers(), to endpoints the explorer
// already calls plus POST …/delete-many. A dropped file goes through the
// explorer's own _uploadFiles(), the path the Upload button uses.
(function () {
  "use strict";

  // delete-many refuses a request that names more ids than this.
  var CHUNK = 100;

  function h(tag, cls, text, attrs) {
    var el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text != null) el.textContent = text;
    Object.keys(attrs || {}).forEach(function (k) {
      el.setAttribute(k, attrs[k]);
    });
    return el;
  }

  function nameOf(doc) {
    return (doc && (doc.title || (doc.fileInfo && doc.fileInfo.originalName) || doc._id)) || "";
  }

  function attach(ex) {
    var ticked = new Map(); // asset _id -> asset, in the order ticked
    var anchor = null; // the last asset ticked by hand; Shift+click ranges from it
    var busy = false; // a bulk request is running: one at a time
    var refused = []; // [{doc, count}] the last delete left behind
    var _t = function (text, vars) {
      return ex._t(text, vars);
    };
    var button = function (cls, text) {
      return h("button", "btn btn-sm " + cls, text, { type: "button" });
    };

    var bar = h("div", "bp-ae-bulk", null, { role: "group", "aria-label": _t("Selected files"), hidden: "" });
    var countEl = h("span", "bp-ae-bulk-count");
    var addSel = h("select", "form-input bp-ae-bulk-add", null, { "aria-label": _t("Add to folder") });
    var removeBtn = button("bp-ae-bulk-remove", _t("Remove from folder"));
    var deleteBtn = button("btn-destructive bp-ae-bulk-delete", _t("Delete"));
    var clearBtn = button("bp-ae-bulk-clear", _t("Clear selection"));
    bar.append(countEl, addSel, removeBtn, deleteBtn, clearBtn);
    // Outside the bar, which is hidden while nothing is ticked: a live region
    // has to be in the page before its text changes to be read out.
    var live = h("div", "sr-only bp-ae-bulk-live", null, { role: "status", "aria-live": "polite" });
    var panel = h("section", "bp-ae-bulk-refused", null, { tabindex: "-1", hidden: "" });
    var drop = h("div", "bp-ae-drop", null, { "aria-hidden": "true" });
    drop.appendChild(h("span", "bp-ae-drop-label", _t("Drop files to upload")));
    ex._gridWrapEl.before(bar, panel, live);
    ex._gridWrapEl.prepend(drop);

    function folders() {
      return (ex._collections || []).filter(function (c) {
        return c.kind !== "virtual" && c.id !== ex._collectionId;
      });
    }

    function syncBar(progress) {
      var n = ticked.size;
      var label = n ? _t("%{count} selected", { count: n }) : "";
      bar.hidden = n === 0 && !busy;
      countEl.textContent = progress || label;
      if (live.textContent !== (progress || label)) live.textContent = progress || label;
      ex._gridEl.classList.toggle("has-ticks", n > 0);
      var open = ex._currentCollection();
      removeBtn.hidden = !(open && open.kind !== "virtual");
      var list = folders();
      addSel.hidden = !list.length;
      addSel.textContent = "";
      addSel.appendChild(h("option", null, _t("Add to folder…"), { value: "" }));
      list.forEach(function (c) {
        addSel.appendChild(h("option", null, c.title || c.id, { value: c.id }));
      });
      [addSel, removeBtn, deleteBtn, clearBtn].forEach(function (el) {
        el.disabled = busy;
      });
    }

    // Tick boxes follow `ticked`; nothing else is rebuilt.
    function paint(progress) {
      ex._gridEl.querySelectorAll(".bp-ae-tick").forEach(function (box) {
        var on = ticked.has(box.dataset.tickId);
        box.checked = on;
        box.disabled = busy;
        box.parentNode.classList.toggle("is-ticked", on);
      });
      syncBar(progress);
    }

    // Runs after every grid render. Each card is a <button>, and a tick box
    // may not sit inside one, so the pair goes in a wrapper. A tick on a file
    // that is no longer in the list goes away with it.
    function decorate() {
      var loaded = new Map(
        ex._assets.map(function (d) {
          return [d._id, d];
        })
      );
      Array.from(ticked.keys()).forEach(function (id) {
        if (loaded.has(id)) ticked.set(id, loaded.get(id));
        else ticked.delete(id);
      });
      if (anchor && !loaded.has(anchor)) anchor = null;
      ex._gridEl.querySelectorAll(".bp-ae-card, .bp-ae-list-row").forEach(function (card) {
        var doc = loaded.get(card.dataset.id);
        if (!doc) return;
        var cell = h("div", "bp-ae-cell");
        var box = h("input", "bp-ae-tick", null, {
          type: "checkbox",
          "aria-label": _t("Select %{name}", { name: nameOf(doc) })
        });
        box.dataset.tickId = doc._id;
        card.replaceWith(cell);
        cell.append(box, card);
      });
      paint();
    }

    function tick(id, on, range) {
      var items = ex._assets;
      var to = items.findIndex(function (d) {
        return d._id === id;
      });
      if (to < 0) return;
      var from = range && anchor ? items.findIndex(function (d) { return d._id === anchor; }) : -1;
      if (from >= 0) {
        for (var i = Math.min(from, to); i <= Math.max(from, to); i++) ticked.set(items[i]._id, items[i]);
      } else if (on) {
        ticked.set(id, items[to]);
      } else {
        ticked.delete(id);
      }
      anchor = id;
      paint();
    }

    function clear() {
      ticked.clear();
      anchor = null;
      paint();
    }

    // Capture phase: a Shift or Ctrl/Cmd click on a card ticks it and never
    // reaches the card's own handler. A plain click still opens the inspector.
    ex._gridEl.addEventListener(
      "click",
      function (e) {
        var box = e.target.closest && e.target.closest(".bp-ae-tick");
        if (box) {
          e.stopPropagation();
          tick(box.dataset.tickId, box.checked, e.shiftKey);
          return;
        }
        var card = e.target.closest && e.target.closest(".bp-ae-card, .bp-ae-list-row");
        if (!card || !(e.shiftKey || e.metaKey || e.ctrlKey)) return;
        e.preventDefault();
        e.stopPropagation();
        if (!busy) tick(card.dataset.id, e.shiftKey || !ticked.has(card.dataset.id), e.shiftKey);
      },
      true
    );

    document.addEventListener("keydown", function (e) {
      if (!ex.isConnected || busy) return;
      var el = e.target;
      var typing = el && /input|textarea|select/i.test(el.tagName || "") && !el.classList.contains("bp-ae-tick");
      if ((e.metaKey || e.ctrlKey) && String(e.key).toLowerCase() === "a") {
        if (typing || !ex._gridWrapEl.contains(document.activeElement) || !ex._assets.length) return;
        e.preventDefault();
        ex._assets.forEach(function (d) {
          ticked.set(d._id, d);
        });
        paint();
      } else if (e.key === "Escape" && ticked.size && !typing && !ex.querySelector(".bp-ae-modal:not([hidden])")) {
        clear();
      }
    });

    // A real confirm step: this Studio does nothing with data-confirm.
    function ask(title, hint, okLabel) {
      return new Promise(function (resolve) {
        var modal = h("div", "bp-ae-modal bp-ae-bulk-confirm", null, {
          role: "dialog",
          "aria-labelledby": "bp-ae-bulk-confirm-title"
        });
        modal.setAttribute("aria-modal", "true");
        var card = h("div", "bp-ae-modal-card");
        var actions = h("div", "bp-ae-modal-actions");
        var cancel = button("bp-ae-bulk-confirm-cancel", _t("Cancel"));
        var ok = button("btn-destructive bp-ae-bulk-confirm-ok", okLabel);
        var backdrop = h("div", "bp-ae-modal-backdrop");
        actions.append(cancel, ok);
        card.append(
          h("h2", "bp-ae-modal-title", title, { id: "bp-ae-bulk-confirm-title" }),
          h("p", "bp-ae-modal-hint text-sm text-muted", hint),
          actions
        );
        modal.append(backdrop, card);
        var release = null;
        var done = function (answer) {
          if (!modal.isConnected) return;
          modal.remove();
          if (release) release();
          resolve(answer);
        };
        var mf = window.BarkparkModalFocus;
        if (mf && typeof mf.trap === "function") {
          release = mf.trap(modal, { onEscape: function () { done(false); }, fallback: deleteBtn });
        }
        backdrop.addEventListener("click", function () { done(false); });
        cancel.addEventListener("click", function () { done(false); });
        ok.addEventListener("click", function () { done(true); });
        ex.appendChild(modal);
        cancel.focus();
      });
    }

    // What the explorer says when a write is refused for who is asking.
    function refusalText(status) {
      if (status === 401) return _t("Your session has ended. Sign in again.");
      if (status === 403) return _t("You do not have permission to change these files.");
      return "";
    }

    function renderPanel() {
      panel.textContent = "";
      panel.hidden = !refused.length;
      if (!refused.length) return;
      var used = refused.filter(function (r) { return r.count > 0; });
      panel.appendChild(
        h("strong", "bp-ae-bulk-refused-title",
          refused.length === 1
            ? _t("1 file was not deleted")
            : _t("%{count} files were not deleted", { count: refused.length }))
      );
      var list = h("ul", "bp-ae-bulk-refused-list");
      refused.forEach(function (r) {
        var why =
          r.count === 1
            ? _t("Used by 1 document")
            : r.count > 1
              ? _t("Used by %{count} documents", { count: r.count })
              : _t("Could not be deleted");
        var li = h("li");
        li.append(h("span", "bp-ae-bulk-refused-name", nameOf(r.doc)), h("span", "text-muted", why));
        list.appendChild(li);
      });
      var actions = h("div", "bp-ae-bulk-refused-actions");
      if (used.length) {
        var anyway = button("btn-destructive bp-ae-bulk-force", _t("Delete anyway"));
        anyway.addEventListener("click", function () {
          if (busy) return;
          var docs = used.map(function (r) { return r.doc; });
          ask(
            docs.length === 1
              ? _t("Delete 1 file that documents use?")
              : _t("Delete %{count} files that documents use?", { count: docs.length }),
            _t("Documents that use these files will show a broken file. This cannot be undone."),
            _t("Delete anyway")
          ).then(function (yes) {
            if (yes) runDelete(docs, true);
          });
        });
        actions.appendChild(anyway);
      }
      var close = button("bp-ae-bulk-refused-close", _t("Close"));
      close.addEventListener("click", function () {
        refused = [];
        renderPanel();
      });
      actions.appendChild(close);
      panel.append(list, actions);
    }

    // The inspector may be showing a file that is now gone.
    function dropInspected(gone) {
      if (!ex._selected || !gone.has(ex._selected._id)) return;
      ex._selected = null;
      ex._inspectorMode = ex._collectionId ? "collection" : "none";
      if (ex._collectionId) ex._renderCollectionInspector();
      else ex._showEmptyInspector();
    }

    // `force` is sent only from the refusal panel's second confirm. The call
    // may take minutes: no timeout, one request at a time, bar disabled.
    async function runDelete(docs, force) {
      docs = docs.filter(function (d) { return d && d._blobId; });
      if (busy || !docs.length) return;
      busy = true;
      refused = [];
      renderPanel();
      var byBlob = new Map(docs.map(function (d) { return [d._blobId, d]; }));
      var ids = Array.from(byBlob.keys());
      var gone = new Set();
      var failure = "";
      var progress = function (done) {
        paint(_t("Deleting… %{done} of %{total}", { done: done, total: ids.length }));
      };
      progress(0);
      for (var i = 0; i < ids.length && !failure; i += CHUNK) {
        var chunk = ids.slice(i, i + CHUNK);
        var out = null;
        try {
          var r = await fetch(ex._mediaBase() + "/delete-many", {
            method: "POST",
            credentials: "same-origin",
            headers: ex._headers(true),
            body: JSON.stringify(force ? { ids: chunk, force: true } : { ids: chunk })
          });
          var data = await r.json().catch(function () { return null; });
          // 200 carries the three lists in `result`; a 409 with any file
          // refused carries the same lists in `error.details`.
          if (r.ok) out = data && data.result;
          else if (r.status === 409) out = data && data.error && data.error.details;
          if (!out || !Array.isArray(out.deleted)) {
            out = null;
            failure = refusalText(r.status) || _t("Delete failed (%{status})", { status: r.status });
          }
        } catch (_e) {
          failure = _t("The delete request failed. The list shows what is left.");
        }
        if (out) {
          out.deleted.concat(out.gone || []).forEach(function (id) {
            var doc = byBlob.get(id);
            if (doc) gone.add(doc._id);
          });
          (out.refused || []).forEach(function (row) {
            var doc = byBlob.get(row.id);
            if (doc) refused.push({ doc: doc, count: Number(row.referencedByCount) || 0 });
          });
        }
        progress(Math.min(i + CHUNK, ids.length));
      }
      busy = false;
      gone.forEach(function (id) { ticked.delete(id); });
      dropInspected(gone);
      if (failure) ex._toast(failure);
      else if (gone.size === 1) ex._toast(_t("1 file deleted"));
      else if (gone.size) ex._toast(_t("%{count} files deleted", { count: gone.size }));
      renderPanel();
      // Refreshes the grid, the counts and the facets; decorate() then drops
      // the ticks of files that are gone and keeps the refused ones.
      await ex._loadAssets();
      if (refused.length) panel.focus();
    }

    // Add to (POST) or take out of (DELETE) a folder, one file per request:
    // the member endpoints the inspector already uses.
    async function eachMember(folder, add) {
      var docs = Array.from(ticked.values()).filter(function (d) { return d._blobId; });
      if (busy || !folder || !docs.length) return;
      busy = true;
      var base = ex._mediaBase() + "/collections/" + encodeURIComponent(folder.id) + "/members";
      var failed = 0;
      var stop = "";
      for (var i = 0; i < docs.length && !stop; i++) {
        paint(_t("Working… %{done} of %{total}", { done: i, total: docs.length }));
        try {
          var r = add
            ? await fetch(base, {
                method: "POST",
                credentials: "same-origin",
                headers: ex._headers(true),
                body: JSON.stringify({ assetId: docs[i]._blobId })
              })
            : await fetch(base + "/" + encodeURIComponent(docs[i]._blobId), {
                method: "DELETE",
                credentials: "same-origin",
                headers: ex._headers()
              });
          if (r.ok) ticked.delete(docs[i]._id);
          else if (!(stop = refusalText(r.status))) failed++;
        } catch (_e) {
          failed++;
        }
      }
      busy = false;
      var vars = { count: docs.length, failed: failed, name: folder.title || folder.id };
      if (stop) ex._toast(stop);
      else if (failed) ex._toast(add ? _t("%{failed} of %{count} could not be added", vars) : _t("%{failed} of %{count} could not be removed", vars));
      else ex._toast(add ? _t("Added %{count} to %{name}", vars) : _t("Removed %{count} from %{name}", vars));
      await ex._loadAssets();
    }

    addSel.addEventListener("change", function () {
      var folder = folders().find(function (c) { return c.id === addSel.value; });
      addSel.value = "";
      eachMember(folder, true);
    });
    removeBtn.addEventListener("click", function () {
      eachMember(ex._currentCollection(), false);
    });
    clearBtn.addEventListener("click", clear);
    deleteBtn.addEventListener("click", function () {
      if (busy || !ticked.size) return;
      var docs = Array.from(ticked.values());
      ask(
        docs.length === 1 ? _t("Delete 1 file?") : _t("Delete %{count} files?", { count: docs.length }),
        _t("This cannot be undone. Files that documents use are kept."),
        _t("Delete")
      ).then(function (yes) {
        if (yes) runDelete(docs, false);
      });
    });

    // Drop files from the desktop on the grid. A drag that carries no files
    // (text, a link, a card) is left to the browser.
    var depth = 0;
    var carriesFiles = function (e) {
      var types = (e.dataTransfer && e.dataTransfer.types) || [];
      return Array.prototype.indexOf.call(types, "Files") !== -1;
    };
    var zone = function (on) {
      if (!on) depth = 0;
      ex._gridWrapEl.classList.toggle("is-drop-target", on);
    };
    ex._gridWrapEl.addEventListener("dragenter", function (e) {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      depth++;
      zone(true);
    });
    ex._gridWrapEl.addEventListener("dragover", function (e) {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    });
    ex._gridWrapEl.addEventListener("dragleave", function (e) {
      if (carriesFiles(e) && --depth <= 0) zone(false);
    });
    ex._gridWrapEl.addEventListener("drop", function (e) {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      zone(false);
      var files = Array.from(e.dataTransfer.files || []);
      if (files.length) ex._uploadFiles(files);
    });

    var renderGrid = ex._renderGrid.bind(ex);
    ex._renderGrid = function () {
      renderGrid();
      decorate();
    };
    syncBar();
    return { clear: clear, ticked: ticked };
  }

  window.BpAssetExplorerBulk = { attach: attach, CHUNK: CHUNK };
})();
