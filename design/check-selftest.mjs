// design/check-selftest.mjs — the negative half of design/check.mjs.
//
// Run it as `node design/check.mjs --selftest`; this module is the body behind
// that switch. It exists because design/check.mjs spent its whole life with
// NOTHING exercising it, and produced two defect rows in one day, both in its
// ok-summary reporting and both proven with a harness the builder then threw
// away: task-6a265c12a8589702 (a part printed `ok` beside its own FAIL lines) and
// task-60500d9c1893efb8 (Part B suppressed a TRUE `ok`). Opposite signs, same
// class — nobody could ask the gate "can you still fail?".
//
// WHAT IT ASSERTS, and why it is these two directions and not one. An ok-summary
// is a claim about ONE part, so it has two ways to lie:
//
//   FALSE REASSURANCE  a part that FAILED still prints its ok.
//   FALSE SILENCE      a part that PASSED withholds its ok because something
//                      EARLIER in the run failed. The exit code is right either
//                      way, so nothing ships wrongly — but a reader debugging a
//                      red run cannot tell "this part passed and was suppressed"
//                      from "this part never ran", and a diagnostic that reads
//                      the same for two different states is not a diagnostic.
//
// A selftest that only drives the healthy path re-creates exactly the blind spot
// it is meant to close, so every arm below is a run in which SOMETHING fails.
//
// WHY THE ARMS ARE A LOOP AND NOT A LIST. The first version of this file named
// three arms by hand — Parts A, B and D — against a gate of seventeen Parts and
// twenty-four ok lines. It was RIGHT about those three and silent about the other
// fourteen, and the silence read exactly like a pass: neuter Part E's failure path
// and `--selftest` exited 0, so a reader who tried the obvious experiment on the
// obvious part learned the opposite of the truth. A hand-written arm list is a
// SNAPSHOT of the gate on the day it was typed; it drifts the moment a Part is
// added, and it drifts SILENTLY, which is the defect class this file exists to
// catch. So nothing here is hand-listed:
//
//   • the set of Parts comes from the gate's OWN OUTPUT (its `— Part <id>:`
//     headers), so a Part that prints a header is a Part this file knows about;
//   • the set of INJECTABLE Parts comes from the gate's OWN SOURCE (one
//     `FAULT.has("<id>")` hook beside each ok-gate), so covering a new Part means
//     adding its hook in check.mjs and NOTHING here;
//   • the difference between those two sets is printed BY NAME as uncovered, so
//     "this gate cannot be exercised here" never again reads as "this gate did
//     not fail";
//   • which ok line belongs to which Part comes from the section the line prints
//     in, so no ok line is ever matched by a phrase typed into this file that a
//     later reword could quietly stop matching.
//
// WHAT IT STILL CANNOT ASK, said out loud because the whole point of this file is
// that a silence must never be mistaken for a pass. The arms below ask ONE
// question per Part — did this Part withhold an ok when it failed. A Part with
// TWO ok lines can therefore lose the gate on one of them and still answer yes:
// Parts G and H are the live cases, and neutering either one's FIRST gate is
// invisible to a per-Part question. So the arms also MEASURE how many ok lines the
// whole run withholds and ratchet it (OK_LINE_FLOOR): the count is derived every
// run, printed every run, and may not shrink. Losing one gate inside a two-gate
// Part drops it by one and reds here. And the ok lines that NO fault withholds —
// the ones a Part prints unconditionally, beside its own FAIL lines if it has any
// — are printed BY NAME as ungated, because those are exactly the lines this file
// can say nothing about and a reader must not read as proven.
//
// HOW IT FORCES A FAILURE WITHOUT TOUCHING THE REPO. design/check.mjs reads
// BP_DESIGN_CHECK_FAULT — a comma-separated set of part ids, each of which makes
// that part record ONE EXTRA failure at the point it records its own. The hook can
// only ADD a failure, never suppress one, so no value of that variable can mute a
// real drift; the worst a stray setting in CI does is red the gate. Nothing is
// written anywhere: each arm is one ~0.3s subprocess against the real tree, so the
// arms also prove the gate still parses and still runs end to end.
//
// PROVEN ABLE TO FAIL, measured before it was trusted: neuter ANY hooked part's
// failure path — replace its ok-gate condition with `true`, or drop the `failed++`
// its fail helper does — and that part's arm reds, naming the part. Part E is the
// recorded case: at merge sha 345288f7e the same mutation exited 0 and was
// invisible. Relaxing an assertion here to match reality deletes the test.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DESIGN_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(DESIGN_DIR, "..");
const CHECK = join(DESIGN_DIR, "check.mjs");

