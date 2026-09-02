#!/usr/bin/env node
// tasks — blend Barkpark TASKS into the codebase-intelligence graph as a THIRD
// node layer, so files, intentions, AND tasks live in one web.
//
// THE INSIGHT: a task advances an INTENTION by changing FILES. Two independent
// sources of "which files a task touches" let us cross-validate scope:
//   ACTUAL    — commit messages carry the task id, e.g. "(cqv2-p1)".
//               git log --all --grep="(<id>)" --name-only → files it changed.
//   PREDICTED — the task's intention(s) → scope's file set (the files it SHOULD
//               touch). A task INHERITS the intentions of the files it changed,
//               so the prediction is grounded in real history, not a guess.
//
// Cross-validation per task (mirrors cochange's three-layer cross-validator):
//   predicted ∩ actual → on-target      (the task hit its scope)
//   predicted − actual → scoped-untouched (in-scope files it left alone)
//   actual − predicted → scope-creep      (surprise files outside the scope)
//
//   node tooling/tasks/tasks.mjs            → tasks-report.json + console summary
//   node tooling/tasks/tasks.mjs publish    → also publish task nodes into the
//                                             `codebase` Barkpark dataset
//   node tooling/tasks/tasks.mjs --host URL --dataset codebase
//
// Dependency-free. Derived outputs gitignored. Reads committed git history + the
// other passes' reports + Barkpark over HTTP; never touches api/ source.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveEnv, banner, flag, fetchBackpressureAware } from "../lib/barkpark-env.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const e = (s = "") => process.stderr.write(s + "\n");

const argv = process.argv.slice(2);
const PUBLISH = argv.includes("publish");
const ENV = await resolveEnv(argv, { dataset: "codebase", datasetKey: "codebase" });
const HOST = ENV.host, DATASET = ENV.dataset;
const SRC_DATASET = flag(argv, "--src-dataset", "production"); // where the tasks live
const LIMIT = +flag(argv, "--limit", "200");
const DEV = ENV.token, INGEST = process.env.BARKPARK_INGEST_TOKEN || "barkpark-dev-ingest-token";
e(banner(ENV, "tasks"));

// ──────────── load the codebase graph + the quality reports ────────────
const graph = rd("tooling/barkpark-sync/nodes.json", { nodes: [] });
const codeNodes = graph.nodes.filter((n) => n.kind !== "intention");
const inGraph = new Set(codeNodes.map((n) => n.path));
const idOf = (p) => p.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const nodeByPath = new Map(codeNodes.map((n) => [n.path, n]));

// file → intention hub ids (bare slugs) it advances, from the generated graph
const fileIntents = new Map(codeNodes.map((n) => [n.path, (n.fields?.intentions || [])]));
// intention hub id (bare) → member file paths — the "predicted scope" of an intention
const intentMembers = new Map();
for (const n of codeNodes) for (const id of (n.fields?.intentions || [])) {
  if (!intentMembers.has(id)) intentMembers.set(id, new Set());
  intentMembers.get(id).add(n.path);
}
// intention hub id (bare) → title, from the taxonomy
const tax = rd("tooling/intentions/intentions-report.json", { taxonomy: [] }).taxonomy;
const intentTitle = Object.fromEntries(tax.map((t) => [t.id, t.title]));

// ──────────── triage scope for OPEN tasks (title → intention match) ────────────
// A committed task scopes itself from the files it touched. An OPEN task has no
// commits yet — so we ground its predicted scope in the same taxonomy by matching
// its title's tokens against intention titles + ids (the slug carries the words).
const STOP = new Set("the a an of to and or for in on with by into from this that fix feat add remove update refactor phase build review chore test docs".split(" "));
const toks = (s) => [...new Set(String(s).toLowerCase().match(/[a-z0-9]+/g)?.filter((w) => w.length > 2 && !STOP.has(w)) || [])];
const intentTokens = new Map(tax.map((t) => [t.id, new Set([...toks(t.title), ...toks(t.id)])]));
function matchIntentions(title) {
  const tt = toks(title); if (!tt.length) return [];
  const scored = [];
  for (const [id, set] of intentTokens) {
    const hits = tt.filter((w) => set.has(w)).length;
    if (hits) scored.push({ id, score: hits });
  }
  scored.sort((a, b) => b.score - a.score);
  // prefer PRECISE multi-token matches; a single common token (one hit) is weak
  // signal — fall back to just the best one rather than dragging in 3 big
  // intentions on a coincidental word. Keeps title-matched scope tight.
  const strong = scored.filter((s) => s.score >= 2);
  return (strong.length ? strong : scored.slice(0, 1)).slice(0, 2).map((s) => s.id);
}

