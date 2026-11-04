// Scanner used by the Barkpark-owned workflow path-filter integration test and
// the package-owned synthetic scanner test.
//
// The filter was hand-kept, and it went blind more than once: a suite added a
// read of bp-modal-focus.js, bp-tab-keys.js, nav.ex or the pd-parity corpus, and
// a change to that file alone never ran the suite that pins it. This derives
// the reads instead of trusting a list:
//   1. entry points: every `node <file>`, `npm test` and `npm run <script>` in
//      the workflow, expanded through package.json (pre/post hooks, nested
//      `npm run`, `esbuild <entry>`), and through scripts/test-chain.mjs, which
//      runs every file its chain() lists;
//   2. from each reachable file, every path it names that exists: "./x" and
//      "../x" literals, bare repo paths ("api/x"), `${ROOT}/x` templates,
//      ROOT + "/x" concats, join/resolve(ROOT, "a", "b/c", …), and CSS url(x).
//      Each resolves against the file's folder, the package root and the repo
//      root, first hit wins. Inside the package it is followed, outside it is a
//      sink. A folder, or the fixed prefix before a template hole, is a folder
//      sink: a new file in it must trigger too.
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, relative, resolve, sep } from "node:path";
const SCANNED = new Set([".js", ".mjs", ".cjs", ".css", ".html", ".json"]);

export function filterArms(yml) {
  const arms = {};
  let arm = null;
  let inPaths = false;
  for (const line of yml.split("\n")) {
    const key = line.match(/^  ([a-z_]+):\s*$/);
    if (key) { arm = key[1]; inPaths = false; continue; }
    if (/^\S/.test(line)) { arm = null; inPaths = false; continue; }
    if (arm && /^    paths:\s*$/.test(line)) { inPaths = true; arms[arm] = []; continue; }
    if (!inPaths) continue;
    const entry = line.match(/^      - ["']?([^"'#]+?)["']?\s*$/);
    if (entry) arms[arm].push(entry[1]);
    else if (/^    \S/.test(line)) inPaths = false;
  }
  return arms;
}

export function globToRegExp(pattern) {
  let re = "";
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "*" && pattern[i + 1] === "*") { re += ".*"; i++; }
    else if (c === "*") re += "[^/]*";
    else re += c.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

function kind(p) {
  if (!existsSync(p)) return null;
  return statSync(p).isDirectory() ? "dir" : "file";
}

function firstExisting(bases, lit) {
  return bases.map((base) => resolve(base, lit)).find((p) => existsSync(p));
}

