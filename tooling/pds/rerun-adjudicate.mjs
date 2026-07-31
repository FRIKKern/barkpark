#!/usr/bin/env node
// rerun-adjudicate.mjs — the CLI. Read a PDS corpus, adjudicate every stored
// rerun through grip's shipped grammar, print the verdict line.
//
// THIS FILE IS THE **ONLY** PLACE IN tooling/pds/ THAT MAY CALL process.exit,
// and it is deliberately the last thing that happens. Every module it imports
// returns a structured ruling; nothing anywhere reads an exit code to decide a
// verdict. That is the epic's law applied to the epic's own instrument.
//
//   node tooling/pds/rerun-adjudicate.mjs
//   node tooling/pds/rerun-adjudicate.mjs --budget-ms 500      # refuses to start
//   node tooling/pds/rerun-adjudicate.mjs --fetch               # live board
//   node tooling/pds/rerun-adjudicate.mjs --json
//
// EXIT CODES ARE FOR THE SHELL, NEVER FOR A VERDICT:
//   0  the run COMPLETED. It does NOT mean the reasons are true — read the line.
//   1  the run did not complete (budget refusal, budget exhaustion, or a
//      REFUTED row, which is a real finding and must not be silently green).
//   2  the instrument could not read its corpus at all.
//   3  usage error.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { join } from "node:path";
import { loadCorpus, fetchCorpus, liveAdjudicated } from "./corpus.mjs";
import { adjudicateCorpus, PDS_VERDICT } from "./adjudicate.mjs";
import { renderVerdict } from "./verdict.mjs";

export const DEFAULT_CORPUS = fileURLToPath(new URL("./fixtures/live-corpus-2026-07-31.json", import.meta.url));
export const RECIPES_PATH = fileURLToPath(new URL("./recipes.json", import.meta.url));
export const REPO_ROOT = fileURLToPath(new URL("../../", import.meta.url));

export function loadRecipes(path = RECIPES_PATH) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(parsed?.recipes)) {
    throw new Error(`recipes: ${path} has no \`recipes\` array`);
  }
  return parsed.recipes;
}

const KNOWN_FLAGS = new Set(["--corpus", "--recipes", "--budget-ms", "--fetch", "--json", "--no-list", "--help", "-h"]);

function parseArgv(argv) {
  const opts = { corpus: DEFAULT_CORPUS, recipes: RECIPES_PATH, budgetMs: 8000, fetch: false, json: false, list: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!KNOWN_FLAGS.has(a)) return { error: `unknown flag \`${a}\` — known flags: ${[...KNOWN_FLAGS].join(" ")}` };
    if (a === "--corpus") opts.corpus = argv[++i];
    else if (a === "--recipes") opts.recipes = argv[++i];
    else if (a === "--budget-ms") opts.budgetMs = Number(argv[++i]);
    else if (a === "--fetch") opts.fetch = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--no-list") opts.list = false;
    else if (a === "--help" || a === "-h") opts.help = true;
  }
  if (!Number.isFinite(opts.budgetMs) || opts.budgetMs <= 0) return { error: "--budget-ms must be a positive number of milliseconds" };
  return { opts };
}

function bpConfig() {
  try {
    return JSON.parse(readFileSync(join(homedir(), ".config", "barkpark", "config.json"), "utf8"));
  } catch {
    return {};
  }
}

export async function main(argv = process.argv.slice(2)) {
  const { opts, error } = parseArgv(argv);
  if (error) {
    process.stderr.write(`rerun-adjudicate: ${error}\n`);
    return 3;
  }
  if (opts.help) {
    process.stdout.write(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 21).join("\n") + "\n");
    return 0;
  }

  let corpus;
  try {
    if (opts.fetch) {
      const cfg = bpConfig();
      corpus = await fetchCorpus({
        server: process.env.BARKPARK_SERVER || cfg.server,
        token: process.env.BARKPARK_TOKEN || cfg.token,
      });
    } else {
      corpus = loadCorpus(opts.corpus);
    }
  } catch (err) {
    process.stderr.write(`rerun-adjudicate: ${err.message}\n`);
    return 2;
  }

  let recipes;
  try {
    recipes = loadRecipes(opts.recipes);
  } catch (err) {
    process.stderr.write(`rerun-adjudicate: ${err.message}\n`);
    return 2;
  }

  const rows = liveAdjudicated(corpus);
  const report = adjudicateCorpus(rows, recipes, { budgetMs: opts.budgetMs, root: REPO_ROOT });
  const text = renderVerdict(report, { source: corpus.source, listProseOnly: opts.list });

  if (opts.json) {
    process.stdout.write(JSON.stringify({ source: corpus.source, ...report }, null, 1) + "\n");
    process.stderr.write(text + "\n");
  } else {
    process.stdout.write(text + "\n");
  }

  if (report.status !== "COMPLETE") return 1;
  if (report.rows.some((r) => r.verdict === PDS_VERDICT.REFUTED)) return 1;
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().then((rc) => { process.exitCode = rc; });
}
