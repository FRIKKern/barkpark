#!/usr/bin/env node
// design/sync-evergreen.mjs — the ATOMIC evergreen seam writer (gui-remake GR2/GR4).
//
// EVERGREEN IS ATOMIC: emit.mjs's seam guard (deepEqualColor at import) THROWS
// unless design/tokens.json's color tree === derive(themes/evergreen.json), so an
// evergreen restyle must move BOTH files in one mechanical step. This writer
// applies derive(evergreen) onto tokens.json's color tree SURGICALLY — a
// position-tracking scan finds each theme-varying string leaf and replaces the
// value bytes in place, so the hand-authored formatting (column alignment, _role
// / _note annotations, key order) survives untouched and the diff is exactly the
// slots that moved. Idempotent: a second run finds zero drift and writes nothing.
//
//   node design/sync-evergreen.mjs           # sync (writes only on drift)
//   node design/sync-evergreen.mjs --check   # report drift, exit 1 if any, write nothing
//
// Runs BEFORE emit.mjs in the pipeline (emit imports would throw on a stale
// tokens.json): validate → sync-evergreen → emit --write → check.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { derive } from "./derive.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const TOKENS = join(here, "tokens.json");
const checkOnly = process.argv.includes("--check");

// ── position-tracking JSON scan ──────────────────────────────────────────────
// Walks the raw text and records, for every STRING leaf, its dotted path and the
// byte span of the value INCLUDING quotes. Minimal JSON grammar (the file is
// proven well-formed by JSON.parse first); no dependency, no reformat.
function scanStringLeaves(text) {
  JSON.parse(text); // well-formedness gate — scan assumes valid JSON
  const leaves = new Map(); // "a.b.c" → { start, end, value }
  let i = 0;
  const ws = () => { while (i < text.length && /[\s]/.test(text[i])) i++; };
  const str = () => {
    // at opening quote; returns { value, start, end } with end past closing quote
    const start = i;
    i++; // opening "
    let out = "";
    while (text[i] !== '"') {
      if (text[i] === "\\") { out += JSON.parse(`"${text.slice(i, i + 2)}"`); i += 2; }
      else { out += text[i]; i++; }
    }
    i++; // closing "
    return { value: out, start, end: i };
  };
  const scalar = () => { while (i < text.length && !/[,\]}]/.test(text[i])) i++; };
  const value = (path) => {
    ws();
    const c = text[i];
    if (c === "{") {
      i++;
      ws();
      if (text[i] === "}") { i++; return; }
      for (;;) {
        ws();
        const k = str().value;
        ws();
        i++; // :
        value(path ? `${path}.${k}` : k);
        ws();
        if (text[i] === ",") { i++; continue; }
        i++; // }
        return;
      }
    } else if (c === "[") {
      i++;
      ws();
      if (text[i] === "]") { i++; return; }
      for (let idx = 0; ; idx++) {
        value(`${path}[${idx}]`);
        ws();
        if (text[i] === ",") { i++; continue; }
        i++; // ]
        return;
      }
    } else if (c === '"') {
      const s = str();
      leaves.set(path, s);
    } else {
      scalar(); // number / true / false / null — not a themable leaf
    }
  };
  value("");
  return leaves;
}

// ── the sync ─────────────────────────────────────────────────────────────────
const text = readFileSync(TOKENS, "utf8");
const leaves = scanStringLeaves(text);
const evergreen = JSON.parse(readFileSync(join(here, "themes", "evergreen.json"), "utf8"));
const { values } = derive(evergreen);

const edits = [];
const missing = [];
for (const [slot, want] of Object.entries(values)) {
  if (want === undefined) continue;
  const leaf = leaves.get(`color.${slot}`);
  if (!leaf) { missing.push(slot); continue; }
  if (leaf.value !== want) edits.push({ slot, from: leaf.value, to: want, start: leaf.start, end: leaf.end });
}
if (missing.length) {
  console.error(`sync-evergreen FAIL: ${missing.length} derive slot(s) have no tokens.json leaf (structure drift — the no-hole gate owns this): ${missing.slice(0, 6).join(", ")}`);
  process.exit(1);
}

if (edits.length === 0) {
  console.log("sync-evergreen: tokens.json already mirrors derive(evergreen) — 0 slots moved (idempotent no-op).");
  process.exit(0);
}

for (const e of edits) console.log(`  ${checkOnly ? "DRIFT" : "sync"} color.${e.slot}: "${e.from}" → "${e.to}"`);
if (checkOnly) {
  console.error(`sync-evergreen --check: ${edits.length} slot(s) drifted — run node design/sync-evergreen.mjs`);
  process.exit(1);
}

let out = text;
for (const e of edits.sort((a, b) => b.start - a.start))
  out = out.slice(0, e.start) + JSON.stringify(e.to) + out.slice(e.end);
JSON.parse(out); // never write a broken tokens.json
writeFileSync(TOKENS, out);
console.log(`sync-evergreen: ${edits.length} slot(s) synced into design/tokens.json (formatting preserved).`);
