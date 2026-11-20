// What Markdown carries: the one content comparison source mode checks before it opens.
//
//   sourceLoss(blocks)        -> null, or the first place where the Markdown source mode
//                                would show reads back with less than `blocks`
//   firstLoss(before, after)  -> the same comparison for any two block lists
//
// Source mode shows blocksToMarkdown(blocks) and, after any edit, saves
// markdownToBlocks(text) in place of the document. So it may open only where that
// round trip gives the document back: every character, every mark on a character,
// every link, every checked state, every block, every item child and every slot. There
// is no list of shapes here; the round trip itself is the check, as in BPML's own law
// (Barkpark.PortableDoc.Bpml: printing a block tree and parsing it back gives the same
// tree, held by the property test in bpml_test.exs).
//
// Four spellings are the same content and are compared as one (and an `id` the save
// gives a nested block that had none is not a loss: nothing stored goes):
//   1. a top-level block's `id`: markdownToBlocks mints new ids and source mode gives
//      each surviving block its id back (realignAcrossCommits);
//   2. adjacent text runs carrying the same marks, which are one run;
//   3. a text run with no characters and no mark, which carries nothing;
//   4. a key holding false, "", null, an empty list or an empty map, which is the same
//      as no key (`ordered: false`, `lang: ""`, `marks: []`).

import { blocksToMarkdown } from "./serialize.js";
import { markdownToBlocks } from "./parse.js";

// `settle(parsed)` is what the caller does to the parse before it saves: source mode
// gives surviving blocks their ids back and puts a locked template prefix back
// (sourceModeCommit), so it passes those steps and the check judges what would be saved.
export function sourceLoss(blocks, settle = (parsed) => parsed) {
  const list = Array.isArray(blocks) ? blocks : [];
  return firstLoss(list, settle(markdownToBlocks(blocksToMarkdown(list))));
}

// The first place `after` parts from `before`: { index, type, path, part }, where index
// is the top-level block (0-based), type its block type, path the place inside it
// ("slots.body", "content[1].marks") and part the plain name of what is lost there.
export function firstLoss(before, after) {
  const a = (before || []).map((block) => topBlock(block));
  const b = (after || []).map((block) => topBlock(block));
  const count = Math.max(a.length, b.length);
  for (let index = 0; index < count; index++) {
    const path = diffPath(a[index], b[index], "");
    if (path === null) continue;
    const block = (before || [])[index] ?? (after || [])[index];
    const type = block && typeof block === "object" && typeof block.type === "string" ? block.type : "block";
    return { index, type, path, part: partName(path) };
  }
  return null;
}

function topBlock(block) {
  if (!block || typeof block !== "object" || Array.isArray(block)) return normal(block);
  const { id: _id, ...rest } = block;
  return normal(rest);
}

// The normal form: rules 2 and 3 above, applied wherever an array holds text runs.
function normal(value) {
  if (Array.isArray(value)) {
    const out = [];
    for (const item of value.map(normal)) {
      if (isTextRun(item)) {
        if (item.value === "" && !item.marks) continue;
        const prev = out[out.length - 1];
        if (isTextRun(prev) && sameJson(prev.marks, item.marks)) {
          out[out.length - 1] = { ...prev, value: prev.value + item.value };
          continue;
        }
      }
      out.push(item);
    }
    return out;
  }
  if (value && typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value)) {
      // A text run keeps its `value` here; rule 3 drops the empty run whole.
      if (carriesNothing(value[key]) && !(key === "value" && value.type === "text")) continue;
      out[key] = normal(value[key]);
    }
    return out;
  }
  return value;
}

function carriesNothing(value) {
  if (value === false || value === "" || value === null || value === undefined) return true;
  if (Array.isArray(value)) return value.length === 0;
  return isMap(value) && Object.keys(value).length === 0;
}

function isTextRun(node) {
  if (!node || typeof node !== "object" || Array.isArray(node)) return false;
  if (node.type !== "text" || typeof node.value !== "string") return false;
  return Object.keys(node).every((key) => key === "type" || key === "value" || key === "marks");
}

function holdsTextRuns(value) {
  return Array.isArray(value) && value.some(isTextRun);
}

// The same content with every text run's marks taken off, then put in normal form.
function unmarked(value) {
  const strip = (v) => Array.isArray(v)
    ? v.map(strip)
    : isMap(v)
      ? Object.fromEntries(Object.entries(v)
        .filter(([key]) => !(key === "marks" && isTextRun(v)))
        .map(([key, item]) => [key, strip(item)]))
      : v;
  return normal(strip(value));
}

function sameJson(x, y) {
  return canonical(x ?? null) === canonical(y ?? null);
}

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isMap(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

// The first path where x and y part, or null when they are the same.
function diffPath(x, y, path) {
  if (Object.is(x, y)) return null;
  // Inline content that holds the same characters once the marks are set aside lost a
  // mark (which also merges its run into its neighbour): name the marks, not the text.
  if (holdsTextRuns(x) && holdsTextRuns(y) && !sameJson(x, y) && sameJson(unmarked(x), unmarked(y))) {
    return `${path}.marks`;
  }
  if (Array.isArray(x) && Array.isArray(y)) {
    const n = Math.min(x.length, y.length);
    for (let i = 0; i < n; i++) {
      const found = diffPath(x[i], y[i], `${path}[${i}]`);
      if (found !== null) return found;
    }
    return x.length === y.length ? null : `${path}[${n}]`;
  }
  if (isMap(x) && isMap(y)) {
    const keys = [...new Set([...Object.keys(x), ...Object.keys(y)])].sort();
    for (const key of keys) {
      const at = path ? `${path}.${key}` : key;
      if (key === "id" && !(key in x)) continue;
      if (!(key in x) || !(key in y)) return missingPath(key in x ? x[key] : y[key], at);
      const found = diffPath(x[key], y[key], at);
      if (found !== null) return found;
    }
    return null;
  }
  return path;
}

// A key one side lacks: when it holds a map (slots), name its first key (the body).
function missingPath(value, path) {
  if (!isMap(value)) return path;
  const [first] = Object.keys(value).sort();
  return first === undefined ? path : missingPath(value[first], `${path}.${first}`);
}

function isMap(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// The plain name of what a path loses, for the one line source mode shows.
function partName(path) {
  const keys = path.replace(/\[\d+\]/g, "").split(".").filter(Boolean);
  const slot = keys.indexOf("slots");
  if (slot !== -1 && keys[slot + 1]) return keys[slot + 1];
  if (keys.includes("marks")) return "marks";
  if (keys.includes("href")) return "links";
  if (keys.includes("checked")) return "checked boxes";
  if (keys.includes("children") && keys.includes("items")) return "item children";
  const last = keys[keys.length - 1];
  if (!last || last === "type") return "content";
  if (last === "value" || last === "text") return "text";
  return last;
}
