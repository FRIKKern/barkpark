// @local: exact packaged editor candidate -> served baseline through Barkpark host routes.
// The HTTP server, Paper, browser profile, and all writes are disposable and loopback-only.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launchChrome, evaluate, waitFor } from "./browser.mjs";
import { referenceFold } from "../src/testing-ground/fold.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../..");
const FILES = [
  "bp-paper-code.js",
  "bp-paper-editor-shell.css",
  "bp-paper-editor.bundle.js",
  "bp-paper-editor.css",
  "bp-paper-mermaid.js",
  "bp-paper-surface.css",
];
const EDITOR_FILES = [
  "bp-paper-editor.bundle.js",
  "bp-paper-editor.css",
  "bp-paper-editor-shell.css",
  "bp-paper-surface.css",
];
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function usage(why) {
  throw new Error(`${why}\nusage: npm run host:restore -- --candidate-tarball=<tgz> --candidate-sha256=<sha256> --baseline=<directory> --output=<directory>`);
}

function options(args) {
  const known = /^--(candidate-tarball=.+|candidate-sha256=[0-9a-f]{64}|baseline=.+|output=.+)$/;
  const bad = args.find((arg) => !known.test(arg));
  if (bad) usage(`unknown or malformed option ${bad}`);
  const value = (name) => args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
  for (const name of ["candidate-tarball", "candidate-sha256", "baseline", "output"]) {
    if (!value(name)) usage(`--${name} is required`);
    if (args.filter((arg) => arg.startsWith(`--${name}=`)).length !== 1) usage(`--${name} must be given once`);
  }
  return {
    candidateTarball: resolve(value("candidate-tarball")),
    candidateSha256: value("candidate-sha256"),
    baseline: resolve(value("baseline")),
    output: resolve(value("output")),
  };
}

function sums(dir, label) {
  const declared = new Map(readFileSync(join(dir, "SHA256SUMS"), "utf8").trim().split("\n").map((line) => {
    const match = /^([0-9a-f]{64})  (bp-paper-[a-z0-9.-]+)$/.exec(line);
    if (!match) throw new Error(`${label} has malformed SHA256SUMS line: ${JSON.stringify(line)}`);
    return [match[2], match[1]];
  }));
  assert.deepEqual([...declared.keys()].sort(), [...FILES].sort(), `${label} must declare exactly six browser assets`);
  return declared;
}

function loadDirectory(dir, label, contract, source) {
  const declared = sums(dir, label);
  const assets = Object.fromEntries(FILES.map((name) => {
    const bytes = readFileSync(join(dir, name));
    const digest = sha256(bytes);
    assert.equal(digest, declared.get(name), `${label} ${name} differs from SHA256SUMS`);
    return [name, { bytes, sha256: digest, path: `/assets/v/${digest.slice(0, 16)}/${name}` }];
  }));
  return { label, contract, source, dir, assets };
}

function loadCandidate(tarball, expectedDigest, extraction) {
  const bytes = readFileSync(tarball);
  assert.equal(sha256(bytes), expectedDigest, "candidate tarball differs from its hosted dry-run SHA-256");
  execFileSync("tar", ["-xzf", tarball, "-C", extraction]);
  const packageDir = join(extraction, "package");
  const metadata = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8"));
  assert.equal(metadata.name, "@portable-doc/editor");
  assert.equal(metadata.version, "0.1.0-alpha.1");
  assert.equal(metadata.barkpark?.contractVersion, "1.22.0");
  const dist = join(packageDir, "dist");
  const lines = FILES.map((name) => `${sha256(readFileSync(join(dist, name)))}  ${name}`);
  writeFileSync(join(dist, "SHA256SUMS"), lines.join("\n") + "\n");
  return loadDirectory(dist, "candidate", "1.22.0", {
    kind: "hosted-dry-run-tarball",
    path: tarball,
    sha256: expectedDigest,
    package: { name: metadata.name, version: metadata.version },
  });
}

function html(body, scripts = "") {
  return `<!doctype html><html><head><meta charset="utf-8"><title>R2.6 host restore</title></head><body>${body}${scripts}</body></html>`;
}

function assetTags(names, pathOf) {
  return names.map((name) => name.endsWith(".css")
    ? `<link rel="stylesheet" href="${pathOf(name)}" data-asset="${name}">`
    : `<script src="${pathOf(name)}" data-asset="${name}" defer></script>`).join("\n");
}

