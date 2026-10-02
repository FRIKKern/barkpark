// Decorate the server's reader markup, never reproduce a renderer.
// The native editing hosts survive server paints while focused. Their changes
// enter the existing canvas history/save/conflict pipeline immediately.
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const scalar = value => typeof value === "string" || typeof value === "number";
// A field is a flat key of its item, or — when the painted run is a slice of one
// stored string (a file-tree line) — a read/write pair over the item. `verbatim`
// keeps leading/trailing whitespace the reader paints (white-space: pre).
const valueOf = (field, item) => field.read ? field.read(item) : item[field.key];

// `collection` names the block key holding the rows (default `items`; pipeline
// `nodes`, lineage `entries`, …); a field with `index: null` is a block-level key.
export function wirePaintedTextInline(body, { getBlock, isEditable, commit, undo, redo, collection = "items" }, describeFields) {
  let fields = new Map();
  let pendingHtml = null;
  let composing = false;
  let sourceBlock = null;
  const dirty = new Set();
  const allowed = () => isEditable() && !getBlock()?.locked && getBlock()?.query == null;
  const itemAt = (block, index) => index == null ? block : block?.[collection]?.[index];

  function decorate() {
    fields = new Map();
    if (!allowed()) return;
    for (const { el, item, index, key, label, read, write, verbatim } of describeFields(body, sourceBlock || getBlock())) {
      const value = read ? read(item) : item?.[key];
      if (!el || !object(item) || item.locked === true || item.query != null || !scalar(value)) continue;
      fields.set(el, { index, key, read, write, verbatim, original: value, shown: el.textContent });
      el.contentEditable = "plaintext-only";
      el.setAttribute("role", "textbox");
      el.setAttribute("aria-label", label);
      el.setAttribute("aria-multiline", "false");
      el.tabIndex = 0;
      el.style.cursor = "text";
    }
  }

  function refresh() {
    const block = getBlock();
    for (const [el, field] of fields) {
      const item = itemAt(block, field.index);
      const enabled = allowed() && object(item) && item.locked !== true && item.query == null;
      el.contentEditable = enabled ? "plaintext-only" : "false";
      el.tabIndex = enabled ? 0 : -1;
      if (!item || (composing && document.activeElement === el)) continue;
      const value = valueOf(field, item);
      const shown = value === field.original ? field.shown : scalar(value)
        ? (document.activeElement === el || field.verbatim ? String(value) : String(value).trim()) : "";
      if (el.textContent !== shown) el.textContent = shown;
    }
  }

  function paint(html, source) {
    if (fields.has(document.activeElement)) { pendingHtml = { html, source }; return; }
    sourceBlock = source || getBlock();
    body.innerHTML = html;
    decorate();
    refresh();
  }
  function onPaint(event) {
    event.preventDefault();
    const html = event.detail?.html;
    paint(typeof html === "string" && html.trim() ? html : '<div class="bp-canvas-readonly-chip">Nothing to show yet.</div>', event.detail?.sourceBlock);
  }
  function onInput(event) {
    const field = fields.get(event.target);
    if (field && event.type === "input") dirty.add(event.target);
    if (!field || !dirty.has(event.target) || composing || !allowed()) return;
    const block = getBlock();
    const item = itemAt(block, field.index);
    if (!object(item) || item.locked === true || item.query != null) return;
    const text = event.target.textContent || "";
    const value = text === field.shown ? field.original : text;
    dirty.delete(event.target);
    if (valueOf(field, item) === value) return;
    const updated = field.write ? field.write(item, value) : { ...item, [field.key]: value };
    commit(field.index == null ? updated : {
      ...block, [collection]: block[collection].map((row, index) => index === field.index ? updated : row),
    });
  }
  function onKey(event) {
    if (!fields.has(event.target) || event.isComposing) return;
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a") {
      // Chromium otherwise selects the outer contenteditable canvas, crossing
      // this native island and potentially replacing unrelated Paper blocks.
      event.preventDefault();
      event.stopPropagation();
      const range = document.createRange();
      range.selectNodeContents(event.target);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    else if (event.key === "Enter") { event.preventDefault(); event.target.blur(); }
    else if ((event.metaKey || event.ctrlKey) && !event.altKey && ["z", "y"].includes(event.key.toLowerCase())) {
      event.preventDefault();
      (event.shiftKey || event.key.toLowerCase() === "y" ? redo : undo)();
    }
  }
  function onBlur(event) {
    if (!fields.has(event.target)) return;
    composing = false;
    onInput(event);
    // Moving between native hosts must not detach the destination mid-click.
    if (fields.has(event.relatedTarget)) return;
    if (pendingHtml != null) {
      const { html, source } = pendingHtml;
      pendingHtml = null;
      paint(html, source);
    } else refresh();
  }
  const onStart = event => { if (fields.has(event.target)) composing = true; };
  const onEnd = event => { composing = false; onInput(event); };
  const onBeforeInput = event => {
    if (fields.has(event.target) && ["insertParagraph", "insertLineBreak"].includes(event.inputType)) event.preventDefault();
  };
  const events = { "bp-fleet-paint": onPaint, input: onInput, keydown: onKey,
    focusout: onBlur, compositionstart: onStart, compositionend: onEnd, beforeinput: onBeforeInput };
  for (const [type, listener] of Object.entries(events)) body.addEventListener(type, listener);
  return {
    refresh,
    flush: () => { if (!composing && fields.has(document.activeElement)) onInput({ target: document.activeElement }); },
    destroy: () => { for (const [type, listener] of Object.entries(events)) body.removeEventListener(type, listener); },
  };
}
