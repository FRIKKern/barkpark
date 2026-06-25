#!/usr/bin/env node
// Unit proof for the SAFETY CLASSIFIER that makes Cody's god-module split ranking
// RISK-AWARE (tooling/ergonomics/ergonomics.mjs → classifySafety).
//
//   node tooling/ergonomics/safety-classifier.test.mjs
//
// The classifier is a PURE, DETERMINISTIC fn of (path, churn, contract) — no I/O,
// no git, no deps — so the test imports it directly and asserts every branch. The
// CRUX it guards: a prod module must NEVER read "safe"; a test file must NEVER read
// "prod". A wrong label mis-guides a dangerous refactor, so we ground-truth against
// the REAL candidates (onixedit/indexer = prod, the test files = test, tui.go/
// api_tester = cli-tool, plugin.ex = contract) plus the churn overlay.

import { classifySafety, CHURN_HOT } from "./ergonomics.mjs";

let fails = 0;
const ok = (cond, msg) => { if (cond) { console.log(`  ✓ ${msg}`); } else { console.log(`  ✗ ${msg}`); fails++; } };
const safetyOf = (p, churn = 0, contract = false) => classifySafety(p, churn, contract).safety;

// ── 1. the four categories — ground-truthed against the REAL repo candidates ──
console.log("CATEGORY: contract (cb>=3 → DO NOT split)");
ok(safetyOf("api/lib/barkpark/plugin.ex", 40, true) === "contract", "plugin.ex (contract=true) → contract");
ok(safetyOf("api/lib/barkpark/plugins/onixedit.ex", 47, true) === "contract", "contract flag WINS over a prod path (a @callback prod module is still 'contract')");

console.log("CATEGORY: test (test tree → SAFE, zero prod risk)");
ok(safetyOf("api/test/barkpark_web/live/studio/studio_live_paper_canvas_test.exs", 11) === "test", "studio *_test.exs → test (#223)");
ok(safetyOf("api/assets/paper-editor/src/__smoke.mjs", 27) === "test", "__smoke.mjs → test (#219)");
ok(safetyOf("internal/cli/cli_test.go", 10) === "test", "internal/cli/cli_test.go → test (test pattern beats cli-tool path)");
ok(safetyOf("api/assets/paper-editor/src/__wikilink.test.mjs", 3) === "test", "*.test.mjs → test");
ok(safetyOf("web/components/finder.test.tsx", 5) === "test", "*.test.tsx → test");
ok(safetyOf("api/test/some/feature/spec/thing.exs", 2) === "test", "/spec/ tree → test");

console.log("CATEGORY: cli-tool (off the served request path → LOW risk)");
ok(safetyOf("cmd/barkpark/tui.go", 7) === "cli-tool", "cmd/barkpark/tui.go → cli-tool (#222)");
ok(safetyOf("api/lib/barkpark/api_tester/endpoints.ex", 34) === "cli-tool", "api_tester/endpoints.ex → cli-tool (#220)");
ok(safetyOf("internal/cli/run.go", 9) === "cli-tool", "internal/cli/run.go → cli-tool");
ok(safetyOf("tooling/quality/quality.mjs", 12) === "cli-tool", "tooling/ → cli-tool (dev tool)");
ok(safetyOf("bin/paperflow-target", 3) === "cli-tool", "bin/ → cli-tool");
ok(safetyOf("scripts/install-cli.sh", 4) === "cli-tool", "scripts/ → cli-tool");

console.log("CATEGORY: prod (live application code → CARE)");
ok(safetyOf("api/lib/barkpark/plugins/onixedit.ex", 47) === "prod", "onixedit.ex (live prod-API, NOT contract) → prod");
ok(safetyOf("api/lib/barkpark/plugins/indx/indexer.ex", 17) === "prod", "indexer.ex → prod");
ok(safetyOf("web/components/finder.tsx", 36) === "prod", "web/ prod component → prod");
ok(safetyOf("js/sdk/src/client.ts", 8) === "prod", "js/ published src → prod");
ok(safetyOf("api/lib/barkpark/content.ex", 182) === "prod", "api/lib serving path → prod");

// ── 2. the CRUX — no misclassification across the danger boundary ─────────────
console.log("CRUX: no prod↔test / prod↔safe misclassification");
ok(safetyOf("api/lib/barkpark/plugins/onixedit.ex", 47) !== "test", "a prod module is NEVER 'test'");
ok(safetyOf("api/lib/barkpark/plugins/onixedit.ex", 47) !== "cli-tool", "a prod module is NEVER 'cli-tool'");
ok(safetyOf("api/test/barkpark_web/live/studio/studio_live_paper_canvas_test.exs", 11) !== "prod", "a test file is NEVER 'prod'");
ok(safetyOf("cmd/barkpark/tui.go", 7) !== "prod", "a cli-tool is NEVER 'prod'");

// ── 3. the CHURN overlay (orthogonal to category) ────────────────────────────
console.log(`CHURN OVERLAY: churn > ${CHURN_HOT} ⇒ "high-churn — conflict risk" note, category unchanged`);
const hotProd = classifySafety("api/lib/barkpark/plugins/onixedit.ex", 47);
ok(hotProd.safety === "prod", "high-churn prod stays category 'prod' (overlay does not change the label)");
ok(/high-churn/.test(hotProd.safetyNote), "churn 47 (> 30) note carries 'high-churn — conflict risk'");
const coolProd = classifySafety("api/lib/barkpark/plugins/indx/indexer.ex", 17);
ok(!/high-churn/.test(coolProd.safetyNote), "churn 17 (≤ 30) note has NO high-churn overlay");
const hotCli = classifySafety("api/lib/barkpark/api_tester/endpoints.ex", 34);
ok(hotCli.safety === "cli-tool" && /high-churn/.test(hotCli.safetyNote), "churn 34 cli-tool gets the overlay but stays 'cli-tool'");
ok(CHURN_HOT === 30, "CHURN_HOT threshold is 30");

// ── 4. determinism (same input → same output, no I/O) ─────────────────────────
console.log("DETERMINISM: pure fn, repeatable");
ok(JSON.stringify(classifySafety("api/lib/barkpark/plugins/onixedit.ex", 47)) === JSON.stringify(classifySafety("api/lib/barkpark/plugins/onixedit.ex", 47)), "identical input → identical output");

console.log(fails === 0 ? "\nPASS — classifier correct across the 4 categories + churn overlay + the crux." : `\nFAIL — ${fails} assertion(s) failed.`);
process.exit(fails === 0 ? 0 : 1);
