// PLATFORM-AWARE REACH (task-403fe20b2a7f2743, Cody calibration).
//
// Reach is "how many files transitively depend on this one" (usefulness.mjs).
// It counted every dependency edge, including the edge from a BACKEND
// SELECTOR to a backend the deployed platform never selects. The calibration
// case: api/lib/barkpark/media/image_backend.ex picks a backend by OS
//
//     case :os.type() do
//       {:win32, _} -> Barkpark.Media.ImageBackend.Magick
//       _ -> Barkpark.Media.ImageBackend.Vix
//     end
//
// so on the Linux/ARM prod boxes Magick is never reached. Even so,
// critical-untested ranked magick.ex 99, the highest in the tree, because
// every dependent of image_backend.ex counted toward it.
//
// THE MODEL. Edges are never deleted from the index (the graph stays the graph).
// Instead each selector edge carries a VERDICT for the declared platform
// profile:
//
//   * "active"   the arm that names the target matches the profile (or is the
//                default arm with no earlier match), so the edge counts;
//   * "inactive" only arms for OTHER platforms name the target, so for this
//                profile the edge carries zero reach and the report says why;
//   * "dynamic"  the selector can be overridden at runtime (a config key read
//                ahead of the OS case) AND the deployed config sets that key, or
//                the case is not a literal :os.type() match. We cannot tell,
//                so the edge COUNTS (the conservative direction) and the report
//                names the state instead of assuming the target unreachable.
//
// The profile is DECLARED, never inferred from the machine running the
// tooling: a Mac computing reach for a Linux fleet must not score Linux-only
// code as dead. Precedence: explicit argument > CODY_PLATFORM env > the
// fleet default ("linux"). Every report states which profile it used.

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative } from "node:path";

export const DEFAULT_PROFILE = "linux";

// :os.type() family/name → the profile names an arm can match.
//   {:win32, _}        → win32
//   {:unix, :darwin}   → darwin
//   {:unix, :linux}    → linux
//   {:unix, _}         → unix (linux + darwin)
const UNIX = new Set(["linux", "darwin"]);

export function resolveProfile(explicit, env = process.env) {
  if (explicit) return { profile: explicit, source: "argument" };
  if (env.CODY_PLATFORM) return { profile: env.CODY_PLATFORM, source: "CODY_PLATFORM" };
  return { profile: DEFAULT_PROFILE, source: "default (the deployed fleet is Linux/ARM)" };
}

// Does an arm pattern match the profile? "*" is the catch-all arm.
function armMatches(pattern, profile) {
  if (pattern === "*") return true;
  if (pattern === "unix") return UNIX.has(profile);
  return pattern === profile;
}

// Parse every `case :os.type() do … end` block in one Elixir source. Returns
// [{arms: [{pattern, modules: [Mod]}], overridable: <config key|null>}].
// The parser is deliberately literal: an arm whose head is not one of the
// four shapes above makes the whole selector "dynamic".
export function parseOsSelectors(src) {
  const selectors = [];
  const re = /case\s+:os\.type\(\)\s+do([\s\S]*?)\n\s*end\b/g;
  let m;
  while ((m = re.exec(src))) {
    const body = m[1];
    const arms = [];
    let literal = true;
    for (const line of body.split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const am = t.match(/^(.+?)\s*->\s*(.*)$/);
      if (!am) continue;
      const head = am[1].trim();
      let pattern;
      if (/^\{:win32,\s*_\w*\}$/.test(head)) pattern = "win32";
      else if (/^\{:unix,\s*:darwin\}$/.test(head)) pattern = "darwin";
      else if (/^\{:unix,\s*:linux\}$/.test(head)) pattern = "linux";
      else if (/^\{:unix,\s*_\w*\}$/.test(head)) pattern = "unix";
      else if (/^_\w*$/.test(head)) pattern = "*";
      else { literal = false; continue; }
      const modules = [...am[2].matchAll(/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+)\b/g)].map((x) => x[1]);
      arms.push({ pattern, modules });
    }
    // A config read ahead of the OS default (`Application.get_env(app, key) ||`)
    // makes the selection overridable at runtime.
    const before = src.slice(0, m.index);
    const ov = [...before.matchAll(/Application\.get_env\(\s*:(\w+)\s*,\s*:(\w+)\s*\)\s*\|\|/g)].pop();
    selectors.push({ arms, literal, overridable: ov ? `${ov[1]}.${ov[2]}` : null });
  }
  return selectors;
}

// Is `key` (e.g. "barkpark.image_backend") set in any deployed config file?
export function configSets(key, configSrcs) {
  const [app, k] = key.split(".");
  const re = new RegExp(`config\\s+:${app}\\s*,[\\s\\S]{0,400}?\\b${k}:`, "m");
  const re2 = new RegExp(`config\\s+:${app}\\s*,\\s*:${k}\\b`);
  return configSrcs.some((s) => re.test(s) || re2.test(s));
}

