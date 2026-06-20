#!/usr/bin/env node
// Combine the two orthogonal axes — IMPORTANCE (per-file) × CONSISTENCY
// (relational) — into one prioritized worklist. priority = importance ×
// inconsistency-severity, so only files that are BOTH important AND genuinely
// broken float to the top.
//
// Pure programmatic join (zero tokens) of:
//   tooling/research-coverage/research-ledger.json   (importance: agent criticality + role/desc)
//   tooling/file-importance/file-signals.json        (objective prior → anchors importance)
//   tooling/consistency/consistency-report.json      (outliers / layering / dup)
//   tooling/consistency/results/group-*.json         (drift/intentional/refactor verdicts)
//   tooling/consistency/results/_layering.json|_dup.json  (verified issue verdicts)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;

const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {} }).files;
const priors = {}; for (const s of (rd("tooling/file-importance/file-signals.json", { signals: [] }).signals)) priors[s.path] = s.prior;
const crep = rd("tooling/consistency/consistency-report.json", { groups: [], layering: [], duplication: [] });

const stackOf = (f) => f.endsWith(".go") ? "go" : /\.(ex|exs|heex|eex)$/.test(f) ? "elixir" : /\.(ts|tsx|js|mjs|jsx)$/.test(f) ? "js" : /\.(md|mdx)$/.test(f) ? "docs" : "other";

// --- importance = blend(objective prior, agent criticality) — same as the chart ---
function importance(path, e) {
  const prior = priors[path];
  const score = Number.isFinite(+e.score) ? +e.score : 0;
  if (e.tier === "agent" && Number.isFinite(prior)) return Math.round(0.45 * prior + 0.55 * score);
  return score;
}

// --- consistency lookups ---
const outlier = {}; for (const g of crep.groups) for (const o of g.outliers) outlier[o.file] = { reasons: o.reasons, conform: g.conform };
const verdict = {}; // group drift/intentional/refactor
const RES = join(ROOT, "tooling/consistency/results");
for (const f of (existsSync(RES) ? readdirSync(RES) : []).filter(f => f.endsWith(".json") && !f.startsWith("_"))) {
  try { for (const x of JSON.parse(readFileSync(join(RES, f), "utf8")).verdicts || []) verdict[x.file] = x; } catch {}
}
const layV = {}; for (const l of rd("tooling/consistency/results/_layering.json", [])) layV[l.file] = l;
const dupV = {}; for (const d of rd("tooling/consistency/results/_dup.json", [])) { for (const k of [d.a, d.b]) { if (!dupV[k] || d.verdict === "extract") dupV[k] = { ...d, partner: k === d.a ? d.b : d.a }; } }
const dupRaw = {}; for (const d of crep.duplication) { for (const k of [d.a, d.b]) dupRaw[k] ||= (k === d.a ? d.b : d.a); }
const layRaw = {}; for (const l of crep.layering) layRaw[l.file] ||= l;

// --- severity model: VERIFIED verdicts win; unverified findings get a provisional, lower weight ---
function consistency(path) {
  const cands = [];
  if (layV[path]) cands.push(layV[path].verdict === "violation"
    ? { sev: 1.0, status: "layering", detail: `${layV[path].reason}${layV[path].fix ? " — fix: " + layV[path].fix : ""}` }
    : { sev: 0.05, status: "layering·ok", detail: layV[path].reason });
  else if (layRaw[path]) cands.push({ sev: 0.7, status: "layering?", detail: layRaw[path].message + " (unverified)" });

  const v = verdict[path];
  if (v?.verdict === "drift") cands.push({ sev: 0.9, status: "drift", detail: v.recommendation });
  else if (v?.verdict === "refactor") cands.push({ sev: 0.6, status: "refactor", detail: v.recommendation });
  else if (v?.verdict === "intentional") cands.push({ sev: 0.05, status: "intentional", detail: v.recommendation });
  else if (outlier[path]) cands.push({ sev: 0.25, status: "off-pattern", detail: outlier[path].reasons.join("; ") });

  if (dupV[path]) cands.push(dupV[path].verdict === "extract"
    ? { sev: 0.55, status: "dup·extract", detail: `${dupV[path].reason} (≈ ${dupV[path].partner})` }
    : { sev: 0.05, status: "dup·ok", detail: dupV[path].reason });
  else if (dupRaw[path]) cands.push({ sev: 0.3, status: "dup?", detail: `≈ ${dupRaw[path]} (unverified)` });

  if (!cands.length) return { sev: 0, status: "clean", detail: "" };
  return cands.sort((a, b) => b.sev - a.sev)[0];
}

