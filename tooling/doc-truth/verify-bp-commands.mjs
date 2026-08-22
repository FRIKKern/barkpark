#!/usr/bin/env node
// verify-bp-commands.mjs — the gate for every `bp …` command a doc PRINTS.
//
// WHAT THIS GATE PROVES: that a printed command PARSES — every token on its
// command path is dispatched by the binary, and every flag it passes is a flag
// that leaf actually reads.
// WHAT IT NEVER PROVES: that the command SUCCEEDS. No server is contacted, no
// token is resolved, no side effect runs. A command that parses can still 401,
// 404, or do the wrong thing.
//
// It resolves against a UNION of the CLI's own sources (bp-cli-sources.mjs):
//   [A] manifest rows · [B] completionNouns · [C] parseHzArgs allowlists ·
//   [D] router switch tables · [E] "--flag" literals
//
// LAWS
//   1. A command that resolves in NO source is UNRESOLVED — the gate FAILS. It
//      never "skips" a token it cannot adjudicate.
//   2. A source that cannot be loaded FAILS the run. Silently dropping [A]
//      manufactures false reds for every manifest-driven command; silently
//      dropping [D] manufactures the false GREEN this gate exists to kill
//      (`bp cloud barkpark ls` is green under A+B+C, because B knows `cloud`
//      and nothing in A/B/C can adjudicate the token after it).
//   3. Absence may be DECLARED, never assumed: --offline drops [A], is accepted
//      only when every target is under templates/**, and PRINTS the declaration.
//   4. UNPROVEN is not a pass. A flag set no source enumerates is reported by
//      NAME and by COUNT, and never counted as verified.
//
//   node tooling/doc-truth/verify-bp-commands.mjs [--json] [--offline] [--brief] <doc>...
//
// Every GREEN row cites the SPECIFIC authority that adjudicated it — the
// file:line of the switch case, the completionNouns literal, the parseHzArgs
// allowlist or the "--flag" literal (and, for [A], the manifest ROW id: that
// manifest is one line of JSON, so a ":<line>" would be a fiction). --brief
// suppresses the citations and prints the source letters alone.
//   node tooling/doc-truth/verify-bp-commands.mjs --selftest
//
// Exit 0 only when every printed command was adjudicated and none is
// unresolved. Dependency-free. ESM, node: builtins only.

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  REPO_ROOT, DEFAULT_MANIFEST, loadBpSources, resolveBpCommand, flagsByDepth,
  splitCommandLine, requiredFlagsFor, PROVEN, UNPROVEN, UNRESOLVED,
} from "./bp-cli-sources.mjs";
import { extractClaims } from "./verify-docs.mjs";

const HEADER = [
  "bp-command gate — proves every printed `bp …` command PARSES against the CLI's own sources.",
  "It does NOT prove the command SUCCEEDS: no server is called, no token resolved, nothing run.",
];

// ── the run ─────────────────────────────────────────────────────────────────

export function verifyDocs(docs, { root = REPO_ROOT, offline = false, use = "ABCDE" } = {}) {
  const sources = loadBpSources({ root, offline });
  const report = {
    header: HEADER,
    sources: {
      ok: sources.ok, errors: sources.errors, absent: sources.absent,
      counts: sources.counts, origins: sources.origins,
    },
    docs: [], totals: { proven: 0, unproven: 0, unresolved: 0, commands: 0 },
    unresolved: [], unproven: [],
  };
  if (!sources.ok) return report; // LAW 2 — an unavailable source fails the run

  for (const rel of docs) {
    const abs = join(root, rel);
    if (!existsSync(abs)) {
      report.sources.errors.push(`target not found: ${rel}`);
      report.sources.ok = false;
      continue;
    }
    const text = readFileSync(abs, "utf8");
    const rows = [];
    for (const claim of extractClaims(rel, text)) {
      if (claim.type !== "command") continue;
      if (claim.target.head !== "bp" && claim.target.head !== "barkpark") continue;
      const r = resolveBpCommand(sources, claim.target.full, { fenced: !!claim.fenced, use });
      const row = {
        doc: rel, line: claim.line, fenced: !!claim.fenced, raw: r.text,
        verdict: r.verdict, path: r.path, via: [...new Set(r.via.filter(Boolean))],
        authority: r.authority, reasons: r.reasons, unproven: r.unproven,
      };
      rows.push(row);
      report.totals.commands++;
      if (r.verdict === PROVEN) report.totals.proven++;
      if (r.verdict === UNPROVEN) { report.totals.unproven++; report.unproven.push(row); }
      if (r.verdict === UNRESOLVED) { report.totals.unresolved++; report.unresolved.push(row); }
    }
    report.docs.push({ doc: rel, rows });
  }
  return report;
}

