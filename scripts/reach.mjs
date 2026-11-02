#!/usr/bin/env node
// What a change reaches: the derived-file steps its diff touches (and every
// step downstream of them), the gates that catch each one stale, and the exact
// commands to rebuild and to run them. task-e04a2c419fdd3621.
//
//   node scripts/reach.mjs              diff against origin/main
//   node scripts/reach.mjs <base>       diff against <base>
//
// The diff is base...HEAD plus anything uncommitted, so it can run before a
// commit as well as before a push.

import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { reached } from "./derived-files.mjs";

const root = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
const lines = (cmd) => execSync(cmd, { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean);

export function changedPaths(base) {
  return [
    ...new Set([
      ...lines(`git diff --name-only ${base}...HEAD`),
      ...lines("git diff --name-only HEAD"),
      ...lines("git ls-files --others --exclude-standard"),
    ]),
  ].sort();
}

export const isTest = (p) =>
  /(_test\.exs|_test\.go|\.test\.(mjs|js|ts|tsx))$/.test(p) || /(^|\/)__[^/]*\.test\.mjs$/.test(p);

function packageOf(path) {
  let dir = dirname(path);
  while (dir !== "." && dir !== "js") {
    const pkg = `${root}/${dir}/package.json`;
    if (existsSync(pkg)) return { dir, name: JSON.parse(readFileSync(pkg, "utf8")).name };
    dir = dirname(dir);
  }
  return null;
}

export function commandsFor(paths) {
  const out = [];
  const mix = (app) => {
    const files = paths.filter((p) => p.startsWith(`${app}/test/`) && p.endsWith(".exs"));
    if (files.length) out.push(`cd ${app} && mix test ${files.map((p) => relative(app, p)).join(" ")}`);
  };
  mix("api");
  mix("cloud");
  for (const p of paths) {
    if (p.includes(".yml: ")) out.push(p);
    else if (p.endsWith(".exs")) continue;
    else if (p.endsWith(".go")) out.push(`go test ./${dirname(p)} -count=1`);
    else if (p.startsWith("apps/mobile/")) out.push(`cd apps/mobile && pnpm exec jest ${relative("apps/mobile", p)}`);
    else if (p.startsWith("js/") && /\.test\.tsx?$/.test(p)) {
      const pkg = packageOf(p);
      out.push(`cd js && pnpm --filter ${pkg.name} exec vitest run ${relative(pkg.dir, p)}`);
    } else if (p.startsWith("api/assets/paper-editor/")) out.push(`cd api/assets/paper-editor && node ${relative("api/assets/paper-editor", p)}`);
    else if (p.endsWith(".mjs") || p.endsWith(".js")) out.push(`node ${p}`);
  }
  return out;
}

export function report(base, paths) {
  const steps = reached(paths);
  const gates = [...new Set(steps.flatMap((s) => s.gates))];
  const tests = paths.filter(isTest);
  const out = [`reach: ${paths.length} changed path(s) against ${base}`];
  if (steps.length) {
    out.push("", "derived files (in order):");
    for (const s of steps) out.push(`  ${s.name}  (after: ${s.after.join(", ") || "-"})`);
    out.push("", "rebuild them:", `  node scripts/regen.mjs --base ${base}`);
    out.push("", "gates that catch them stale:", ...gates.map((g) => `  ${g}`));
  } else out.push("", "derived files: none reached");
  const run = commandsFor([...new Set([...gates.filter((g) => !g.includes(".yml: ")), ...tests])]);
  if (run.length) out.push("", "run:", ...run.map((c) => `  ${c}`));
  return out.join("\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const base = process.argv[2] || "origin/main";
  console.log(report(base, changedPaths(base)));
}
