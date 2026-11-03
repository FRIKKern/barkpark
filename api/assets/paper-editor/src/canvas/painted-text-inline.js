// Decorate the server's reader markup, never reproduce a renderer.
// The native editing hosts survive server paints while focused. Their changes
// enter the existing canvas history/save/conflict pipeline immediately.
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const scalar = value => typeof value === "string" || typeof value === "number";
// A field is a flat key of its item, or — when the painted run is a slice of one
// stored string (a file-tree line) — a read/write pair over the item. `verbatim`
// keeps leading/trailing whitespace the reader paints (white-space: pre).
const valueOf = (field, item) => field.read ? field.read(item) : item[field.key];
const testId = label => `paper-inline-${String(label).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "")}`;
const domValue = field => {
  const raw = field.textNode ? field.textNode.nodeValue || "" : field.el.textContent || "";
  return field.domPrefix && raw.startsWith(field.domPrefix) ? raw.slice(field.domPrefix.length) : raw;
};
const setDomValue = (field, value) => {
  const shown = String(value);
  if (field.textNode) {
    const next = (field.domPrefix || "") + shown;
    if (field.textNode.nodeValue !== next) field.textNode.nodeValue = next;
  } else if (field.el.textContent !== shown) field.el.textContent = shown;
};
const selectedTextRange = field => {
  if (!field.textNode) return null;
  const selection = window.getSelection();
  if (!selection || selection.rangeCount !== 1) return null;
  const range = selection.getRangeAt(0);
  if (range.startContainer !== field.textNode || range.endContainer !== field.textNode) return null;
  const start = field.domPrefix?.length || 0;
  if (range.startOffset < start || range.endOffset > field.textNode.length) return null;
  return range;
};
const placeTextCaret = field => {
  const range = document.createRange();
  range.setStart(field.textNode, field.textNode.length);
  range.collapse(true);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  return range;
};
const hideEditorSemantics = el => {
  el.removeAttribute("role");
  el.removeAttribute("aria-label");
  el.removeAttribute("aria-multiline");
};

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
    for (const { el, item, index, key, label, read, write, verbatim, textNode, domPrefix } of describeFields(body, sourceBlock || getBlock())) {
      const value = read ? read(item) : item?.[key];
      if (!el || !object(item) || item.locked === true || item.query != null || !scalar(value)) continue;
      if (textNode && (textNode.nodeType !== 3 || textNode.parentNode !== el)) continue;
      const field = { el, index, key, label, read, write, verbatim, textNode, domPrefix, original: value };
      field.shown = domValue(field);
      fields.set(el, field);
      el.contentEditable = "plaintext-only";
      el.setAttribute("data-test-id", testId(label));
      el.tabIndex = 0;
    }
    // A reader run may hold an authored bare text node beside real reader
    // children (unit, delta, swatch, lead). Keep those children outside this
    // field unless they are independently wired fields of their own.
    for (const field of fields.values()) {
      if (!field.textNode) continue;
      for (const child of field.el.children) {
        if (!fields.has(child)) child.contentEditable = "false";
      }
    }
  }

  function refresh() {
    const block = getBlock();
    for (const [el, field] of fields) {
      const item = itemAt(block, field.index);
      const enabled = allowed() && object(item) && item.locked !== true && item.query == null;
      el.contentEditable = enabled ? "plaintext-only" : "false";
      el.tabIndex = enabled ? 0 : -1;
      if (!enabled) hideEditorSemantics(el);
      if (!item || (composing && document.activeElement === el)) continue;
      const value = valueOf(field, item);
      const shown = value === field.original ? field.shown : scalar(value)
        ? (document.activeElement === el || field.verbatim ? String(value) : String(value).trim()) : "";
      setDomValue(field, shown);
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
    const text = domValue(field);
    const value = text === field.shown ? field.original : text;
    dirty.delete(event.target);
    if (valueOf(field, item) === value) return;
    const updated = field.write ? field.write(item, value) : { ...item, [field.key]: value };
    commit(field.index == null ? updated : {
      ...block, [collection]: block[collection].map((row, index) => index === field.index ? updated : row),
    });
  }
  function onKey(event) {
    const field = fields.get(event.target);
    if (!field || event.isComposing) return;
    if (field.textNode && ["Backspace", "Delete"].includes(event.key)) {
      const range = selectedTextRange(field);
      const start = field.domPrefix?.length || 0;
      if (!range || (range.collapsed && ((event.key === "Backspace" && range.startOffset === start) ||
        (event.key === "Delete" && range.endOffset === field.textNode.length)))) {
        event.preventDefault();
        return;
      }
    }
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a") {
      // Chromium otherwise selects the outer contenteditable canvas, crossing
      // this native island and potentially replacing unrelated Paper blocks.
      event.preventDefault();
      event.stopPropagation();
      const range = document.createRange();
      range.selectNodeContents(field.textNode || event.target);
      if (field.textNode && field.domPrefix) range.setStart(field.textNode, field.domPrefix.length);
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
    hideEditorSemantics(event.target);
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
  function onFocus(event) {
    const field = fields.get(event.target);
    if (!field || event.target.contentEditable !== "plaintext-only") return;
    event.target.setAttribute("role", "textbox");
    event.target.setAttribute("aria-label", field.label);
    event.target.setAttribute("aria-multiline", "false");
  }
  const onStart = event => { if (fields.has(event.target)) composing = true; };
  const onEnd = event => { composing = false; onInput(event); };
  const onBeforeInput = event => {
    const field = fields.get(event.target);
    if (!field) return;
    if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) {
      event.preventDefault();
      return;
    }
    if (field.textNode && event.inputType && !selectedTextRange(field)) {
      if (event.inputType.startsWith("insert") && document.activeElement === event.target) placeTextCaret(field);
      else event.preventDefault();
    }
  };
  const events = { "bp-fleet-paint": onPaint, input: onInput, keydown: onKey, focusin: onFocus,
    focusout: onBlur, compositionstart: onStart, compositionend: onEnd, beforeinput: onBeforeInput };
  for (const [type, listener] of Object.entries(events)) body.addEventListener(type, listener);
  return {
    refresh,
    flush: () => { if (!composing && fields.has(document.activeElement)) onInput({ target: document.activeElement }); },
    destroy: () => { for (const [type, listener] of Object.entries(events)) body.removeEventListener(type, listener); },
  };
}