// per-file leverage: the combined `priority` composite already = reach × severity ×
// defect-amp × untested-boost (clean roots, fit-weighted). Σ over a file set is the
// task's predicted blast-impact. defect-amp alone drives the calibration-on-tasks score.
const filePriority = (p) => (comb[p]?.priority || 0);
const fileDefectAmp = (p) => { const c = comb[p] || {}, rk = risk[p] || {}; const untested = 1 + (100 - (c.testScore ?? rk.testScore ?? 100)) / 100; return (c.reach || 0) * (1 + (rk.defectDensity || 0)) * untested; };

// ──────────── churn provenance: who drives a hotspot ────────────
// For a file, sum git churn (added+deleted lines) per author → the share owned by
// the top author. A hotspot concentrated in one author is a bus-factor + review
// blind-spot; spread churn is safer. Pure git mining, no agent.
function churnProvenance(path) {
  let out;
  try { out = git(["log", "--no-merges", "--numstat", "--pretty=format:\x01%an", "--", path]); }
  catch { return null; }
  const byAuthor = {}; let total = 0, author = "";
  for (const line of out.split("\n")) {
    if (line.startsWith("\x01")) { author = line.slice(1); continue; }
    const m = line.match(/^(\d+|-)\t(\d+|-)\t/);
    if (!m || !author) continue;
    const churn = (m[1] === "-" ? 0 : +m[1]) + (m[2] === "-" ? 0 : +m[2]);
    byAuthor[author] = (byAuthor[author] || 0) + churn; total += churn;
  }
  if (!total) return null;
  const ranked = Object.entries(byAuthor).sort((a, b) => b[1] - a[1]);
  const [topAuthor, topChurn] = ranked[0];
  return { topAuthor, share: Math.round((topChurn / total) * 100), authors: ranked.length, totalChurn: total };
}

// impact/risk roots from the codebase intelligence
const comb = Object.fromEntries(rd("tooling/combined/combined-report.json", { rows: [] }).rows.map((r) => [r.path, r]));
const risk = rd("tooling/risk/risk-report.json", { files: {} }).files || {};

// tracked source files (so actualFiles ignores deleted paths / docs the suite excludes)
const tracked = new Set(git(["ls-files"]).split("\n").filter(Boolean));

// ──────────── pull the tasks from Barkpark ────────────
async function fetchTasks() {
  const url = `${HOST}/v1/data/query/${SRC_DATASET}/task?perspective=raw&limit=${LIMIT}`;
  // A 429 IS NOT "IS BARKPARK UP". Measured 2026-09-01 under this fleet's own
  // load: the ledger answered this exact read with 429 retry_after=1 and the
  // line below reported a one-second throttle as a dead server, sending the
  // reader to check a host that was healthy. The backoff is bounded and the
  // two conditions now say different things — see barkpark-env.mjs.
  const r = await fetchBackpressureAware(url, { headers: { Authorization: "Bearer " + DEV } });
  if (r.throttled) {
    e(`[tasks] the ledger is RATE LIMITING this client (HTTP 429) — ${r.gaveUp}.`);
    e(`[tasks] Barkpark at ${HOST} is HEALTHY and busy; this is backpressure, not an outage. Re-run when the fleet is quieter, or reduce the request rate.`);
    process.exit(2);
  }
  if (!r.ok) { e(`[tasks] task query failed ${r.status} — is Barkpark up at ${HOST}?`); process.exit(2); }
  const j = JSON.parse(r.body);
  const arr = j.result?.documents || j.documents || (Array.isArray(j.result) ? j.result : Array.isArray(j) ? j : []);
  // real tasks only: kind:task / kind:phase / kind:epic — skip events and anything draft-shaped.
  return arr.filter((t) => t && t._id && (t.kind === "task" || (t.labels || []).some((l) => /^kind:(task|phase|epic|goal)$/.test(l)) || t.kind === undefined && t.title));
}

