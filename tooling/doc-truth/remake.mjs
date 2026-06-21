#!/usr/bin/env node
// remake.mjs — P5 of doc-truth: "the never-worse remake gate."
//
// P1 (verify-docs.mjs) asks "is each claim TRUE?". P2 (waterfall.mjs) asks "is
// each fact stated ONCE?". P3 (highways.mjs) asks "does the routing table still
// resolve?". P4 (priority.mjs) asks "is doc effort proportioned to reach?". P5
// is the CAPSTONE that USES all four: it gates a proposed doc RESTRUCTURE
// (merge / split / promote / rewrite) and lets it land ONLY if it loses no
// verifiable fact and no outbound link — destructive remakes go to HUMAN
// review, never silent auto-apply.
//
//   node tooling/doc-truth/remake.mjs [--json]   → human-review queue + recent rejects
//
// ── THE GATE (Figure 4 of the plan) ──────────────────────────────────────────
//   proposed remake (beforeText → afterText)
//     → CLAIM DIFF:  extractClaims(before) ⊆ extractClaims(after)?
//          any factKey missing → REJECT (one line to the failure log)
//     → LINK CHECK:  every outbound link / URL / doc-path in before in after?
//          any link broken → REJECT
//     → STRUCTURE:   every H2/H3 that P3's routing/pointers target still present
//          (or intentionally redirected via meta)? a dropped anchor → REJECT
//     → SIZE/TYPE:   merges docs / alters a canonical section / touches a
//          verbatim-exempt or requiresOwnerSignoff region?
//            yes → HUMAN (queue for review; never auto-apply)
//            no (prose/reorder only, all three checks green) → AUTO
//
// CONSERVATIVE, PROPOSE-ONLY. The gate EVALUATES a remake — it never writes a
// doc. Applying an accepted remake is a separate, explicitly-invoked step that
// is OUT OF SCOPE for P5 (propose + gate only, exactly like P2).
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, appendFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { extractClaims, sectionsOf, slugify } from "./verify-docs.mjs";
import { factKeyForClaim } from "./waterfall.mjs";
import { runHighways } from "./highways.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const ROOT_CLAUDE = "CLAUDE.md";
const FAILURE_LOG = join(HERE, "remake-failures.log");

// Sections that are verbatim-exempt per their doc's own contract — the same set
// P2 guards. Any remake touching these MUST route to human review (never auto).
// Keyed by `doc::slug`.
const VERBATIM_EXEMPT = new Set([
  `${ROOT_CLAUDE}::golden-rules`,
  `${ROOT_CLAUDE}::past-mistakes-never-repeat`,
]);

// ── (a) the fact-survival oracle: P1's claim extractor, keyed by factKey ──────
// We hash each extracted claim to its normalized factKey (P2's normalizer) so a
// fact stated two ways before/after still matches — and so a remake that
// rewrites prose but keeps the same anchors is recognised as fact-preserving.
function factKeySet(doc, text) {
  const map = new Map(); // factKey -> a representative raw surface
  for (const c of extractClaims(doc, text)) {
    const fk = factKeyForClaim(c);
    if (!map.has(fk)) map.set(fk, c.raw);
  }
  return map;
}

// ── (b) outbound-link survival ───────────────────────────────────────────────
// Extract every outbound link from a doc: markdown [text](url), bare http(s)
// URLs, and backtick doc-paths (`docs/…`, `api/…`, etc.). Returned as a Set of
// normalized link strings.
const DOC_PATH_TOPDIRS = [
  "docs/", "api/", "tooling/", "js/", "web/", "lib/", "priv/", "deploy/",
  ".github/", "scripts/", "internal/", "docs-site/",
];

