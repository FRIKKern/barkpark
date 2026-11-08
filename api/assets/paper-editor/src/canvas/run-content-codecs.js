import { inlineArrayToTiptap, tiptapInlineToPd } from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import { CANVAS_CARD_NODE_NAME, isPlainObject } from "./run-kinds.js";

// ── callout ⇄ canvas content node (S3.2) ────────────────────────────────────
//
// convert.js has NO callout path (it only round-trips paragraph|heading|list), so
// the callout block ⇄ TipTap-node mapping lives HERE, mirroring how blockToTiptap
// /tiptapToBlock handle inline — REUSING convert.js's exported inlineArrayToTiptap
// /tiptapInlineToPd verbatim for the body (the body IS inline runs; do not
// reinvent inline serialization).
//
// The chrome rides node.attrs:
//   tone        — string, defaults "info" (compose.ex:157 `tone || "info"`)
//   title       — optional; ABSENT (null) round-trips as no `title` field
//   collapsible — boolean; ABSENT (false) → no `collapsible` field
//   collapsed   — boolean; ABSENT (false) → no `collapsed` field
// Omitting absent chrome fields is the byte-fidelity contract: compose.ex
// maybe_put / maybe_put_true only thread these when present, so a callout that
// never had a title must round-trip WITHOUT a title key (not title:"").

// calloutBodyInline(block) → the callout body's inline array (STEP 3 slot model).
//
// The `body` slot is the source of truth: when the block carries a materialized
// `slots.body` (a list whose lone element is a paragraph), read that paragraph's
// `content`; otherwise fall back to the legacy `content` array. Both encodings of
// the SAME body yield the SAME inline array, so a slot-form and a content-form
// callout project to an IDENTICAL node — which is what keeps zero-op-on-load true
// (stableCalloutKey keys on node.content, so a legacy-loaded callout and its
// re-projection compare EQUAL). Mirrors Elixir Slots.callout_body_inline/1.
function calloutBodyInline(block) {
  const slotBody = block && block.slots && block.slots.body;
  if (Array.isArray(slotBody) && slotBody.length) {
    const first = slotBody[0];
    return (first && first.content) || [];
  }
  return (block && block.content) || [];
}

// calloutBlockToNode(block) → { type:"callout", attrs:{…}, content:[inline…] }
//
// The body inline array (calloutBodyInline: slots.body[0].content else content) →
// TipTap inline nodes via the shared serializer. Chrome fields → attrs (only the
// present ones; tone always present with its "info" default so a tone swap is
// always diffable). title/collapsible/collapsed stay WIDGET attrs OUTSIDE the slot.
function calloutBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    tone: (block && block.tone) || "info",
  };
  // Only carry title/collapsible/collapsed when PRESENT in the source block, so
  // an untouched callout's getJSON re-projection matches and emits zero ops.
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.collapsible === true) attrs.collapsible = true;
  if (block && block.collapsed === true) attrs.collapsed = true;

  const node = { type: bpType || "callout", attrs };
  const inline = inlineArrayToTiptap(calloutBodyInline(block));
  if (inline.length) node.content = inline;
  return node;
}

// calloutNodeToBlock(node, id) → { id, type:"callout", tone, title?, collapsible?,
//   collapsed?, content:[inline…] }
//
// Reconstruct the portable-doc callout block from a callout NODE (the inverse of
// calloutBlockToNode). Body inline ← tiptapInlineToPd (the shared deserializer).
// Chrome fields read off node.attrs, threaded ONLY when present/true so the
// reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray title:"" / collapsible:false).
function calloutNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "callout",
    tone: attrs.tone || "info",
    content: tiptapInlineToPd((node && node.content) || []),
  };
  if (attrs.title != null) block.title = attrs.title;
  if (attrs.collapsible === true) block.collapsible = true;
  if (attrs.collapsed === true) block.collapsed = true;
  return block;
}

