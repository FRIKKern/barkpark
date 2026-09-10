// __envelope_census.mjs — THE ENVELOPE CENSUS, GENERALIZED PAST /v1/me.
//
// cch-w43-bl-envelope-census-generalizes-past-v1-me. The law is the one
// __me_envelope_census.mjs already enforces, said for every endpoint:
//
//     A CORPUS THAT MINTS A DIFFERENT ROW THAN THE SERVER MINTS
//     IS A GATE CERTIFYING A CONSOLE NOBODY WILL EVER RUN.
//
// ── WHAT THIS ADDS OVER THE /v1/me CENSUS ───────────────────────────────────
//
// The /v1/me census runs a TWO-WAY diff — server keys vs corpus keys — over ONE
// endpoint. This runs a THREE-WAY diff over several:
//
//     keys(defp <x>_json)  ×  keys(<x>() producer, as SERVED)  ×  reads(app.js)
//
// The third axis is the one that turns a list of holes into a VERDICT, because
// the two directions of the two-way diff are not equally serious and the /v1/me
// census had no way to say so:
//
//   UNPAINTABLE (a FAILURE, exit 1)
//       The server ALWAYS sends K, app.js READS K, and no scenario serves it.
//       There is a rendered band here that no preview scenario can ever paint.
//       Every gate downstream of that read is certifying a row the console has
//       never been shown. This is the team-switcher shape, one endpoint over.
//
//   DEAD PAYLOAD (REPORTED, never failed)
//       The server sends K and NOTHING in app.js reads it. The fixture omitting
//       it costs the console nothing, because no render path would notice. It
//       is printed by name — an instrument that reports only the half that
//       fails is an instrument you cannot use to decide anything — but it does
//       not red, because a fixture is not obliged to model payload no surface
//       consumes.
//
//   INVENTED (a FAILURE, exit 1)
//       The corpus serves K and the server does not state it. Anything asserted
//       downstream of K is fiction. Unchanged from the /v1/me census.
//
// Splitting MISSING on the read axis is the whole point of the row. Without it
// the census on origin/main reports THIRTY-EIGHT holes across the three
// endpoints and says nothing about which of them matters — and measured, SEVEN
// do. The other thirty-one are payload no console surface consumes.
//
// ── THE PARSER IS THE /v1/me CENSUS'S OWN ───────────────────────────────────
//
// Every Elixir-side walker here is IMPORTED from __me_envelope_census.mjs, not
// re-implemented. A second copy of that map-literal walker would drift, and two
// censuses that disagree about what the server states is precisely the failure
// this instrument exists to catch, wearing the instrument's own coat. The
// /v1/me census's behaviour as a SCRIPT is byte-identical to what it was before
// the split (its main block is guarded by IS_MAIN); what changed is that its
// walkers are exported and take their refusal vocabulary from a context, so a
// deployments-map parse failure refuses in THIS census's name.
//
// ── WHY THE CORPUS SIDE IS SERVED, NOT PARSED ───────────────────────────────
//
// Same reason the /v1/me census gives, and it bites harder here. Parsing the
// `deployment()` object literal out of scenarios.mjs would report every key
// only an OVERRIDE supplies (`became_live_at`, `preview_host`, `branch`) as a
// hole, and every key a per-scenario row invents as absent. So the corpus side
// calls `route(name, method, path, state)` — the same function mock.js and
// smoke.mjs both delegate to — over EVERY scenario and unions the shapes that
// actually come back. A key counts as SERVED if ANY scenario serves it.
//
// Deployments are reached through the SITES list, per scenario, per site, so
// the `deploymentsBySite` seam is covered without this file knowing it exists.
//
// ── THE READ AXIS, AND WHY IT IS NOT A LIST OF VARIABLE NAMES ───────────────
//
// The naive read test is `grep '\.trigger' app.js`, and on this very endpoint it
// gives the WRONG answer twice over. The filing that produced this row claimed
// a `deployment.source` read in app.js and cited a line for it. There is no such
// read: every `.source` in app.js hangs off a timeline/audit-verify entry
// (`tlvCoalesceKey`, `tlvVerdictOf` and the timeline sort beside them) or off
// `providerIdentityModel`'s stored-id check — never off a deployment. A name-keyed
// grep cannot tell those apart, and a hand-written list of "deployment
// variables" is a snapshot that rots the first time someone renames one.
//
// So the receivers are DERIVED, by a predicate, per NODE of the server tree:
//
//     An identifier R in app.js HOLDS a value of node N when the properties R
//     is read for that are EXCLUSIVE to N — child key names of N no other node
//     claims — sum to MIN_EVIDENCE, each weighted 1/fanout(k), where fanout is
//     how many distinct identifiers in all of app.js read a `.k` at all.
//
// The weighting is not decoration and a flat COUNT does not work. `d` reads
// `d.git_ref`, `d.image_tag`, `d.became_live_at` — names only a deployment has,
// each read off exactly one identifier in the whole file — and scores 9.5, so
// `d` holds deployments and `d.trigger` COUNTS. The timeline-entry variable `e`
// reads `status`, `source` and `detail`, three names no other censused node
// claims either; a count-of-3 rule recruits it as a deployment and
// `deployment.source` then reads as "the console reads this", which is exactly
// the false claim this row's own filing made. Weighted, `e`
// scores 0.5 — `status` is read off thirty-one identifiers, `detail` and
// `source` off six — and `source` lands on the dead-payload arm, where the
// source says it belongs.
//
// MIN_EVIDENCE is 1.0 because that number means something: the evidence of ONE
// property name that nothing else in app.js reads.
//
// HONEST RESIDUAL, and it is not small. A name collision this census cannot see
// through still recruits: the SSE payload variable reads `site_id` (fanout 1),
// `detail` and `stage`, scores 1.33, and is counted a deployment receiver — so
// `deployment.stage` reads as READ when the identifier reading it is a
// stage-event, not a row. Its sibling case is `last_deployment`, which states
// SIX names and owns none of them; that node is unaddressable by construction
// and its verdict is inherited from the deployment shape it collides with (see
// isRead). Both err toward READ, i.e. toward the arm that FAILS, which is the
// only safe direction for a gate to be wrong in — and in both the remedy is
// the same and is correct either way: the producer emits a key the server
// already sends on every row.
//
// ── IT REFUSES RATHER THAN PASSING ──────────────────────────────────────────
//
// The read axis is the one that can go quiet, and quiet here is fail-GREEN: a
// census that finds NO receiver for a node reads every one of that node's keys
// as unread, moves every hole to the reported arm, and exits 0 over a live
// regression. So a node with children and no discovered receiver REFUSES (exit
// 2) naming the node. So does an unreadable/unparseable router.ex, a serializer
// that is gone or has two clauses at the named arity, and a corpus where no
// scenario answers the endpoint at all.
//
// USAGE
//   node cloud/priv/static/__envelope_census.mjs [<router.ex>]
//
// EXIT
//   0 — every endpoint: no UNPAINTABLE key, no INVENTED key (dead payload may
//       still be reported, and is printed either way)
//   1 — at least one UNPAINTABLE or INVENTED key path, all named
//   2 — refused to measure

