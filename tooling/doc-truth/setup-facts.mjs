#!/usr/bin/env node
// setup-facts.mjs: a fact check over the setup docs.
//
// Setup run 1 lost most of its time to docs that named the wrong file, missed
// the sign-in URL and pointed at sections that had moved. This check reads the
// setup docs, pulls out each checkable fact and looks it up in the code:
//
//   env    every BARKPARK_* name, and every other ALL_CAPS_NAME in code spans,
//          is named in server, deploy or CLI code (scanned now, not a hand list)
//   cmd    every `bp <noun> <verb>` is dispatched by the CLI, listed in the
//          manifest fixture (docs/cli/fixtures/full-manifest.json) or declared
//          by the server's capability code in api/lib (the fixture lags it)
//   flag   every --flag on a bp line is read by the CLI or one of those sources
//   route  every HTTP path on our server matches a route in the Phoenix and
//          cloud routers, plugin route tuples or endpoint sockets
//   path   every repo file path and script exists (gitignored run-time paths
//          such as api/uploads count)
//   link   every relative link and #anchor resolves, and every docs/*.md link
//          in a Go or Elixir string, or in api/entrypoint.sh, points at a file
//          and anchor that exist
//
// Scope: docs/setup/*.md, the setup sections of README.md, and every doc a Go
// string in internal/ or cmd/ links to.
//
// Output is one line per wrong fact: `file:line: kind: why; nearest: value`.
// Known failures live in setup-facts-allow.txt with the task that fixes them;
// a fact that is right as written but cannot be checked here carries a label.
// A finding outside the list fails the run.
//
//   node tooling/doc-truth/setup-facts.mjs            # check, exit 1 on a new wrong fact
//   node tooling/doc-truth/setup-facts.mjs --json     # machine-readable findings
//   node tooling/doc-truth/setup-facts.mjs --all      # also print allowed findings
//   node --test tooling/doc-truth/setup-facts.test.mjs
//
// Exit 0: no wrong fact outside the allow-list. Exit 1: at least one. Exit 2:
// the check could not load a source it needs or could not read the list.
//
// Dependency-free. ESM, node: builtins only.

import { readFileSync, existsSync, statSync } from "node:fs";
import { join, dirname, normalize, posix } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const ALLOW_FILE = "tooling/doc-truth/setup-facts-allow.txt";

// ── markdown scanning ───────────────────────────────────────────────────────

// Split a markdown text into lines tagged with fence state. Inline code spans
// and the prose around them are returned per line. HTML comments are skipped.
export function scanMarkdown(text) {
  const lines = text.split("\n");
  const out = [];
  let fence = null; // { ch, len, lang }
  let inComment = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const ln = i + 1;
    const fm = /^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)/.exec(line);
    if (fence) {
      if (fm && fm[1][0] === fence.ch && fm[1].length >= fence.len && /^\s*[`~]+\s*$/.test(line)) {
        fence = null;
        continue;
      }
      out.push({ line: ln, text: line, fenced: true, lang: fence.lang, spans: [], prose: "" });
      continue;
    }
    if (fm) {
      fence = { ch: fm[1][0], len: fm[1].length, lang: fm[2] || "" };
      continue;
    }
    let body = line;
    if (inComment) {
      const end = body.indexOf("-->");
      if (end < 0) continue;
      inComment = false;
      body = body.slice(end + 3);
    }
    body = body.replace(/<!--[\s\S]*?-->/g, "");
    const open = body.indexOf("<!--");
    if (open >= 0) { inComment = true; body = body.slice(0, open); }
    const spans = [];
    const prose = body.replace(/(`+)([\s\S]+?)\1/g, (_, _t, s) => { spans.push(s.trim()); return " "; });
    out.push({ line: ln, text: body, fenced: false, lang: "", spans, prose });
  }
  return out;
}

// GitHub heading slug: lowercase, drop punctuation except - and _, one hyphen
// per space. Markdown link syntax, code ticks and emphasis are stripped first.
export function githubSlug(heading) {
  return heading
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/<[^>]+>/g, "")
    .replace(/`/g, "")
    .replace(/\*+/g, "")
    .replace(/(^|\s)_+|_+(\s|$)/g, "$1$2")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, "")
    .replace(/ /g, "-");
}

// Every anchor a markdown file defines: heading slugs (with GitHub's -1, -2
// suffix for repeats), <a id>/<a name>, and {#id} attributes.
export function anchorsOf(text) {
  const anchors = new Set();
  const seen = new Map();
  for (const l of scanMarkdown(text)) {
    if (l.fenced) continue;
    const h = /^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/.exec(l.text);
    if (h) {
      let title = h[1];
      const attr = /\{#([^}\s]+)\}\s*$/.exec(title);
      if (attr) { anchors.add(attr[1]); title = title.replace(/\s*\{#[^}]+\}\s*$/, ""); }
      const base = githubSlug(title);
      const n = seen.get(base) || 0;
      seen.set(base, n + 1);
      anchors.add(n === 0 ? base : `${base}-${n}`);
    }
    for (const m of l.text.matchAll(/<a\s+[^>]*(?:id|name)\s*=\s*["']([^"']+)["']/gi)) anchors.add(m[1]);
  }
  return anchors;
}

// Restrict README.md to its setup sections: a heading that names setup,
// install, getting started, local or remote, deploy or self-host, and its
// sub-headings. Returns the set of line numbers in scope.
export function setupSectionLines(text) {
  const lines = text.split("\n");
  const keep = new Set();
  let level = 0; // 0: outside a setup section
  let fenced = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s{0,3}(```|~~~)/.test(line)) fenced = !fenced;
    const h = !fenced && /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      const lv = h[1].length;
      if (level && lv <= level) level = 0;
      if (!level && /set ?up|install|get(ting)? started|quick ?start|local or remote|self-host|deploy|sign[ -]?in/i.test(h[2])) level = lv;
    }
    if (level) keep.add(i + 1);
  }
  return keep;
}