// The mutable-fields PATCH for a callout (the analogue of buildPatchBlockOp's
// patch map for prose). It is calloutNodeToBlock MINUS id/type — patch.ex re-pins
// those (the same contract tiptapToBlock follows).
//
// CRITICAL: the patch emits the chrome fields (title/collapsible/collapsed)
// EXPLICITLY even when false/null. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) that can REPLACE or PRESERVE a key but never DELETE one — so
// OMITTING a now-false/null field would leave the STALE old value, silently
// reverting an EXPAND (collapsed true→false via the fold button), a TITLE-CLEAR
// (set→null), or a collapsible-off on persist/reload. An explicit collapsible/
// collapsed:false round-trips byte-identically (compose.ex), and title:null is
// dropped by compose maybe_put. The INSERT path (calloutNodeToBlock) correctly
// OMITS absent fields — only the patch is explicit, so removals actually land.
//
// With the node the edit started from (prevNode), a field rides the patch only when
// its value CHANGED: a body edit must not materialize `collapsible:false` /
// `collapsed:false` / `title:null` keys the author never wrote (task-56bafb69a8a1f250).
// A changed field is still explicit, so an expand, a title clear or a collapsible-off
// still lands. Without prevNode every field rides, as before.
function calloutNodeToPatch(node, prevNode = null) {
  const block = calloutNodeToBlock(node, null);
  const attrs = (node && node.attrs) || {};
  const full = {
    tone: block.tone,
    content: block.content,
    title: attrs.title == null ? null : attrs.title,
    collapsible: attrs.collapsible === true,
    collapsed: attrs.collapsed === true,
  };
  if (!prevNode) return full;
  const prevAttrs = prevNode.attrs || {};
  const before = {
    tone: prevAttrs.tone || "info",
    content: canonicalJSON(prevNode.content || null),
    title: prevAttrs.title == null ? null : prevAttrs.title,
    collapsible: prevAttrs.collapsible === true,
    collapsed: prevAttrs.collapsed === true,
  };
  const after = {
    tone: attrs.tone || "info",
    content: canonicalJSON(node.content || null),
    title: full.title,
    collapsible: full.collapsible,
    collapsed: full.collapsed,
  };
  const patch = {};
  for (const key of Object.keys(full)) {
    if (before[key] !== after[key]) patch[key] = full[key];
  }
  return patch;
}

// True when a callout node's body OR chrome changed (an interior edit). We
// compare the canonical (key-order-insensitive) projection of the diff-relevant
// fields — tone, title, collapsible, collapsed, content — so a tone swap, title
// edit, fold toggle, or body edit flips it, but a pure reorder (bpId/bpType only)
// does not. Uses the SAME canonicalJSON the prose path uses, so a node serialized
// by calloutBlockToNode and the SAME node from the live editor's getJSON compare
// EQUAL despite differing attr/text key order.
function calloutNodeChanged(prevNode, nextNode) {
  return stableCalloutKey(prevNode) !== stableCalloutKey(nextNode);
}

function stableCalloutKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    tone: a.tone || "info",
    title: a.title == null ? null : a.title,
    collapsible: a.collapsible === true,
    collapsed: a.collapsed === true,
    content: node.content || null,
  });
}

// ── note ⇄ canvas content node ──────────────────────────────────────────────
// The reader displays plain strings, but persistence retains the original carrier.
// A single terminal may be edited through any number of wrappers without discarding
// their metadata. Multi-run/opaque carriers use the existing read-only atom route.
function noteScalarText(value) {
  if (typeof value === "string") return value;
  return Number.isInteger(value) ? String(value) : "";
}

// Mirror Blocks.note_no_rich_shadow?: only absent/null/empty alternate
// carriers are harmless. Keep their original keys and values when editing.
function noteNoRichShadow(value, fields) {
  return fields.every(key => !Object.hasOwn(value, key) || value[key] === null ||
    value[key] === "" || (Array.isArray(value[key]) && value[key].length === 0));
}

