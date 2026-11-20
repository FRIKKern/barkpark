// The shared Portable Doc fixtures the source-mode wall is measured on, read in one
// place, from api/priv/portable_doc/goldens:
//
//   sourceWallGoldens()  every block and limit golden (`*.golden.json`), each as a
//                        one-block Paper. canvas/__source_inside_edit_sweep.test.mjs
//                        types on every line of these, and
//                        markdown/__reader_inline_rows.test.mjs reads their types.
//   sharedFixtureWalk()  EVERY file under that root, read by its shape, not by a list
//                        of folders: each document it holds becomes a Paper, and a file
//                        that holds no document is named on SKIPPED with its reason.
//                        A file that is neither read nor skipped comes back in
//                        `unread`, and __source_wall_fixtures.test.mjs fails on it. A
//                        hand-kept folder list is how two refused fixtures were missed.

import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { expandLimitDoc } from "../../../priv/portable_doc/conformance/conformance.mjs";
import { canonicalJSON } from "./canvas/projection-json.js";

const GOLDENS = fileURLToPath(new URL("../../../priv/portable_doc/goldens/", import.meta.url));

const json = (...path) => JSON.parse(readFileSync(join(GOLDENS, ...path), "utf8"));
const files = (dir, ending) => readdirSync(join(GOLDENS, dir)).filter((name) => name.endsWith(ending)).sort();

// [[name, block]], name as "blocks/paragraph", sorted by folder then file.
export function sourceWallGoldens() {
  const out = [];
  for (const dir of ["blocks", "limits"]) {
    for (const file of files(dir, ".golden.json")) {
      const { input } = json(dir, file);
      out.push([`${dir}/${file.replace(/\.golden\.json$/, "")}`, { id: "fixture", ...input }]);
    }
  }
  return out;
}

// The files under the root that hold no Portable Doc document. A pattern is a path from
// the root, where `*` stands for one file name; each says why the file is not swept.
export const SKIPPED = [
  ["stamp.json", "the pack's hashes of its own files"],
  ["fragments.json", "rendered HTML per block type, not blocks"],
  ["canvas-forbidden-classes.json", "class names the canvas may not emit"],
  ["i18n/*.json", "translated interface strings"],
  ["css/*.css", "stylesheets"],
  ["pages/*.html", "rendered pages"],
  ["email.html", "a rendered e-mail"],
];

const matches = (pattern, path) =>
  new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]+")}$`).test(path);

// A stored Paper's top-level blocks all carry an id; a fixture written without one
// gets one by its place.
const withIds = (blocks) => blocks.map((block, index) => (block && block.id ? block : { id: `fixture-${index}`, ...block }));
const isBlocks = (value) => Array.isArray(value) && value.every((block) => block && typeof block === "object" && typeof block.type === "string");
const docBlocks = (doc) => (doc && isBlocks(doc.blocks) ? doc.blocks : null);

// The documents one parsed file holds, as [[label, blocks]], by the file's shape; null
// when it has none of these shapes.
function documentsIn(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  // A block golden or a limit edge golden: one block under `input`.
  if (value.input && typeof value.input === "object" && typeof value.input.type === "string") return [["", [value.input]]];
  // A from-markdown golden or a carrier fixture: the blocks of one document.
  if (isBlocks(value.blocks)) return [["", value.blocks]];
  // An op golden: the document before the op and after it.
  if (docBlocks(value.before) && docBlocks(value.after)) return [[" before", value.before.blocks], [" after", value.after.blocks]];
  // A locale golden: the blocks it renders in that locale.
  if (isBlocks(value.inputs)) return [["", value.inputs]];
  // limit-docs.json: worst-case and edge docs, each one block written with the pack's
  // macros, expanded by the conformance kit's own expander.
  if (Array.isArray(value.docs) && value.docs.every((entry) => entry && entry.name && entry.doc)) {
    return ["docs", "edges"].flatMap((key) => (value[key] || []).map(({ name, doc }) => [` ${key}/${name}`, [expandLimitDoc(doc)]]));
  }
  // value-too-deep.json: cases, each a whole document.
  if (Array.isArray(value.cases) && value.cases.every((entry) => docBlocks(entry && entry.doc))) {
    return value.cases.map((entry, index) => [` ${entry.name || index}`, entry.doc.blocks]);
  }
  return null;
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true })
    .sort((a, b) => (a.name < b.name ? -1 : 1))
    .flatMap((entry) => (entry.isDirectory() ? walk(join(dir, entry.name)) : [join(dir, entry.name)]));
}

// The content of a Paper, without its top-level ids. limit-docs.json's edges are each
// rendered into a limits/ golden as well, so a document read under two names is read
// once: under the file that holds only it, else under the first name read.
const content = (blocks) => canonicalJSON(blocks.map(({ id: _id, ...rest }) => rest));

// { docs: [[name, blocks]], skipped: [[path, reason]], unread: [path], unusedSkips: [pattern],
//   duplicates: [[name, kept name]] }
export function sharedFixtureWalk(root = GOLDENS) {
  const read = [];
  const skipped = [];
  const unread = [];
  const used = new Set();
  for (const file of walk(root)) {
    const path = relative(root, file).split("\\").join("/");
    const skip = SKIPPED.find(([pattern]) => matches(pattern, path));
    if (skip) {
      used.add(skip[0]);
      skipped.push([path, skip[1]]);
      continue;
    }
    let found = null;
    if (path.endsWith(".json")) {
      try {
        found = documentsIn(JSON.parse(readFileSync(file, "utf8")));
      } catch (_notJson) {
        found = null;
      }
    }
    if (!found || found.length === 0) {
      unread.push(path);
      continue;
    }
    const name = path.replace(/\.golden\.json$|\.json$/, "");
    for (const [label, blocks] of found) {
      // A document past the value-depth limit is too deep to stringify; it is its own key.
      const key = jsonDepth({ blocks }) > MAX_VALUE_DEPTH ? `${name}${label}` : content(blocks);
      read.push({ name: `${name}${label}`, blocks: withIds(blocks), alone: found.length === 1, key });
    }
  }
  const kept = new Map();
  for (const entry of read) {
    const was = kept.get(entry.key);
    if (!was || (entry.alone && !was.alone)) kept.set(entry.key, entry);
  }
  const docs = read.filter((entry) => kept.get(entry.key) === entry).map(({ name, blocks }) => [name, blocks]);
  const duplicates = read.filter((entry) => kept.get(entry.key) !== entry).map((entry) => [entry.name, kept.get(entry.key).name]);
  const unusedSkips = SKIPPED.map(([pattern]) => pattern).filter((pattern) => !used.has(pattern));
  return { docs, skipped, unread, unusedSkips, duplicates };
}

// Portable Doc's value-depth limit: a document nesting deeper is refused by the
// validator, so no Paper holds one. The value-depth golden carries the number.
export const MAX_VALUE_DEPTH = json("limits", "value-too-deep.json").maxValueDepth;

// How many JSON levels deep a value goes, counted without recursion (a worst-case
// limit doc nests 20,000 levels).
export function jsonDepth(value) {
  let deepest = 0;
  const stack = [[value, 1]];
  while (stack.length) {
    const [node, depth] = stack.pop();
    if (!node || typeof node !== "object") continue;
    if (depth > deepest) deepest = depth;
    for (const child of Object.values(node)) stack.push([child, depth + 1]);
  }
  return deepest;
}
