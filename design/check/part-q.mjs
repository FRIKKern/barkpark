// design/check/part-q.mjs — Part Q of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { repoRoot, ruleGlyph, tokens } from "../emit.mjs";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part Q: pdrender's DOWNSTREAM golden consumers ───────────────────────────
// Part P above proves every emitted space symbol is READ inside internal/pdrender.
// Being read is not the same as being RENDERED INTO SOMEONE ELSE'S COMMITTED
// BYTES, and that gap has already cost a round: #18593 (724546d10) changed how
// pdrender draws a section boundary, dutifully regenerated its OWN 16 fixtures,
// and left internal/taskboard red on main — taskboard typesets task briefs
// THROUGH pdrender, so its detail_*/compose_*/paper_* goldens are pdrender output
// too and nothing told the author they existed. Part P was green the whole time.
//
// Part Q closes that. Two halves, and neither is a list:
//
//   1. THE CENSUS (a predicate, not a snapshot). A DOWNSTREAM CONSUMER is any
//      package outside internal/pdrender that (a) imports
//      github.com/FRIKKern/barkpark/internal/pdrender in a non-generated .go file
//      and (b) owns a testdata/ directory. Derived by walking the tree on every
//      run, so a package added later enrols itself and a package that stops
//      importing pdrender leaves on its own. A pinned list of four package names
//      would silently un-guard the fifth — the exact defect this repo keeps
//      filing rows about (Part G shipped with five literal suffixes against ten
//      real artifacts). The floors below are SHRINK-ONLY: they red when the
//      census finds LESS than it found when this part was written, which is what
//      a broken predicate and a deleted consumer both look like.
//
//   2. THE AGREEMENT. The section-boundary device is observable in committed
//      bytes: a full-width run of the structural rule glyph, N blank rows above
//      it and M below before the section head. pdrender's own goldens and every
//      downstream consumer's goldens are the SAME renderer's output, so that
//      (blanks-above, blanks-below, glyph) triple must be identical across all of
//      them. Regenerating one side and not the other — literally what #18593 did
//      — breaks the triple, and Part Q reds NAMING the consumer package and the
//      command that regenerates it.
//
// THE LIMIT, stated rather than discovered later: if a rendering change is
// committed with NO goldens regenerated at all, both sides are equally stale and
// Part Q is honestly quiet — internal/pdrender's own golden tests red in that
// case, which is the failure the author cannot miss. Part Q exists for the case
// where the author DID regenerate, just not everywhere.
console.log("\ndesign/check.mjs — Part Q: pdrender downstream golden-consumer agreement");
{
  const failedBeforeQ = failed;
  const qFail = (m) => fail(m);

  // Shrink-only floors. Raise one only alongside the change that makes it true.
  const Q_CONSUMER_FLOOR = 4;        // cmd/barkpark, internal/chat, internal/cli, internal/taskboard
  const Q_SELF_DEVICE_FLOOR = 4;     // section-boundary devices in internal/pdrender's own goldens
  const Q_DOWNSTREAM_DEVICE_FLOOR = 3; // …and in its downstream consumers' goldens

  const skipDir = (n) => n.startsWith(".") || n.startsWith("_") || n === "node_modules" || n === "vendor" || n === "testdata";
  const goPkgDirs = [];
  const walkPkgs = (rel) => {
    let entries;
    try { entries = readdirSync(join(repoRoot, rel || "."), { withFileTypes: true }); } catch { return; }
    if (entries.some((e) => e.isFile() && e.name.endsWith(".go"))) goPkgDirs.push(rel);
    for (const e of entries) if (e.isDirectory() && !skipDir(e.name)) walkPkgs(rel ? `${rel}/${e.name}` : e.name);
  };
  walkPkgs("");

  const IMPORT = `"github.com/FRIKKern/barkpark/internal/pdrender"`;
  const consumers = [];
  for (const dir of goPkgDirs) {
    if (dir === "internal/pdrender" || dir.startsWith("internal/pdrender/")) continue;
    let entries;
    try { entries = readdirSync(join(repoRoot, dir), { withFileTypes: true }); } catch { continue; }
    if (!entries.some((e) => e.isDirectory() && e.name === "testdata")) continue;
    const importers = entries
      .filter((e) => e.isFile() && e.name.endsWith(".go"))
      .filter((e) => readFileSync(join(repoRoot, dir, e.name), "utf8").includes(IMPORT))
      .map((e) => e.name);
    if (importers.length) consumers.push({ dir, importers });
  }

  // Every committed text artifact under a testdata/ tree. Read recursively: a
  // golden moved into a subdirectory (internal/pdrender/testdata/golden/) must
  // not fall out of the census.
  const textFiles = (rel, out = []) => {
    let entries;
    try { entries = readdirSync(join(repoRoot, rel), { withFileTypes: true }); } catch { return out; }
    for (const e of entries) {
      if (e.isDirectory()) textFiles(`${rel}/${e.name}`, out);
      else if (e.isFile() && !e.name.endsWith(".json")) out.push(`${rel}/${e.name}`);
    }
    return out;
  };

  // The section-boundary device as committed BYTES: a line that is nothing but a
  // run of the structural glyph, with its surrounding blank-row counts. Lines
  // that merely CONTAIN the glyph (a progress bar's filled head) are not the
  // device and are not counted — the predicate is "the whole line is the rule".
  const glyph = ruleGlyph(tokens.space.section.rule);
  const devicesIn = (text) => {
    const lines = text.split("\n");
    const found = [];
    for (let i = 0; i < lines.length; i++) {
      const s = lines[i].trim();
      if (!s || [...new Set(s)].join("") !== glyph) continue;
      let above = 0;
      for (let j = i - 1; j >= 0 && lines[j].trim() === ""; j--) above++;
      let below = 0;
      for (let k = i + 1; k < lines.length && lines[k].trim() === ""; k++) below++;
      found.push({ line: i + 1, above, below });
    }
    return found;
  };
  const sigOf = (d) => `${d.above} blank row(s) above / ${d.below} below / ${JSON.stringify(glyph)}`;

  const scanTree = (rel) => {
    const hits = [];
    for (const f of textFiles(rel)) {
      let text;
      try { text = readFileSync(join(repoRoot, f), "utf8"); } catch { continue; }
      for (const d of devicesIn(text)) hits.push({ file: f, ...d });
    }
    return hits;
  };

  const self = scanTree("internal/pdrender/testdata");
  const selfSigs = new Set(self.map(sigOf));

  if (consumers.length < Q_CONSUMER_FLOOR)
    qFail(
      `  Part Q FAIL: the downstream-consumer census found ${consumers.length} package(s), floor is ${Q_CONSUMER_FLOOR}.\n` +
        `    Either a consumer was deleted, or the predicate (imports ${IMPORT} AND owns testdata/)\n` +
        `    stopped resolving. A census that shrank is indistinguishable from a census that broke —\n` +
        `    re-derive it with:\n` +
        `      git ls-files '*.go' | xargs grep -l ${IMPORT} | sed 's|/[^/]*$||' | sort -u\n` +
        `    and lower Q_CONSUMER_FLOOR in the same commit that removes the consumer.`,
    );
  if (self.length < Q_SELF_DEVICE_FLOOR)
    qFail(
      `  Part Q FAIL: internal/pdrender's own goldens hold ${self.length} section-boundary device(s), floor is ${Q_SELF_DEVICE_FLOOR}.\n` +
        `    Part Q compares downstream goldens against pdrender's own rendering of the device; with\n` +
        `    no device of its own there is nothing to compare against and this part would pass\n` +
        `    vacuously. Keep a fixture with an L2 heading after prose, or lower the floor deliberately.`,
    );
  if (selfSigs.size > 1)
    qFail(
      `  Part Q FAIL: internal/pdrender's own goldens disagree with EACH OTHER about the section\n` +
        `    boundary: ${[...selfSigs].join(" vs ")}. Some of its fixtures were regenerated and some\n` +
        `    were not — run: go test ./internal/pdrender -update`,
    );

  const selfSig = self.length ? sigOf(self[0]) : null;
  let downstreamDevices = 0;
  const rows = [];
  for (const c of consumers) {
    const hits = scanTree(`${c.dir}/testdata`);
    downstreamDevices += hits.length;
    const bad = selfSig ? hits.filter((h) => sigOf(h) !== selfSig) : [];
    rows.push({ dir: c.dir, importers: c.importers.length, devices: hits.length, bad: bad.length });
    if (bad.length)
      qFail(
        `  Part Q FAIL: ${c.dir} goldens are STALE pdrender output — regenerate them.\n` +
          `    ${c.dir} renders THROUGH pdrender (imports it in ${c.importers.join(", ")}), so its goldens\n` +
          `    are pdrender's committed bytes too. internal/pdrender's own goldens draw the section\n` +
          `    boundary as ${selfSig}, but ${bad.length} device(s) in ${c.dir}/testdata still draw it as\n` +
          `    ${[...new Set(bad.map(sigOf))].join(" / ")}:\n` +
          bad.slice(0, 6).map((b) => `      ${b.file}:${b.line}`).join("\n") +
          `\n    A pdrender rendering change regenerated its OWN fixtures and not these. Fix:\n` +
          `      go test ./${c.dir} -update\n` +
          `    (this is #18593's exact shape: 16 pdrender fixtures moved, internal/taskboard stayed\n` +
          `    behind, main went red for a round and no gate had said a word.)`,
      );
  }
  if (downstreamDevices < Q_DOWNSTREAM_DEVICE_FLOOR)
    qFail(
      `  Part Q FAIL: the downstream goldens hold ${downstreamDevices} section-boundary device(s), floor is\n` +
        `    ${Q_DOWNSTREAM_DEVICE_FLOOR}. Part Q's agreement half has nothing to compare and is passing\n` +
        `    vacuously — an all-clear and a nothing-measured look identical from the outside. Either a\n` +
        `    consumer's fixtures lost their section boundary, or the device predicate stopped matching.`,
    );

  if (FAULT.has("Q")) qFail("  Part Q FAIL: injected fault (--selftest)");
  if (failed === failedBeforeQ) {
    for (const r of rows)
      console.log(`       ${r.dir}  (${r.importers} pdrender importer file(s), ${r.devices} section-boundary device(s) in testdata/)`);
    console.log(
      `  ok   ${consumers.length} downstream golden consumer(s) derived by predicate; ` +
        `${downstreamDevices} downstream + ${self.length} pdrender device(s) agree on ${selfSig}`,
    );
  }
}
