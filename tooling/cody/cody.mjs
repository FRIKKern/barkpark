#!/usr/bin/env node
// cody — "bound variables: programming through papers" (POC).
//
// A value lives in BOTH a Barkpark paper (typed, validated) AND one-or-more code
// literals. Edit it in Barkpark → cody rewrites every bound literal on disk,
// validated + verified + reviewable (git). It also detects DRIFT — when copies
// of one logical constant have fallen out of sync across files.
//
//   node cody.mjs scan            code → paper  (extract literals, push to Barkpark)
//   node cody.mjs status          control panel: code vs paper, locations, drift
//   node cody.mjs set <var> <val> edit in Barkpark (validated at the paper)
//   node cody.mjs apply [--write] paper → code  (rewrite EVERY bound location)
//   node cody.mjs watch           live: SSE stream → edits land on disk instantly

import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const HOST = "http://localhost:4000", DATASET = "cody-poc", TOK = "barkpark-dev-token";
const BINDINGS = JSON.parse(readFileSync(join(HERE, "bindings.json"), "utf8"));
const byName = Object.fromEntries(BINDINGS.map(b => [b.name, b]));
const locs = (b) => b.locations || [{ file: b.file, pattern: b.pattern }];

const post = async (path, body) => {
  const r = await fetch(HOST + path, { method: "POST",
    headers: { authorization: "Bearer " + TOK, "content-type": "application/json" },
    body: JSON.stringify(body) });
  return { ok: r.ok, status: r.status, body: await r.text() };
};
const query = async () => {
  const r = await fetch(`${HOST}/v1/data/query/${DATASET}/tuning?perspective=raw&limit=200`,
    { headers: { authorization: "Bearer " + TOK } });
  if (!r.ok) return [];
  return (await r.json()).result?.documents || [];
};
const mutate = (m) => post(`/v1/data/mutate/${DATASET}`, { mutations: m });

// ── read the literal at one location via its anchor ──
function readLoc(loc) {
  const m = readFileSync(join(ROOT, loc.file), "utf8").match(new RegExp(loc.pattern));
  return m ? m[1] : null;
}
const codeValues = (b) => locs(b).map(readLoc);
const codeValue  = (b) => codeValues(b)[0];                       // canonical = first
const driftset   = (b) => [...new Set(codeValues(b).filter(v => v != null))];
const hasDrift   = (b) => driftset(b).length > 1;                 // copies disagree

// ── validate a candidate against the binding's type + constraints ──
function validate(b, raw) {
  const s = String(raw).trim();
  if (b.vtype === "int"   && !/^-?\d+$/.test(s))     return { ok: false, why: `not an int: "${s}"` };
  if (b.vtype === "float" && !/^-?\d*\.?\d+$/.test(s)) return { ok: false, why: `not a number: "${s}"` };
  const n = Number(s);
  if (b.min != null && n < b.min) return { ok: false, why: `${n} < min ${b.min}` };
  if (b.max != null && n > b.max) return { ok: false, why: `${n} > max ${b.max}` };
  return { ok: true, value: s };
}

// ── rewrite the literal at EVERY bound location (the "compile" step) ──
function writeCode(b, newVal) {
  const changed = [];
  for (const loc of locs(b)) {
    const path = join(ROOT, loc.file);
    const txt = readFileSync(path, "utf8");
    const m = txt.match(new RegExp(loc.pattern));
    if (!m) throw new Error(`anchor not found in ${loc.file}`);
    if (m[1] === newVal) continue;                       // already correct
    writeFileSync(path, txt.replace(m[0], m[0].replace(m[1], newVal)));
    if (readLoc(loc) !== newVal) throw new Error(`verify failed in ${loc.file}`);
    changed.push({ file: loc.file, from: m[1], to: newVal });
  }
  return changed;                                        // [] if nothing changed
}

const C = { g: "\x1b[32m", y: "\x1b[33m", r: "\x1b[31m", b: "\x1b[1m", d: "\x1b[2m", x: "\x1b[0m" };
const docFields = (b, value) => ({ _type: "tuning", varname: b.name, value: String(value),
  vtype: b.vtype, doc: b.doc, locations: String(locs(b).length) });

// ── commands ──────────────────────────────────────────────────────────────
async function scan() {
  const schema = { name: "tuning", title: "Tuning variables", fields: [
    { name: "varname", type: "string" }, { name: "value", type: "string" },
    { name: "vtype", type: "string" }, { name: "doc", type: "string" }, { name: "locations", type: "string" } ] };
  const sr = await post(`/v1/schemas/${DATASET}`, schema);
  console.error(sr.ok ? `[cody] registered tuning schema in '${DATASET}'` : `[cody] schema: ${sr.status} (may already exist)`);
  for (const b of BINDINGS) {
    const v = codeValue(b), id = `tuning-${b.name}`, n = locs(b).length;
    await mutate([{ createOrReplace: { _id: id, ...docFields(b, v) } }]);
    await mutate([{ publish: { id, type: "tuning" } }]);
    const drift = hasDrift(b) ? ` ${C.r}⚠ DRIFT ${driftset(b).join("≠")}${C.x}` : "";
    console.log(`  ${C.g}↑${C.x} ${b.name.padEnd(19)} = ${C.b}${v}${C.x}  ${C.d}(${n} location${n>1?"s":""})${C.x}${drift}`);
  }
  console.error(`[cody] ${BINDINGS.length} bound variables → Barkpark dataset '${DATASET}'`);
}