export function outboundLinks(text) {
  const links = new Set();
  // markdown links: [text](url)  — keep the href whole (cross-doc path#anchor
  // and bare #anchor both preserved as-is).
  for (const m of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    const href = m[1].trim();
    if (href) links.add(href);
  }
  // bare http(s) URLs.
  for (const m of text.matchAll(/https?:\/\/[^\s)\]`"'<>]+/g)) {
    links.add(m[0]);
  }
  // backtick doc-paths: `docs/ops/PROD_OPS.md`, `api/CLAUDE.md`, etc. Mine from
  // backtick spans only so prose mentions never count as links. We walk line by
  // line and skip ``` fence DELIMITER lines but still scan inline-backtick spans
  // inside a fenced block — an odd fence backtick would otherwise drift the
  // whole-doc pairing (P1's extractSpans uses the same discipline).
  const lines = text.split("\n");
  let inFence = false;
  for (const line of lines) {
    if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
    for (const m of line.matchAll(/`([^`]+)`/g)) {
      const raw = m[1].trim();
      // strip a trailing §/# anchor and any trailing punctuation
      const path = raw.split(/[§#\s]/)[0].replace(/[.,;]+$/, "");
      if (!path.includes("/")) continue;
      if (/^https?:\/\//.test(path)) { links.add(path); continue; }
      if (DOC_PATH_TOPDIRS.some((d) => path.startsWith(d))) links.add(path);
    }
  }
  return links;
}

// ── (c) structure survival: P3's routing/pointer anchor targets ──────────────
// The set of H2/H3 heading slugs in the BEFORE doc that P3 treats as routing or
// pointer targets. We reuse P3's resolved routing chains + every #anchor named
// by the routing table or by a pointer signpost, then intersect with the
// before-doc's own headings (only anchors that LIVE in this doc can be dropped
// by a remake of it).
function routingAnchorTargets(beforePath, beforeText) {
  const sections = sectionsOf(beforeText);
  const ownSlugs = new Set(sections.filter((s) => s.slug).map((s) => s.slug));
  const targeted = new Set();

  // 1. anchors named directly in the root routing table's Load cells (the
  //    `api/CLAUDE.md §Bulldocs` / `docs/x.md#anchor` forms). P3 already parses
  //    these — we re-read its resolved routes for any anchor that points INTO
  //    this doc.
  let highways = null;
  try { highways = runHighways(); } catch { highways = null; }
  if (highways && highways.routes) {
    for (const r of highways.routes) {
      if (!r.anchor) continue;
      // the anchor targets r.loadTarget (or its resolved owner). If that doc IS
      // the before-doc, the anchor is a heading slug this remake could drop.
      const targetsThisDoc =
        r.loadTarget === beforePath || r.ownerDoc === beforePath;
      if (targetsThisDoc) targeted.add(slugify(r.anchor));
    }
  }

  // 2. in-doc #anchor links anywhere in the corpus that point at a heading in
  //    THIS doc — both `#slug` (same-doc) and `before/path#slug` (cross-doc).
  //    We scan the before-doc itself for same-doc anchors (a section that links
  //    to another section is a structural dependency the remake must preserve).
  for (const m of beforeText.matchAll(/\]\(([^)]*#[^)]+)\)/g)) {
    const href = m[1].trim();
    const hash = href.split("#")[1];
    if (!hash) continue;
    const slug = hash.trim();
    if (ownSlugs.has(slug)) targeted.add(slug);
  }

  // only anchors that actually exist as headings in the before-doc are
  // droppable by a remake of it.
  const out = new Set();
  for (const s of targeted) if (ownSlugs.has(s)) out.add(s);
  return { targeted: out, ownSlugs };
}

// ── (d) classification → verdict ─────────────────────────────────────────────
// A remake is HUMAN when it merges docs, alters a canonical section, or touches
// a verbatim-exempt / requiresOwnerSignoff region. Pure prose/reorder with all
// three survival checks green is AUTO-eligible.
function classify(beforePath, beforeText, afterText, meta) {
  const reasons = [];

  // verbatim-exempt / owner-signoff: any section heading in the before-doc that
  // is in the exempt set, OR an explicit meta flag, forces human review.
  const beforeSlugs = sectionsOf(beforeText).filter((s) => s.slug).map((s) => s.slug);
  const touchesExempt = beforeSlugs.some((s) => VERBATIM_EXEMPT.has(`${beforePath}::${s}`));
  if (touchesExempt) reasons.push("touches a verbatim-exempt section (owner sign-off required)");
  if (meta && meta.requiresOwnerSignoff) reasons.push("meta: requiresOwnerSignoff");

  // merges docs: the remake declares it folds another doc in (meta.mergesDocs)
  // OR the canonical structure changed (a top-level # title or doc-tier marker
  // shifted). We detect a structural change by comparing the H2 heading SET.
  if (meta && Array.isArray(meta.mergesDocs) && meta.mergesDocs.length) {
    reasons.push(`merges docs: ${meta.mergesDocs.join(", ")}`);
  }
  const beforeH2 = new Set(sectionsOf(beforeText).filter((s) => s.level === 2).map((s) => s.slug));
  const afterH2 = new Set(sectionsOf(afterText).filter((s) => s.level === 2).map((s) => s.slug));
  const h2Changed =
    beforeH2.size !== afterH2.size ||
    [...beforeH2].some((s) => !afterH2.has(s));
  if (h2Changed) reasons.push("alters the canonical H2 structure");

  return { human: reasons.length > 0, reasons };
}

// ── (e) the gate ─────────────────────────────────────────────────────────────
export function gateRemake({ beforePath, beforeText, afterText, meta }) {
  meta = meta || {};
  const before = factKeySet(beforePath, beforeText);
  const after = factKeySet(beforePath, afterText);

  // CLAIM DIFF — every before factKey must survive in after.
  const lostClaims = [];
  for (const [fk] of before) if (!after.has(fk)) lostClaims.push(fk);

  // LINK CHECK — every before outbound link must survive in after.
  const beforeLinks = outboundLinks(beforeText);
  const afterLinks = outboundLinks(afterText);
  const lostLinks = [];
  for (const l of beforeLinks) if (!afterLinks.has(l)) lostLinks.push(l);

  // STRUCTURE — every routing/pointer anchor target must survive (or be
  // redirected via meta.redirects: { oldSlug: newSlug }).
  const { targeted } = routingAnchorTargets(beforePath, beforeText);
  const afterSlugs = new Set(sectionsOf(afterText).filter((s) => s.slug).map((s) => s.slug));
  const redirects = (meta && meta.redirects) || {};
  const lostAnchors = [];
  let redirectedAnchor = false;
  for (const slug of targeted) {
    if (afterSlugs.has(slug)) continue;
    if (redirects[slug] && afterSlugs.has(redirects[slug])) {
      redirectedAnchor = true; // declared redirect — not a loss, but human-worthy
      continue;
    }
    lostAnchors.push(slug);
  }

  // verdict
  let verdict, reason;
  const cls = classify(beforePath, beforeText, afterText, meta);

  if (lostClaims.length) {
    verdict = "reject";
    reason = `lost ${lostClaims.length} verifiable fact(s): ${lostClaims.slice(0, 5).join(", ")}`;
  } else if (lostLinks.length) {
    verdict = "reject";
    reason = `lost ${lostLinks.length} outbound link(s): ${lostLinks.slice(0, 5).join(", ")}`;
  } else if (lostAnchors.length) {
    verdict = "reject";
    reason = `dropped ${lostAnchors.length} routing anchor(s) with no redirect: ${lostAnchors.join(", ")}`;
  } else if (cls.human || redirectedAnchor) {
    verdict = "human";
    reason = redirectedAnchor && !cls.human
      ? "routing anchor intentionally redirected — human review"
      : cls.reasons.join("; ");
  } else {
    verdict = "auto";
    reason = "prose/reorder only — all survival checks green, no canonical/exempt region touched";
  }

  const result = {
    verdict,
    reason,
    lostClaims,
    lostLinks,
    lostAnchors,
    classification: {
      human: cls.human,
      reasons: cls.reasons,
      routingAnchorsChecked: [...targeted],
      redirectedAnchor,
      beforeFactCount: before.size,
      afterFactCount: after.size,
      beforeLinkCount: beforeLinks.size,
      afterLinkCount: afterLinks.size,
    },
  };

  if (verdict === "reject") logReject(beforePath, reason, meta);
  return result;
}

// ── (f) failure log (transient — gitignored, like simplify-failures.log) ──────
function logReject(doc, reason, meta) {
  const at = (meta && meta.at) || "REMAKE-REJECT";
  const line = `${at}\t${doc}\t${reason}\n`;
  try { appendFileSync(FAILURE_LOG, line); } catch { /* best-effort */ }
}

function readFailureLog() {
  if (!existsSync(FAILURE_LOG)) return [];
  try {
    return readFileSync(FAILURE_LOG, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => {
        const [at, doc, ...rest] = l.split("\t");
        return { at, doc, reason: rest.join("\t") };
      });
  } catch { return []; }
}

// ── reporting (the human-review queue + recent rejects) ───────────────────────
// P5 itself never persists the human queue (the gate is invoked per-proposal by
// a caller, e.g. /paperflow). The CLI shows the recent reject log so an operator
// can see what the gate has been turning away.
function printHuman() {
  const bar = "─".repeat(74);
  const rejects = readFailureLog();
  process.stdout.write(`\ndoc-truth remake — never-worse remake gate (propose-only)\n${bar}\n`);
  process.stdout.write(
    `The gate evaluates a proposed doc restructure (merge/split/promote/rewrite)\n` +
    `and returns auto | human | reject. It NEVER writes a doc. Verbatim-exempt and\n` +
    `canonical-structure remakes route to HUMAN review; fact/link/anchor losses are\n` +
    `REJECTED. Invoke gateRemake({beforePath, beforeText, afterText, meta}) per proposal.\n`);
  process.stdout.write(`\nRECENT REJECTS (from ${FAILURE_LOG.replace(ROOT + "/", "")})\n`);
  if (rejects.length === 0) {
    process.stdout.write(`  none\n`);
  } else {
    for (const r of rejects.slice(-15)) {
      process.stdout.write(`  ✗ [${r.at}] ${r.doc}\n      ${r.reason}\n`);
    }
  }
  process.stdout.write(`${bar}\n`);
}

function printJson() {
  const rejects = readFailureLog();
  const out = {
    gate: "remake",
    proposeOnly: true,
    humanQueue: [], // populated by the caller per-proposal; the gate is stateless
    recentRejects: rejects.slice(-15),
    failureLog: FAILURE_LOG.replace(ROOT + "/", ""),
  };
  process.stdout.write(JSON.stringify(out, null, 2) + "\n");
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const wantJson = process.argv.includes("--json");
  if (wantJson) printJson();
  else printHuman();
  process.exit(0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