import fs from "node:fs";
import path from "node:path";
import { SCENARIO_NAMES, route } from "./__preview__/scenarios.mjs";
import {
  useCensusContext,
  blank,
  balanced,
  namedHelperMap,
  scalarOrMapHelper,
  walkMap,
  valuePaths,
  isOpaque,
  underOpaque,
} from "./__me_envelope_census.mjs";

const here = path.dirname(new URL(import.meta.url).pathname);
const ROUTER = process.argv[2] || path.join(here, "../../lib/barkpark_cloud/web/router.ex");
const APP_JS = path.join(here, "app.js");

// ── THE ONE REFUSAL VOCABULARY (cch-w63-bl) ─────────────────────────────────
// One exit-2 path, on STDERR, in the shape scripts/console-refusal-capture.mjs
// reads. Do not add a second.
const REFUSAL_NAME = "ENVELOPE CENSUS";
const refuse2 = (reason) => {
  process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\n`);
  process.exit(2);
};

function die2(lines) {
  console.log("── ENVELOPE CENSUS ──────────────────────────────────────────────────────────");
  for (const l of lines) console.log(l);
  console.log("");
  refuse2(String(lines[0] || "the census could not measure an envelope").replace(/^FAIL\(2\):\s*/, ""));
}

// The evidence an app.js identifier must carry before it is believed to hold a
// value of a node: the sum of 1/fanout over the node-exclusive properties read
// off it. 1.0 has a meaning rather than being a knob — it is "the equivalent of
// ONE property name that nothing else in app.js reads". See the header.
const MIN_EVIDENCE = 1.0;

// ── THE ENDPOINTS ───────────────────────────────────────────────────────────
//
// Each names its SERVER side (a serializer by name/arity, or — for /v1/me — the
// route clause's own response map, which has no serializer to name) and its
// CORPUS side (a function from one scenario to the rows that endpoint served).
// Adding an endpoint is these five lines; nothing else in this file is
// per-endpoint.
const ENDPOINTS = [
  {
    id: "/v1/me",
    server: { clause: 'get "/v1/me" do' },
    corpus(name) {
      const res = route(name, "GET", "/v1/me", {});
      return res && res.status === 200 && res.body && typeof res.body === "object" ? [res.body] : [];
    },
  },
  {
    id: "/v1/sites",
    // The list surface calls `site_json/1`, which is a one-line delegator to
    // `site_json/2` — the /2 clause is where every key is spelled, so that is
    // the arity named. Naming /1 would derive ONE key path (the delegation) and
    // report the whole corpus as invented.
    //
    // `folds` are keys the ROUTE adds after the serializer returns:
    //   json(conn, 200, %{sites: Enum.map(sites, &put_last_deployment(site_json(&1), &1, fresh))})
    // Without it `last_deployment` and its four sub-keys read as INVENTED — the
    // corpus serving something the server "does not state" — when the server
    // states it one call further out. A census that reports a real key as
    // fiction teaches its readers to ignore it.
    server: { serializer: "site_json", arity: 2, folds: [{ key: "last_deployment", helper: "last_deployment_json" }] },
    corpus(name) {
      const res = route(name, "GET", "/v1/sites", {});
      return res && res.status === 200 && res.body && Array.isArray(res.body.sites) ? res.body.sites : [];
    },
  },
  {
    id: "/v1/sites/:id/deployments",
    server: { serializer: "deployment_json", arity: 1 },
    corpus(name) {
      const sites = route(name, "GET", "/v1/sites", {});
      const rows = sites && sites.status === 200 && sites.body && Array.isArray(sites.body.sites) ? sites.body.sites : [];
      const out = [];
      for (const s of rows) {
        if (!s || !s.id) continue;
        const res = route(name, "GET", `/v1/sites/${s.id}/deployments`, {});
        if (res && res.status === 200 && res.body && Array.isArray(res.body.deployments)) out.push(...res.body.deployments);
      }
      return out;
    },
  },
];

// ── the server side ─────────────────────────────────────────────────────────
useCensusContext({ router: ROUTER, die2, resolveBare: scalarOrMapHelper });

let SRC;
try {
  SRC = fs.readFileSync(ROUTER, "utf8");
} catch (e) {
  die2([`FAIL(2): router.ex not readable at ${ROUTER} — the server side of every diff cannot be derived.`, `         ${e.message}`]);
}
const BLANKED = blank(SRC);

function routeClauseMap(clause) {
  let at = -1;
  for (let i = SRC.indexOf(clause); i !== -1; i = SRC.indexOf(clause, i + 1)) {
    if (BLANKED[i] === clause[0]) { at = i; break; }
  }
  if (at === -1) {
    die2([
      `FAIL(2): no \`${clause}\` clause in ${path.relative(process.cwd(), ROUTER)}.`,
      `         The route this endpoint mirrors is gone or renamed. An EMPTY server-side set`,
      `         would green every corpus, so nothing is reported.`,
    ]);
  }
  const j = BLANKED.indexOf("json(conn, 200, %{", at);
  if (j === -1) {
    die2([`FAIL(2): the \`${clause}\` clause has no \`json(conn, 200, %{\` response map — its 200 body is built some other way now.`]);
  }
  const region = balanced(BLANKED, BLANKED.indexOf("{", j));
  if (!region) die2([`FAIL(2): the \`${clause}\` response map is unbalanced — refusing to measure.`]);
  return region;
}

