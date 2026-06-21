#!/usr/bin/env node
// highways.mjs — P3 of doc-truth: "the highways stay open."
//
// P1 (verify-docs.mjs) asks "is each claim TRUE?". P2 (waterfall.mjs) asks "is
// each fact stated ONCE?". P3 asks the routing question: "does every entry in
// the root CLAUDE.md routing table reach exactly ONE canonical owner doc, in a
// short hop?" — and reports the byte-budget / 7-card-cap violations that gate
// the doc spine, so a single run tells you whether the map still works.
//
//   node tooling/doc-truth/highways.mjs [--json]
//
// ── WHAT IT CHECKS ───────────────────────────────────────────────────────────
//   1. ROUTING RESOLUTION — parse the `| Group | Task pattern | Load |` table in
//      root CLAUDE.md. For every Load target, the file must exist on disk and
//      resolve to its canonical owner in ≤2 hops (see THE HOP MODEL below). A
//      target that doesn't resolve, exceeds 2 hops, or is a pointer-of-a-pointer
//      is a routing FAILURE.
//   2. CANONICAL-FOR UNIQUENESS — scan every doc's line-1 marker; one topic may
//      own exactly one doc. A topic on 2+ docs is a duplicate-owner violation.
//   3. ORPHANS — topics named by the routing table (or as a pointer target) that
//      have no canonical owner doc.
//   4. BUDGET + CARD-CAP — shell out to scripts/check-doc-budgets.sh; surface
//      over-budget docs and the card count vs the hard cap of 7.
//
// ── THE HOP MODEL (defined explicitly, never inferred) ───────────────────────
// A "hop" is one canonical-record redirection. We count hops as:
//
//   hop 0 — the Load target file exists AND is NOT a pointer doc. It carries its
//           own `canonical-for: <topic>` and that topic is its own owner. Done.
//   hop 1 — the Load target IS a pointer doc (its body says "Canonical record:
//           `<path>`" or "Canonical guidance …: [..](<path>)", OR its
//           canonical-for ends in `-redirect`/`-pointer`). Follow the named
//           path. If THAT doc is a real, non-pointer owner → resolved at 1 hop.
//   hop 2 — the followed doc is itself a pointer → follow once more. A real
//           owner here resolves at 2 hops.
//   FAIL  — still a pointer after 2 follows (pointer→pointer→pointer), or any
//           link in the chain is missing on disk, or the final doc carries no
//           canonical-for marker.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultCorpus } from "./waterfall.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const ROOT_CLAUDE = "CLAUDE.md";
const BUDGET_SCRIPT = "scripts/check-doc-budgets.sh";
const MAX_HOPS = 2;

// ── routing-table parse ──────────────────────────────────────────────────────
// Pull the `| Group | Task pattern | Load |` rows out of the root CLAUDE.md
// `## Routing table` section. We locate the header row (its three column names),
// skip the `|---|` separator, and read pipe rows until a blank line / non-table
// line ends the block. The Load cell may carry a `§anchor` suffix — we strip to
// the bare file path (and record the original for reporting).
function parseRoutingTable() {
  const abs = join(ROOT, ROOT_CLAUDE);
  const lines = readFileSync(abs, "utf8").split("\n");
  const rows = [];
  let inTable = false;
  for (const line of lines) {
    const isRow = /^\s*\|/.test(line);
    if (!inTable) {
      // header detection: a pipe row naming the three columns
      if (isRow && /\bGroup\b/i.test(line) && /\bTask pattern\b/i.test(line) && /\bLoad\b/i.test(line)) {
        inTable = true;
      }
      continue;
    }
    if (!isRow) break; // table ended
    if (/^\s*\|[\s:|-]+\|\s*$/.test(line)) continue; // |---|---|---| separator
    const cells = splitRow(line);
    if (cells.length < 3) continue;
    const group = cells[0];
    const pattern = cells[1];
    const loadCell = cells[2];
    if (/^group$/i.test(group)) continue; // a re-stated header, skip
    for (const t of loadTargetsFromCell(loadCell)) {
      rows.push({ group, pattern, loadCell, loadTarget: t.path, anchor: t.anchor });
    }
  }
  return rows;
}

// Split a markdown pipe row into trimmed cell strings (drop the leading/trailing
// empty cells produced by the bordering pipes).
function splitRow(line) {
  const parts = line.split("|");
  // first and last are the borders → empties
  return parts.slice(1, -1).map((c) => c.trim());
}