// A part's header line and its ok lines, both matched on SHAPE rather than on any
// wording this file restates. `Part B (§6):` and `Part C2:` both land on the id.
const PART_HEADER = /^design\/check\.mjs — Part ([A-Za-z0-9]+)\b/;
const OK_LINE = /^ {2}ok {3}/;

// What every hook prints, derived from the id. Asserting it is the PRECONDITION
// check: without it, "Part E's ok did not print" could equally mean the fault
// never landed and Part E never ran at all. It is a PREFIX, not the whole line,
// because a hook may declare more about its part after the `--selftest` — see
// DECLARES_NO_SUMMARY.
const faultPrefix = (part) => `  Part ${part} FAIL: injected fault (--selftest`;

// One part — Part A — prints a per-ARTIFACT ok line and gates no part-summary, so
// its fault withholds no ok. That is a property of Part A, declared in Part A's
// own hook message, and read back here. It is NOT an exemption this file grants:
// a part whose hook does not say this MUST withhold an ok under its own fault, so
// a new part that forgets to gate its summary reds instead of being tolerated —
// and a part that declares this and then DOES withhold one reds too, because the
// declaration has gone stale.
const DECLARES_NO_SUMMARY = "gates no part-summary";

// The ok-line ratchet. Every single-part arm records which healthy ok lines its
// fault withheld; the union is the set of ok lines this selftest has PROVEN can
// still be withheld. That count is a measurement, not a list, and it may not
// shrink: a gate that stops gating drops it, including a gate inside a Part whose
// OTHER gate still answers for the Part. Growth is fine and prints a NOTE — a new
// hooked Part earns its line without editing anything here.
const OK_LINE_FLOOR = 22;

