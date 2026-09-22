#!/usr/bin/env node
// Disposal of harness debris left on guerrilla by tooling/studio-journey/journey.mjs.
//
// WHY THIS IS A SCRIPT WITH AN ALLOW-LIST AND NOT A QUERY.
// The obvious implementation is "select the debris and delete it". That is the shape
// that makes this dangerous. Every predicate we have tried on this population has been
// wrong in at least one direction:
//   * the harness's own sweepCandidate() keyed on the TITLE, and a run killed after its
//     TYPE beat leaves a titled draft the sweep can never select (task-d582be9d064f35dc);
//   * the TIME clause is `since this run's press`, so any leftover is outside every later
//     run's window whatever its title says;
//   * the NEW journeyRun predicate selects none of the six pre-existing drafts, because
//     nothing stamped them.
// A predicate that cannot reliably FIND these documents cannot be trusted to decide which
// ones to DESTROY. So the ids are enumerated, by hand, from a catalogue that was read out
// of a full pagination of the host and committed beside this file — and anything not on
// that list is refused, loudly, including by a caller who passes it deliberately.
//
// AUTHORISATION. Nothing here runs without the owner. These are documents on a live host.
// Ruling of 2026-09-22 (BLOCKED-ON-USER item 19): do not delete; prepare the disposal so
// it runs in one command when the owner approves. That is what this is.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const CATALOGUE = join(HERE, "evidence-sweep", "catalogue.json");

// The ONLY ids this script will ever act on. Cohorts are separate because their
// provenance is separate, and the owner may well approve one and not the other.
const COHORTS = {
  // Owner item 19. Left by journey.mjs runs killed mid-flight on 2026-09-22 (two Chrome
  // hangs and a set quarantined for concurrency). Five carry the harness's own TYPE-beat
  // marker strings verbatim. The sixth does NOT and is called out as the weakest case.
  "item-19": [
    "drafts.paper-c113346aba4d66ab",
    "drafts.paper-0643af76eb6b633b",
    "drafts.paper-3a477d9b6918e824",
    "drafts.paper-98e2223da8e80e75",
    "drafts.paper-b9a56007639bfd72",
    "drafts.paper-8be087501234ae2d",
  ],
  // Created deliberately by task-d582be9d064f35dc while reproducing criterion 0.
  // Provenance is certain: all three carry a journeyRun stamp written by that work.
  "w13-reproduction": [
    "drafts.paper-e64b438d91789273",
    "drafts.paper-w13probemucnckud",
    "drafts.paper-w13controlmucnodkq",
  ],
};

const WEAKEST = "drafts.paper-8be087501234ae2d";

function die(msg) {
  console.error(`REFUSED: ${msg}`);
  process.exit(2);
}

const argv = process.argv.slice(2);
const cohort = (argv.find((a) => a.startsWith("--cohort=")) || "").split("=")[1];
const confirm = argv.includes("--confirm");
const extra = argv.filter((a) => !a.startsWith("--"));

if (extra.length) {
  die(
    `this script takes no positional ids. It acts on a hard-coded allow-list and nothing else.\n` +
      `        Refused: ${extra.join(", ")}\n` +
      `        If an id genuinely belongs here, add it to COHORTS in this file, in a reviewed commit,\n` +
      `        with its catalogue evidence — not on a command line.`,
  );
}
if (!cohort) die(`name a cohort: --cohort=${Object.keys(COHORTS).join(" | --cohort=")}`);
if (!COHORTS[cohort]) die(`unknown cohort "${cohort}". Known: ${Object.keys(COHORTS).join(", ")}`);

// The catalogue is the evidence. If an id is not in it, we do not know what we are deleting.
let catalogue;
try {
  catalogue = JSON.parse(readFileSync(CATALOGUE, "utf8"));
} catch (e) {
  die(`cannot read the catalogue at ${CATALOGUE}: ${e.message}\n        The catalogue IS the authorisation record; without it this script does nothing.`);
}
const known = new Set((catalogue.harness_debris || []).map((r) => r.id));
const ids = COHORTS[cohort];
const unbacked = ids.filter((id) => !known.has(id));
if (unbacked.length) {
  die(
    `these ids are in the allow-list but NOT in the committed catalogue, so their evidence is missing:\n` +
      `        ${unbacked.join("\n        ")}\n` +
      `        Refusing rather than deleting a document whose provenance is not on the record.`,
  );
}

console.log(`cohort ${cohort}: ${ids.length} document(s), all backed by ${CATALOGUE}`);
console.log(`host    ${catalogue._host}`);
console.log(`dataset ${catalogue._dataset}`);
for (const id of ids) {
  const row = (catalogue.harness_debris || []).find((r) => r.id === id);
  const flag = id === WEAKEST ? "  <-- WEAKEST CASE: no marker text; debris only by circumstance" : "";
  console.log(`  ${id}  ${JSON.stringify(row?.title ?? null)}${flag}`);
}

if (!confirm) {
  console.log("");
  console.log("DRY RUN. Nothing was deleted. Re-run with --confirm to perform the disposal.");
  console.log("Owner approval is required first — see BLOCKED-ON-USER item 19.");
  process.exit(0);
}

console.error("");
console.error("REFUSED: --confirm is armed but the delete call is deliberately NOT implemented yet.");
console.error("The owner has not ruled. When they do, wire the delete here in a reviewed commit so the");
console.error("approval and the capability land together, rather than leaving a loaded gun in the tree.");
process.exit(3);
