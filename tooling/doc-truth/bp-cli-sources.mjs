// bp-cli-sources.mjs — the CLI's own vocabulary, read back out of the CLI.
//
// WHAT THIS PROVES, AND WHAT IT DOES NOT.
// It proves a printed `bp …` command PARSES: that every token on its command
// path is dispatched somewhere in the binary, and that every flag it passes is
// a flag that leaf actually reads. It NEVER claims the command SUCCEEDS — no
// server is contacted, no auth is resolved, no side effect is run. A command
// can parse perfectly and still 404, 403, or wipe the wrong dataset.
//
// It resolves against a UNION of four sources, because no single one of them
// knows the whole surface:
//
//   [A] manifest rows            docs/cli/fixtures/full-manifest.json
//                                — the server-declared noun/verb tree. Carries
//                                  `doc`, `task`, `workspace`, … Dropping A
//                                  manufactures false REDs across the repo for
//                                  every manifest-driven command.
//   [B] completionNouns          internal/cli/builtins.go
//                                — the built-in top-level nouns (`cloud`,
//                                  `login`, `vercel`, …). B knows `cloud` is a
//                                  noun; B canNOT know what follows it, which
//                                  is exactly the vacuous green this gate kills.
//   [C] parseHzArgs allowlists   internal/cli/*.go
//                                — a leaf's declared value/bool flag names.
//   [D] router dispatch          internal/cli/*.go `switch`/`case "x":`,
//                                  `if verb == "x"` intercepts, AND the verb
//                                  TABLES a dispatcher looks up (siteVerbMatrix)
//                                — the DEPTH. `bp cloud barkpark ls` is green
//                                  under A+B+C (B has `cloud`, and nothing in
//                                  A/B/C can adjudicate the token after it);
//                                  only D's cloud switch can say `barkpark` is
//                                  not a cloud command. D is not optional.
//                                  D reads dispatch by SHAPE, not by spelling:
//                                  a `case` arm and a table row are the same
//                                  fact, and keying on one of them makes every
//                                  refactor of the other a false red.
//   [E] `"--flag"` literals      internal/cli/*.go (file-scoped)
//                                — the micro-source for hand-rolled parsers
//                                  (`case "--site":`, `flagDevice = "--device"`)
//                                  that declare no parseHzArgs allowlist. Without
//                                  E, `bp login --device` and every
//                                  `bp vercel quick-setup` flag is UNPROVEN.
//
// LAWS
//   · A token that resolves in NO source is a FAILURE, never a skip.
//   · A source that cannot be loaded is a FAILURE — a gate that silently drops
//     a source is a gate that manufactures both false greens and false reds.
//   · Absence may be DECLARED, never assumed (see the caller's --offline).
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

export const DEFAULT_MANIFEST = "docs/cli/fixtures/full-manifest.json";
const CLI_DIR = "internal/cli";
const BUILTINS = "internal/cli/builtins.go";

// ── source A: manifest rows ─────────────────────────────────────────────────

function loadManifest(root, relPath) {
  const abs = join(root, relPath);
  if (!existsSync(abs)) return { ok: false, why: `manifest not found at ${relPath}` };
  let raw;
  try {
    raw = JSON.parse(readFileSync(abs, "utf8"));
  } catch (e) {
    return { ok: false, why: `manifest at ${relPath} is not valid JSON: ${e.message}` };
  }
  const nouns = new Set((raw.nouns || []).map((n) => n.name));
  const verbs = new Map(); // noun -> Set(verb)
  const flags = new Map(); // "noun.verb" -> Set("--flag")
  // The manifest ships as ONE line of JSON, so a ":<line>" would be a fiction.
  // The honest authority for [A] is the ROW: `<path>#<row id>`.
  const at = new Map();    // "noun" | "noun.verb" -> "<relPath>#<row>"
  for (const nd of raw.nouns || []) if (nd.name) at.set(nd.name, `${relPath}#nouns[${nd.name}]`);
  for (const c of raw.commands || []) {
    if (!c.noun || !c.verb) continue;
    nouns.add(c.noun);
    if (!verbs.has(c.noun)) verbs.set(c.noun, new Set());
    verbs.get(c.noun).add(c.verb);
    const f = new Set();
    for (const fl of c.flags || []) if (fl.name) f.add("--" + fl.name);
    flags.set(`${c.noun}.${c.verb}`, f);
    at.set(`${c.noun}.${c.verb}`, `${relPath}#${c.id || `${c.noun}.${c.verb}`}`);
    if (!at.has(c.noun)) at.set(c.noun, `${relPath}#nouns[${c.noun}]`);
  }
  if (nouns.size === 0) return { ok: false, why: `manifest at ${relPath} declares no nouns` };
  return { ok: true, origin: relPath, nouns, verbs, flags, at, rows: (raw.commands || []).length };
}

// ── the Go scan (sources B, C, D, E + usage synopses) ───────────────────────

function goFiles(root) {
  const dir = join(root, CLI_DIR);
  const out = [];
  const walk = (d) => {
    let entries;
    try { entries = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".go") && !e.name.endsWith("_test.go")) out.push(p);
    }
  };
  if (existsSync(dir) && statSync(dir).isDirectory()) walk(dir);
  return out;
}

const CASE_RE = /^\s*case\s+((?:"[^"]*"\s*,\s*)*"[^"]*")\s*:/;
const FUNC_RE = /^func\s+(?:\([^)]*\)\s*)?(\w+)\s*\(/;
const RETURN_RUN_RE = /return\s+(run[A-Z]\w*)\s*\(/;
// `==` and `!=` are the SAME declaration of vocabulary. A guard written as a
// refusal — `if args[0] != "schema" { usage; return }` in make_cmd.go — names
// the one token this leaf accepts just as literally as `case "schema":` would,
// and keying only on `==` made `bp make schema <name>` UNRESOLVED on a doc line
// that was never wrong. Either operator is a branch ON that token: the parser
// demonstrably knows the word. (It cannot manufacture a vacuous green: the
// token is donated only to the node that already sits at that dispatch point.)
const VERB_EQ_RE = /\b(?:verb|resource|args\[0\]|rest\[0\]|sub|tail\[0\])\s*(?:==|!=)\s*"([\w][\w.-]*)"/g;
const FLAG_LITERAL_RE = /"(--[a-z0-9][a-z0-9-]*)"/g;
const HZ_RE = /parseHzArgs\(\s*[^,]+,\s*\[\]string\{([^}]*)\}\s*,\s*\[\]string\{([^}]*)\}/;
const STRING_RE = /"((?:[^"\\]|\\.)*)"/g;

