#!/usr/bin/env node
// harvest.mjs — the quarry for the source-of-truth grip layer.
//
// Two committed artifacts live under fixtures/, and this script is how they are
// (re)made and how they are GATED:
//
//   fixtures/evidence-corpus.json      a stratified, size-bounded sample of the REAL
//                                      evidence strings and proofs that past workflow
//                                      runs returned via StructuredOutput
//   fixtures/level-skip-specimens.json the six ratified level-skip specimens, each
//                                      LABELLED with the rule that catches it (D12)
//
// Why the corpus is frozen INTO the repo (D13): ~30k real evidence strings live only
// under ~/.claude, outside the repo, unbacked-up and prunable. An unfrozen quarry
// evaporates.
//
// Why the harvest COMMAND is stored beside the sample: this epic's own doctrine is
// "store the re-run command, never the number." A count is a fact with a shelf life;
// the command that re-derives it is not.
//
// NOTE the harvest form uses `find -print0 | xargs -0`, NOT a shell glob. The glob
// blows the argument limit and silently returns ZERO — a pass-shaped absence, which
// is itself a specimen of the failure mode this epic exists to prevent.
//
//   node tooling/grip/harvest.mjs --harvest   re-harvest from ~/.claude and rewrite the fixture
//   node tooling/grip/harvest.mjs --verify    THE GATE: validate the committed fixtures (+ selftest)
//   node tooling/grip/harvest.mjs --selftest  the mutation controls alone
//   node tooling/grip/harvest.mjs --stats     read-only: what the committed fixture contains
//
// --verify runs WITHOUT the ~/.claude corpus on purpose: it gates the committed bytes,
// so it works in a clean worktree and in CI, where the quarry does not exist.
//
// Exit codes:  0 pass   1 a check FAILED   2 usage/IO error   3 CONTROL DID NOT FIRE (D18)
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(HERE, "fixtures");
const CORPUS = join(FIXTURES, "evidence-corpus.json");
const SPECIMENS = join(FIXTURES, "level-skip-specimens.json");

// ---------------------------------------------------------------------------
// The harvest command. Stored verbatim in the fixture's _meta and executed here
// from the SAME constant, so the recorded command can never drift from the one
// that actually ran.
// ---------------------------------------------------------------------------
const HARVEST_COMMAND =
  "find ~/.claude/projects/-Volumes-SATECHI-github-barkpark " +
  "-path '*/subagents/workflows/wf_*' -name 'agent-*.jsonl' -print0 | xargs -0 cat";

// The file-enumeration half of the same command, used to walk file-by-file so a
// single malformed line cannot cost us the whole corpus.
const LIST_COMMAND =
  "find ~/.claude/projects/-Volumes-SATECHI-github-barkpark " +
  "-path '*/subagents/workflows/wf_*' -name 'agent-*.jsonl' -print0";

// Sampling bounds. Deterministic and stratified: every run id that contributed any
// evidence is represented before any run gets a second item, so no single epic can
// dominate the fixture (the corpus spans 238 runs; the top five are only 6.4%).
const PER_RUN_EVIDENCE = 8;
const PER_RUN_PROOFS = 4;
const MAX_STRING = 600; // per-string cap; longer values are truncated with a marker
const TRUNC_MARK = "…[truncated]";

const SCHEMA = 1;

// ---------------------------------------------------------------------------
// harvest
// ---------------------------------------------------------------------------

