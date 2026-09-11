// type-floor.test.mjs — the floor's own unit harness.
//
// Two halves, deliberately separated:
//
//   (A) THE PARSER, against hand-written fixtures. Every clause below exists
//       because a naive parse gets it wrong: the `font:` shorthand carries a
//       size the filing row's `grep -cE 'font-size:'` census could not see;
//       @media-nested rules are declarations too; a comment containing
//       `font-size: 8px` is not a declaration; `var()` chains bottom out at
//       :root; and anything the parse CANNOT resolve must surface in
//       `.unresolved` rather than be counted clean.
//
//   (B) THE ARTIFACT, against the real app.css. This is the assertion that
//       turns the floor into an instrument. It is ALSO run from __app.test.mjs
//       so the repo-wide unit gate reds on a regression, but it lives here too
//       because this is the file a person edits when they change the floor.
//
// The allowlist tests are the D180 half: a committed literal, and a stale
// entry is FATAL rather than a console.log.
//
// Run: node --test cloud/priv/static/__preview__/type-floor.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";

import {
  APP_CSS,
  FLOOR_PX,
  ALLOWLIST,
  audit,
  blankComments,
  fontShorthandSize,
  fontSizeDeclarations,
  resolvePx,
  rootVars,
} from "./type-floor.mjs";

// ── (A) the parser ──────────────────────────────────────────────────────────

test("blankComments preserves byte offsets and newlines", () => {
  const css = "a{}\n/* x\ny */\nb{}";
  const out = blankComments(css);
  assert.equal(out.length, css.length);
  assert.equal(out.split("\n").length, css.split("\n").length);
  assert.ok(!out.includes("x"));
});

test("a comment is not a declaration", () => {
  const css = ":root{--text-xs:12px}\n/* font-size: 8px is what it used to be */\n.a{color:red}";
  assert.equal(fontSizeDeclarations(css).length, 0);
});

test("the `font:` shorthand carries a size, and `font: inherit` does not", () => {
  assert.equal(fontShorthandSize("600 11px var(--font)"), "11px");
  assert.equal(fontShorthandSize("12px/1.55 var(--mono)"), "12px");
  assert.equal(fontShorthandSize("var(--text-xs)/1.4 var(--mono)"), "var(--text-xs)");
  assert.equal(fontShorthandSize("inherit"), null);
});

test("the shorthand is audited exactly like font-size — the grep census could not see it", () => {
  const css = ":root{--text-xs:12px}\n.deploy-console-toggle{font: 600 11px var(--font);}";
  const r = audit(css, { allowlist: [] });
  assert.equal(r.violations.length, 1);
  assert.equal(r.violations[0].prop, "font");
  assert.equal(r.violations[0].px, 11);
  assert.equal(r.violations[0].selector, ".deploy-console-toggle");
});

test("rules inside @media are parsed, and the @media is reported", () => {
  const css = ":root{--text-xs:12px}\n@media (max-width: 720px){ .a{font-size:9px} }";
  const r = audit(css, { allowlist: [] });
  assert.equal(r.violations.length, 1);
  assert.equal(r.violations[0].selector, ".a");
  assert.match(r.violations[0].media, /max-width: 720px/);
});

test("var() chains resolve through :root; rem resolves at 16", () => {
  const vars = rootVars(":root{--text-xs:12px;--tiny:var(--text-xs)}");
  assert.equal(resolvePx("var(--tiny)", vars).px, 12);
  assert.equal(resolvePx("0.5rem", vars).px, 8);
  assert.equal(resolvePx("11.5px", vars).px, 11.5);
});

test("what cannot be resolved is NAMED, never counted clean", () => {
  const css = ":root{--text-xs:12px}\n.a{font-size:0.8em}\n.b{font-size:calc(1px + 1px)}\n.c{font-size:var(--nope)}\n.d{font-size:smaller}";
  const r = audit(css, { allowlist: [] });
  assert.equal(r.violations.length, 0, "an unresolvable value is not a violation");
  assert.equal(r.unresolved.length, 4);
  for (const u of r.unresolved) assert.ok(u.why && u.why.length > 10, `no reason for ${u.selector}`);
  assert.match(r.unresolved.find((u) => u.selector === ".c").why, /not declared at :root/);
});

// ── the allowlist contract (D180) ───────────────────────────────────────────