for (const ep of ENDPOINTS) {
  useCensusContext({ subject: ep.id });
  const region = ep.server.clause
    ? routeClauseMap(ep.server.clause)
    : namedHelperMap(BLANKED, ep.server.serializer, ep.server.arity);
  const out = new Set();
  walkMap(BLANKED, region, "", out, ep.id);
  for (const f of ep.server.folds || []) {
    out.add(f.key);
    const folded = scalarOrMapHelper(BLANKED, f.helper, `${ep.id} ${f.key}`);
    if (!folded) {
      die2([
        `FAIL(2): the fold \`${f.key}\` of ${ep.id} names \`${f.helper}\`, and no clause of it returns a map.`,
        `         A fold this census cannot see through states its sub-keys nowhere, and the corpus`,
        `         serving them would then read as INVENTED — a real key reported as fiction.`,
      ]);
    }
    walkMap(BLANKED, folded, f.key + ".", out, `${ep.id} ${f.key}`);
  }
  if (!out.size) die2([`FAIL(2): the server side of ${ep.id} derived ZERO key paths.`]);
  ep.serverPaths = out;
  ep.serverLabel = ep.server.clause
    ? `${ep.server.clause.replace(/\s+do$/, "")} response map`
    : `defp ${ep.server.serializer}/${ep.server.arity}`;
}

