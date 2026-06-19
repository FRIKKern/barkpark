#!/usr/bin/env node
// Combine the two orthogonal axes — IMPORTANCE (per-file) × CONSISTENCY
// (relational) — into one priority view. The point: a file that is both
// important AND inconsistent is urgent; drift in a trivial file is not.
// priority = importance × inconsistency-severity → the actionable worklist.
//
// Pure programmatic join (zero tokens) of:
//   tooling/research-coverage/research-ledger.json   (importance: score/role/desc)
//   tooling/consistency/consistency-report.json      (outliers/layering/dup)
//   tooling/consistency/results/group-*.json         (agent verdicts)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p) => JSON.parse(readFileSync(join(ROOT, p), "utf8"));

const ledger = rd("tooling/research-coverage/research-ledger.json").files;
const crep = rd("tooling/consistency/consistency-report.json");

// --- consistency lookups ---
const outlier = {};      // path -> {reasons, groupConform, dir}
for (const g of crep.groups) for (const o of g.outliers) outlier[o.file] = { reasons: o.reasons, groupConform: g.conform, dir: g.dir };
const layering = {};      // path -> message
for (const l of crep.layering) (layering[l.file] ||= l.message);
const dupOf = {};         // path -> partner
for (const d of crep.duplication) { (dupOf[d.a] ||= d.b); (dupOf[d.b] ||= d.a); }
const verdict = {};       // path -> {verdict, recommendation}
const RES = join(ROOT, "tooling/consistency/results");
for (const f of (existsSync(RES) ? readdirSync(RES) : []).filter(f => f.endsWith(".json"))) {
  try { const v = JSON.parse(readFileSync(join(RES, f), "utf8")); for (const x of v.verdicts || []) verdict[x.file] = x; } catch {}
}

// --- severity model ---
function consistency(path) {
  if (layering[path]) return { status: "layering", severity: 1.0, detail: layering[path] };
  const vd = verdict[path];
  if (vd?.verdict === "drift") return { status: "drift", severity: 0.9, detail: vd.recommendation };
  if (vd?.verdict === "refactor") return { status: "refactor", severity: 0.6, detail: vd.recommendation };
  if (dupOf[path]) return { status: "dup", severity: 0.4, detail: `≈ ${dupOf[path]}` };
  if (vd?.verdict === "intentional") return { status: "intentional", severity: 0.05, detail: vd.recommendation };
  if (outlier[path]) return { status: "off-pattern", severity: 0.3, detail: outlier[path].reasons.join("; ") };
  return { status: "clean", severity: 0, detail: "" };
}

// --- join ---
const rows = Object.entries(ledger).map(([path, e]) => {
  const imp = Number.isFinite(+e.score) ? +e.score : 0;
  const c = consistency(path);
  return { path, importance: imp, stack: e.tier === "auto" ? "" : "", role: e.role || "", description: e.description || "",
    status: c.status, severity: c.severity, detail: c.detail, groupConform: outlier[path]?.groupConform ?? "",
    priority: Math.round(imp * c.severity) };
}).sort((a, b) => b.priority - a.priority || b.importance - a.importance);

// --- quadrant ---
const HI = 60, ISSUE = 0.4;
const quad = { hiIssue: [], hiClean: 0, loIssue: 0, loClean: 0 };
for (const r of rows) {
  const hi = r.importance >= HI, iss = r.severity >= ISSUE;
  if (hi && iss) quad.hiIssue.push(r); else if (hi) quad.hiClean++; else if (iss) quad.loIssue++; else quad.loClean++;
}

// --- CSV ---
const cols = ["priority","importance","status","severity","groupConform","path","role","detail"];
const esc = (v) => `"${String(v).replace(/"/g,'""').replace(/\n/g," ")}"`;
writeFileSync(join(HERE, "combined-report.csv"), [cols.join(","), ...rows.map(r => cols.map(c => esc(r[c])).join(","))].join("\n"));

// --- HTML ---
const E = (s) => String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;");
const sevColor = (s) => s >= 1 ? "#dc2626" : s >= 0.9 ? "#ea580c" : s >= 0.6 ? "#d97706" : s >= 0.4 ? "#ca8a04" : s >= 0.3 ? "#eab308" : s > 0 ? "#94a3b8" : "#e2e8f0";
const impColor = (v) => `hsl(${Math.round(v/100*120)},70%,88%)`;
const row = (r, i) => `<tr><td class="rank">${i+1}</td>`
  + `<td class="pri" style="background:${sevColor(r.severity)};color:${r.priority>30?'#fff':'#000'}"><b>${r.priority}</b></td>`
  + `<td class="n" style="background:${impColor(r.importance)}">${r.importance}</td>`
  + `<td><span class="st ${r.status}">${r.status}</span></td>`
  + `<td class="path">${E(r.path)}</td><td>${E(r.role)}</td><td class="detail">${E(r.detail)}</td></tr>`;

