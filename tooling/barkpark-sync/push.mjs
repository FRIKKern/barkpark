#!/usr/bin/env node
// Push the codebase graph into a LOCAL Barkpark: one paper per file, with the
// file content as PortableDoc blocks (→ /papers/:slug), the quality metrics as
// fields, and dependency references (→ content graph edges).
//   push.mjs [--limit N] [--host URL]
// Sequence: createOrReplace all → publish all (refs resolve) → ingest blocks.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const argv = process.argv.slice(2);
const valOf = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };
const HOST = valOf("--host", "http://localhost:4000");
const LIMIT = +valOf("--limit", "0");
// DEFAULT to the isolated `codebase` dataset — NEVER production. A bare
// `push.mjs` (no --dataset) used to leak per-file code papers into production;
// the separation is a hard requirement (graph-view.mjs + tasks.mjs already
// default to codebase). Pass --dataset explicitly to target anything else.
const DATASET = valOf("--dataset", "codebase");
if (DATASET === "production") { console.error("[push] refusing to publish code papers into 'production' — pass a non-production --dataset (the isolated 'codebase' is the default)."); process.exit(2); }
const DEV = "barkpark-dev-token", INGEST = "paperflow-dev-ingest-token";

const all = JSON.parse(readFileSync(join(HERE, "nodes.json"), "utf8")).nodes;
const taxPath = join(ROOT, "tooling/intentions/intentions-report.json");
const TAX = existsSync(taxPath) ? Object.fromEntries(JSON.parse(readFileSync(taxPath, "utf8")).taxonomy.map(t => [t.id, t.title])) : {};
const nodes = LIMIT ? all.slice(0, LIMIT) : all;
const ids = new Set(nodes.map(n => n.id));
const LANG = { ex: "elixir", exs: "elixir", go: "go", ts: "typescript", tsx: "tsx", js: "javascript", mjs: "javascript", jsx: "jsx", heex: "html", eex: "html", sh: "bash" };

async function post(path, token, body) {
  const r = await fetch(HOST + path, { method: "POST", headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const t = await r.text();
  return { ok: r.ok, status: r.status, body: t };
}
const chunk = (a, n) => { const o = []; for (let i = 0; i < a.length; i += n) o.push(a.slice(i, i + n)); return o; };
const f = (n) => n.fields;
const metricsLine = (n) => `importance ${f(n).importance} · reach ${f(n).reach ?? "?"} · priority ${f(n).priority} · ${f(n).sizeClass} ${f(n).tokens}tok/${f(n).loc}loc · churn ${f(n).churn} · depends-on ${n.deps.length} · depended-on-by ${f(n).dependentCount ?? 0}${f(n).seam ? " · 🔗seam" : ""} · owners ${f(n).authorCount ?? "?"} (top ${f(n).primaryAuthorShare ?? "?"}%) · test ${f(n).testScore ?? "?"} · defect ${f(n).defectDensity} · consistency ${f(n).consistency}`;

// ---- phase 0: register the paper schema for this dataset ----
// The content-edge extractor keys on list_schemas(dataset) to find reference
// fields; without a `paper` schema in this dataset, the graph has 0 edges.
console.error(`[push] ${nodes.length} nodes → ${HOST} (dataset ${DATASET})`);
{
  const schema = { name: "paper", title: "Papers", fields: [
    { name: "title", type: "string" }, { name: "event_type", type: "string" },
    { name: "source_doc", type: "string" }, { name: "goal_id", type: "string" },
    { name: "related", type: "arrayOf", of: { type: "reference", refType: "paper" } },
    // typed reference fields (Sanity-style) — each relationship is its own navigable reference set
    { name: "dependencies", type: "arrayOf", of: { type: "reference", refType: "paper" } },
    { name: "intentions", type: "arrayOf", of: { type: "reference", refType: "paper" } },
  ] };
  const r = await post(`/v1/schemas/${DATASET}`, DEV, schema);
  console.error(r.ok ? `  registered paper schema for ${DATASET}` : `  paper schema register: ${r.status} (may already exist) ${r.body.slice(0, 80)}`);
}

// ---- phase 1a: create ALL bare (so every reference target exists) ----
const doc = (n, deps, ints) => ({ createOrReplace: { _type: "paper", _id: n.id, title: n.path, source_doc: n.path, event_type: (n.kind === "intention" ? "intention" : f(n).stack), goal_id: `imp:${f(n).importance ?? 0}`, related: [], dependencies: deps || [], intentions: ints || [] } });
let created = 0;
for (const ck of chunk(nodes, 40)) {
  const r = await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: ck.map(n => doc(n, [], [])) });
  if (!r.ok) { console.error(`  create chunk failed ${r.status}: ${r.body.slice(0, 200)}`); process.exit(1); }
  created += ck.length;
}
console.error(`  created ${created}`);
// ---- phase 1b: set TYPED references — dependencies + intentions as separate fields ----
const depRefs = (n) => (n.deps || []).filter(d => ids.has(d));
const intRefs = (n) => (n.intentRefs || []).filter(d => ids.has(d));
let linked = 0;
for (const ck of chunk(nodes.filter(n => depRefs(n).length || intRefs(n).length), 40)) {
  const r = await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: ck.map(n => doc(n, depRefs(n), intRefs(n))) });
  if (!r.ok) { console.error(`  relink chunk failed ${r.status}: ${r.body.slice(0, 200)}`); process.exit(1); }
  linked += ck.length;
}
console.error(`  linked typed references on ${linked} nodes (dependencies + intentions fields)`);

