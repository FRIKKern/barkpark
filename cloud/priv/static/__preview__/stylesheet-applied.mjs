// stylesheet-applied.mjs — THE CASCADE PRECONDITION for any leg that judges a
// COMPUTED STYLE rather than a geometry.
//
// ── THE RUN THIS EXISTS FOR (cch-w19-bl-gr115-intermittent-ua-defaults) ──────
// console-harness run 30714372486 (ubuntu-latest, head 35908a194) reported
// EIGHT findings where the deliberate mutation could only produce two. The
// other six were all GR115, and every one of them is a UA DEFAULT:
//
//     ✗ .bp-console-body max-height computes none, expected 320px
//     ✗ .bp-console-body font-size computes 16px, expected 13px
//     ✗ .bp-console-toggle font-size computes 13.3333px, expected 13px
//     ✗ .new-console twin regressed: max-height none font-size 16px
//     ✗ .bp-console.is-collapsed .bp-console-toggle border-bottom is outset/2px
//     ✗ .bp-console.is-collapsed caret transform is "none"
//
// `none` / `16px` / `13.3333px` (the UA's button font) / `outset 2px` (the UA's
// button border) / `none` are not a cascade-order defect inside a media block.
// They are the computed styles of a document to which app.css HAS NOT APPLIED.
// The control run 30714465001, byte-identical content on the same runner,
// printed GR115 clean — so the guard reported a CSS defect (exit 1) about a
// moment in which it had no stylesheet to measure.
//
// ── WHY THE EXISTING GATES DO NOT CLOSE IT ──────────────────────────────────
// Both of nav()'s post-readiness gates were written for a different fault, and
// each was added AFTER the red run (font-pin.mjs 2026-08-02 #9101,
// ready-host-paint.mjs 2026-08-24 #13617 / 2026-09-01 #14630 — the red run's
// tree at 35908a194 had NEITHER):
//   • the FONT PIN asks `document.fonts`, i.e. whether the @font-face BLOCKS
//     registered. It is a real interception of the total-absence case — with
//     the <link> deleted from index.html it refuses at exit 2 today — but a
//     face is registered by PARSING a sheet, never by that sheet WINNING a
//     cascade, so it says nothing about whether a rule reached an element.
//   • the RENDERED-HOST FLOOR asks whether the leg's readiness selector paints
//     a box. `.topbar` without app.css is a plain block with children: it
//     paints, so the floor passes on an unstyled document by construction.
// Neither is a statement about the CASCADE, which is the only thing a leg
// asserting `getComputedStyle(...) === "13px"` is entitled to assume.
//
// ── THE PREDICATE, AND WHY IT CANNOT SWALLOW A REAL DEFECT ──────────────────
// Two questions, both answered in the SAME evaluate as the measurement (a
// second round trip would judge a different moment than the one it excuses —
// ready-host-paint.mjs learnt that the expensive way):
//   (1) is a sheet whose href is /app.css in `document.styleSheets`, with a
//       readable, NON-EMPTY rule list;
//   (2) do the BASE witnesses below still compute their authored values.
// The witnesses are chosen so that the defect the leg hunts CANNOT move them:
// GR115 is about `@media (max-width: 720px)` declarations losing the cascade to
// the later base rules at equal specificity, and every witness here is a BASE
// declaration outside that block, asserted by no GR115 criterion. A tree with
// the dead rule fully restored, and a tree with it dead, produce IDENTICAL
// witness readings — measured both ways. So a real GR115 defect still exits 1;
// only a document with no cascade at all refuses.
//
// FAIL-CLOSED: a report missing any field it is judged on refuses. This can
// only ever turn a defect claim into a refusal — never the reverse.

// Each witness is a BASE rule in app.css (never inside the 720 block), present
// in the GR115 fixture markup, and asserted by no criterion in that leg. `ua`
// is what the property computes to with NO author stylesheet — it is quoted in
// the refusal so the reader sees the discrimination rather than being told it.
export const STYLESHEET_WITNESSES = [
  // app.css: `.bp-console-line { display: flex; … }`
  { sel: ".bp-console-line", prop: "display", want: "flex", ua: "block" },
  // app.css: `.bp-console-caret { … border-top: 6px solid currentColor; … }`
  { sel: ".bp-console-caret", prop: "borderTopWidth", want: "6px", ua: "0px" },
];