function listCorpusFiles() {
  const out = execFileSync("bash", ["-c", LIST_COMMAND], {
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  return out.split("\0").filter(Boolean);
}

const runIdOf = (path) => (path.match(/\/(wf_[^/]+)\//) || [])[1] || "wf_UNKNOWN";

const clip = (s) =>
  typeof s !== "string" ? null : s.length > MAX_STRING ? s.slice(0, MAX_STRING) + TRUNC_MARK : s;

// Stable per-item ordering key, so re-harvesting the same corpus yields the same
// sample. A random or insertion-ordered sample would make the fixture irreproducible,
// which is exactly the defect that BLOCKED research-coverage from this wave (D10).
const stableKey = (s) => createHash("sha256").update(s).digest("hex");

function harvest() {
  const files = listCorpusFiles();
  const byRunEvidence = new Map(); // run -> Map(evidence -> item)
  const byRunProofs = new Map(); // run -> Map(key -> item)
  let totalEvidence = 0;
  let totalProofs = 0;
  let structuredOutputs = 0;
  let unparsableLines = 0;

  for (const file of files) {
    let text;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    // Cheap pre-filter: skip files that cannot contain a payload at all.
    if (text.indexOf("StructuredOutput") < 0) continue;
    const run = runIdOf(file);

    for (const line of text.split("\n")) {
      if (!line || line.indexOf("StructuredOutput") < 0) continue;
      let rec;
      try {
        rec = JSON.parse(line);
      } catch {
        unparsableLines++;
        continue;
      }
      const blocks = rec?.message?.content;
      if (!Array.isArray(blocks)) continue;

      for (const b of blocks) {
        if (b?.type !== "tool_use" || b?.name !== "StructuredOutput") continue;
        structuredOutputs++;
        const input = b.input || {};

        if (Array.isArray(input.facts)) {
          for (const f of input.facts) {
            const ev = f?.evidence;
            if (typeof ev !== "string" || !ev.trim()) continue;
            totalEvidence++;
            if (!byRunEvidence.has(run)) byRunEvidence.set(run, new Map());
            const bucket = byRunEvidence.get(run);
            if (bucket.has(ev)) continue; // dedupe within a run
            bucket.set(ev, {
              run,
              claim: clip(f?.claim) ?? null,
              evidence: clip(ev),
              // NB: no `rerun` field exists in the corpus — that is the whole point.
              // The gap this fixture documents is that 100% of these strings are
              // prose, which the grammar must therefore treat as L6 (D1).
              has_command_field: Object.prototype.hasOwnProperty.call(f ?? {}, "rerun"),
            });
          }
        }

        if (Array.isArray(input.proofs)) {
          for (const p of input.proofs) {
            const cmd = p?.command;
            if (typeof cmd !== "string" || !cmd.trim()) continue;
            totalProofs++;
            if (!byRunProofs.has(run)) byRunProofs.set(run, new Map());
            const bucket = byRunProofs.get(run);
            const key = cmd + "\u0000" + (p?.claim ?? "");
            if (bucket.has(key)) continue;
            bucket.set(key, {
              run,
              claim: clip(p?.claim) ?? null,
              command: clip(cmd),
              output_excerpt: clip(p?.output_excerpt) ?? null,
              passed: typeof p?.passed === "boolean" ? p.passed : null,
            });
          }
        }
      }
    }
  }

  const stratify = (byRun, perRun) => {
    const runs = [...byRun.keys()].sort();
    const out = [];
    for (const run of runs) {
      const items = [...byRun.get(run).values()];
      items.sort((a, b) =>
        stableKey(JSON.stringify(a)).localeCompare(stableKey(JSON.stringify(b))),
      );
      out.push(...items.slice(0, perRun));
    }
    return out;
  };

  return {
    evidence: stratify(byRunEvidence, PER_RUN_EVIDENCE),
    proofs: stratify(byRunProofs, PER_RUN_PROOFS),
    census: {
      files_scanned: files.length,
      structured_output_calls: structuredOutputs,
      unparsable_lines: unparsableLines,
      total_evidence_entries: totalEvidence,
      total_proof_entries: totalProofs,
      distinct_runs_with_evidence: byRunEvidence.size,
      distinct_runs_with_proofs: byRunProofs.size,
    },
  };
}

function writeCorpus() {
  const started = Date.now();
  const h = harvest();
  const elapsed = ((Date.now() - started) / 1000).toFixed(1);

  const fixture = {
    _meta: {
      schema: SCHEMA,
      what: "A stratified, size-bounded sample of REAL evidence strings and proofs returned by past workflow runs via StructuredOutput. Frozen into the repo per charter D13 because the source lives only under ~/.claude, outside the repo, unbacked-up and prunable.",
      // The command, not the number. Re-run it to re-derive today's census; the
      // census below is a SNAPSHOT with a date, never a standing assertion.
      harvest_command: HARVEST_COMMAND,
      harvest_command_note:
        "Uses `find -print0 | xargs -0`, NOT a shell glob. A glob over this corpus blows the argument limit and silently returns ZERO — a pass-shaped absence, itself a specimen of this epic's failure mode.",
      list_command: LIST_COMMAND,
      payload_shape:
        'each line is JSON; payloads are message.content[] blocks with type=="tool_use" and name=="StructuredOutput"; input.facts[].evidence and input.proofs[] are the quarry',
      harvested_at: new Date().toISOString(),
      harvest_seconds: Number(elapsed),
      sampling: {
        strategy:
          "stratified by wf_ run id, deterministic: runs sorted, items within a run sorted by sha256 of their serialization, then the first N taken. Re-harvesting the same corpus yields the same sample.",
        per_run_evidence: PER_RUN_EVIDENCE,
        per_run_proofs: PER_RUN_PROOFS,
        max_string_chars: MAX_STRING,
      },
      census_snapshot: h.census,
      census_caveat:
        "This census describes the corpus AS OF harvested_at on ONE laptop. It is not a repo fact and must never be quoted as one — re-run harvest_command to re-derive it.",
      authority_level: "L1 (a read of files on the machine that produced them)",
    },
    evidence: h.evidence,
    proofs: h.proofs,
  };

  mkdirSync(FIXTURES, { recursive: true });
  writeFileSync(CORPUS, JSON.stringify(fixture, null, 2) + "\n");
  const bytes = readFileSync(CORPUS).length;

  console.log(`harvested in ${elapsed}s`);
  console.log(`  files scanned                 ${h.census.files_scanned}`);
  console.log(`  StructuredOutput calls        ${h.census.structured_output_calls}`);
  console.log(`  evidence entries seen         ${h.census.total_evidence_entries}`);
  console.log(`  proof entries seen            ${h.census.total_proof_entries}`);
  console.log(`  distinct wf_ runs (evidence)  ${h.census.distinct_runs_with_evidence}`);
  console.log(`  distinct wf_ runs (proofs)    ${h.census.distinct_runs_with_proofs}`);
  console.log(`  SAMPLED evidence              ${h.evidence.length}`);
  console.log(`  SAMPLED proofs                ${h.proofs.length}`);
  console.log(`  fixture bytes                 ${bytes}`);
  console.log(`wrote ${CORPUS}`);
}

// ---------------------------------------------------------------------------
// verify — THE GATE
// ---------------------------------------------------------------------------

const VALID_CAUGHT_BY = new Set(["R1", "R2", "R3", "R4", "UNCAUGHT"]);

// Each check is a named predicate over the loaded fixtures. `plant` mutates a deep
// copy into a state the check MUST reject — that is how we prove the control can
// fire (D18). A check whose plant does not trip it exits 3.
const CHECKS = [
  {
    name: "corpus._meta stores the literal harvest COMMAND",
    check: (c) =>
      typeof c._meta?.harvest_command === "string" &&
      c._meta.harvest_command.includes("-print0") &&
      c._meta.harvest_command.includes("xargs -0") &&
      !/\*\.jsonl'?\s*\)/.test(c._meta.harvest_command),
    plant: (c) => {
      c._meta.harvest_command = "cat ~/.claude/**/agent-*.jsonl"; // the glob form that silently returns zero
    },
  },
  {
    name: "corpus census is labelled a snapshot, not a standing fact",
    check: (c) => typeof c._meta?.census_caveat === "string" && c._meta.census_caveat.length > 20,
    plant: (c) => {
      delete c._meta.census_caveat;
    },
  },
  {
    name: "corpus sample is non-empty",
    check: (c) => Array.isArray(c.evidence) && c.evidence.length > 0 && Array.isArray(c.proofs) && c.proofs.length > 0,
    plant: (c) => {
      c.evidence = [];
    },
  },
  {
    name: "corpus is stratified across many distinct wf_ runs (>= 50)",
    check: (c) => new Set(c.evidence.map((e) => e.run)).size >= 50,
    plant: (c) => {
      c.evidence = c.evidence.map((e) => ({ ...e, run: "wf_one" }));
    },
  },
  {
    name: "no single run dominates the corpus sample (<= 5%)",
    check: (c) => {
      const counts = new Map();
      for (const e of c.evidence) counts.set(e.run, (counts.get(e.run) || 0) + 1);
      return Math.max(...counts.values()) / c.evidence.length <= 0.05;
    },
    plant: (c) => {
      const pad = Array.from({ length: c.evidence.length }, () => ({ ...c.evidence[0] }));
      c.evidence = [...c.evidence, ...pad];
    },
  },
  {
    name: "corpus is size-bounded (fixture under 4 MB)",
    check: (c, _s, sizes) => sizes.corpus < 4 * 1024 * 1024,
    // The subject is a byte count, not the parsed object, so the plant mutates
    // the (cloned) sizes the selftest hands it — the bound is a real control,
    // not the one exemption in the set.
    plant: (_c, _s, sizes) => {
      sizes.corpus = 8 * 1024 * 1024;
    },
  },
  {
    name: "every corpus evidence row carries its run id and a non-empty string",
    check: (c) => c.evidence.every((e) => typeof e.run === "string" && e.run.startsWith("wf_") && typeof e.evidence === "string" && e.evidence.length > 0),
    plant: (c) => {
      c.evidence[0] = { ...c.evidence[0], run: "nope" };
    },
  },
  {
    name: "every corpus proof row carries a command",
    check: (c) => c.proofs.every((p) => typeof p.command === "string" && p.command.length > 0),
    plant: (c) => {
      c.proofs[0] = { ...c.proofs[0], command: "" };
    },
  },
  {
    name: "exactly SIX ratified specimens (D12: the table has six rows, not seven)",
    check: (_c, s) => s.specimens.filter((x) => x.ratified === true).length === 6,
    plant: (_c, s) => {
      s.specimens.push({ ...s.specimens[0], id: 99, ratified: true });
    },
  },
  {
    name: "every specimen carries wrong_evidence and honest_counterpart",
    check: (_c, s) =>
      s.specimens.every(
        (x) =>
          typeof x.wrong_evidence === "string" &&
          x.wrong_evidence.length > 0 &&
          typeof x.honest_counterpart === "string" &&
          x.honest_counterpart.length > 0,
      ),
    plant: (_c, s) => {
      s.specimens[0] = { ...s.specimens[0], honest_counterpart: "" };
    },
  },
  {
    // A RATIFIED specimen must carry a real command. Prose parked in the `rerun`
    // field passes a presence check VACUOUSLY, and downstream (the executor, the
    // acceptance suite) would hand "n/a — the ratified table did not…" to
    // /bin/sh. The absence of a command is data; it must be typed as absence.
    //
    // An UNRATIFIED specimen has two honest shapes, and PROSE IS NEITHER:
    //   * `rerun: null` + no_rerun_reason — 101 and 102, which have no ratified
    //     command to carry because their rows were never ratified;
    //   * a REAL executable command + rerun_note saying what it re-derives —
    //     103, whose honest counterpart is a live command in this repo. The note
    //     is what keeps this arm from becoming "any string is fine": a command
    //     with no account of what it answers is the vacuity the other arm bans.
    name: "ratified specimens carry an executable rerun; unratified carry rerun:null + a reason, or a real command + a note",
    check: (_c, s) => {
      const executable = (v) => typeof v === "string" && v.trim().length > 0 && !/^n\/a\b/i.test(v.trim());
      return s.specimens.every((x) => {
        if (x.ratified === true) return executable(x.rerun);
        if (x.rerun === null) return typeof x.no_rerun_reason === "string" && x.no_rerun_reason.length > 20;
        return executable(x.rerun) && typeof x.rerun_note === "string" && x.rerun_note.length > 20;
      });
    },
    plant: (_c, s) => {
      const u = s.specimens.find((x) => x.ratified === false);
      if (u) u.rerun = "n/a — no command was ratified for this row";
    },
  },
  {
    // The no_lag side was CONSTRUCTED, not observed — its box_head/origin_main
    // are placeholder strings. Slice 6 consumes this fixture; without the flag
    // it can read "<equal to origin_main>" as a commit id and build a proof on
    // fiction. The flag is the fixture telling the truth about itself.
    name: "specimen 1's no_lag side declares itself SYNTHETIC (its shas are placeholders)",
    check: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 1);
      const nl = x?.sides?.no_lag;
      return nl?.synthetic === true && typeof nl.synthetic_note === "string" && nl.synthetic_note.length > 20;
    },
    plant: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 1);
      if (x?.sides?.no_lag) delete x.sides.no_lag.synthetic;
    },
  },
  {
    name: "every caught_by is one of R1/R2/R3/R4/UNCAUGHT",
    check: (_c, s) => s.specimens.every((x) => VALID_CAUGHT_BY.has(x.caught_by)),
    plant: (_c, s) => {
      s.specimens[0] = { ...s.specimens[0], caught_by: "R9" };
    },
  },
  {
    name: "every UNCAUGHT specimen states a reason (anti-vacuity: never pad the fixture)",
    check: (_c, s) =>
      s.specimens
        .filter((x) => x.caught_by === "UNCAUGHT")
        .every((x) => typeof x.uncaught_reason === "string" && x.uncaught_reason.length > 20),
    plant: (_c, s) => {
      const u = s.specimens.find((x) => x.caught_by === "UNCAUGHT");
      if (u) delete u.uncaught_reason;
    },
  },
  {
    // THREE since 2026-09-02: 103 joined 101 and 102 when specimen 5's R3 label
    // was re-derived to R1. It is the fixture's first R3-shaped case — an R3
    // violation with HONEST levels, which R1 structurally cannot reach — and it
    // is a negative control, never a seventh ratified row. The count stays
    // EXACT: a `>=` here would stop noticing a silently dropped control.
    name: "the three UNRATIFIED specimens are present and all UNCAUGHT",
    check: (_c, s) => {
      const un = s.specimens.filter((x) => x.ratified === false);
      return un.length === 3 && un.every((x) => x.caught_by === "UNCAUGHT");
    },
    plant: (_c, s) => {
      const u = s.specimens.find((x) => x.ratified === false);
      if (u) u.caught_by = "R1";
    },
  },
  {
    name: "specimen 4 freezes served_sha + command and asserts NO frozen number",
    check: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 4);
      if (!x) return false;
      if (typeof x.served_sha !== "string" || x.served_sha.length < 32) return false;
      if (x.frozen_number !== null) return false;
      // Belt and braces: the honest counterpart must not smuggle the drifted figure
      // back in as a standing assertion.
      return x.number_is_frozen === false;
    },
    plant: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 4);
      if (x) {
        x.frozen_number = 64.0;
        x.number_is_frozen = true;
      }
    },
  },
  {
    name: "specimen 1 captures BOTH the lag and the no-lag side (does not depend on lag persisting)",
    check: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 1);
      return !!x?.sides && typeof x.sides.lag === "object" && typeof x.sides.no_lag === "object";
    },
    plant: (_c, s) => {
      const x = s.specimens.find((y) => y.id === 1);
      if (x) delete x.sides.no_lag;
    },
  },
  {
    name: "the six-row count is derived from the PAPER, not from the wave brief",
    check: (_c, s) => {
      const p = s._meta?.row_count_provenance;
      return (
        !!p &&
        typeof p.how_derived === "string" &&
        p.how_derived.includes("bp doc get") &&
        typeof p.rerun === "string" &&
        p.rerun.includes("survey-once-build-forever")
      );
    },
    plant: (_c, s) => {
      s._meta.row_count_provenance.how_derived = "taken from the wave brief";
      s._meta.row_count_provenance.rerun = "";
    },
  },
  {
    name: "no specimen rerun command uses a path-less line reference (D9)",
    check: (_c, s) => s.specimens.every((x) => !/(^|\s)[A-Za-z_]+\.(ex|exs|mjs|js|ts):\d+/.test(x.rerun)),
    plant: (_c, s) => {
      s.specimens[0] = { ...s.specimens[0], rerun: "read notifications.ex:389-397" };
    },
  },
];