// A node is one dispatch point: either a whole function, or a `case "<tok>":`
// block inside one (where `if verb == "x"` intercepts live — cli.go's task noun
// is exactly that shape, and attributing those to the whole function would make
// `bp <anything> create` resolvable).
function newNode(id, file) {
  return { id, file, cases: new Set(), edges: new Map(), caseAt: new Map(), fn: null };
}

// ── [D2] VERB TABLES — dispatch that is DATA, not syntax ────────────────────
//
// WHY THIS EXISTS. A `switch`/`case "x":` is one SPELLING of dispatch, not the
// thing itself. When internal/cli replaced runCloudSite()'s verb switch with a
// lookup table (siteVerbMatrix, #18555), a case-scraping reader saw "no verbs
// at all" and reported every correct `bp cloud site …` line in templates/ as
// UNRESOLVED — a false red on docs that had not changed. The fix is NOT to
// grep for a second spelling (`Verb: "x"` alongside `case "x":`): that is the
// same fault one refactor later. The fix is to read the TABLE — the artifact
// the binary itself resolves against — and to reach it the way the binary
// does, by following the call that hands a user-typed token into it.
//
// WHAT IS READ, all from the table's own vocabulary:
//   · `Verb:`/`Name:`/`Cmd:` — the canonical token
//   · `Aliases: []string{…}`  — accepted synonyms (`bp cloud site build`)
//   · `Scope:  …SpawnerOnly`  — a verb offered at ONE spelling; at the other
//                               spelling it stays UNRESOLVED
//   · handler fields (`Impl:`, `Fleet:`, `Spawner:`) — which spelling reaches
//     which func, so flags still resolve against the real leaf ([C]/[E])
//
// A table is attached to a dispatcher only through a call chain that carries a
// user token (`args[0]`, `verb`, …), so a function that merely RENDERS the
// table (runSiteMatrix) never donates its verbs to anything.

const TABLE_DECL_RE = /(?:var\s+)?([A-Za-z_]\w*)\s*(?::?=)\s*\[\]([A-Za-z_]\w*)\s*\{/g;
const VERB_FIELD_RE = /\b(?:Verb|Name|Cmd|Command):\s*"([^"]+)"/;
const ALIASES_FIELD_RE = /\b(?:Aliases|Alias|Synonyms):\s*\[\]string\{([^}]*)\}/;
const SCOPE_FIELD_RE = /\b(?:Scope|Only|Availability):\s*([A-Za-z_]\w*)/;
const HANDLER_FIELD_RE = /\b([A-Z]\w*):\s*(?:(\w+)\(\s*(\w+)\s*\)|(\w+))\s*,/g;
const SCOPE_ONLY_RE = /([A-Z][a-z0-9]+)Only$/;
// A row that names its own NOUN is not dispatched by its verb alone: the
// dispatch token is the PAIR (`task create`). nounBuiltins is that shape, and
// donating its bare verbs to a node would make `bp <anything> create`
// resolvable — the exact vacuous green source D exists to kill.
const QUALIFIER_FIELD_RE = /\b(?:Noun|Group|Parent|Namespace|Family):\s*"([^"]+)"/;
// the tokens a dispatcher's caller uses for "the verb the USER typed"
const USER_TOKEN_RE = /\b(?:args|rest|tail|a|argv)\[0\]|\b(?:verb|sub|subcommand)\b/;
const HANDLER_SKIP = new Set(["Verb", "Name", "Cmd", "Command", "Aliases", "Alias",
  "Synonyms", "Scope", "Only", "Availability", "Summary", "KindNote", "Help", "Doc",
  "Usage", "Desc", "Description"]);

// Walk from the `{` at `open` to its matching `}`, skipping string/rune/comment
// bodies. Returns the index just past the closing brace, or -1.
function matchBrace(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "`" || c === "'") {
      const q = c;
      i++;
      while (i < text.length && text[i] !== q) { if (q !== "`" && text[i] === "\\") i++; i++; }
      continue;
    }
    if (c === "/" && text[i + 1] === "/") { while (i < text.length && text[i] !== "\n") i++; continue; }
    if (c === "/" && text[i + 1] === "*") { i = text.indexOf("*/", i); if (i < 0) return -1; i++; continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return i + 1; }
  }
  return -1;
}

// The top-level `{ … }` elements of a composite-literal body.
function literalElements(text, bodyStart, bodyEnd) {
  const out = [];
  let depth = 0, elStart = -1;
  for (let i = bodyStart; i < bodyEnd; i++) {
    const c = text[i];
    if (c === '"' || c === "`" || c === "'") {
      const q = c;
      i++;
      while (i < bodyEnd && text[i] !== q) { if (q !== "`" && text[i] === "\\") i++; i++; }
      continue;
    }
    if (c === "/" && text[i + 1] === "/") { while (i < bodyEnd && text[i] !== "\n") i++; continue; }
    if (c === "{") { if (depth === 0) elStart = i; depth++; }
    else if (c === "}") { depth--; if (depth === 0 && elStart >= 0) { out.push({ start: elStart, text: text.slice(elStart, i + 1) }); elStart = -1; } }
  }
  return out;
}

