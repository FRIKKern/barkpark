// A raw 0x00 byte in a tracked TEXT file makes that file invisible to plain
// grep — and not just at the NUL: BSD grep classifies the whole file as binary
// and reports NOTHING, including for matches that sit BEFORE the NUL. So a
// correctly scoped, self-tested census over this tree silently returns zero.
//
// That is not hypothetical here. markdown.js carried six raw NULs for months.
// Its own comment described them as "the 6-char escape", because the author
// meant to write the escape and a raw byte got pasted instead — the prose and
// the bytes disagreed and nothing could tell anyone. The sibling case cost a
// real audit: a census recorded __terminal_verb_dump.mjs as having no refusal
// arm while process.exit(6) sat in the file, unreadable.
//
// THIS IS A PREDICATE, NOT A LIST. It enumerates the tracked files under
// api/assets/paper-editor/ fresh on every run and fails on ANY of them, plus
// the two committed bundles. A file added tomorrow is covered the day it is
// added; there is no allowlist to forget to update. Every tracked path under
// this tree is text (mjs/js/json/html/md/css), so no binary carve-out is
// needed — and if a genuinely binary asset is ever added here, this test
// SHOULD red and force a deliberate decision rather than silently widening.
//
// The guard token in markdown.js is still a NUL at RUNTIME. Only the source
// SPELLING changed — the escape and the raw byte denote the same code point,
// which is why the whole bundle diff for that change was 1 byte becoming 6.
//
// This guard caught its own author: the first draft of THIS file carried a
// pasted raw NUL in the comment above, and stayed invisible until `git add`
// made it tracked. That is the failure mode, reproduced by accident.
//
// Run: node src/__no_raw_nul.test.mjs
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const NUL = 0x00;

// Tracked paths this guard covers: the whole editor source tree, plus the two
// committed artifacts built from it (a raw NUL in the source reaches the
// bundle through a regex literal, which esbuild copies verbatim).
const SCOPES = [
  "api/assets/paper-editor",
  "api/priv/static/assets/bp-paper-editor.bundle.js",
  "web/public/bp-paper-editor.bundle.js",
];

function trackedFiles() {
  const out = execFileSync("git", ["-C", REPO, "ls-files", "-z", "--", ...SCOPES]);
  return out.toString("utf8").split("\0").filter(Boolean);
}

function countNul(buf) {
  let n = 0;
  for (let i = 0; i < buf.length; i++) if (buf[i] === NUL) n++;
  return n;
}

const files = trackedFiles();
if (files.length < 100) {
  console.error(`FAIL: enumerated only ${files.length} tracked files — the sweep did not run`);
  process.exit(1);
}

const offenders = [];
for (const rel of files) {
  const n = countNul(readFileSync(resolve(REPO, rel)));
  if (n > 0) offenders.push({ rel, n });
}

// CONTROL: the detector must actually fire. Feed it a byte sequence we know
// carries a NUL; if this does not register, every clean verdict above is dead.
const controlHits = countNul(Buffer.from([0x61, NUL, 0x62]));
if (controlHits !== 1) {
  console.error(`FAIL: detector control did not fire (saw ${controlHits}, expected 1)`);
  process.exit(1);
}

if (offenders.length > 0) {
  console.error(`FAIL: ${offenders.length} tracked text file(s) carry a raw NUL:`);
  for (const o of offenders) console.error(`  ${o.n} NUL  ${o.rel}`);
  console.error("");
  console.error("Write the byte as the source escape backslash-u-0-0-0-0 instead. The runtime");
  console.error("string is identical; only the spelling changes, and the file stays greppable.");
  process.exit(1);
}

console.log(`__no_raw_nul: ${files.length} tracked files swept, 0 raw NUL, detector control fired`);
