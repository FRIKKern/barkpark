// __me_envelope_census.mjs — THE /v1/me ENVELOPE CENSUS over the preview corpus.
//
// Charter D478/D480/D481 (wave 43). The law this instrument enforces:
//
//     A CORPUS THAT MINTS A DIFFERENT ACCOUNT THAN THE SERVER MINTS
//     IS A GATE CERTIFYING A CONSOLE NOBODY WILL EVER RUN.
//
// The Console gate is a REQUIRED context on a protected main. Everything it
// certifies about how the console renders, it certifies against ONE fixture
// producer: `me()` in __preview__/scenarios.mjs, the single builder behind every
// logged-in scenario's GET /v1/me. Before wave 43 that producer emitted FOUR of
// the SIX top-level keys the server sends — no `teams`, no `team_authority` —
// so every rendered scenario took app.js's pre-wave-42 compatibility floors,
// the `grant` band had never been painted by any instrument, and the gate told
// every merge the console renders correctly for an account it had never once
// rendered.
//
// This census makes that class of lie reddable: it diffs the key paths the
// SERVER states against the key paths the CORPUS serves, and reports both
// directions by name.
//
//     MISSING  — a key path /v1/me states that no scenario serves. The corpus
//                renders an account the control plane cannot mint, so every
//                assertion downstream of that key is untested.
//     INVENTED — a key path the corpus serves that /v1/me does not state. The
//                corpus renders an account the control plane will never send,
//                so every assertion downstream of that key is fiction.
//
// ── WHY IT IS A RUNTIME CENSUS, NOT A SOURCE SCAN (charter D480) ────────────
//
// The obvious cheap form — parse `me()`'s object literal out of scenarios.mjs
// and diff its keys — is WRONG, and wrong in the direction that manufactures a
// finding. `user.platform_operator` does NOT appear in me()'s literal, but it
// is not missing: `operatorMe()` wraps me() and raises it, and the operator
// scenarios serve it. A source scan reports it as a hole; the corpus serves it.
//
// So both sides are taken from the thing itself. The corpus side calls the
// exported `route(name, "GET", "/v1/me", state)` over EVERY scenario and reads
// the body that actually comes back — which covers mock.js (the browser
// harness) and smoke.mjs (the render harness) in one pass, because both
// delegate to that same route() (scenarios.mjs is, in mock.js's own words, "the
// single source of truth"). The server side is parsed out of the `get "/v1/me"`
// clause's own response map in router.ex.
//
// ── UNION SEMANTICS, AND WHY ────────────────────────────────────────────────
//
// A key path counts as SERVED if ANY scenario serves it. That is not laxity: it
// is what "the corpus has rendered this" means. `user.platform_operator` is
// served by the operator scenarios and by no others, and that is correct — a
// per-scenario intersection would demand every fixture be an operator.
//
// ── OPAQUE NODES, AND THE ONE KIND THAT IS NOT ALLOWED TO BE ────────────────
//
// The server side is a tree, and a node has children only where router.ex spells
// a map literal (`%{...}`) for it. A value with no `%{` in it — `user.email`,
// `Accounts.two_factor_enabled?(user)` — states a scalar this census cannot see
// through, so it is censused as PRESENT and its subtree is not compared in
// either direction.
//
// `onboarding:` used to be counted in that bucket and it did not belong there.
// `onboarding: team && onboarding_json(Accounts.onboarding_status(team))` hides
// a five-key MAP, and `onboarding_json/1` is a `defp` in THIS file — the shape
// is right there. Treating it as opaque cost SEVEN key paths compared in
// NEITHER direction (MISSING vacuous because no sub-path was ever derived,
// INVENTED suppressed outright by `underOpaque`) while the report printed a
// clean `ok  onboarding` line and the gate printed PASS. That is the exact lie
// this instrument exists to make reddable, told by the instrument itself.
//
// So a BARE lowercase call — `foo_json(...)`, an unqualified local function of
// this module — is RESOLVED: its single clause is found in the same file, its
// map literal is walked by the same walkMap, and its keys join the census under
// the calling key's prefix. Refusal, never degradation: a bare local name that
// cannot be resolved to a one-clause helper opening on `%{` exits 2 naming the
// symbol and the file searched.
//
// The discriminator is SYNTACTIC and narrow, and it has to be. Five /v1/me
// values are legitimate scalar-returning REMOTE calls (`Accounts.*`, `Authz.*`,
// `Notifications.*`); "any unresolved call dies" would refuse on unmodified
// main. A DOTTED call is excluded BY CONSTRUCTION — not by an allowlist that
// would rot — because this census can only read one file and a remote callee
// lives in another. Bare Kernel calls (`is_nil/1`) are the one thing that looks
// local and is not, so KERNEL_BARE names them; that list is load-bearing, not
// decoration (drop `is_nil` and the census refuses on unmodified main at
// `user.confirmed`).
//
// HONEST RESIDUAL: moving `onboarding_json/1` into another module — making the
// call DOTTED — restores the blindness and greens. This census reads ONE file,
// so a remote helper is genuinely beyond it. The refuse rule is therefore
// dodgeable by relocating the helper, and nothing reds when it is. Filed:
// cch-w44-bl-me-census-module-file-map — give this census a module→file map,
// the shape __binding_census.mjs's CONTEXT_SOURCES already carries.
//
// ── NO COUNT LITERAL, EITHER SIDE ───────────────────────────────────────────
//
// Both sides are DERIVED sets and the gate is their symmetric difference. There
// is no expected total anywhere in this file — a count gate is fail-green (drop
// one key, add another, the count holds over a live regression) and a pinned
// expected-missing list would have to be edited by the same commit that fixes
// the hole, which is a gate that cannot lose.
//
// ── IT REFUSES RATHER THAN PASSING ──────────────────────────────────────────
//
// If the `get "/v1/me"` clause, its response map, or any key inside it cannot
// be parsed, this exits 2 and measures nothing. A parser that silently derives
// an EMPTY server-side set would green on every corpus, which is the worst
// failure a census can have: it would go quiet at exactly the moment the file
// it reads was restructured.
//
// USAGE
//   node cloud/priv/static/__me_envelope_census.mjs [<router.ex>]
//
// EXIT
//   0 — the corpus serves exactly what /v1/me states
//   1 — MISSING and/or INVENTED key paths (both named)
//   2 — refused to measure (router.ex unreadable / unparseable)

