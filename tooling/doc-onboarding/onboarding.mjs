#!/usr/bin/env node
// Doc-Onboarding analyzer — the "Onboarding / Time-to-Value" critic.
// Programmatic half of the Cody 14th dimension. Sibling of doc-truth but orthogonal:
// doc-truth asks "is each statement correct/deduplicated/routed?"; this critic asks
// "does the fastest, lowest-friction path to a first win exist, is it led-with, is it
// sequenced like a smart waterfall, and is it current with shipped features?"
//
//   node tooling/doc-onboarding/onboarding.mjs [--json]
//   → onboarding-report.json + console summary (--json also prints JSON to stdout)
//
// PROGRAMMATIC SIGNALS (six axes → per-doc + aggregate):
//   stepsToFirstWin    — executable commands from cold to first win verb
//   leadOffset         — lines from H1 to first CTA; grade table before CTA flag
//   zeroInstallPath    — live-demo URL presence and CTA-framing check
//   cliCoverage        — shipped Cloud bp commands vs mentioned in onboarding docs
//   featureCurrencyDelta — feat( commits since each doc's last git touch
//   destructiveGuards  — destructive tokens checked for preceding warning/dry-run
//
// AGENT JUDGMENT BATCHES are emitted in agentJudgmentBatches[] so a follow-on
// agent pass can fill in: fastest-path verdict, per-persona dead-end locator,
// materiality weighting, friction-ranking honesty, and tone/pedagogy review.
//
// Pure Node, dependency-free, NO network. Reads fs + git.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const git  = (a, opts = {}) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, ...opts });
const read = (p) => { try { return readFileSync(join(ROOT, p), "utf8"); } catch { return ""; } };
const e    = (s = "") => process.stderr.write(s + "\n");
const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));
const jsonFlag = process.argv.includes("--json");

// ── HARDCODED ONBOARDING SURFACE ─────────────────────────────────────────────
const DOCS = [
  "README.md",
  "docs/setup/CLOUD-QUICKSTART.md",
  "docs/setup/QUICKSTART.md",
  "docs/setup/SETUP.md",
  "docs/setup/WINDOWS.md",
  "docs/setup/TASK-SYSTEM.md",
  "docs/setup/personal-local.md",
  "docs/INDEX.md",
  "docs/PHILOSOPHY.md",
  "docs/cheatsheets/bp.md",
  "docs/cheatsheets/tasks.md",
  "docs/cheatsheets/tui.md",
  "docs/cheatsheets/http-api.md",
  "docs/cheatsheets/papers.md",
  "cloud/README.md",
  "js/README.md",
  "sdk/README.md",
  "api/README.md",
  "web/README.md",
];

// Entry-point docs that should each carry a "which path is mine?" routing signal
const ENTRY_POINT_DOCS = new Set([
  "README.md", "docs/setup/QUICKSTART.md", "docs/setup/SETUP.md",
  "docs/INDEX.md", "cloud/README.md",
]);

// Shipped Cloud bp subcommands (from internal/cli/cli.go case blocks)
const CLOUD_CMDS = ["signup", "login", "subscribe", "launch", "go-live", "barkparks", "doctor"];

// ── REGEXES ───────────────────────────────────────────────────────────────────

// First win verb: reaching this point = first concrete value
const WIN_VERB_RE  = /\bbp\s+task\s+ready\b|\bbp\s+task\s+next\b|\bbp\s+whoami\b|\bbp\s+capabilities\b|curl\s+.*\/api\/schemas/;

// "Get started" CTA heading
const CTA_HEADING_RE = /^#{1,3}\s*(Get started|Install|Quick\s*start|First\s*run|Set up|Setup|Try it|Start here)/im;

// Grade / percentage table: three or more table cells containing a plain integer 50-100
const GRADE_CELL_RE = /\|\s*\*{0,2}\d{2,3}\*{0,2}\s*\|/g;

// Live-demo / zero-install URL
const DEMO_URL_RE     = /https?:\/\/api\.barkpark\.cloud\/studio/i;
// Framed as CTA: heading or imperative imperative sentence nearby
const DEMO_CTA_RE     = /^#{1,3}\s*(Try|Live demo|Demo|Open|Get started)/im;
const DEMO_IMPERATIVE_RE = /\b(try|open|visit|launch|see)\b.{0,50}(demo|studio|live)/i;