function noteInlineTerminal(value, path) {
  if (value == null || (Array.isArray(value) && value.length === 0))
    return { path, empty: true };
  if (!Array.isArray(value) || value.length !== 1) return null;
  const leaf = value[0];
  if (!leaf || typeof leaf !== "object" || Array.isArray(leaf)) return null;
  if (leaf.type === "text" || leaf.type === "code") {
    if (!noteNoRichShadow(leaf, ["children", "content", "text"])) return null;
    if (leaf.value != null && typeof leaf.value !== "string" && !Number.isInteger(leaf.value)) return null;
    return { path: [...path, 0, "value"] };
  }
  if (Array.isArray(leaf.children) && leaf.children.length === 1 &&
      noteNoRichShadow(leaf, ["content", "text", "value"]))
    return noteInlineTerminal(leaf.children, [...path, 0, "children"]);
  return null;
}

function noteFieldState(block, name, flatKey) {
  const slot = block.slots && block.slots[name];
  if (slot != null && (!Array.isArray(slot) || (slot.length === 0 && name !== "lead"))) return null;
  let text = noteScalarText(block[flatKey]);
  let terminal = { path: [flatKey], scalar: true };
  // Server authoring permits only the optional lead slot to be an empty array.
  // A populated paragraph's content wins even when it reads as empty.
  if (Array.isArray(slot) && slot.length) {
    const first = slot[0];
    if (!first || typeof first !== "object" || Array.isArray(first) || slot.length !== 1 || first.type !== "paragraph") return null;
    if (!noteNoRichShadow(first, ["children", "text", "value"])) return null;
    text = flattenInlineText(first.content);
    terminal = noteInlineTerminal(first.content, ["slots", name, 0, "content"]);
  } else if (block[flatKey] != null && typeof block[flatKey] !== "string" && !Number.isInteger(block[flatKey])) {
    return null;
  }
  if (!terminal) return null;
  if (name === "body" && Array.isArray(block.content) && block.content.length) {
    if (text === "") {
      text = flattenInlineText(block.content);
      terminal = noteInlineTerminal(block.content, ["content"]);
    } else if (flattenInlineText(block.content) !== "") {
      // Clearing the primary would resurrect this dormant fallback. Preserving
      // that unrelated carrier and promising an editable clear are incompatible.
      return null;
    }
  }
  if (name === "body" && block.content != null && !Array.isArray(block.content)) return null;
  return terminal && { text, ...terminal };
}

function noteState(block) {
  if (block.slots != null && !isPlainObject(block.slots)) return { label: null, lead: null, body: null };
  return {
    label: noteFieldState(block, "label", "label"),
    lead: noteFieldState(block, "lead", "lead"),
    body: noteFieldState(block, "body", "text"),
  };
}

// Flatten a portable-doc inline array to plain text, marks dropped — the JS twin of
// Elixir Slots.flatten_inline_text/1. A text / inline-code leaf contributes its
// `value`; a mark wrapper (strong/em/link/…) contributes its `children` flattened.
function flattenInlineText(arr) {
  if (typeof arr === "string") return arr;
  if (!Array.isArray(arr)) return "";
  return arr.map(flattenInlineNode).join("");
}
function flattenInlineNode(n) {
  if (typeof n === "string") return n;
  if (!n || typeof n !== "object") return "";
  if (n.type === "text" || n.type === "code")
    return noteScalarText(n.value);
  if (Array.isArray(n.children)) return flattenInlineText(n.children);
  return "";
}

// The plain-text body string of a note NODE — its inline content (via the shared
// deserializer) flattened to plain text (marks dropped), matching the reader's
// note_body_text plain contract. This is what the flat `text` field persists.
function noteNodeBodyText(node) {
  return flattenInlineText(tiptapInlineToPd((node && node.content) || []));
}

