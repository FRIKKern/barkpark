#!/usr/bin/env node
// waterfall.mjs — P2 of doc-truth: "each fact once."
//
// P1 (verify-docs.mjs) asks "is each claim TRUE?". P2 asks the orthogonal
// question: "is the same fact RESTATED in more than one place?" — and, when it
// is, proposes (never applies) collapsing the duplicates to ONE canonical home
// plus typed pointers.
//
//   node tooling/doc-truth/waterfall.mjs [--json]
//   node tooling/doc-truth/waterfall.mjs --topic <factKey-substring> [--json]
//
// ── THE KEY IDEA: hash on verifiable claims, NOT prose. ───────────────────────
// Two sections restate the same fact when they share a significant set of
// VERIFIABLE CLAIM ANCHORS (the paths/commands/symbols P1 extracts, plus a small
// class of code/config invariants P1's five types skip — `force_ssl`, `<head>`,
// `_build/prod`, env vars). We content-hash the NORMALIZED anchor (its factKey),
// never the surrounding prose. Restatement = high Jaccard over factKey sets.
// Different-context co-mentions (small overlap) are a noop.
//
// A section can restate an anchor in PROSE that another section states in a
// backtick (Golden Rule "NEVER skip `systemctl restart`" ↔ Past Mistake "Forgot
// systemctl restart"). To catch that without falling back to prose-similarity,
// we build a corpus-wide VOCABULARY of verifiable anchor strings first, then a
// section's factKey set also includes any vocabulary anchor whose literal string
// appears in that section's body. The prose-scan only ever re-finds strings that
// are verifiable claims SOMEWHERE — it never does fuzzy text matching.
//
// ── CONSERVATIVE, PROPOSE-ONLY. ──────────────────────────────────────────────
// The detector emits PROPOSALS as data. It never edits a doc. Verbatim-exempt
// sections (CLAUDE.md Golden Rules / Past Mistakes) are still proposed, tagged
// `requiresOwnerSignoff: true`. Every proposal enforces the LOSE-NO-FACT
// guarantee: it enumerates every factKey in either section and asserts each one
// survives in `canonical ∪ pointer`; if any would be lost the proposal is
// invalid and dropped with a logged reason.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { extractClaims, sectionsOf, slugify } from "./verify-docs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const CORPUS_FIXTURE = join(HERE, "fixtures/audit-2026-06-21-corpus.json");
const ROOT_CLAUDE = "CLAUDE.md";

// Restatement threshold. A section pair is a restatement cluster when its
// factKey-set Jaccard ≥ JACCARD_MIN AND it shares ≥ SHARED_MIN raw anchors.
// Tuned conservatively: SHARED_MIN=3 keeps unrelated sections that happen to
// co-mention one shared path/command from clustering, while still catching the
// Golden Rules ↔ Past Mistakes pair (which shares ≥4 anchors). The Jaccard floor
// guards against one tiny section being swallowed by a large one.
const JACCARD_MIN = 0.10;
const SHARED_MIN = 3;

// Sections that are verbatim-exempt per their doc's own contract. We still
// detect + propose, but flag the proposal as requiring owner sign-off so the
// orchestrator never auto-applies. Keyed by `doc::slug`.
const VERBATIM_EXEMPT = new Set([
  `${ROOT_CLAUDE}::golden-rules`,
  `${ROOT_CLAUDE}::past-mistakes-never-repeat`,
]);

// ── doc-tier (canonical preference) ──────────────────────────────────────────
// The canonical home for a fact prefers the higher doc-tier. Read the marker on
// line 1: `<!-- doc-tier: agent|human|cold | … -->`. Default unknown → "human".
const TIER_RANK = { agent: 3, human: 2, cold: 1, unknown: 0 };
function docTier(text) {
  const first = text.split("\n", 1)[0] || "";
  const m = first.match(/doc-tier:\s*([a-z]+)/i);
  return m ? m[1].toLowerCase() : "unknown";
}

