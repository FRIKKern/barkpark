// The guard on what a source-mode save would store, for the blocks the textarea shows
// as JSON sentinels (serialize.js). It looks at the saved blocks, not at what was typed,
// so no shape of edit to a sentinel line gets past it:
//
//   (a) no block the save writes holds, in any of its strings, the sentinel marker or a
//       shown sentinel's JSON more times than that block held it before (a block a
//       Paper already stored with a Markdown sample keeps it);
//   (b) every block shown as a sentinel is saved unchanged (the same id, the same
//       bytes as stored or as shown) or not saved at all.
//
// sentinelHarm(base, shown, text, saved) is the index in `saved` of the first block
// that breaks either rule, or -1. `base` is what the save folds onto, `shown` the blocks
// the textarea was made from, `text` what it held before the edit (a block counts as
// shown as JSON only when its sentinel line is one of those lines: after a remote change
// the textarea keeps the writer's own spelling of a block), `saved` the fold.

import { blocksToMarkdown } from "../markdown/serialize.js";
import { SENTINEL_CLOSE, SENTINEL_OPEN } from "../markdown/shared.js";
import { canonicalJSON } from "./projection-json.js";

export function sentinelHarm(base, shown, text, saved) {
  const held = new Set(String(text || "").split("\n").map((line) => line.trim()));
  const sentinels = (shown || []).flatMap((block) => {
    const line = block && block.id ? blocksToMarkdown([block]).trim() : "";
    return line.startsWith(SENTINEL_OPEN) && line.endsWith(SENTINEL_CLOSE) && !line.includes("\n") && held.has(line)
      ? [[block, line.slice(SENTINEL_OPEN.length, line.length - SENTINEL_CLOSE.length)]]
      : [];
  });
  if (!sentinels.length) return -1;
  const needles = [SENTINEL_OPEN.trim(), ...sentinels.map(([, payload]) => payload)];
  const byId = (blocks) => new Map((blocks || []).filter((b) => b && b.id).map((b) => [b.id, b]));
  const before = byId(base);
  const shownById = byId(shown);
  const sentinelIds = new Set(sentinels.map(([block]) => block.id));
  return (saved || []).findIndex((block) => {
    const was = block && before.get(block.id);
    if (sentinelIds.has(block && block.id)) {
      const json = canonicalJSON(block);
      return json !== canonicalJSON(was) && json !== canonicalJSON(shownById.get(block.id));
    }
    if (was && canonicalJSON(was) === canonicalJSON(block)) return false;
    return needles.some((needle) => hits(block, needle) > (was ? hits(was, needle) : 0));
  });
}

// How many times `needle` appears across every string in `value`.
function hits(value, needle) {
  if (typeof value === "string") return value.split(needle).length - 1;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + hits(item, needle), 0);
  if (value && typeof value === "object") return Object.values(value).reduce((sum, item) => sum + hits(item, needle), 0);
  return 0;
}
