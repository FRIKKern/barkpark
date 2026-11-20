// The shared Portable Doc fixtures the source-mode wall is measured on, read in one
// place, from api/priv/portable_doc/goldens. sharedFixtureWalk() reads EVERY file under
// that root by its shape, not by a list of folders: each document it holds becomes a
// Paper, and a file that holds no document is named on SKIPPED with its reason. A file
// counts as read only when every key in it belongs to its shape; a file neither read
// nor skipped comes back in `unread`, and a skipped JSON file that holds a document
// comes back in `skippedDocuments`. __source_wall_fixtures.test.mjs fails on both. A
// hand-kept folder list is how two refused fixtures were missed.
//
// canvas/__source_inside_edit_sweep.test.mjs types on every document of the walk, and
// markdown/__reader_inline_rows.test.mjs reads their block types.

import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { expandLimitDoc } from "../../../priv/portable_doc/conformance/conformance.mjs";
import { canonicalJSON } from "./canvas/projection-json.js";

const GOLDENS = fileURLToPath(new URL("../../../priv/portable_doc/goldens/", import.meta.url));

const json = (...path) => JSON.parse(readFileSync(join(GOLDENS, ...path), "utf8"));

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

const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const onlyKeys = (value, keys) => isObject(value) && Object.keys(value).every((key) => keys.includes(key));
const docOf = (doc, keys) => (onlyKeys(doc, keys) && isBlocks(doc.blocks) ? doc.blocks : null);

// Each shape a fixture file can have: what marks it, the full set of keys a file of that
// shape may carry, and the documents it holds as [[label, blocks]]. A file with a key
// outside its shape's set is not read, so a document added under a new key cannot hide.
const SHAPES = [
  {
    name: "block or limit golden: one block under `input`",
    marks: (value) => isObject(value.input) && typeof value.input.type === "string",
    keys: ["_comment", "expectedHtml", "input", "name", "shape", "type"],
    documents: (value) => [["", [value.input]]],
  },
  {
    name: "from-markdown golden or carrier fixture: the blocks of one document",
    marks: (value) => isBlocks(value.blocks),
    keys: ["blocks", "markdown"],
    documents: (value) => [["", value.blocks]],
  },
  {
    name: "op golden: the document before the op and after it",
    marks: (value) => isObject(value.before) && isObject(value.after),
    keys: ["after", "before", "op", "tableProjections"],
    documents: (value) => {
      const docKeys = ["blocks", "preview", "title", "version"];
      const before = docOf(value.before, docKeys);
      const after = docOf(value.after, docKeys);
      return before && after ? [[" before", before], [" after", after]] : null;
    },
  },
  {
    name: "locale golden: the blocks it renders in that locale",
    marks: (value) => isBlocks(value.inputs),
    keys: ["_comment", "expectedHtml", "inputs", "locale", "shape", "strings"],
    documents: (value) => [["", value.inputs]],
  },
  {
    // Worst-case and edge docs, each one block written with the pack's macros, expanded
    // by the conformance kit's own expander.
    name: "limit-docs.json: named docs and edges",
    marks: (value) => Array.isArray(value.docs),
    keys: ["_comment", "docs", "edges"],
    documents: (value) => {
      const lists = ["docs", "edges"].map((key) => [key, value[key] || []]);
      const entries = lists.flatMap(([, list]) => list);
      if (!entries.every((entry) => onlyKeys(entry, ["doc", "name"]) && entry.name && entry.doc)) return null;
      return lists.flatMap(([key, list]) => list.map(({ name, doc }) => [` ${key}/${name}`, [expandLimitDoc(doc)]]));
    },
  },
  {
    name: "value-too-deep.json: cases, each a whole document",
    marks: (value) => Array.isArray(value.cases),
    keys: ["cases", "maxValueDepth"],
    documents: (value) => {
      if (!value.cases.every((entry) => onlyKeys(entry, ["doc", "expect", "name"]) && docOf(entry.doc, ["blocks"]))) return null;
      return value.cases.map((entry, index) => [` ${entry.name || index}`, entry.doc.blocks]);
    },
  },
];

// The documents one parsed file holds, as [[label, blocks]]; null when it has none of
// the shapes, or a key its shape does not carry.
export function documentsIn(value) {
  if (!isObject(value)) return null;
  const shape = SHAPES.find((candidate) => candidate.marks(value));
  if (!shape || !onlyKeys(value, shape.keys)) return null;
  const found = shape.documents(value);
  return found && found.length ? found : null;
}

// Whether a value holds a document anywhere inside it: an object any shape marks, at any
// depth. A skipped file must hold none.
export function holdsDocument(value) {
  const stack = [value];
  while (stack.length) {
    const node = stack.pop();
    if (!node || typeof node !== "object") continue;
    if (isObject(node) && SHAPES.some((shape) => shape.marks(node))) return true;
    stack.push(...Object.values(node));
  }
  return false;
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

// { docs: [[name, blocks]], skipped: [[path, reason]], skippedDocuments: [path],
//   unread: [path], unusedSkips: [pattern], duplicates: [[name, kept name]] }
export function sharedFixtureWalk(root = GOLDENS) {
  const read = [];
  const skipped = [];
  const unread = [];
  const skippedDocuments = [];
  const used = new Set();
  for (const file of walk(root)) {
    const path = relative(root, file).split("\\").join("/");
    const skip = SKIPPED.find(([pattern]) => matches(pattern, path));
    if (skip) {
      used.add(skip[0]);
      skipped.push([path, skip[1]]);
      if (path.endsWith(".json") && holdsDocument(JSON.parse(readFileSync(file, "utf8")))) skippedDocuments.push(path);
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
    if (!found) {
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
  return { docs, skipped, skippedDocuments, unread, unusedSkips, duplicates };
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
