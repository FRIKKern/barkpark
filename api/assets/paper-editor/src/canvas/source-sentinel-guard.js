// The guard on what a source-mode save would store, for the blocks the textarea shows
// as JSON sentinels (serialize.js). It looks at the saved blocks, not at what was typed,
// so no shape of edit to a sentinel line gets past it:
//
//   (a) no block the save writes holds, in any of its strings, the sentinel marker or a
//       shown sentinel's JSON more times than that block held it before (a block a
//       Paper already stored with a Markdown sample keeps it);
//   (b) every block shown as a sentinel that the save folds onto is either stored
//       with the same id and the same bytes (as stored or as shown), or deleted by a
//       save that only deletes: what it stores is what it folds onto with blocks taken
//       out, each one left unchanged and in its order. Deleting such a block and
//       writing anything else go in two saves. A copy under a new id, while the block
//       stays, is a new block like any other.
//
// sentinelRefusal(base, shown, text, saved) is null when the save may go, else
// { index, removal }: the block to name (a block shown as JSON by its place in `shown`,
// a new block by its place in `saved`), and whether the save deletes a block shown as
// JSON and does more. Which of the two it is follows the stored result: a block whose
// id the save still holds counts as edited. A null `saved`, a batch the fold refuses,
// is refused whatever the Paper holds: nothing proves it safe. sentinelHarm gives the
// index or -1.
// `base` is what the save folds onto, `shown` the blocks the textarea was made from,
// `text` what it held before the edit (a block counts as shown as JSON only when its
// sentinel line is one of those lines: after a remote change the textarea keeps the
// writer's own spelling of a block), `saved` the fold.

import { blocksToMarkdown } from "../markdown/serialize.js";
import { SENTINEL_CLOSE, SENTINEL_OPEN } from "../markdown/shared.js";
import { canonicalJSON } from "./projection-json.js";

export function sentinelHarm(base, shown, text, saved) {
  const refusal = sentinelRefusal(base, shown, text, saved);
  return refusal ? refusal.index : -1;
}

export function sentinelRefusal(base, shown, text, saved) {
  const held = new Set(String(text || "").split("\n").map((line) => line.trim()));
  const sentinels = (shown || []).flatMap((block) => {
    const line = block && block.id ? blocksToMarkdown([block]).trim() : "";
    return line.startsWith(SENTINEL_OPEN) && line.endsWith(SENTINEL_CLOSE) && !line.includes("\n") && held.has(line)
      ? [[block, line.slice(SENTINEL_OPEN.length, line.length - SENTINEL_CLOSE.length)]]
      : [];
  });
  if (!saved) return { index: sentinels.length ? (shown || []).indexOf(sentinels[0][0]) : 0, removal: false };
  if (!sentinels.length) return null;
  const needles = [SENTINEL_OPEN.trim(), ...sentinels.map(([, payload]) => payload)];
  const byId = (blocks) => new Map((blocks || []).filter((b) => b && b.id).map((b) => [b.id, b]));
  const before = byId(base);
  const shownById = byId(shown);
  const unchanged = (block) => {
    const was = block && before.get(block.id);
    return Boolean(was) && canonicalJSON(was) === canonicalJSON(block);
  };
  const at = new Map(saved.map((block, index) => [block && block.id, index]));
  const gone = [];
  for (const [block] of sentinels) {
    if (!before.has(block.id)) continue;
    if (!at.has(block.id)) {
      gone.push(block);
      continue;
    }
    const json = canonicalJSON(saved[at.get(block.id)]);
    if (json !== canonicalJSON(before.get(block.id)) && json !== canonicalJSON(shownById.get(block.id))) {
      return { index: shown.indexOf(block), removal: false };
    }
  }
  if (gone.length) {
    // A save that deletes a block shown as JSON only deletes: every block it stores
    // was there before, unchanged and in its order.
    const order = new Map((base || []).map((block, index) => [block && block.id, index]));
    let last = -1;
    const onlyDeletes = saved.every((block) => {
      const index = unchanged(block) ? order.get(block.id) : -1;
      if (index === -1 || index <= last) return false;
      last = index;
      return true;
    });
    return onlyDeletes ? null : { index: shown.indexOf(gone[0]), removal: true };
  }
  const index = saved.findIndex((block) => {
    if (unchanged(block)) return false;
    const was = block && before.get(block.id);
    return needles.some((needle) => hits(block, needle) > (was ? hits(was, needle) : 0));
  });
  return index === -1 ? null : { index, removal: false };
}

// How many times `needle` appears across every string in `value`.
function hits(value, needle) {
  if (typeof value === "string") return value.split(needle).length - 1;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + hits(item, needle), 0);
  if (value && typeof value === "object") return Object.values(value).reduce((sum, item) => sum + hits(item, needle), 0);
  return 0;
}