// Provisional / unshipped language in onboarding docs
// Provisional = unshipped framing. Note: bare "(wizard)" is NOT provisional —
// it usually just means "via the setup wizard". Only catch it in a ship-marker
// context ("commands marked (wizard)", "(wizard) ship with…").
const PROVISIONAL_RE  = /marked\s*\(wizard\)|\(wizard\)\s*(?:ship|are|will)|against the .{1,50}-branch|\(coming\s*soon\)|\[coming\s*soon\]/gi;

// Genuinely destructive (data-loss) operations inside a code block. Bare `--yes`
// is NOT destructive on its own — it only auto-confirms, which is harmless on
// `connect` / `deploy` / the additive `--profile demo`. The real data-loss case
// is an explicit reset/drop/rm -rf, or a `--target local` apply (which runs
// `mix ecto.reset` under the hood) that is not a `--dry-run` preview.
const CODE_DESTRUCTIVE_RE = /mix\s+ecto\.(reset|drop)|rm\s+-rf/i;
function isDestructiveBlock(t) {
  if (CODE_DESTRUCTIVE_RE.test(t)) return true;
  // `--docker` local setup is isolated compose containers (ephemeral DB, no host
  // data to lose), so it is NOT host-destructive — exclude it.
  return /--target\s+local\b/i.test(t) && /--yes\b/i.test(t) &&
         !/--dry-run\b/i.test(t) && !/--docker\b/i.test(t);
}
function destructiveTrigger(t) {
  const m = t.match(CODE_DESTRUCTIVE_RE);
  return m ? m[0] : "--target local --yes";
}
// Guard words that should PRECEDE a destructive block
const GUARD_RE        = /\bdestructive\b|\bdry.run\b|\bstop\s+(it|the)\s+(dev|server)\b|\bWARNING\b|\bwarning\b|\bcaution\b/i;

// Routing / decision tree signal
const DECISION_TREE_RE = /\b(which|pick|choose|for you|your path|ways in|four ways|two ways|three ways|routes|targets?)\b/i;

// Pricing tiers
const PRICING_RE = /Supporter.*\$69|\$69.*Supporter|Support\+\+.*\$499|\$499.*Support\+\+/i;

// Install / first command line (outside code blocks, or inside)
const INSTALL_CMD_RE  = /^curl\s|^irm\s|^npm\s+install|^brew\s+install|^apt[-\s]/m;