// ── distance, for the nearest correct value ─────────────────────────────────

export function editDistance(a, b) {
  if (a === b) return 0;
  const m = a.length, n = b.length;
  if (!m) return n;
  if (!n) return m;
  let prev = new Array(n + 1);
  for (let j = 0; j <= n; j++) prev[j] = j;
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[n];
}

export function nearest(value, candidates) {
  let best = null, bestD = Infinity;
  for (const c of candidates) {
    if (Math.abs(c.length - value.length) >= bestD) continue;
    const d = editDistance(value, c);
    if (d < bestD || (d === bestD && c < best)) { best = c; bestD = d; }
  }
  return best;
}

// ── ground truth: the repo ──────────────────────────────────────────────────

function gitFiles(root) {
  const out = execFileSync("git", ["ls-files", "-z"], { cwd: root, maxBuffer: 256 * 1024 * 1024 }).toString();
  return out.split("\0").filter(Boolean);
}

const TEST_FILE = /(_test\.(go|exs?)$|\.test\.[a-z]+$|\.spec\.[a-z]+$|(^|\/)(test|tests|__tests__|fixtures|testdata)\/)/;
const CODE_EXT = /\.(go|ex|exs|eex|heex|sh|bash|ya?ml|toml|ts|tsx|mjs|cjs|js|bicep|bicepparam|tf|ps1|py|txt|json)$|(^|\/)(Dockerfile[^/]*|Makefile|entrypoint\.sh|start\.sh|\.env\.example)$/;

export class Repo {
  constructor(root) {
    this.root = root;
    this.files = gitFiles(root);
    this.fileSet = new Set(this.files);
    this.dirSet = new Set();
    for (const f of this.files) {
      let d = posix.dirname(f);
      while (d !== "." && !this.dirSet.has(d)) { this.dirSet.add(d); d = posix.dirname(d); }
    }
    this.topLevel = new Set(this.files.map((f) => f.split("/")[0]));
    this._text = new Map();
  }
  read(rel) {
    if (!this._text.has(rel)) {
      let t = null;
      try { t = readFileSync(join(this.root, rel), "utf8"); } catch { t = null; }
      this._text.set(rel, t);
    }
    return this._text.get(rel);
  }
  // A gitignored path (api/uploads) is made at run time, so it is real.
  ignored(rel) {
    for (const p of [rel, rel + "/x"]) {
      try { execFileSync("git", ["check-ignore", "-q", "--no-index", p], { cwd: this.root, stdio: "ignore" }); return true; } catch { /* not ignored */ }
    }
    return false;
  }
  exists(rel) {
    const r = rel.replace(/\/+$/, "");
    return this.fileSet.has(r) || this.dirSet.has(r) || existsSync(join(this.root, r));
  }
}

// Env var names the code reads or sets. Same idea as the -update branch of
// TestInstanceKnownSettingsList, widened to every non-test code file, and run
// on every check so the list never needs a hand refresh.
export function knownEnvNames(repo) {
  const names = new Set();
  const re = /\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/g;
  for (const f of repo.files) {
    if (!CODE_EXT.test(f) || TEST_FILE.test(f)) continue;
    if (f.startsWith("docs/") || f.startsWith("changelog/") || f.startsWith("tooling/doc-truth/")) continue;
    if (f.endsWith(".txt") && f !== "internal/cli/instance_known_settings.txt") continue;
    let st;
    try { st = statSync(join(repo.root, f)); } catch { continue; }
    if (st.size > 2 * 1024 * 1024) continue;
    const t = repo.read(f);
    if (!t) continue;
    for (const m of t.matchAll(re)) names.add(m[0]);
  }
  return names;
}

// Every quoted lowercase literal and "--flag" literal in the CLI's Go sources.
// A flag or positional word a doc prints must appear as one of these.
export function cliLiterals(repo) {
  const lits = new Set();
  const flags = new Set();
  for (const f of repo.files) {
    if (!/^(internal\/cli|cmd\/barkpark|internal\/setup)\/.*\.go$/.test(f) || TEST_FILE.test(f)) continue;
    const t = repo.read(f);
    if (!t) continue;
    for (const m of t.matchAll(/"(-{1,2}[a-zA-Z][a-zA-Z0-9-]*)(?:=|"|\s)/g)) flags.add(m[1]);
    for (const m of t.matchAll(/"([a-z][a-z0-9_-]*)"/g)) lits.add(m[1]);
    for (const m of t.matchAll(/`([a-z][a-z0-9_-]*)`/g)) lits.add(m[1]);
  }
  return { lits, flags };
}

// ── ground truth: the routers ───────────────────────────────────────────────

const VERB_RE = /^\s*(get|post|put|patch|delete|options|head|match|live|forward|live_dashboard|resources)\s*\(?\s*(?::[a-z*]+\s*,\s*)?(?:"([^"]*)")?/;