function loadFixtures() {
  for (const [label, p] of [["evidence-corpus.json", CORPUS], ["level-skip-specimens.json", SPECIMENS]]) {
    if (!existsSync(p)) {
      console.error(`FAIL  missing fixture ${label} — run: node tooling/grip/harvest.mjs --harvest`);
      process.exit(2);
    }
  }
  const corpusRaw = readFileSync(CORPUS);
  const specimensRaw = readFileSync(SPECIMENS);
  return {
    corpus: JSON.parse(corpusRaw.toString("utf8")),
    specimens: JSON.parse(specimensRaw.toString("utf8")),
    sizes: { corpus: corpusRaw.length, specimens: specimensRaw.length },
  };
}

const clone = (o) => JSON.parse(JSON.stringify(o));

function runChecks({ corpus, specimens, sizes }) {
  let failed = 0;
  for (const c of CHECKS) {
    let ok;
    try {
      ok = c.check(corpus, specimens, sizes) === true;
    } catch (e) {
      ok = false;
    }
    console.log(`  ${ok ? "ok  " : "FAIL"}  ${c.name}`);
    if (!ok) failed++;
  }
  return failed;
}

// D18: prove each control CAN fire, by planting the defect it exists to catch and
// requiring it to reject. A control that stays green on its own plant is not a
// control — that is exit 3, never absorbed into a normal pass.
function runSelftest({ corpus, specimens, sizes }) {
  let inert = 0;
  let planted = 0;
  for (const c of CHECKS) {
    if (!c.plant) {
      console.log(`  skip  ${c.name} (no in-memory plant: property of the bytes on disk)`);
      continue;
    }
    const mc = clone(corpus);
    const ms = clone(specimens);
    // sizes is cloned and handed to the plant too, so a check whose subject is
    // the BYTE COUNT rather than the parsed object is still plantable. Without
    // this it printed `skip` forever — honest, but an unproven control, and an
    // unproven control is the vacuity D18 exists to forbid.
    const msizes = clone(sizes);
    c.plant(mc, ms, msizes);
    planted++;
    let stillPasses;
    try {
      stillPasses = c.check(mc, ms, msizes) === true;
    } catch {
      stillPasses = false; // a throw is a rejection, which is a firing control
    }
    if (stillPasses) {
      console.log(`  INERT ${c.name} — plant did NOT trip it`);
      inert++;
    } else {
      console.log(`  fires ${c.name}`);
    }
  }
  return { inert, planted };
}