/** One run of the real gate. `faults` is the array of part ids to force. */
function runGate(faults) {
  const env = { ...process.env };
  if (faults.length) env.BP_DESIGN_CHECK_FAULT = faults.join(",");
  else delete env.BP_DESIGN_CHECK_FAULT;
  const r = spawnSync(process.execPath, [CHECK], {
    cwd: REPO_ROOT,
    env,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw new Error(`could not run ${CHECK}: ${r.error.message}`);
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

/** stdout → Map<partId, ok lines printed under that part's header>, in run order. */
function sections(stdout) {
  const map = new Map();
  let cur = null;
  for (const line of stdout.split("\n")) {
    const m = PART_HEADER.exec(line);
    if (m) { cur = m[1]; if (!map.has(cur)) map.set(cur, []); continue; }
    if (cur && OK_LINE.test(line)) map.get(cur).push(line);
  }
  return map;
}

const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

export async function selftest() {
  // ── the control, and the source of every enumeration below ─────────────────
  // It runs FIRST because the coverage statement is derived from it, and the
  // coverage statement must print even when an arm later reds.
  const healthyRun = runGate([]);
  const healthy = sections(healthyRun.stdout);
  const PARTS = [...healthy.keys()];

  // The injectable set comes from check.mjs itself — one hook per ok-gate. The
  // `[A-Z0-9]+` shape deliberately does not match the `FAULT.has("<id>")` written
  // in that file's own comment. It was `[A-Z][A-Z0-9]*` until r21d, which is to
  // say it could not see a hook on a Part whose id STARTS with a digit — and the
  // gate has exactly one, Part 0. The set of ids here must mirror PART_HEADER's
  // `[A-Za-z0-9]+`, not a narrower guess at what a Part will be called, or a hook
  // that IS present reads here as a Part that carries none.
  const source = readFileSync(CHECK, "utf8");
  const INJECTABLE = [...new Set(
    [...source.matchAll(/FAULT\.has\("([A-Z0-9][A-Z0-9]*)"\)/g)].map((m) => m[1]),
  )];
  const covered = PARTS.filter((p) => INJECTABLE.includes(p));
  const uncovered = PARTS.filter((p) => !INJECTABLE.includes(p));
  const orphan = INJECTABLE.filter((p) => !PARTS.includes(p));

  // ── the coverage statement (c1: silence is never left to be interpreted) ────
  console.log(`design/check.mjs --selftest: coverage — ${PARTS.length} Part(s) in the gate's own output, ${covered.length} exercised here.`);
  console.log(`  exercised: ${covered.join(", ") || "(none)"}`);
  if (uncovered.length) {
    console.log(`  UNCOVERED — no \`FAULT.has("<id>")\` hook in design/check.mjs, so this selftest cannot ask whether`);
    console.log(`  their gate can still fail. A mutation to one of these exits 0 and is INVISIBLE here:`);
    for (const p of uncovered) console.log(`    Part ${p} — NOT exercised by --selftest`);
  } else {
    console.log(`  UNCOVERED: none — every Part the gate prints carries a hook.`);
  }
  if (orphan.length) console.log(`  hooks with no Part in the output: ${orphan.join(", ")}`);
  console.log("");

  const checks = [];
  const check = (name, fn) => checks.push({ name, fn });

  // Every arm asserts the subprocess REACHED the parts it is judging. A missing
  // ok line and a gate that crashed in Part 0 look identical otherwise.
  const ran = (r, what) => {
    const got = [...sections(r.stdout).keys()];
    if (!same(got, PARTS)) {
      throw new Error(`${what}: the run printed Parts [${got.join(", ")}], not the healthy run's [${PARTS.join(", ")}] — it did not reach every part being judged`);
    }
  };
  const landed = (r, part, what) => {
    const line = r.stderr.split("\n").find((l) => l.startsWith(faultPrefix(part)));
    if (!line) {
      throw new Error(`${what}: the injected Part ${part} fault did not land — expected a stderr line starting ${JSON.stringify(faultPrefix(part))}, got:\n${r.stderr}`);
    }
    return line;
  };
  const red = (r, what) => {
    if (r.status === 0) throw new Error(`${what}: the gate exited 0 with a forced failure in it`);
  };
  // Direction 1 for the faulted parts, direction 2 for every other part, in one
  // comparison against the healthy run — which is why no ok-line phrase is typed
  // into this file at all.
  // Every ok line any single-part arm proved withholdable. Populated by compare().
  const proven = new Set();
  const compare = (r, faultedLines, what, record) => {
    const got = sections(r.stdout);
    const notes = [];
    for (const p of PARTS) {
      const before = healthy.get(p), after = got.get(p);
      const declared = faultedLines.get(p);
      if (declared === undefined) {
        if (!same(before, after)) {
          throw new Error(
            `${what}: Part ${p} did NOT fail, yet its ok lines changed — false silence.\n` +
            `       healthy: ${JSON.stringify(before)}\n       now:     ${JSON.stringify(after)}`,
          );
        }
        continue;
      }
      const withheld = before.filter((l) => !after.includes(l));
      const extra = after.filter((l) => !before.includes(l));
      if (extra.length) throw new Error(`${what}: Part ${p} printed ok line(s) it does not print healthy: ${JSON.stringify(extra)}`);
      if (declared.includes(DECLARES_NO_SUMMARY)) {
        if (withheld.length) {
          throw new Error(
            `${what}: Part ${p}'s hook declares it ${JSON.stringify(DECLARES_NO_SUMMARY)}, but its fault withheld ` +
            `${JSON.stringify(withheld)} — the declaration in check.mjs has gone stale`,
          );
        }
        notes.push(`Part ${p} withheld no ok, as its hook declares`);
      } else if (!withheld.length) {
        throw new Error(
          `${what}: Part ${p} FAILED and still printed every ok line it prints healthy — false reassurance.\n` +
          `       ${JSON.stringify(before)}\n` +
          `       (if Part ${p} genuinely gates no part-summary, say so in its hook message in check.mjs.)`,
        );
      } else {
        if (record) for (const l of withheld) proven.add(l);
        notes.push(`Part ${p} withheld ${withheld.length} ok line(s)`);
      }
    }
    return notes.join("; ");
  };

  check("healthy tree: the gate exits 0, no fault fires, and every Part prints the ok lines the arms below are measured against", () => {
    const r = healthyRun;
    ran(r, "healthy");
    if (r.status !== 0) throw new Error(`healthy: the gate exited ${r.status} on an unmutated tree:\n${r.stderr}`);
    if (r.stdout.includes("injected fault") || r.stderr.includes("injected fault")) {
      throw new Error("healthy: an injected fault appeared with BP_DESIGN_CHECK_FAULT unset — the hook is not off by default");
    }
    if (!covered.length) throw new Error("healthy: design/check.mjs carries no FAULT hook at all — this selftest would assert nothing");
    if (orphan.length) throw new Error(`healthy: check.mjs hooks Part(s) ${orphan.join(", ")}, which print no header — the hook is dead or the part never runs`);
    const noOk = PARTS.filter((p) => healthy.get(p).length === 0);
    if (noOk.length && noOk.some((p) => covered.includes(p))) {
      throw new Error(`healthy: hooked Part(s) ${noOk.filter((p) => covered.includes(p)).join(", ")} print no ok line at all — nothing for a fault to withhold`);
    }
  });

  // ── one arm per injectable Part, derived — add a Part, add its hook, done ───
  for (const p of covered) {
    check(`Part ${p} fails: the gate reds, Part ${p} answers for its own ok, and every other Part keeps all of its own`, () => {
      const what = `fault=${p}`;
      const r = runGate([p]);
      ran(r, what);
      const line = landed(r, p, what);
      red(r, what);
      return compare(r, new Map([[p, line]]), what, true);
    });
  }

  // ── and the first and last hooked Parts at once, so no arm above is passing
  //    by an accident of ordering (the earliest fault cannot mask the latest) ──
  if (covered.length >= 2) {
    const pair = [covered[0], covered[covered.length - 1]];
    check(`Parts ${pair.join(" and ")} fail together: each answers for its own ok, and every Part between keeps all of its own`, () => {
      const what = `fault=${pair.join(",")}`;
      const r = runGate(pair);
      ran(r, what);
      const lines = new Map(pair.map((p) => [p, landed(r, p, what)]));
      red(r, what);
      return compare(r, lines, what, false);
    });
  }

  // ── the ok-LINE accounting: the per-Part arms above cannot see a lost gate
  //    inside a Part that has two, so count what the whole run withheld ─────────
  check(`ok-line coverage: the run withholds at least OK_LINE_FLOOR (${OK_LINE_FLOOR}) distinct ok line(s)`, () => {
    const all = PARTS.flatMap((p) => healthy.get(p));
    const ungated = all.filter((l) => !proven.has(l));
    console.log(`  ok-line coverage: ${proven.size} of ${all.length} ok line(s) proven withholdable by the arms above (floor ${OK_LINE_FLOOR}).`);
    if (ungated.length) {
      console.log(`  NOT WITHHELD by any fault above (${ungated.length} line(s)) — this selftest cannot say whether these`);
      console.log(`  would still print beside their own Part's FAIL lines. Read them as unproven, not as proven.`);
      console.log(`  A Part listed as MIXED is the one to look at: it gates some of its ok lines on its own`);
      console.log(`  failures and prints the rest regardless, so its green and its red can appear together.`);
      for (const p of PARTS) {
        const lines = healthy.get(p), open = lines.filter((l) => !proven.has(l));
        if (!open.length) continue;
        const mixed = open.length < lines.length;
        console.log(`    Part ${p} — ${open.length} of ${lines.length} not withheld${mixed ? ` (MIXED: ${lines.length - open.length} other line(s) ARE withheld)` : ""}`);
        // A wholly-unwithheld Part prints one specimen; a MIXED Part prints all of
        // them, because there the same Part can print green beside its own red.
        for (const l of (mixed ? open : open.slice(0, 1))) console.log(`      ${l.trim()}`);
        if (!mixed && open.length > 1) console.log(`      … and ${open.length - 1} more of the same shape`);
      }
    }
    if (proven.size < OK_LINE_FLOOR) {
      throw new Error(
        `ok-line coverage SHRANK ${OK_LINE_FLOOR} → ${proven.size}. An ok line that used to be withheld when its ` +
        `part failed is now printed anyway — that is the false-reassurance defect returning, and a Part with a ` +
        `second gate still answering for it will hide that from every per-Part arm above.`,
      );
    }
    if (proven.size > OK_LINE_FLOOR) {
      console.log(`  NOTE: raise OK_LINE_FLOOR in design/check-selftest.mjs from ${OK_LINE_FLOOR} to ${proven.size}.`);
      return `${proven.size} withholdable, above the ${OK_LINE_FLOOR} floor`;
    }
    return `${proven.size} withholdable, at the floor`;
  });

  let passed = 0;
  for (const c of checks) {
    let note;
    try {
      note = c.fn();
    } catch (e) {
      console.error(`FAIL ${c.name}\n     ${e.message}`);
      console.error(`\ndesign/check.mjs --selftest: FAILED — ${passed}/${checks.length} passed before this one.`);
      return false;
    }
    passed += 1;
    console.log(`ok   ${c.name}${note ? ` — ${note}` : ""}`);
  }
  console.log(
    `design/check.mjs --selftest: ${passed}/${checks.length} passed — the ok-summary gating still fails in both directions ` +
    `for all ${covered.length} hooked Part(s)${uncovered.length ? `; UNEXERCISED: ${uncovered.map((p) => `Part ${p}`).join(", ")} (see coverage above)` : ""}.`,
  );
  return true;
}