function noteBlockToNode(block, bpId, bpType) {
  const state = noteState(block);
  if (Object.values(state).some(field => !field)) {
    return { type: "bpOpaque", attrs: { bpId, bpType, bpBlock: deepClone(block) } };
  }
  const attrs = { bpId, bpType: bpType || "note", bpBlock: deepClone(block) };
  if (state.label.text !== "") attrs.label = state.label.text;
  if (state.lead.text !== "") attrs.lead = state.lead.text;
  const node = { type: bpType || "note", attrs };
  if (state.body.text !== "") node.content = [{ type: "text", text: state.body.text }];
  return node;
}

// Existing notes reconstruct from their complete source plus changed carriers.
// New slash-inserted notes have no source carrier and keep the flat wire form.
function noteNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  if (attrs.bpBlock) {
    return { ...deepClone(attrs.bpBlock), ...noteNodeToPatch(node, attrs.bpBlock), id, type: "note" };
  }
  const block = { id, type: "note" };
  if (attrs.label != null && attrs.label !== "") block.label = attrs.label;
  if (attrs.lead != null && attrs.lead !== "") block.lead = attrs.lead;
  block.text = noteNodeBodyText(node);
  return block;
}

// patch-block merges shallowly, so any slot edit sends the complete slots map.
// Only an already-equal binary flat twin follows a materialized edit. Absent,
// null, numeric and divergent shadows stay exactly as stored.
function noteNodeToPatch(node, original) {
  const block = original || (node.attrs && node.attrs.bpBlock);
  if (!block) return {};
  const state = noteState(block);
  if (Object.values(state).some(field => !field)) return {};
  const attrs = node.attrs || {};
  const values = { label: attrs.label || "", lead: attrs.lead || "", body: noteNodeBodyText(node) };
  const patch = {};
  for (const [name, value] of Object.entries(values)) {
    const carrier = state[name];
    if (value === carrier.text) continue;
    const flatKey = name === "body" ? "text" : name;
    const [root, ...rest] = carrier.path;
    if (!rest.length) {
      patch[root] = carrier.scalar && name !== "body" && value === "" ? null : value;
    } else {
      if (!(root in patch)) patch[root] = deepClone(block[root]);
      let target = patch[root];
      for (const key of rest.slice(0, -1)) target = target[key];
      target[rest[rest.length - 1]] = carrier.empty ? [{ type: "text", value }] : value;
    }
    if (root === "slots" && typeof block[flatKey] === "string" && block[flatKey] === carrier.text)
      patch[flatKey] = value;
  }
  return patch;
}

// True when a note node's body OR chrome (label/lead) changed — an interior edit.
// Canonical (key-order-insensitive) compare on the diff-relevant fields, so a body/
// label/lead edit flips it but a pure reorder (bpId/bpType only) does not. Keys on
// plain body text so mark-only or empty-content representation changes are no-ops.
function noteNodeChanged(prevNode, nextNode) {
  return stableNoteKey(prevNode) !== stableNoteKey(nextNode);
}

function stableNoteKey(node, includeCarrier = false) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    label: a.label == null || a.label === "" ? null : a.label,
    lead: a.lead == null || a.lead === "" ? null : a.lead,
    text: noteNodeBodyText(node),
    // Compare the effective edited source, not the original bpBlock: a genuine
    // own edit still matches, but equal text cannot hide external metadata.
    ...(includeCarrier ? { block: noteNodeToBlock(node, null) } : {}),
  });
}