// ── the corpus side ─────────────────────────────────────────────────────────
for (const ep of ENDPOINTS) {
  const served = new Set();
  const byPath = new Map();
  let rows = 0;
  let answering = 0;
  for (const name of SCENARIO_NAMES) {
    let got;
    try {
      got = ep.corpus(name);
    } catch (e) {
      die2([`FAIL(2): the corpus read for ${ep.id} threw on scenario "${name}" — the corpus cannot be censused.`, `         ${e.message}`]);
    }
    if (!got.length) continue;
    answering++;
    for (const row of got) {
      if (!row || typeof row !== "object") continue;
      rows++;
      const mine = new Set();
      valuePaths(row, "", mine);
      for (const p of mine) {
        served.add(p);
        if (!byPath.has(p)) byPath.set(p, []);
        if (!byPath.get(p).includes(name)) byPath.get(p).push(name);
      }
    }
  }
  if (!rows) {
    die2([
      `FAIL(2): NOT ONE of the ${SCENARIO_NAMES.length} scenarios served a row for ${ep.id}.`,
      `         An empty corpus side reports every server key as missing and every corpus key as`,
      `         absent — a result, not a measurement.`,
    ]);
  }
  ep.served = served;
  ep.byPath = byPath;
  ep.rows = rows;
  ep.answering = answering;
}

// ── the read axis ───────────────────────────────────────────────────────────
//
// Blank JS line/block comments and string bodies (length preserved) so a key
// name inside a comment or a message string is not mistaken for a read. This is
// the census's own founding sin in miniature: `// team_authority.admin carries`
// appears SIX times in app.js's prose, and a scan that counted those would
// certify the exact key it was built to interrogate.
function blankJs(src) {
  const out = src.split("");
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    if (c === "/" && n === "/") {
      while (i < src.length && src[i] !== "\n") { out[i] = " "; i++; }
    } else if (c === "/" && n === "*") {
      out[i] = " "; out[i + 1] = " "; i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { if (src[i] !== "\n") out[i] = " "; i++; }
      if (i < src.length) { out[i] = " "; out[i + 1] = " "; i += 2; }
    } else if (c === '"' || c === "'" || c === "`") {
      const q = c;
      i++;
      while (i < src.length && src[i] !== q) {
        if (src[i] === "\\") { out[i] = " "; i++; }
        if (i < src.length) { if (src[i] !== "\n") out[i] = " "; i++; }
      }
      i++;
    } else {
      i++;
    }
  }
  return out.join("");
}

let APP;
try {
  APP = blankJs(fs.readFileSync(APP_JS, "utf8"));
} catch (e) {
  die2([`FAIL(2): app.js not readable at ${APP_JS} — the READ axis cannot be derived, and without it every`, `         hole would land on the reported arm and this census would exit 0 over a live regression.`, `         ${e.message}`]);
}