// The href test. `document.styleSheets[i].href` is absolute, and the preview
// server may serve the sheet with a cache-buster, so match the PATH tail.
export const APP_SHEET_RE = /\/app\.css(?:[?#].*)?$/;

// THE BROWSER PROBE, as an EXPRESSION (not a statement block) so a leg can
// evaluate it inside the object it is already building — `out.css = <this>` —
// and the cascade fact is read in the same round trip as the pixels it guards.
// `rootExpr` is the element the witnesses are queried under; pass the leg's own
// fixture host so the witnesses are the very nodes about to be measured.
export function stylesheetProbeJs(rootExpr = "document") {
  return (
    `(function(root){` +
    `var sheets=[].slice.call(document.styleSheets).map(function(s){` +
    // A cross-origin sheet throws on .cssRules. -1 says "present but unreadable",
    // which is NOT the same as 0 and must not be reported as an empty sheet.
    `var n=null;try{n=s.cssRules?s.cssRules.length:0;}catch(e){n=-1;}` +
    `return {href:String(s.href||"(inline)"),rules:n};});` +
    `var w=${JSON.stringify(STYLESHEET_WITNESSES)}.map(function(x){` +
    `var el=root&&root.querySelector?root.querySelector(x.sel):null;` +
    `var got=null;try{got=el?String(getComputedStyle(el)[x.prop]):null;}catch(e){got=null;}` +
    `return {sel:x.sel,prop:x.prop,want:x.want,ua:x.ua,got:got,found:!!el};});` +
    `return {sheets:sheets,witnesses:w,readyState:document.readyState};})(${rootExpr})`
  );
}

// PURE VERDICT over one probe report. `ok` means a leg may compare computed
// styles; anything else is an ENVIRONMENT refusal (exit 2), never a defect.
//
// The order of the clauses is the order a reader should think in: is there a
// stylesheet at all, is it readable, did it reach these elements.
export function stylesheetVerdict(report) {
  if (!report || !Array.isArray(report.sheets) || !Array.isArray(report.witnesses)) {
    return { kind: "refuse", reason: "the cascade probe returned no report — nothing about the stylesheet was established, so nothing may be measured" };
  }
  const app = report.sheets.filter((s) => APP_SHEET_RE.test(String(s && s.href)));
  if (app.length === 0) {
    return { kind: "refuse", reason: `no /app.css in document.styleSheets (${report.sheets.length} sheet(s) present: ${report.sheets.map((s) => s.href).join(", ") || "none"}) — the page is running on UA defaults` };
  }
  const unreadable = app.find((s) => s.rules === -1);
  if (unreadable) {
    return { kind: "refuse", reason: `${unreadable.href} is in document.styleSheets but its cssRules threw (cross-origin) — the guard cannot confirm the cascade it is about to judge` };
  }
  const empty = app.find((s) => !(Number(s.rules) > 0));
  if (empty) {
    return { kind: "refuse", reason: `${empty.href} is in document.styleSheets with ${empty.rules} rule(s) — an empty or unparsed sheet applies nothing` };
  }
  for (const w of report.witnesses) {
    if (!w || typeof w.got !== "string") {
      return { kind: "refuse", reason: `the base witness ${w && w.sel} (${w && w.prop}) read nothing — ${w && w.found === false ? "the fixture node is absent" : "getComputedStyle failed"}; a witness that was not read excuses nothing` };
    }
    if (w.got !== w.want) {
      return {
        kind: "refuse",
        reason:
          `the BASE rule witness \`${w.sel} { ${w.prop} }\` computes "${w.got}", authored "${w.want}"` +
          (w.got === w.ua ? ` — exactly the UA default ("${w.ua}")` : "") +
          `. This declaration is OUTSIDE the @media block any GR115 defect lives in, so it cannot be moved by the defect this leg hunts; reading it wrong means app.css did not reach these nodes`,
      };
    }
  }
  return { kind: "ok" };
}

// THE REFUSAL STRING. It must be textually disjoint from every DEFECT line the
// leg prints: the whole point of this module is that a reader can tell "the CSS
// is wrong" from "there was no CSS", and a refusal that sounded like a finding
// would re-open the exact confusion that made run 30714372486 unreadable.
export function stylesheetRefusal({ url, reason, report }) {
  const sheets = report && Array.isArray(report.sheets)
    ? report.sheets.map((s) => `${s.href}[${s.rules}]`).join(", ") || "none"
    : "unavailable";
  const witnesses = report && Array.isArray(report.witnesses)
    ? report.witnesses.map((w) => `${w.sel}{${w.prop}}=${w.got === null ? "unread" : `"${w.got}"`}`).join(", ")
    : "unavailable";
  return (
    `STYLESHEET NOT APPLIED at ${url} — ${reason}.\n` +
    `   document.styleSheets: ${sheets}\n` +
    `   base witnesses: ${witnesses}\n` +
    `   document.readyState: ${report && report.readyState ? report.readyState : "unknown"}\n` +
    `   This is an ENVIRONMENT refusal (exit 2), NOT a measured CSS defect (exit 1): with no cascade in the ` +
    `document, EVERY computed value this leg compares is a UA default, and reporting those as a dead rule is ` +
    `how run 30714372486 printed six findings a one-declaration mutation could not have caused. NO claim is ` +
    `being made about the console's CSS either way (cch-w19-bl-gr115-intermittent-ua-defaults).`
  );
}