function clientAudit(names) {
  return `<script>window.__r26Ready = Promise.all(${JSON.stringify(names)}.map(async name => {
    const node = document.querySelector('[data-asset="' + name + '"]');
    if (node && !performance.getEntriesByName(node.src || node.href).length) await new Promise((ok, fail) => { node.addEventListener('load', ok, {once:true}); node.addEventListener('error', fail, {once:true}); });
    const url = node.src || node.href;
    const response = await fetch(url);
    if (!response.ok) throw new Error(name + ': ' + response.status);
    const digest = await crypto.subtle.digest('SHA-256', await response.arrayBuffer());
    return [name, {url, sha256: [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')}];
  })).then(Object.fromEntries);</script>`;
}

function readerPage() {
  const names = ["bp-paper-surface.css", "bp-paper-code.js", "bp-paper-mermaid.js"];
  return html(`<main class="bp-paper-surface"><h1>Reader restore proof</h1><pre><code class="language-js">const host = "reader";</code></pre></main>`, assetTags(names, (name) => `/assets/${name}`) + clientAudit(names));
}

function webPage() {
  const names = ["bp-paper-editor.css", "bp-paper-editor.bundle.js"];
  const pathOf = (name) => name === "bp-paper-editor.bundle.js" ? "/bp-paper-editor.bundle.js" : `/assets/${name}`;
  return html(`<main><h1>Web restore proof</h1><bp-paper-editor id="web-paper"></bp-paper-editor></main>`, assetTags(names, pathOf) + clientAudit(names) + `<script>window.__r26Ready.then(() => customElements.whenDefined('bp-paper-editor')).then(() => window.__r26WebDefined = true);</script>`);
}

function studioPage() {
  return html(`<main class="bp-paper-editor"><h1>Studio field canvas restore proof</h1><div class="bp-paper-edit-canvas" id="mount"></div></main>`, `<script>
window.__r26Ready = (async () => {
  const manifest = await fetch('/v1/embed/canvas').then(response => response.json());
  const urls = [manifest.script, ...manifest.styles];
  for (const href of manifest.styles) await new Promise((ok, fail) => { const link = Object.assign(document.createElement('link'), {rel:'stylesheet', href}); link.onload=ok; link.onerror=fail; document.head.append(link); });
  await new Promise((ok, fail) => { const script = Object.assign(document.createElement('script'), {src:manifest.script}); script.onload=ok; script.onerror=fail; document.head.append(script); });
  await customElements.whenDefined('bp-paper-canvas');
  const paper = await fetch('/v1/papers/restore-proof').then(response => response.json());
  const canvas = document.createElement('bp-paper-canvas');
  canvas.setAttribute('editable', 'true');
  canvas.acknowledgedSaves = true;
  canvas.blocks = structuredClone(paper.blocks);
  canvas.addEventListener('bp-canvas-ops', async event => {
    const {ops, seq} = event.detail;
    const requestId = 'r26-' + seq;
    canvas.identifyOpsRequest(seq, requestId);
    try {
      const response = await fetch('/v1/papers/restore-proof/ops', {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({ifRev:window.__r26Rev, ops})});
      const saved = await response.json();
      if (!response.ok) throw new Error(saved.error || response.status);
      window.__r26Rev = saved.rev;
      canvas.applyServerBlocks(structuredClone(saved.blocks), {mode:'own', requestId});
      canvas.acknowledgeOps(seq, true);
    } catch (error) {
      canvas.discardInflightOps(seq);
      window.__r26Error = error.message;
    }
  });
  window.__r26Rev = paper.rev;
  document.querySelector('#mount').append(canvas);
  const assets = {};
  for (const url of urls) {
    const response = await fetch(url);
    const digest = await crypto.subtle.digest('SHA-256', await response.arrayBuffer());
    assets[url.split('/').at(-1)] = {url:new URL(url, location.href).href, sha256:[...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')};
  }
  return assets;
})();</script>`);
}

function json(response, status, value) {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(value));
}

async function body(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks));
}