// ── factKey normalization ────────────────────────────────────────────────────
// A factKey is a STABLE, content-derived identity for a verifiable claim —
// normalized so the same fact stated two ways hashes identically.
function factKeyForClaim(c) {
  switch (c.type) {
    case "path": {
      // repo-relative, trailing slash stripped, capped at a 2-segment prefix so
      // `_build/prod` and `_build/prod/lib/barkpark` collapse to one build-tree
      // fact. (The full literal is kept on the anchor record for reporting.)
      const lit = c.target.literal.replace(/\/+$/, "");
      return "path:" + lit.split("/").slice(0, 2).join("/");
    }
    case "command":
      // tool + salient arg (the subcommand) — `make rebuild`, `systemctl restart`.
      return "cmd:" + c.target.head + (c.target.sub ? " " + c.target.sub : "");
    case "symbol":
      return "sym:" + (c.target.module || "") + "#" + (c.target.func || "");
    case "route":
      return "route:" + c.target.path;
    case "lineref":
      return "lref:" + c.target.base;
    default:
      return c.type + ":" + c.raw;
  }
}

// ── invariant anchors: the verifiable class P1's five types skip ─────────────
// `force_ssl`, `<script>`/`<head>`, env-var names, `phx-click`, bare build-tree
// path tokens like `_build/prod`. These name real code/config invariants — they
// ARE verifiable claims, just not ones P1's verifier resolves. We only mine them
// from backtick spans (never free prose) so the vocabulary stays anchored.
const INVARIANT_PATTERNS = [
  // HTML/HEEx tag tokens: <script>, <head>, <body>
  { re: /^<\/?([a-z][a-z0-9]*)>$/i, key: (m) => "html:<" + m[1].toLowerCase() + ">" },
  // build-tree path token without a top-dir/extension anchor: _build/prod[/...]
  { re: /^_build\/[A-Za-z0-9_./-]+$/, key: (m) => "path:_build/" + m[0].split("/")[1] },
  // config / Phoenix env keys & directives: force_ssl, phx-click, PHX_HOST
  { re: /^(force_ssl|check_origin|async)$/, key: (m) => "cfg:" + m[1] },
  { re: /^(phx-[a-z]+)$/, key: (m) => "cfg:" + m[1] },
  { re: /^([A-Z][A-Z0-9_]{3,})(=\S*)?$/, key: (m) => "env:" + m[1] },
];

function invariantKey(raw) {
  for (const p of INVARIANT_PATTERNS) {
    const m = raw.match(p.re);
    if (m) return { factKey: p.key(m), raw };
  }
  return null;
}

