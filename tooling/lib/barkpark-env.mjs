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

// ── BACKPRESSURE IS NOT A FAULT ─────────────────────────────────────────────
//
// MEASURED 2026-09-01 17:02Z: under this campaign's own load — 18 agent lanes,
// each with a pulse loop and its own queries — the ledger answered `bp task
// ready` with HTTP 429 and `retry_after=1`. Consumers across tooling/ map ANY
// non-2xx to a terminal fault (`if (!r.ok) … process.exit(2)`), so a ONE SECOND
// wait was reported to the operator as a broken ledger.
//
// A 429 is the only non-2xx that carries its own remedy: a 401 is a refusal, a
// 404 an absence, a 500 a fault — none of them change by being asked again. The
// server is saying "ask me again in one second", and a tool that reads that as
// an outage teaches its operator to distrust the instrument.
//
// tooling/barkpark-sync/push.mjs already learned this the hard way and grew its
// own inline loop. This is that pattern, lifted into the one module every
// tooling script already imports for its connection, so the NEXT consumer gets
// it by importing rather than by rediscovering it under load.
//
// BOUNDED, because an unbounded backoff is its own outage:
//   * the wait comes from the server (`Retry-After`, else the envelope's
//     `error.details.retry_after`), never from our own guesswork;
//   * a single wait above MAX_WAIT_S is NOT slept out — the pulse plugin answers
//     `Retry-After: 3600` on a spent daily cap, and honoring that literally
//     would be indistinguishable from a hung process;
//   * the total wait per call is capped;
//   * every backoff says so on stderr, so a slow command is never a mystery.
export const BACKPRESSURE = { ATTEMPTS: 4, DEFAULT_WAIT_S: 1, MAX_WAIT_S: 5, MAX_TOTAL_WAIT_S: 10 };

// Pull the server's requested wait out of a Response + its already-read body.
// The header is the standard spelling; `error.details.retry_after` is what
// `Errors.to_envelope({:error, :rate_limited, %{retry_after: s}})` puts in the
// body. Returns null when the server named nothing, so the caller can say so
// rather than claiming the server asked for a number we invented.
export function retryAfterOf(res, text) {
  const h = Number(res && res.headers && res.headers.get && res.headers.get("retry-after"));
  if (isFinite(h) && h >= 0 && (res.headers.get("retry-after") ?? "") !== "") return h;
  try {
    const d = JSON.parse(text);
    const n = Number(d && d.error && d.error.details && d.error.details.retry_after);
    if (isFinite(n) && n >= 0) return n;
  } catch { /* a body that is not our envelope names no wait */ }
  return null;
}

// fetch, with the bounded 429 backoff above. Returns { ok, status, body, res,
// throttled, gaveUp } — `body` is the text, already read, so a caller never has
// to worry about a consumed stream across retries.
//
// It retries a 429 for ANY method, and that is deliberate rather than careless:
// every 429 this API emits comes from a Plug that HALTS the pipeline
// (api/lib/barkpark_web/plugs/rate_limit.ex and its two siblings all
// `put_status(429) |> halt()`), so the handler never ran and the write provably
// did not happen. Replaying a refused request cannot duplicate it. Anything
// that is NOT a 429 is returned untouched on the first answer.
export async function fetchBackpressureAware(url, init = {}, opts = {}) {
  const sleep = opts.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  const say = opts.say || ((m) => process.stderr.write(m + "\n"));
  const doFetch = opts.fetch || fetch;
  let waited = 0;
  for (let attempt = 1; ; attempt++) {
    const res = await doFetch(url, init);
    const body = await res.text();
    if (res.status !== 429) return { ok: res.ok, status: res.status, body, res, throttled: false };

    const asked = retryAfterOf(res, body);
    const wait = asked === null ? BACKPRESSURE.DEFAULT_WAIT_S : asked;
    const give = (why) => ({ ok: false, status: 429, body, res, throttled: true, gaveUp: why });

    if (wait > BACKPRESSURE.MAX_WAIT_S)
      return give(`the server asked for ${wait}s, longer than this tool will wait on your behalf (${BACKPRESSURE.MAX_WAIT_S}s); returned unslept`);
    if (attempt >= BACKPRESSURE.ATTEMPTS)
      return give(`the attempt cap of ${BACKPRESSURE.ATTEMPTS} is spent (waited ${waited}s in total)`);
    if (waited + wait > BACKPRESSURE.MAX_TOTAL_WAIT_S)
      return give(`a further ${wait}s would exceed the ${BACKPRESSURE.MAX_TOTAL_WAIT_S}s total-wait budget (already waited ${waited}s)`);

    say(`[barkpark] rate limited (429) by ${url} — BACKPRESSURE, not a fault; waiting ${wait}s (${asked === null ? "no retry_after given, using our default" : "the server asked for it"}) and retrying (attempt ${attempt} of ${BACKPRESSURE.ATTEMPTS})`);
    await sleep(wait * 1000);
    waited += wait;
  }
}