// ── card ⇄ canvas content node (STEP 4) ──────────────────────────────────────
//
// The NEW slots-native `card` block ⇄ a bpCard node. Persisted shape (slots-native,
// no legacy inline encoding):
//   { id, type:"card", tone?, slots:{ title?:[{type:"heading",text}],
//     body:[{type:"paragraph",content:[<inline>…]}], media?:[<image>], action?:[<action>] } }
//
// The body slot becomes the ONE editable inline contentDOM (the callout precedent —
// a widget FLATTENS its body slot to inline); title/tone/media/action ride node.attrs.
//   tone   — string, PRESENT-ONLY (DIVERGES from callout's always-"info" default: a
//            tone-less card must NOT gain a tone on round-trip, or it emits a spurious
//            op; card_html treats absent tone as NO modifier, matching a legacy item).
//   title  — the title slot heading's `text`; PRESENT-ONLY (absent → no attr).
//   media  — the OPTIONAL media slot's lone element, carried VERBATIM on attrs.media.
//   action — the OPTIONAL action slot's lone element, carried VERBATIM on attrs.action.
// Omitting absent chrome is the byte-fidelity contract: cardNodeToBlock threads each
// field ONLY when present, so a card that never entered the canvas round-trips byte-
// identical.

// cardBodyInline(block) → the card body slot's inline array (slots.body[0].content).
// A card has NO legacy `content` encoding (it is slots-native), so an absent/empty
// body slot yields []. JS twin of Slots.card_body_text's SOURCE (the inline array
// before it is flattened to plain text server-side).
function cardBodyInline(block) {
  const slotBody = block && block.slots && block.slots.body;
  if (Array.isArray(slotBody) && slotBody.length) {
    const first = slotBody[0];
    return (first && first.content) || [];
  }
  return [];
}

// cardTitle(block) → the card title slot heading's `text`, or null when absent/empty.
// JS twin of Slots.card_title_text (present-only; "" and absent both → null so a
// title-less card round-trips WITHOUT a title attr).
function cardTitle(block) {
  const slotTitle = block && block.slots && block.slots.title;
  if (Array.isArray(slotTitle) && slotTitle.length) {
    const t = slotTitle[0] && slotTitle[0].text;
    return t == null || t === "" ? null : t;
  }
  return null;
}

// The lone element of a card's OPTIONAL media/action slot (verbatim), or null.
function cardMedia(block) {
  const s = block && block.slots && block.slots.media;
  return Array.isArray(s) && s.length && s[0] ? s[0] : null;
}
function cardAction(block) {
  const s = block && block.slots && block.slots.action;
  return Array.isArray(s) && s.length && s[0] ? s[0] : null;
}

function optionalCardText(element, key) {
  return !Object.prototype.hasOwnProperty.call(element, key) ||
    element[key] == null || typeof element[key] === "string";
}

function cardSlotSupported(slots, name, validate) {
  if (!Object.prototype.hasOwnProperty.call(slots, name) || slots[name] == null ||
      (Array.isArray(slots[name]) && slots[name].length === 0)) return true;
  return Array.isArray(slots[name]) && slots[name].length === 1 &&
    isPlainObject(slots[name][0]) && validate(slots[name][0]);
}

function cardBodyContentSupported(block, content) {
  try {
    if (canonicalJSON(tiptapInlineToPd(inlineArrayToTiptap(content))) ===
        canonicalJSON(content)) return true;
  } catch (_) {
    return false;
  }
  // The slash-menu's unsaved Card default intentionally uses the editor-wide
  // empty-text sentinel. It normalizes to [] when inserted; no persisted Card is
  // granted that lossy exception.
  return block.id == null && content.length === 1 &&
    canonicalJSON(content[0]) === canonicalJSON({ type: "text", value: "" });
}

// A malformed Card cannot be edited without normalizing or truncating authored
// data. Keep it on the established opaque/read-only path instead.
function cardBlockEditable(block) {
  if (!isPlainObject(block) || block.type !== "card") return false;
  if (!optionalCardText(block, "tone")) return false;
  if (block.slots == null) return true;
  if (!isPlainObject(block.slots)) return false;
  const slots = block.slots;
  return cardSlotSupported(slots, "title", (element) =>
    element.type === "heading" && optionalCardText(element, "text")) &&
    cardSlotSupported(slots, "body", (element) => {
      if (element.type !== "paragraph" ||
          !(element.content == null || Array.isArray(element.content))) return false;
      const content = element.content || [];
      return cardBodyContentSupported(block, content);
    }) &&
    cardSlotSupported(slots, "media", (element) =>
      (!Object.hasOwn(element, "type") || element.type === "image") &&
      optionalCardText(element, "src") && optionalCardText(element, "alt")) &&
    cardSlotSupported(slots, "action", (element) =>
      element.type === "action" && optionalCardText(element, "label") &&
      optionalCardText(element, "href") && optionalCardText(element, "priority"));
}