async function status() {
  const docs = Object.fromEntries((await query()).map(d => [d.varname, d.value]));
  console.log(`  ${C.b}variable             code     paper    loc  state${C.x}`);
  for (const b of BINDINGS) {
    const code = codeValue(b), paper = docs[b.name] ?? "(unscanned)", n = locs(b).length;
    const tag = hasDrift(b) ? `${C.r}⚠ DRIFT across copies (${driftset(b).join("≠")})${C.x}`
      : paper === "(unscanned)" ? `${C.d}—${C.x}`
      : code === paper ? `${C.g}in sync${C.x}` : `${C.y}DRIFT → apply${C.x}`;
    console.log(`  ${b.name.padEnd(19)} ${String(code).padEnd(8)} ${String(paper).padEnd(8)} ${String(n).padEnd(4)} ${tag}`);
  }
}

async function set(name, val) {
  const b = byName[name];
  if (!b) { console.error(`[cody] unknown variable: ${name}`); process.exit(2); }
  const v = validate(b, val);
  if (!v.ok) { console.error(`  ${C.r}✗ rejected at the paper${C.x} — ${name}: ${v.why} (${b.vtype}${b.min!=null?`, min ${b.min}`:""}${b.max!=null?`, max ${b.max}`:""})`); process.exit(1); }
  const id = `tuning-${b.name}`;
  await mutate([{ createOrReplace: { _id: id, ...docFields(b, v.value) } }]);
  await mutate([{ publish: { id, type: "tuning" } }]);
  console.log(`  ${C.g}✓${C.x} ${name} = ${C.b}${v.value}${C.x} in Barkpark  ${C.d}(${locs(b).length} code location(s) still ${codeValue(b)} — apply to sync)${C.x}`);
}

async function apply(write) {
  const docs = Object.fromEntries((await query()).map(d => [d.varname, d.value]));
  let n = 0;
  for (const b of BINDINGS) {
    const paper = docs[b.name];
    if (paper == null) continue;
    const needsWrite = codeValues(b).some(c => c !== paper);
    if (!needsWrite) continue;
    const v = validate(b, paper);
    if (!v.ok) { console.log(`  ${C.r}✗ skip ${b.name}${C.x} — paper value invalid: ${v.why}`); continue; }
    n++;
    if (write) {
      for (const d of writeCode(b, v.value))
        console.log(`  ${C.g}✎ ${d.file}${C.x}  ${d.from} → ${C.b}${d.to}${C.x}  ${C.d}(${b.name}, verified)${C.x}`);
    } else {
      console.log(`  ${C.y}~ ${b.name}${C.x} → ${C.b}${paper}${C.x}  ${C.d}(${locs(b).length} location(s); --write to apply)${C.x}`);
    }
  }
  if (!n) console.log(`  ${C.g}nothing to apply — code and papers agree${C.x}`);
  else if (write) console.error(`\n[cody] synced ${n} variable(s). Review: ${C.b}git diff${C.x}`);
}

// ── watch: live SSE bridge — edits in Barkpark land on disk instantly ──
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function reconcile(reason) {
  const docs = Object.fromEntries((await query()).map(d => [d.varname, d.value]));
  for (const b of BINDINGS) {
    const paper = docs[b.name];
    if (paper == null || !codeValues(b).some(c => c !== paper)) continue;
    const v = validate(b, paper);
    if (!v.ok) { console.log(`  ${C.r}✗ ${b.name}${C.x} invalid in paper (${v.why})`); continue; }
    for (const d of writeCode(b, v.value))
      console.log(`  ${C.g}✎ ${d.file}${C.x}  ${d.from} → ${C.b}${d.to}${C.x}  ${C.d}(${b.name} · ${reason})${C.x}`);
  }
}
async function onFrame(frame) {
  let event = "message", data = "";
  for (const l of frame.split("\n")) {
    if (l.startsWith("event:")) event = l.slice(6).trim();
    else if (l.startsWith("data:")) data += l.slice(5).trim();
  }
  if (event !== "mutation") return;
  let p; try { p = JSON.parse(data); } catch { return; }
  if (p.type !== "tuning") return;
  await reconcile(`${p.mutation} ${p.documentId}`);
}
async function watch() {
  console.error(`${C.b}[cody watch]${C.x} live bridge on '${DATASET}' — edit a tuning variable in Barkpark, it lands on disk`);
  await reconcile("startup");
  const url = `${HOST}/v1/data/listen/${DATASET}`;
  for (;;) {
    try {
      // Accept: */* — the route's :accepts plug only allows "json" and 406s on
      // "text/event-stream"; the controller streams SSE regardless.
      const res = await fetch(url, { headers: { authorization: "Bearer " + TOK, accept: "*/*" } });
      if (!res.ok || !res.body) { console.error(`  ${C.y}connect ${res.status}; retry 3s${C.x}`); await sleep(3000); continue; }
      console.error(`  ${C.d}connected → /v1/data/listen/${DATASET} (Ctrl-C to stop)${C.x}`);
      const reader = res.body.getReader(), dec = new TextDecoder(); let buf = "";
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        buf += dec.decode(value, { stream: true });
        let i; while ((i = buf.indexOf("\n\n")) >= 0) { const f = buf.slice(0, i); buf = buf.slice(i + 2); await onFrame(f); }
      }
      console.error(`  ${C.y}stream ended; reconnecting${C.x}`);
    } catch (e) { console.error(`  ${C.y}${e.message}; retry 3s${C.x}`); }
    await sleep(3000);
  }
}

const [cmd, ...rest] = process.argv.slice(2);
const run = { scan, status, set: () => set(rest[0], rest[1]), apply: () => apply(rest.includes("--write")), watch }[cmd];
if (!run) { console.error("usage: cody.mjs scan | status | set <var> <value> | apply [--write] | watch"); process.exit(2); }
await run();