const LITERAL = /(["'`])((?:(?!\1)[^\\\n]|\\.)*)\1/g;
const IDENT = /^[A-Za-z_$][\w$.]*$/;

function fixedPart(lit) {
  const hole = lit.indexOf("${");
  const fixed = hole < 0 ? lit : lit.slice(0, lit.lastIndexOf("/", hole) + 1);
  return { fixed: fixed.replace(/[?#].*$/, ""), templated: hole >= 0 };
}

function splitArgs(inner) {
  const args = [];
  let depth = 0, quote = null, start = 0;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth--;
    else if (c === "," && depth === 0) { args.push(inner.slice(start, i).trim()); start = i + 1; }
  }
  args.push(inner.slice(start).trim());
  return args;
}

const literalValue = (arg) => {
  const m = arg.match(/^(["'`])([\s\S]*)\1$/);
  return m ? m[2] : null;
};

export function scanner({ repo, pkg, notRead = new Map(), self = null, runs = new Map() }) {
  const inside = (p) => p === pkg || p.startsWith(pkg + sep);
  const inRepo = (p) => p.startsWith(repo + sep);
  const ancestorOfPkg = (p) => pkg.startsWith(p + sep);
  const repoPath = (p) => relative(repo, p).split(sep).join("/");

  function candidates(file, text) {
    const out = [];
    const add = (lit, bases) => {
      const { fixed, templated } = fixedPart(lit);
      const path = firstExisting(bases, fixed);
      if (path) out.push({ path, templated });
    };
    const here = [dirname(file), pkg];
    const anywhere = [dirname(file), pkg, repo];
    for (const m of text.matchAll(LITERAL)) {
      const lit = m[2];
      if (/^\.\.?\//.test(lit)) add(lit, here);
      else if (/^[A-Za-z_][\w.@-]*\//.test(lit)) add(lit, [repo]);
      const head = lit.match(/^\$\{[A-Za-z_$][\w$.]*\}\/(.+)$/s);
      if (head) add(head[1], anywhere);
    }
    for (const m of text.matchAll(/[A-Za-z_$][\w$.]*\s*\+\s*(["'`])\/([^"'`\n]+)\1/g)) add(m[2], anywhere);
    for (const m of text.matchAll(/\b(?:join|resolve)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g)) {
      const [first, ...rest] = splitArgs(m[1]);
      if (!IDENT.test(first)) continue;
      const parts = [];
      for (const arg of rest) {
        const v = literalValue(arg);
        if (v === null) break;
        parts.push(v);
      }
      if (parts.length) add(parts.join("/"), anywhere);
    }
    if (extname(file) === ".css") {
      for (const m of text.matchAll(/url\(\s*([^"')\s]+)\s*\)/g)) add(m[1], here);
    }
    return out;
  }

  function sinkOf(file, { path, templated }) {
    if (!inRepo(path) || ancestorOfPkg(path) || path.includes(`${sep}node_modules${sep}`)) return null;
    const k = kind(path);
    if (templated && k !== "dir") return null;
    if (inside(path)) return k === "file" ? { follow: path } : null;
    const sink = k === "dir" ? `${repoPath(path)}/` : repoPath(path);
    if (notRead.has(sink) && (file === self || notRead.get(sink) === relative(pkg, file).split(sep).join("/"))) return null;
    return { sink };
  }

  function reads(yml, scripts) {
    const sinks = new Map();
    const queue = [];
    const visited = new Set();
    const expanded = new Set();
    const expand = (name) => {
      for (const hook of [`pre${name}`, name, `post${name}`]) {
        if (expanded.has(hook) || typeof scripts[hook] !== "string") continue;
        expanded.add(hook);
        commands(scripts[hook]);
      }
    };
    const commands = (text) => {
      for (const m of text.matchAll(/\bnode\s+([^\s&|;"'>]+\.(?:mjs|cjs|js))/g)) {
        const file = resolve(pkg, m[1]);
        queue.push(file, ...(runs.get(file) || []));
      }
      for (const m of text.matchAll(/\besbuild\s+([^\s&|;"'>-][^\s&|;"'>]*)/g)) queue.push(resolve(pkg, m[1]));
      for (const m of text.matchAll(/\bnpm\s+run\s+([\w:-]+)/g)) expand(m[1]);
      for (const m of text.matchAll(/["']npm["'],\s*\[\s*["']run["'],\s*["']([\w:-]+)["']/g)) expand(m[1]);
      if (/\bnpm\s+test\b/.test(text)) expand("test");
    };
    commands(yml);
    const entries = queue.length;
    while (queue.length) {
      const file = queue.shift();
      if (visited.has(file) || kind(file) !== "file") continue;
      visited.add(file);
      if (!SCANNED.has(extname(file))) continue;
      const text = readFileSync(file, "utf8");
      commands(text);
      for (const c of candidates(file, text)) {
        const hit = sinkOf(file, c);
        if (hit?.follow) queue.push(hit.follow);
        else if (hit && !sinks.has(hit.sink)) sinks.set(hit.sink, repoPath(file));
      }
    }
    return { entries, sinks, visited };
  }

  return { candidates, sinkOf, reads };
}

export function verdict(arms, sinks, ownedPrefixes) {
  return {
    unequal: JSON.stringify(arms.push) !== JSON.stringify(arms.pull_request),
    missing: [...sinks].filter(([sink]) => !covers(arms.push, sink)).map(([sink, by]) => `${sink}  (read by ${by})`),
    unused: arms.push.filter((p) => !ownedPrefixes.some((prefix) => p.startsWith(prefix)) && ![...sinks.keys()].some((s) => covers([p], s))),
  };
}

export const covers = (patterns, sink) => {
  const probe = sink.endsWith("/") ? `${sink}a-new-file` : sink;
  return patterns.some((p) => globToRegExp(p).test(probe));
};