// identifier → the dotted property chains read off it. `a.b.c` contributes both
// "b" and "b.c" to a's set, so a node reached through its parent's receiver is
// still visible (`me.user.platform_operator` is how app.js actually spells that
// read — there is no `user` variable at that site).
//
// FANOUT is the second product of the same pass: for each property NAME, the
// set of distinct identifiers it is read directly off. It is how this census
// tells a name that identifies a type from a name that is merely common
// English. `git_ref` is read off exactly one identifier in all of app.js;
// `status` off thirty-one. Measured, never listed.
const READS = new Map();
const FANOUT = new Map();
{
  const re = /\b([A-Za-z_$][\w$]*)((?:\.[A-Za-z_$][\w$]*)+)/g;
  let m;
  while ((m = re.exec(APP)) !== null) {
    const recv = m[1];
    const segs = m[2].slice(1).split(".");
    if (!READS.has(recv)) READS.set(recv, new Set());
    const set = READS.get(recv);
    for (let i = 1; i <= segs.length; i++) set.add(segs.slice(0, i).join("."));
    let parent = recv;
    for (const s of segs) {
      if (!FANOUT.has(s)) FANOUT.set(s, new Set());
      FANOUT.get(s).add(parent);
      parent = s;
    }
  }
}
const fanout = (k) => (FANOUT.has(k) ? FANOUT.get(k).size : 0);

// The child key names of a node — the node "" being the endpoint root.
function childrenOf(paths, node) {
  const stem = node ? node + "." : "";
  const listStem = node ? node + "[]." : "";
  const kids = new Set();
  for (const p of paths) {
    for (const s of [stem, listStem]) {
      if (!s && p.includes(".")) continue;
      if (s && !p.startsWith(s)) continue;
      const rest = p.slice(s.length);
      if (!rest || rest.includes(".")) continue;
      kids.add(rest);
    }
  }
  return kids;
}

// Every node (path with children) of every endpoint, root included.
const NODES = [];
for (const ep of ENDPOINTS) {
  const seen = new Set([""]);
  NODES.push({ ep, node: "", kids: childrenOf(ep.serverPaths, "") });
  for (const p of ep.serverPaths) {
    if (isOpaque(ep.serverPaths, p) || seen.has(p)) continue;
    seen.add(p);
    NODES.push({ ep, node: p, kids: childrenOf(ep.serverPaths, p) });
  }
}

// A key name is EXCLUSIVE to a node when no OTHER node claims it. `id`, `name`
// and `status` are claimed by several and buy no evidence; `git_ref` and
// `previews_enabled` are claimed by one each and do.
const CLAIMS = new Map();
for (const n of NODES) for (const k of n.kids) CLAIMS.set(k, (CLAIMS.get(k) || 0) + 1);

for (const n of NODES) {
  n.exclusive = [...n.kids].filter((k) => CLAIMS.get(k) === 1);
  n.receivers = [];
  for (const [recv, props] of READS) {
    const hits = n.exclusive.filter((k) => props.has(k));
    // Evidence is WEIGHTED by 1/fanout: a name only this node's receiver reads
    // is worth a whole point, one thirty-one identifiers read is worth 1/31.
    // A flat count of exclusive hits does not work here and the failure is not
    // hypothetical — the timeline-entry variable `e` reads `status`, `source`
    // and `detail`, three names no OTHER censused node claims, and a count-of-3
    // rule recruits it as a deployment. `deployment.source` then reads as
    // "read by the console", which is exactly the false claim this row's own
    // filing made — it cited a line for a deployment `.source` read that app.js
    // has never had.
    const score = hits.reduce((a, k) => a + 1 / Math.max(1, fanout(k)), 0);
    if (score >= MIN_EVIDENCE) n.receivers.push({ recv, hits, score });
  }
  n.receivers.sort((a, b) => b.score - a.score || a.recv.localeCompare(b.recv));
}