// Parse a Phoenix router's scope/route tree. Returns route patterns as
// { path, prefix, at } where prefix means "any path under this one".
export function parsePhoenixRouter(text, file, pluginPaths = []) {
  const routes = [];
  const lines = text.split("\n");
  const stack = []; // frames: { scope: "/x" | null }
  let pendingScope = null;
  const join2 = (...parts) => ("/" + parts.join("/")).replace(/\/+/g, "/").replace(/(.)\/$/, "$1");
  const prefix = () => join2(...stack.filter((f) => f.scope).map((f) => f.scope));
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const line = raw.replace(/(^|\s)#.*$/, "");
    if (!line.trim()) continue;
    const sc = /^\s*scope\s*\(?\s*(?:path:\s*)?"([^"]*)"/.exec(line);
    const opensBlock = /\bdo\s*$/.test(line) || /\bfn\b[^]*->\s*$/.test(line);
    if (sc) {
      if (opensBlock) stack.push({ scope: sc[1] });
      else pendingScope = sc[1];
      continue;
    }
    if (pendingScope !== null && opensBlock) { stack.push({ scope: pendingScope }); pendingScope = null; continue; }
    const v = VERB_RE.exec(line);
    if (v) {
      let p = v[2];
      if (p === undefined) {
        // multi-line call: `post(` then the path on a following line
        for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
          const q = /^\s*"([^"]*)"/.exec(lines[j]);
          if (q) { p = q[1]; break; }
        }
      }
      if (p !== undefined) {
        const full = join2(prefix(), p);
        const pre = v[1] === "forward" || v[1] === "live_dashboard";
        routes.push({ path: full, prefix: pre, at: `${file}:${i + 1}` });
        if (v[1] === "resources") {
          for (const s of [":id", "new", ":id/edit"]) routes.push({ path: join2(full, s), prefix: false, at: `${file}:${i + 1}` });
        }
      }
      if (opensBlock) stack.push({ scope: null });
      continue;
    }
    if (/^\s*plugin_routes\s*\(/.test(line)) {
      for (const pp of pluginPaths) routes.push({ path: join2(prefix(), pp.path), prefix: false, at: pp.at });
      continue;
    }
    if (opensBlock) { stack.push({ scope: null }); continue; }
    if (/^\s*end\b/.test(line)) { stack.pop(); continue; }
  }
  return routes;
}

// Plug.Router (the cloud app): flat `get "/x" do` routes, no scopes.
export function parsePlugRouter(text, file) {
  const routes = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const m = /^\s*(get|post|put|patch|delete|options|head|match|forward)\s*\(?\s*"(\/[^"]*)"/.exec(lines[i]);
    if (m) routes.push({ path: m[2], prefix: m[1] === "forward", at: `${file}:${i + 1}` });
  }
  return routes;
}

export function loadRoutes(repo) {
  const pluginPaths = [];
  for (const f of repo.files) {
    if (!/^api\/lib\/barkpark\/plugins\/.*\.ex$/.test(f)) continue;
    const t = repo.read(f) || "";
    const lines = t.split("\n");
    for (let i = 0; i < lines.length; i++) {
      for (const m of lines[i].matchAll(/\{\s*:(?:get|post|put|patch|delete|live|options|head)\s*,\s*"(\/[^"]*)"/g)) {
        pluginPaths.push({ path: m[1], at: `${f}:${i + 1}` });
      }
    }
  }
  const routes = [];
  const api = "api/lib/barkpark_web/router.ex";
  const apiText = repo.read(api);
  if (!apiText) return { ok: false, why: `cannot read ${api}`, routes };
  routes.push(...parsePhoenixRouter(apiText, api, pluginPaths));
  const cloud = "cloud/lib/barkpark_cloud/web/router.ex";
  const cloudText = repo.read(cloud);
  if (cloudText) routes.push(...parsePlugRouter(cloudText, cloud));
  for (const ep of ["api/lib/barkpark_web/endpoint.ex"]) {
    const t = repo.read(ep) || "";
    const lines = t.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const s = /^\s*socket\s+"([^"]+)"/.exec(lines[i]);
      if (s) routes.push({ path: s[1], prefix: true, at: `${ep}:${i + 1}` });
      const st = /\bat:\s*"([^"]+)"/.exec(lines[i]);
      if (st && st[1] !== "/") routes.push({ path: st[1], prefix: true, at: `${ep}:${i + 1}` });
    }
  }
  if (routes.length < 100) return { ok: false, why: `router parse found only ${routes.length} routes`, routes };
  return { ok: true, routes };
}

