// The desk's Vision (Desk.Vision), as the TanStack Studio's Vision.tsx (J37):
// a query is fetched by the browser with the editor's own session, and its
// result drawn as a folding JSON tree, with the query URL to copy, the
// timings and Save result as JSON. The words are the page's (data-t-*).
//
// A query is Barkpark's older form, a type and a query string
// (`post?filter[title][contains]=x&limit=5`, GET …/v1/data/query/<ds>/<type>),
// or else GROQ, sent in the query parameter of GET …/v<apiVersion>/data/query/<ds>
// (Sanity's address): so nothing typed ever becomes a path. Reads only. The
// dataset and API version are picked beside the perspective, as TanStack's, and
// Params is a JSON object whose keys the query names as $key: each goes as
// $key=<JSON>, as Sanity's client sends them, so a value is never a path. It runs once a page, from the
// desk hook's loader; everything is delegated from the document, so a page
// drawn after it loaded works the same. Its queries are bp-desk-vision-query.js and
// its result tree bp-desk-vision-tree.js: Desk.Vision's script tags load them first;
// on a live patch, where bp-desk.js loads this file alone, this loads them, then starts.
(function () {
  if (window.BarkparkDeskVision || window.__bpDeskVisionLoading) return;
  // The parts this needs, and the attribute on Vision's root naming each one's path.
  var parts = [["BarkparkDeskVisionQuery", "data-vision-query-js"], ["BarkparkDeskVisionTree", "data-vision-tree-js"]];
  var missing = parts.filter(function (p) { return !window[p[0]]; });
  if (!missing.length) return start();
  var root = document.querySelector("[data-desk-vision]");
  if (!root) return;
  window.__bpDeskVisionLoading = true;
  var left = missing.length;
  missing.forEach(function (p) {
    var script = document.createElement("script");
    script.src = root.getAttribute(p[1]);
    script.addEventListener("load", function () {
      if (--left === 0) (window.__bpDeskVisionLoading = false), start();
    });
    // Not loaded: the next open of Vision tries again (bp-desk.js loads this file again).
    script.addEventListener("error", function () {
      script.remove();
      window.__bpDeskVisionLoading = false;
      var me = document.querySelector("script[data-desk-vision-js]");
      if (me) me.remove();
    });
    document.head.appendChild(script);
  });

  function start() {
    var KEY = "bp-desk-vision";
    // Open this deep, as Sanity's: GROQ's result is the tree; the query string's
    // documents sit two levels down ({result: {documents: […]}}).
    var OPEN_GROQ = 3;
    var OPEN_STRING = 5;

    var part = function (root, sel) {
      return root.querySelector(sel);
    };

    var Q = window.BarkparkDeskVisionQuery;
    var T = window.BarkparkDeskVisionTree;
    var PERSPECTIVES = Q.PERSPECTIVES, today = Q.today, customApiVersion = Q.customApiVersion;
    var parseParams = Q.parseParams, target = Q.target, frame = Q.frame;
    var word = T.word, el = T.el, tree = T.tree, setOpen = T.setOpen, more = T.more;

    /** The version a run sends: the picked one, or under "Other" the last typed that read as one. */
    var version = function (root) {
      var pick = part(root, "[data-vision-version]");
      if (!root.__version) root.__version = pick.value === "other" ? today() : pick.value;
      return pick.value === "other" ? root.__version : pick.value;
    };

    // Params that are not a JSON object tint their pane, say why on its icon (and in the result, on a
    // Fetch), and Fetch waits until they are, as TanStack's. Returns what parseParams read.
    var checkParams = function (root) {
      var box = part(root, "[data-vision-params]");
      var read = parseParams(box ? box.value : "");
      var why = read.error ? (read.error === "params-json" ? word(root, "params-json", { detail: read.detail }) : word(root, "params-object")) : "";
      if (box) {
        box.closest("[data-vision-params-pane]").toggleAttribute("data-invalid", !!why);
        box.setAttribute("aria-invalid", why ? "true" : "false");
        var icon = part(root, "[data-vision-params-error]");
        icon.hidden = !why;
        icon.title = why;
      }
      root.__badParams = !!why;
      fetchState(root);
      return why ? { error: why } : read;
    };

    // Fetch is aria-disabled while a run is out or Params are not an object.
    var fetchState = function (root) {
      var button = part(root, "[data-vision-fetch]");
      root.__busy || root.__badParams ? button.setAttribute("aria-disabled", "true") : button.removeAttribute("aria-disabled");
    };

    var remember = function (root) {
      var params = part(root, "[data-vision-params]");
      try {
        localStorage.setItem(
          KEY,
          JSON.stringify({
            query: part(root, "#dk-vision-query").value,
            params: params ? params.value : undefined,
            perspective: part(root, "[data-vision-perspective]").value,
            dataset: part(root, "[data-vision-dataset]").value,
            version: version(root),
          })
        );
      } catch (_e) {}
    };

    // "Other" shows the field for a typed version, as Sanity's: it starts as "v", not yet one.
    var other = function (root, text) {
      var field = part(root, "[data-vision-custom]");
      var input = field.querySelector("input");
      field.hidden = text === null;
      if (text === null) return;
      input.value = text;
      input.setAttribute("aria-invalid", customApiVersion(text) ? "false" : "true");
    };

    var pickDataset = function (root) {
      part(root, "[data-vision-json]").setAttribute("download", "vision-" + part(root, "[data-vision-dataset]").value + ".json");
    };

    // A picker changed, or "Other"'s version was typed.
    var picked = function (root, el) {
      if (el.hasAttribute("data-vision-version")) {
        if (el.value === "other") other(root, "v");
        else (other(root, null), (root.__version = el.value));
      } else if (el.hasAttribute("data-vision-dataset")) {
        pickDataset(root);
      } else if (el.hasAttribute("data-vision-params")) {
        checkParams(root);
      } else if (el.closest("[data-vision-custom]")) {
        var v = customApiVersion(el.value);
        el.setAttribute("aria-invalid", v ? "false" : "true");
        if (v) root.__version = v;
      }
    };

    var option = function (select, value) {
      for (var i = 0; i < select.options.length; i++) if (select.options[i].value === value) return select.options[i];
      return null;
    };

    // The last query, perspective, dataset and API version stay in this browser, as TanStack's.
    var init = function (root) {
      if (root.__visionReady) return;
      root.__visionReady = true;
      try {
        var kept = JSON.parse(localStorage.getItem(KEY) || "null");
        // Not over what was typed before this script came.
        var box = part(root, "#dk-vision-query");
        if (kept && typeof kept.query === "string" && kept.query.trim() && box.value === box.defaultValue) box.value = kept.query;
        var params = part(root, "[data-vision-params]");
        if (params && kept && typeof kept.params === "string" && params.value === params.defaultValue) params.value = kept.params;
        if (kept && PERSPECTIVES.indexOf(kept.perspective) >= 0) part(root, "[data-vision-perspective]").value = kept.perspective;
        // A kept dataset only if this page lists it for this token; a kept version as listed, or as typed.
        var ds = kept && option(part(root, "[data-vision-dataset]"), kept.dataset);
        if (ds && !ds.disabled) (part(root, "[data-vision-dataset]").value = kept.dataset), pickDataset(root);
        var pick = part(root, "[data-vision-version]");
        if (kept && kept.version !== "other" && option(pick, kept.version)) {
          pick.value = kept.version;
        } else if (kept && customApiVersion(kept.version)) {
          pick.value = "other";
          root.__version = customApiVersion(kept.version);
          other(root, root.__version);
        }
      } catch (_e) {}
      checkParams(root);
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
      // One run at a time, as TanStack's Fetch. Not `disabled`: that would take focus off the
      // button it was pressed with, to the page's body. Fetch is `aria-disabled` while busy,
      // which Playwright's toBeEnabled() also reads as not enabled.
      if (root.__busy) return;
      init(root);
      remember(root);
      var query = part(root, "#dk-vision-query").value;
      // Params that are not an object send nothing: the result says why.
      var given = checkParams(root);
      var to = given.error
        ? { error: "params", text: given.error }
        : target(root.getAttribute("data-scope"), part(root, "[data-vision-dataset]").value, query, part(root, "[data-vision-perspective]").value, version(root), given.params);
      var seq = (root.__seq = (root.__seq || 0) + 1);
      var url = part(root, "[data-vision-url]");
      // "Copied" was said of the URL before this one.
      part(root, "[data-vision-copied]").textContent = "";
      if (to.error) {
        url.hidden = true;
        return show(root, { query: query }, { error: to.text || word(root, to.error, { name: to.name }) });
      }
      var href = root.ownerDocument.location.origin + to.shown;
      url.hidden = false;
      part(root, "#vision-url").value = href;
      var result = part(root, ".dk-vision-result");
      result.setAttribute("aria-busy", "true");
      root.__busy = true;
      fetchState(root);
      var t0 = performance.now();
      var run = { query: query.trim(), groq: to.groq };
      var done = function (answer) {
        if (seq !== root.__seq) return;
        result.setAttribute("aria-busy", "false");
        root.__busy = false;
        fetchState(root);
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
      var input = part(root, "#vision-url");
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
      if (hit.__more) return more(root, hit);
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
      if (root) (init(root), picked(root, e.target), remember(root));
    });

    // What is typed is kept as it is typed, as TanStack's.
    document.addEventListener("input", function (e) {
      var root = vision(e.target);
      if (!root || (e.target.tagName !== "TEXTAREA" && !e.target.closest("[data-vision-custom]"))) return;
      init(root);
      picked(root, e.target);
      remember(root);
    });

    document.addEventListener("focusin", function (e) {
      var root = vision(e.target);
      if (root) init(root);
    });

    document.querySelectorAll("[data-desk-vision]").forEach(init);

    window.BarkparkDeskVision = { target: target, parseParams: parseParams, customApiVersion: customApiVersion, frame: frame, fetchIt: fetchIt, init: init };
  }
})();
