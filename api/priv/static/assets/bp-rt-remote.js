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
// number this page was pushed, or, while values wait, one less than the
// first of them. A newer value replaces the one waiting, but the editor
// still shows what it showed before the first: with one less than the
// newest, a post was read against a value it never showed, and B's change
// before it was taken out with no word (task-2833650e2e72d380). A new
// socket's stored value (`born`, task-eeda66fac5af065f) waits with the
// number this page had before it, is seen at once when the editor already
// shows it, and is never drawn over words typed since the last draw. The merge
// of this page's own post (`own`) starts again from itself: the editor
// shows that post, which the server merged with all that waited before.
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
  // name -> {seq, html, seen, born}: theirs, not shown yet; `seen`, the
  // number the editor's text is read from (see above).
  const waiting = new Map();
  // editor -> time of its last input, and of its last draw from here.
  const typedAt = new WeakMap();
  const shownAt = new WeakMap();
  const composing = new WeakSet();
  let timer = null;

  const wrapOf = (name) => {
    for (const w of document.querySelectorAll(WRAP)) if (w.dataset.ptSubfield === name) return w;
    return null;
  };
  const editorIn = (w) => (w ? w.querySelector("bp-rich-text-editor") : null);

  const seenOf = (name) => (waiting.has(name) ? waiting.get(name).seen : last);

  // Typed since this page last drew a value into it: words that may not be
  // posted yet (a socket that went takes them with it).
  const typedSince = (editor) => (typedAt.get(editor) || 0) > (shownAt.get(editor) || 0);

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

  // A point of the selection as its top-level block's index, text and
  // offset in that text; a custom block also by its key.
  const pointIn = (body, node, offset) => {
    let block = node;
    while (block && block.parentNode !== body) block = block.parentNode;
    if (!block) return null;
    const before = document.createRange();
    before.selectNodeContents(block);
    before.setEnd(node, offset);
    return {
      i: [...body.children].indexOf(block),
      key: block.getAttribute && block.getAttribute("data-pt-block"),
      text: block.textContent,
      at: before.toString().length,
    };
  };

  // The selection's anchor and focus, so a selected word stays selected,
  // in its direction (task-cfd4254783206ad7).
  const caretIn = (body) => {
    const sel = window.getSelection();
    if (!body || !sel || !sel.rangeCount || !body.contains(sel.anchorNode)) return null;
    if (!body.contains(sel.focusNode)) return null;
    const anchor = pointIn(body, sel.anchorNode, sel.anchorOffset);
    const focus = sel.isCollapsed ? anchor : pointIn(body, sel.focusNode, sel.focusOffset);
    return anchor && focus ? {anchor, focus} : null;
  };

  // How well a change's edge between characters a and b sits on a boundary,
  // as diff-match-patch's cleanupSemanticLossless scores it: the text's
  // start or end, a line break, a sentence end, a space, punctuation.
  const WORD = /[\p{L}\p{N}]/u;
  const edge = (a, b) => {
    if (a === undefined || b === undefined) return 6;
    const [na, nb] = [!WORD.test(a), !WORD.test(b)];
    const [wa, wb] = [na && /\s/.test(a), nb && /\s/.test(b)];
    if ((wa && /[\r\n]/.test(a)) || (wb && /[\r\n]/.test(b))) return 4;
    if (na && !wa && wb) return 3;
    if (wa || wb) return 2;
    if (na || nb) return 1;
    return 0;
  };

  // An insert or a delete of k characters at l in `text` can sit anywhere
  // the same characters repeat around it: "say hello" to "say hi hello" is
  // "i h" after "say h" as much as "hi " after "say ". It moves to the place
  // whose edges are the best boundaries, the later one on a tie, so the
  // change is their whole word and the caret is not inside it (#28716
  // review).
  const slide = (text, l, k) => {
    while (l > 0 && text[l - 1] === text[l + k - 1]) l--;
    let best = l, score = -1;
    for (;; l++) {
      const here = edge(text[l - 1], text[l]) + edge(text[l + k - 1], text[l + k]);
      if (here >= score) [best, score] = [l, here];
      if (l + k >= text.length || text[l] !== text[l + k]) break;
    }
    return best;
  };

  // Where the caret goes in a block whose text theirs changed, as TanStack's
  // editor carries its selection through another editor's text patch: after
  // the same characters it was after. A change before it moves it by the
  // change's length, one after it leaves it; inside the changed part it goes
  // after what replaced it (#28349 r3 review, K2). An insert or a delete is
  // first moved to word boundaries (`slide`).
  const mapOffset = (old, now, at) => {
    const max = Math.min(old.length, now.length);
    let p = 0;
    while (p < max && old[p] === now[p]) p++;
    let s = 0;
    while (s < max - p && old[old.length - 1 - s] === now[now.length - 1 - s]) s++;
    const [gone, added] = [old.length - s - p, now.length - s - p];
    if (!gone && added) p = slide(now, p, added);
    else if (gone && !added) p = slide(old, p, gone);
    if (at <= p) return at;
    if (at >= p + gone) return at + added - gone;
    return p + added;
  };

  // The block of the same key, else of the same text nearest where it was
  // (a paragraph theirs added above moves it down): the point goes back to
  // its offset. Its text changed: the point goes to the same place in the
  // block now at its place (`mapOffset`). The DOM node and offset.
  const placeOf = (body, blocks, c) => {
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
    return [node, off];
  };

  const caretBack = (body, c) => {
    const blocks = [...body.children];
    if (!blocks.length) return;
    const anchor = placeOf(body, blocks, c.anchor);
    const focus = c.focus === c.anchor ? anchor : placeOf(body, blocks, c.focus);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.setBaseAndExtent(anchor[0], anchor[1], focus[0], focus[1]);
  };

  // Through the editor's first-paint path, and into the hidden input the
  // form posts, so a later post of another field carries what is shown.
  const show = (w, editor, html) => {
    const body = editor.querySelector(".bp-rte-body");
    const caret = caretIn(body);
    editor.value = html;
    shownAt.set(editor, Date.now());
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
    // A new socket's stored value (`born`) is never drawn over words typed
    // since the last draw: A's next post is held against it instead
    // (task-eeda66fac5af065f).
    if (theirs.born && typedSince(editor)) return;
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
    // Another document is shown: what waits is the old one's (task-29686209fb9fc5dc).
    if (e.detail && e.detail.forget) waiting.clear();
    const values = (e.detail && e.detail.values) || {};
    // A new socket's stored value is read from what this page had before it.
    const before = last;
    for (const [name, v] of Object.entries(values)) {
      if (!v || typeof v.seq !== "number") continue;
      last = Math.max(last, v.seq);
      const w = wrapOf(name);
      const editor = editorIn(w);
      if (typeof v.html === "string") {
        const theirs = waiting.get(name);
        // What the editor shows already: seen, with nothing to draw.
        const shows = editor && (editor.value === v.html ||
          (v.born && !typedSince(editor) && editor.getAttribute("value") === v.html));
        if (shows && (!theirs || theirs.seq < v.seq)) {
          waiting.delete(name);
        } else if (!theirs || theirs.seq < v.seq) {
          const seen = theirs && !v.own ? theirs.seen : v.born ? before : v.seq - 1;
          waiting.set(name, {seq: v.seq, html: v.html, reload: !!v.reload, seen, born: !!v.born});
        }
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
