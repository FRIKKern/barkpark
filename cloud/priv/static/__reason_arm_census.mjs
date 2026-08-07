// __reason_arm_census.mjs — THE REASON-ARM CENSUS: every refusal cause the
// router can EMIT must have a written arm in the console.
//
// Charter D448/D449 (wave 40). The law this instrument enforces:
//
//     A CAUSE THE SERVER SENDS AND THE CONSOLE HAS NO ARM FOR DOES NOT
//     DEGRADE TO SILENCE — IT DEGRADES TO WHATEVER THE CURATED DEFAULT SAYS.
//
// Auth.forbidden/2 merges evidence around the `forbidden` slug: `required` (the
// authority the gate wanted) or `reason` (a CAUSE, for refusals where no static
// authority label would be true). The console maps `reason` through
// FORBIDDEN_REASON_COPY. A reason with no arm there does not render as nothing:
// forbiddenEvidenceCopy returns null, friendly() falls through, and the person
// reads the curated `forbidden` entry — a sentence written for a completely
// different refusal. That is precisely how a plain team ADMIN clicking Remove on
// a peer admin came to read "Only the team owner can manage billing." (D448).
//
// ── WHY THIS HAS TO BE A CROSS-FILE CENSUS (charter D449) ───────────────────
//
// An app.js-only check is STRUCTURALLY BLIND to this defect. The bug is a key
// that was NEVER WRITTEN, so there is nothing in app.js to diff, nothing to
// count, and no drift to detect — the map is internally consistent and complete
// with respect to itself. The only oracle for "which causes exist" is the
// EMITTER, and the emitter is in another language in another tree. Measured:
// adding the two missing arms to app.js alone ships 919/919 green and smoke
// 104/104 green. Nothing in the console's own harness can see this class.
//
// ── THE DIRECTION IS A SUBSET, DELIBERATELY, AND ONLY ONE WAY ───────────────
//
//     { slugs router.ex can emit }  ⊆  keys(FORBIDDEN_REASON_COPY)
//
// NOT an equality. The console may legitimately carry an arm for a reason this
// router file does not emit — `no_team` is exactly that: it comes from
// Auth.gate_role in auth.ex, not from router.ex. Gating on equality would red on
// a correct tree and teach people to delete arms to quiet it, which is the
// opposite of the property. An UNUSED arm is dead copy; an UNWRITTEN arm is a
// person reading a sentence about someone else's problem.
//
// ── IT MUST NOT BE ABLE TO GO GREEN BY FAILING TO READ (exit 2) ─────────────
//
// The whole value here is the resolution of ONE dynamic binding: router.ex sends
// `Auth.forbidden(conn, reason: reason)` where `reason` is bound one hop back by
//
//     reason =
//       if Authz.can_grant?(…) == :ok, do: "outranked", else: "cannot_grant_higher_role"
//
// A census that shrugged at that would report ONE emission site instead of three
// and go green over the exact defect it exists to see. So an unresolvable
// binding is exit 2 — a REFUSAL TO MEASURE, never a pass. Same for a vanished
// FORBIDDEN_REASON_COPY, an unreadable input, an Auth.forbidden/2 call whose
// evidence shape this parser does not recognise, or a zero-slug census (which
// would mean the extractor broke, since main has three emissions today).
//
// ── HONEST LIMITS, stated, because an unstated limit is the same lie ────────
//
//   LIMIT 1 — SCOPE IS router.ex. Auth.forbidden/2 is also called from auth.ex
//   (the gate_role no-team arm). Those are the SOURCE of `no_team`, which the
//   console already answers; widening the scan is a strict improvement and is
//   filed, not done here, because auth.ex's arms are `forbidden(conn, …)` (no
//   `Auth.` prefix) and mixing the two grammars in one pass would make the
//   refusal path harder to reason about than the thing it guards.
//
//   LIMIT 2 — IT MATCHES `Auth.forbidden(conn, …)` LITERALLY. A refusal emitted
//   through a wrapper, or with the whole evidence keyword list in a variable, is
//   invisible to it. Every call it DOES see must resolve or it exits 2, so the
//   failure mode is loud rather than silent — but this raises the cost of the
//   mistake, it does not prove absence.
//
//   LIMIT 3 — IT PROVES THE ARM EXISTS, NOT THAT THE ARM IS GOOD. Whether the
//   sentence is TRUE is a judgement, and it is pinned in __app.test.mjs
//   ("the two RANK refusals are MAPPED, never echoed"). This is a coverage gate.
//
// Exit codes:
//   0 — every emittable reason slug has a written arm
//   1 — at least one does not: each is named with its emission site
//   2 — the instrument lost its footing and is making NO claim either way
//
// Run: node cloud/priv/static/__reason_arm_census.mjs
//      node cloud/priv/static/__reason_arm_census.mjs <router.ex> <app.js>
//   (the argv overrides exist so a mutation driver can point the census at a
//    patched COPY without writing inside this slice's fence — the fail-before
//    half of this guard's discrimination proof is run exactly that way)