// A Load cell may name MORE than one target (the Meta row lists two slash-joined
// docs). Pull every backtick-wrapped doc path; strip a trailing `§anchor` (and
// any `#anchor`). Returns [{path, anchor|null}].
function loadTargetsFromCell(cell) {
  const out = [];
  const re = /`([^`]+)`/g;
  let m;
  while ((m = re.exec(cell))) {
    const raw = m[1].trim();
    // `api/CLAUDE.md` §Bulldocs → the § may sit OUTSIDE the backticks; the
    // backtick content is just the path here. Strip an inline §/# anchor too.
    let anchor = null;
    let path = raw;
    const sec = path.match(/^(.*?)\s*[§#]\s*(.+)$/);
    if (sec) { path = sec[1].trim(); anchor = sec[2].trim(); }
    if (!path) continue;
    out.push({ path, anchor });
  }
  // also catch a `§Anchor` that trails the backtick (outside it) — attach it to
  // the last target if it has no anchor yet.
  const trailing = cell.match(/`[^`]+`\s*§\s*([A-Za-z0-9_-]+)/);
  if (trailing && out.length && !out[out.length - 1].anchor) {
    out[out.length - 1].anchor = trailing[1];
  }
  return out;
}

// ── doc marker + pointer model ───────────────────────────────────────────────
// Read a doc's line-1 (or first non-front-matter) marker → its canonical-for
// topic + tier. Front-matter (`---` … `---`) is tolerated: we scan the first
// few lines for the `<!-- doc-tier … -->` marker.
function markerOf(relDoc) {
  const abs = join(ROOT, relDoc);
  if (!existsSync(abs)) return null;
  const text = readFileSync(abs, "utf8");
  const lines = text.split("\n");
  // scan a small window for the marker (front-matter may precede it)
  let marker = null;
  for (let i = 0; i < Math.min(lines.length, 12); i++) {
    const m = lines[i].match(/doc-tier:\s*([a-z]+)\s*\|\s*canonical-for:\s*([A-Za-z0-9_-]+)/i);
    if (m) { marker = { tier: m[1].toLowerCase(), topic: m[2] }; break; }
  }
  return marker ? { ...marker, text } : { tier: "unknown", topic: null, text };
}