// ---- phase 2: publish (materializes references → edges) ----
let pub = 0;
for (const ck of chunk(nodes, 40)) {
  const mutations = ck.map(n => ({ publish: { id: n.id, type: "paper" } }));
  const r = await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations });
  if (!r.ok) { console.error(`  publish chunk failed ${r.status}: ${r.body.slice(0, 200)}`); process.exit(1); }
  pub += ck.length;
}
console.error(`  published ${pub}`);

// ---- phase 3: ingest content blocks (per doc) ----
// Bulldocs paper ingest is now dataset-aware (the `dataset` param is honored),
// so content blocks land in the requested dataset. --no-content opts out.
const SKIP_CONTENT = argv.includes("--no-content");
let ing = 0, ingFail = 0;
if (SKIP_CONTENT) console.error(`  [skip] content ingest (--no-content)`);
for (const n of (SKIP_CONTENT ? [] : nodes)) {
  let blocks;
  if (n.kind === "intention" || f(n).kind === "intention") {
    // intention HUB paper — the objective + every file advancing it
    blocks = [
      { type: "heading", level: 1, text: `🎯 ${f(n).title}` },
      { type: "paragraph", content: [{ type: "text", value: `${f(n).scale === "epic" ? "Epic intention" : "Intention"} · ${f(n).members} files advance this.` }] },
      { type: "paragraph", content: [{ type: "text", value: f(n).description || "" }] },
      { type: "heading", level: 2, text: "Files advancing this intention" },
      { type: "code", language: "text", value: n.content.split("Files advancing")[1]?.split(":").slice(1).join(":").trim() || "" },
    ];
  } else {
    const lang = LANG[f(n).ext] || "text";
    const depsList = n.deps.length ? n.deps.map(d => "→ " + (all.find(x => x.id === d)?.path || d)).join("\n") : "(no resolved dependencies)";
    const ints = (f(n).intentions || []).map(id => "🎯 " + (TAX[id] || id)).join("\n") || "(none)";
    blocks = [
      { type: "heading", level: 1, text: n.path },
      { type: "paragraph", content: [{ type: "text", value: metricsLine(n) }] },
      { type: "paragraph", content: [{ type: "text", value: (f(n).role || "") + (f(n).description ? " — " + f(n).description : "") }] },
      { type: "heading", level: 2, text: `Reach ${f(n).reach ?? "?"}/100 (transitive dependents) · why reusable` },
      { type: "paragraph", content: [{ type: "text", value: f(n).why || "(no description)" }] },
      { type: "heading", level: 2, text: `Intentions it serves (${(f(n).intentions || []).length})` },
      { type: "code", language: "text", value: ints },
      { type: "heading", level: 2, text: `Depends on (${n.deps.length})` },
      { type: "code", language: "text", value: depsList },
      { type: "heading", level: 2, text: `Depended on by (${f(n).dependentCount ?? 0})` },
      { type: "code", language: "text", value: (f(n).dependents || []).slice(0, 50).map(p => "← " + p).join("\n") + ((f(n).dependents || []).length > 50 ? `\n… (+${f(n).dependents.length - 50} more)` : "") || "(nothing in the graph depends on this)" },
      { type: "heading", level: 2, text: `Git history (${f(n).git?.commitCount ?? 0} commits · ${f(n).git?.authors?.length ?? 0} authors · ${f(n).git?.firstDate || "?"} → ${f(n).git?.lastDate || "?"})` },
      { type: "code", language: "text", value: (f(n).git?.commits || []).map(c => `${c.date}  ${c.hash}  ${(c.author || "").split(" ")[0]}  ${c.subject}`).join("\n") || "(no history)" },
      { type: "heading", level: 2, text: "Source" },
      { type: "code", language: lang, value: n.content || "(empty)" },
    ];
  }
  const r = await post(`/v1/plugins/bulldocs/papers`, INGEST, { slug: n.id, dataset: DATASET, style: "article", blocks, source_doc: n.path, event_type: (n.kind === "intention" ? "intention" : f(n).stack), goal_id: `imp:${f(n).importance ?? 0}` });
  if (r.ok) ing++; else { ingFail++; if (ingFail <= 3) console.error(`  ingest ${n.id} failed ${r.status}: ${r.body.slice(0, 160)}`); }
}
console.error(`  ingested blocks: ${ing} ok, ${ingFail} failed`);
console.error(`[push] done. View: ${HOST}/papers/${nodes[0].id}  ·  graph: ${HOST}/v1/graph/${nodes.find(n=>n.deps.length)?.id || nodes[0].id}`);
