// bp-rt-remote — another editor's save of a rich text inside an object or an
// array row, put into this page's open editor in place (task-47be2cdf59d0acd5).
//
// The editor sits in a phx-update="ignore" wrapper ([data-pt-subfield] names
// its input), so a re-render never changes its text, and a remount would
// throw away typing not yet posted, the caret and an IME composition. The
// server (Handlers.RichTextRemote) pushes `bp:rt-remote`:
//
//   {values: {"doc[meta].rt": {seq, html}}}       theirs, to show
//   {values: {"doc[meta].rt": {seq, big: true}}}  theirs, too big to send
//   {values: {"doc[meta].rt": {seq, own: true, html?}}}
//                                                 the server held this page's
//                                                 post over theirs: its text is
//                                                 now the base of the next one
//
// Theirs goes in only while the editor is free: no focus inside its wrapper,
// no IME composition, and no input for IDLE_MS (longer than the hidden
// input's 500 ms debounce, so the last keys have been posted). It goes in
// through the editor's own first-paint path (`value` -> `_paint`), never as
// raw HTML of its own. Until then it waits, and a blur or the idle timer
// tries again.
//
// Each editor reports the number of the last value it shows, in a hidden
// `_bp_rt_seen[]` input inside its wrapper (`name|number`): the newest
// number this page was pushed, or, while theirs waits, one less than
// theirs. A post typed over theirs then carries an older number, and the
// server holds it instead of writing it over theirs: also when theirs is
// still on its way, since this page reports the numbers it has, 0 before
// any. A page without this file reports nothing, and its posts are read as
// before.

(() => {
  if (window.__bpRtRemote) return;
  window.__bpRtRemote = true;

  const IDLE_MS = 800;
  const WRAP = "[data-pt-subfield]";

  // The newest number any push carried.
  let last = 0;
  // name -> {seq, html}: theirs, not shown yet. html is null when too big.
  const waiting = new Map();
  // editor -> time of its last input.
  const typedAt = new WeakMap();
  const composing = new WeakSet();
  let timer = null;

  const wrapOf = (name) => {
    for (const w of document.querySelectorAll(WRAP)) if (w.dataset.ptSubfield === name) return w;
    return null;
  };
  const editorIn = (w) => (w ? w.querySelector("bp-rich-text-editor") : null);

  const seenOf = (name) => (waiting.has(name) ? waiting.get(name).seq - 1 : last);

  // The wrapper's `_bp_rt_seen[]`, made on first need. The wrapper is
  // ignored by LiveView's patch, so the input stays.
  const mark = (w) => {
    if (!w) return;
    let input = w.querySelector("input[data-bp-rt-seen]");
    if (!input) {
      input = document.createElement("input");
      input.type = "hidden";
      input.name = "_bp_rt_seen[]";
      input.setAttribute("data-bp-rt-seen", "");
      w.appendChild(input);
    }
    input.value = w.dataset.ptSubfield + "|" + seenOf(w.dataset.ptSubfield);
  };

  const markAll = () => {
    for (const input of document.querySelectorAll("input[data-bp-rt-seen]")) mark(input.closest(WRAP));
  };

  const busy = (w, editor) =>
    w.contains(document.activeElement) ||
    composing.has(editor) ||
    Date.now() - (typedAt.get(editor) || 0) < IDLE_MS;

  // Through the editor's first-paint path, and into the hidden input the
  // form posts, so a later post of another field carries what is shown.
  const show = (w, editor, html) => {
    editor.value = html;
    const id = editor.dataset.bridgeTarget;
    const input = id ? document.getElementById(id) : null;
    if (input) input.value = editor.value;
  };

  const tryShow = (name) => {
    const theirs = waiting.get(name);
    if (!theirs || theirs.html == null) return;
    const w = wrapOf(name);
    const editor = editorIn(w);
    // Not on the page: a later draw shows the server's value.
    if (!editor) {
      waiting.delete(name);
      return;
    }
    if (busy(w, editor)) return;
    show(w, editor, theirs.html);
    waiting.delete(name);
    mark(w);
  };

  const tick = () => {
    timer = null;
    for (const name of [...waiting.keys()]) tryShow(name);
    if ([...waiting.values()].some((t) => t.html != null)) timer = setTimeout(tick, IDLE_MS);
  };

  const later = () => {
    if (!timer) timer = setTimeout(tick, IDLE_MS);
  };

  const onRemote = (e) => {
    const values = (e.detail && e.detail.values) || {};
    for (const [name, v] of Object.entries(values)) {
      if (!v || typeof v.seq !== "number") continue;
      last = Math.max(last, v.seq);
      const w = wrapOf(name);
      if (v.own) {
        // This page's text, held over theirs: nothing of theirs waits any
        // more, and the text comes back if theirs was shown meanwhile.
        const theirs = waiting.get(name);
        if (theirs && theirs.seq < v.seq) waiting.delete(name);
        const editor = editorIn(w);
        if (editor && typeof v.html === "string" && !busy(w, editor)) show(w, editor, v.html);
      } else {
        waiting.set(name, {seq: v.seq, html: typeof v.html === "string" ? v.html : null});
        tryShow(name);
      }
      mark(w);
    }
    markAll();
    later();
  };

  window.addEventListener("phx:bp:rt-remote", onRemote);

  const editorOf = (e) => (e.target && e.target.closest ? e.target.closest("bp-rich-text-editor") : null);

  document.addEventListener("input", (e) => {
    const editor = editorOf(e);
    if (editor) typedAt.set(editor, Date.now());
  }, true);

  // Before the bridge copies the text into the hidden input and the form
  // posts it, the wrapper says what this editor shows.
  document.addEventListener("bp-change", (e) => {
    const w = e.target && e.target.closest ? e.target.closest(WRAP) : null;
    if (w) mark(w);
  }, true);

  document.addEventListener("compositionstart", (e) => {
    const editor = editorOf(e);
    if (editor) composing.add(editor);
  }, true);

  document.addEventListener("compositionend", (e) => {
    const editor = editorOf(e);
    if (!editor) return;
    composing.delete(editor);
    typedAt.set(editor, Date.now());
    later();
  }, true);

  document.addEventListener("focusout", (e) => {
    if (e.target && e.target.closest && e.target.closest(WRAP) && waiting.size) later();
  }, true);
})();