// Is this doc a POINTER (redirect/signpost), and to WHERE? A pointer is any of:
//   · canonical-for ends in `-redirect` or `-pointer`
//   · a body line "Canonical record: `<path>`" (the redirect-stub form)
//   · a body line "Canonical guidance …: [text](<path>)" (the signpost form)
// Returns { pointer: bool, target: relPath|null }.
function pointerInfo(relDoc, marker) {
  if (!marker) return { pointer: false, target: null };
  const topicSaysPointer =
    marker.topic && (/-(redirect|pointer)$/.test(marker.topic));
  const text = marker.text || "";
  // redirect-stub: Canonical record: `docs/...md`
  let target = null;
  const rec = text.match(/Canonical record:\s*`([^`]+)`/i);
  if (rec) target = rec[1].trim();
  if (!target) {
    // signpost: Canonical guidance …: [api/CLAUDE.md](CLAUDE.md)
    const sign = text.match(/Canonical guidance[^\n]*?\]\(([^)]+)\)/i);
    if (sign) target = resolveRelLink(relDoc, sign[1].trim());
  }
  const isPointer = topicSaysPointer || !!target;
  return { pointer: isPointer, target };
}

// Resolve a markdown link href (possibly doc-relative, possibly with #anchor)
// to a repo-relative path. `CLAUDE.md` inside api/AGENTS.md → api/CLAUDE.md.
function resolveRelLink(fromDoc, href) {
  let h = href.split("#")[0].trim();
  if (!h) return null;
  if (h.startsWith("/")) return h.replace(/^\/+/, "");
  // already repo-relative (starts with a known top dir or contains a slash that
  // resolves from root)?
  if (existsSync(join(ROOT, h))) return h;
  const baseDir = dirname(fromDoc);
  const joined = baseDir === "." ? h : join(baseDir, h);
  return joined;
}

// ── ≤2-hop resolution ────────────────────────────────────────────────────────
// Follow the pointer chain from a Load target to its non-pointer canonical
// owner. Returns { resolved, hops, canonicalOwner|null, chain:[...], failure? }.
function resolve(loadTarget) {
  const chain = [];
  let cur = loadTarget;
  for (let hop = 0; hop <= MAX_HOPS; hop++) {
    if (!cur || !existsSync(join(ROOT, cur))) {
      return {
        resolved: false, hops: hop, canonicalOwner: null, chain,
        failure: `missing doc on disk: ${cur || "(null)"}`,
      };
    }
    const marker = markerOf(cur);
    chain.push(cur);
    const ptr = pointerInfo(cur, marker);
    if (!ptr.pointer) {
      // a real owner — must carry a canonical-for topic
      if (!marker || !marker.topic) {
        return {
          resolved: false, hops: hop, canonicalOwner: null, chain,
          failure: `doc has no canonical-for marker: ${cur}`,
        };
      }
      return {
        resolved: true, hops: hop, chain,
        canonicalOwner: { doc: cur, topic: marker.topic, tier: marker.tier },
      };
    }
    // it's a pointer — follow it (counts as the next hop)
    if (!ptr.target) {
      return {
        resolved: false, hops: hop, canonicalOwner: null, chain,
        failure: `pointer doc names no canonical target: ${cur}`,
      };
    }
    cur = ptr.target;
  }
  // ran out of hops — still pointing after MAX_HOPS follows
  return {
    resolved: false, hops: MAX_HOPS + 1, canonicalOwner: null, chain,
    failure: `pointer chain exceeds ${MAX_HOPS} hops (pointer-of-a-pointer): ${chain.join(" → ")}`,
  };
}

// ── canonical-for index (uniqueness + orphans) ───────────────────────────────
// Scan every corpus doc's marker → topic → [owners]. Duplicate owners violate
// the one-owner-per-topic invariant.
function buildCanonicalIndex(docs) {
  const byTopic = new Map(); // topic -> [doc...]
  for (const d of docs) {
    const m = markerOf(d);
    if (m && m.topic) {
      let arr = byTopic.get(m.topic);
      if (!arr) byTopic.set(m.topic, (arr = []));
      arr.push(d);
    }
  }
  const duplicateOwners = [];
  for (const [topic, owners] of byTopic) {
    if (owners.length > 1) duplicateOwners.push({ topic, owners: [...owners] });
  }
  return { byTopic, duplicateOwners };
}

// ── budget + card-cap (shell out to the repo gate) ───────────────────────────
// Run scripts/check-doc-budgets.sh and parse its per-line `FAIL:`/`ok:` output
// plus the card-count line. We never re-derive budgets; the script is the gate.
function runBudgetCheck() {
  const script = join(ROOT, BUDGET_SCRIPT);
  if (!existsSync(script)) {
    return { ok: false, ran: false, violations: [], cardCount: null, note: `missing ${BUDGET_SCRIPT}` };
  }
  let stdout = "", code = 0;
  try {
    stdout = execFileSync("bash", [script], { cwd: ROOT }).toString();
  } catch (e) {
    code = e.status == null ? 1 : e.status;
    stdout = (e.stdout ? e.stdout.toString() : "") + (e.stderr ? e.stderr.toString() : "");
  }
  const violations = [];
  let cardCount = null;
  for (const line of stdout.split("\n")) {
    const t = line.trim();
    if (t.startsWith("FAIL:")) violations.push(t.slice(5).trim());
    const cc = t.match(/holds\s+(\d+)\s+cards/);
    if (cc) cardCount = parseInt(cc[1], 10);
    if (/card count is exactly 7/.test(t)) cardCount = 7;
  }
  return { ok: code === 0, ran: true, exitCode: code, violations, cardCount };
}

// ── top-level run ────────────────────────────────────────────────────────────
export function runHighways(docsArg) {
  const docs = docsArg && docsArg.length ? docsArg : defaultCorpus();
  const rows = parseRoutingTable();
  const { byTopic, duplicateOwners } = buildCanonicalIndex(docs);

  // resolve each routing row
  const routes = rows.map((r) => {
    const res = resolve(r.loadTarget);
    return {
      group: r.group,
      pattern: r.pattern,
      loadTarget: r.loadTarget,
      anchor: r.anchor || null,
      resolved: res.resolved,
      hops: res.hops,
      canonicalOwner: res.canonicalOwner ? res.canonicalOwner.topic : null,
      ownerDoc: res.canonicalOwner ? res.canonicalOwner.doc : null,
      chain: res.chain,
      failure: res.resolved ? undefined : res.failure,
    };
  });

  // orphans: a topic referenced by a routing row's RESOLVED owner is fine; an
  // UNRESOLVED row whose load target doc carries a canonical-for that has no
  // backing owner is an orphan. More directly: collect topics named anywhere in
  // the routing chain (the load targets' own markers + their pointer targets'
  // markers) that resolve to NO doc with that topic in the index.
  const orphanSet = new Map(); // topic -> reason
  for (const r of routes) {
    // a load target that is itself missing → its intended topic is unknowable;
    // record the path as an orphaned route, not a topic orphan.
    for (const doc of r.chain) {
      const m = markerOf(doc);
      if (m && m.topic && !byTopic.has(m.topic)) {
        orphanSet.set(m.topic, `topic on ${doc} has no owner in the corpus index`);
      }
    }
    if (!r.resolved && r.chain.length === 0) {
      orphanSet.set(`(route:${r.loadTarget})`, r.failure || "load target missing");
    }
  }
  const orphans = [...orphanSet.entries()].map(([topic, reason]) => ({ topic, reason }));

  const budget = runBudgetCheck();

  return { routes, duplicateOwners, orphans, budget, corpusSize: docs.length };
}

// ── reporting ────────────────────────────────────────────────────────────────
function printHuman(res) {
  const bar = "─".repeat(78);
  const out = (s) => process.stdout.write(s);
  out(`\ndoc-truth highways — routing resolution + byte budgets\n${bar}\n`);

  const ok = res.routes.filter((r) => r.resolved).length;
  out(`routing rows: ${res.routes.length} · resolved ${ok}/${res.routes.length} · ≤${MAX_HOPS} hops\n\n`);
  out(`ROUTING RESOLUTION\n`);
  for (const r of res.routes) {
    const mark = r.resolved ? "✓" : "✗";
    const owner = r.resolved
      ? `→ ${r.canonicalOwner} (${r.ownerDoc}, ${r.hops} hop${r.hops === 1 ? "" : "s"})`
      : `→ FAIL: ${r.failure}`;
    out(`  ${mark} [${r.group}] ${trunc(r.pattern, 40)}\n`);
    out(`      ${r.loadTarget}${r.anchor ? " §" + r.anchor : ""}  ${owner}\n`);
  }

  out(`\nDUPLICATE OWNERS (canonical-for on 2+ docs — must be 0)\n`);
  if (res.duplicateOwners.length === 0) out(`  none\n`);
  for (const d of res.duplicateOwners) {
    out(`  ✗ ${d.topic} owned by: ${d.owners.join(", ")}\n`);
  }

  out(`\nORPHANS (topic referenced but no owner doc)\n`);
  if (res.orphans.length === 0) out(`  none\n`);
  for (const o of res.orphans) out(`  ✗ ${o.topic} — ${o.reason}\n`);

  out(`\nBUDGET + CARD-CAP (via ${BUDGET_SCRIPT})\n`);
  if (!res.budget.ran) {
    out(`  not run: ${res.budget.note}\n`);
  } else {
    out(`  budget check: ${res.budget.ok ? "PASS" : "FAIL"} (exit ${res.budget.exitCode})\n`);
    out(`  card count: ${res.budget.cardCount == null ? "?" : res.budget.cardCount} / 7 cap\n`);
    if (res.budget.violations.length === 0) out(`  violations: none\n`);
    for (const v of res.budget.violations) out(`  ✗ ${v}\n`);
  }

  out(`\n${bar}\n`);
}

function trunc(s, n) { return s.length > n ? s.slice(0, n - 1) + "…" : s; }

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const wantJson = argv.includes("--json");
  const res = runHighways();
  if (wantJson) {
    const ok = res.routes.filter((r) => r.resolved).length;
    const out = {
      summary: { routingRows: res.routes.length, resolved: ok, maxHops: MAX_HOPS },
      routes: res.routes.map((r) => ({
        group: r.group, pattern: r.pattern, loadTarget: r.loadTarget, anchor: r.anchor,
        resolved: r.resolved, hops: r.hops, canonicalOwner: r.canonicalOwner,
        ownerDoc: r.ownerDoc, ...(r.failure ? { failure: r.failure } : {}),
      })),
      orphans: res.orphans,
      duplicateOwners: res.duplicateOwners,
      budget: {
        ok: res.budget.ok,
        ran: res.budget.ran,
        violations: res.budget.violations,
        cardCount: res.budget.cardCount,
      },
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
