// The desk's Vision (Desk.Vision), as the TanStack Studio's Vision.tsx (J37):
// a query is fetched by the browser with the editor's own session, and its
// result drawn as a folding JSON tree, with the query URL to copy, the
// timings and Save result as JSON. The words are the page's (data-t-*).
//
// A query is Barkpark's older form, a type and a query string
// (`post?filter[title][contains]=x&limit=5`, GET …/v1/data/query/<ds>/<type>),
// or else GROQ, sent in the query parameter of GET …/v1/data/groq/<ds>: so
// nothing typed ever becomes a path. Reads only. It runs once a page, from the
// desk hook's loader; everything is delegated from the document, so a page
// drawn after it loaded works the same.
(function () {
  if (window.BarkparkDeskVision) return;

  var KEY = "bp-desk-vision";
  // Barkpark's older form: a type, then an optional query string. Anything else is GROQ.
  var QUERY_STRING = /^[A-Za-z0-9_-]+(\?[^#\n]*)?$/;
  // The GROQ read answers a longer GET with 414 (docs/contracts/groq-query.md).
  var MAX_URL = 32753;
  var PERSPECTIVES = ["raw", "published", "drafts"];
  // A big array or object draws this many entries, then "Show n more".
  var CHUNK = 100;
  // Open this deep, as Sanity's: GROQ's result is the tree; the query string's
  // documents sit two levels down ({result: {documents: […]}}).
  var OPEN_GROQ = 3;
  var OPEN_STRING = 5;

  var word = function (root, name, values) {
    var text = root.getAttribute("data-t-" + name) || "";
    return text.replace(/%\{(\w+)\}/g, function (all, key) {
      return values && key in values ? String(values[key]) : all;
    });
  };
  var part = function (root, sel) {
    return root.querySelector(sel);
  };

  /** What a query reads: {error} or {path, groq}. Pure, so the host tests load it. */
  var target = function (api, dataset, text, perspective) {
    var raw = String(text || "").trim();
    if (!raw) return { error: "empty" };
    var p = PERSPECTIVES.indexOf(perspective) >= 0 ? perspective : "drafts";
    var ds = encodeURIComponent(dataset);
    var path, groq;
    if (QUERY_STRING.test(raw)) {
      var at = raw.indexOf("?");
      var type = at < 0 ? raw : raw.slice(0, at);
      var params = new URLSearchParams(at < 0 ? "" : raw.slice(at + 1));
      if (!params.has("perspective")) params.set("perspective", p);
      path = api + "/query/" + ds + "/" + type + "?" + params.toString();
      groq = false;
    } else {
      path = api + "/groq/" + ds + "?" + new URLSearchParams({ query: raw, perspective: p }).toString();
      groq = true;
    }
    if (path.length > MAX_URL) return { error: "long" };
    return { path: path, groq: groq };
  };

  var remember = function (root) {
    try {
      localStorage.setItem(KEY, JSON.stringify({ query: part(root, "textarea").value, perspective: part(root, "[data-vision-perspective]").value }));
    } catch (_e) {}
  };

  // The last query and perspective stay in this browser, as TanStack's.
  var init = function (root) {
    if (root.__visionReady) return;
    root.__visionReady = true;
    try {
      var kept = JSON.parse(localStorage.getItem(KEY) || "null");
      // Not over what was typed before this script came.
      var box = part(root, "textarea");
      if (kept && typeof kept.query === "string" && kept.query.trim() && box.value === box.defaultValue) box.value = kept.query;
      if (kept && PERSPECTIVES.indexOf(kept.perspective) >= 0) part(root, "[data-vision-perspective]").value = kept.perspective;
    } catch (_e) {}
  };

  var el = function (doc, tag, cls, text) {
    var node = doc.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // Sanity Vision's tree: objects and arrays fold, each saying how much it holds.
  var node = function (root, name, value, depth, open) {
    var doc = root.ownerDocument;
    var li = el(doc, "li");
    li.setAttribute("role", "treeitem");
    var key = name === undefined ? null : el(doc, "span", "json-key", name + ": ");
    if (value === null || typeof value !== "object") {
      li.className = "json-leaf";
      if (key) li.appendChild(key);
      var type = value === null ? "null" : typeof value;
      li.appendChild(el(doc, "span", "json-" + type, type === "string" ? value : String(value)));
      return li;
    }
    var array = Array.isArray(value);
    var entries = array
      ? value.map(function (v, i) { return [String(i), v]; })
      : Object.keys(value).map(function (k) { return [k, value[k]]; });
    var n = entries.length;
    var count = array ? (n === 1 ? word(root, "item") : word(root, "items", { count: n })) : n === 1 ? word(root, "property") : word(root, "properties", { count: n });
    var button = el(doc, "button", "json-toggle");
    button.type = "button";
    var arrow = el(doc, "span", "json-arrow");
    arrow.setAttribute("aria-hidden", "true");
    if (depth > 0) button.appendChild(arrow);
    if (key) button.appendChild(key);
    button.appendChild(el(doc, "span", "json-brace", array ? (n ? "[…]" : "[]") : n ? "{…}" : "{}"));
    button.appendChild(doc.createTextNode(" "));
    button.appendChild(el(doc, "span", "json-count", count));
    li.appendChild(button);
    if (!n) {
      button.disabled = true;
      return li;
    }
    li.__entries = entries;
    li.__depth = depth;
    li.__open = open;
    setOpen(root, li, depth < open);
    return li;
  };

  var setOpen = function (root, li, open) {
    li.setAttribute("aria-expanded", open ? "true" : "false");
    var arrow = li.firstChild.querySelector(".json-arrow");
    if (arrow) arrow.textContent = open ? "▾" : "▸";
    var group = li.querySelector(":scope > ul");
    if (!open) {
      if (group) group.remove();
      return;
    }
    if (group) return;
    group = el(root.ownerDocument, "ul");
    group.setAttribute("role", "group");
    li.appendChild(group);
    drawFrom(root, li, group, 0);
  };

  var drawFrom = function (root, li, group, from) {
    var entries = li.__entries;
    var to = Math.min(entries.length, from + CHUNK);
    for (var i = from; i < to; i++) group.appendChild(node(root, entries[i][0], entries[i][1], li.__depth + 1, li.__open));
    if (to < entries.length) {
      var more = el(root.ownerDocument, "li");
      more.setAttribute("role", "none");
      var button = el(root.ownerDocument, "button", "json-more", word(root, "more", { count: entries.length - to }));
      button.type = "button";
      button.__more = { li: li, group: group, from: to };
      more.appendChild(button);
      group.appendChild(more);
    }
  };

  var tree = function (root, value, open) {
    var ul = el(root.ownerDocument, "ul", "json-tree");
    ul.setAttribute("role", "tree");
    ul.appendChild(node(root, undefined, value, 0, open));
    return ul;
  };

  // Where a GROQ parse error is: its line, with carets under start..end, as Sanity's.
  var frame = function (query, start, end) {
    var at = Math.max(0, Math.min(start, query.length));
    var before = query.slice(0, at).split("\n");
    var line = query.split("\n")[before.length - 1] || "";
    var column = before[before.length - 1].length;
    var width = Math.max(1, Math.min(line.length + 1 - column, (typeof end === "number" ? end : at + 1) - at));
    return line + "\n" + " ".repeat(column) + "^".repeat(width);
  };

  var say = function (root, text) {
    var said = part(root, "[data-vision-said]");
    if (said) said.textContent = text;
  };

  var show = function (root, run, answer) {
    var doc = root.ownerDocument;
    var out = part(root, "[data-vision-out]");
    out.textContent = "";
    out.removeAttribute("data-error");
    var save = part(root, "[data-vision-save]");
    save.hidden = true;
    root.__saved = null;
    var na = word(root, "na");
    var ms = answer.ms === undefined ? na : answer.ms + "ms";
    part(root, "[data-vision-ms]").textContent = word(root, "execution", { time: answer.error ? na : ms });
    part(root, "[data-vision-total]").textContent = word(root, "total", { time: answer.error ? na : answer.total + "ms" });
    var alert = function (message, where) {
      out.setAttribute("data-error", "");
      var box = el(doc, "div", "dk-vision-error");
      box.setAttribute("role", "alert");
      box.appendChild(el(doc, "p", null, message));
      if (where) box.appendChild(el(doc, "pre", null, where));
      out.appendChild(box);
    };
    if (answer.error) {
      alert(answer.error);
      return say(root, word(root, "failed", { error: answer.error }));
    }
    var body = answer.body;
    if (!answer.ok) {
      var error = body && typeof body === "object" ? body.error : null;
      var message = (error && (error.description || error.message)) || String(answer.status);
      var where = error && typeof error.start === "number" ? frame(run.query, error.start, error.end) : null;
      alert(message, where);
      return say(root, word(root, "error", { error: message }));
    }
    var value = run.groq && body && typeof body === "object" && "result" in body ? body.result : body;
    if (value === undefined) {
      out.appendChild(el(doc, "pre", null, answer.text));
    } else {
      out.appendChild(tree(root, value, run.groq ? OPEN_GROQ : OPEN_STRING));
      root.__saved = JSON.stringify(value, null, 2);
      save.hidden = false;
    }
    var rows = run.groq ? value : value && value.result && value.result.documents;
    if (!Array.isArray(rows)) return say(root, word(root, "done", { ms: answer.ms }));
    say(root, rows.length === 1 ? word(root, "one", { ms: answer.ms }) : word(root, "many", { count: rows.length, ms: answer.ms }));
  };

  var fetchIt = function (root) {
    init(root);
    remember(root);
    var query = part(root, "textarea").value;
    var to = target(root.getAttribute("data-api"), root.getAttribute("data-dataset"), query, part(root, "[data-vision-perspective]").value);
    var seq = (root.__seq = (root.__seq || 0) + 1);
    var url = part(root, "[data-vision-url]");
    if (to.error) {
      url.hidden = true;
      return show(root, { query: query }, { error: word(root, to.error) });
    }
    var href = root.ownerDocument.location.origin + to.path;
    url.hidden = false;
    part(root, "#dk-vision-url").value = href;
    var result = part(root, ".dk-vision-result");
    var button = part(root, "[data-vision-fetch]");
    result.setAttribute("aria-busy", "true");
    button.disabled = true;
    var t0 = performance.now();
    var run = { query: query.trim(), groq: to.groq };
    var done = function (answer) {
      if (seq !== root.__seq) return;
      result.setAttribute("aria-busy", "false");
      button.disabled = false;
      answer.total = Math.round(performance.now() - t0);
      show(root, run, answer);
    };
    window
      .fetch(to.path, { credentials: "same-origin", headers: { accept: "application/json" } })
      .then(function (res) {
        return res.text().then(function (text) {
          var body;
          try {
            body = JSON.parse(text);
          } catch (_e) {}
          var ms = body && typeof body.ms === "number" ? body.ms : Math.round(performance.now() - t0);
          done({ ok: res.ok, status: res.status, text: text, body: body, ms: ms });
        });
      })
      .catch(function (e) {
        done({ error: (e && e.message) || String(e) });
      });
  };

  var copy = function (root) {
    var input = part(root, "#dk-vision-url");
    var said = part(root, "[data-vision-copied]");
    var tell = function (ok) {
      said.textContent = word(root, ok ? "copied" : "not-copied");
      clearTimeout(root.__copiedTimer);
      root.__copiedTimer = setTimeout(function () { said.textContent = ""; }, 4000);
    };
    var fallback = function () {
      input.select();
      var ok = false;
      try {
        ok = root.ownerDocument.execCommand("copy");
      } catch (_e) {}
      tell(ok);
    };
    var clip = navigator.clipboard;
    if (clip && clip.writeText) clip.writeText(input.value).then(function () { tell(true); }, fallback);
    else fallback();
  };

  var vision = function (target) {
    return target && target.closest ? target.closest("[data-desk-vision]") : null;
  };

  document.addEventListener("click", function (e) {
    var root = vision(e.target);
    if (!root) return;
    init(root);
    var hit = e.target.closest("button, a");
    if (!hit) return;
    if (hit.hasAttribute("data-vision-fetch")) return fetchIt(root);
    if (hit.hasAttribute("data-vision-copy")) return copy(root);
    if (hit.__more) {
      var m = hit.__more;
      hit.parentNode.remove();
      return drawFrom(root, m.li, m.group, m.from);
    }
    if (hit.classList.contains("json-toggle")) {
      var li = hit.parentNode;
      return setOpen(root, li, li.getAttribute("aria-expanded") !== "true");
    }
    // Save result as JSON: the file is made when asked for, as a blob the link points at.
    if (hit.hasAttribute("data-vision-json")) {
      if (root.__saved === null || root.__saved === undefined) return e.preventDefault();
      if (hit.href.indexOf("blob:") === 0) URL.revokeObjectURL(hit.href);
      hit.href = URL.createObjectURL(new Blob([root.__saved], { type: "application/json;charset=utf-8" }));
    }
  });

  document.addEventListener("keydown", function (e) {
    var root = vision(e.target);
    if (!root || e.key !== "Enter" || !(e.metaKey || e.ctrlKey) || e.target.tagName !== "TEXTAREA") return;
    e.preventDefault();
    fetchIt(root);
  });

  document.addEventListener("change", function (e) {
    var root = vision(e.target);
    if (root) (init(root), remember(root));
  });

  // What is typed is kept as it is typed, as TanStack's.
  document.addEventListener("input", function (e) {
    var root = vision(e.target);
    if (root && e.target.tagName === "TEXTAREA") (init(root), remember(root));
  });

  document.addEventListener("focusin", function (e) {
    var root = vision(e.target);
    if (root) init(root);
  });

  document.querySelectorAll("[data-desk-vision]").forEach(init);

  window.BarkparkDeskVision = { target: target, frame: frame, fetchIt: fetchIt, init: init };
})();
