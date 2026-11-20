// The desk's Vision, its Listen (bp-desk-vision.js), as the TanStack Studio's (J37,
// lib/vision-listen.ts): the query's changes as they happen, newest first, the last 50,
// as a JSON tree, until Stop. It runs over the desk's own LiveView socket
// (Desk.VisionListen): the page asks with `vision-listen-start` and `vision-listen-stop`
// through the desk hook, and each change comes back as the `desk-vision-listen` event.
// No token is ever in the page: the socket is signed in already, and the server holds
// the Listen to its workspace, project and dataset. bp-desk-vision.js uses it as
// window.BarkparkDeskVisionListen.
(function () {
  if (window.BarkparkDeskVisionListen) return;

  var KEEP = 50;
  var OPEN = 2;

  var part = function (root, sel) {
    return root.querySelector(sel);
  };

  // The desk hook's push (bp-desk.js sets it on the hook's element).
  var pusher = function (root) {
    for (var n = root; n; n = n.parentElement) if (typeof n.bpPush === "function") return n.bpPush;
    return null;
  };

  var live = function (root) {
    return !!(root.__listen && !root.__listen.error);
  };

  // The button reads Stop while listening (aria-pressed), else Listen.
  var button = function (root) {
    var b = part(root, "[data-vision-listen]");
    if (!b) return;
    var on = live(root);
    var T = window.BarkparkDeskVisionTree;
    b.setAttribute("aria-pressed", on ? "true" : "false");
    part(b, "[data-vision-listen-play]").hidden = on;
    part(b, "[data-vision-listen-stop]").hidden = !on;
    part(b, "[data-vision-listen-word]").textContent = T.word(root, on ? "stop" : "listen");
    on || !root.__badParams ? b.removeAttribute("aria-disabled") : b.setAttribute("aria-disabled", "true");
  };

  // The Result, as TanStack draws a Listen: its error, a hint until the first change, then the changes.
  var draw = function (root) {
    var T = window.BarkparkDeskVisionTree;
    var doc = root.ownerDocument;
    var out = part(root, "[data-vision-out]");
    var l = root.__listen;
    out.textContent = "";
    out.removeAttribute("data-error");
    if (!l) return;
    if (l.error) {
      out.setAttribute("data-error", "");
      var box = T.el(doc, "div", "dk-vision-error");
      box.setAttribute("role", "alert");
      box.appendChild(T.el(doc, "p", null, l.error));
      return out.appendChild(box);
    }
    if (l.skipped) out.appendChild(T.el(doc, "p", "dk-vision-hint", T.word(root, "listen-skipped", { count: l.skipped })));
    if (!l.events.length) return out.appendChild(T.el(doc, "p", "dk-vision-hint", T.word(root, l.open ? "listening" : "connecting")));
    out.appendChild(T.tree(root, l.events, OPEN));
  };

  // A Listen has no timings and nothing to save, as TanStack's.
  var clear = function (root) {
    var T = window.BarkparkDeskVisionTree;
    var na = T.word(root, "na");
    part(root, "[data-vision-save]").hidden = true;
    root.__saved = null;
    part(root, "[data-vision-ms]").textContent = T.word(root, "execution", { time: na });
    part(root, "[data-vision-total]").textContent = T.word(root, "total", { time: na });
    part(root, "[data-vision-url]").hidden = true;
  };

  /** Listen to what `ask` names ({error} or `target`'s `listen` plus `dataset`). */
  var start = function (root, ask) {
    stop(root);
    clear(root);
    var id = (root.__listenSeq = (root.__listenSeq || 0) + 1);
    var push = pusher(root);
    root.__listen = { id: id, open: false, events: [], skipped: 0 };
    if (ask.error || !push) root.__listen.error = ask.error || window.BarkparkDeskVisionTree.word(root, "listen-closed");
    else push("vision-listen-start", Object.assign({ id: id }, ask));
    button(root);
    draw(root);
  };

  /** Stop listening: the server ends its subscription, and the Result is empty again. */
  var stop = function (root) {
    var was = live(root);
    var push = pusher(root);
    root.__listen = null;
    if (was && push) push("vision-listen-stop", {});
    button(root);
    if (was) draw(root);
  };

  // One message of the server's (Desk.VisionListen), for the Listen it names.
  var heard = function (root, m) {
    var l = root.__listen;
    if (!l || l.error || !m || m.id !== l.id) return;
    if (m.kind === "open") l.open = true;
    else if (m.kind === "mutation") (l.open = true), (l.events = [m.event].concat(l.events).slice(0, KEEP));
    else if (m.kind === "skipped") l.skipped += m.count || 0;
    else if (m.kind === "error") l.error = m.message || window.BarkparkDeskVisionTree.word(root, "listen-closed");
    else l.error = window.BarkparkDeskVisionTree.word(root, "listen-closed");
    button(root);
    draw(root);
  };

  window.addEventListener("phx:desk-vision-listen", function (e) {
    document.querySelectorAll("[data-desk-vision]").forEach(function (root) {
      heard(root, e.detail);
    });
  });

  // The socket dropped: its Listen ended with the LiveView it ran in, so the listener
  // closed, as TanStack says when its stream ends. Listen starts a new one.
  var dropped = function () {
    document.querySelectorAll("[data-desk-vision]").forEach(function (root) {
      if (live(root)) heard(root, { id: root.__listen.id, kind: "closed" });
    });
  };
  var watch = function () {
    var main = document.querySelector("[data-phx-main]");
    if (!main || main.__visionWatched || typeof MutationObserver !== "function") return;
    main.__visionWatched = true;
    new MutationObserver(function () {
      if (main.classList.contains("phx-disconnected") || main.classList.contains("phx-error")) dropped();
    }).observe(main, { attributes: true, attributeFilter: ["class"] });
  };
  watch();
  document.addEventListener("phx:page-loading-stop", watch);

  window.BarkparkDeskVisionListen = { KEEP: KEEP, start: start, stop: stop, live: live, button: button, heard: heard };
})();