// cardBlockToNode(block) → { type:"bpCard", attrs:{…}, content:[inline…] }
// The body slot inline → TipTap inline nodes via the shared serializer (the callout
// body path). Chrome → attrs, PRESENT-ONLY (tone/title/media/action omitted when
// absent) so an untouched card's getJSON re-projection matches and emits zero ops.
function cardBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "card", bpBlock: deepClone(block) };
  const title = cardTitle(block);
  if (title != null) attrs.title = title;
  if (block && block.tone != null) attrs.tone = block.tone; // PRESENT-ONLY (no default)
  const media = cardMedia(block);
  if (media != null) attrs.media = deepClone(media);
  const action = cardAction(block);
  if (action != null) attrs.action = deepClone(action);

  const node = { type: CANVAS_CARD_NODE_NAME, attrs };
  const inline = inlineArrayToTiptap(cardBodyInline(block));
  if (inline.length) node.content = inline;
  return node;
}

// Overlay the live editable surfaces onto the exact authoritative slots map. Known
// singleton elements keep their IDs and opaque metadata; untouched absent/null/[]
// representations stay byte-exact.
function cardNodeSlotOverlay(node, sourceBlock) {
  const attrs = (node && node.attrs) || {};
  const sourceSlots = isPlainObject(sourceBlock && sourceBlock.slots)
    ? sourceBlock.slots
    : {};
  const slots = deepClone(sourceSlots);
  let changed = false;

  const sourceTitle = cardTitle(sourceBlock);
  const nextTitle = attrs.title == null || attrs.title === "" ? null : attrs.title;
  if (nextTitle !== sourceTitle) {
    changed = true;
    if (nextTitle != null) {
      const title = Array.isArray(sourceSlots.title) && sourceSlots.title.length === 1
        ? deepClone(sourceSlots.title[0])
        : { type: "heading" };
      slots.title = [{ ...title, text: nextTitle }];
    } else if (Array.isArray(sourceSlots.title) && sourceSlots.title.length === 1) {
      slots.title = [{ ...deepClone(sourceSlots.title[0]), text: "" }];
    }
  }

  const sourceContent = cardBodyInline(sourceBlock);
  const nextContent = tiptapInlineToPd((node && node.content) || []);
  if (canonicalJSON(nextContent) !== canonicalJSON(sourceContent)) {
    changed = true;
    const body = Array.isArray(sourceSlots.body) && sourceSlots.body.length === 1
      ? deepClone(sourceSlots.body[0])
      : { type: "paragraph" };
    slots.body = [{ ...body, content: nextContent }];
  }

  const sourceMedia = cardMedia(sourceBlock);
  if (canonicalJSON(attrs.media == null ? null : attrs.media) !==
      canonicalJSON(sourceMedia == null ? null : sourceMedia)) {
    changed = true;
    if (attrs.media != null) {
      const media = sourceMedia == null ? {} : deepClone(sourceMedia);
      slots.media = [{ ...media, ...deepClone(attrs.media) }];
    } else if (sourceMedia != null) {
      slots.media = [{ ...deepClone(sourceMedia), src: "" }];
    }
  }

  const sourceAction = cardAction(sourceBlock);
  if (canonicalJSON(attrs.action == null ? null : attrs.action) !==
      canonicalJSON(sourceAction == null ? null : sourceAction)) {
    changed = true;
    if (attrs.action != null) {
      const action = {
        ...(sourceAction == null ? {} : deepClone(sourceAction)),
        ...deepClone(attrs.action),
      };
      if (!Object.prototype.hasOwnProperty.call(attrs.action, "priority")) {
        delete action.priority;
      }
      slots.action = [action];
    } else if (sourceAction != null) {
      const action = { ...deepClone(sourceAction), label: "", href: "" };
      delete action.priority;
      slots.action = [action];
    }
  }
  return { slots, changed };
}