// ──────────── per-task ACTUAL files via commit-id join ────────────
function actualFilesFor(id) {
  // git log --all --grep="(<id>)" --name-only — the parenthesised task-id convention.
  let out;
  try { out = git(["log", "--all", `--grep=(${id})`, "--name-only", "--pretty=format:\x01"]); }
  catch { return { files: [], commits: 0 }; }
  const files = new Set();
  let commits = 0;
  for (const line of out.split("\n")) {
    if (line.startsWith("\x01")) { commits++; continue; }
    const p = line.trim();
    if (p && tracked.has(p)) files.add(p);
  }
  return { files: [...files].sort(), commits };
}

// ──────────── impact + risk from the codebase intelligence ────────────
function scoreFiles(files) {
  let reach = 0, hotspot = 0;
  const fragile = [];
  for (const p of files) {
    const c = comb[p] || {}, rk = risk[p] || {};
    reach += c.reach || 0;
    hotspot += c.hotspot || 0;
    // fragile = touched a critical-untested file, or a defect-dense file with no test
    if ((c.criticalUntested || 0) > 0 || ((rk.defectDensity || 0) > 0 && !rk.hasTest)) fragile.push(p);
  }
  return { impact: reach, risk: hotspot, fragileFiles: fragile, fragile: fragile.length > 0 };
}

function build(tasks) {
  // task tree (parent_id) → a parent task ROLLS UP its descendants' file evidence
  // (an epic carries 0 commits of its own; its phases carry them).
  const parentOf = {};
  for (const t of tasks) { const pid = t.parent_id ?? t.content?.parent_id; if (pid) parentOf[t._id] = String(pid).replace(/^drafts\./, ""); }
  const childrenOf = {};
  for (const [c, p] of Object.entries(parentOf)) (childrenOf[p] ||= []).push(c);
  // visited-set: a parent_id cycle in live task data must degrade to a warning, not an infinite walk
  const cyclic = new Set();
  const descendants = (id) => { const o = [], seen = new Set([id]), stack = [...(childrenOf[id] || [])]; while (stack.length) { const x = stack.pop(); if (seen.has(x)) { cyclic.add(x); continue; } seen.add(x); o.push(x); for (const c of (childrenOf[x] || [])) stack.push(c); } return o; };
  const rawById = {}; for (const t of tasks) rawById[t._id] = actualFilesFor(t._id);

  const out = [];
  for (const t of tasks) {
    const id = t._id;
    const ids = [id, ...descendants(id)];
    const fileSet = new Set(); let commits = 0;
    for (const x of ids) { const r = rawById[x] || (rawById[x] = actualFilesFor(x)); for (const f of r.files) fileSet.add(f); commits += r.commits; }
    const actualFiles = [...fileSet].sort();
    const rolledUp = ids.length > 1;

    // ONLY graph-node files can be cross-validated; docs/.gitignore/SKILL.md aren't
    // nodes (carry no intentions) → can never be "predicted", so they're reported
    // separately, not counted as scope-creep.
    const actualGraph = actualFiles.filter((p) => inGraph.has(p));
    const nonGraphFiles = actualFiles.filter((p) => !inGraph.has(p));

    // a task inherits the intentions of the (graph) files it changed
    const intentSet = new Set();
    for (const p of actualGraph) for (const i of (fileIntents.get(p) || [])) intentSet.add(i);
    const intentions = [...intentSet].sort();
    // predicted scope source: committed intentions (grounded) for tasks with
    // file evidence; else match the TITLE against the taxonomy so OPEN, unstarted
    // tasks can still be triaged. predictedVia records which path was taken.
    let scopeIntents = intentions, predictedVia = intentions.length ? "commits" : "none";
    if (!intentions.length) { const m = matchIntentions(t.title || id); if (m.length) { scopeIntents = m; predictedVia = "title"; } }
    // predicted = union of every member file of the scope intentions
    const predSet = new Set();
    for (const i of scopeIntents) for (const p of (intentMembers.get(i) || [])) predSet.add(p);
    const predictedFiles = [...predSet].sort();

    const actualGraphSet = new Set(actualGraph);
    const onTarget = actualGraph.filter((p) => predSet.has(p));            // predicted ∩ actual (graph)
    const scopedUntouched = predictedFiles.filter((p) => !actualGraphSet.has(p)); // predicted − actual
    const scopeCreep = actualGraph.filter((p) => !predSet.has(p));         // SOURCE outside scope (real creep)

    const { impact, risk: riskScore, fragileFiles, fragile } = scoreFiles(actualGraph);

    // calibration-on-tasks: a forward-looking defect-risk for the task. Score the
    // files it WILL touch (predicted scope for open tasks, the files it DID touch
    // for committed ones) by the same defect-amp the file calibration uses. A
    // HEURISTIC composite (too few closed tasks to train a model yet — sharpens as
    // the (task-id) history grows); ranks open work, doesn't certify it.
    const riskScopeFiles = actualGraph.length ? actualGraph : predictedFiles;
    const predictedImpact = Math.round(predictedFiles.reduce((s, p) => s + filePriority(p), 0));
    const defectRisk = Math.round(riskScopeFiles.reduce((s, p) => s + fileDefectAmp(p), 0));
    const open = !/^(done|closed|cancelled)$/.test((t.lifecycle_status || t.content?.lifecycle_status || t.status || ""));

    out.push({
      id, title: t.title || id,
      status: t.lifecycle_status || t.content?.lifecycle_status || t.status || "",
      kind: (t.labels || []).find((l) => l.startsWith("kind:"))?.slice(5) || t.kind || "task",
      commits, rolledUp, open,
      actualFiles, nonGraphFiles, predictedFiles, intentions, predictedVia,
      impact, risk: riskScore, fragile, fragileFiles,
      predictedImpact, defectRisk,
      onTarget, scopedUntouched, scopeCreep,
    });
  }
  // tasks with real file evidence first, then by impact
  out.sort((a, b) => (b.actualFiles.length - a.actualFiles.length) || (b.impact - a.impact) || a.id.localeCompare(b.id));
  if (cyclic.size) process.stderr.write(`  ⚠ parent_id CYCLE in task data through: ${[...cyclic].join(", ")} — rollups near the cycle are partial; fix the ledger\n`);
  return out;
}

