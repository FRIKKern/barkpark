// stylesheet-applied.test.mjs — the cascade precondition, driven WITHOUT a
// browser (the reason it is a module and not a closure inside overflow-guard).
//
// The two directions that matter are pinned against each other in every test:
// a document with NO cascade must REFUSE, and a document carrying the very
// defect GR115 hunts must NOT refuse — otherwise the remedy for a phantom red
// would be a guard that can no longer report the real one.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  APP_SHEET_RE,
  STYLESHEET_WITNESSES,
  stylesheetProbeJs,
  stylesheetRefusal,
  stylesheetVerdict,
} from "./stylesheet-applied.mjs";

// ── report builders ─────────────────────────────────────────────────────────
// HEALTHY: app.css present with rules, every base witness at its authored value.
const healthy = () => ({
  sheets: [{ href: "http://127.0.0.1:4199/app.css", rules: 1830 }],
  witnesses: STYLESHEET_WITNESSES.map((w) => ({ ...w, got: w.want, found: true })),
  readyState: "complete",
});

// THE REAL GR115 DEFECT: the 720-block declarations lost the cascade. The sheet
// is loaded and every BASE witness is untouched — which is the whole reason
// those witnesses were chosen.
const deadRule = () => healthy();

// NO CASCADE: the document is running on UA defaults.
const uaDefaults = () => ({
  sheets: [],
  witnesses: STYLESHEET_WITNESSES.map((w) => ({ ...w, got: w.ua, found: true })),
  readyState: "complete",
});

test("a healthy document is OK — the leg may compare computed styles", () => {
  assert.equal(stylesheetVerdict(healthy()).kind, "ok");
});

test("the GR115 defect itself does NOT refuse — a dead media rule moves no base witness", () => {
  const v = stylesheetVerdict(deadRule());
  assert.equal(v.kind, "ok", "a cascade-dead 720-block rule must still be reportable as exit 1");
});

test("no /app.css in document.styleSheets refuses, and names the sheets it did see", () => {
  const v = stylesheetVerdict(uaDefaults());
  assert.equal(v.kind, "refuse");
  assert.match(v.reason, /no \/app\.css in document\.styleSheets/);
});

test("a sheet OTHER than app.css does not satisfy the precondition", () => {
  const r = healthy();
  r.sheets = [{ href: "http://127.0.0.1:4199/other.css", rules: 40 }];
  assert.equal(stylesheetVerdict(r).kind, "refuse");
});

test("app.css present but EMPTY refuses — a parsed-to-nothing sheet applies nothing", () => {
  const r = healthy();
  r.sheets = [{ href: "http://127.0.0.1:4199/app.css", rules: 0 }];
  const v = stylesheetVerdict(r);
  assert.equal(v.kind, "refuse");
  assert.match(v.reason, /0 rule\(s\)/);
});

test("app.css present but UNREADABLE (cross-origin, rules -1) refuses as its own cause", () => {
  const r = healthy();
  r.sheets = [{ href: "http://127.0.0.1:4199/app.css", rules: -1 }];
  const v = stylesheetVerdict(r);
  assert.equal(v.kind, "refuse");
  assert.match(v.reason, /cssRules threw \(cross-origin\)/);
  assert.doesNotMatch(v.reason, /rule\(s\) —/, "an unreadable sheet must not be reported as an empty one");
});

test("a sheet with rules but a base witness at its UA default still refuses", () => {
  // The shape a truncated app.css produces: the @font-face preamble parses (so
  // the sheet is present AND non-empty AND the font pin passes), while every
  // rule the console needs is gone.
  const r = healthy();
  r.witnesses[0] = { ...STYLESHEET_WITNESSES[0], got: STYLESHEET_WITNESSES[0].ua, found: true };
  const v = stylesheetVerdict(r);
  assert.equal(v.kind, "refuse");
  assert.match(v.reason, /BASE rule witness/);
  assert.match(v.reason, /exactly the UA default/);
});

test("EVERY declared witness is load-bearing — each one alone forces the refusal", () => {
  for (let i = 0; i < STYLESHEET_WITNESSES.length; i++) {
    const r = healthy();
    r.witnesses[i] = { ...STYLESHEET_WITNESSES[i], got: STYLESHEET_WITNESSES[i].ua, found: true };
    assert.equal(
      stylesheetVerdict(r).kind,
      "refuse",
      `witness ${STYLESHEET_WITNESSES[i].sel} is decoration — flipping it alone changed no verdict`,
    );
  }
  assert.ok(STYLESHEET_WITNESSES.length > 0, "the witness list must not be empty");
});

test("FAIL-CLOSED: a report missing its fields excuses nothing", () => {
  assert.equal(stylesheetVerdict(null).kind, "refuse");
  assert.equal(stylesheetVerdict({}).kind, "refuse");
  assert.equal(stylesheetVerdict({ sheets: [], witnesses: null }).kind, "refuse");
  const r = healthy();
  r.witnesses[0] = { ...STYLESHEET_WITNESSES[0], got: null, found: false };
  const v = stylesheetVerdict(r);
  assert.equal(v.kind, "refuse");
  assert.match(v.reason, /read nothing/);
});

test("APP_SHEET_RE matches the served sheet with or without a query, and nothing else", () => {
  assert.ok(APP_SHEET_RE.test("http://127.0.0.1:4199/app.css"));
  assert.ok(APP_SHEET_RE.test("http://127.0.0.1:4199/app.css?v=2"));
  assert.ok(!APP_SHEET_RE.test("http://127.0.0.1:4199/app.css.map"));
  assert.ok(!APP_SHEET_RE.test("http://127.0.0.1:4199/notapp.css"));
});

test("the probe is an EXPRESSION and carries every witness selector", () => {
  const js = stylesheetProbeJs("host");
  assert.ok(js.startsWith("(function(") && js.endsWith("(host)"), "must be embeddable as `out.css = <expr>`");
  for (const w of STYLESHEET_WITNESSES) assert.ok(js.includes(w.sel), `probe drops ${w.sel}`);
  assert.ok(js.includes("document.readyState"));
});

test("the refusal is textually DISJOINT from a defect line and states exit 2", () => {
  const report = uaDefaults();
  const msg = stylesheetRefusal({
    url: "http://127.0.0.1:4199/?scen=empty&theme=light",
    reason: stylesheetVerdict(report).reason,
    report,
  });
  assert.match(msg, /STYLESHEET NOT APPLIED/);
  assert.match(msg, /ENVIRONMENT refusal \(exit 2\)/);
  assert.match(msg, /NOT a measured CSS defect \(exit 1\)/);
  // The words the leg's own ✗ lines use for the real defect must not appear —
  // a refusal that reads like a finding sends the reader after the wrong cause.
  assert.doesNotMatch(msg, /cascade-dead/);
  assert.doesNotMatch(msg, /legibility floor/);
  assert.match(msg, /cch-w19-bl-gr115-intermittent-ua-defaults/);
});

test("the refusal quotes what it measured, not a summary of it", () => {
  const report = uaDefaults();
  const msg = stylesheetRefusal({ url: "u", reason: "r", report });
  assert.match(msg, /base witnesses: .*\.bp-console-line\{display\}="block"/);
  assert.match(msg, /document\.readyState: complete/);
  const withSheets = stylesheetRefusal({ url: "u", reason: "r", report: healthy() });
  assert.match(withSheets, /app\.css\[1830\]/);
});