// The verdict of the selector edge (selectorPath → targetModule) for a profile.
export function edgeVerdict(selector, targetModule, profile, configSrcs = []) {
  if (!selector.literal) return { state: "dynamic", why: "the :os.type() case has an arm this model cannot read" };
  if (selector.overridable && configSets(selector.overridable, configSrcs)) {
    return { state: "dynamic", why: `config sets ${selector.overridable}, which overrides the OS default at runtime` };
  }
  // First matching arm wins, as in Elixir.
  const chosen = selector.arms.find((a) => armMatches(a.pattern, profile));
  const naming = selector.arms.filter((a) => a.modules.includes(targetModule)).map((a) => a.pattern);
  if (!naming.length) return null; // not a selector edge for this target
  if (chosen && chosen.modules.includes(targetModule)) {
    return { state: "active", why: `selected on ${profile}`, arms: naming };
  }
  return {
    state: "inactive",
    why: `selected only on ${naming.join(", ")}; the ${profile} profile takes ${chosen ? chosen.modules.join(", ") || chosen.pattern : "no arm"}`,
    arms: naming,
  };
}

// Scan an api tree: module name → file, and file → its OS selectors.
export function scanElixir(root, libDir = "api/lib") {
  const moduleFile = {};
  const selectorsByFile = {};
  const base = join(root, libDir);
  if (!existsSync(base)) return { moduleFile, selectorsByFile };
  const walk = (d) => {
    for (const e of readdirSync(d)) {
      const p = join(d, e);
      if (statSync(p).isDirectory()) walk(p);
      else if (p.endsWith(".ex")) {
        const src = readFileSync(p, "utf8");
        const rel = relative(root, p);
        for (const mm of src.matchAll(/^\s*defmodule\s+([A-Z][\w.]*)\s+do/gm)) moduleFile[mm[1]] ||= rel;
        const sels = parseOsSelectors(src);
        if (sels.length) selectorsByFile[rel] = sels;
      }
    }
  };
  walk(base);
  return { moduleFile, selectorsByFile };
}

export function readConfigs(root, dir = "api/config") {
  const base = join(root, dir);
  if (!existsSync(base)) return [];
  return readdirSync(base).filter((f) => f.endsWith(".exs")).map((f) => readFileSync(join(base, f), "utf8"));
}

// Reach with platform verdicts. `nodes` is the usefulness graph
// ({id, path, deps:[id]}). The returned map carries, per path: raw (old
// count), reach (effective), and the edges that were discounted, with why.
// Edges are never removed: an inactive edge just carries no reach.
export function platformReach(nodes, { moduleFile = {}, selectorsByFile = {}, configSrcs = [], profile = DEFAULT_PROFILE } = {}) {
  const byId = Object.fromEntries(nodes.map((n) => [n.id, n]));
  const fileModules = {};
  for (const [mod, file] of Object.entries(moduleFile)) (fileModules[file] ||= []).push(mod);

  // Verdict for the edge dependent(selector) → dependency(target).
  const verdicts = {};
  const edgeKey = (from, to) => `${from}->${to}`;
  for (const n of nodes) {
    const sels = selectorsByFile[n.path];
    if (!sels) continue;
    for (const d of n.deps) {
      const target = byId[d];
      if (!target) continue;
      for (const mod of fileModules[target.path] || []) {
        for (const s of sels) {
          const v = edgeVerdict(s, mod, profile, configSrcs);
          if (v) verdicts[edgeKey(n.id, d)] = { ...v, selector: n.path, target: target.path, module: mod };
        }
      }
    }
  }

  const dependents = {};
  for (const n of nodes) for (const d of n.deps) (dependents[d] ||= []).push(n.id);
  const count = (id, honour) => {
    const seen = new Set();
    const q = (dependents[id] || []).filter((up) => !honour || verdicts[edgeKey(up, id)]?.state !== "inactive");
    while (q.length) {
      const x = q.shift();
      if (seen.has(x)) continue;
      seen.add(x);
      for (const up of dependents[x] || []) {
        if (seen.has(up)) continue;
        if (honour && verdicts[edgeKey(up, x)]?.state === "inactive") continue;
        q.push(up);
      }
    }
    return seen.size;
  };

  const out = {};
  for (const n of nodes) {
    const raw = count(n.id, false);
    const reach = count(n.id, true);
    const edges = Object.values(verdicts).filter((v) => v.target === n.path);
    out[n.path] = { raw, reach, discounted: raw !== reach, edges };
  }
  return { profile, files: out, verdicts: Object.values(verdicts) };
}
