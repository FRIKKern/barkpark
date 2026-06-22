// barkpark-env — the ONE place tooling resolves WHICH Barkpark it talks to.
//
// Until now every tooling/ script hard-coded `http://localhost:4000`. The bp
// CLI/TUI already resolve a connection through a precedence chain (see
// internal/cli/config.go + main.go); this is the node-side mirror of that chain,
// with the project-level layer (barkpark.json) the CLI was missing:
//
//   flag (--host/--dataset/--token) > BARKPARK_* env > barkpark.json > baked default
//
// plus a /v1/capabilities reachability probe and a local→public fallover, so a
// script launched with the local server down still finds the project's PUBLIC
// Barkpark when barkpark.json declares one. Dependency-free (matches the suite).
//
//   import { resolveEnv, banner } from "../lib/barkpark-env.mjs";
//   const ENV = await resolveEnv(process.argv.slice(2), { dataset: "codebase" });
//   console.error(banner(ENV, "push"));   // push → http://localhost:4000 [local] dataset=codebase via barkpark.json:local ✓

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const DEFAULT_HOST = "http://localhost:4000";
const DEFAULT_TOKEN = "barkpark-dev-token";

export function repoRoot(from = process.cwd()) {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: from }).toString().trim();
}

// barkpark.json is COMMITTED, PUBLIC and SECRET-FREE — it answers "where does
// this repo's Barkpark live", never "what's my token". Missing/invalid → {}.
export function loadConfig(root = repoRoot()) {
  const p = join(root, "barkpark.json");
  if (!existsSync(p)) return {};
  try { return JSON.parse(readFileSync(p, "utf8")); }
  catch (e) { process.stderr.write(`[barkpark-env] barkpark.json is not valid JSON: ${e.message}\n`); return {}; }
}

export const flag = (argv, name, def = null) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : def; };

const trim = (u) => String(u).replace(/\/+$/, "");
const hostUrl = (cfg, name) => { const h = cfg.hosts?.[name]; return typeof h === "string" ? h : h?.url; };

// local if loopback or a private/LAN address; else cloud. A host entry may pin
// `kind` explicitly (mirrors ServerEntry.Kind in the bp CLI); else it's derived.
export function kindOf(url, pinned) {
  if (pinned === "local" || pinned === "cloud") return pinned;
  try {
    const h = new URL(url).hostname;
    if (h === "localhost" || h === "127.0.0.1" || h === "::1" || h.endsWith(".local")) return "local";
    if (/^10\./.test(h) || /^192\.168\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h)) return "local";
    return "cloud";
  } catch { return "cloud"; }
}

// the canonical reachability check the suite already uses (status.mjs:71):
// GET /v1/capabilities → 2xx. AbortSignal.timeout keeps a dead host from hanging.
export async function probe(url, ms = 3000) {
  try { return (await fetch(trim(url) + "/v1/capabilities", { signal: AbortSignal.timeout(ms) })).ok; }
  catch { return false; }
}

// Resolve the full connection. opts.dataset is the LITERAL default dataset the
// caller hard-codes today (e.g. "codebase"); opts.datasetKey is an optional
// logical key looked up in barkpark.json `datasets` (e.g. "cody" → "cody-poc").
export async function resolveEnv(argv = process.argv.slice(2), opts = {}) {
  const root = repoRoot();
  const cfg = loadConfig(root);

  // ── host ──
  let host, source;
  const fHost = flag(argv, "--host");
  if (fHost) { host = fHost; source = "flag"; }
  else if (process.env.BARKPARK_API_URL) { host = process.env.BARKPARK_API_URL; source = "env"; }
  else if (cfg.defaultHost && hostUrl(cfg, cfg.defaultHost)) { host = hostUrl(cfg, cfg.defaultHost); source = `barkpark.json:${cfg.defaultHost}`; }
  else { host = DEFAULT_HOST; source = "default"; }
  host = trim(host);
  let pinned = (cfg.hosts && Object.values(cfg.hosts).find((h) => typeof h === "object" && trim(h.url) === host)?.kind) || undefined;

  // ── probe + fallover ── only when the host was DERIVED (config/default), never
  // when explicitly forced by flag/env. Prefer a declared host that is reachable.
  let reachable = await probe(host);
  let fellOver = null;
  const explicit = source === "flag" || source === "env";
  if (!reachable && !explicit && cfg.hosts) {
    const candidates = Object.entries(cfg.hosts)
      .map(([name, h]) => ({ name, url: trim(typeof h === "string" ? h : h?.url || ""), kind: typeof h === "object" ? h.kind : undefined }))
      .filter((c) => c.url && c.url !== host)
      .sort((a, b) => (kindOf(b.url, b.kind) === "cloud") - (kindOf(a.url, a.kind) === "cloud")); // prefer cloud as the fallover
    for (const c of candidates) {
      if (await probe(c.url)) { host = c.url; source = `barkpark.json:${c.name}`; reachable = true; fellOver = c.name; pinned = c.kind; break; }
    }
  }

  // ── dataset ──  flag > env > barkpark.json[datasetKey] > caller default
  const dataset = flag(argv, "--dataset") || process.env.BARKPARK_DATASET
    || (opts.datasetKey && cfg.datasets?.[opts.datasetKey]) || opts.dataset || "production";

  // ── token ──  dev default; REAL creds come from env, never barkpark.json.
  const token = flag(argv, "--token") || process.env.BARKPARK_TOKEN || DEFAULT_TOKEN;

  return { root, cfg, host, kind: kindOf(host, pinned), source, reachable, fellOver, dataset, token };
}

export function banner(env, name = "barkpark") {
  const fo = env.fellOver ? ` (fell over to ${env.fellOver})` : "";
  return `${name} → ${env.host} [${env.kind}] dataset=${env.dataset} via ${env.source}${fo} ${env.reachable ? "✓" : "✗ UNREACHABLE"}`;
}