// A node with no receiver is UNADDRESSABLE: its keys can only be seen through a
// chain off an ancestor (`me.team.slug`). Some nodes are unaddressable by
// construction — `/v1/me`'s `team` states id, name and slug and NOT ONE of
// those is exclusive to it, because a site states all three too. That is not a
// defect in the node; it is a name collision, and refusing on it outright would
// make this census unable to run at all.
//
// It is still a blind spot, and blindness on the read axis is fail-GREEN. So
// the refusal is placed exactly where the blindness could change an answer:
// below, at the moment a MISSING key path under an unaddressable node reads as
// unread. A key the corpus already serves is never in question, so a node
// nobody can address and whose keys are all served costs the verdict nothing
// and is reported as such.
for (const ep of ENDPOINTS) {
  const root = NODES.find((n) => n.ep === ep && n.node === "");
  if (root.receivers.length) continue;
  die2([
    `FAIL(2): no app.js identifier could be shown to hold a ${ep.id} row.`,
    `         Its ${root.exclusive.length} exclusive key name(s) — ${root.exclusive.slice(0, 8).join(", ") || "(none)"} —`,
    `         are read off no identifier ${MIN_EVIDENCE}-at-a-time, so this census cannot say which of this`,
    `         endpoint's keys the console reads. With no receiver EVERY hole moves to the reported`,
    `         arm and this census exits 0 over a live regression, so it refuses instead.`,
  ]);
}

// The node a path hangs directly off — the root for a top-level key.
function deepestNode(ep, p) {
  const bare = p.replace(/\[\]/g, "");
  const parent = bare.includes(".") ? bare.slice(0, bare.lastIndexOf(".")) : "";
  return (
    NODES.find((n) => n.ep === ep && n.node.replace(/\[\]/g, "") === parent) ||
    NODES.find((n) => n.ep === ep && n.node === "")
  );
}

// Is server path P read anywhere in app.js? Through any receiver of any
// ancestor node, reading the remainder of the path off it.
function isRead(ep, p) {
  const bare = p.replace(/\[\]/g, "");
  for (const n of NODES) {
    if (n.ep !== ep) continue;
    const stem = n.node ? n.node.replace(/\[\]/g, "") + "." : "";
    if (stem && !bare.startsWith(stem)) continue;
    const rest = bare.slice(stem.length);
    if (!rest) continue;
    for (const r of n.receivers) if (READS.get(r.recv).has(rest)) return true;
  }
  // ── READ BY SHAPE, when the node cannot be told apart from another ─────────
  //
  // An UNADDRESSABLE node — one with no exclusive key name at all — is by
  // definition indistinguishable from the nodes it collides with, and the
  // collision is not academic. `/v1/sites`' `last_deployment` states status,
  // trigger, failure_class, failure_reason, inserted_at and updated_at; a
  // DEPLOYMENT states all six. app.js reads them off the same variable, because
  // `var d = s && s.last_deployment` binds the embed to the very identifier the
  // deployment rows use. There is no analysis of this file that separates them.
  //
  // So the verdict is inherited: a key of an unaddressable node is READ when
  // some ADDRESSABLE node that claims the same key name has a receiver reading
  // it. The alternative is to call it unread, and unread is the arm that does
  // not fail — a census guessing in the direction that greens is the one thing
  // it must never do.
  const owner = deepestNode(ep, p);
  if (owner.exclusive.length) return false;
  const leaf = bare.slice(bare.lastIndexOf(".") + 1);
  for (const n of NODES) {
    if (!n.receivers.length || !n.kids.has(leaf)) continue;
    for (const r of n.receivers) if (READS.get(r.recv).has(leaf)) return true;
  }
  return false;
}

// ── the report ──────────────────────────────────────────────────────────────
const pad = (s, n) => (s + " ".repeat(n)).slice(0, Math.max(n, s.length));
let unpaintable = 0;
let inventedTotal = 0;
let deadTotal = 0;

console.log("── ENVELOPE CENSUS ──────────────────────────────────────────────────────────");
console.log(`   server  ${path.relative(process.cwd(), ROUTER)}`);
console.log(`   corpus  __preview__/scenarios.mjs — route() over ${SCENARIO_NAMES.length} scenarios`);
console.log(`   reads   ${path.relative(process.cwd(), APP_JS)} — receivers derived, ≥${MIN_EVIDENCE} node-exclusive properties`);
console.log("");