test("the allowlist is a committed LITERAL — it does not read app.css", () => {
  const src = fs.readFileSync(new URL("./type-floor.mjs", import.meta.url), "utf8");
  const decl = src.slice(src.indexOf("export const ALLOWLIST"), src.indexOf("// ── parse"));
  assert.ok(!/readFileSync|APP_CSS|\.filter\(|\.map\(/.test(decl),
    "ALLOWLIST must be typed out, never derived from the artifact it exempts (D180)");
  assert.ok(ALLOWLIST.length >= 1);
});

test("every allowlist entry names ONE selector and carries its OWN written reason", () => {
  for (const a of ALLOWLIST) {
    assert.equal(typeof a.selector, "string");
    assert.ok(!a.selector.includes(","), `${a.selector}: a class waiver is not an entry`);
    assert.equal(typeof a.px, "number");
    assert.ok(a.px < FLOOR_PX, `${a.selector}: an entry at or above the floor exempts nothing`);
    assert.ok(typeof a.reason === "string" && a.reason.length >= 80,
      `${a.selector}: the reason must argue this site, not gesture at a class`);
    assert.ok(typeof a.where === "string" && a.where.length > 0);
  }
  const keys = ALLOWLIST.map((a) => `${a.selector}@${a.px}`);
  assert.equal(new Set(keys).size, keys.length, "duplicate allowlist entries");
});

test("a STALE allowlist entry is FATAL, not a console.log (D180's named anti-pattern)", () => {
  const css = ":root{--text-xs:12px}\n.real{font-size:10px}";
  const good = audit(css, { allowlist: [{ selector: ".real", px: 10, where: "w", reason: "r" }] });
  assert.equal(good.errors.length, 0);

  const bogus = audit(css, {
    allowlist: [
      { selector: ".real", px: 10, where: "w", reason: "r" },
      { selector: ".this-rule-does-not-exist", px: 10, where: "w", reason: "r" },
    ],
  });
  assert.equal(bogus.violations.length, 0, "the bogus entry must not be a BELOW-FLOOR finding");
  assert.equal(bogus.stale.length, 1);
  assert.equal(bogus.errors.length, 1, "a stale entry must reach errors, exactly as a violation does");
  assert.match(bogus.errors[0], /STALE ALLOWLIST ENTRY/);
});

test("an entry whose site CHANGED SIZE goes stale rather than silently re-blessing it", () => {
  const css = ":root{--text-xs:12px}\n.real{font-size:6px}";
  const r = audit(css, { allowlist: [{ selector: ".real", px: 10, where: "w", reason: "r" }] });
  assert.equal(r.violations.length, 1, "6px is not the 10px that was argued for");
  assert.equal(r.stale.length, 1, "and the 10px entry now matches nothing");
});

// ── (B) the artifact ────────────────────────────────────────────────────────

test("app.css: no declaration resolves below the floor outside the literal allowlist", () => {
  const r = audit(fs.readFileSync(APP_CSS, "utf8"));
  assert.deepEqual(r.errors, [],
    `type-floor: app.css breaks the ${FLOOR_PX}px legibility floor.\n` + r.errors.join("\n"));
});

test("app.css: the audit is not vacuous — it parses a real stylesheet and resolves it", () => {
  // A parse defeated by a rename would report zero declarations and go green on
  // everything above. The floor is only an instrument while it is still reading.
  const r = audit(fs.readFileSync(APP_CSS, "utf8"));
  assert.ok(r.decls.length > 200, `only ${r.decls.length} font-size declarations parsed — the parse is DEFEATED`);
  assert.ok(r.decls.some((d) => d.prop === "font"), "the `font:` shorthand arm read nothing");
  assert.ok(r.resolved.length > 200, `only ${r.resolved.length} resolved to px`);
  assert.ok(r.below.length >= ALLOWLIST.length,
    "fewer below-floor declarations than allowlist entries — the allowlist has gone stale wholesale");
});

test("app.css: the mutation this floor exists to catch — .instance-card-stat-k below the floor — REDS", () => {
  // The charter's own proof shape (D240): 10px -> 6px on the front screen's
  // CPU/RAM/DISK/DOCS legend left __css_check at 0 errors, the unit suite
  // unchanged and overflow-guard at 28/28 clean. It must not leave THIS green.
  const css = fs.readFileSync(APP_CSS, "utf8");
  const mutated = css.replace(
    /\.instance-card-stat-k \{ font-family: var\(--mono\); font-size: var\(--text-xs\);/,
    ".instance-card-stat-k { font-family: var(--mono); font-size: 6px;",
  );
  assert.notEqual(mutated, css, "the mutation did not apply — this test is measuring nothing");
  const r = audit(mutated);
  assert.equal(r.violations.length, 1);
  assert.equal(r.violations[0].selector, ".instance-card-stat-k");
  assert.equal(r.violations[0].px, 6);
});
