/**
 * Shared search intelligence client helpers (Phase 8).
 * Loaded before bp-* pickers/explorer in root.html.heex.
 */
(function (global) {
  const DEBOUNCE_MS = 350;

  function clientId(surface, dataset) {
    const key = "bp-search-client:" + surface + ":" + dataset;
    try {
      let id = sessionStorage.getItem(key);
      if (!id) {
        id =
          typeof crypto !== "undefined" && crypto.randomUUID
            ? crypto.randomUUID()
            : "c" + Date.now().toString(36);
        sessionStorage.setItem(key, id);
      }
      return id;
    } catch (_e) {
      return "anon-" + Date.now().toString(36);
    }
  }

  /**
   * @param {{clientId?: string, parentEventId?: string}} state
   * @param {{source?: string, record?: boolean, contentType?: boolean, authorization?: string}} opts
   */
  function searchHeaders(state, opts) {
    opts = opts || {};
    state = state || {};
    const h = { Accept: "application/json" };
    if (opts.contentType) h["Content-Type"] = "application/json";
    if (opts.authorization) h["Authorization"] = opts.authorization;
    if (state.clientId) h["X-BP-Search-Client"] = state.clientId;
    if (state.parentEventId) h["X-BP-Search-Parent"] = state.parentEventId;
    if (opts.source) h["X-BP-Search-Source"] = opts.source;
    if (opts.record) h["X-BP-Search-Record"] = "1";
    return h;
  }

  function debounce(fn, wait) {
    const ms = wait == null ? DEBOUNCE_MS : wait;
    let timer;
    return function debounced() {
      const args = arguments;
      const self = this;
      clearTimeout(timer);
      timer = setTimeout(function () {
        fn.apply(self, args);
      }, ms);
    };
  }

  function captureEventId(state, body) {
    if (state && body && body.searchEventId) {
      state.parentEventId = body.searchEventId;
    }
  }

  function interactionPath(surface, dataset) {
    if (surface === "media") {
      return (
        "/v1/media/" + encodeURIComponent(dataset) + "/search/interaction"
      );
    }
    return (
      "/v1/data/search/" + encodeURIComponent(dataset) + "/interaction"
    );
  }

  function trackInteraction(surface, dataset, state, objectId, position, opts) {
    opts = opts || {};
    if (!state || !state.parentEventId || !objectId) return;
    const url = interactionPath(surface, dataset);
    fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: searchHeaders(state, {
        contentType: true,
        source: opts.source,
        authorization: opts.authorization
      }),
      body: JSON.stringify({
        queryEventId: state.parentEventId,
        objectId: objectId,
        position: position,
        type: opts.type || "select"
      })
    }).catch(function () {});
  }

  global.BpSearchIntel = {
    DEBOUNCE_MS: DEBOUNCE_MS,
    clientId: clientId,
    searchHeaders: searchHeaders,
    debounce: debounce,
    captureEventId: captureEventId,
    trackInteraction: trackInteraction
  };
})(typeof window !== "undefined" ? window : globalThis);