// ──────────── publish task nodes into the codebase dataset ────────────
async function post(path, token, body) {
  const r = await fetch(HOST + path, { method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return { ok: r.ok, status: r.status, body: await r.text() };
}

async function publish(report) {
  const tasks = report.tasks.filter((t) => t.actualFiles.length); // only tasks with real file evidence become nodes
  e(`[tasks] publishing ${tasks.length} task node(s) → ${HOST} (dataset ${DATASET})`);

  // schema already carries dependencies + intentions reference fields (push.mjs
  // registered it); re-register is idempotent and harmless.
  {
    const schema = { name: "paper", title: "Papers", fields: [
      { name: "title", type: "string" }, { name: "event_type", type: "string" },
      { name: "source_doc", type: "string" }, { name: "goal_id", type: "string" },
      { name: "related", type: "arrayOf", of: { type: "reference", refType: "paper" } },
      { name: "dependencies", type: "arrayOf", of: { type: "reference", refType: "paper" } },
      { name: "intentions", type: "arrayOf", of: { type: "reference", refType: "paper" } },
    ] };
    const r = await post(`/v1/schemas/${DATASET}`, DEV, schema);
    e(r.ok ? `  paper schema ok for ${DATASET}` : `  paper schema: ${r.status} (likely exists)`);
  }

  const slugOf = (t) => `task-${t.id}`;
  // edges only point at papers that EXIST in the codebase dataset (in-graph files +
  // intention hubs). .md / .gitignore / SKILL.md are tracked but not graph nodes.
  const fileRef = (p) => inGraph.has(p) ? idOf(p) : null;
  const intentRef = (i) => `intent-${i}`;
  const depRefsOf = (t) => [...new Set(t.actualFiles.map(fileRef).filter(Boolean))];
  const intentRefsOf = (t) => t.intentions.map(intentRef);

  const doc = (t, deps, ints) => ({ createOrReplace: { _type: "paper", _id: slugOf(t), title: t.title,
    source_doc: t.id, event_type: "task", goal_id: t.status || "", dependencies: deps || [], intentions: ints || [] } });

  // phase 1a — create bare so every target resolves
  for (const t of tasks) { const r = await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: [doc(t, [], [])] }); if (!r.ok) { e(`  create ${t.id} failed ${r.status}: ${r.body.slice(0, 160)}`); } }
  e(`  created ${tasks.length}`);

  // phase 2 — publish FIRST (before references) so the materialiser sees live targets
  for (const t of tasks) await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: [{ publish: { id: slugOf(t), type: "paper" } }] });
  e(`  published ${tasks.length}`);

  // phase 3 — set typed references, then re-publish to materialise the edges
  let linked = 0;
  for (const t of tasks) {
    const deps = depRefsOf(t), ints = intentRefsOf(t);
    const r = await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: [doc(t, deps, ints)] });
    if (r.ok) { await post(`/v1/data/mutate/${DATASET}`, DEV, { mutations: [{ publish: { id: slugOf(t), type: "paper" } }] }); linked++; }
    else e(`  link ${t.id} failed ${r.status}: ${r.body.slice(0, 160)}`);
  }
  e(`  linked typed references (dependencies + intentions) on ${linked} task node(s)`);

  // phase 4 — ingest the body content (dataset-aware Bulldocs ingest)
  let ing = 0, ingFail = 0;
  for (const t of tasks) {
    const intLines = t.intentions.map((i) => `🎯 ${intentTitle[i] || i}`).join("\n") || "(none inferred)";
    const blocks = [
      { type: "heading", level: 1, text: `📋 ${t.title}` },
      { type: "paragraph", content: [{ type: "text", value: `Task ${t.id} · ${t.kind} · status ${t.status || "?"} · ${t.commits} commit(s) carry the task id · impact ${t.impact} · risk ${t.risk}${t.fragile ? " · ⚠️ touched fragile files" : ""}` }] },
      { type: "heading", level: 2, text: `Intentions advanced (${t.intentions.length})` },
      { type: "code", language: "text", value: intLines },
      { type: "heading", level: 2, text: `Files it actually changed (${t.actualFiles.length})` },
      { type: "code", language: "text", value: t.actualFiles.map((p) => (inGraph.has(p) ? "→ " : "· ") + p).join("\n") || "(no committed files carry this task id)" },
      { type: "heading", level: 2, text: `Scope cross-validation (predicted ${t.predictedFiles.length})` },
      { type: "code", language: "text", value:
        `on-target  (predicted ∩ actual): ${t.onTarget.length}\n` +
        t.onTarget.map((p) => "  ✓ " + p).join("\n") +
        `\n\nscope-creep (actual − predicted): ${t.scopeCreep.length}\n` +
        t.scopeCreep.map((p) => "  ! " + p).join("\n") +
        `\n\nscoped-untouched (predicted − actual): ${t.scopedUntouched.length}\n` +
        t.scopedUntouched.slice(0, 30).map((p) => "  ◦ " + p).join("\n") +
        (t.scopedUntouched.length > 30 ? `\n  … (+${t.scopedUntouched.length - 30} more)` : "") },
      ...(t.fragile ? [
        { type: "heading", level: 2, text: `⚠️ Fragile files touched (${t.fragileFiles.length})` },
        { type: "code", language: "text", value: t.fragileFiles.map((p) => "  ⚠ " + p).join("\n") },
      ] : []),
    ];
    const r = await post(`/v1/plugins/bulldocs/papers`, INGEST, { slug: slugOf(t), dataset: DATASET, style: "article", blocks, source_doc: t.id, event_type: "task", goal_id: t.status || "" });
    if (r.ok) ing++; else { ingFail++; if (ingFail <= 3) e(`  ingest ${t.id} failed ${r.status}: ${r.body.slice(0, 160)}`); }
  }
  e(`  ingested blocks: ${ing} ok, ${ingFail} failed`);
  e(`[tasks] done. View a task node: ${HOST}/papers/task-${tasks[0]?.id}  ·  graph: ${HOST}/v1/graph?dataset=${DATASET}`);
}

