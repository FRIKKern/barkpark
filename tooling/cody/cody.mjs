#!/usr/bin/env node
// cody — "bound variables: programming through papers" (POC).
//
// A value lives in BOTH a Barkpark paper (typed, validated) AND one-or-more code
// literals. Edit it in Barkpark → cody rewrites every bound literal on disk,
// validated + verified + reviewable (git). It also detects DRIFT — when copies
// of one logical constant have fallen out of sync across files.
//
//   node cody.mjs preflight       where am I + is the codebase fully analyzed?
//   node cody.mjs scan            code → paper  (extract literals, push to Barkpark)
//   node cody.mjs status          control panel: code vs paper, locations, drift
//   node cody.mjs set <var> <val> edit in Barkpark (validated at the paper)
//   node cody.mjs apply [--write] paper → code  (rewrite EVERY bound location)
//   node cody.mjs watch           live: SSE stream → edits land on disk instantly
//
// Cody is Barkpark's own agent: it ALWAYS resolves which Barkpark it is launched
// against (local vs the project's public host, from barkpark.json), and refuses
// to rewrite code (apply/watch) unless preflight is green — full codebase
// intelligence is current. --force overrides; read-only commands only warn.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { evalFormula, formulaVars } from "../lib/formula.mjs";
import { resolveEnv, banner } from "../lib/barkpark-env.mjs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const FORCE = argv.includes("--force");
const ENV = await resolveEnv(argv, { dataset: "cody-poc", datasetKey: "cody" });
const HOST = ENV.host, DATASET = ENV.dataset, TOK = ENV.token, ROOT = ENV.root, CFG = ENV.cfg;
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

// ── read the raw captured literal at one location (used for the in-place rewrite) ──
function rawAt(loc) {
  const m = readFileSync(join(ROOT, loc.file), "utf8").match(new RegExp(loc.pattern));
  return m ? m[1] : null;
}
// canonical form for compare/display. A `list` normalises to compact JSON so a
// code literal `["a", "b"]` and a paper value `["a","b"]` compare equal; scalars
// are their own canonical form.
function canon(b, raw) {
  if (raw == null) return null;
  if (b.vtype === "list") { try { return JSON.stringify(JSON.parse(raw)); } catch { return raw; } }
  if (b.vtype === "expr") return raw.replace(/\s+/g, " ").trim();   // whitespace-insensitive
  return raw;
}
const fmtList = (arr) => "[" + arr.map(x => JSON.stringify(x)).join(", ") + "]";  // code-literal form
const codeValues = (b) => locs(b).map(loc => canon(b, rawAt(loc)));
const codeValue  = (b) => codeValues(b)[0];                       // canonical = first
const driftset   = (b) => [...new Set(codeValues(b).filter(v => v != null))];
const hasDrift   = (b) => driftset(b).length > 1;                 // copies disagree

// ── validate a candidate against the binding's type + constraints ──
function validate(b, raw) {
  const s = String(raw).trim();
  if (b.vtype === "list") {
    let a; try { a = JSON.parse(s); } catch { return { ok: false, why: "not valid JSON" }; }
    if (!Array.isArray(a)) return { ok: false, why: "not a list" };
    if (b.elem === "string" && !a.every(x => typeof x === "string")) return { ok: false, why: "all items must be strings" };
    if (b.min != null && a.length < b.min) return { ok: false, why: `fewer than ${b.min} item(s)` };
    return { ok: true, value: JSON.stringify(a) };   // canonical
  }
  if (b.vtype === "expr") {                           // a FORMULA — logic, validated by trying to evaluate it
    const allowed = b.vars || [];
    const bad = formulaVars(s).filter(v => !allowed.includes(v));
    if (bad.length) return { ok: false, why: `unknown variable(s): ${bad.join(", ")} (allowed: ${allowed.join(", ")})` };
    try { evalFormula(s, Object.fromEntries(allowed.map(v => [v, 2]))); } catch (e) { return { ok: false, why: e.message }; }
    return { ok: true, value: s.replace(/\s+/g, " ").trim() };
  }
  if (b.vtype === "int"   && !/^-?\d+$/.test(s))     return { ok: false, why: `not an int: "${s}"` };
  if (b.vtype === "float" && !/^-?\d*\.?\d+$/.test(s)) return { ok: false, why: `not a number: "${s}"` };
  const n = Number(s);
  if (b.min != null && n < b.min) return { ok: false, why: `${n} < min ${b.min}` };
  if (b.max != null && n > b.max) return { ok: false, why: `${n} > max ${b.max}` };
  return { ok: true, value: s };
}

// ── rewrite the literal at EVERY bound location (the "compile" step) ──
function writeCode(b, newVal) {                          // newVal is canonical (paper value)
  const changed = [];
  const lit = b.vtype === "list" ? fmtList(JSON.parse(newVal)) : newVal;   // code-literal form
  for (const loc of locs(b)) {
    const path = join(ROOT, loc.file);
    const txt = readFileSync(path, "utf8");
    const m = txt.match(new RegExp(loc.pattern));
    if (!m) throw new Error(`anchor not found in ${loc.file}`);
    if (canon(b, m[1]) === newVal) continue;             // already in sync (content-wise)
    writeFileSync(path, txt.replace(m[0], m[0].replace(m[1], lit)));
    if (canon(b, rawAt(loc)) !== newVal) throw new Error(`verify failed in ${loc.file}`);
    changed.push({ file: loc.file, from: m[1], to: lit });
  }
  return changed;                                        // [] if nothing changed
}