// Mine invariant anchors from a doc's backtick spans. We re-walk the raw text
// for inline + fenced backtick tokens (cheap; the same shape P1's extractSpans
// uses) and classify each against INVARIANT_PATTERNS.
function invariantAnchors(doc, text) {
  const out = [];
  const lines = text.split("\n");
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
    const ln = i + 1;
    if (inFence) {
      const hit = invariantKey(line.trim());
      if (hit) out.push({ doc, line: ln, type: "invariant", ...hit });
      continue;
    }
    for (const m of line.matchAll(/`([^`]+)`/g)) {
      const hit = invariantKey(m[1].trim());
      if (hit) out.push({ doc, line: ln, type: "invariant", ...hit });
    }
  }
  return out;
}

// ── per-doc anchor table ─────────────────────────────────────────────────────
// Every anchor (P1 claim + invariant) carries: factKey, raw surface string, the
// line it sits on, and the section that line falls in.
function sectionAt(sections, line) {
  for (const s of sections) {
    if (line >= s.startLine && line < s.endLine) return s;
  }
  return null;
}

function anchorsForDoc(doc) {
  const abs = join(ROOT, doc);
  const text = readFileSync(abs, "utf8");
  const sections = sectionsOf(text);
  const tier = docTier(text);
  const raw = [
    ...extractClaims(doc, text).map((c) => ({
      doc, line: c.line, type: c.type, raw: c.raw, factKey: factKeyForClaim(c),
    })),
    ...invariantAnchors(doc, text),
  ];
  const anchors = [];
  for (const a of raw) {
    const sec = sectionAt(sections, a.line);
    anchors.push({ ...a, section: sec ? sec.heading : "(preamble)", slug: sec ? sec.slug : "" });
  }
  return { doc, tier, sections, text, anchors };
}

// ── corpus → canonical-fact DAG ──────────────────────────────────────────────
// factKey → { canonical: {doc,section,line,slug,tier}, pointers: [...] }.
// Canonical pick: highest doc-tier, tie-broken by first occurrence in corpus
// order. The DAG is the substrate P3's routing table queries via --topic.
function buildDag(docDatas) {
  const dag = new Map(); // factKey -> { occurrences: [...] }
  for (const dd of docDatas) {
    for (const a of dd.anchors) {
      let entry = dag.get(a.factKey);
      if (!entry) dag.set(a.factKey, (entry = { factKey: a.factKey, occurrences: [] }));
      entry.occurrences.push({
        doc: a.doc, section: a.section, slug: a.slug, line: a.line,
        raw: a.raw, type: a.type, tier: dd.tier,
      });
    }
  }
  // resolve canonical + pointers per factKey
  for (const entry of dag.values()) {
    const occ = entry.occurrences;
    let best = occ[0];
    for (const o of occ) {
      if (TIER_RANK[o.tier] > TIER_RANK[best.tier]) best = o; // higher tier wins
      // tie on tier → keep earlier (first occurrence) — occ is in corpus order
    }
    entry.canonical = best;
    entry.pointers = occ.filter((o) => o !== best);
  }
  return dag;
}

// ── restatement detector ─────────────────────────────────────────────────────
// Group anchors by (doc, section); compare every section PAIR (cross-doc AND
// within a doc) on factKey-set overlap. Conservative thresholds keep co-mentions
// from clustering.
function sectionFactSets(docDatas) {
  const map = new Map(); // "doc::slug" -> { doc, section, slug, line, keys:Set, rawByKey:Map }
  for (const dd of docDatas) {
    for (const a of dd.anchors) {
      const id = `${a.doc}::${a.slug}`;
      let s = map.get(id);
      if (!s) {
        map.set(id, (s = {
          doc: a.doc, section: a.section, slug: a.slug, firstLine: a.line,
          tier: dd.tier, keys: new Set(), rawByKey: new Map(),
        }));
      }
      s.keys.add(a.factKey);
      if (!s.rawByKey.has(a.factKey)) s.rawByKey.set(a.factKey, a.raw);
      if (a.line < s.firstLine) s.firstLine = a.line;
    }
  }
  return map;
}

// PROSE-SCAN augmentation: a section's factKey set also includes any corpus
// vocabulary anchor whose literal surface string appears verbatim in the
// section's body text. This is what lets a prose restatement ("Forgot systemctl
// restart") match a backtick one (`systemctl restart`). The vocabulary is the
// set of verifiable anchors — never arbitrary prose.
function augmentWithProse(sectionMap, docDatas, vocab) {
  // index doc text + section line ranges
  const byDoc = new Map();
  for (const dd of docDatas) byDoc.set(dd.doc, dd);
  for (const s of sectionMap.values()) {
    const dd = byDoc.get(s.doc);
    if (!dd) continue;
    const sec = dd.sections.find((x) => x.slug === s.slug) ||
      dd.sections.find((x) => x.heading === s.section);
    if (!sec) continue;
    const body = dd.text.split("\n").slice(sec.startLine - 1, sec.endLine).join("\n");
    for (const [str, fk] of vocab) {
      if (s.keys.has(fk)) continue;
      // word-ish boundary check so `async` doesn't match inside `asynchronous`
      if (bodyContains(body, str)) {
        s.keys.add(fk);
        if (!s.rawByKey.has(fk)) s.rawByKey.set(fk, str);
      }
    }
  }
}

function bodyContains(body, needle) {
  let from = 0;
  while (true) {
    const i = body.indexOf(needle, from);
    if (i === -1) return false;
    const before = i === 0 ? "" : body[i - 1];
    const after = body[i + needle.length] || "";
    const boundaryOk =
      !/[A-Za-z0-9_]/.test(before.slice(-1) || "") &&
      !/[A-Za-z0-9_]/.test(after);
    // for path-ish needles (contain `/`) skip the trailing boundary (a longer
    // path is a legit superstring match we WANT, e.g. _build/prod[/lib/...]).
    if (boundaryOk || needle.includes("/")) return true;
    from = i + needle.length;
  }
}

// Build the vocabulary: surface-string → factKey, restricted to anchors whose
// surface is distinctive enough to prose-scan safely (length ≥ 5, OR contains a
// non-word char like `/`, `_`, `<`). Short bare words are excluded to avoid
// accidental prose hits.
function buildVocab(docDatas) {
  const vocab = new Map();
  for (const dd of docDatas) {
    for (const a of dd.anchors) {
      const s = a.raw;
      if (!s) continue;
      const distinctive = s.length >= 5 || /[/_<>=-]/.test(s);
      if (!distinctive) continue;
      if (!vocab.has(s)) vocab.set(s, a.factKey);
    }
  }
  return vocab;
}

function jaccard(aSet, bSet) {
  let inter = 0;
  for (const k of aSet) if (bSet.has(k)) inter++;
  const uni = aSet.size + bSet.size - inter;
  return { inter, jaccard: uni === 0 ? 0 : inter / uni };
}

// A bare top-dir path key (`path:api`, `path:priv`, `path:docs`) is a generic
// prefix that two unrelated sections share just by both touching the same area
// of the tree. It is NOT restatement evidence. We exclude such keys from the
// shared-COUNT that gates clustering (they still live in the DAG). A path key is
// "generic" when its 2-segment normalization collapsed to a single top-dir.
function isGenericPrefix(fk) {
  if (!fk.startsWith("path:")) return false;
  const p = fk.slice(5);
  return TOP_DIRS_BARE.has(p);
}
const TOP_DIRS_BARE = new Set([
  "api", "tooling", "docs", "js", "web", "lib", "priv", "deploy",
  ".github", "scripts", "internal", "docs-site",
]);

// Shared keys that count as restatement evidence (drops generic prefixes).
function distinctiveShared(aSet, bSet) {
  const shared = new Set();
  for (const k of aSet) if (bSet.has(k) && !isGenericPrefix(k)) shared.add(k);
  return shared;
}

// ── collapse proposal (propose only) ─────────────────────────────────────────
// Promote one section to canonical (higher tier, tie → earlier); replace the
// overlapping facts in the OTHER with a typed pointer. Enforce lose-no-fact:
// every factKey in either section must survive in canonical ∪ pointer.
function makeProposal(a, b, shared) {
  // canonical = higher tier; tie → the one appearing earlier (lower firstLine,
  // or doc order — a is always corpus-earlier than b by construction below).
  let canonical = a, other = b;
  if (TIER_RANK[b.tier] > TIER_RANK[a.tier]) { canonical = b; other = a; }

  // The pointer the OTHER section would carry, replacing its overlapping facts.
  const pointer = {
    inSection: { doc: other.doc, section: other.section, slug: other.slug },
    toCanonical: { doc: canonical.doc, section: canonical.section, slug: canonical.slug },
    typedMarkdown:
      `> See [${canonical.section}](` +
      (canonical.doc === other.doc ? `#${canonical.slug}` : `${canonical.doc}#${canonical.slug}`) +
      `) — canonical for: ${[...shared].map(fkShort).join(", ")}.`,
    replacesFactKeys: [...shared],
  };

  // lose-no-fact: a collapse only ever touches the SHARED facts — the OTHER
  // section keeps its non-shared facts in place, and the canonical section is
  // untouched. So the post-collapse fact set is:
  //   canonical.keys  ∪  (other.keys \ shared)  ∪  pointer.replacesFactKeys
  // Every factKey present BEFORE in either section must survive there. The only
  // way a fact is lost is if a SHARED key is somehow not actually in canonical
  // (it always is, since shared ⊆ both) or the pointer fails to name it. We
  // enumerate explicitly and assert before ⊆ after.
  const before = new Set([...a.keys, ...b.keys]);
  const otherRetained = new Set([...other.keys].filter((k) => !shared.has(k)));
  const after = new Set([
    ...canonical.keys,
    ...otherRetained,
    ...pointer.replacesFactKeys,
  ]);
  const lost = [];
  for (const k of before) if (!after.has(k)) lost.push(k);

  const requiresOwnerSignoff =
    VERBATIM_EXEMPT.has(`${a.doc}::${a.slug}`) ||
    VERBATIM_EXEMPT.has(`${b.doc}::${b.slug}`);

  return {
    canonical: { doc: canonical.doc, section: canonical.section, slug: canonical.slug, tier: canonical.tier },
    pointerInto: { doc: other.doc, section: other.section, slug: other.slug, tier: other.tier },
    sharedFactKeys: [...shared],
    sharedRaw: [...shared].map((k) => a.rawByKey.get(k) || b.rawByKey.get(k) || k),
    pointer,
    requiresOwnerSignoff,
    loseNoFact: { before: before.size, lost, ok: lost.length === 0 },
  };
}