function cardNodeToSlots(node, sourceBlock) {
  if (sourceBlock) return cardNodeSlotOverlay(node, sourceBlock).slots;
  const attrs = (node && node.attrs) || {};
  const slots = {};
  if (attrs.title != null && attrs.title !== "") {
    slots.title = [{ type: "heading", text: attrs.title }];
  }
  slots.body = [{
    type: "paragraph",
    content: tiptapInlineToPd((node && node.content) || []),
  }];
  if (attrs.media != null) slots.media = [deepClone(attrs.media)];
  if (attrs.action != null) slots.action = [deepClone(attrs.action)];
  return slots;
}

// cardNodeToBlock(node, id) → { id, type:"card", slots:{…}, tone? }
// Reconstruct the portable-doc card block from a bpCard NODE (the inverse of
// cardBlockToNode). tone threaded ONLY when present (present-only, byte-fidelity).
function cardNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const sourceBlock = isPlainObject(attrs.bpBlock) ? attrs.bpBlock : null;
  const block = sourceBlock
    ? deepClone(sourceBlock)
    : { id, type: "card", slots: cardNodeToSlots(node) };
  block.id = id;
  block.type = "card";
  if (sourceBlock) {
    const overlay = cardNodeSlotOverlay(node, sourceBlock);
    if (overlay.changed) block.slots = overlay.slots;
    const sourceTone = sourceBlock.tone == null ? null : sourceBlock.tone;
    const nextTone = attrs.tone == null ? null : attrs.tone;
    if (nextTone !== sourceTone) block.tone = nextTone;
  } else if (attrs.tone != null) {
    block.tone = attrs.tone;
  }
  return block;
}

// The mutable-fields PATCH for a card. patch-block is a shallow top-level merge, so
// emit `slots` only when a slot surface changed, and `tone` only when tone changed.
// This prevents a tone-only edit from normalizing the authoritative slot shapes and
// prevents a body-only edit from materializing tone:null.
function cardNodeToPatch(node, sourceBlock) {
  const attrs = (node && node.attrs) || {};
  const patch = {};
  const overlay = cardNodeSlotOverlay(node, sourceBlock || {});
  if (overlay.changed) patch.slots = overlay.slots;
  const sourceTone = sourceBlock && sourceBlock.tone != null ? sourceBlock.tone : null;
  const nextTone = attrs.tone == null ? null : attrs.tone;
  if (nextTone !== sourceTone) patch.tone = nextTone;
  return patch;
}

// True when a card node's body OR chrome (tone/title/media/action) changed — an
// interior edit. Canonical (key-order-insensitive) compare so a body/tone/title/
// media/action edit flips it but a pure reorder (bpId only) does not.
function cardNodeChanged(prevNode, nextNode) {
  return stableCardKey(prevNode) !== stableCardKey(nextNode);
}

function stableCardKey(node) {
  const block = cardNodeToBlock(node, null);
  delete block.id;
  return canonicalJSON(block);
}

export {
  calloutBlockToNode,
  calloutNodeChanged,
  calloutNodeToBlock,
  calloutNodeToPatch,
  noteBlockToNode,
  noteNodeChanged,
  noteNodeToBlock,
  noteNodeToPatch,
  stableNoteKey,
  cardBlockEditable,
  cardBlockToNode,
  cardNodeChanged,
  cardNodeToBlock,
  cardNodeToPatch,
};