function verify() {
  const f = loadFixtures();
  console.log("grip fixture gate — checks over the COMMITTED bytes");
  console.log(`  corpus    ${f.sizes.corpus} bytes, ${f.corpus.evidence.length} evidence / ${f.corpus.proofs.length} proofs`);
  console.log(`  specimens ${f.sizes.specimens} bytes, ${f.specimens.specimens.length} records`);
  console.log("");
  const failed = runChecks(f);

  console.log("");
  console.log("selftest — every control must fire on its own plant (D18)");
  const { inert, planted } = runSelftest(f);

  console.log("");
  if (inert > 0) {
    console.error(`CONTROL DID NOT BEHAVE AS A CONTROL: ${inert}/${planted} plants did not trip their check.`);
    process.exit(3);
  }
  if (failed > 0) {
    console.error(`FAIL: ${failed}/${CHECKS.length} checks failed.`);
    process.exit(1);
  }
  console.log(`PASS: ${CHECKS.length} checks green, ${planted} controls proven able to fail.`);
}

function stats() {
  const { corpus, specimens, sizes } = loadFixtures();
  const runs = new Set(corpus.evidence.map((e) => e.run));
  console.log("harvest command (stored in _meta):");
  console.log(`  ${corpus._meta.harvest_command}`);
  console.log("");
  console.log(`corpus sample     ${corpus.evidence.length} evidence / ${corpus.proofs.length} proofs`);
  console.log(`distinct wf_ runs ${runs.size}`);
  console.log(`fixture bytes     ${sizes.corpus}`);
  console.log(`census snapshot   ${JSON.stringify(corpus._meta.census_snapshot)}`);
  console.log("");
  console.log("specimens:");
  for (const s of specimens.specimens) {
    console.log(`  ${String(s.id).padStart(2)} [${s.ratified ? "ratified " : "unratified"}] caught_by=${s.caught_by.padEnd(8)} ${s.title}`);
  }
}

// ---------------------------------------------------------------------------

const mode = process.argv[2] || "--verify";
try {
  if (mode === "--harvest") writeCorpus();
  else if (mode === "--verify") verify();
  else if (mode === "--selftest") {
    const f = loadFixtures();
    const { inert, planted } = runSelftest(f);
    if (inert > 0) {
      console.error(`CONTROL DID NOT BEHAVE AS A CONTROL: ${inert}/${planted}`);
      process.exit(3);
    }
    console.log(`PASS: ${planted} controls proven able to fail.`);
  } else if (mode === "--stats") stats();
  else {
    console.error(`usage: node tooling/grip/harvest.mjs [--harvest|--verify|--selftest|--stats]`);
    process.exit(2);
  }
} catch (e) {
  console.error(`ERROR: ${e?.message || e}`);
  process.exit(2);
}