for (const ep of ENDPOINTS) {
  const missing = [...ep.serverPaths].filter((p) => !ep.served.has(p)).sort();
  const invented = [...ep.served].filter((p) => !ep.serverPaths.has(p) && !underOpaque(ep.serverPaths, p)).sort();
  // DEAD PAYLOAD is a property of the SERVER key, not of the hole: a key the
  // console never reads is dead whether or not a fixture happens to carry it.
  // Scoping it to the missing set would have hidden `user.confirmed` and the
  // three unread `onboarding` keys — the four this row names by name — purely
  // because me() already emits them.
  const dead = [...ep.serverPaths].filter((p) => !isRead(ep, p)).sort();
  const unread = missing.filter((p) => !isRead(ep, p));
  const read = missing.filter((p) => isRead(ep, p));

  // THE FAIL-GREEN GUARD, placed where the blindness could change the answer.
  // A missing key that reads as UNREAD lands on the reported arm and does not
  // fail. If the node it hangs off is unaddressable, "unread" may only mean
  // "unseeable", and this census would be printing a clean line over a hole
  // exactly like the one it exists to catch.
  for (const p of unread) {
    const owner = deepestNode(ep, p);
    if (owner.receivers.length) continue;
    die2([
      `FAIL(2): \`${p}\` of ${ep.id} is served by NO scenario, and this census cannot say whether`,
      `         app.js reads it: no identifier could be shown to hold \`${owner.node || "the root"}\`, whose key`,
      `         names (${[...owner.kids].slice(0, 6).join(", ")}) are each claimed by another node too.`,
      `         Reporting it as dead payload would be a clean line over an unmeasured hole.`,
    ]);
  }
  unpaintable += read.length;
  inventedTotal += invented.length;
  deadTotal += dead.length;

  const root = NODES.find((n) => n.ep === ep && n.node === "");
  console.log(`══ ${ep.id}`);
  console.log(`   server ${pad(ep.serverLabel, 42)} ${ep.serverPaths.size} key paths`);
  console.log(`   corpus ${pad(`${ep.rows} rows from ${ep.answering} scenarios`, 42)} ${ep.served.size} key paths`);
  console.log(`   held in app.js by ${root.receivers.slice(0, 4).map((r) => `\`${r.recv}\` [${r.score.toFixed(1)}: ${r.hits.slice(0, 3).join(", ")}]`).join(", ") || "—"}`);
  console.log("");

  if (read.length) {
    console.log(`   UNPAINTABLE — the server always sends these, app.js READS them, NO scenario serves them (${read.length}):`);
    for (const p of read) console.log(`      ✗ ${p}`);
    console.log("");
    console.log("      A rendered band exists here that no preview scenario can paint. Widen the");
    console.log("      PRODUCER in __preview__/scenarios.mjs — one builder, every scenario — never");
    console.log("      the scenario list.");
    console.log("");
  }
  if (invented.length) {
    console.log(`   INVENTED — the corpus serves these and the server does not state them (${invented.length}):`);
    for (const p of invented) console.log(`      ✗ ${p}  ← served by ${(ep.byPath.get(p) || []).slice(0, 3).join(", ")}`);
    console.log("");
  }
  if (dead.length) {
    console.log(`   DEAD PAYLOAD (reported, NOT a failure) — the server sends these and NOTHING in app.js reads them (${dead.length}):`);
    for (const p of dead) console.log(`      · ${p}${ep.served.has(p) ? "" : "   (and no scenario serves it either)"}`);
    console.log("");
  }
  if (!read.length && !invented.length) {
    console.log(`   ok — every key the console reads is served by the corpus.`);
    console.log("");
  }
}

console.log("─────────────────────────────────────────────────────────────────────────────");
console.log(`   UNPAINTABLE  ${unpaintable}   (read by app.js, never served — FAILS)`);
console.log(`   INVENTED     ${inventedTotal}   (served, never sent — FAILS)`);
console.log(`   DEAD PAYLOAD ${deadTotal}   (sent, read by nothing — reported only)`);
console.log("");

if (!unpaintable && !inventedTotal) {
  console.log(`PASS: across ${ENDPOINTS.length} endpoints, every key path the console READS is served by the preview corpus.`);
  process.exit(0);
}
console.log("FAIL(1): the corpus cannot paint every band the console renders.");
process.exit(1);