import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const ROUTER = process.argv[2] || path.join(here, "../../lib/barkpark_cloud/web/router.ex");
const APP = process.argv[3] || path.join(here, "app.js");
// Report against stable repo-relative labels so the output reads the same from
// any cwd; a mutant copy passed on argv keeps its own path.
const ROUTER_LABEL = process.argv[2] || "cloud/lib/barkpark_cloud/web/router.ex";
const APP_LABEL = process.argv[3] || "cloud/priv/static/app.js";

function die2(lines) {
  console.error("");
  for (const l of lines) console.error(l);
  console.error("");
  console.error("  EXIT 2 — THE CENSUS REFUSED TO MEASURE. It is making NO claim about this tree:");
  console.error("  nothing here says the console's reason arms are complete and nothing says they");
  console.error("  are not. A gate that cannot read its input must not go green (charter D449).");
  process.exit(2);
}

function read(file, label) {
  if (!fs.existsSync(file)) die2([`FAIL(2): ${label} not readable at ${file}.`]);
  return fs.readFileSync(file, "utf8");
}

const routerSrc = read(ROUTER, ROUTER_LABEL);
const appSrc = read(APP, APP_LABEL);
const routerLines = routerSrc.split("\n");
const lineOf = (index) => routerSrc.slice(0, index).split("\n").length;

// ═══════════════════════════════════════════════════════════════════════════
// (A) THE EMITTER SIDE — every slug `Auth.forbidden(conn, reason: …)` can send.
//
// Every Auth.forbidden/2 call is classified. A call carrying `required:` is a
// ROLE refusal and contributes no reason slug (the console answers those through
// FORBIDDEN_ROLE_COPY, a different map with a different completeness property:
// it has a bounded-label fallback, so an unwritten `required` still renders
// something true). A call carrying `reason:` must yield one or more literal
// slugs. Anything else is unrecognised → exit 2.
// ═══════════════════════════════════════════════════════════════════════════

const CALL_RE = /Auth\.forbidden\(\s*conn\s*,([^\n]*)/g;
const emissions = []; // { slug, line, via }
const roleSites = [];
let m;
while ((m = CALL_RE.exec(routerSrc)) !== null) {
  const line = lineOf(m.index);
  const args = m[1];

  if (/\brequired:\s*/.test(args)) {
    roleSites.push(line);
    continue;
  }

  const literal = args.match(/\breason:\s*"([a-z][a-z0-9_]*)"/);
  if (literal) {
    emissions.push({ slug: literal[1], line, via: "literal" });
    continue;
  }

  const bound = args.match(/\breason:\s*([a-z_][a-zA-Z0-9_]*)\s*\)?/);
  if (bound) {
    const name = bound[1];
    const resolved = resolveBinding(name, line);
    if (!resolved.length) {
      die2([
        `FAIL(2): an unresolvable \`reason:\` binding at ${ROUTER_LABEL}:${line}.`,
        `  The call sends \`reason: ${name}\`, and this census could not resolve \`${name}\` to a`,
        "  set of string literals by walking back from the call site.",
        "",
        "  THIS IS THE ONE THING THE CENSUS EXISTS TO DO. Resolving that binding is what",
        "  turns one visible call site into the THREE slugs the router can actually emit;",
        "  shrugging at it would under-report the emitter set and go green over the defect.",
        "  Teach the resolver the new shape, or make the binding literal at the call site.",
      ]);
    }
    for (const slug of resolved) emissions.push({ slug, line, via: `bound \`${name}\`` });
    continue;
  }

  die2([
    `FAIL(2): an Auth.forbidden/2 call at ${ROUTER_LABEL}:${line} carries evidence this census`,
    "  does not recognise — neither `required:` nor `reason:`.",
    `    ${routerLines[line - 1].trim()}`,
    "  A third evidence key would be a third thing the console has to answer, and this",
    "  gate would be silently blind to it. Classify it here before it ships.",
  ]);
}

// ONE HOP BACK. Walks up from the call site to the nearest `<name> =` binding and
// collects every string literal in an `if …, do: "A", else: "B"` (the shape at
// router.ex:4952-4956, written across four lines). The window is bounded so a
// same-named binding in a distant clause cannot be mistaken for this one.
function resolveBinding(name, callLine) {
  const WINDOW = 40;
  for (let i = callLine - 1; i >= Math.max(1, callLine - WINDOW); i--) {
    const text = routerLines[i - 1];
    if (!new RegExp("^\\s*" + name + "\\s*=\\s*(#.*)?$|^\\s*" + name + "\\s*=\\s+[^=]").test(text)) continue;
    // The binding's body: from this line up to (but not including) the call.
    const body = routerLines.slice(i - 1, callLine - 1).join("\n");
    // Only an `if …, do:/else:` conditional is understood; a bare literal
    // assignment (`reason = "x"`) resolves to that one literal.
    const arms = [...body.matchAll(/\b(?:do|else):\s*"([a-z][a-z0-9_]*)"/g)].map((a) => a[1]);
    if (arms.length) return [...new Set(arms)];
    const flat = body.match(new RegExp("^\\s*" + name + '\\s*=\\s*"([a-z][a-z0-9_]*)"', "m"));
    if (flat) return [flat[1]];
    return []; // found the binding, could not read it → the caller exits 2
  }
  return [];
}