function printReport(report, { authority = true } = {}) {
  const w = (s) => process.stdout.write(s + "\n");
  const bar = "─".repeat(78);
  w("");
  for (const h of report.header) w(h);
  w(bar);
  for (const [k, origin] of Object.entries(report.sources.origins)) {
    const absent = report.sources.absent.includes(k);
    const n = report.sources.counts[k];
    w(absent
      ? `  [${k}] SOURCE ${k} DECLARED ABSENT — ${origin}`
      : `  [${k}] ${String(n).padStart(5)} rows · ${origin}`);
  }
  if (!report.sources.ok) {
    w(bar);
    for (const e of report.sources.errors) w(`  ✗ ${e}`);
    w("  the gate FAILS rather than skipping: a dropped source manufactures both");
    w("  false greens and false reds. Fix the source or DECLARE it absent.");
    w(bar);
    return;
  }
  w(bar);
  for (const d of report.docs) {
    if (d.rows.length === 0) continue;
    w(`\n${d.doc}`);
    for (const r of d.rows) {
      const mark = r.verdict === PROVEN ? "✓" : r.verdict === UNPROVEN ? "?" : "✗";
      const via = r.via.length ? ` [${r.via.join("+")}]` : "";
      w(`  ${mark} L${r.line}${r.fenced ? "" : " (inline)"} \`${trunc(r.raw, 66)}\`${r.verdict === PROVEN ? via : ""}`);
      if (authority) for (const a of r.authority) w(`        ↳ ${a}`);
      for (const reason of r.reasons) w(`      ${reason}`);
      for (const u of r.unproven) w(`      UNPROVEN: ${u}`);
    }
  }
  const t = report.totals;
  w(`\n${bar}`);
  w(`TOTALS  ${t.commands} printed bp command(s): ${t.proven} parse · ${t.unproven} UNPROVEN · ${t.unresolved} UNRESOLVED`);
  if (t.unproven) {
    w(`UNPROVEN (${t.unproven}) — reported, never counted as a pass:`);
    for (const r of report.unproven) w(`  ? ${r.doc}:${r.line} \`${trunc(r.raw, 60)}\``);
  }
  if (t.unresolved) {
    w(`UNRESOLVED (${t.unresolved}) — the gate FAILS on these:`);
    for (const r of report.unresolved) w(`  ✗ ${r.doc}:${r.line} \`${trunc(r.raw, 60)}\``);
  }
  w(`VERDICT: ${t.unresolved === 0 ? "every printed command parses" : "FAIL — " + t.unresolved + " printed command(s) do not parse"}`);
  w(bar);
}

function trunc(s, n) { return s.length > n ? s.slice(0, n - 1) + "…" : s; }

// ── selftest ────────────────────────────────────────────────────────────────
//
// Every law above is proved BY MUTATION: the negative half (drop a source, drop
// the continuation join, drop the depth rule) must FAIL, or the positive half
// proves nothing.