// ── PER-DOC PARSER ────────────────────────────────────────────────────────────
function parseDoc(path) {
  const content  = read(path);
  const exists   = content.length > 0;
  if (!exists) return { path, exists, missing: true };

  const lines = content.split("\n");

  // ── structure: split into alternating prose / code-block segments ──────────
  const segments = [];  // { kind: "prose"|"code", startLine, endLine, text }
  let inFence = false, fenceStart = 0, fenceAcc = [];
  for (let i = 0; i < lines.length; i++) {
    if (!inFence && lines[i].startsWith("```")) {
      if (fenceAcc.length) segments.push({ kind: "prose", startLine: fenceStart, endLine: i, text: fenceAcc.join("\n") });
      inFence = true;
      fenceStart = i;
      fenceAcc  = [];
    } else if (inFence && lines[i].startsWith("```")) {
      segments.push({ kind: "code", startLine: fenceStart, endLine: i, text: fenceAcc.join("\n") });
      inFence   = false;
      fenceStart = i + 1;
      fenceAcc  = [];
    } else {
      fenceAcc.push(lines[i]);
    }
  }
  if (fenceAcc.length) segments.push({ kind: "prose", startLine: fenceStart, endLine: lines.length - 1, text: fenceAcc.join("\n") });

  // ── H1 line ────────────────────────────────────────────────────────────────
  const h1Line = lines.findIndex(l => /^# /.test(l)) + 1;

  // ── first CTA heading line ─────────────────────────────────────────────────
  let ctaLine = 0;
  for (let i = 0; i < lines.length; i++) {
    if (/^#{1,3}\s*(Get started|Install(?!\s+the\s+dep)|Quick\s*start|First\s*run|Setup|Try it|Start here)/i.test(lines[i])) {
      ctaLine = i + 1;
      break;
    }
  }

  // ── grade table BEFORE first CTA ──────────────────────────────────────────
  const preCtaText = lines.slice(0, Math.max(0, ctaLine - 1)).join("\n");
  const gradeCells = (preCtaText.match(GRADE_CELL_RE) || []).length;
  const gradeTableBeforeCta = gradeCells >= 3 && ctaLine > 0;

  // ── first install command (in any code block) ──────────────────────────────
  let installLine = 0;
  for (const seg of segments) {
    if (seg.kind !== "code") continue;
    for (const [idx, ln] of seg.text.split("\n").entries()) {
      if (INSTALL_CMD_RE.test(ln.trimStart())) {
        installLine = seg.startLine + idx + 2; // +1 for fence line, +1 for 1-index
        break;
      }
    }
    if (installLine) break;
  }

  // ── steps to first win: count executable command lines in code blocks up to
  //    the first win-verb occurrence, then stop ──────────────────────────────
  let stepsToFirstWin   = 0;
  let codeBlocksToWin   = 0;
  let winReached        = false;
  for (const seg of segments) {
    if (winReached) break;
    if (seg.kind !== "code") continue;
    const codeLines = seg.text.split("\n");
    const exeLines  = codeLines.filter(l => l.trim() && !l.trim().startsWith("#"));
    if (!exeLines.length) continue;
    codeBlocksToWin++;
    stepsToFirstWin += exeLines.length;
    if (WIN_VERB_RE.test(seg.text)) winReached = true;
  }
  // If we never hit a win verb, cap at 0 (no win path detected)
  if (!winReached) { stepsToFirstWin = 0; codeBlocksToWin = 0; }

  // ── zero-install / live demo ───────────────────────────────────────────────
  const demoPresent   = DEMO_URL_RE.test(content);
  const demoCtaFramed = demoPresent && (DEMO_CTA_RE.test(content) || DEMO_IMPERATIVE_RE.test(content));

  // ── provisional framing flags ─────────────────────────────────────────────
  const provisionalFlags = [];
  let pMatch;
  const pRe = new RegExp(PROVISIONAL_RE.source, "gi");
  while ((pMatch = pRe.exec(content)) !== null) {
    const lineNum = content.slice(0, pMatch.index).split("\n").length;
    provisionalFlags.push({ text: pMatch[0], line: lineNum });
  }

  // ── destructive-step guard check ──────────────────────────────────────────
  //    For each code block containing a destructive pattern, check the PRECEDING
  //    prose segment for a guard word. Warning AFTER the block doesn't count.
  const destructiveBlocks = { guarded: 0, unguarded: 0, details: [] };
  for (let s = 0; s < segments.length; s++) {
    const seg = segments[s];
    if (seg.kind !== "code") continue;
    if (!isDestructiveBlock(seg.text)) continue;
    // Find the immediately preceding prose segment
    const prevProse = s > 0 ? segments.slice(0, s).filter(x => x.kind === "prose").slice(-1)[0] : null;
    const hasGuard  = prevProse ? GUARD_RE.test(prevProse.text) : false;
    const trigger   = destructiveTrigger(seg.text);
    if (hasGuard) destructiveBlocks.guarded++;
    else          destructiveBlocks.unguarded++;
    destructiveBlocks.details.push({
      startLine: seg.startLine + 1,
      trigger: trigger.trim().slice(0, 60),
      guarded: hasGuard,
    });
  }

  // ── Cloud command coverage ────────────────────────────────────────────────
  const cloudCommandsFound = CLOUD_CMDS.filter(cmd => content.includes("bp " + cmd));

  // ── pricing tiers present ─────────────────────────────────────────────────
  const pricingPresent = PRICING_RE.test(content);

  // ── entry-point routing: "which path is mine?" decision tree ─────────────
  const hasDecisionTree = ENTRY_POINT_DOCS.has(path) ? DECISION_TREE_RE.test(content) : null;

  // ── section ordering: demo-data section before setup commands ─────────────
  //    (demo-data / informed-choice before the Local/deploy setup headings)
  const demoDataLine  = lines.findIndex(l => /demo\s*data|profile.*demo|seed.*demo/i.test(l));
  const setupCmdLine  = lines.findIndex(l => /^##?\s+(Local|Deploy|Provision)\b/i.test(l));
  const demoBeforeSetup = (demoDataLine >= 0 && setupCmdLine >= 0) ? (demoDataLine < setupCmdLine) : null;

  return {
    path,
    exists,
    lineCount: lines.length,
    h1Line: h1Line || null,
    ctaLine: ctaLine || null,
    installLine: installLine || null,
    gradeTableBeforeCta,
    gradeCellCount: gradeCells,
    stepsToFirstWin,
    codeBlocksToWin,
    demoPresent,
    demoCtaFramed,
    provisionalFlags,
    destructiveBlocks,
    cloudCommandsFound,
    pricingPresent,
    hasDecisionTree,
    demoBeforeSetup,
  };
}

// ── GIT SIGNALS ───────────────────────────────────────────────────────────────
function lastTouchHash(docPath) {
  try {
    return git(["log", "--format=%H", "-n", "1", "--", docPath]).trim() || null;
  } catch { return null; }
}

function lastTouchDate(docPath) {
  try {
    return git(["log", "--format=%ad", "--date=short", "-n", "1", "--", docPath]).trim() || null;
  } catch { return null; }
}

function countFeatCommitsSince(hash) {
  if (!hash) return null;
  try {
    const log = git(["log", "--oneline", `${hash}..HEAD`]);
    return log.split("\n").filter(l => /^[a-f0-9]+ feat\(/.test(l)).length;
  } catch { return null; }
}

function countCloudFeatCommitsSince(hash) {
  if (!hash) return null;
  try {
    const log = git(["log", "--oneline", `${hash}..HEAD`]);
    return log.split("\n").filter(l => /^[a-f0-9]+ feat\(cloud\)/.test(l)).length;
  } catch { return null; }
}

// ── MAIN ──────────────────────────────────────────────────────────────────────
// Analyze each doc
const docResults = DOCS.map(docPath => {
  const parsed    = parseDoc(docPath);
  const hash      = lastTouchHash(docPath);
  const lastTouch = lastTouchDate(docPath);
  const featDrift      = countFeatCommitsSince(hash);
  const cloudFeatDrift = countCloudFeatCommitsSince(hash);
  return { ...parsed, lastTouch, featDrift, cloudFeatDrift };
});

// ── AGGREGATE SIGNALS ──────────────────────────────────────────────────────────

// Cloud command coverage across the whole onboarding surface
const coveredCloudCmds = new Set(docResults.flatMap(d => d.cloudCommandsFound || []));
const cloudCoverageRatio   = +(coveredCloudCmds.size / CLOUD_CMDS.length).toFixed(2);
const uncoveredCloudCmds   = CLOUD_CMDS.filter(c => !coveredCloudCmds.has(c));

// Cloud README staleness (measured against known commit hash for cloud-7 cloud/README.md last touch)
const cloudReadme = docResults.find(d => d.path === "cloud/README.md");
const cloudReadmeCloudDrift = cloudReadme?.cloudFeatDrift ?? null;

// Total feat(cloud) commits ever
let totalCloudFeatCommits = 0;
try {
  totalCloudFeatCommits = git(["log", "--oneline"]).split("\n")
    .filter(l => /^[a-f0-9]+ feat\(cloud\)/.test(l)).length;
} catch {}

// Zero-install path
const zeroInstallPresent   = docResults.some(d => d.demoPresent);
const zeroInstallCtaFramed = docResults.some(d => d.demoPresent && d.demoCtaFramed);

// Entry points without decision tree
const entryPointsWithoutDecisionTree = docResults
  .filter(d => ENTRY_POINT_DOCS.has(d.path) && d.hasDecisionTree === false)
  .map(d => d.path);

// Unguarded destructive steps
const unguardedDestructive = docResults.flatMap(d =>
  (d.destructiveBlocks?.details || [])
    .filter(x => !x.guarded)
    .map(x => ({ path: d.path, ...x }))
);

// Provisional framing docs
const provisionalDocs = docResults.filter(d => (d.provisionalFlags || []).length > 0);

// Pricing found anywhere in onboarding surface
const pricingInOnboarding = docResults.some(d => d.pricingPresent);

// README stepsToFirstWin (headline number for the banner)
const readmeDoc = docResults.find(d => d.path === "README.md");
const qsDoc     = docResults.find(d => d.path === "docs/setup/QUICKSTART.md");

// ── FINDINGS ──────────────────────────────────────────────────────────────────
const findings = [];

// F1 — inverted pyramid: grade table before first CTA
for (const d of docResults.filter(d => d.gradeTableBeforeCta)) {
  findings.push({
    path: d.path,
    kind: "inverted-pyramid",
    subAxis: "lead-with-value",
    severity: 0.70,
    why: `A grade/percentage table (${d.gradeCellCount} numeric cells) appears before the first CTA at line ${d.ctaLine}. A cold reader must scroll past the repo's self-assessment before reaching the install command.`,
    fix: `Move the grade table below "Get started", or compress to a single badge line. Lead with the value proposition and the install CTA, not the codebase scorecard.`,
  });
}

// F2 — provisional / unshipped framing
for (const d of provisionalDocs) {
  for (const flag of d.provisionalFlags) {
    findings.push({
      path: d.path,
      kind: "provisional-framing",
      subAxis: "pedagogical-waterfall",
      severity: 0.60,
      why: `Provisional language "${flag.text}" (line ${flag.line}) makes a shipped feature read as unreleased, eroding trust in the waterfall.`,
      fix: `Remove or update the stamp. If the feature is shipped, strike the branch/wizard qualifier.`,
    });
  }
}

// F3 — destructive step before guard (wrong reading order)
for (const x of unguardedDestructive) {
  findings.push({
    path: x.path,
    kind: "destructive-without-guard",
    subAxis: "pedagogical-waterfall",
    severity: 0.65,
    why: `Code block containing "${x.trigger}" at line ${x.startLine} — no dry-run/warning found in the immediately preceding prose. A cold reader who follows the doc step-by-step runs the destructive command before seeing the guard.`,
    fix: `Move the "Destructive:" warning paragraph BEFORE the code block it guards, not after. In reading order the caution must precede the command.`,
  });
}

// F4 — Cloud command coverage gap (most severe)
if (uncoveredCloudCmds.length > 0) {
  findings.push({
    path: "cloud/README.md",
    kind: "currency-gap",
    subAxis: "currency-feature-coverage",
    severity: 0.92,
    why: `Barkpark Cloud has shipped ${totalCloudFeatCommits} feat(cloud) PRs (#251–#283: signup/login/subscribe/launch/go-live/barkparks/doctor, Stripe tiers $69/$499, SSE dashboard, site hosting). ${uncoveredCloudCmds.length} of ${CLOUD_CMDS.length} shipped Cloud commands (${uncoveredCloudCmds.map(c => "bp " + c).join(", ")}) have zero mention in any onboarding doc. cloud/README.md is frozen ${cloudReadmeCloudDrift ?? "?"} feat(cloud) commits behind its cloud-7 skeleton.`,
    fix: `Update cloud/README.md with the full signup→login→subscribe→launch→go-live waterfall. Add Cloud commands (bp login, bp launch, bp go-live) to docs/cheatsheets/bp.md. Add a "Barkpark Cloud" section to QUICKSTART.md with a 3-command snippet.`,
  });
}

// F5 — PHILOSOPHY has no operational waterfall behind "bp go-live"
const philDoc = docResults.find(d => d.path === "docs/PHILOSOPHY.md");
// A philosophy doc is not a dead-end if it LINKS readers to where the operational
// steps live (the Cloud README / go-live runbook / Cloud quickstart). Forcing a
// command waterfall into a philosophy doc would be wrong-genre; a pointer resolves it.
const philText = philDoc && philDoc.exists ? read("docs/PHILOSOPHY.md") : "";
const philLinksOps = /\.\.\/cloud\/README|barkpark-cloud-go-live|CLOUD-QUICKSTART/.test(philText);
if (philDoc && philDoc.exists && philDoc.stepsToFirstWin === 0 && philText.includes("bp go-live") && !philLinksOps) {
  findings.push({
    path: "docs/PHILOSOPHY.md",
    kind: "dead-end",
    subAxis: "path-completeness",
    severity: 0.75,
    why: `PHILOSOPHY.md names "bp go-live" as the fastest production path but provides no operational waterfall — no signup, subscribe, or launch step. A motivated reader who follows the "bp go-live" CTA hits a dead end: cloud/README.md is the cloud-7 skeleton, and the go-live runbook lives in docs/ops/ (not linked).`,
    fix: `Link "bp go-live" to a Cloud happy-path section, or inline a 3-command snippet (bp login → bp subscribe → bp launch) directly in PHILOSOPHY.md.`,
  });
}

// F6 — zero-install demo URL not framed as CTA
if (zeroInstallPresent && !zeroInstallCtaFramed) {
  findings.push({
    path: "README.md",
    kind: "passive-demo-link",
    subAxis: "lead-with-value",
    severity: 0.55,
    why: `A live demo URL (https://api.barkpark.cloud/studio) is present but rendered as a passive inline link — not a CTA heading, button, or imperative "Try it" text. A cold reader who wants to explore before installing has no clear signal that zero-install is possible.`,
    fix: `Promote the demo to an imperative CTA: "**Try the live demo →** https://api.barkpark.cloud/studio" as a standalone callout, ideally BEFORE "## Get started".`,
  });
}

// F7 — sdk/ wrong-door naming
const sdkDoc = docResults.find(d => d.path === "sdk/README.md");
if (sdkDoc && sdkDoc.exists) {
  const sdkContent = read("sdk/README.md");
  const isGeneralSdk = /general|javascript sdk|@barkpark\/core|js sdk/i.test(sdkContent.slice(0, 400));
  if (!isGeneralSdk) {
    findings.push({
      path: "sdk/",
      kind: "wrong-door-naming",
      subAxis: "path-completeness",
      severity: 0.50,
      why: `sdk/ is the Bulldocs ingest SDK (PortableDoc/pdrender), not the general @barkpark/core JavaScript SDK (which lives in js/packages/core). A browsing newcomer expecting "the SDK" lands in the wrong codebase and misunderstands the JS integration story.`,
      fix: `Rename sdk/ to sdk-bulldocs/ or bulldocs-sdk/ and add a note in sdk/README.md: "This is the Bulldocs ingest SDK — for the general JavaScript SDK see js/packages/core."`,
    });
  }
}

// F8 — pricing absent from user-facing onboarding surface
if (!pricingInOnboarding) {
  findings.push({
    path: "(onboarding surface)",
    kind: "pricing-absent",
    subAxis: "currency-feature-coverage",
    severity: 0.60,
    why: `Barkpark Cloud ships Supporter ($69/mo) and Support++ ($499/mo) USD tiers. Zero onboarding docs (README, QUICKSTART, PHILOSOPHY, cheatsheets) mention these. A buyer must find the ops runbook (barkpark-cloud-go-live.md) or read source to learn the price.`,
    fix: `Add a pricing line to PHILOSOPHY.md next to the "bp go-live" CTA: "Supporter $69/mo · Support++ $499/mo — cancel anytime." Mirror it in QUICKSTART.md's Cloud section when that section is added.`,
  });
}

// F9 — entry points without decision tree
for (const p of entryPointsWithoutDecisionTree) {
  if (p === "docs/INDEX.md") continue; // INDEX.md is a catalog, not a routing selector
  findings.push({
    path: p,
    kind: "missing-decision-tree",
    subAxis: "path-completeness",
    severity: 0.45,
    why: `${p} is an entry-point doc but lacks a "which path is mine?" routing signal. A cold reader must guess which of the four targets (connect/local/deploy/provision) or which surface (CLI/Studio/TUI/API) is theirs.`,
    fix: `Add a one-paragraph or a short table that disambiguates: "New user → connect to the live demo or use Cloud; self-hoster → local or deploy target; plugin author → from-source (SETUP.md)."`,
  });
}

// ── SCORES (programmatic partial — agent pass refines) ────────────────────────
//
// Each sub-axis scored 0–100 from programmatic signals only.
// Agent pass will adjust; these are the lower-bound floor.

const scores = {
  // time-to-first-value: README happy path = 3 steps is decent; live demo passive link = penalty
  timeToFirstValue: clamp(
    (readmeDoc?.stepsToFirstWin > 0 ? Math.max(0, 80 - (readmeDoc.stepsToFirstWin - 3) * 8) : 45) -
    (zeroInstallPresent && !zeroInstallCtaFramed ? 12 : 0) -
    (entryPointsWithoutDecisionTree.length * 5)
  ),

  // currency-feature-coverage: penalize hard for Cloud gap (most material)
  currencyFeatureCoverage: clamp(
    100 -
    Math.round((1 - cloudCoverageRatio) * 60) -   // Cloud command gap is dominant signal
    (!pricingInOnboarding ? 12 : 0) -
    (cloudReadmeCloudDrift != null ? Math.min(20, cloudReadmeCloudDrift) : 10)
  ),

  // lead-with-value: grade table before CTA is the headline failure here
  leadWithValue: clamp(
    100 -
    (docResults.some(d => d.gradeTableBeforeCta) ? 30 : 0) -
    (zeroInstallPresent && !zeroInstallCtaFramed ? 15 : 0) -
    (entryPointsWithoutDecisionTree.filter(p => p !== "docs/INDEX.md").length * 10)
  ),

  // pedagogical-waterfall: provisional stamps + unguarded destructive steps
  pedagogicalWaterfall: clamp(
    100 -
    provisionalDocs.reduce((acc, d) => acc + d.provisionalFlags.length * 15, 0) -
    unguardedDestructive.length * 20
  ),

  // path-completeness: PHILOSOPHY dead-end (Cloud buyer) + wrong-door naming
  pathCompleteness: clamp(
    100 -
    (findings.some(f => f.kind === "dead-end") ? 35 : 0) -
    (findings.some(f => f.kind === "wrong-door-naming") ? 12 : 0) -
    (findings.some(f => f.kind === "currency-gap") ? 18 : 0)
  ),
};

// Weights from the rubric charter
const WEIGHTS = {
  timeToFirstValue:        0.28,
  currencyFeatureCoverage: 0.24,
  leadWithValue:           0.18,
  pedagogicalWaterfall:    0.18,
  pathCompleteness:        0.12,
};

const overallScore = clamp(
  Object.entries(WEIGHTS).reduce((sum, [k, w]) => sum + scores[k] * w, 0)
);

// ── AGENT JUDGMENT BATCHES ─────────────────────────────────────────────────────
// Emitted for a follow-on agent pass. Each batch targets one sub-axis.
const agentJudgmentBatches = [
  {
    subAxis: "time-to-first-value",
    question: "Is the path presented first (curl | sh → bp setup → bp task ready, ~3 steps) actually the fastest available, or does the zero-install live demo at https://api.barkpark.cloud/studio offer a lower-friction route that is never framed as a path?",
    verdictDimensions: ["well/partially/poorly per persona: OSS self-hoster · Cloud buyer · API integrator · plugin author", "First concrete point where each persona's next step becomes undiscoverable"],
  },
  {
    subAxis: "currency-feature-coverage",
    question: `Materiality of the Cloud command gap: ${uncoveredCloudCmds.map(c => "bp " + c).join(", ")} have zero onboarding coverage. Which of these BLOCKS first value (e.g. bp login gates the entire Cloud happy path) vs nice-to-have? Rate each missing command as blocks-first-value / degrades-experience / nice-to-have.`,
    verdictDimensions: ["Materiality tier per gap", "Whether cloud/README.md being ~21 feat(cloud) PRs behind constitutes an infinite time-to-first-value for the Cloud persona"],
  },
  {
    subAxis: "lead-with-value",
    question: "The README leads with a 13-critic, 24-cell self-grade table before the 'Get started' CTA. Does the live-demo link (inline, line 6) partially redeem the lead, or does the dominant first impression remain the codebase scorecard? Are the four 'ways in' (CLI/Studio/TUI/API) usefully disambiguated for a cold reader?",
    verdictDimensions: ["Inverted-pyramid severity (minor/notable/severe)", "Whether the four surfaces are friction-ranked or presented as equivalent choices"],
  },
  {
    subAxis: "pedagogical-waterfall",
    question: "QUICKSTART.md says 'Written 2026-06-10 against the premium-setup branch' (line 4). Does this make the entire QUICKSTART read as unshipped, or does the subsequent content redeem it? Also: does the 'Destructive: runs mix ecto.reset' warning landing AFTER the --yes command constitute a real safety risk for a newcomer, or is the --dry-run mention on a different line sufficient?",
    verdictDimensions: ["Provisional-stamp trust impact (none/minor/trust-eroding)", "Destructive-order risk (cosmetic/real)"],
  },
  {
    subAxis: "path-completeness",
    question: "Trace the Cloud buyer's path end-to-end: PHILOSOPHY.md names bp go-live but links nowhere. docs/ops/barkpark-cloud-go-live.md exists. Is that path discoverable from the onboarding surface, or is the Cloud persona's next step genuinely undiscoverable from README/QUICKSTART/PHILOSOPHY? Also: does sdk/ being the Bulldocs ingest SDK (not the JS SDK) realistically confuse a browsing newcomer?",
    verdictDimensions: ["Cloud persona: path exists / buried / dead-end", "sdk/ wrong-door risk: high / low / not an issue"],
  },
];

// ── REPORT ─────────────────────────────────────────────────────────────────────
const summary = {
  overallScore,
  scores,
  weights: WEIGHTS,
  docsAnalyzed: DOCS.length,
  docsMissing: docResults.filter(d => d.missing).length,
  // time-to-first-value
  readmeStepsToFirstWin: readmeDoc?.stepsToFirstWin ?? null,
  qsStepsToFirstWin:     qsDoc?.stepsToFirstWin ?? null,
  zeroInstallPresent,
  zeroInstallCtaFramed,
  // currency
  shippedCloudCommands:  CLOUD_CMDS,
  coveredCloudCommands:  [...coveredCloudCmds],
  uncoveredCloudCommands: uncoveredCloudCmds,
  cloudCoverageRatio,
  cloudReadmeCloudDrift,
  totalCloudFeatCommits,
  pricingInOnboarding,
  // lead-with-value
  docsWithGradeTableBeforeCta: docResults.filter(d => d.gradeTableBeforeCta).map(d => d.path),
  entryPointsWithoutDecisionTree,
  // pedagogical-waterfall
  provisionalDocs: provisionalDocs.map(d => ({ path: d.path, flags: d.provisionalFlags })),
  unguardedDestructiveSteps: unguardedDestructive.length,
  unguardedDestructive,
  // path-completeness
  wrongDoorNaming: findings.filter(f => f.kind === "wrong-door-naming").map(f => f.path),
};

const out = {
  at:              new Date().toISOString(),
  dimensionName:   "Onboarding / Time-to-Value",
  overallScore,
  scores,
  summary,
  docs:            docResults,
  findings,
  agentJudgmentBatches,
};

writeFileSync(join(HERE, "onboarding-report.json"), JSON.stringify(out, null, 2));

// ── CONSOLE SUMMARY ────────────────────────────────────────────────────────────
e(`\n  ONBOARDING / TIME-TO-VALUE  (programmatic pass — agent judgment needed for final)`);
e(`    Overall (weighted)    ${String(overallScore).padStart(3)}`);
e(`    time-to-first-value   ${String(scores.timeToFirstValue).padStart(3)}  README: ${readmeDoc?.stepsToFirstWin ?? "?"} steps to win · zero-install demo: ${zeroInstallPresent ? (zeroInstallCtaFramed ? "CTA ✓" : "passive (not CTA)") : "absent"}`);
e(`    currency-coverage     ${String(scores.currencyFeatureCoverage).padStart(3)}  Cloud cmd coverage ${Math.round(cloudCoverageRatio * 100)}% (${coveredCloudCmds.size}/${CLOUD_CMDS.length}) · cloud/README ${cloudReadmeCloudDrift ?? "?"} feat(cloud) PRs stale`);
e(`    lead-with-value       ${String(scores.leadWithValue).padStart(3)}  grade table before CTA: ${docResults.filter(d => d.gradeTableBeforeCta).map(d => d.path).join(", ") || "none"}`);
e(`    pedagogical-waterfall ${String(scores.pedagogicalWaterfall).padStart(3)}  provisional stamps: ${provisionalDocs.length} doc(s) · unguarded destructive: ${unguardedDestructive.length}`);
e(`    path-completeness     ${String(scores.pathCompleteness).padStart(3)}  entry-points w/o decision tree: ${entryPointsWithoutDecisionTree.length} · wrong-door naming: ${findings.filter(f => f.kind === "wrong-door-naming").length}`);
e(`    findings: ${findings.length} total — ${findings.map(f => f.kind).join(", ")}`);
e(`  → tooling/doc-onboarding/onboarding-report.json  (${docResults.length} docs analyzed)`);
e(`  → Highest-leverage fix: ${findings.sort((a, b) => b.severity - a.severity)[0]?.fix?.slice(0, 90) ?? "n/a"}`);

if (jsonFlag) process.stdout.write(JSON.stringify(out, null, 2) + "\n");
