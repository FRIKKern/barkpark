// What a source-mode save stores, found by running the save rather than modelling it.
//
//   sourceSaved(base, parsed, view) -> the blocks the server would hold after a
//                                      source commit of `parsed` over `base`
//   sourceWallLoss(stored, live, view) -> the first loss opening source mode on
//                                      `stored` (shown as `live`) could make, or null
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

import { firstLoss, sourceLoss } from "../markdown/carries.js";
import { markdownToBlocks } from "../markdown/parse.js";
import { blocksToMarkdown } from "../markdown/serialize.js";
import { readerInline, readerInlineKey } from "../markdown/reader-inline.js";
import { normalizeCanvasDoc } from "./canvas-document.js";
import { applyOps } from "./patch-fold.js";
import { docToBlocks } from "./run-convert.js";
import { clampLockedPrefix, deepCloneBlocks, realignAcrossCommits } from "./source-realign.js";

export function sourceSaved(base, parsed, view, { calloutBody = "named", realignTo = null } = {}) {
  const stored = deepCloneBlocks(base);
  const shownBefore = realignTo ? deepCloneBlocks(realignTo) : stored;
  const laid = clampLockedPrefix(shownBefore, realignAcrossCommits(shownBefore, shownBefore, parsed));
  const { shown, saved: folded } = sourceStored(stored, laid, view);
  if (!folded) return [];
  let saved = folded;
  const shownById = new Map(shown.filter((block) => block && block.id).map((block) => [block.id, block]));
  saved = saved.map((block) => withoutUnshownWords(block, shownById.get(block && block.id)));
  return calloutBody === "lifted" ? saved : saved.map(withoutCalloutBody);
}

// What a source commit of `laid` (the parse, realigned and clamped) stores over `base`:
// the editor's projection of it (`shown`), and the ops runToOps sends from `base`
// folded onto `base` (`saved`, null when the fold refuses the batch).
export function sourceStored(base, laid, view) {
  const stored = deepCloneBlocks(base);
  // An empty run projects to a doc with no content key.
  const doc = view.toDoc(laid);
  const shown = docToBlocks(normalizeCanvasDoc({ ...doc, content: doc.content || [] }, stored));
  try {
    return { shown, saved: applyOps(stored, view.toOps(stored, view.toDoc(shown), { preserveNewIds: true }) || []) };
  } catch (_refused) {
    return { shown, saved: null };
  }
}

export { sentinelHarm, sentinelRefusal } from "./source-sentinel-guard.js";

// The wall: the first loss opening source mode could make, or null. `stored` is what
// the Paper holds, with the ops still in flight (`inflight`) folded on. Its own
// Markdown is judged for what Markdown cannot carry. Then the live doc's Markdown, the
// text source mode shows, is saved unedited the way a commit saves it (realigned
// against the live doc, the editor's projection, ops from the stored blocks) and must
// give back the stored blocks: a key the editor's own save drops is a loss here too.
export function sourceWallLoss(stored, live, view, { inflight = null, ...options } = {}) {
  let base = deepCloneBlocks(stored);
  if (Array.isArray(inflight) && inflight.length) {
    try {
      base = applyOps(base, inflight);
    } catch (_refused) {
      // A batch the fold refuses: judge against what is stored.
    }
  }
  const fromStored = sourceLoss(base, (parsed) => sourceSaved(base, parsed, view, options));
  if (fromStored) return fromStored;
  const parsed = markdownToBlocks(blocksToMarkdown(live));
  return firstLoss(base, sourceSaved(base, parsed, view, { ...options, realignTo: live }));
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