import fs from "node:fs";
import path from "node:path";
import { SCENARIO_NAMES, route } from "./__preview__/scenarios.mjs";

const here = path.dirname(new URL(import.meta.url).pathname);
const ROUTER = process.argv[2] || path.join(here, "../../lib/barkpark_cloud/web/router.ex");

function die2(lines) {
  console.log("── /v1/me ENVELOPE CENSUS ───────────────────────────────────────────────────");
  for (const l of lines) console.log(l);
  console.log("");
  console.log("REFUSED (2): the census will not report a result it could not measure.");
  process.exit(2);
}

// ── the server side ─────────────────────────────────────────────────────────
// Blank out Elixir comments and string bodies so brace/paren depth counting and
// `key:` matching see structure only. Length is preserved so every index into
// the blanked text is an index into the original.
function blank(src) {
  const out = src.split("");
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === "#") {
      while (i < src.length && src[i] !== "\n") { out[i] = " "; i++; }
    } else if (c === '"') {
      i++;
      while (i < src.length && src[i] !== '"') {
        if (src[i] === "\\") { out[i] = " "; i++; }
        if (i < src.length) { out[i] = " "; i++; }
      }
      i++;
    } else if (c === "?" && src[i + 1] === '"') {
      out[i + 1] = " ";
      i += 2;
    } else {
      i++;
    }
  }
  return out.join("");
}

// The balanced `%{ … }` region starting at `open` (the index of `{`).
function balanced(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return { start: open + 1, end: i }; }
  }
  return null;
}

