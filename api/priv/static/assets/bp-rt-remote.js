// bp-rt-remote — another editor's save of a rich text inside an object or an
// array row, put into this page's open editor in place (task-47be2cdf59d0acd5).
//
// The editor sits in a phx-update="ignore" wrapper ([data-pt-subfield] names
// its input), so a re-render never changes its text, and a remount would
// throw away typing not yet posted, the caret and an IME composition. The
// server (Handlers.RichTextRemote) pushes `bp:rt-remote`:
//
//   {values: {"doc[meta].rt": {seq, html}}}       a value to show: another
//                                                 editor's save, the merge of
//                                                 it with this page's post, or,
//                                                 on a clash, this page's
//                                                 block over theirs elsewhere
//   {values: {"doc[meta].rt": {seq, html, reload: true}}}
//                                                 the stored text after this
//                                                 page's own Reload or restore:
//                                                 shown at once
//
// A value goes in once this page is idle in that editor: no IME composition
// and no input for IDLE_MS (longer than the hidden input's 500 ms debounce,
// so the last keys have been posted). Focus does not hold it back: a caret
// that just sits there would hold it back for ever (#28349 r2 review, S7b).
// A focused editor keeps its caret in a block whose text did not change. It
// goes in through the editor's own first-paint path (`value` -> `_paint`),
// never as raw HTML of its own. Until then it waits, and the idle timer
// tries again.
//
// Each editor reports the number of the last value it shows, in a hidden
// `_bp_rt_seen[]` input inside its wrapper (`name|number`): the newest
// number this page was pushed, or, while a value waits, one less than it.
// The server reads a post against the value its number names: a post typed
// before this page showed a value is merged with it, or held, never written
// over it, and that holds for a commit of a composition begun earlier too.
// A page without this file reports nothing, and its posts are read as
// before.

(() => {
  if (window.__bpRtRemote) return;
  window.__bpRtRemote = true;

  const IDLE_MS = 800;
  const WRAP = "[data-pt-subfield]";

  // The newest number any push carried.
  let last = 0;
  // name -> {seq, html}: theirs, not shown yet.
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

  const busy = (editor) =>
    composing.has(editor) || Date.now() - (typedAt.get(editor) || 0) < IDLE_MS;

  // The caret as its top-level block's index, text and offset in that text;
  // a custom block also by its key.
  const caretIn = (body) => {
    const sel = window.getSelection();
    if (!body || !sel || !sel.rangeCount || !body.contains(sel.anchorNode)) return null;
    const r = sel.getRangeAt(0);
    let block = r.startContainer;
    while (block && block.parentNode !== body) block = block.parentNode;
    if (!block) return null;
    const before = document.createRange();
    before.selectNodeContents(block);
    before.setEnd(r.startContainer, r.startOffset);
    return {
      i: [...body.children].indexOf(block),
      key: block.getAttribute && block.getAttribute("data-pt-block"),
      text: block.textContent,
      at: before.toString().length,
    };
  };

  // Where the caret goes in a block whose text theirs changed, as TanStack's
  // editor carries its selection through another editor's text patch: after
  // the same characters it was after. A change before it moves it by the
  // change's length, one after it leaves it; inside the changed part it goes
  // after what replaced it (#28349 r3 review, K2).
  const mapOffset = (old, now, at) => {
    const max = Math.min(old.length, now.length);
    let p = 0;
    while (p < max && old[p] === now[p]) p++;
    let s = 0;
    while (s < max - p && old[old.length - 1 - s] === now[now.length - 1 - s]) s++;
    if (at <= p) return at;
    if (at >= old.length - s) return now.length - (old.length - at);
    return now.length - s;
  };

  // The block of the same key, else of the same text nearest where it was
  // (a paragraph theirs added above moves it down): the caret goes back to
  // its offset. Its text changed: the caret goes to the same place in the
  // block now at its place (`mapOffset`).
  const caretBack = (body, c) => {
    const blocks = [...body.children];
    if (!blocks.length) return;
    let block = c.key ? blocks.find((b) => b.getAttribute("data-pt-block") === c.key) : null;
    for (let d = 0; !block && d < blocks.length; d++) {
      block = [blocks[c.i + d], blocks[c.i - d]].find((b) => b && b.textContent === c.text);
    }
    let at = c.at;
    if (!block || block.textContent !== c.text) {
      block = blocks[Math.min(Math.max(c.i, 0), blocks.length - 1)];
      at = mapOffset(c.text, block.textContent, c.at);
    }
    const walk = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    let node = block, off = 0, t;
    while ((t = walk.nextNode())) {
      node = t;
      off = Math.min(at, t.length);
      if (at <= t.length) break;
      at -= t.length;
    }
    const r = document.createRange();
    r.setStart(node, off);
    r.collapse(true);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
  };

  // Through the editor's first-paint path, and into the hidden input the
  // form posts, so a later post of another field carries what is shown.
  const show = (w, editor, html) => {
    const body = editor.querySelector(".bp-rte-body");
    const caret = caretIn(body);
    editor.value = html;
    if (caret && body) caretBack(body, caret);
    const id = editor.dataset.bridgeTarget;
    const input = id ? document.getElementById(id) : null;
    if (input) input.value = editor.value;
  };

  const tryShow = (name) => {
    const theirs = waiting.get(name);
    if (!theirs) return;
    const w = wrapOf(name);
    const editor = editorIn(w);
    // Not on the page: a later draw shows the server's value.
    if (!editor) {
      waiting.delete(name);
      return;
    }
    if (!theirs.reload && busy(editor)) return;
    show(w, editor, theirs.html);
    waiting.delete(name);
    mark(w);
  };

  const tick = () => {
    timer = null;
    for (const name of [...waiting.keys()]) tryShow(name);
    if (waiting.size) timer = setTimeout(tick, IDLE_MS);
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
      if (typeof v.html === "string") {
        const theirs = waiting.get(name);
        if (!theirs || theirs.seq < v.seq) waiting.set(name, {seq: v.seq, html: v.html, reload: !!v.reload});
        tryShow(name);
      }
      mark(w);
    }
    markAll();
    later();
  };

  window.addEventListener("phx:bp:rt-remote", onRemote);

  const editorOf = (e) => (e.target && e.target.closest ? e.target.closest("bp-rich-text-editor") : null);

  // An input that is not part of a composition ends one: a commit does not
  // always fire compositionend (Chrome's Input.insertText over a composition).
  document.addEventListener("input", (e) => {
    const editor = editorOf(e);
    if (!editor) return;
    typedAt.set(editor, Date.now());
    if (!e.isComposing) composing.delete(editor);
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