async function startServer(candidate, baseline) {
  let active = candidate;
  let blocks = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "Rollback proof" }] }];
  let rev = 1;
  const writes = [];
  const reads = [];
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://127.0.0.1").pathname;
    reads.push({ phase: active.label, method: request.method, pathname });
    if (request.method === "GET" && pathname === "/v1/embed/canvas") return json(response, 200, {
      script: active.assets["bp-paper-editor.bundle.js"].path,
      styles: ["bp-paper-editor.css", "bp-paper-editor-shell.css", "bp-paper-surface.css"].map((name) => active.assets[name].path),
    });
    if (request.method === "GET" && pathname === "/v1/papers/restore-proof") return json(response, 200, { rev, blocks });
    if (request.method === "POST" && pathname === "/v1/papers/restore-proof/ops") {
      const payload = await body(request);
      if (payload.ifRev !== rev || !Array.isArray(payload.ops)) return json(response, 409, { error: "revision_conflict", rev, blocks });
      blocks = await referenceFold.apply(structuredClone(blocks), payload.ops);
      rev += 1;
      writes.push({ phase: active.label, rev, ops: payload.ops, blocks: structuredClone(blocks) });
      return json(response, 200, { rev, blocks });
    }
    if (request.method === "GET" && pathname === "/papers/restore-proof") {
      response.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" }); return response.end(readerPage());
    }
    if (request.method === "GET" && pathname === "/web/documents/restore-proof") {
      response.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" }); return response.end(webPage());
    }
    if (request.method === "GET" && pathname === "/studio/field/restore-proof") {
      response.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" }); return response.end(studioPage());
    }
    const asset = Object.entries(active.assets).find(([name, value]) => pathname === value.path || pathname === `/assets/${name}` || (name === "bp-paper-editor.bundle.js" && pathname === `/${name}`));
    if (request.method === "GET" && asset) {
      const immutable = pathname === asset[1].path;
      response.writeHead(200, { "content-type": asset[0].endsWith(".css") ? "text/css" : "text/javascript", "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache" });
      return response.end(asset[1].bytes);
    }
    json(response, 404, { error: "not_found" });
  });
  await new Promise((ok, fail) => { server.once("error", fail); server.listen(0, "127.0.0.1", ok); });
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    setPhase(label) { active = label === "candidate" ? candidate : baseline; },
    snapshot() { return { rev, blocks: structuredClone(blocks), writes: structuredClone(writes), reads: structuredClone(reads) }; },
    async close() { server.closeAllConnections(); await new Promise((ok) => server.close(ok)); },
  };
}

async function navigate(cdp, url) {
  const { errorText } = await cdp.send("Page.navigate", { url });
  if (errorText) throw new Error(`navigation failed: ${errorText}`);
  await waitFor(cdp, "document.readyState === 'complete' && Boolean(window.__r26Ready)");
  await evaluate(cdp, "window.__r26Ready");
}

function verifyAudit(phase, audit, names, route, expectedPath = (name) => phase.assets[name].path) {
  assert.deepEqual(Object.keys(audit).sort(), [...names].sort(), `${phase.label} ${route} asset names`);
  for (const name of names) {
    assert.equal(audit[name].sha256, phase.assets[name].sha256, `${phase.label} ${route} ${name}`);
    assert.equal(new URL(audit[name].url).pathname, expectedPath(name), `${phase.label} ${route} ${name} URL`);
  }
}

async function edit(cdp, before, suffix, expectedRev) {
  await waitFor(cdp, "Boolean(document.querySelector('bp-paper-canvas')?._editor)");
  await evaluate(cdp, `(() => {
    const root = document.querySelector('bp-paper-canvas');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node; while ((node = walker.nextNode())) if (node.data.includes(${JSON.stringify(before)})) break;
    if (!node) throw new Error('edit text not found');
    const range = document.createRange(); range.setStart(node, node.data.length); range.collapse(true);
    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); node.parentElement.focus();
  })()`);
  await cdp.send("Input.insertText", { text: suffix });
  await waitFor(cdp, `window.__r26Rev === ${expectedRev} && !window.__r26Error`);
  return before + suffix;
}