// Split a map body at its TOP-LEVEL commas — the ones outside every nested
// map, list, tuple and call. Each segment carries the offset it starts at
// WITHIN the body, because a later `indexOf(segment)` would find the FIRST
// textual occurrence and could silently walk the wrong nested map: the one
// failure a census must never have is a confident wrong answer.
function topLevelSplit(text) {
  const parts = [];
  let depth = 0, from = 0;
  const push = (to) => {
    const slice = text.slice(from, to);
    if (slice.trim().length) parts.push({ text: slice, at: from });
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "{" || c === "[" || c === "(") depth++;
    else if (c === "}" || c === "]" || c === ")") depth--;
    else if (c === "," && depth === 0) { push(i); from = i + 1; }
  }
  push(text.length);
  return parts;
}

// Bare lowercase calls that are Kernel, not local — they LOOK like a local
// helper (no module qualifier) and are not one, so the resolver would hunt a
// `defp` that will never exist and refuse. Every entry is a scalar-returning
// Kernel function: none of them can hide a map, so skipping them claims
// nothing. This list is LOAD-BEARING, not decoration — `is_nil` is spelled in
// the /v1/me map today (`confirmed: not is_nil(user.confirmed_at)`) and
// removing it makes this census exit 2 on unmodified main. The others are here
// because they are the plausible next scalar Kernel call in a JSON map; a bare
// name that is neither Kernel nor resolvable REFUSES, which is the safe way to
// be wrong about this list.
const KERNEL_BARE = new Set(["is_nil", "length", "map_size", "byte_size"]);