const segs = (p) => p.split("/").filter(Boolean);
export const isDocPlaceholder = (s) =>
  /[<{$]|^:|^\*$|^\.\.\.$|^…$|^[A-Z][A-Z0-9_]*$/.test(s);

// A doc path matches when it equals a route pattern, is a prefix of one, or
// sits under a prefix route (forward, socket, static, *glob).
export function routeMatches(docPath, routes) {
  const d = segs(docPath);
  const docPrefix = d.length && d[d.length - 1] === "*";
  if (docPrefix) d.pop();
  for (const r of routes) {
    const rs = segs(r.path);
    let ok = true, i = 0;
    for (; i < d.length && i < rs.length; i++) {
      if (rs[i].startsWith("*")) { i = d.length; break; }
      if (isDocPlaceholder(d[i]) || rs[i].startsWith(":")) continue;
      if (d[i] !== rs[i]) { ok = false; break; }
    }
    if (!ok) continue;
    if (i >= d.length) return true;            // equal, or doc is a prefix of the route
    if (r.prefix && i >= rs.length) return true; // under a forward/socket/static mount
  }
  return false;
}

// ── ground truth: the CLI ───────────────────────────────────────────────────

async function loadCli(repo) {
  const { loadBpSources } = await import("./bp-cli-sources.mjs");
  const sources = loadBpSources({ root: repo.root });
  if (!sources.ok) return { ok: false, why: sources.errors.join("; ") };
  const nouns = new Set([...(sources.A ? sources.A.nouns : []), ...(sources.B || [])]);
  const rootNode = sources.D.nodes.get(sources.D.rootFn);
  if (rootNode) for (const c of rootNode.cases) nouns.add(c);
  const verbs = new Map();
  const addVerb = (n, v) => { if (!verbs.has(n)) verbs.set(n, new Set()); verbs.get(n).add(v); };
  if (sources.A) for (const [n, vs] of sources.A.verbs) for (const v of vs) addVerb(n, v);
  for (const [n, m] of sources.D.pairs) for (const v of m.keys()) addVerb(n, v);
  if (rootNode) {
    for (const n of rootNode.cases) {
      const callee = rootNode.edges.get(n);
      const node = (callee && sources.D.nodes.get(callee)) || sources.D.nodes.get(`${rootNode.id}::${n}`);
      if (node) for (const v of node.cases) addVerb(n, v);
    }
  }
  const flags = new Set(sources.globals);
  if (sources.A) for (const fs of sources.A.flags.values()) for (const f of fs) flags.add(f);
  for (const fs of sources.E.values()) for (const f of fs) flags.add(f);
  const { lits, flags: litFlags } = cliLiterals(repo);
  for (const f of litFlags) flags.add(f);
  // The server's own capability declarations. The manifest fixture is a
  // snapshot and lags the code, so the source it is built from counts too.
  const srv = serverCapabilities(repo);
  for (const [n, vs] of srv.verbs) { nouns.add(n); for (const v of vs) addVerb(n, v); }
  for (const f of srv.flags) flags.add(f);
  return { ok: true, sources, nouns, verbs, flags, lits };
}

// Commands and flags the server declares in api/lib: core_cmd("n.v", "n", "v")
// in capabilities.ex and %{id: "n.v", noun: "n", verb: "v"} maps in plugins.
export function serverCapabilities(repo) {
  const verbs = new Map();
  const flags = new Set();
  const add = (n, v) => { if (!verbs.has(n)) verbs.set(n, new Set()); verbs.get(n).add(v); };
  for (const f of repo.files) {
    if (!/^api\/lib\/.*\.ex$/.test(f)) continue;
    const t = repo.read(f);
    if (!t || !/core_cmd\(|\bverb:\s*"/.test(t)) continue;
    for (const m of t.matchAll(/core_cmd\(\s*"[^"]*",\s*"([^"]+)",\s*"([^"]+)"/g)) add(m[1], m[2]);
    for (const m of t.matchAll(/\bnoun:\s*"([^"]+)",\s*verb:\s*"([^"]+)"/g)) add(m[1], m[2]);
    for (const m of t.matchAll(/\bid:\s*"([a-z][a-z0-9_-]*)\.([a-z][a-z0-9_-]*)",\s*noun:/g)) add(m[1], m[2]);
    for (const m of t.matchAll(/\bflag\(\s*"([a-z][a-z0-9_-]*)"/g)) flags.add("--" + m[1]);
    for (const m of t.matchAll(/%\{\s*name:\s*"([a-z][a-z0-9_-]*)"/g)) flags.add("--" + m[1]);
  }
  return { verbs, flags };
}

// ── extraction ──────────────────────────────────────────────────────────────

const ENV_RE = /\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+(_\*?|\*)?(?![a-z0-9])/g;
const FS_ROOTS = new Set(["opt", "usr", "etc", "var", "tmp", "root", "home", "bin", "sbin", "dev", "proc", "srv", "mnt", "Users", "Applications", "Library", "System", "private", "run", "lib", "snap"]);
const PATH_EXT = /\.(md|sh|go|ex|exs|mjs|js|ts|tsx|json|ya?ml|toml|bicep|bicepparam|txt|ps1|py|sql|env|example|html|css)$/;

// Our host in a URL: a placeholder, localhost, an example domain.
export function isOurHost(host) {
  return /[<{$]/.test(host) || /^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?$/.test(host) ||
    /(^|\.)example(\.(com|org|net))?(:\d+)?$/.test(host) || /^(api|studio|cms|barkpark)\.[^.]+\.(example|test|local)/.test(host);
}

// Pull every checkable fact out of one markdown text. `inScope(line)` limits
// extraction to some lines (README setup sections). Pure apart from the input.
export function extractFacts(rel, text, { inScope = () => true, routeFirst = new Set(), topLevel = new Set() } = {}) {
  const facts = [];
  const add = (kind, line, value, extra = {}) => facts.push({ kind, file: rel, line, value, ...extra });
  let prevText = "";
  for (const l of scanMarkdown(text)) {
    const lastText = prevText;
    prevText = l.text;
    if (!inScope(l.line)) continue;
    const codeParts = l.fenced ? [l.text] : l.spans;
    const allText = l.fenced ? l.text : l.text;

    // env: ALL_CAPS names in code; BARKPARK_* anywhere
    const envSeen = new Set();
    for (const part of codeParts) {
      for (const m of part.matchAll(ENV_RE)) {
        if (envSeen.has(m[0])) continue;
        // `$NAME` or `${NAME}` is a shell variable the reader sets; only
        // BARKPARK_* names are ours by their prefix
        const before = part.slice(Math.max(0, m.index - 2), m.index);
        if (/\$\{?$/.test(before) && !m[0].startsWith("BARKPARK_")) continue;
        envSeen.add(m[0]);
        add("env", l.line, m[0].replace(/\*$/, ""));
      }
    }
    if (!l.fenced) {
      for (const m of l.prose.matchAll(/\bBARKPARK_[A-Z0-9_]*[A-Z0-9](_\*?|\*)?(?![a-z0-9])/g)) {
        if (envSeen.has(m[0])) continue;
        envSeen.add(m[0]);
        add("env", l.line, m[0].replace(/\*$/, ""));
      }
    }

    // links: markdown links, reference definitions, <a href>
    if (!l.fenced) {
      const linkText = l.text.replace(/(`+)[\s\S]+?\1/g, " ");
      for (const m of linkText.matchAll(/\]\(\s*<?([^)\s>]+)>?(?:\s+["'][^)]*)?\)/g)) add("link", l.line, m[1]);
      const ref = /^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(\s|$)/.exec(linkText);
      if (ref) add("link", l.line, ref[1]);
      for (const m of linkText.matchAll(/<a\s+[^>]*href\s*=\s*["']([^"']+)["']/gi)) add("link", l.line, m[1]);
    }

    // routes: URL paths on our hosts, and bare /paths whose first segment is a
    // route root (or a versioned API or probe path)
    const routeSrc = l.fenced ? l.text : [...l.spans, l.prose].join("  ");
    const stripped = routeSrc.replace(/\]\([^)]*\)/g, " ");
    const urlRe = /\bhttps?:\/\/([^\/\s)`'"\]]+)(\/[^\s)`'"\]]*)?/g;
    for (const m of stripped.matchAll(urlRe)) {
      if (!isOurHost(m[1]) || !m[2]) continue;
      const p = cleanRoute(m[2]);
      if (p && p !== "/") add("route", l.line, p);
    }
    const noUrls = stripped.replace(urlRe, " ");
    const routeSeen = new Set();
    // The first segment must be a route root. A code span that is only a path,
    // or `GET /path`, also counts when its first segment is one typo away from
    // a route root (/readyzz). Other bare paths are files or slash commands.
    const whole = new Set();
    if (!l.fenced) {
      for (const sp of l.spans) {
        const m = /^(?:(?:GET|POST|PUT|PATCH|DELETE|HEAD)\s+)?(\/[A-Za-z0-9_.:<>{}*%\/-]+)$/.exec(sp);
        if (m) whole.add(cleanRoute(m[1]));
      }
    }
    for (const m of noUrls.matchAll(/(?<![\w.~\/$}>\]-])(\/[A-Za-z0-9_.:<>{}*%-]+(?:\/[A-Za-z0-9_.:<>{}*%-]*)*)/g)) {
      const p = cleanRoute(m[1]);
      if (!p || routeSeen.has(p)) continue;
      const first = segs(p)[0] || "";
      if (FS_ROOTS.has(first) || /\.[a-z]{1,5}$/.test(first)) continue;
      const typo = whole.has(p) && [...routeFirst].some((r) => editDistance(r, first) <= (first.length >= 6 ? 2 : 1));
      if (typo || routeFirst.has(first) || /^v\d+$/.test(first) || /^(healthz?|livez|readyz)$/.test(first)) {
        routeSeen.add(p);
        // "there is no `/register`" states an absence; it is not a claim the route exists
        const at = l.text.indexOf(m[1]);
        const lead = (lastText + " " + l.text.slice(0, Math.max(0, at))).trimEnd() + " ";
        if (at >= 0 && /\b(no|not|never|without)\s+([\w-]+\s+){0,2}`?\s?$/i.test(lead)) continue;
        add("route", l.line, p);
      }
    }

    // paths: repo paths in code spans and fenced lines
    const pathParts = l.fenced ? l.text.split(/[\s"'=(),;|]+/) : l.spans.flatMap((s) => s.split(/\s+/));
    for (let tok of pathParts) {
      tok = tok.replace(/^[`'"(]+|[`'".,:;)]+$/g, "");
      const lineRef = /^(.*?)(?::\d+(?:[-:]\d+)*)$/.exec(tok);
      if (lineRef) tok = lineRef[1];
      tok = tok.replace(/^\.\//, "");
      // dot dirs (.cursor/, .codex/, .github/) name files in the reader's repo
      if (!tok || /[<>{}*$~\\[\]?]|^\.|^\/|:\/\/|^-/.test(tok)) continue;
      const parts = tok.split("/");
      if (parts.length >= 2 && topLevel.has(parts[0]) && parts.every((p) => /^[A-Za-z0-9_.@+-]*$/.test(p)) && parts[1] !== "") {
        add("path", l.line, tok.replace(/\/$/, ""), { anchored: true });
      } else if (parts.length >= 2 && PATH_EXT.test(tok) && /^[A-Za-z0-9_-]/.test(parts[0]) && !parts[0].includes(".") &&
                 parts.every((p) => /^[A-Za-z0-9_.@+-]+$/.test(p))) {
        add("path", l.line, tok, { anchored: false });
      }
    }
  }
  return facts;
}

function cleanRoute(p) {
  let s = p.replace(/[?#].*$/, "").replace(/[.,;:)'"`]+$/, "");
  if (s.length > 1) s = s.replace(/\/$/, "");
  if (!s.startsWith("/") || s === "/") return null;
  return s;
}

// Doc link string literals in Go and Elixir code: "docs/x.md#anchor" and
// github.com/FRIKKern/barkpark/blob/main/... URLs. Comments are skipped.
export function codeDocLinks(rel, text) {
  const out = [];
  const lines = text.split("\n");
  const comment = rel.endsWith(".go") ? /^\s*\/\// : /^\s*#/;
  let inDoc = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!rel.endsWith(".go") && /@(moduledoc|doc)\s+(""")/.test(line)) { inDoc = true; continue; }
    if (inDoc) { if (/^\s*"""/.test(line)) inDoc = false; continue; }
    if (comment.test(line)) continue;
    // a doc path anywhere inside a string on a code line: a constant, or a
    // "see docs/x.md" inside an error or help message
    for (const m of line.matchAll(/(?<![\w./-])(docs\/[A-Za-z0-9_./-]+\.md(?:#[A-Za-z0-9_-]+)?)/g)) {
      const q = (line.slice(0, m.index).match(/(?<!\\)["`]/g) || []).length;
      if (q % 2 === 1) out.push({ line: i + 1, target: m[1] });
    }
    for (const m of line.matchAll(/github\.com\/FRIKKern\/barkpark\/(?:blob|tree)\/main\/([A-Za-z0-9_./-]+(?:#[A-Za-z0-9_-]+)?)/g)) out.push({ line: i + 1, target: m[1] });
  }
  return out;
}

// ── checking ────────────────────────────────────────────────────────────────

export function checkLink(repo, fromFile, target, anchorCache = new Map()) {
  if (/^(https?:|mailto:|tel:|data:)/.test(target)) {
    const gh = /^https:\/\/github\.com\/FRIKKern\/barkpark\/(?:blob|tree)\/main\/([^?#]+)(#.*)?$/.exec(target);
    if (!gh) return null;
    return checkLink(repo, "", gh[1] + (gh[2] || ""), anchorCache);
  }
  const hashAt = target.indexOf("#");
  let pathPart = hashAt >= 0 ? target.slice(0, hashAt) : target;
  const anchor = hashAt >= 0 ? decodeURIComponent(target.slice(hashAt + 1)) : "";
  pathPart = pathPart.replace(/\?.*$/, "");
  let rel;
  if (!pathPart) rel = fromFile;
  else if (pathPart.startsWith("/")) rel = pathPart.slice(1);
  else rel = posix.normalize(posix.join(posix.dirname(fromFile || "x"), decodeURIComponent(pathPart)));
  if (rel.startsWith("..")) return null; // outside the repo
  if (!repo.exists(rel)) {
    const near = nearestFile(repo, rel);
    return { why: `link target ${pathPart || rel} does not exist`, nearest: near ? posix.relative(posix.dirname(fromFile || "x"), near) || near : null };
  }
  if (!anchor || !rel.endsWith(".md")) return null;
  if (!anchorCache.has(rel)) anchorCache.set(rel, anchorsOf(repo.read(rel) || ""));
  const anchors = anchorCache.get(rel);
  if (anchors.has(anchor) || anchors.has(anchor.toLowerCase())) return null;
  return { why: `anchor #${anchor} is not a heading in ${rel}`, nearest: nearestAnchor(repo, rel, anchor, anchorCache) };
}

// The closest heading for a moved section: most shared words, looking in the
// same file first and then in the docs beside it.
export function nearestAnchor(repo, rel, anchor, anchorCache = new Map()) {
  const STOP = new Set(["a", "an", "and", "for", "in", "of", "on", "the", "to", "with"]);
  const words = new Set(anchor.split("-").filter((w) => !STOP.has(w)));
  const dir = posix.dirname(rel);
  const files = [rel, ...repo.files.filter((f) => f !== rel && f.endsWith(".md") && posix.dirname(f) === dir)];
  let best = null;
  for (const f of files) {
    if (!anchorCache.has(f)) anchorCache.set(f, anchorsOf(repo.read(f) || ""));
    for (const a of anchorCache.get(f)) {
      const aw = a.split("-");
      const hit = aw.filter((w) => words.has(w)).length;
      const shared = hit * 10 - (aw.length - hit); // shared words, fewer extra words
      const d = editDistance(anchor, a);
      const cand = { f, a, shared, d, same: f === rel };
      if (!best || shared > best.shared || (shared === best.shared && cand.same && !best.same) ||
          (shared === best.shared && cand.same === best.same && d < best.d)) best = cand;
    }
  }
  if (!best) return null;
  return best.same ? `#${best.a}` : `${best.f}#${best.a}`;
}

function nearestFile(repo, rel) {
  const base = posix.basename(rel);
  const same = repo.files.filter((f) => posix.basename(f) === base);
  if (same.length) return nearest(rel, same);
  const dir = posix.dirname(rel);
  const sib = repo.files.filter((f) => posix.dirname(f) === dir);
  if (sib.length) return nearest(rel, sib);
  return nearest(rel, repo.files.filter((f) => f.split("/")[0] === rel.split("/")[0]));
}

export async function collectScope(repo) {
  const docs = new Map(); // rel -> inScope(line) predicate
  for (const f of repo.files) if (/^docs\/setup\/[^/]+\.md$/.test(f)) docs.set(f, () => true);
  if (repo.fileSet.has("README.md")) {
    const keep = setupSectionLines(repo.read("README.md") || "");
    docs.set("README.md", (ln) => keep.has(ln));
  }
  const codeLinks = [];
  for (const f of repo.files) {
    const isGo = /^(internal|cmd)\/.*\.go$/.test(f);
    const isEx = /^(api|cloud)\/lib\/.*\.exs?$/.test(f) || f === "api/entrypoint.sh";
    if (!(isGo || isEx) || TEST_FILE.test(f)) continue;
    const t = repo.read(f);
    if (!t || !/docs\/[A-Za-z0-9_./-]+\.md|FRIKKern\/barkpark\/(blob|tree)/.test(t)) continue;
    for (const l of codeDocLinks(f, t)) {
      codeLinks.push({ file: f, line: l.line, target: l.target });
      // docs the CLI links to join the scope; server links are only resolved
      const doc = l.target.replace(/#.*$/, "");
      if (isGo && doc.endsWith(".md") && repo.fileSet.has(doc) && !docs.has(doc)) docs.set(doc, () => true);
    }
  }
  return { docs, codeLinks };
}

// Load every source of truth once. Returns { ok, errors, ...context }.
export async function loadContext(root) {
  const repo = new Repo(root);
  const errors = [];
  const cli = await loadCli(repo);
  if (!cli.ok) errors.push(`CLI sources: ${cli.why}`);
  const rt = loadRoutes(repo);
  if (!rt.ok) errors.push(`routes: ${rt.why}`);
  const env = knownEnvNames(repo);
  if (env.size < 200) errors.push(`env names: only ${env.size} found in code`);
  if (errors.length) return { ok: false, errors };
  const { extractClaims } = await import("./verify-docs.mjs");
  const lib = await import("./bp-cli-sources.mjs");
  return {
    ok: true, errors, repo, cli, rt, env, envList: [...env], extractClaims, lib,
    routeFirst: new Set(rt.routes.map((r) => segs(r.path)[0]).filter((s) => s && !s.startsWith(":") && !s.startsWith("*"))),
    routeStrings: [...new Set(rt.routes.map((r) => r.path))],
    anchorCache: new Map(),
  };
}

// Check one doc's text. `rel` decides how relative links resolve.
export function checkDocText(ctx, rel, text, inScope = () => true) {
  const { repo, env, envList, rt, cli } = ctx;
  const out = [];
  const push = (f) => out.push(f);
  for (const f of extractFacts(rel, text, { inScope, routeFirst: ctx.routeFirst, topLevel: repo.topLevel })) {
    if (f.kind === "env") {
      const name = f.value;
      if (/_$/.test(name)) {
        if (!envList.some((e) => e.startsWith(name))) push({ ...f, why: `no env var in code starts with ${name}`, nearest: nearest(name, envList) });
      } else if (!env.has(name)) {
        push({ ...f, why: `env var ${name} is not named in server, deploy or CLI code`, nearest: nearest(name, envList) });
      }
    } else if (f.kind === "link") {
      const r = checkLink(repo, rel, f.value, ctx.anchorCache);
      if (r) push({ ...f, why: r.why, nearest: r.nearest });
    } else if (f.kind === "route") {
      if (!routeMatches(f.value, rt.routes)) push({ ...f, why: `HTTP path ${f.value} matches no route in the routers`, nearest: nearest(f.value, ctx.routeStrings) });
    } else if (f.kind === "path") {
      if (f.anchored) {
        if (!repo.exists(f.value) && !repo.exists(f.value + ".md") && !repo.ignored(f.value)) push({ ...f, why: `repo path ${f.value} does not exist`, nearest: nearestFile(repo, f.value) });
      } else if (!repo.exists(f.value) && !repo.files.some((x) => x.endsWith("/" + f.value)) && !repo.exists(posix.join(posix.dirname(rel), f.value))) {
        // unanchored (config/runtime.exs): must exist somewhere as a suffix
        push({ ...f, why: `file ${f.value} matches no repo path`, nearest: nearestFile(repo, f.value) });
      }
    }
  }

  // bp commands and their flags
  const scopeText = text.split("\n").map((ln, i) => (inScope(i + 1) ? ln : "")).join("\n");
  const seen = new Set();
  for (const c of ctx.extractClaims(rel, scopeText)) {
    if (c.type !== "command" || (c.target.head !== "bp" && c.target.head !== "barkpark")) continue;
    // an inline span that reads as a sentence quotes bp output, not a command
    if (!c.fenced && /\s/.test(c.target.full) && /[.!?]$/.test(c.target.full)) continue;
    const key = `${c.line}\0${c.target.full}`;
    if (seen.has(key)) continue;
    seen.add(key);
    for (const f of checkBpLine(c.target.full, cli, ctx.lib)) {
      push({ kind: f.kind, file: rel, line: c.line, value: f.value, why: f.why, nearest: f.nearest });
    }
  }
  return out;
}

export async function runCheck(root) {
  const ctx = await loadContext(root);
  if (!ctx.ok) return { ok: false, errors: ctx.errors, findings: [] };
  const { docs, codeLinks } = await collectScope(ctx.repo);
  const findings = [];
  for (const [rel, inScope] of docs) findings.push(...checkDocText(ctx, rel, ctx.repo.read(rel) || "", inScope));
  for (const l of codeLinks) {
    const r = checkLink(ctx.repo, "", l.target, ctx.anchorCache);
    if (r) findings.push({ kind: "link", file: l.file, line: l.line, value: l.target, why: `doc link constant: ${r.why}`, nearest: r.nearest });
  }
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.kind.localeCompare(b.kind));
  const c = ctx;
  return { ok: true, errors: [], findings, counts: { docs: docs.size, codeLinks: codeLinks.length, routes: c.rt.routes.length, env: c.env.size, nouns: c.cli.nouns.size, flags: c.cli.flags.size } };
}

// Check one printed bp line: the noun, the verb and every --flag.
export function checkBpLine(line, cli, lib) {
  const out = [];
  const { tokens, text } = lib.splitCommandLine(line);
  if (tokens.length < 2) return out;
  // flags, against every flag the CLI or manifest knows
  for (const t of tokens.slice(1)) {
    if (!/^--[a-zA-Z]/.test(t)) continue;
    const f = t.split("=")[0].replace(/[),.;:]+$/, "");
    if (cli.flags.has(f) || cli.lits.has(f.slice(2))) continue;
    out.push({ kind: "flag", value: f, why: `flag ${f} is not read by the CLI or listed in the manifest`, nearest: nearest(f, cli.flags) });
  }
  const r = lib.resolveBpCommand(cli.sources, line, {});
  if (r.verdict !== lib.UNRESOLVED) return out;
  for (const reason of r.reasons) {
    let m;
    if ((m = /^`bp (\S+)` — head `([^`]+)` resolves in NO source/.exec(reason))) {
      if (cli.nouns.has(m[2])) continue;
      out.push({ kind: "cmd", value: `bp ${m[2]}`, why: `bp has no command ${m[2]}`, nearest: `bp ${nearest(m[2], cli.nouns)}` });
    } else if ((m = /^`bp (\S+) (\S+)` — `([^`]+)` is (?:neither a verb|not dispatched)/.exec(reason))) {
      // only `bp <noun> <verb>`; deeper words are arguments
      const noun = m[1], tok = m[3];
      const vs = cli.verbs.get(noun) || new Set();
      if (vs.has(tok) || cli.lits.has(tok)) continue; // a verb, or a word the CLI spells (onramp targets, seed types)
      out.push({ kind: "cmd", value: `bp ${noun} ${tok}`, why: `bp ${noun} has no verb ${tok}`, nearest: vs.size ? `bp ${noun} ${nearest(tok, vs)}` : null });
    }
  }
  return out;
}

// ── allow-list ──────────────────────────────────────────────────────────────

// One entry per line: file | kind | value | owner | reason. The owner is the
// task that fixes the fact, or a label for a fact that is right as written:
// `external` (a name another tool or repo reads, such as a Copilot secret
// prefix), `example` (a made-up name in an example) or `history` (a dated
// record naming a file as it was then). Matching
// ignores the line number, so an edit above a known failure keeps its entry.
export function parseAllow(text) {
  const entries = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i].trim();
    if (!l || l.startsWith("#")) continue;
    const parts = l.split("|").map((s) => s.trim());
    if (parts.length < 5 || !/^(task-[0-9a-f]{16}|external|example|history)$/.test(parts[3]) || !parts[4]) {
      throw new Error(`${ALLOW_FILE}:${i + 1}: want "file | kind | value | task-<16 hex>, external, example or history | reason"`);
    }
    entries.push({ file: parts[0], kind: parts[1], value: parts[2], task: parts[3], reason: parts.slice(4).join("|"), at: i + 1 });
  }
  return entries;
}

export function applyAllow(findings, entries) {
  const used = new Set();
  const fresh = [], allowed = [];
  for (const f of findings) {
    const e = entries.find((a) => a.file === f.file && a.kind === f.kind && a.value === f.value);
    if (e) { used.add(e); allowed.push({ ...f, task: e.task }); } else fresh.push(f);
  }
  const stale = entries.filter((e) => !used.has(e));
  return { fresh, allowed, stale };
}

export function formatFinding(f) {
  return `${f.file}:${f.line}: ${f.kind}: ${f.why}; nearest: ${f.nearest || "(none)"}`;
}

// ── main ────────────────────────────────────────────────────────────────────

async function main(argv) {
  const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
  const json = argv.includes("--json");
  const all = argv.includes("--all");
  const res = await runCheck(root);
  if (!res.ok) {
    for (const e of res.errors) console.error(`setup-facts: cannot check: ${e}`);
    return 2;
  }
  let entries = [];
  try {
    entries = parseAllow(existsSync(join(root, ALLOW_FILE)) ? readFileSync(join(root, ALLOW_FILE), "utf8") : "");
  } catch (e) {
    console.error(`setup-facts: ${e.message}`);
    return 2;
  }
  const { fresh, allowed, stale } = applyAllow(res.findings, entries);
  if (json) {
    process.stdout.write(JSON.stringify({ counts: res.counts, fresh, allowed, stale }, null, 2) + "\n");
    return fresh.length ? 1 : 0;
  }
  const c = res.counts;
  console.log(`setup-facts: ${c.docs} docs, ${c.codeLinks} doc link constants; checked against ${c.env} env names, ${c.nouns} bp nouns, ${c.flags} flags, ${c.routes} routes`);
  if (all) for (const f of allowed) console.log(`allowed (${f.task}): ${formatFinding(f)}`);
  else if (allowed.length) console.log(`${allowed.length} finding(s) match ${ALLOW_FILE}; --all prints them`);
  for (const e of stale) console.log(`note: ${ALLOW_FILE}:${e.at} no longer fails (${e.file} ${e.kind} ${e.value}); delete the line`);
  for (const f of fresh) console.log(formatFinding(f));
  if (fresh.length) {
    console.log(`setup-facts: FAIL, ${fresh.length} wrong fact(s). Fix the doc or the code. A failure that must wait goes in ${ALLOW_FILE} with its task.`);
    return 1;
  }
  console.log("setup-facts: PASS");
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === normalize(process.argv[1])) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => { console.error(e.stack || String(e)); process.exit(2); });
}
