#!/usr/bin/env node
// Push the codebase graph into a LOCAL Barkpark: one paper per file, with the
// file content as PortableDoc blocks (→ /papers/:slug), the quality metrics as
// fields, and dependency references (→ content graph edges).
//   push.mjs [--limit N] [--host URL] [--nodes PATH] [--dry-run]
// Sequence: gate → createOrReplace all → publish all (refs resolve) → ingest blocks.
//
// THE GATE. Nothing is published unless every node carries the evidence tier
// the upstream passes already compute (see provenance.mjs for why that was not
// true before). A node missing it, or one whose body would put an agent's L6
// opinion in the same register as a git commit count, exits 2 — the same hard
// refusal the `--dataset production` guard uses, because it is the same class
// of mistake: a durable write that a reader cannot walk back.
//
// --dry-run gates and renders every body and posts nothing, so the refusal can
// be exercised against a real nodes.json without a server.

import { readFileSync, existsSync } from "node:fs";
import { dirname, join, extname, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveEnv, banner, flag } from "../lib/barkpark-env.mjs";
import { gateNodes, checkRendered, renderFileBlocks, renderIntentionBlocks, GATE_VERSION } from "./provenance.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
// Resolve the target through the shared chain (flags > BARKPARK_* env >
// barkpark.json > localhost). DEFAULT to the isolated `codebase` dataset —
// NEVER production. A bare push used to leak per-file code papers into prod; the
// separation is a hard requirement (graph-view.mjs + tasks.mjs default the same).
const ENV = await resolveEnv(argv, { dataset: "codebase", datasetKey: "codebase" });
const HOST = ENV.host, DATASET = ENV.dataset, ROOT = ENV.root;
const LIMIT = +flag(argv, "--limit", "0");
const DRY_RUN = argv.includes("--dry-run");
console.error(banner(ENV, "push"));
if (DATASET === "production") { console.error("[push] refusing to publish code papers into 'production' — pass a non-production --dataset (the isolated 'codebase' is the default)."); process.exit(2); }
const DEV = ENV.token, INGEST = process.env.BARKPARK_INGEST_TOKEN || "barkpark-dev-ingest-token";

const NODES_ARG = flag(argv, "--nodes", null);
const NODES_PATH = NODES_ARG ? (isAbsolute(NODES_ARG) ? NODES_ARG : join(process.cwd(), NODES_ARG)) : join(HERE, "nodes.json");
const all = JSON.parse(readFileSync(NODES_PATH, "utf8")).nodes;
const taxPath = join(ROOT, "tooling/intentions/intentions-report.json");
const TAX = existsSync(taxPath) ? Object.fromEntries(JSON.parse(readFileSync(taxPath, "utf8")).taxonomy.map(t => [t.id, t.title])) : {};
const nodes = LIMIT ? all.slice(0, LIMIT) : all;
const ids = new Set(nodes.map(n => n.id));
const LANG = { ex: "elixir", exs: "elixir", go: "go", ts: "typescript", tsx: "tsx", js: "javascript", mjs: "javascript", jsx: "jsx", heex: "html", eex: "html", sh: "bash" };