function fkShort(fk) {
  // strip the type prefix for human-readable pointer text
  const i = fk.indexOf(":");
  return i === -1 ? fk : fk.slice(i + 1);
}

// ── top-level detect ──────────────────────────────────────────────────────────
function detect(docs) {
  const docDatas = docs.map(anchorsForDoc);
  const dag = buildDag(docDatas);
  const sectionMap = sectionFactSets(docDatas);
  const vocab = buildVocab(docDatas);
  augmentWithProse(sectionMap, docDatas, vocab);

  // sections in corpus order: doc order, then firstLine
  const docOrder = new Map(docs.map((d, i) => [d, i]));
  const sections = [...sectionMap.values()]
    .filter((s) => s.keys.size > 0)
    .sort((x, y) =>
      (docOrder.get(x.doc) - docOrder.get(y.doc)) || (x.firstLine - y.firstLine));

  const clusters = [];
  const invalid = []; // dropped lose-no-fact failures, logged
  for (let i = 0; i < sections.length; i++) {
    for (let j = i + 1; j < sections.length; j++) {
      const A = sections[i], B = sections[j];
      const { jaccard: jac } = jaccard(A.keys, B.keys);
      // gate on DISTINCTIVE shared anchors (generic top-dir prefixes excluded).
      const distinctive = distinctiveShared(A.keys, B.keys);
      if (distinctive.size < SHARED_MIN || jac < JACCARD_MIN) continue;
      // the proposal's shared set is the FULL overlap (generic prefixes still get
      // a canonical home via the pointer — losing nothing), but evidence count is
      // the distinctive subset.
      const shared = new Set([...A.keys].filter((k) => B.keys.has(k)));
      const proposal = makeProposal(A, B, shared);
      const cluster = {
        a: { doc: A.doc, section: A.section, slug: A.slug, tier: A.tier, factCount: A.keys.size },
        b: { doc: B.doc, section: B.section, slug: B.slug, tier: B.tier, factCount: B.keys.size },
        sharedCount: distinctive.size,
        sharedTotal: shared.size,
        jaccard: +jac.toFixed(3),
        sharedFactKeys: [...distinctive],
        proposal,
      };
      if (proposal.loseNoFact.ok) clusters.push(cluster);
      else invalid.push({ cluster, reason: "lose-no-fact violated", lost: proposal.loseNoFact.lost });
    }
  }
  // strongest clusters first
  clusters.sort((x, y) => y.sharedCount - x.sharedCount || y.jaccard - x.jaccard);
  return { docDatas, dag, sectionMap, clusters, invalid };
}

