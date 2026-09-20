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

import { readFileSync, existsSync, mkdtempSync, cpSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  REPO_ROOT, DEFAULT_MANIFEST, loadBpSources, resolveBpCommand, flagsByDepth,
  splitCommandLine, requiredFlagsFor, PROVEN, UNPROVEN, UNRESOLVED, NOT_A_COMMAND,
} from "./bp-cli-sources.mjs";
import { extractClaims } from "./verify-docs.mjs";

const HEADER = [
  "bp-command gate — proves every printed `bp …` command PARSES against the CLI's own sources.",
  "It does NOT prove the command SUCCEEDS: no server is called, no token resolved, nothing run.",
];

// ── the run ─────────────────────────────────────────────────────────────────

export function verifyDocs(docs, { root = REPO_ROOT, offline = false, use = "ABCDE", manifestPath } = {}) {
  // manifestPath is threaded through so the "an unavailable source FAILS the
  // RUN" law can be proved at RUN level, not merely at loader level. Without
  // it the run always loaded the real manifest, so the law was untested where
  // it actually matters.
  const sources = loadBpSources(manifestPath ? { root, offline, manifestPath } : { root, offline });
  const report = {
    header: HEADER,
    sources: {
      ok: sources.ok, errors: sources.errors, absent: sources.absent,
      counts: sources.counts, origins: sources.origins,
    },
    docs: [], totals: { proven: 0, unproven: 0, unresolved: 0, commands: 0, metasyntax: 0 },
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
      // A pure grammar diagram (`bp [global flags] <noun> <verb> …`) is not a
      // printed command at all: excluded from `commands`, never a pass, never
      // counted toward UNRESOLVED.
      if (r.verdict === NOT_A_COMMAND) { report.totals.metasyntax++; continue; }
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
      const mark = r.verdict === PROVEN ? "✓" : r.verdict === UNPROVEN ? "?" :
        r.verdict === NOT_A_COMMAND ? "·" : "✗";
      const via = r.via.length ? ` [${r.via.join("+")}]` : "";
      w(`  ${mark} L${r.line}${r.fenced ? "" : " (inline)"} \`${trunc(r.raw, 66)}\`${r.verdict === PROVEN ? via : ""}`);
      if (authority) for (const a of r.authority) w(`        ↳ ${a}`);
      for (const reason of r.reasons) w(`      ${reason}`);
      for (const u of r.unproven) w(`      UNPROVEN: ${u}`);
    }
  }
  const t = report.totals;
  w(`\n${bar}`);
  w(`TOTALS  ${t.commands} printed bp command(s): ${t.proven} parse · ${t.unproven} UNPROVEN · ${t.unresolved} UNRESOLVED` +
    (t.metasyntax ? ` (+${t.metasyntax} grammar diagram line(s) excluded — not a printed command)` : ""));
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

  // ── FIXTURES ─────────────────────────────────────────────────────────────
  //
  // Every mutation below runs over a corpus this selftest OWNS, never over the
  // live templates/** READMEs. That is deliberate: those files are edited by
  // other rows (#6941 repaired the `--barkpark` defects; stw11-claim-ledger
  // edits them again), so a mutation anchored to them proves nothing the moment
  // someone repairs a README — and keeps reporting green while it proves
  // nothing. Fixtures test the LOGIC; the live run at the end tests the WIRING.
  const FIX = "tooling/doc-truth/fixtures/bp-commands";
  const fix = (name) => `${FIX}/${name}.md`;
  const runFix = (name, opts) => verifyDocs([fix(name)], opts);

  check("FIXTURES: the corpus exists (a missing corpus must not pass vacuously)", () => {
    const missing = ["clean", "unknown-flag", "unknown-subnoun", "unresolvable-head"]
      .filter((f) => !existsSync(join(REPO_ROOT, fix(f))));
    return missing.length === 0 || `missing fixture(s): ${missing.join(", ")}`;
  });

  // POSITIVE HALF — a clean fixture GREENs, and is not green by being empty.
  check("FIXTURE: the clean fixture GREENs every command it prints", () => {
    const r = runFix("clean");
    if (r.totals.commands < 6) return `only ${r.totals.commands} command(s) extracted — corpus too small to prove anything`;
    return (r.totals.unresolved === 0 && r.totals.unproven === 0) ||
      `${r.totals.unresolved} UNRESOLVED / ${r.totals.unproven} UNPROVEN: ` +
      [...r.unresolved, ...r.unproven].map((x) => `${x.doc}:${x.line}`).join(", ");
  });

  // The clean fixture must exercise every markup shape a command appears in. A
  // pattern written for one shape silently UNDER-counts the rest and returns a
  // clean-looking green, so the shapes are asserted, not assumed.
  check("EXTRACTOR: the clean fixture covers all four markup shapes", () => {
    const rows = runFix("clean").docs[0].rows;
    const shapes = {
      fenced: rows.some((r) => r.fenced && !/^bp cloud site (create|status)/.test(r.raw)),
      prompted: rows.some((r) => r.raw === "bp cloud site status <slug>"),
      continued: rows.some((r) => r.fenced && /--template search-starter$/.test(r.raw) && /--name/.test(r.raw)),
      inline: rows.some((r) => !r.fenced),
    };
    const missing = Object.entries(shapes).filter(([, ok]) => !ok).map(([k]) => k);
    return missing.length === 0 || `shape(s) not covered by the fixture: ${missing.join(", ")}`;
  });

  // NEGATIVE HALF — each defect fixture REDs, and is named in the report.
  const redsByName = (name, needle) => {
    const r = runFix(name);
    if (r.totals.unresolved !== 1) return `expected exactly 1 UNRESOLVED, got ${r.totals.unresolved}`;
    const row = r.unresolved[0];
    if (!row.raw.includes(needle)) return `RED row does not name ${needle}: ${row.raw}`;
    if (!row.reasons.length) return "RED row carries no reason";
    return true;
  };
  check("MUTATION: an unknown FLAG REDs (fixture), named with its reason", () =>
    redsByName("unknown-flag", "--barkpark"));
  check("MUTATION: an unknown SUB-NOUN REDs (fixture) — only D can adjudicate it", () =>
    redsByName("unknown-subnoun", "bp cloud barkpark"));
  check("MUTATION: an unresolvable HEAD REDs (fixture), never skipped", () =>
    redsByName("unresolvable-head", "totally-not-a-noun"));

  // A source made unavailable must FAIL THE RUN — not degrade it to a skip that
  // reports green over a corpus nothing adjudicated.
  check("MUTATION: a source made unavailable FAILS the RUN, not just the load", () => {
    const r = verifyDocs([fix("clean")], { manifestPath: "docs/cli/fixtures/does-not-exist.json" });
    return (r.sources.ok === false && /SOURCE A UNAVAILABLE/.test(r.sources.errors.join(" "))) ||
      `run did not fail: ok=${r.sources.ok} errors=${JSON.stringify(r.sources.errors)}`;
  });

  // ── VERB TABLES: dispatch that is DATA, not syntax ───────────────────────
  //
  // #18555 replaced runCloudSite()'s verb switch with a lookup table
  // (internal/cli/site_verb_matrix.go). A reader keyed to `case "x":` saw NO
  // verbs and reported every correct `bp cloud site …` line in templates/ as
  // UNRESOLVED — a false red on docs nobody had touched
  // (task-130384a036e99eb6). The resolver now reads the TABLE.
  //
  // BOTH ARMS, because either failure is silent:
  //   · the POSITIVE checks RED if the reader is reverted to case-scraping, or
  //     if it stops citing the table row that adjudicated the verb;
  //   · the MUTATION checks RED if the reader is widened into one that answers
  //     "parses" for tokens the table does not declare — the vacuous green
  //     this whole gate exists to prevent.
  const tableCite = (line) => {
    const r = verdict(line);
    if (r.verdict !== PROVEN) return `${r.verdict}: ${r.reasons.join("|")}`;
    const cited = (r.authority || []).filter((a) => /^D .*site_verb_matrix\.go:\d+$/.test(a));
    return cited.length > 0 ||
      `resolved but cited no verb-table row: ${JSON.stringify(r.authority)}`;
  };
  for (const v of ["create", "deploy", "status", "rollback", "delete", "ls"]) {
    check(`VERB TABLE: \`bp cloud site ${v}\` resolves THROUGH siteVerbMatrix`, () =>
      tableCite(`bp cloud site ${v}`));
  }
  check("VERB TABLE: an Aliases cell resolves (`bp cloud site build` → deploy)", () =>
    tableCite("bp cloud site build"));
  check("VERB TABLE: the other spelling reads the SAME table (`bp sites logs`)", () =>
    tableCite("bp sites logs"));
  check("VERB TABLE: a token the table does NOT declare still REDs", () => {
    const r = verdict("bp cloud site redeploy");
    return (r.verdict === UNRESOLVED && /redeploy/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")} — the table reader answers for verbs the table never declares`;
  });
  check("VERB TABLE: a NOUN-QUALIFIED table donates no bare verbs", () => {
    // nounBuiltins rows carry `Noun: "task", Verb: "lint"` — the dispatch token
    // is the PAIR. Donating the bare verb would make `bp <anything> lint`
    // resolvable, which is the vacuous green source D exists to kill.
    const r = verdict("bp vercel lint");
    return (r.verdict === UNRESOLVED) ||
      `${r.verdict} — a noun-qualified row resolved by its verb alone`;
  });
  check("VERB TABLE SCOPE: a spawner-only verb still REFUSES at the fleet noun", () => {
    const r = verdict("bp sites deploy");
    return (r.verdict === UNRESOLVED && /deploy/.test(r.reasons.join(" "))) ||
      `${r.verdict} — the Scope column was ignored; every verb reads as offered at every noun`;
  });

  // MUTATION on a COPY of internal/cli — the arm that fires on REAL drift: a
  // verb retired in the table while a doc still prints it. The tree is copied,
  // not edited, so nothing here can touch the working tree.
  const runProbe = (printed, edit, editFile = "internal/cli/site_verb_matrix.go", opts = {}) => {
    const tmp = mkdtempSync(join(tmpdir(), "bp-verb-table-"));
    try {
      cpSync(join(REPO_ROOT, "internal/cli"), join(tmp, "internal/cli"), { recursive: true });
      let changed = true;
      if (edit) {
        const f = join(tmp, editFile);
        const before = readFileSync(f, "utf8");
        const after = edit(before);
        changed = after !== before;
        if (changed) writeFileSync(f, after);
      }
      writeFileSync(join(tmp, "probe.md"), "```sh\n" + printed + "\n```\n");
      if (opts.rawLoad) {
        return { changed, sources: loadBpSources({ root: tmp, offline: true }) };
      }
      return { changed, report: verifyDocs(["probe.md"], { root: tmp, offline: true }) };
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  };
  const dropRow = (verb) => (src) =>
    src.replace(new RegExp(`\\n\\t\\t\\{\\n\\t\\t\\tVerb: "${verb}",[\\s\\S]*?\\n\\t\\t\\},`), "");

  check("CONTROL: the probe doc GREENs against the UNMUTATED copy", () => {
    const { report } = runProbe("bp cloud site rollback <slug>", null);
    return (report.totals.commands === 1 && report.totals.unresolved === 0) ||
      `commands=${report.totals.commands} unresolved=${report.totals.unresolved} — ` +
      "the mutation checks below would be measuring a broken harness, not the mutation";
  });
  check("MUTATION: retire `rollback` from the table and the doc printing it REDs", () => {
    const { changed, report } = runProbe("bp cloud site rollback <slug>", dropRow("rollback"));
    if (!changed) return "the row-drop did not apply — this check would pass vacuously";
    return (report.totals.unresolved === 1) ||
      `expected 1 UNRESOLVED, got ${report.totals.unresolved} of ${report.totals.commands} — ` +
      "a verb deleted from the table still resolves";
  });
  check("MUTATION: drop the `build` alias and `bp cloud site build` REDs", () => {
    const { changed, report } = runProbe("bp cloud site build <slug>",
      (src) => src.replace(' Aliases: []string{"build"},', ""));
    if (!changed) return "the alias-drop did not apply — this check would pass vacuously";
    return (report.totals.unresolved === 1) ||
      `expected 1 UNRESOLVED, got ${report.totals.unresolved} — aliases are not read from the table`;
  });
  check("MUTATION: widen deploy's Scope and `bp sites deploy` stops refusing", () => {
    // The scope column is READ, not decoration: flip spawner-only to shared and
    // the fleet noun starts answering. If this stays UNRESOLVED the scope check
    // above is passing for some other reason.
    const { changed, report } = runProbe("bp sites deploy <slug>",
      (src) => src.replace("Scope: siteVerbSpawnerOnly", "Scope: siteVerbShared"));
    if (!changed) return "the scope flip did not apply — this check would pass vacuously";
    return (report.totals.unresolved === 0) ||
      `still UNRESOLVED with the scope widened: ${report.unresolved.map((x) => x.reasons.join("|")).join(" ")}`;
  });

  // ── [D3] the NOUN-QUALIFIED built-in registry ────────────────────────────
  //
  // `bp task create` is dispatched from nounBuiltins and exists in NO manifest.
  // Before D3 the verifier scored three TRUE docs/cli/error-exit-table.md lines
  // UNRESOLVED. The arms below prove the pair resolves, prove it resolves ONLY
  // because of the registry, and prove the registry read REFUSES rather than
  // answering "no pairs" when it comes back empty.
  const NB = "internal/cli/noun_builtins.go";

  check("D3 resolves `bp task create --publish` (registry-only, no manifest row)", () => {
    const r = verdict("bp task create --publish");
    const fromRegistry = r.authority.some((a) => /^D create → internal\/cli\/noun_builtins\.go:\d+$/.test(a));
    return (r.verdict === PROVEN && fromRegistry) ||
      `${r.verdict} via ${r.via.join("+")} — authority: ${r.authority.join(" ; ")}`;
  });
  check("D3 names the built-in's own leaf, so [C]/[E] can still adjudicate its flags", () => {
    // Without the leaf the pair parses and the FLAG degrades to UNPROVEN — a
    // softer answer that is not a pass and hides that --publish is real.
    const r = verdict("bp task create --publish");
    return (r.unproven.length === 0) ||
      `flags fell to UNPROVEN: ${r.unproven.join("|")}`;
  });
  check("D3 does NOT donate a bare verb: `bp doc create` is judged by the manifest, `bp task frontier` by the pair", () => {
    // The pair is the dispatch token. `frontier` is registered under `task`
    // only; a noun that does not carry it must not inherit it.
    const good = verdict("bp task frontier");
    const bad = verdict("bp media frontier");
    return (good.verdict === PROVEN && bad.verdict === UNRESOLVED) ||
      `task frontier=${good.verdict} media frontier=${bad.verdict} — the pair leaked into another noun`;
  });
  check("CONTROL: the D3 probe doc GREENs against the UNMUTATED copy", () => {
    const { report } = runProbe("bp task create --publish", null, NB);
    return (report.totals.commands === 1 && report.totals.unresolved === 0) ||
      `commands=${report.totals.commands} unresolved=${report.totals.unresolved} — ` +
      "the D3 mutations below would be measuring a broken harness";
  });
  check("MUTATION: delete the `task create` registry row and the doc printing it REDs", () => {
    const { changed, report } = runProbe("bp task create --publish",
      (src) => src.replace(/\n\t\{\n\t\tNoun:\s+"task",\n\t\tVerb:\s+"create",[\s\S]*?\n\t\},/, ""), NB);
    if (!changed) return "the row-drop did not apply — this check would pass vacuously";
    return (report.totals.unresolved === 1) ||
      `expected 1 UNRESOLVED, got ${report.totals.unresolved} of ${report.totals.commands} — ` +
      "`task create` resolves from something other than the registry, so D3 is not what greens it";
  });
  check("POSITIVE CONTROL: an EMPTY registry REFUSES the load — it never answers `no pairs`", () => {
    // An absence claim needs a control. If the registry read could come back
    // empty and still report a clean load, every `<noun> <verb>` built-in would
    // silently go back to being invisible and this gate would RED true lines
    // while looking healthy. The refusal is keyed on the SHAPE, not a filename.
    const { changed, sources } = runProbe("bp task create",
      (src) => src.replace(/\bNoun:/g, "Group_RENAMED_AWAY:"), NB, { rawLoad: true });
    if (!changed) return "the registry blanking did not apply — this check would pass vacuously";
    return (sources.ok === false && /noun-qualified verb registry/.test(sources.errors.join(" "))) ||
      `expected a REFUSAL, got ok=${sources.ok} errors=${sources.errors.join("|")}`;
  });

  // ── [D] `!=` intercepts are dispatch too ─────────────────────────────────
  const MK = "internal/cli/make_cmd.go";

  check("D reads a `!=` sub-noun guard: `bp make schema <name>`", () => {
    const r = verdict("bp make schema <name>");
    const fromMake = r.authority.some((a) => /^D schema → internal\/cli\/make_cmd\.go:\d+$/.test(a));
    return (r.verdict === PROVEN && fromMake) ||
      `${r.verdict} — authority: ${r.authority.join(" ; ")}`;
  });
  check("CONTROL: the `!=` probe doc GREENs against the UNMUTATED copy", () => {
    const { report } = runProbe("bp make schema post", null, MK);
    return (report.totals.commands === 1 && report.totals.unresolved === 0) ||
      `commands=${report.totals.commands} unresolved=${report.totals.unresolved}`;
  });
  check("MUTATION: rename the token in the `!=` guard and `bp make schema` REDs", () => {
    const { changed, report } = runProbe("bp make schema post",
      (src) => src.replace(/args\[0\] != "schema"/g, 'args[0] != "blueprint"'), MK);
    if (!changed) return "the guard rename did not apply — this check would pass vacuously";
    return (report.totals.unresolved === 1) ||
      `expected 1 UNRESOLVED, got ${report.totals.unresolved} — \`schema\` resolves from something ` +
      "other than the guard, so the `!=` rule is not what greens it";
  });
  check("`!=` does not make an UNDECLARED sub-noun resolvable", () => {
    const r = verdict("bp make casserole");
    return (r.verdict === UNRESOLVED) ||
      `${r.verdict} — reading \`!=\` turned the make leaf into a wildcard`;
  });

  // the templates/** corpus, on the real files: E is what closes the UNPROVEN
  // set, and an UNPROVEN row is reported by NAME and by COUNT — never as a pass.
  // This is the WIRING half — fixtures cannot prove the gate reads real docs.
  const TEMPLATES = [
    "templates/DEPLOYING.md", "templates/MANIFEST.md",
    "templates/astro-search-starter/README.md", "templates/search-starter/DEPLOYING.md",
    "templates/search-starter/README.md",
  ].filter((d) => existsSync(join(REPO_ROOT, d)));
  check("templates/**: 0 UNPROVEN with all five sources", () => {
    if (TEMPLATES.length === 0) return "the live corpus filtered to EMPTY — this check would pass vacuously";
    const r = verifyDocs(TEMPLATES);
    if (r.totals.commands === 0) return "the live corpus yielded 0 commands — nothing was adjudicated";
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
  // Cited rows come from the FIXTURE corpus, not the live READMEs: a citation
  // check anchored to files other rows edit stops proving anything the moment
  // one is edited, and stays green while it does.
  const CITED = runFix("clean").docs.flatMap((d) => d.rows).filter((r) => r.verdict === PROVEN);

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

  // ── EXTRACTOR: bare global flags, verb-alternation, pipe-alternation,
  // metasyntax (wbt-jwt-cli-doc-parity-extractor) ──────────────────────────
  //
  // A printed line that is ONLY a declared global flag IS the command — the
  // CLI's own builtins.go declares `--version`/`-V`/`-h`/`--help` usable with
  // no noun.
  for (const flag of ["--version", "-V", "-h", "--help"]) {
    check(`BARE GLOBAL: \`bp ${flag}\` resolves without a noun`, () => {
      const r = verdict(`bp ${flag}`);
      return (r.verdict === PROVEN) || `${r.verdict}: ${r.reasons.join("|")}`;
    });
  }
  check("MUTATION: an UNDECLARED bare global flag still REDs", () => {
    const r = verdict("bp --not-a-real-global-flag");
    return (r.verdict === UNRESOLVED && /not a global flag/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });

  // a verb SUMMARY (`bp task ls/ready/prime/…`) expands into one check per
  // verb against the noun's manifest verb set — a coverage GAIN.
  check("VERB ALTERNATION: a `/`-summary expands against the noun's manifest verb set", () => {
    const r = verdict("bp task ls/ready/prime/events/get/claim/release/stamp/pulse/close/next/move");
    return (r.verdict === PROVEN && r.via.includes("A")) || `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("MUTATION: an alternation naming a verb the noun LACKS still REDs, named", () => {
    const r = verdict("bp task ls/ready/not-a-real-verb");
    return (r.verdict === UNRESOLVED && /not-a-real-verb/.test(r.reasons.join(" "))) ||
      `${r.verdict}: ${r.reasons.join("|")}`;
  });

  // a pipe alternation (`bash|zsh|fish`) documents one ARGUMENT's values, not
  // verbs — read like a placeholder once a command path already exists.
  check("PIPE ALTERNATION: `bash|zsh|fish` resolves as an argument value, not a verb", () => {
    const r = verdict("bp completion bash|zsh|fish");
    return r.verdict === PROVEN || `${r.verdict}: ${r.reasons.join("|")}`;
  });

  // a pure grammar diagram is NOT a printed command: never a pass, never an
  // UNRESOLVED failure.
  check("METASYNTAX: a grammar diagram line is not-a-command", () => {
    const r = verdict("bp [global flags] <noun> <verb> [args] [command flags]");
    return (r.verdict === NOT_A_COMMAND) || `${r.verdict}: ${r.reasons.join("|")}`;
  });
  check("MUTATION: one bare literal token means it is a REAL command, not metasyntax", () => {
    const r = verdict("bp doc ls post");
    return (r.verdict !== NOT_A_COMMAND) || "wrongly classified `bp doc ls post` as metasyntax";
  });
  check("WIRING: docs/cli/HANDBOOK.md's grammar-diagram line is excluded from totals", () => {
    const r = verifyDocs(["docs/cli/HANDBOOK.md"]);
    const row = r.docs[0] && r.docs[0].rows.find((x) => /^bp \[global flags\]/.test(x.raw));
    if (!row) return "the grammar-diagram row was not found at all — extraction regressed";
    return (row.verdict === NOT_A_COMMAND && r.totals.metasyntax >= 1) ||
      `row verdict=${row.verdict} totals.metasyntax=${r.totals.metasyntax}`;
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