const C = { g: "\x1b[32m", y: "\x1b[33m", r: "\x1b[31m", b: "\x1b[1m", d: "\x1b[2m", x: "\x1b[0m" };
const docFields = (b, value) => ({ _type: "tuning", varname: b.name, value: String(value),
  vtype: b.vtype, doc: b.doc, locations: String(locs(b).length) });

// ── codebase-intelligence freshness ────────────────────────────────────────
// Reads the artifacts status.mjs already writes (ASSESS · ENRICH · PUBLISH) — it
// never re-runs the chain. "fully analyzed" = scanned + coverage ≥ the bar in
// barkpark.json + no pending agent work + the published graph is in sync.
function intel() {
  const rd = (p, d) => { const f = join(ROOT, p); return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : d; };
  const tx = (p, d) => { const f = join(ROOT, p); return existsSync(f) ? readFileSync(f, "utf8").trim() : d; };
  const nodesPath = join(ROOT, "tooling/barkpark-sync/nodes.json");
  const scanned = existsSync(nodesPath);
  const raw = scanned ? readFileSync(nodesPath) : null;
  const nodes = scanned ? JSON.parse(raw).nodes.filter((n) => n.kind !== "intention") : [];
  const cov = rd("tooling/research-coverage/coverage-report.json", { pct: 0, stale: 0, new: 0 });
  const intRep = rd("tooling/intentions/intentions-report.json", { files: {}, taxonomy: [] });
  const taxonomyN = (intRep.taxonomy || []).length;
  const nodesHash = scanned ? createHash("sha256").update(raw).digest("hex").slice(0, 16) : "";
  return {
    scanned, fileCount: nodes.length, covPct: cov.pct || 0,
    covPending: (cov.stale || 0) + (cov.new || 0),
    intentPending: taxonomyN === 0 ? nodes.length : nodes.filter((n) => !(n.path in intRep.files)).length,
    staleGroups: +tx("tooling/consistency/batch-count.txt", "0"),
    issuesStale: tx("tooling/consistency/issues-stale.txt", "0") === "1",
    publishNeeded: !!nodesHash && nodesHash !== tx("tooling/barkpark-sync/.last-push-hash", ""),
  };
}

// Assemble the problem list. Empty ⇒ green. `set <scan>` here only the bits that
// matter for trusting a tuning edit: a stale graph means tuning blind.
function preflightProblems(i, drift) {
  const minCov = CFG.intelligence?.minCoveragePct ?? 100;
  const p = [];
  if (!ENV.reachable) p.push(`Barkpark unreachable at ${ENV.host} — ${CFG.setup?.local ? `start it (\`${CFG.setup.local}\`)` : "start it"} or pass --host`);
  if (!i.scanned) p.push(`codebase not scanned — run \`${CFG.intelligence?.scan || "node tooling/status/status.mjs --publish"}\``);
  else {
    if (i.covPct < minCov) p.push(`research coverage ${i.covPct}% < ${minCov}% (${i.covPending} file(s) pending)`);
    if (i.intentPending) p.push(`${i.intentPending} file(s) missing intention tags`);
    if (i.staleGroups) p.push(`${i.staleGroups} consistency group(s) stale`);
    if (i.issuesStale) p.push(`layering/dup analysis stale`);
    if (i.publishNeeded) p.push(`graph changed since last push — the published dataset is behind (run --publish)`);
  }
  if (drift.length) p.push(`${drift.length} bound variable(s) drifted: ${drift.map((b) => b.name).join(", ")}`);
  return p;
}

async function preflight() {
  const i = intel(), drift = BINDINGS.filter(hasDrift), problems = preflightProblems(i, drift);
  console.log(`  ${banner(ENV, "cody")}`);
  console.log(`  ${C.d}intelligence:${C.x} ${i.scanned ? `${i.fileCount} files · coverage ${i.covPct}% · ${i.publishNeeded ? C.y + "graph behind" + C.x : C.g + "graph in sync" + C.x}` : C.r + "not scanned" + C.x}`);
  if (!problems.length) console.log(`  ${C.g}${C.b}✓ GREEN — Barkpark reachable, codebase fully analyzed, no drift${C.x}`);
  else { console.log(`  ${C.r}${C.b}✗ ${problems.length} blocker(s):${C.x}`); for (const m of problems) console.log(`     ${C.r}•${C.x} ${m}`); }
  return { fresh: problems.length === 0, problems };
}

// gate writes: apply/watch BLOCK on a non-green preflight (--force overrides);
// scan/status/set only WARN, since they never rewrite source on disk.
async function gate(cmd) {
  const blocking = cmd === "apply" || cmd === "watch";
  const { fresh, problems } = await preflight();
  if (fresh) return;
  if (blocking && !FORCE) {
    console.error(`\n  ${C.r}${C.b}✗ ${cmd} blocked${C.x} — fix the above or re-run with ${C.b}--force${C.x}. Tuning against a stale graph is tuning blind.`);
    process.exit(1);
  }
  console.error(`  ${C.y}⚠ proceeding with ${problems.length} unresolved warning(s)${FORCE && blocking ? " (--force)" : ""}${C.x}\n`);
}

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

const [cmd, ...rest] = argv;
if (cmd === "preflight") { const { fresh } = await preflight(); process.exit(fresh ? 0 : 1); }
const run = { scan, status, set: () => set(rest[0], rest[1]), apply: () => apply(rest.includes("--write")), watch }[cmd];
if (!run) { console.error("usage: cody.mjs preflight | scan | status | set <var> <value> | apply [--write] | watch  [--host URL] [--dataset DS] [--force]"); process.exit(2); }
// every command runs the gate first: blocks apply/watch on a stale graph, warns elsewhere.
await gate(cmd);
await run();