const worklist = quad.hiIssue;
const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Importance × Consistency</title>
<style>body{font:13px/1.45 -apple-system,Segoe UI,sans-serif;margin:0;color:#1a1a1a}
header{background:#0f172a;color:#fff;padding:14px 20px;position:sticky;top:0;z-index:2}
.quad{display:flex;gap:10px;padding:12px 20px;background:#f1f5f9;flex-wrap:wrap}
.q{padding:8px 12px;border-radius:8px;background:#fff;border:1px solid #cbd5e1;min-width:150px}
.q b{font-size:20px} .q.hot{border-color:#dc2626;background:#fef2f2}
.controls{padding:8px 20px;position:sticky;top:52px;background:#fff;z-index:2;border-bottom:1px solid #e2e8f0}
input{padding:5px 8px;width:300px;border:1px solid #94a3b8;border-radius:6px}
table{border-collapse:collapse;width:100%} th,td{padding:4px 8px;border-bottom:1px solid #eef2f7;text-align:left;vertical-align:top}
th{background:#e2e8f0;position:sticky;top:96px;font-size:11px;text-transform:uppercase;cursor:pointer}
td.pri,td.n{text-align:center;width:46px;font-variant-numeric:tabular-nums} td.rank{color:#cbd5e1;text-align:right}
td.path{font-family:ui-monospace,monospace;font-size:12px} td.detail{color:#475569;font-size:12px;max-width:480px}
.st{font-size:10px;padding:1px 6px;border-radius:8px;text-transform:uppercase}
.st.layering{background:#fecaca}.st.drift{background:#fed7aa}.st.refactor{background:#fde68a}.st.dup{background:#fef08a}.st.off-pattern{background:#fef9c3}.st.intentional{background:#dcfce7;color:#166534}.st.clean{background:#f1f5f9;color:#94a3b8}
tr:hover{background:#fffbeb}</style>
<header><b>Barkpark — Importance × Consistency</b>
<div style="font-size:12px;opacity:.85">priority = importance × inconsistency-severity · ${rows.length} files</div></header>
<div class="quad">
 <div class="q hot">⚠ important &amp; inconsistent<br><b>${quad.hiIssue.length}</b> <span style="color:#64748b">the worklist</span></div>
 <div class="q">important &amp; clean<br><b>${quad.hiClean}</b></div>
 <div class="q">minor &amp; inconsistent<br><b>${quad.loIssue}</b></div>
 <div class="q">minor &amp; clean<br><b>${quad.loClean}</b></div>
</div>
<div class="controls"><input id="q" placeholder="filter…" oninput="f()"> <span id="c"></span> · sorted by priority (importance × severity)</div>
<table id="t"><thead><tr><th>#</th><th>Priority</th><th>Import</th><th>Consistency</th><th>Path</th><th>Role</th><th>Detail</th></tr></thead>
<tbody>${rows.map(row).join("")}</tbody></table>
<script>const tb=document.querySelector('#t tbody'),all=[...tb.rows];document.getElementById('c').textContent=all.length+' files';
function f(){const q=document.getElementById('q').value.toLowerCase();let n=0;for(const r of all){const ok=r.textContent.toLowerCase().includes(q);r.style.display=ok?'':'none';if(ok)n++}document.getElementById('c').textContent=n+' shown'}</script>`;
writeFileSync(join(HERE, "combined-report.html"), html);

// --- console ---
const e = (s)=>process.stderr.write(s+"\n");
e(`combined  ${rows.length} files joined (importance × consistency)`);
e(`  QUADRANTS — important&inconsistent: ${quad.hiIssue.length}  important&clean: ${quad.hiClean}  minor&inconsistent: ${quad.loIssue}  minor&clean: ${quad.loClean}`);
e(`  → THE WORKLIST (important AND inconsistent), top by priority:`);
for (const r of worklist.slice(0, 12)) e(`    P${String(r.priority).padStart(3)} imp${String(r.importance).padStart(3)} [${r.status}] ${r.path}`);
e(`  → combined-report.{html,csv}`);
