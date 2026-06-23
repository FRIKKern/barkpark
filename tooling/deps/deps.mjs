#!/usr/bin/env node
// Dependency / supply-chain audit — a cheap, programmatic signal feeding the
// Cody "Dependencies" dimension. Audits across all four ecosystems and degrades
// GRACEFULLY: a missing tool or a non-zero audit exit (audits exit non-zero WHEN
// THEY FIND ISSUES) never throws — stdout is captured anyway, the same pattern
// risk.mjs uses for its coverage suites (see tooling/risk/risk.mjs tryRun).
//
//   deps.mjs → tooling/deps/deps-report.json + one-line stderr summary   [free]

import { execFileSync } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();

// Capture stdout even on non-zero exit (audits signal findings via exit code).
function tryRun(cmd, args, opts) {
  try { return execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: 180_000, ...opts }); }
  catch (e) { return (e.stdout || "") + (e.stderr || ""); }
}
const onPath = (cmd) => { try { execFileSync("sh", ["-c", `command -v ${cmd}`], { stdio: "ignore" }); return true; } catch { return false; } };

const sources = {};
const skipped = [];
const totals = { critical: 0, high: 0, moderate: 0, low: 0 };

// ── mix: `mix hex.audit` in api/ — lists retired packages, else "No retired packages" ──
try {
  if (onPath("mix") && existsSync(join(ROOT, "api/mix.exs"))) {
    const out = tryRun("mix", ["hex.audit"], { cwd: join(ROOT, "api") });
    let retired = 0;
    if (/No retired packages/i.test(out)) {
      retired = 0;
    } else {
      // Each retired package is a table row; count lines that look like a package
      // row (start with whitespace then a lowercase package name + version column).
      for (const line of out.split("\n")) {
        if (/^\s*[a-z][a-z0-9_]+\s+\S/.test(line) && !/Dependency|Version|Retirement|hex\.audit/i.test(line)) retired++;
      }
    }
    sources.mix = { retired };
    // retired/vulnerable hex packages count as moderate supply-chain risk
    totals.moderate += retired;
  } else {
    sources.mix = "skipped:no-mix-or-project";
    skipped.push("mix");
  }
} catch { sources.mix = "skipped:error"; skipped.push("mix"); }

// ── npm: `npm audit --json` at repo root AND in sdk/ — sum .metadata.vulnerabilities ──
function npmAudit(rel) {
  const dir = rel ? join(ROOT, rel) : ROOT;
  if (!existsSync(join(dir, "package-lock.json"))) return "skipped:no-lockfile";
  const out = tryRun("npm", ["audit", "--json"], { cwd: dir });
  try {
    const j = JSON.parse(out);
    const v = (j.metadata && j.metadata.vulnerabilities) || {};
    return { critical: v.critical || 0, high: v.high || 0, moderate: v.moderate || 0, low: v.low || 0, info: v.info || 0 };
  } catch { return "skipped:parse-error"; }
}
if (onPath("npm")) {
  for (const [key, rel] of [["root", ""], ["sdk", "sdk"]]) {
    const r = npmAudit(rel);
    sources[`npm:${key}`] = r;
    if (typeof r === "object") {
      totals.critical += r.critical; totals.high += r.high; totals.moderate += r.moderate; totals.low += r.low;
    } else if (rel) { /* skipped sub-source — only flag whole-npm if both gone */ }
  }
} else {
  sources["npm:root"] = "skipped:no-npm"; sources["npm:sdk"] = "skipped:no-npm"; skipped.push("npm");
}

// ── pnpm: `pnpm audit --json` in js/ — only if pnpm on PATH ──
if (onPath("pnpm") && existsSync(join(ROOT, "js/pnpm-lock.yaml"))) {
  const out = tryRun("pnpm", ["audit", "--json"], { cwd: join(ROOT, "js") });
  try {
    const j = JSON.parse(out);
    // pnpm shapes it as .metadata.vulnerabilities (npm-compatible) or .advisories map.
    const v = (j.metadata && j.metadata.vulnerabilities) || null;
    if (v) {
      const r = { critical: v.critical || 0, high: v.high || 0, moderate: v.moderate || 0, low: v.low || 0 };
      sources.pnpm = r;
      totals.critical += r.critical; totals.high += r.high; totals.moderate += r.moderate; totals.low += r.low;
    } else {
      sources.pnpm = "skipped:no-metadata";
    }
  } catch { sources.pnpm = "skipped:parse-error"; }
} else {
  sources.pnpm = "skipped:no-pnpm";
  skipped.push("js");
}

// ── go: govulncheck — NOT installed by default ──
if (onPath("govulncheck")) {
  const out = tryRun("govulncheck", ["./..."], { cwd: ROOT });
  // Each vulnerability is reported as "Vulnerability #N:"
  const findings = (out.match(/Vulnerability #\d+/g) || []).length;
  sources.go = { findings };
  totals.high += findings; // treat go vulns as high-severity supply-chain risk
} else {
  sources.go = "skipped:not-installed";
  skipped.push("go");
}

const report = { at: new Date().toISOString(), totals, sources, skipped };
writeFileSync(join(HERE, "deps-report.json"), JSON.stringify(report, null, 2));

process.stderr.write(
  `deps  ${totals.critical} crit · ${totals.high} high · ${totals.moderate} moderate · ${totals.low} low` +
  (skipped.length ? ` · skipped: ${skipped.join("/")}` : "") +
  `  → deps-report.json\n`
);