async function post(path, token, body) {
  // 429s honor Retry-After (server sends retry_after seconds) instead of aborting
  // a multi-minute push mid-sequence; anything else returns to the caller as before.
  for (let attempt = 0; ; attempt++) {
    let r;
    try {
      r = await fetch(HOST + path, { method: "POST", headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    } catch (e) {
      // transient socket drop (ECONNRESET et al) under a long write storm — retry, don't abort the push
      if (attempt < 5) { await new Promise((res) => setTimeout(res, 1000 * (attempt + 1))); continue; }
      throw e;
    }
    const t = await r.text();
    if (r.status === 429 && attempt < 5) {
      const wait = (+r.headers.get("retry-after") || 1) * 1000 + 250;
      await new Promise((res) => setTimeout(res, wait));
      continue;
    }
    return { ok: r.ok, status: r.status, body: t };
  }
}
const chunk = (a, n) => { const o = []; for (let i = 0; i < a.length; i += n) o.push(a.slice(i, i + n)); return o; };
const f = (n) => n.fields;
// The document-level stamp carries the basis too, so a query can tell a blended
// score from a deterministic prior without opening the body. The `imp:` prefix
// is kept because it is the census handle every blast-radius sweep greps for.
const goalId = (n) => `imp:${f(n).importanceBasis || "prior"}:${f(n).importance ?? 0}`;

// ---- the provenance gate: refuse BEFORE the first mutation ----
// This runs ahead of the schema register so a corpus that cannot be labelled
// never reaches the server at all, not even as bare documents.
{
  const gate = gateNodes(nodes);
  if (!gate.ok) {
    console.error(`[push] REFUSING to publish: ${gate.failures.length}/${gate.checked} node(s) carry no usable evidence provenance (gate v${GATE_VERSION}).`);
    console.error(`[push] the pipeline computes tier/prior/agentCrit/votes/agreement/confidence upstream; a node without them would publish an agent judgment as a measured fact.`);
    for (const x of gate.failures.slice(0, 10)) console.error(`  ✗ ${x.path || x.id}: ${x.reasons.join(", ")}`);
    if (gate.failures.length > 10) console.error(`  … (+${gate.failures.length - 10} more)`);
    console.error(`[push] fix upstream, then re-run: node tooling/file-importance/merge.mjs && node tooling/research-coverage/coverage.mjs && node tooling/barkpark-sync/generate.mjs`);
    process.exit(2);
  }
  console.error(`  provenance gate: ${gate.checked} node(s) labelled (gate v${GATE_VERSION})`);
}

// ---- the body renderer, shared by --dry-run and the real ingest ----
// Every body goes back through checkRendered: the gate above judges the DATA,
// this judges the ARTEFACT, so a later edit that re-fuses the two registers or
// re-prints a prior under the word "importance" is refused even when the node
// itself is well-formed.
function bodyFor(n) {
  const isInt = n.kind === "intention" || f(n).kind === "intention";
  const blocks = isInt ? renderIntentionBlocks(n) : renderFileBlocks(n, {
    lang: LANG[f(n).ext] || "text",
    depsList: n.deps.length ? n.deps.map(d => "→ " + (all.find(x => x.id === d)?.path || d)).join("\n") : "(no resolved dependencies)",
    intentions: (f(n).intentions || []).map(id => "🎯 " + (TAX[id] || id)).join("\n") || "(none)",
  });
  const bad = checkRendered(n, blocks);
  if (bad.length) {
    console.error(`[push] REFUSING to publish: rendered body for ${n.path || n.id} mixes registers — ${bad.join(", ")} (gate v${GATE_VERSION}).`);
    process.exit(2);
  }
  return blocks;
}

if (DRY_RUN) {
  let n0 = null;
  for (const n of nodes) { const b = bodyFor(n); if (!n0) n0 = { n, b }; }
  console.error(`[push] --dry-run: ${nodes.length} node(s) gated and rendered, 0 written to ${HOST}.`);
  if (n0) {
    console.error(`[push] sample body — ${n0.n.path}:`);
    for (const b of n0.b.slice(0, 6)) console.error(`  ${b.type}: ${(b.text ?? (b.content || []).map(c => c.value).join("")).slice(0, 200)}`);
  }
  process.exit(0);
}

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
const doc = (n, deps, ints) => ({ createOrReplace: { _type: "paper", _id: n.id, title: n.path, source_doc: n.path, event_type: (n.kind === "intention" ? "intention" : f(n).stack), goal_id: goalId(n), related: [], dependencies: deps || [], intentions: ints || [] } });
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
  const blocks = bodyFor(n);
  const r = await post(`/v1/plugins/bulldocs/papers`, INGEST, { slug: n.id, dataset: DATASET, style: "article", blocks, source_doc: n.path, event_type: (n.kind === "intention" ? "intention" : f(n).stack), goal_id: goalId(n) });
  if (r.ok) ing++; else { ingFail++; if (ingFail <= 3) console.error(`  ingest ${n.id} failed ${r.status}: ${r.body.slice(0, 160)}`); }
}
console.error(`  ingested blocks: ${ing} ok, ${ingFail} failed`);
console.error(`[push] done. View: ${HOST}/papers/${nodes[0].id}  ·  graph: ${HOST}/v1/graph/${nodes.find(n=>n.deps.length)?.id || nodes[0].id}`);
