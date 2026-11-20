// The desk's Vision (bp-desk-vision.js), its queries: what a query reads (a type and a
// query string at …/v1/data/query/<ds>/<type>, or GROQ in the query parameter of
// …/v<apiVersion>/data/query/<ds>, with Params as $key=<JSON>), the API version typed
// under "Other", the Params box read, and where a GROQ parse error is. Pure: no page,
// so the host tests load it. bp-desk-vision.js uses it as window.BarkparkDeskVisionQuery.
(function () {
  if (window.BarkparkDeskVisionQuery) return;

  // Barkpark's older form: a type, then an optional query string. Anything else is GROQ.
  var QUERY_STRING = /^[A-Za-z0-9_-]+(\?[^#\n]*)?$/;
  // The GROQ read answers a longer GET with 414 (docs/contracts/groq-query.md).
  var MAX_URL = 32753;
  var PERSPECTIVES = ["raw", "published", "drafts"];
  // An API version as sent: Sanity's 1, X or a date (lib/vision-groq.ts).
  var VERSION = /^v(1|X|\d{4}-\d{2}-\d{2})$/;
  var today = function () {
    return "v" + new Date().toISOString().split("T")[0];
  };

  /** A version typed under "Other" (Sanity's validateApiVersion): the "v" optional, 1, X or a date. As sent, or null. */
  var customApiVersion = function (text) {
    var v = String(text || "").replace(/^v/, "").trim().toUpperCase();
    if (v === "1" || v === "X") return "v" + v;
    return /^\d{4}-\d{2}-\d{2}$/.test(v) && !isNaN(Date.parse(v)) ? "v" + v : null;
  };

  /** The Params box as an object, or why not ({error, detail}): JSON, as TanStack's; blank is none. */
  var parseParams = function (text) {
    if (!String(text || "").trim()) return { params: {} };
    try {
      var v = JSON.parse(text);
    } catch (e) {
      return { error: "params-json", detail: (e && e.message) || "" };
    }
    if (!v || typeof v !== "object" || Array.isArray(v)) return { error: "params-object" };
    return { params: v };
  };

  // The query-string form's $key: the value, a list comma-joined (Barkpark's `in`), encoded where it is put.
  var valueOf = function (v) {
    return Array.isArray(v) ? v.map(String).join(",") : v === null ? "null" : typeof v === "object" ? JSON.stringify(v) : String(v);
  };

  /** What a query reads, under the project's `scope` path: {error} or {path, groq, shown}; `shown`, the Query URL, keeps a query string's brackets as typed (TanStack's). Pure, so the host tests load it. */
  var target = function (scope, dataset, text, perspective, version, given) {
    var values = given || {};
    var raw = String(text || "").trim();
    if (!raw) return { error: "empty" };
    var p = PERSPECTIVES.indexOf(perspective) >= 0 ? perspective : "drafts";
    var ds = encodeURIComponent(dataset);
    var path, groq, shown;
    if (QUERY_STRING.test(raw)) {
      var at = raw.indexOf("?");
      var type = at < 0 ? raw : raw.slice(0, at);
      var missing = null;
      var qs = (at < 0 ? "" : raw.slice(at + 1)).replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, function (all, key) {
        if (Object.prototype.hasOwnProperty.call(values, key)) return encodeURIComponent(valueOf(values[key]));
        return (missing = missing || key), all;
      });
      if (missing) return { error: "params-missing", name: missing };
      var params = new URLSearchParams(qs);
      if (!params.has("perspective")) params.set("perspective", p);
      path = scope + "/v1/data/query/" + ds + "/" + type + "?" + params.toString();
      shown = scope + "/v1/data/query/" + ds + "/" + type + "?" + decodeURIComponent(params.toString());
      groq = false;
    } else {
      var v = VERSION.test(version) ? version : today();
      var sent = new URLSearchParams({ query: raw });
      for (var key in values) if (Object.prototype.hasOwnProperty.call(values, key)) sent.set("$" + key, JSON.stringify(values[key]));
      sent.set("perspective", p);
      path = scope + "/" + v + "/data/query/" + ds + "?" + sent.toString();
      groq = true;
    }
    if (path.length > MAX_URL) return { error: "long" };
    return { path: path, groq: groq, shown: shown || path };
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

  window.BarkparkDeskVisionQuery = { PERSPECTIVES: PERSPECTIVES, today: today, customApiVersion: customApiVersion, parseParams: parseParams, target: target, frame: frame };
})();