// One table row, reduced to what dispatch needs.
function parseTableEntry(elText) {
  const vm = elText.match(VERB_FIELD_RE);
  if (!vm) return null;
  const qm = elText.match(QUALIFIER_FIELD_RE);
  if (qm) {
    // [D3] A noun-qualified row dispatches the PAIR, never the bare verb. Its
    // verbs must still NOT be donated to a node (that is the vacuous green
    // `bp <anything> create` this source exists to kill) — but dropping the row
    // entirely made a REAL front door invisible: `bp task create` is dispatched
    // from nounBuiltins and was scored UNRESOLVED on three true doc lines. So
    // the row is kept, keyed by its pair, and adjudicates only `<noun> <verb>`.
    const off = elText.indexOf(`"${vm[1]}"`);
    // The row's own handler names the LEAF, so this pair's flags still resolve
    // against the real function ([C]/[E]) instead of falling to UNPROVEN. A
    // registry row wraps its leaf in a func literal (`Run: func(…) int { return
    // runTaskCreate(…) }`), which HANDLER_FIELD_RE cannot see, so read the call.
    const lm = elText.match(/\b(run[A-Z]\w*)\s*\(/);
    return { qualified: true, noun: qm[1], verb: vm[1], verbOff: off >= 0 ? off : 0, leaf: lm ? lm[1] : null };
  }
  const names = [vm[1]];
  const am = elText.match(ALIASES_FIELD_RE);
  if (am) for (const s of am[1].matchAll(/"([^"]+)"/g)) names.push(s[1]);
  // Each NAME is cited at the line that literally spells it — the row's opening
  // brace declares nothing, and the citation read-back re-opens the file and
  // demands the token be there.
  const nameOff = new Map();
  for (const n of names) {
    const off = elText.indexOf(`"${n}"`);
    if (off >= 0) nameOff.set(n, off);
  }
  const sm = elText.match(SCOPE_FIELD_RE);
  const scopeOnly = sm ? (sm[1].match(SCOPE_ONLY_RE) || [])[1] || null : null;
  // handler fields: `Impl: fleetAdapter(runSitesList),` / `Spawner: runCloudSiteCreate,`
  const handlers = new Map();   // field name -> leaf func name
  for (const m of elText.matchAll(HANDLER_FIELD_RE)) {
    const field = m[1];
    if (HANDLER_SKIP.has(field)) continue;
    // an adapter call donates its ARGUMENT as the leaf (fleetAdapter(runSitesEnv))
    const fn = m[3] || m[4];
    if (!fn || /^(?:true|false|nil)$/.test(fn)) continue;
    handlers.set(field, fn);
  }
  return { names, nameOff, scopeOnly, handlers };
}

// Which verbs of `table` a call with these identifier arguments can reach, and
// through which leaf. `ctx` is the bare identifiers at the call site — the
// spelling constant (`siteSpellingSpawner`) is what selects a split verb's door.
function reachableVerbs(table, ctx) {
  const lowered = ctx.map((s) => s.toLowerCase());
  const namesField = (field) => lowered.some((id) => id.endsWith(field.toLowerCase()));
  // DOOR FIELDS are derived from the table's own shape, not from a name list:
  // a field that shares a row with another handler field is a door (the
  // spelling picks one of them). A field that is ever a row's ONLY handler is
  // unconditional — every caller reaches it. In siteVerbMatrix that makes
  // {Fleet, Spawner} doors and Impl unconditional, which is exactly what
  // dispatchSiteVerb does at runtime.
  const doorFields = new Set();
  for (const e of table.entries) {
    if (e.handlers.size > 1) for (const f of e.handlers.keys()) doorFields.add(f);
  }
  for (const e of table.entries) {
    if (e.handlers.size === 1) doorFields.delete([...e.handlers.keys()][0]);
  }
  const out = [];
  for (const e of table.entries) {
    // a `…Only` scope names the ONE door this verb is offered at
    if (e.scopeOnly && doorFields.size && !namesField(e.scopeOnly)) continue;
    let leaf = null;
    if (e.handlers.size) {
      const uncond = [...e.handlers.entries()].find(([f]) => !doorFields.has(f));
      const named = [...e.handlers.entries()].find(([f]) => doorFields.has(f) && namesField(f));
      if (uncond) leaf = uncond[1];
      else if (named) leaf = named[1];
      else continue;   // every handler is a door and the caller named none
    }
    out.push({ names: e.names, at: e.at, leaf });
  }
  return out;
}

// Find every verb table in the CLI sources.
//
// Returns BOTH kinds of registry the CLI writes as a `[]T{…}` literal:
//   · tables — bare-verb tables, dispatched by the verb alone. Attached to the
//     functions that hand a user token into them (attachVerbTables).
//   · pairs  — [D3] NOUN-QUALIFIED registries (nounBuiltins), where the
//     dispatch token is the PAIR `<noun> <verb>`. These are never attached to a
//     node; they adjudicate the pair and nothing else.
function scanVerbTables(texts) {
  const tables = new Map();   // var name -> {name, file, entries}
  const pairs = new Map();    // noun -> Map(verb -> "file:line")
  for (const [rel, text] of texts) {
    TABLE_DECL_RE.lastIndex = 0;
    let m;
    while ((m = TABLE_DECL_RE.exec(text)) !== null) {
      const varName = m[1];
      const open = text.indexOf("{", m.index + m[0].length - 1);
      const end = matchBrace(text, open);
      if (end < 0) continue;
      const entries = [];
      let qualified = false;
      for (const el of literalElements(text, open + 1, end - 1)) {
        const e = parseTableEntry(el.text);
        if (!e) continue;
        const lineOf = (off) => text.slice(0, el.start + off).split("\n").length;
        if (e.qualified) {
          // a noun-qualified row: record the PAIR, donate no bare verb
          qualified = true;
          if (!pairs.has(e.noun)) pairs.set(e.noun, new Map());
          const at = `${rel}:${lineOf(e.verbOff)}`;
          if (!pairs.get(e.noun).has(e.verb)) pairs.get(e.noun).set(e.verb, { at, leaf: e.leaf });
          continue;
        }
        e.at = new Map();
        for (const n of e.names) e.at.set(n, `${rel}:${lineOf(e.nameOff.get(n) ?? 0)}`);
        entries.push(e);
      }
      if (qualified) { TABLE_DECL_RE.lastIndex = end; continue; }
      // one row is a struct literal, not a dispatch table
      if (entries.length < 2) continue;
      const prev = tables.get(varName);
      tables.set(varName, { name: varName, file: rel, entries: prev ? prev.entries.concat(entries) : entries });
      TABLE_DECL_RE.lastIndex = end;
    }
  }
  return { tables, pairs };
}

// Attach each verb table to every function that hands a USER-TYPED token into
// it, directly or through a lookup helper. Reaching the table any other way
// (rendering it, counting it) donates nothing — that is what keeps a help
// printer from making every verb resolvable everywhere.
function attachVerbTables({ texts, fnBodies, funcFile, nodeFor }) {
  const { tables, pairs } = scanVerbTables(texts);
  if (tables.size === 0) return { tables, pairs };

  // level 0 — functions that RANGE a table
  const provides = new Map();   // func -> Set(table var)
  const addProvide = (fn, v) => {
    if (!provides.has(fn)) provides.set(fn, new Set());
    provides.get(fn).add(v);
  };
  for (const [fn, body] of fnBodies) {
    for (const v of tables.keys()) {
      if (new RegExp(`\\brange\\s+${v}\\b`).test(body) || new RegExp(`\\b${v}\\s*\\[`).test(body)) addProvide(fn, v);
    }
  }

  // levels 1..n — a caller that passes the user's token into a provider is
  // itself a dispatcher for that provider's tables. Three rounds cover
  // runCloudSite → dispatchSiteVerb → lookupSiteVerb and leave room for one
  // more hop; the set only grows, so the loop is monotone and terminating.
  const attachments = [];       // {fn, table, ctx}
  for (let round = 0; round < 4; round++) {
    let grew = false;
    for (const [fn, body] of fnBodies) {
      for (const [callee, vars] of [...provides]) {
        if (callee === fn) continue;
        const callRe = new RegExp(`\\b${callee}\\s*\\(([^()]*(?:\\([^()]*\\)[^()]*)*)\\)`, "g");
        let c;
        while ((c = callRe.exec(body)) !== null) {
          const argList = c[1];
          if (!USER_TOKEN_RE.test(argList)) continue;
          const ctx = [...argList.matchAll(/[A-Za-z_]\w*/g)].map((x) => x[0]);
          for (const v of vars) {
            if (!(provides.get(fn) || new Set()).has(v)) { addProvide(fn, v); grew = true; }
            attachments.push({ fn, table: tables.get(v), ctx });
          }
        }
      }
    }
    if (!grew) break;
  }

  for (const { fn, table, ctx } of attachments) {
    const node = nodeFor(fn, funcFile.get(fn) || table.file);
    for (const row of reachableVerbs(table, ctx)) {
      for (const name of row.names) {
        if (node.cases.has(name)) continue;   // a real `case` arm already said so
        node.cases.add(name);
        node.caseAt.set(name, row.at.get(name));
        if (row.leaf) node.edges.set(name, row.leaf);
      }
    }
  }
  return { tables, pairs };
}

function scanGo(root) {
  const files = goFiles(root);
  if (files.length === 0) return { ok: false, why: `no Go sources under ${CLI_DIR}` };

  const nodes = new Map();          // node id -> node
  const funcFile = new Map();       // func name -> repo-relative file
  const hz = new Map();             // func name -> Set("--flag")   [C]
  const hzAt = new Map();           // func name -> "file:line" of its parseHzArgs
  const fileFlags = new Map();      // repo-relative file -> Set("--flag")  [E]
  const flagAt = new Map();         // file -> Map("--flag" -> "file:line")  [E]
  let nounsAt = BUILTINS;           // "file:line" of `var completionNouns`
  let globalsAt = BUILTINS;         // "file:line" of `var completionGlobals`
  const synopses = [];              // {path:[tok], required:Set, all:Set}
  let completionNouns = null;       // [B]
  let completionGlobals = new Set();
  let rootFn = null;
  const texts = new Map();          // repo-relative file -> source text
  const fnBodies = new Map();       // func name -> its body text  [D2]

  const nodeFor = (id, file) => {
    if (!nodes.has(id)) nodes.set(id, newNode(id, file));
    return nodes.get(id);
  };

  for (const abs of files) {
    const rel = relative(root, abs);
    const text = readFileSync(abs, "utf8");
    texts.set(rel, text);
    const lines = text.split("\n");

    // [E] every `--flag` string literal in the file, file-scoped. Hand-rolled
    // parsers spell their flags as `case "--site":` or `flagDevice = "--device"`;
    // both are the same declaration of vocabulary.
    const eSet = fileFlags.get(rel) || new Set();
    const eAt = flagAt.get(rel) || new Map();
    for (const m of text.matchAll(FLAG_LITERAL_RE)) {
      eSet.add(m[1]);
      // first spelling wins — the line where this file DECLARES the flag
      if (!eAt.has(m[1])) {
        eAt.set(m[1], `${rel}:${text.slice(0, m.index).split("\n").length}`);
      }
    }
    fileFlags.set(rel, eSet);
    flagAt.set(rel, eAt);

    // [B] the completion noun/global lists (builtins.go).
    if (rel === BUILTINS) {
      const nb = text.match(/var\s+completionNouns\s*=\s*\[\]string\{([\s\S]*?)\}/);
      if (nb) {
        completionNouns = [...nb[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
        nounsAt = `${rel}:${text.slice(0, nb.index).split("\n").length}`;
      }
      const gb = text.match(/var\s+completionGlobals\s*=\s*\[\]string\{([\s\S]*?)\}/);
      if (gb) {
        for (const m of gb[1].matchAll(/"([^"]+)"/g)) completionGlobals.add(m[1]);
        globalsAt = `${rel}:${text.slice(0, gb.index).split("\n").length}`;
      }
    }

    let fn = null;
    let caseNodeId = null;    // the `case "x":` block we are inside, if any
    let fnBody = [];
    const flushFn = () => {
      if (!fn) return;
      const joined = fnBody.join("\n");
      const m = joined.match(HZ_RE);
      if (m) {
        const set = hz.get(fn) || new Set();
        for (const g of [m[1], m[2]]) for (const s of g.matchAll(/"([^"]+)"/g)) set.add("--" + s[1]);
        hz.set(fn, set);
      }
      if (/switch\s+noun\s*\{/.test(joined)) rootFn = fn;
      fnBodies.set(fn, (fnBodies.get(fn) || "") + "\n" + joined);
      fnBody = [];
    };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const fm = line.match(FUNC_RE);
      if (fm) {
        flushFn();
        fn = fm[1];
        caseNodeId = null;
        funcFile.set(fn, rel);
        nodeFor(fn, rel);
        continue;
      }
      if (!fn) {
        // package-level usage synopses still count.
        collectSynopses(line, synopses);
        continue;
      }
      fnBody.push(line);
      if (!hzAt.has(fn) && line.includes("parseHzArgs(")) hzAt.set(fn, `${rel}:${i + 1}`);
      collectSynopses(line, synopses);

      const cm = line.match(CASE_RE);
      if (cm) {
        const toks = [...cm[1].matchAll(/"([^"]*)"/g)].map((m) => m[1]);
        const isFlagCase = toks.every((t) => t.startsWith("-"));
        if (!isFlagCase) {
          const node = nodeFor(fn, rel);
          for (const t of toks) { node.cases.add(t); node.caseAt.set(t, `${rel}:${i + 1}`); }
          // an edge is a `return runX(` within the case body
          let callee = null;
          for (let j = i + 1; j < Math.min(lines.length, i + 9); j++) {
            if (CASE_RE.test(lines[j])) break;
            const rm = lines[j].match(RETURN_RUN_RE);
            if (rm) { callee = rm[1]; break; }
          }
          if (callee) for (const t of toks) node.edges.set(t, callee);
          // the case block becomes its own node for `if verb == "x"` intercepts
          caseNodeId = `${fn}::${toks[0]}`;
          nodeFor(caseNodeId, rel);
        }
        continue;
      }

      // `if verb == "x"` / `args[0] == "x"` intercepts — dispatch that never
      // reaches a switch. Attributed to the enclosing case block when there is
      // one, else to the function.
      for (const m of line.matchAll(VERB_EQ_RE)) {
        const tok = m[1];
        const node = nodeFor(caseNodeId || fn, rel);
        node.cases.add(tok);
        node.caseAt.set(tok, `${rel}:${i + 1}`);
        for (let j = i; j < Math.min(lines.length, i + 5); j++) {
          const rm = lines[j].match(RETURN_RUN_RE);
          if (rm) { node.edges.set(tok, rm[1]); break; }
        }
      }
    }
    flushFn();
  }

  const { pairs } = attachVerbTables({ texts, fnBodies, funcFile, nodeFor });

  if (!completionNouns || completionNouns.length === 0) {
    return { ok: false, why: `completionNouns not found in ${BUILTINS}` };
  }
  if (!rootFn) return { ok: false, why: "top-level `switch noun` dispatch not found in internal/cli" };
  // [D3] POSITIVE CONTROL. An absence claim needs one: if the noun-qualified
  // registry read silently yielded nothing — the file emptied, renamed,
  // unreadable, or its field spelling refactored out from under
  // QUALIFIER_FIELD_RE — then every `<noun> <verb>` built-in would go back to
  // being invisible and this gate would RED true doc lines while reporting a
  // clean load. A source that cannot be read is a FAILURE, never a skip, so
  // the read REFUSES instead of answering "no pairs". The predicate is the
  // SHAPE (any `[]T{…}` row carrying both a noun field and a verb field), not
  // a filename: renaming noun_builtins.go breaks nothing, emptying it reds.
  if (pairs.size === 0) {
    return {
      ok: false,
      why: "no noun-qualified verb registry found under " + CLI_DIR +
        " — source D3 cannot adjudicate any `<noun> <verb>` built-in " +
        "(expected `[]T{ {Noun: \"…\", Verb: \"…\"}, … }`, e.g. nounBuiltins)",
    };
  }
  return {
    ok: true, nodes, funcFile, hz, hzAt, fileFlags, flagAt, nounsAt, globalsAt, synopses,
    completionNouns: new Set(completionNouns), completionGlobals, rootFn, pairs,
  };
}

// A usage synopsis is any Go string literal that spells a `bp …` invocation.
// Both `const usage = "bp cloud site create --name <n> …"` and a help printer's
// `p("usage: bp vercel quick-setup --site <slug> …")` declare the same thing.
function collectSynopses(line, out) {
  for (const m of line.matchAll(STRING_RE)) {
    // A help printer aligns its ALTERNATIVE spellings with leading whitespace
    // ("       bp vercel quick-setup --static <path>"). Dropping those on a
    // leading-anchor match leaves ONE synopsis standing, and a single synopsis
    // makes its own flags look universally required — which reds every doc that
    // prints the other legitimate form.
    // A CONCATENATION STUB — `"bp login --email " + email`, `"...--provider " + p`
    // — is a hint template, NOT an authoritative usage synopsis. Its trailing
    // whitespace is the runtime-value seam. Read as a synopsis it marks its
    // dangling flag universally required (`bp login` then reds a valid
    // `--device`-only invocation on a phantom "missing --email"). A real synopsis
    // literal is authored complete, never with a trailing space, so drop those.
    if (/\s$/.test(m[1])) continue;
    const s = m[1].replace(/^\s+/, "");
    if (!/^(usage:\s*)?(bp|barkpark)\s+[a-z]/.test(s)) continue;
    const body = s.replace(/^usage:\s*/, "").replace(/^(bp|barkpark)\s+/, "");
    const toks = body.split(/\s+/);
    const path = [];
    for (const t of toks) {
      if (t.startsWith("-") || t.startsWith("[") || t.startsWith("<") || t.startsWith("(")) break;
      if (!/^[a-z][\w-]*$/.test(t)) break;
      path.push(t);
    }
    if (path.length === 0) continue;
    const { depth0, all } = flagsByDepth(body);
    if (all.size === 0) continue;
    out.push({ path, required: depth0, all });
  }
}

// Flags split by BRACKET DEPTH. `[--framework astro]` is shown as optional, so
// its flag is neither required by a synopsis nor supplied by a doc line — the
// depth is the only thing that distinguishes the two, and a depth-blind scan
// reads every usage synopsis as a fully-flagged invocation.
export function flagsByDepth(text) {
  const depth0 = new Set();
  const all = new Set();
  let depth = 0;
  for (const tok of tokenize(text)) {
    if (tok === "[" || tok === "(") { depth++; continue; }
    if (tok === "]" || tok === ")") { depth = Math.max(0, depth - 1); continue; }
    const lead = (tok.match(/^\[+/) || [""])[0].length;
    const trail = (tok.match(/\]+$/) || [""])[0].length;
    const bare = tok.replace(/^[[(]+/, "").replace(/[\])]+$/, "");
    const eff = depth + lead;
    if (/^--?[a-zA-Z]/.test(bare)) {
      const name = bare.split("=")[0];
      all.add(name);
      if (eff === 0) depth0.add(name);
    }
    depth = Math.max(0, depth + lead - trail);
  }
  return { depth0, all };
}

function tokenize(text) {
  return text.split(/\s+/).filter(Boolean);
}

// ── loading ─────────────────────────────────────────────────────────────────

// Load every source. `offline` DECLARES source A absent rather than pretending
// it was there: the caller must print that declaration, and callers outside the
// templates/** scope are refused it entirely.
export function loadBpSources({ root = REPO_ROOT, offline = false, manifestPath = DEFAULT_MANIFEST } = {}) {
  const absent = [];
  const errors = [];
  let A = null;
  if (offline) {
    absent.push("A");
  } else {
    const a = loadManifest(root, manifestPath);
    if (!a.ok) errors.push(`SOURCE A UNAVAILABLE: ${a.why}`);
    else A = a;
  }
  const go = scanGo(root);
  if (!go.ok) errors.push(`SOURCES B/C/D/E UNAVAILABLE: ${go.why}`);

  return {
    ok: errors.length === 0,
    errors,
    absent,
    root,
    A,
    B: go.ok ? go.completionNouns : null,
    C: go.ok ? go.hz : null,
    Cat: go.ok ? go.hzAt : new Map(),
    D: go.ok ? { nodes: go.nodes, funcFile: go.funcFile, rootFn: go.rootFn, pairs: go.pairs } : null,
    E: go.ok ? go.fileFlags : null,
    Eat: go.ok ? go.flagAt : new Map(),
    Bat: go.ok ? go.nounsAt : BUILTINS,
    Gat: go.ok ? go.globalsAt : BUILTINS,
    globals: go.ok ? go.completionGlobals : new Set(),
    synopses: go.ok ? go.synopses : [],
    counts: {
      A: A ? A.rows : 0,
      B: go.ok ? go.completionNouns.size : 0,
      C: go.ok ? go.hz.size : 0,
      D: go.ok ? go.nodes.size : 0,
      D3: go.ok ? [...go.pairs.values()].reduce((n, m) => n + m.size, 0) : 0,
      E: go.ok ? [...go.fileFlags.values()].reduce((n, s) => n + s.size, 0) : 0,
    },
    origins: {
      A: offline ? "(declared absent)" : manifestPath,
      B: BUILTINS,
      C: `${CLI_DIR}/**.go parseHzArgs allowlists`,
      D: `${CLI_DIR}/**.go switch/case + verb==/!= intercepts + verb tables + noun-qualified built-in registry`,
      E: `${CLI_DIR}/**.go "--flag" literals`,
    },
  };
}

// ── command-line splitting ──────────────────────────────────────────────────

// Turn a printed line into argv-ish tokens: drop a `$ ` prompt, drop a trailing
// shell comment, keep bracket structure (the depth check needs it).
export function splitCommandLine(raw) {
  let s = String(raw).trim().replace(/^\$\s+/, "");
  // strip a trailing comment that is not inside quotes
  let out = "", q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { out += c; if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { q = c; out += c; continue; }
    if (c === "#" && (i === 0 || /\s/.test(s[i - 1]))) break;
    out += c;
  }
  s = out.trim();
  // a pipeline/chain: only the leading command is ours
  s = s.split(/\s(?:\|\||&&|\|)\s/)[0].trim();
  return { text: s, tokens: tokenize(s) };
}

const PLACEHOLDER_RE = /^[<{$"'(]|[>}…]$|^\.\.\.$|^\.\.\.\S|^…/;
export function isPlaceholder(tok) {
  const t = tok.replace(/^[[(]+/, "").replace(/[\])]+$/, "");
  if (t === "") return true;
  return PLACEHOLDER_RE.test(t) || /^[A-Z0-9_]+=/.test(t) || t.includes("<") || t.includes("$");
}
function isFlag(tok) {
  const t = tok.replace(/^[[(]+/, "");
  return /^--?[a-zA-Z]/.test(t);
}

// ── resolution ──────────────────────────────────────────────────────────────

export const PROVEN = "proven";
export const UNPROVEN = "unproven";
export const UNRESOLVED = "unresolved";
// A pure grammar diagram (`bp [global flags] <noun> <verb> [args] [command
// flags]`) prints no literal command at all — scoring it PROVEN/UNPROVEN would
// manufacture a pass over nothing, scoring it UNRESOLVED would manufacture a
// red on prose that is documenting the grammar, not invoking it. It is its own
// verdict: reported, never a pass, never counted as a parse failure.
export const NOT_A_COMMAND = "not-a-command";

// A "/"-alternation lists VERBS for one noun (`get/ls/query`); each listed word
// must be a real word-token (never a flag, a placeholder, or a shell value) or
// this is not a verb summary.
function splitVerbAlternation(tok) {
  if (!tok.includes("/") || tok.includes("|")) return null;
  const parts = tok.split("/");
  return parts.length > 1 && parts.every((p) => /^[a-z][\w-]*$/.test(p)) ? parts : null;
}

// A "|"-alternation documents the VALUES one argument accepts (`bash|zsh|fish`)
// — it is never a verb or noun, so it is read exactly like a placeholder: once
// a command path already exists, it terminates the walk as a positional
// argument this gate says nothing further about.
function isArgAlternation(tok) {
  return !tok.includes("/") && /^[a-z][\w-]*(?:\|[a-z][\w-]*)+$/i.test(tok);
}

// A line is a pure metasyntax / grammar diagram when every token after `bp` is
// either an angle placeholder (`<noun>`) or a fully-bracketed group (`[global
// flags]`, `[args]`) — never a bare literal word. One bare word anywhere (e.g.
// `doc` in `bp doc ls post`) means this is a real, adjudicable command.
export function isMetasyntaxLine(text) {
  const m = String(text).trim().match(/^(?:bp|barkpark)\s+(.+)$/);
  if (!m) return false;
  const toks = tokenize(m[1]);
  let i = 0;
  while (i < toks.length) {
    const t = toks[i];
    if (t.startsWith("<") && t.endsWith(">")) { i++; continue; }
    if (t.startsWith("[") || t.startsWith("(")) {
      const open = t[0], close = open === "[" ? "]" : ")";
      let depth = 0;
      do {
        for (const ch of toks[i]) { if (ch === open) depth++; else if (ch === close) depth--; }
        i++;
      } while (i < toks.length && depth > 0);
      if (depth > 0) return false; // unterminated group — not a clean diagram
      continue;
    }
    return false; // a bare literal token — this IS a printed command
  }
  return i > 0;
}

// Resolve one printed `bp …` command against the union.
//
// Returns {verdict, path, via, reasons, unproven}. `unproven` is never folded
// into a pass: it is the honest "no source can adjudicate this", reported by
// name and by count, and it is a different thing from `unresolved` (a source
// CAN adjudicate it, and says no).
export function resolveBpCommand(sources, line, { fenced = false, use = "ABCDE" } = {}) {
  const useA = use.includes("A") && sources.A;
  const useB = use.includes("B") && sources.B;
  const useC = use.includes("C") && sources.C;
  const useD = use.includes("D") && sources.D;
  const useE = use.includes("E") && sources.E;

  const { text, tokens } = splitCommandLine(line);
  const res = { verdict: PROVEN, path: [], via: [], authority: [], reasons: [], unproven: [], text };
  // `cite` records WHICH line of WHICH file adjudicated this token. A source
  // letter alone ("[D]") is not checkable by a reader; `hetzner_cmd.go:88` is.
  const cite = (src, tok, at) => { if (at) res.authority.push(`${src} ${tok} → ${at}`); };
  if (tokens.length === 0 || !/^(bp|barkpark)$/.test(tokens[0])) {
    res.verdict = UNRESOLVED;
    res.reasons.push(`not a bp command: ${text}`);
    return res;
  }

  // a pure grammar diagram (`bp [global flags] <noun> <verb> …`) prints no
  // literal command — adjudicate it as neither a pass nor a parse failure.
  if (isMetasyntaxLine(text)) {
    res.verdict = NOT_A_COMMAND;
    res.reasons.push(`grammar diagram, not a printed command: ${text}`);
    return res;
  }

  let node = useD ? sources.D.nodes.get(sources.D.rootFn) : null;
  let leafFn = null;
  let i = 1;
  let consumedGlobal = false;

  // pre-noun global flags: `bp -s <server> workspace create …`
  while (i < tokens.length && res.path.length === 0 && isFlag(tokens[i])) {
    const g = tokens[i].split("=")[0];
    if (sources.globals.size && !sources.globals.has(g)) {
      res.verdict = UNRESOLVED;
      res.reasons.push(`\`${g}\` is not a global flag (${sources.origins.B} completionGlobals)`);
      return res;
    }
    consumedGlobal = true;
    res.via.push("B");
    cite("B", g, sources.Gat);
    i++;
    // a value-taking global consumes the next token unless it is itself a flag
    // or resolves as a noun.
    if (i < tokens.length && !isFlag(tokens[i]) && !tokens[i].includes("=")) {
      const t = tokens[i];
      const isNoun = (useB && sources.B.has(t)) || (useA && sources.A.nouns.has(t)) ||
        (node && node.cases.has(t));
      if (!isNoun) i++;
    }
  }

  // the command path. A token is consumed only while we are still WALKING the
  // dispatch tree; once a leaf is reached the rest are positional arguments and
  // this gate says nothing about them (it proves dispatch, not semantics).
  let leaf = false;
  for (; i < tokens.length; i++) {
    const tok = tokens[i];
    if (isFlag(tok)) break;
    if (leaf) break;
    if (isPlaceholder(tok)) {
      if (res.path.length > 0) break; // a positional argument
      continue;
    }
    if (isArgAlternation(tok)) {
      // `bash|zsh|fish` etc — a pipe alternation over one ARGUMENT's values,
      // never a verb or noun. Once a command path already exists it is read
      // exactly like a placeholder: the rest of the line is positional.
      if (res.path.length > 0) break;
      // no path yet — fall through; nothing currently needs this at the head.
    }
    if (node && node.cases.has(tok)) {
      res.path.push(tok);
      res.via.push("D");
      cite("D", tok, node.caseAt.get(tok));
      const callee = node.edges.get(tok);
      const sub = sources.D.nodes.get(`${node.id}::${tok}`) || null;
      if (callee) {
        leafFn = callee;
        node = sources.D.nodes.get(callee) || sub;
      } else {
        node = sub;
      }
      if (!node || node.cases.size === 0) leaf = true;
      continue;
    }
    if (res.path.length === 0) {
      const inA = useA && sources.A.nouns.has(tok);
      const inB = useB && sources.B.has(tok);
      if (inA || inB) {
        res.path.push(tok);
        res.via.push(inA ? "A" : "B");
        cite(inA ? "A" : "B", tok, inA ? sources.A.at.get(tok) : sources.Bat);
        node = null;
        continue;
      }
      res.verdict = UNRESOLVED;
      res.reasons.push(
        `\`bp ${tok}\` — head \`${tok}\` resolves in NO source ` +
        `(A manifest nouns, B completionNouns, D router switches)`);
      return res;
    }
    // depth ≥ 2 — the router switch did not dispatch it. Two sources still can:
    // [D3] the noun-qualified built-in registry (`bp task create` is dispatched
    // from nounBuiltins and exists in NO manifest — it was UNRESOLVED on three
    // true doc lines until this branch existed), and [A] the manifest, since a
    // built-in noun intercepts a few verbs client-side and lets every other one
    // fall through to its manifest row.
    const noun = res.path[0];
    const builtinVerbs = (res.path.length === 1 && useD && sources.D.pairs.get(noun)) || null;
    const inA = res.path.length === 1 && useA && sources.A.nouns.has(noun);
    if (builtinVerbs || inA) {
      const manifestVerbs = inA ? (sources.A.verbs.get(noun) || new Set()) : new Set();
      // WHERE a verb is adjudicated decides WHICH file the citation names: the
      // manifest row, or the registry line that spells the pair.
      const has = (v) => manifestVerbs.has(v) || !!(builtinVerbs && builtinVerbs.has(v));
      const citeVerb = (v) => manifestVerbs.has(v)
        ? cite("A", v, sources.A.at.get(`${noun}.${v}`))
        : cite("D", v, builtinVerbs.get(v).at);
      const src = (v) => (manifestVerbs.has(v) ? "A" : "D");
      if (has(tok)) {
        res.path.push(tok);
        res.via.push(src(tok));
        citeVerb(tok);
        // a built-in's own handler is the leaf whose flags [C]/[E] enumerate
        if (!manifestVerbs.has(tok) && builtinVerbs.get(tok).leaf) leafFn = builtinVerbs.get(tok).leaf;
        leaf = true;
        continue;
      }
      // a verb SUMMARY — `bp doc get/ls/query/…` — is a coverage GAIN, not a
      // suppression: it expands into one check per verb against this noun's
      // verb set, and a verb the noun lacks still REDs, named.
      const alt = splitVerbAlternation(tok);
      if (alt) {
        const missing = alt.filter((v) => !has(v));
        if (missing.length === 0) {
          res.path.push(tok);
          res.via.push(alt.some((v) => src(v) === "A") ? "A" : "D");
          for (const v of alt) citeVerb(v);
          leaf = true;
          continue;
        }
        res.verdict = UNRESOLVED;
        res.reasons.push(
          `\`bp ${noun} ${tok}\` — alternation lists verb(s) not in noun \`${noun}\` ` +
          `(manifest rows + noun-qualified built-ins): ` + missing.join(", "));
        return res;
      }
      res.verdict = UNRESOLVED;
      res.reasons.push(
        `\`bp ${noun} ${tok}\` — \`${tok}\` is neither a verb of noun \`${noun}\` ` +
        `(manifest rows + noun-qualified built-ins) nor dispatched by a router switch`);
      return res;
    }
    if (!node) {
      // No source can adjudicate past this point. That is UNPROVEN — reported
      // by name — never a silent pass and never a manufactured red.
      res.verdict = res.verdict === UNRESOLVED ? UNRESOLVED : UNPROVEN;
      res.unproven.push(
        `\`bp ${res.path.join(" ")} ${tok}\` — no source can adjudicate \`${tok}\`: ` +
        `\`${noun}\` carries no manifest row${useD ? "" : " and source D was not consulted"}`);
      leaf = true;
      continue;
    }
    res.verdict = UNRESOLVED;
    res.reasons.push(
      `\`bp ${res.path.join(" ")} ${tok}\` — \`${tok}\` is not dispatched by ` +
      `${node.id.replace("::", " case ")}()`);
    return res;
  }

  if (res.path.length === 0) {
    // a bare declared global (or several) IS the command — `bp --version`,
    // `bp -V`, `bp -h`, `bp --help` all resolve without a noun. An UNDECLARED
    // bare flag already REDs inside the loop above and never reaches here.
    if (consumedGlobal) return res;
    res.verdict = UNRESOLVED;
    res.reasons.push(`bare \`bp\` with no resolvable command: ${text}`);
    return res;
  }

  // ── flags ────────────────────────────────────────────────────────────────
  const { depth0: supplied, all: usedFlags } = flagsByDepth(text);
  const nonGlobal = [...usedFlags].filter((f) => !sources.globals.has(f) && f !== "-h" && f !== "--help");
  if (nonGlobal.length) {
    const vocab = new Set();
    let vocabSource = null;
    const flagAuth = new Map();   // "--flag" -> "file:line" that declares it
    if (useC && leafFn && sources.C.has(leafFn)) {
      const at = sources.Cat.get(leafFn);
      for (const f of sources.C.get(leafFn)) { vocab.add(f); if (at) flagAuth.set(f, at); }
      vocabSource = "C";
    }
    const key = res.path.join(".");
    if (useA && sources.A.flags.has(key)) {
      const at = sources.A.at.get(key);
      for (const f of sources.A.flags.get(key)) { vocab.add(f); if (!flagAuth.has(f) && at) flagAuth.set(f, at); }
      vocabSource = vocabSource ? `${vocabSource}+A` : "A";
    }
    if (useE && leafFn && sources.D && sources.D.funcFile.has(leafFn)) {
      const file = sources.D.funcFile.get(leafFn);
      const eAt = sources.Eat.get(file) || new Map();
      for (const f of sources.E.get(file) || []) { vocab.add(f); if (!flagAuth.has(f)) flagAuth.set(f, eAt.get(f)); }
      vocabSource = vocabSource ? `${vocabSource}+E` : "E";
    }
    if (vocab.size === 0) {
      res.verdict = res.verdict === UNRESOLVED ? UNRESOLVED : UNPROVEN;
      res.unproven.push(
        `flags [${nonGlobal.join(" ")}] on \`bp ${res.path.join(" ")}\` — no source enumerates this ` +
        `leaf's flags (C allowlist absent, A carries no row, E found none)`);
    } else {
      res.via.push(vocabSource);
      for (const f of nonGlobal) if (vocab.has(f)) cite(vocabSource, f, flagAuth.get(f));
      const unknown = nonGlobal.filter((f) => !vocab.has(f));
      if (unknown.length) {
        res.verdict = UNRESOLVED;
        res.reasons.push(
          `\`bp ${res.path.join(" ")}\` does not accept ${unknown.join(", ")} ` +
          `(known: ${[...vocab].sort().join(" ")})`);
      }
    }
  }

  // ── required flags — FENCED lines only ───────────────────────────────────
  // An inline prose fragment (`bp cloud site create --template search-starter`)
  // is an illustration of one flag, not an invocation; required-checking it
  // manufactures a red on every doc that names a flag mid-sentence.
  if (fenced && res.verdict !== UNRESOLVED) {
    const required = requiredFlagsFor(sources, res.path);
    const missing = [...required].filter((f) => !supplied.has(f));
    if (missing.length) {
      res.verdict = UNRESOLVED;
      res.reasons.push(
        `\`bp ${res.path.join(" ")}\` is missing required ${missing.join(", ")} ` +
        `(the CLI's own usage synopsis marks them non-optional)`);
    }
  }

  return res;
}

// Required = the INTERSECTION of the depth-0 flags of every usage synopsis for
// this exact path. A leaf with two alternative synopses (`quick-setup --site …`
// vs `quick-setup --static …`) therefore requires nothing, which is the honest
// answer: no single flag is required by all spellings.
export function requiredFlagsFor(sources, path) {
  const matches = sources.synopses.filter(
    (s) => s.path.length === path.length && s.path.every((t, i) => t === path[i]));
  if (matches.length === 0) return new Set();
  let acc = null;
  for (const m of matches) {
    if (acc === null) acc = new Set(m.required);
    else for (const f of [...acc]) if (!m.required.has(f)) acc.delete(f);
  }
  return acc || new Set();
}