// The bare lowercase calls inside a value — `foo_json(` — i.e. unqualified
// functions of THIS module. A DOTTED call (`Accounts.onboarding_status(`) is
// excluded BY CONSTRUCTION: the preceding `.` fails the boundary class. That
// exclusion is the whole reason this rule does not refuse on unmodified main,
// where five /v1/me values are legitimate scalar-returning remote calls.
function bareLocalCalls(value) {
  const names = [];
  const re = /(^|[^\w.])([a-z_][A-Za-z0-9_]*[?!]?)\s*\(/g;
  let m;
  while ((m = re.exec(value)) !== null) {
    const name = m[2];
    if (KERNEL_BARE.has(name)) continue;
    if (!names.includes(name)) names.push(name);
  }
  return names;
}

// Names currently being resolved, so a helper that (directly or through another
// helper) calls itself refuses instead of recursing forever.
const RESOLVING = new Set();

// Resolve a bare local call to the map literal its single clause returns.
// Refuses — never degrades back to "opaque" — because this census is on the
// hook for the subtree the moment it can see the helper at all.
function localHelperMap(blanked, name, self) {
  const searched = `${path.relative(process.cwd(), ROUTER)} (searched for \`defp ${name}(\`)`;
  if (RESOLVING.has(name)) {
    die2([
      `FAIL(2): \`${name}/1\`, reached from \`${self}\`, resolves through itself — this census cannot`,
      `         state a shape for a recursive builder.`,
      `         ${searched}`,
    ]);
  }
  // Two shapes count as a clause head, and BOTH must, or the count is a lie:
  // the paren'd form `defp foo(args)` (the only one we can walk) and the
  // paren-LESS form `defp foo, do: …` / `defp foo do`. Counting only the first
  // means a helper with one paren'd clause and one paren-less clause looks
  // SINGLE-clause, and this census would walk one of two and call it the shape
  // — the confident wrong answer its own header forbids. Paren-less heads are
  // counted for the arity check and are never walked: with >1 clause we refuse,
  // and with a lone paren-less clause `clauses` is empty and the "no clause"
  // arm below refuses too.
  const paren = new RegExp(`(^|\\n)\\s*defp?\\s+${name}\\s*\\(`, "g");
  const bare = new RegExp(`(^|\\n)\\s*defp?\\s+${name}\\s*(,|do\\b)`, "g");
  const clauses = [];
  let m;
  while ((m = paren.exec(blanked)) !== null) clauses.push(m.index + m[0].length - 1); // index of `(`
  let bareClauses = 0;
  while (bare.exec(blanked) !== null) bareClauses++;
  if (clauses.length + bareClauses > 1) {
    die2([
      `FAIL(2): \`${name}/…\` has ${clauses.length + bareClauses} clause heads in ${searched} and \`${self}\` could take`,
      `         any of them. This census will not pick one and call it the shape.`,
    ]);
  }
  if (!clauses.length) {
    die2([
      `FAIL(2): \`${self}\` is built by the bare local call \`${name}(...)\` and no walkable clause of it`,
      `         exists in ${searched}`,
      bareClauses
        ? `         (its only clause head takes no parens, so this census cannot read its arguments).`
        : `         .`,
      `         A bare (unqualified) call is a function of this module by construction, so it is`,
      `         resolvable in principle — reporting the subtree as opaque here would hide however`,
      `         many key paths it states behind a clean line.`,
    ]);
  }
  const open = clauses[0];
  let depth = 0, close = -1;
  for (let i = open; i < blanked.length; i++) {
    if (blanked[i] === "(") depth++;
    else if (blanked[i] === ")") { depth--; if (depth === 0) { close = i; break; } }
  }
  if (close === -1) die2([`FAIL(2): the head of \`${name}\` in ${searched} has unbalanced parens.`]);
  const nl = blanked.indexOf("\n", close);
  const headerTail = nl === -1 ? blanked.slice(close + 1) : blanked.slice(close + 1, nl);
  if (!/\bdo\s*$/.test(headerTail)) {
    die2([
      `FAIL(2): \`${name}\` in ${searched} is not a plain \`… do\`-block helper (its head continues past`,
      `         the clause line), so \`${self}\`'s shape cannot be read off it.`,
      `         The head, verbatim: ${headerTail.trim().slice(0, 120)}`,
    ]);
  }
  let i = nl + 1;
  while (i < blanked.length && /\s/.test(blanked[i])) i++;
  if (blanked.slice(i, i + 2) !== "%{") {
    die2([
      `FAIL(2): \`${name}\` in ${searched} does not open on a \`%{\` map literal, so this census cannot`,
      `         say what key paths \`${self}\` carries. It states the subtree or it states nothing.`,
    ]);
  }
  const nested = balanced(blanked, i + 1);
  if (!nested) die2([`FAIL(2): the map returned by \`${name}\` in ${searched} is unbalanced — refusing to guess its keys.`]);
  return nested;
}

// Walk a map body into key paths. `blanked` drives the structure, `raw` is read
// for nothing but nicer failure messages.
function walkMap(blanked, region, prefix, out, trail) {
  const body = blanked.slice(region.start, region.end);
  const segs = topLevelSplit(body);
  if (!segs.length) die2([`FAIL(2): the map at ${trail || "/v1/me"} parsed to ZERO keys — the response map's shape moved.`]);
  for (const segment of segs) {
    const seg = segment.text;
    const m = seg.match(/^\s*([a-z_][A-Za-z0-9_]*):\s*([\s\S]*)$/);
    if (!m) {
      die2([
        `FAIL(2): a segment of the ${trail || "/v1/me"} response map is not a \`key: value\` pair and this census`,
        `         cannot say what the server states there. The segment, verbatim:`,
        `             ${seg.trim().slice(0, 160)}`,
      ]);
    }
    const key = m[1];
    const value = m[2];
    const self = prefix + key;
    out.add(self);
    // A list of maps: `Enum.map(…, fn t -> %{…} end)`. The element shape is the
    // nested literal, and its paths are named `key[].field`.
    const isList = /\bEnum\.map\s*\(/.test(value);
    // Absolute offset of the first `%{` inside this value, if any.
    const rel = value.indexOf("%{");
    if (rel === -1) {
      // No literal here — but a BARE local call can still hide a whole map
      // (`onboarding: team && onboarding_json(...)`). Resolve it in this file
      // rather than answering "opaque" to a question this census can answer.
      const local = bareLocalCalls(value);
      if (!local.length) continue; // genuinely opaque: a remote call, a variable, a scalar
      if (local.length > 1) {
        die2([
          `FAIL(2): \`${self}\` is built by ${local.length} bare local calls (${local.join(", ")}) and this census`,
          `         cannot say which one states its shape.`,
        ]);
      }
      const name = local[0];
      const nested = localHelperMap(blanked, name, self);
      RESOLVING.add(name);
      walkMap(blanked, nested, self + (isList ? "[]." : "."), out, self);
      RESOLVING.delete(name);
      continue;
    }
    const absValueStart = region.start + segment.at + (seg.length - value.length);
    const nested = balanced(blanked, absValueStart + rel + 1);
    if (!nested) die2([`FAIL(2): the nested map under \`${self}\` is unbalanced — refusing to guess its keys.`]);
    walkMap(blanked, nested, self + (isList ? "[]." : "."), out, self);
  }
}

function serverKeyPaths() {
  let src;
  try {
    src = fs.readFileSync(ROUTER, "utf8");
  } catch (e) {
    die2([`FAIL(2): router.ex not readable at ${ROUTER} — the server side of this diff cannot be derived.`, `         ${e.message}`]);
  }
  const blanked = blank(src);
  // The clause header is located in the RAW text (blanking eats the path
  // literal), then confirmed against the blanked text at the same index —
  // blanking preserves length, so a hit whose first char survived blanking is
  // real code and a hit inside a comment is not.
  let clause = -1;
  for (let at = src.indexOf('get "/v1/me" do'); at !== -1; at = src.indexOf('get "/v1/me" do', at + 1)) {
    if (blanked[at] === "g") { clause = at; break; }
  }
  if (clause === -1) {
    die2([
      `FAIL(2): no \`get "/v1/me" do\` clause in ${ROUTER}.`,
      `         The route this census exists to mirror is gone or renamed. An EMPTY server-side`,
      `         set would green every corpus, so nothing is reported.`,
    ]);
  }
  const j = blanked.indexOf("json(conn, 200, %{", clause);
  if (j === -1) {
    die2([
      `FAIL(2): the \`get "/v1/me"\` clause has no \`json(conn, 200, %{\` response map.`,
      `         Its 200 body is built some other way now and this census cannot read it.`,
    ]);
  }
  const region = balanced(blanked, blanked.indexOf("{", j));
  if (!region) die2([`FAIL(2): the /v1/me response map is unbalanced — refusing to measure.`]);
  const out = new Set();
  walkMap(blanked, region, "", out, "");
  if (!out.size) die2([`FAIL(2): the /v1/me response map derived ZERO key paths.`]);
  return out;
}

// ── the corpus side ─────────────────────────────────────────────────────────
// Every key path a value carries. Arrays contribute `key[].field`, so a
// per-element shape is compared against the server's per-element shape.
function valuePaths(value, prefix, out) {
  if (Array.isArray(value)) {
    for (const el of value) valuePaths(el, prefix + "[]", out);
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const k of Object.keys(value)) {
    const self = prefix ? prefix + "." + k : k;
    out.add(self);
    valuePaths(value[k], self, out);
  }
}

function corpusKeyPaths() {
  const served = new Set();
  const byPath = new Map(); // key path → scenarios serving it (first few, for the report)
  let answered = 0;
  for (const name of SCENARIO_NAMES) {
    let res;
    try {
      res = route(name, "GET", "/v1/me", {});
    } catch (e) {
      die2([`FAIL(2): route("${name}", "GET", "/v1/me") threw — the corpus cannot be censused.`, `         ${e.message}`]);
    }
    // Only a 200 is an envelope. A logged-out scenario 401s and a meFault
    // scenario serves its fault on purpose; neither is a claim about shape.
    if (!res || res.status !== 200 || !res.body || typeof res.body !== "object") continue;
    answered++;
    const mine = new Set();
    valuePaths(res.body, "", mine);
    for (const p of mine) {
      served.add(p);
      if (!byPath.has(p)) byPath.set(p, []);
      byPath.get(p).push(name);
    }
  }
  if (!answered) {
    die2([
      `FAIL(2): NOT ONE of the ${SCENARIO_NAMES.length} scenarios answered GET /v1/me with a 200.`,
      `         An empty corpus side would report every server key as missing and every`,
      `         corpus key as absent — a result, not a measurement.`,
    ]);
  }
  return { served, byPath, answered };
}

// ── the diff ────────────────────────────────────────────────────────────────
// Server nodes with children are the only ones whose subtree is compared; an
// opaque node (a call, a scalar) makes no claim about what hangs beneath it,
// so neither does this census.
function isOpaque(serverPaths, p) {
  const stem = p + ".";
  const listStem = p + "[].";
  for (const s of serverPaths) if (s.startsWith(stem) || s.startsWith(listStem)) return false;
  return true;
}
function underOpaque(serverPaths, p) {
  const parts = p.split(".");
  for (let i = 1; i < parts.length; i++) {
    const ancestor = parts.slice(0, i).join(".").replace(/\[\]$/, "");
    if (serverPaths.has(ancestor) && isOpaque(serverPaths, ancestor)) return true;
  }
  return false;
}

const server = serverKeyPaths();
const { served, byPath, answered } = corpusKeyPaths();

// The corpus emits `teams[].id`-shaped paths for arrays; normalise the server's
// `teams[].id` the same way (walkMap already does). Both sides speak one dialect.
const missing = [...server].filter((p) => !served.has(p)).sort();
const invented = [...served].filter((p) => !server.has(p) && !underOpaque(server, p)).sort();

const pad = (s, n) => (s + " ".repeat(n)).slice(0, Math.max(n, s.length));

console.log("── /v1/me ENVELOPE CENSUS ───────────────────────────────────────────────────");
console.log(`   server  ${path.relative(process.cwd(), ROUTER)} — get "/v1/me" response map`);
console.log(`   corpus  __preview__/scenarios.mjs — route(name, "GET", "/v1/me") over ${SCENARIO_NAMES.length} scenarios, ${answered} answering 200`);
console.log("");
console.log(`   key paths STATED by the server : ${server.size}`);
console.log(`   key paths SERVED by the corpus : ${served.size} (union; a path counts if ANY scenario serves it)`);
console.log("");
for (const p of [...server].sort()) {
  const who = byPath.get(p) || [];
  const mark = who.length ? "ok  " : "MISS";
  const detail = who.length === answered
    ? "every answering scenario"
    : who.length
      ? `${who.length}/${answered} scenarios (e.g. ${who.slice(0, 3).join(", ")})`
      : "NO SCENARIO SERVES THIS";
  const tag = isOpaque(server, p) ? "" : "  ·";
  console.log(`   ${mark}  ${pad(p, 34)}${detail}${tag}`);
}
console.log("");

if (!missing.length && !invented.length) {
  console.log(`PASS: the preview corpus mints the account /v1/me mints — ${server.size} key paths, no MISSING, no INVENTED.`);
  process.exit(0);
}

if (missing.length) {
  console.log(`MISSING — /v1/me states these and NO scenario serves them (${missing.length}):`);
  for (const p of missing) console.log(`   ${p}`);
  console.log("");
  console.log("   Every console read of these key paths is currently certified by a gate that");
  console.log("   has never rendered them. Widen me() in __preview__/scenarios.mjs (ONE producer,");
  console.log("   every logged-in scenario) — not the individual scenarios.");
  console.log("");
}
if (invented.length) {
  console.log(`INVENTED — the corpus serves these and /v1/me does not state them (${invented.length}):`);
  for (const p of invented) console.log(`   ${p}  ← served by ${(byPath.get(p) || []).slice(0, 3).join(", ")}`);
  console.log("");
  console.log("   The corpus renders an account the control plane will never send, so anything");
  console.log("   asserted downstream of these is fiction. Either the fixture is wrong or the");
  console.log("   route stopped sending them and a console read is now dead.");
  console.log("");
}
console.log("FAIL(1): the corpus and the route disagree about what an account looks like.");
process.exit(1);