// ──────────── main ────────────
const TRIAGE = argv.includes("triage");

(async () => {
  const tasks = await fetchTasks();

  // churn provenance for the top hotspot files — who drives the riskiest code.
  const hotspots = Object.values(comb).filter((r) => (r.hotspot || 0) > 0).sort((a, b) => b.hotspot - a.hotspot).slice(0, 15);
  const provenance = hotspots.map((r) => ({ path: r.path, hotspot: r.hotspot, ...(churnProvenance(r.path) || { topAuthor: null, share: 0, authors: 0, totalChurn: 0 }) }))
    .filter((p) => p.topAuthor);

  const report = { at: new Date().toISOString(), host: HOST, dataset: DATASET, taskCount: tasks.length, tasks: build(tasks), provenance };
  writeFileSync(join(HERE, "tasks-report.json"), JSON.stringify(report, null, 2));

  // ── triage mode: rank OPEN tasks by predicted leverage × defect-risk ──
  if (TRIAGE) {
    const openScoped = report.tasks.filter((t) => t.open && t.predictedVia !== "none" && (t.predictedImpact > 0 || t.defectRisk > 0))
      .sort((a, b) => (b.predictedImpact - a.predictedImpact) || (b.defectRisk - a.defectRisk));
    const openUnscoped = report.tasks.filter((t) => t.open && (t.predictedVia === "none" || (t.predictedImpact === 0 && t.defectRisk === 0)));
    e(`[tasks · triage] ${openScoped.length} open task(s) ranked by predicted impact × defect-risk\n`);
    for (const t of openScoped.slice(0, 20)) {
      e(`  ${String(t.predictedImpact).padStart(5)} impact · ${String(t.defectRisk).padStart(5)} defect-risk  ${t.id}  ${t.title}`);
      e(`        scope via ${t.predictedVia}: ${t.intentions.concat(t.predictedVia === "title" ? ["(title-matched)"] : []).join(", ") || "—"} · ${t.predictedFiles.length} predicted file(s)`);
    }
    if (openUnscoped.length) e(`\n  ${openUnscoped.length} open task(s) unscored (no intention match — title carries no taxonomy tokens): ${openUnscoped.slice(0, 8).map((t) => t.id).join(", ")}${openUnscoped.length > 8 ? " …" : ""}`);
    if (provenance.length) {
      e(`\n[churn provenance] who drives the top hotspots:`);
      for (const p of provenance.slice(0, 8)) e(`  ${p.path}  hotspot ${p.hotspot} · ${p.topAuthor} owns ${p.share}% of churn (${p.authors} author${p.authors > 1 ? "s" : ""})`);
    }
    return;
  }

  // ── console summary ──
  const withFiles = report.tasks.filter((t) => t.actualFiles.length);
  e(`[tasks] ${report.tasks.length} tasks pulled · ${withFiles.length} have committed file evidence (task-id in a commit message)`);
  e(`  → tasks-report.json  ·  triage open work: node tooling/tasks/tasks.mjs triage`);
  e("");
  for (const t of withFiles.slice(0, 12)) {
    const graphN = t.onTarget.length + t.scopeCreep.length;
    e(`  ${t.id}  ${t.title}${t.rolledUp ? " (rolled up from children)" : ""}`);
    e(`     ${t.commits} commit(s) · ${graphN} source + ${t.nonGraphFiles.length} non-graph files · intentions: ${t.intentions.join(", ") || "(none)"}`);
    e(`     impact ${t.impact} · risk ${t.risk}${t.fragile ? " · ⚠️ fragile" : ""} · on-target ${t.onTarget.length}/${graphN} · scope-creep ${t.scopeCreep.length} · scoped-untouched ${t.scopedUntouched.length}`);
    if (t.scopeCreep.length) e(`     creep: ${t.scopeCreep.slice(0, 4).join(", ")}${t.scopeCreep.length > 4 ? " …" : ""}`);
  }
  if (!withFiles.length) e(`  ⚠️ no task carried its id in a commit message — the commit-id→file join is empty. Tasks need "(<task-id>)" in the subject.`);

  if (PUBLISH) { e(""); await publish(report); }
})();