// --- join ---
const rows = Object.entries(ledger).map(([path, e]) => {
  const imp = importance(path, e), c = consistency(path);
  return { path, stack: stackOf(path), importance: imp, role: e.role || "",
    status: c.status, severity: c.sev, detail: c.detail, priority: Math.round(imp * c.sev) };
}).sort((a, b) => b.priority - a.priority || b.importance - a.importance);

const HI = 60, ISSUE = 0.4;
const hiIssue = rows.filter(r => r.importance >= HI && r.severity >= ISSUE);
const quad = {
  hiIssue: hiIssue.length,
  hiClean: rows.filter(r => r.importance >= HI && r.severity < ISSUE).length,
  loIssue: rows.filter(r => r.importance < HI && r.severity >= ISSUE).length,
  loClean: rows.filter(r => r.importance < HI && r.severity < ISSUE).length,
};
const minorIssue = rows.filter(r => r.importance < HI && r.severity >= ISSUE);
const unverified = rows.filter(r => /\?$/.test(r.status)).length;

// --- CSV ---
const cols = ["priority", "importance", "status", "severity", "stack", "path", "role", "detail"];
const esc = (v) => `"${String(v).replace(/"/g, '""').replace(/\n/g, " ")}"`;
writeFileSync(join(HERE, "combined-report.csv"), [cols.join(","), ...rows.map(r => cols.map(c => esc(r[c])).join(","))].join("\n"));

// --- HTML ---
const E = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");
const sevC = (s) => s >= 1 ? "#dc2626" : s >= 0.9 ? "#ea580c" : s >= 0.55 ? "#d97706" : s >= 0.4 ? "#ca8a04" : s > 0 ? "#cbd5e1" : "#f1f5f9";
const impC = (v) => `hsl(${Math.round(v / 100 * 120)},70%,88%)`;
const wrow = (r, i) => `<tr><td class=rank>${i + 1}</td><td class=pri style="background:${sevC(r.severity)};color:${r.severity >= 0.55 ? "#fff" : "#000"}"><b>${r.priority}</b></td>`
  + `<td class=n style="background:${impC(r.importance)}">${r.importance}</td><td><span class="st ${r.status.replace(/[^a-z]/g,"")}">${E(r.status)}</span></td>`
  + `<td class=path>${E(r.path)}</td><td>${E(r.role)}</td><td class=detail>${E(r.detail)}</td></tr>`;
const table = (rs) => `<table><thead><tr><th>#</th><th>Priority</th><th>Import</th><th>Status</th><th>Path</th><th>Role</th><th>Action / detail</th></tr></thead><tbody>${rs.map(wrow).join("")}</tbody></table>`;