async function run(args = process.argv.slice(2)) {
  const opts = options(args);
  const extraction = mkdtempSync(join(tmpdir(), "bp-r26-hosted-package-"));
  const candidate = loadCandidate(opts.candidateTarball, opts.candidateSha256, extraction);
  const baselineManifest = JSON.parse(readFileSync(join(opts.baseline, "manifest.json"), "utf8"));
  const baseline = loadDirectory(opts.baseline, "restored-baseline", "1.21.0", { kind: "preserved-served-baseline", manifest: baselineManifest });
  assert.notEqual(candidate.assets["bp-paper-editor.bundle.js"].sha256, baseline.assets["bp-paper-editor.bundle.js"].sha256, "candidate and restored baseline bundle must differ");
  const host = await startServer(candidate, baseline);
  const browser = await launchChrome();
  const phases = [];
  try {
    let text = "Rollback proof";
    for (const [index, phase] of [candidate, baseline].entries()) {
      host.setPhase(phase.label);
      await navigate(browser.cdp, `${host.origin}/papers/restore-proof`);
      const reader = await evaluate(browser.cdp, "window.__r26Ready");
      verifyAudit(phase, reader, ["bp-paper-surface.css", "bp-paper-code.js", "bp-paper-mermaid.js"], "reader", (name) => `/assets/${name}`);

      await navigate(browser.cdp, `${host.origin}/web/documents/restore-proof`);
      await waitFor(browser.cdp, "window.__r26WebDefined === true");
      const web = await evaluate(browser.cdp, "window.__r26Ready");
      verifyAudit(phase, web, ["bp-paper-editor.css", "bp-paper-editor.bundle.js"], "web", (name) => name === "bp-paper-editor.bundle.js" ? `/${name}` : `/assets/${name}`);

      await navigate(browser.cdp, `${host.origin}/studio/field/restore-proof`);
      const studio = await evaluate(browser.cdp, "window.__r26Ready");
      verifyAudit(phase, studio, EDITOR_FILES, "studio-field");
      await waitFor(browser.cdp, `document.querySelector('bp-paper-canvas')?.textContent.includes(${JSON.stringify(text)})`);
      const contract = await evaluate(browser.cdp, "customElements.get('bp-paper-editor')?.CONTRACT_VERSION");
      assert.equal(contract, phase.contract);
      text = await edit(browser.cdp, text, index === 0 ? " candidate" : " restored", index + 2);
      await navigate(browser.cdp, `${host.origin}/studio/field/restore-proof`);
      await waitFor(browser.cdp, `document.querySelector('bp-paper-canvas')?.textContent.includes(${JSON.stringify(text)})`);
      phases.push({ phase: phase.label, contract, declared: Object.fromEntries(FILES.map((name) => [name, phase.assets[name].sha256])), loaded: { reader, web, studioField: studio }, savedText: text, revision: index + 2 });
      console.log(`PASS ${phase.label} contract ${contract} revision ${index + 2}`);
    }
    const state = host.snapshot();
    assert.equal(state.rev, 3);
    assert.equal(state.writes.length, 2);
    assert.equal(state.blocks[0].content.map((part) => part.value).join(""), "Rollback proof candidate restored");
    mkdirSync(opts.output, { recursive: true });
    const manifest = {
      schema: 1,
      sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { cwd: REPO, encoding: "utf8" }).trim(),
      sourceDirty: execFileSync("git", ["status", "--porcelain", "--", "api/assets/paper-editor/hosts/restore.mjs", "api/assets/paper-editor/hosts/README.md", "api/assets/paper-editor/package.json"], { cwd: REPO, encoding: "utf8" }).trim() !== "",
      isolation: { loopbackOnly: true, liveMutation: false, origin: host.origin, disposablePaper: "restore-proof" },
      candidate: candidate.source,
      baseline: baseline.source,
      phases,
      final: { revision: state.rev, blocks: state.blocks, writes: state.writes },
      assertions: [
        "the hosted dry-run tarball matched its expected SHA-256 before extraction",
        "all six candidate and restored-baseline browser assets matched their recorded SHA-256 identities",
        "reader, web, and Studio field routes loaded the exact assets selected for each phase",
        "the candidate edit received revision 2 and survived reload",
        "the restored-baseline client loaded the candidate-saved Paper, received revision 3, and survived reload",
        "the backend, Paper, browser profile, and all writes were disposable and loopback-only",
      ],
    };
    writeFileSync(join(opts.output, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
    console.log(`Evidence: ${join(opts.output, "manifest.json")}`);
  } finally {
    await browser.close();
    await host.close();
    rmSync(extraction, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  run().catch((error) => { console.error(`npm run host:restore: ${error.stack || error.message}`); process.exitCode = 1; });
}