function selftest() {
  const results = [];
  const check = (name, fn) => {
    try {
      const r = fn();
      results.push({ name, ok: r === true, detail: r === true ? "" : String(r) });
    } catch (e) {
      results.push({ name, ok: false, detail: e.stack ? e.stack.split("\n")[0] : String(e) });
    }
  };
  const S = loadBpSources({});
  const verdict = (line, opts) => resolveBpCommand(S, line, opts);

  check("sources load: all five present", () =>
    S.ok || S.errors.join("; "));
  check("source counts are non-trivial", () => {
    const c = S.counts;
    return (c.A > 50 && c.B > 20 && c.C > 5 && c.D > 50 && c.E > 20) || JSON.stringify(c);
  });

  // LAW: a head resolving in no source FAILS, never skips.
  check("unknown head is UNRESOLVED, not skipped", () => {
    const r = verdict("bp frobnicate ls");
    return (r.verdict === UNRESOLVED && /resolves in NO source/.test(r.reasons[0])) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });

  // [D] is load-bearing: the vacuous green this gate exists to kill.
  check("D adjudicates `bp cloud barkpark ls`", () => {
    const r = verdict("bp cloud barkpark ls");
    return (r.verdict === UNRESOLVED && /barkpark/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("MUTATION: A+B+C are structurally unable to RED `bp cloud barkpark ls`", () => {
    const r = resolveBpCommand(S, "bp cloud barkpark ls", { use: "ABCE" });
    return (r.verdict !== UNRESOLVED && r.verdict === UNPROVEN) ||
      `expected UNPROVEN without D (nothing left to adjudicate the token after \`cloud\`), got ${r.verdict}`;
  });

  // [A] is load-bearing the other way: dropping it manufactures false reds.
  check("A resolves manifest-driven commands", () => {
    const ok = ["bp doc ls post", "bp task claim x y", "bp workspace create acme"]
      .every((c) => verdict(c).verdict === PROVEN);
    return ok || "a manifest-driven command did not parse";
  });
  check("MUTATION: without A, no manifest-driven command survives (≥1 falsely RED)", () => {
    const v = ["bp doc ls post", "bp task claim x y", "bp workspace create acme"]
      .map((c) => resolveBpCommand(S, c, { use: "BCDE" }).verdict);
    const proven = v.filter((x) => x === PROVEN).length;
    const reds = v.filter((x) => x === UNRESOLVED).length;
    return (proven === 0 && reds >= 1) ||
      `expected 0 proven and ≥1 falsely red without A, got ${JSON.stringify(v)}`;
  });

  // LAW: an unavailable source FAILS the run.
  check("LAW: an unavailable source FAILS (never silently drops)", () => {
    const bad = loadBpSources({ manifestPath: "docs/cli/fixtures/does-not-exist.json" });
    return (bad.ok === false && /SOURCE A UNAVAILABLE/.test(bad.errors.join(" "))) ||
      `expected failure, got ok=${bad.ok}`;
  });
  check("LAW: --offline DECLARES A absent rather than assuming it", () => {
    const off = loadBpSources({ offline: true });
    return (off.ok === true && off.absent.includes("A") && off.A === null) ||
      `offline load did not declare A absent (ok=${off.ok})`;
  });
  check("LAW: --offline is refused outside templates/**", () =>
    offlineAllowed(["templates/search-starter/README.md"]) === true &&
    offlineAllowed(["docs/cards/cli.md"]) === false ||
    "offline scope guard is wrong");

  // [E] the micro-source: without it, hand-rolled parsers are UNPROVEN.
  check("E proves `bp login --device`", () => {
    const r = verdict("bp login --device");
    return (r.verdict === PROVEN && r.via.includes("E")) || `${r.verdict} via ${r.via.join("+")}`;
  });
  check("MUTATION: without E, `bp login --device` is UNPROVEN — not a pass", () => {
    const r = resolveBpCommand(S, "bp login --device", { use: "ABCD" });
    return (r.verdict === UNPROVEN && r.unproven.length === 1) ||
      `expected UNPROVEN, got ${r.verdict}`;
  });
  check("E proves every `bp vercel quick-setup` flag", () => {
    const r = verdict("bp vercel quick-setup --site s --app-dir a --vercel-team t --no-deploy", { fenced: true });
    return r.verdict === PROVEN || `${r.verdict}: ${r.reasons.join("|")} ${r.unproven.join("|")}`;
  });

  // the continuation join (extractor fix 1)
  check("EXTRACTOR: a `\\`-continued fenced command is ONE claim", () => {
    const md = "```sh\nbp cloud site create --name my-search --dataset default/default/production \\\n  --instance box --framework astro --template astro-search-starter\n```\n";
    const cmds = extractClaims("x.md", md).filter((c) => c.type === "command");
    if (cmds.length !== 1) return `expected 1 command claim, got ${cmds.length}`;
    const r = resolveBpCommand(S, cmds[0].target.full, { fenced: true });
    return r.verdict === PROVEN || `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("MUTATION: unjoined, the same command REDs for a missing required flag", () => {
    const r = verdict("bp cloud site create --name my-search --dataset default/default/production", { fenced: true });
    return (r.verdict === UNRESOLVED && /missing required --instance/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });

  // required flags: FENCED only, by bracket DEPTH (extractor fix 2)
  check("required flags are checked on FENCED lines only", () => {
    const line = "bp cloud site create --template search-starter";
    const inline = resolveBpCommand(S, line, { fenced: false });
    const fenced = resolveBpCommand(S, line, { fenced: true });
    return (inline.verdict === PROVEN && fenced.verdict === UNRESOLVED) ||
      `inline=${inline.verdict} fenced=${fenced.verdict}`;
  });
  check("bracket DEPTH: a [--flag] shown optional is not counted as supplied", () => {
    const r = verdict("bp cloud site create [--name n] --dataset w/p/d --instance box", { fenced: true });
    return (r.verdict === UNRESOLVED && /missing required --name/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("bracket DEPTH: a synopsis's optional group is not read as required", () => {
    const req = requiredFlagsFor(S, ["cloud", "site", "create"]);
    return (req.has("--name") && req.has("--dataset") && req.has("--instance") &&
      !req.has("--framework") && !req.has("--kind")) || `required=${[...req].join(" ")}`;
  });
  check("bracket DEPTH: flagsByDepth splits the two levels", () => {
    const { depth0, all } = flagsByDepth("bp vercel quick-setup --site <s> [--schema f --seed f] [--vercel-team t]");
    return (depth0.has("--site") && !depth0.has("--schema") && all.has("--schema")) ||
      `depth0=${[...depth0].join(" ")}`;
  });

  // unknown flags red; globals never do
  check("an unknown flag is UNRESOLVED", () => {
    const r = verdict("bp cloud site create --name n --dataset w/p/d --instance b --barkpark x", { fenced: true });
    return (r.verdict === UNRESOLVED && /--barkpark/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("global flags before the noun are consumed, not misread", () => {
    const r = verdict("bp -s <server> workspace create \"$SITE\"", { fenced: true });
    return r.verdict === PROVEN || `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("a trailing shell comment is not part of the command", () => {
    const { text } = splitCommandLine("bp cloud site deploy <slug>          # streams PLAN→BUILD");
    return text === "bp cloud site deploy <slug>" || `got ${text}`;
  });

  // the templates/** corpus, on the real files: E is what closes the UNPROVEN
  // set, and an UNPROVEN row is reported by NAME and by COUNT — never as a pass.
  const TEMPLATES = [
    "templates/DEPLOYING.md", "templates/MANIFEST.md",
    "templates/astro-search-starter/README.md", "templates/search-starter/DEPLOYING.md",
    "templates/search-starter/README.md",
  ].filter((d) => existsSync(join(REPO_ROOT, d)));
  check("templates/**: 0 UNPROVEN with all five sources", () => {
    const r = verifyDocs(TEMPLATES);
    return r.totals.unproven === 0 || `${r.totals.unproven} UNPROVEN: ` +
      r.unproven.map((x) => `${x.doc}:${x.line}`).join(", ");
  });
  check("MUTATION: without E, templates/** UNPROVEN rows are named and counted", () => {
    const r = verifyDocs(TEMPLATES, { use: "ABCD" });
    const named = r.unproven.map((x) => x.raw);
    const hasLogin = named.some((n) => /^bp login --device/.test(n));
    const hasVercel = named.some((n) => /^bp vercel quick-setup .*--/.test(n));
    const counted = r.totals.unproven === r.unproven.length && r.totals.unproven > 0;
    const notPasses = r.unproven.every((x) => x.verdict === UNPROVEN);
    return (hasLogin && hasVercel && counted && notPasses) ||
      `unproven=${r.totals.unproven} named=${JSON.stringify(named)}`;
  });

  // ── the citation is the claim: read every cited line BACK ────────────────
  //
  // A source letter is not checkable by a reader; `hetzner_cmd.go:118` is — but
  // only if it is TRUE. A citation that points at a plausible-looking wrong line
  // is worse than none, so the gate re-opens each file it cited and demands the
  // token actually be declared there. `readBack` returns the failures, so the
  // positive check demands zero and the mutation below demands some.
  const CITE_RE = /^([A-Z+]+) (\S+) → (.+):(\d+)$/;
  const readBack = (rows, shift = 0) => {
    const bad = [];
    for (const r of rows) {
      for (const a of r.authority || []) {
        const m = a.match(CITE_RE);
        if (!m) continue;                       // [A] cites a row id, not a line
        const [, , tok, file, lineNo] = m;
        const abs = join(REPO_ROOT, file);
        if (!existsSync(abs)) { bad.push(`${a} — no such file`); continue; }
        const lines = readFileSync(abs, "utf8").split("\n");
        const text = lines[Number(lineNo) - 1 + shift];
        // the cited line must literally declare the token it was cited for
        const bare = tok.replace(/^--/, "");
        if (text === undefined || !(text.includes(`"${tok}"`) || text.includes(`"${bare}"`))) {
          bad.push(`${a} — line ${Number(lineNo) + shift} does not declare ${tok}: ${String(text).trim().slice(0, 60)}`);
        }
      }
    }
    return bad;
  };
  const CITED = verifyDocs(TEMPLATES).docs.flatMap((d) => d.rows).filter((r) => r.verdict === PROVEN);

  check("every GREEN row cites a SPECIFIC authority (letter alone is not enough)", () => {
    const naked = CITED.filter((r) => !r.authority || r.authority.length === 0);
    return naked.length === 0 || `${naked.length} row(s) cite no authority: ` +
      naked.map((r) => `${r.doc}:${r.line}`).join(", ");
  });
  check("every cited file:line REALLY declares the token it was cited for", () => {
    const bad = readBack(CITED);
    return bad.length === 0 || `${bad.length} false citation(s): ${bad.slice(0, 3).join(" | ")}`;
  });
  check("MUTATION: shift every citation by one line and the read-back FAILS", () => {
    // Proves the check above is not vacuous — it is reading the file, not the
    // string it printed. If an off-by-one still passed, the check proves nothing.
    const bad = readBack(CITED, 1);
    return bad.length > 0 || "an off-by-one citation still passed — the read-back is VACUOUS";
  });
  check("citations name real dispatch, not the doc: [D] cites internal/cli/**.go", () => {
    const d = CITED.flatMap((r) => r.authority).filter((a) => a.startsWith("D "));
    return (d.length > 0 && d.every((a) => /→ internal\/cli\/\S+\.go:\d+$/.test(a))) ||
      `${d.length} D-citations, offenders: ${d.filter((a) => !/internal\/cli/.test(a)).slice(0, 3).join(" | ")}`;
  });

  // the header never claims success
  check("the header says PARSES and denies SUCCEEDS", () => {
    const h = HEADER.join(" ");
    return (/PARSES/.test(h) && /does NOT prove the command SUCCEEDS/.test(h)) || h;
  });

  const w = (s) => process.stdout.write(s + "\n");
  const bar = "─".repeat(78);
  w("");
  for (const h of HEADER) w(h);
  w(`${bar}\nselftest — every law proved by mutation (the negative half must FAIL)\n${bar}`);
  let bad = 0;
  for (const r of results) {
    if (!r.ok) bad++;
    w(`  ${r.ok ? "✓" : "✗"} ${r.name}${r.ok ? "" : `\n      ${r.detail}`}`);
  }
  w(bar);
  w(`selftest: ${results.length - bad}/${results.length} passed`);
  w(bar);
  return bad === 0 ? 0 : 1;
}

// --offline drops source [A]. That is honest only where the manifest fixture is
// genuinely not part of the consumer's tree — a shipped template. Anywhere else
// the fixture IS present and dropping it would fake a smaller ground truth.
export function offlineAllowed(docs) {
  return docs.length > 0 && docs.every((d) => d.startsWith("templates/"));
}

// ── CLI ─────────────────────────────────────────────────────────────────────

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--selftest")) process.exit(selftest());
  const wantJson = argv.includes("--json");
  const offline = argv.includes("--offline");
  const docs = argv.filter((a) => !a.startsWith("--"));

  if (docs.length === 0) {
    process.stderr.write("usage: verify-bp-commands.mjs [--json] [--offline] [--brief] <doc.md>...\n");
    process.exit(2);
  }
  if (offline && !offlineAllowed(docs)) {
    process.stderr.write(
      "--offline drops source [A] (the manifest) and is accepted only when every target is\n" +
      "under templates/**. Refusing: a dropped source outside that scope manufactures reds.\n");
    process.exit(2);
  }

  const report = verifyDocs(docs, { offline });
  if (wantJson) process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  else printReport(report, { authority: !argv.includes("--brief") });

  if (!report.sources.ok) process.exit(2);
  process.exit(report.totals.unresolved === 0 ? 0 : 1);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
