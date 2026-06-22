#!/usr/bin/env node
// Render the codebase content-graph (Barkpark's /v1/graph data) with Barkpark's
// OWN renderer (bp-graph.js) into a self-contained interactive HTML. Nodes are
// colored by language (stack) and titled with the file path. Opens in a browser.
//   graph-view.mjs [--dataset codebase] [--host URL]

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveEnv, banner } from "../lib/barkpark-env.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const ENV = await resolveEnv(argv, { dataset: "codebase", datasetKey: "codebase" });
const HOST = ENV.host, DATASET = ENV.dataset, ROOT = ENV.root;
console.error(banner(ENV, "graph-view"));

const graph = await (await fetch(`${HOST}/v1/graph?dataset=${DATASET}`, { headers: { Authorization: "Bearer " + ENV.token } })).json();
const meta = existsSync(join(HERE, "nodes.json")) ? Object.fromEntries(JSON.parse(readFileSync(join(HERE, "nodes.json"), "utf8")).nodes.map(n => [n.id, n.fields])) : {};

// color by language; keep path as title
for (const n of graph.nodes) { const f = meta[n.id]; n.type = (f?.kind === "intention") ? "intention" : (f?.stack || "other"); n.title = n.title || n.id; }

const bpgraph = readFileSync(join(ROOT, "api/priv/static/assets/bp-graph.js"), "utf8");
const stacks = {}; for (const n of graph.nodes) stacks[n.type] = (stacks[n.type] || 0) + 1;
const legend = Object.entries(stacks).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(" · ");

const html = `<!DOCTYPE html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Barkpark — Codebase Graph (${DATASET})</title>
<style>html,body{margin:0;height:100%;background:#16161a;overflow:hidden;font-family:Inter,system-ui,sans-serif}
#studio-graph{position:absolute;inset:0}
#cap{position:absolute;left:14px;top:12px;z-index:40;color:rgba(255,255,255,.55);font-size:12px;letter-spacing:.03em}
#cap b{color:#9a8cff}</style></head><body>
<div id=studio-graph></div>
<div id=cap><b>BARKPARK</b> codebase graph &middot; dataset <b>${DATASET}</b> &middot; ${graph.nodes.length} nodes &middot; <span id=ecount>${graph.edges.length}</span> edges &middot; ${legend}</div>
<div id=bar>
  <button data-k="all" class=on>All edges</button>
  <button data-k="dependencies">🔗 Dependencies (${graph.edges.filter(e => e.kind === "dependencies").length})</button>
  <button data-k="intentions">🎯 Intentions (${graph.edges.filter(e => e.kind === "intentions").length})</button>
</div>
<style>#bar{position:absolute;left:14px;bottom:14px;z-index:40;display:flex;gap:8px}
#bar button{background:#23232b;color:#cbd5e1;border:1px solid #3a3a44;border-radius:7px;padding:6px 11px;font-size:12px;cursor:pointer}
#bar button.on{background:#9a8cff;color:#15151a;border-color:#9a8cff}</style>
<script>${bpgraph}</script>
<script>
var DATA=${JSON.stringify({ nodes: graph.nodes, edges: graph.edges })};
var c=document.getElementById("studio-graph");
var OPTS={theme:"dark",reducedMotion:false,flow:false,fullColor:true,onNodeClick:function(n){window.open("${HOST}/d/${DATASET}/papers/"+(n.doc_id||n.id),"_blank")},onNodeHover:function(){}};
function render(kind){
  var edges = kind==="all" ? DATA.edges : DATA.edges.filter(function(e){return e.kind===kind});
  c.innerHTML="";
  window.__r=window.BarkparkGraphRenderer(c,{nodes:DATA.nodes,edges:edges},OPTS);
  document.getElementById("ecount").textContent=edges.length;
}
render("all");
document.querySelectorAll("#bar button").forEach(function(b){b.onclick=function(){
  document.querySelectorAll("#bar button").forEach(function(x){x.classList.remove("on")});
  b.classList.add("on"); render(b.dataset.k);
};});
</script></body></html>`;

writeFileSync(join(HERE, "codebase-graph.html"), html);
process.stderr.write(`[graph-view] ${graph.nodes.length} nodes · ${graph.edges.length} edges → codebase-graph.html (click a node → opens its paper)\n`);
