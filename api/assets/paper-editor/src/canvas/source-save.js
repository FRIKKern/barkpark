// What a source-mode save stores, found by running the save rather than modelling it.
//
//   sourceSaved(base, parsed, view) -> the blocks the server would hold after a
//                                      source commit of `parsed` over `base`
//
// sourceModeCommit gives each surviving block its id back and puts a locked template
// prefix back, lays the result into the editor, and emits runToOps(stored, editor
// doc); the server folds those ops onto what it stores (patch.ex). Here the same
// steps run without touching the editor: the realign and clamp, the editor's
// projection (`view.toDoc`, its schema included), runToOps (`view.toOps`), then the
// ops folded onto `base` with the patch.ex mirror (patch-fold.js). So a key the parse
// leaves out survives exactly when the save would keep it: a heading's role (never
// patched), a paragraph's tone (a patch-block merge), but not a list's `start` (the
// prose patch writes it as null) and not anything a replace-block or a remove and
// insert rebuilds. A batch the fold refuses saves nothing whole, so it reads as the
// loss of every block.
//
// One rule sits next to the fold: a callout holding a body (slots.body) is counted as
// losing it. The fold keeps the body on an edit elsewhere, but the editor shows a
// callout's text from slots.body[0] and writes an edit inside it into `content`, over
// the callout's own words, and no check before opening can see that edit. So such a
// Paper opens read-only naming the callout until task-6a8137419e0153e4 fixes the
// callout projection and lifts this rule. `{ calloutBody: "lifted" }` lifts it, for
// the inside-edit sweep (__source_inside_edit_sweep.test.mjs) that proves the rule is
// the whole class.
//
// A second rule is derived, not named: after the save, a prose block must show in the
// reader the words the editor showed for it (markdown/reader-inline.js mirrors the
// reader's fallbacks). Where the editor's projection drops the key the reader reads
// (a quote or callout holding only `text`), the save keeps that key and the reader
// goes on showing it over what was typed, so the block counts as losing that key.

import { firstLoss } from "../markdown/carries.js";
import { readerInline, readerInlineKey } from "../markdown/reader-inline.js";
import { normalizeCanvasDoc } from "./canvas-document.js";
import { applyOps } from "./patch-fold.js";
import { docToBlocks } from "./run-convert.js";
import { clampLockedPrefix, deepCloneBlocks, realignAcrossCommits } from "./source-realign.js";

export function sourceSaved(base, parsed, view, { calloutBody = "named" } = {}) {
  const stored = deepCloneBlocks(base);
  const laid = clampLockedPrefix(stored, realignAcrossCommits(stored, stored, parsed));
  const shown = docToBlocks(normalizeCanvasDoc(view.toDoc(laid), stored));
  const doc = view.toDoc(shown);
  let saved;
  try {
    saved = applyOps(stored, view.toOps(stored, doc, { preserveNewIds: true }) || []);
  } catch (_refused) {
    return [];
  }
  const shownById = new Map(shown.filter((block) => block && block.id).map((block) => [block.id, block]));
  saved = saved.map((block) => withoutUnshownWords(block, shownById.get(block && block.id)));
  return calloutBody === "lifted" ? saved : saved.map(withoutCalloutBody);
}

// The saved block with the reader's key dropped when the reader would show other words
// than the editor showed for it.
function withoutUnshownWords(block, shown) {
  const read = readerInline(block);
  if (!shown || read === null || shown.type !== block.type) return block;
  const wrap = (content) => [{ type: "paragraph", content }];
  if (!firstLoss(wrap(readerInline(shown)), wrap(read))) return block;
  const key = readerInlineKey(block);
  if (key === "slots.body") {
    const { body: _body, ...slots } = block.slots;
    return { ...block, slots };
  }
  const { [key]: _words, ...rest } = block;
  return rest;
}

function withoutCalloutBody(block) {
  if (!block || block.type !== "callout" || !block.slots || !Array.isArray(block.slots.body) || block.slots.body.length === 0) {
    return block;
  }
  const { body: _body, ...slots } = block.slots;
  return { ...block, slots };
}