const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Importance × Consistency</title>
<style>body{font:13px/1.45 -apple-system,Segoe UI,sans-serif;margin:0;color:#1a1a1a}
header{background:#0f172a;color:#fff;padding:14px 20px} h2{margin:20px 20px 4px;font-size:15px} .sub{margin:0 20px;color:#64748b;font-size:12px}
.quad{display:flex;gap:10px;padding:12px 20px;background:#f1f5f9;flex-wrap:wrap}
.q{padding:8px 12px;border-radius:8px;background:#fff;border:1px solid #cbd5e1;min-width:140px}.q b{font-size:20px}.q.hot{border-color:#dc2626;background:#fef2f2}
table{border-collapse:collapse;width:calc(100% - 40px);margin:6px 20px}
th,td{padding:4px 8px;border-bottom:1px solid #eef2f7;text-align:left;vertical-align:top}th{background:#e2e8f0;font-size:11px;text-transform:uppercase}
td.pri,td.n{text-align:center;width:46px;font-variant-numeric:tabular-nums}td.rank{color:#cbd5e1;text-align:right}
td.path{font-family:ui-monospace,monospace;font-size:12px}td.detail{color:#475569;font-size:12px;max-width:520px}
.st{font-size:10px;padding:1px 6px;border-radius:8px;text-transform:uppercase;white-space:nowrap}
.st.layering{background:#fecaca}.st.layering?,.st.layering{background:#fecaca}.st.drift{background:#fed7aa}.st.refactor{background:#fde68a}.st.dupextract{background:#fde68a}.st.dup{background:#fef9c3}.st.offpattern{background:#fef9c3}.st.intentional{background:#dcfce7;color:#166534}.st.layeringok,.st.dupok{background:#dcfce7;color:#166534}.st.clean{background:#f1f5f9;color:#94a3b8}
.controls{padding:8px 20px}input{padding:5px 8px;width:300px;border:1px solid #94a3b8;border-radius:6px}
tr:hover{background:#fffbeb}</style>
<header><b>Barkpark — Importance × Consistency</b><div style="font-size:12px;opacity:.85">priority = importance × inconsistency-severity · ${rows.length} files · importance = blend(objective prior 45%, agent 55%)${unverified ? ` · <b style=color:#fca5a5>${unverified} unverified — run issue-judgment</b>` : " · all issues verified"}</div></header>
<div class=quad>
 <div class="q hot">⚠ important &amp; inconsistent<br><b>${quad.hiIssue}</b> <span style=color:#64748b>the worklist</span></div>
 <div class=q>important &amp; clean<br><b>${quad.hiClean}</b></div>
 <div class=q>minor &amp; inconsistent<br><b>${quad.loIssue}</b></div>
 <div class=q>minor &amp; clean<br><b>${quad.loClean}</b></div>
</div>
<h2>⚠ Worklist — important &amp; genuinely inconsistent</h2><div class=sub>fix these first: high importance × a verified issue</div>
${hiIssue.length ? table(hiIssue) : '<div class=sub>none — every important file is consistent ✓</div>'}
<h2>Minor &amp; inconsistent</h2><div class=sub>real issues in less-important files — fix opportunistically</div>
${minorIssue.length ? table(minorIssue.slice(0, 40)) : '<div class=sub>none</div>'}
<h2>All files</h2><div class=controls><input id=q placeholder="filter…" oninput=f()> <span id=c></span></div>
<table id=t><thead><tr><th>#</th><th>Priority</th><th>Import</th><th>Status</th><th>Path</th><th>Role</th><th>Action / detail</th></tr></thead><tbody>${rows.map(wrow).join("")}</tbody></table>
<script>const tb=document.querySelector('#t tbody'),all=[...tb.rows];document.getElementById('c').textContent=all.length+' files';
function f(){const q=document.getElementById('q').value.toLowerCase();let n=0;for(const r of all){const ok=r.textContent.toLowerCase().includes(q);r.style.display=ok?'':'none';if(ok)n++}document.getElementById('c').textContent=n+' shown'}</script>`;
writeFileSync(join(HERE, "combined-report.html"), html);

const e = (s) => process.stderr.write(s + "\n");
e(`combined  ${rows.length} files · quadrants: important&inconsistent ${quad.hiIssue} · important&clean ${quad.hiClean} · minor&inconsistent ${quad.loIssue} · minor&clean ${quad.loClean}`);
if (unverified) e(`  ${unverified} UNVERIFIED issue(s) — run the issue-judgment pass for a trustworthy worklist`);
e(`  WORKLIST (important & verified-inconsistent):`);
for (const r of hiIssue.slice(0, 12)) e(`    P${String(r.priority).padStart(3)} imp${String(r.importance).padStart(3)} [${r.status}] ${r.path}`);
e(`  → combined-report.{html,csv}`);