// ── --topic query (the DAG query P3 builds on) ───────────────────────────────
function topicQuery(dag, substr) {
  const hits = [];
  for (const entry of dag.values()) {
    if (!entry.factKey.toLowerCase().includes(substr.toLowerCase())) continue;
    hits.push({
      factKey: entry.factKey,
      canonical: entry.canonical
        ? { doc: entry.canonical.doc, section: entry.canonical.section, slug: entry.canonical.slug, line: entry.canonical.line, tier: entry.canonical.tier }
        : null,
      pointers: entry.pointers.map((p) => ({ doc: p.doc, section: p.section, slug: p.slug, line: p.line, tier: p.tier })),
    });
  }
  hits.sort((a, b) => b.pointers.length - a.pointers.length);
  return hits;
}

// ── corpus resolution (mirror verify-docs) ───────────────────────────────────
function defaultCorpus() {
  const present = [];
  const seen = new Set();
  const add = (d) => { if (!seen.has(d) && existsSync(join(ROOT, d))) { seen.add(d); present.push(d); } };
  // the P1 92-doc corpus fixture …
  try {
    const c = JSON.parse(readFileSync(CORPUS_FIXTURE, "utf8"));
    for (const d of [...(c.ctx || []), ...(c.batches || []).flat()]) add(d);
  } catch { /* fixture optional */ }
  // … plus the root CLAUDE.md (the acceptance target)
  add(ROOT_CLAUDE);
  return present;
}