// THE VACUITY FLOOR. main emits three reason slugs from two call sites today. A
// census that found NONE has a broken extractor, not a clean tree — and it would
// pass trivially, which is exactly the clause-4 vacuity this epic exists to kill.
if (!emissions.length) {
  die2([
    `FAIL(2): ZERO \`reason:\` emissions found in ${ROUTER_LABEL}.`,
    `  ${roleSites.length} Auth.forbidden/2 call(s) were seen, all classified as \`required:\` role refusals.`,
    "  A subset check over an EMPTY set passes trivially. Either the router genuinely stopped",
    "  sending causes (delete this gate in the same commit, with a reason) or — far more likely",
    "  — the extractor stopped matching the call shape. It must not report that as clean.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (B) THE CONSOLE SIDE — the arms FORBIDDEN_REASON_COPY actually writes.
// ═══════════════════════════════════════════════════════════════════════════

const mapStart = appSrc.indexOf("var FORBIDDEN_REASON_COPY = {");
if (mapStart === -1) {
  die2([
    `FAIL(2): FORBIDDEN_REASON_COPY not found in ${APP_LABEL}.`,
    "  This census resolves the console side by NAME, not by line. Either the map was renamed",
    "  (point this census at the new name in the same commit) or the reason seam was removed —",
    "  in which case every cause the router sends is falling through to the curated default,",
    "  which is the defect, not the fix.",
  ]);
}
const bodyStart = appSrc.indexOf("{", mapStart);
let depth = 0;
let bodyEnd = -1;
for (let i = bodyStart; i < appSrc.length; i++) {
  if (appSrc[i] === "{") depth++;
  else if (appSrc[i] === "}") {
    depth--;
    if (depth === 0) { bodyEnd = i; break; }
  }
}
if (bodyEnd === -1) die2([`FAIL(2): FORBIDDEN_REASON_COPY in ${APP_LABEL} is unbalanced — the map body could not be read.`]);

const mapBody = appSrc.slice(bodyStart + 1, bodyEnd);
const arms = new Set([...mapBody.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"/gm)].map((a) => a[1]));
if (!arms.size) {
  die2([
    `FAIL(2): FORBIDDEN_REASON_COPY was found in ${APP_LABEL} but parsed to ZERO arms.`,
    "  An empty arm set makes every emittable reason a miss, which would look like a very loud",
    "  PASS-BEFORE/FAIL-AFTER gate for the wrong reason. The parser has lost the map's shape.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (C) THE SUBSET CHECK.
// ═══════════════════════════════════════════════════════════════════════════

const missing = emissions.filter((e) => !arms.has(e.slug));

if (missing.length) {
  console.error("");
  console.error("FAIL(1): the router can emit refusal causes the console has no written arm for.");
  console.error("");
  for (const e of missing) {
    console.error(`  UNANSWERED  reason: "${e.slug}"   emitted at ${ROUTER_LABEL}:${e.line}  (${e.via})`);
    console.error(`              ${routerLines[e.line - 1].trim()}`);
  }
  console.error("");
  console.error("  These do NOT degrade to silence. forbiddenEvidenceCopy returns null, friendly()");
  console.error("  falls through, and the person reads the curated `forbidden` entry — a sentence");
  console.error("  written for a different refusal entirely (charter D448).");
  console.error("");
  console.error(`  Write an arm in FORBIDDEN_REASON_COPY (${APP_LABEL}) for each. MAP it, never echo it:`);
  console.error("  a slug rendered raw puts \"cannot grant higher role\" in front of a human.");
  console.error("");
  console.error(`  emittable (${new Set(emissions.map((e) => e.slug)).size}): ${[...new Set(emissions.map((e) => e.slug))].sort().join(", ")}`);
  console.error(`  written   (${arms.size}): ${[...arms].sort().join(", ")}`);
  process.exit(1);
}

const slugs = [...new Set(emissions.map((e) => e.slug))].sort();
const unused = [...arms].filter((a) => !slugs.includes(a)).sort();
console.log("");
console.log(`OK: all ${emissions.length} \`reason:\` emission(s) in ${ROUTER_LABEL} resolve to a written arm.`);
console.log(`    emitted (${slugs.length}): ${slugs.join(", ")}`);
console.log(`    written (${arms.size}): ${[...arms].sort().join(", ")}`);
if (unused.length) {
  console.log(`    arms this file does not emit (NOT a failure — auth.ex sends these): ${unused.join(", ")}`);
}
console.log(`    ${roleSites.length} Auth.forbidden/2 call(s) classified as \`required:\` role refusals (a different map, with a bounded-label fallback).`);
process.exit(0);