// ── reporting ─────────────────────────────────────────────────────────────────
function printHuman(res) {
  const bar = "─".repeat(74);
  process.stdout.write(`\ndoc-truth waterfall — restatement detector (propose-only)\n${bar}\n`);
  process.stdout.write(`corpus: ${res.docDatas.length} docs · ${res.dag.size} distinct facts · ${res.clusters.length} restatement cluster(s)\n`);
  if (res.invalid.length) {
    process.stdout.write(`dropped (lose-no-fact violated): ${res.invalid.length}\n`);
  }
  for (const c of res.clusters) {
    process.stdout.write(`\n● cluster — ${c.sharedCount} shared anchors · jaccard ${c.jaccard}\n`);
    process.stdout.write(`    A: ${c.a.doc} » ${c.a.section}  [tier ${c.a.tier}, ${c.a.factCount} facts]\n`);
    process.stdout.write(`    B: ${c.b.doc} » ${c.b.section}  [tier ${c.b.tier}, ${c.b.factCount} facts]\n`);
    process.stdout.write(`    shared facts: ${c.proposal.sharedRaw.map((r) => "`" + r + "`").join(", ")}\n`);
    const p = c.proposal;
    process.stdout.write(`    → canonical: ${p.canonical.doc} » ${p.canonical.section}\n`);
    process.stdout.write(`      pointer into: ${p.pointerInto.doc} » ${p.pointerInto.section}\n`);
    process.stdout.write(`      ${p.pointer.typedMarkdown}\n`);
    process.stdout.write(`      lose-no-fact: ${p.loseNoFact.ok ? "OK" : "FAIL"} (${p.loseNoFact.before} facts, ${p.loseNoFact.lost.length} lost)`);
    if (p.requiresOwnerSignoff) process.stdout.write(`  ⚠ requires owner sign-off (verbatim-exempt)`);
    process.stdout.write(`\n`);
  }
  process.stdout.write(`\n${bar}\n`);
  process.stdout.write(`PROPOSE-ONLY: no doc was modified. Clusters are leads for a human.\n`);
  process.stdout.write(`${bar}\n`);
}

// Export the engine so the acceptance test imports it directly.
export function runWaterfall(docs) {
  return detect(docs && docs.length ? docs : defaultCorpus());
}

export { factKeyForClaim, buildDag, defaultCorpus };

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const wantJson = argv.includes("--json");
  const topicI = argv.indexOf("--topic");
  // positional args are non-flags, excluding the value that follows --topic
  const globs = argv.filter((a, i) => !a.startsWith("--") && !(topicI !== -1 && i === topicI + 1));
  const docs = globs.length ? globs.filter((d) => existsSync(join(ROOT, d))) : defaultCorpus();

  if (topicI !== -1) {
    const substr = argv[topicI + 1];
    if (!substr) { process.stderr.write("waterfall --topic: give a factKey substring.\n"); process.exit(2); }
    const res = detect(docs);
    const hits = topicQuery(res.dag, substr);
    if (wantJson) {
      process.stdout.write(JSON.stringify({ topic: substr, hits }, null, 2) + "\n");
    } else {
      const bar = "─".repeat(74);
      process.stdout.write(`\nwaterfall topic "${substr}" — ${hits.length} matching fact(s)\n${bar}\n`);
      for (const h of hits) {
        process.stdout.write(`\n${h.factKey}\n`);
        if (h.canonical) process.stdout.write(`  canonical: ${h.canonical.doc} » ${h.canonical.section} (tier ${h.canonical.tier})\n`);
        for (const p of h.pointers) process.stdout.write(`  pointer:   ${p.doc} » ${p.section} (tier ${p.tier})\n`);
      }
      process.stdout.write(`${bar}\n`);
    }
    process.exit(0);
  }

  const res = detect(docs);
  if (wantJson) {
    const out = {
      corpusDocs: res.docDatas.length,
      distinctFacts: res.dag.size,
      clusters: res.clusters,
      droppedLoseNoFact: res.invalid,
    };
    process.stdout.write(JSON.stringify(out, null, 2) + "\n");
  } else {
    printHuman(res);
  }
  process.exit(0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
