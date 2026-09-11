// fleet-scenarios.mjs — WHICH SCENARIOS RENDER A `.fleet-row` IN `#fleet`, AND
// WHICH OF THEM THE W15 LEG MUST DRIVE, ASKED OF THE SHIPPED CODE INSTEAD OF
// TYPED BY HAND.
//
// WHY THIS FILE EXISTS. overflow-guard.mjs's W15-fleet-row-text-bounded leg
// used to drive a literal:
//
//     const FLEET_SCENS = ["mixed-fleet", "fleet-v4", "fleet-support-failed"];
//
// Three names. The fixture corpus renders `.fleet-row` in ONE HUNDRED AND TEN
// scenarios, so 107 of them were never driven at element level — and the leg was
// STRUCTURALLY UNABLE TO REFUSE on a fleet-bearing scenario it had no coverage
// for: an unlisted scenario is simply not walked, so the run goes green. That is
// the half-instrument shape wave 14 named: a list that is walked is not a list
// that is accounted for. Filed as cch-bl-w15-fleet-leg-scenario-axis-of-two,
// whose own title says "of two" — the literal had already grown to three by the
// time this was paid, which is the filing's point, not a contradiction of it.
//
// THE SHAPE IS GR109's, DELIBERATELY (#16372, attention-scenarios.mjs). One
// derivation idiom in this directory, not two: `appHooks()` is IMPORTED from
// that module rather than re-implemented, so the sandbox that evaluates the
// shipped app.js exists once.
//
// HOW THE SET IS DERIVED — THE SHIPPED RENDERER, NOT A SECOND OPINION.
// `#fleet` builds its table with exactly one expression (app.js loadFleet):
//
//     var shown = filterFleet(list, filter);            // filter is null on #fleet
//     body.innerHTML = … + fleetNestedRowsHtml(shown);
//
// so "renders a `.fleet-row`" IS "fleetNestedRowsHtml(scenario.data.barkparks)
// emits one" — and this module asks app.js that question directly, through the
// guarded `__bpTestHook` bag at the tail of the IIFE. A re-implementation here
// would be a SECOND hand-written renderer that drifts from the one the page
// runs, which is the defect this file was written to remove wearing a
// function's clothes.
//
// DRIVING 110 SCENARIOS WOULD MEASURE 107 COPIES. The same expression that
// tells us WHICH scenarios bear rows also tells us WHAT they render, so the
// axis is bounded by CONTENT rather than by fixture count: scenarios whose
// rendered row markup is BYTE-IDENTICAL form one class, and the leg drives one
// member of each class. 110 scenarios collapse to 19 classes, of which 87
// members share a single one-row class — driving all 87 would ask the same
// three questions of the same bytes 87 times and buy nothing. The grouping is
// recomputed every run off today's markup, so a fixture that DIVERGES stops
// being a copy the moment it diverges and becomes a class of its own, which is
// driven. That is a predicate, not a snapshot: nothing here has to be updated
// when a scenario is added.
//
// WHAT CANNOT BE DRIVEN, AND WHY THAT IS A LEDGER RATHER THAN A SHRUG.
// A scenario carrying its own `pathname` renders a DIFFERENT PAGE — `/new` is
// the launch theater, `/activate` the invite entry — and neither mounts the
// console shell, so `#fleet` never routes there and a cell would measure the
// wrong screen. That is a property of the ROUTE, not of the data, and it is the
// only reason a fleet-bearing scenario is allowed out of this leg's axis. Every
// such scenario must carry an ITEMISED entry in FLEET_SCEN_SKIP below with a
// written reason or a filed row id; a fleet-bearing scenario that is neither
// driven, nor a byte-identical copy of a driven one, nor itemised here is
// REFUSED (the consumer die()s, exit 2). An entry that no longer matches is
// refused too, so the ledger cannot rot into a blanket.
//
// THE CONSUMER OWES A REFUSAL. `fleetAxis()` throws rather than returning a
// narrowed set, because an empty or silently-shrunken axis makes a zero-cell
// sweep look like a clean one — the vacuous green the leg's own per-cell zero
// refusals already exist to forbid.

import crypto from "node:crypto";
import { appHooks } from "./attention-scenarios.mjs";

// The three names the pre-derivation literal carried, plus the two the filed
// row named as escapees. Kept ONLY as a positive control on the derivation and
// as pinned representatives — never as the axis itself. `fleet-archives-stored`
// is the corpus's archives fixture; the filed row calls it "fleet-archives",
// which is not a scenario key.
export const FLEET_LITERAL_CONTROL = ["mixed-fleet", "fleet-v4", "fleet-support-failed"];
export const FLEET_PINNED_REPS = [...FLEET_LITERAL_CONTROL, "fleet-archives-stored"];

// ITEMISED, REASONED, AND UNABLE TO ROT. One entry per fleet-bearing scenario
// the leg does not drive for a reason other than "an identical copy is driven".
// `why` must name the property that makes the cell unmeasurable, not the cost of
// measuring it; `row` carries a filed id when the exclusion is a deferral.
export const FLEET_SCEN_SKIP = [
  {
    scen: "theater-midflight",
    why: 'pathname "/new" — the launch theater page, which does not mount the console shell, so `#fleet` never routes there and the cell would measure the wrong screen',
  },
  {
    scen: "theater-failed",
    why: 'pathname "/new" — the launch theater page, which does not mount the console shell, so `#fleet` never routes there and the cell would measure the wrong screen',
  },
  {
    scen: "theater-ready",
    why: 'pathname "/new" — the launch theater page, which does not mount the console shell, so `#fleet` never routes there and the cell would measure the wrong screen',
  },
];

// The console shell is served at the site root; anything else is another page.
// Expressed as a PREDICATE over scenarios.mjs's own field so a tenth `/new`
// fixture is classified without anyone remembering to type it — and then still
// has to be ITEMISED above before the leg will run, which is the half a
// predicate alone gets wrong.
export function drivableAtFleetHash(sc) {
  const p = (sc || {}).pathname;
  return p == null || p === "/";
}

// The rendered row markup for one scenario, taken from the SHIPPED renderer.
// "" when the scenario is signed out (the sign-in screen paints instead of
// `#fleet`, so a cell there measures zero rows and reds for a reason that has
// nothing to do with layout) or carries no boxes.
export function fleetRowsHtml(sc, hooks) {
  if (!sc || sc.authed === false) return "";
  const list = (sc.data && sc.data.barkparks) || [];
  if (!list.length) return "";
  return hooks.fleetNestedRowsHtml(list) || "";
}

export function countFleetRows(html) {
  return (String(html).match(/class="[^"]*\bfleet-row\b/g) || []).length;
}

// Every scenario whose `#fleet` table is non-empty, with the row count the
// shipped renderer yields and the signature of the markup it yields it as.
export function fleetBearingRows(SCENARIOS, hooks = appHooks()) {
  if (typeof hooks.fleetNestedRowsHtml !== "function") {
    throw new Error(
      "fleet-scenarios: app.js's __bpTestHook no longer exports fleetNestedRowsHtml — " +
      "the W15 scenario axis cannot be derived from the shipped renderer, and a " +
      "hand-typed replacement is exactly the blind spot this module removes",
    );
  }
  const out = [];
  for (const name of Object.keys(SCENARIOS || {})) {
    const sc = SCENARIOS[name] || {};
    const html = fleetRowsHtml(sc, hooks);
    const rows = countFleetRows(html);
    if (rows > 0) {
      out.push({ name, rows, sig: crypto.createHash("sha1").update(html).digest("hex").slice(0, 12) });
    }
  }
  out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return out;
}

// The axis the W15 leg drives, plus the full itemisation of what it does not.
// Refuses rather than narrows — see the head of this file.
export function fleetAxis(SCENARIOS, hooks = appHooks()) {
  const bearing = fleetBearingRows(SCENARIOS, hooks);
  if (bearing.length === 0) {
    throw new Error(
      `fleet-scenarios: the derived .fleet-row set is EMPTY across ` +
      `${Object.keys(SCENARIOS || {}).length} scenarios — either the fixtures stopped ` +
      `carrying instances or fleetNestedRowsHtml stopped emitting the class. A zero-length ` +
      `axis makes the W15 leg sweep zero cells and print a clean summary of no work; refused.`,
    );
  }
  const byName = new Map(bearing.map((b) => [b.name, b]));

  const missing = FLEET_PINNED_REPS.filter((n) => !byName.has(n));
  if (missing.length) {
    throw new Error(
      `fleet-scenarios: the derivation lost its positive control — ${missing.join(", ")} ` +
      `render no .fleet-row, though the pre-derivation W15 literal drove them (and ` +
      `fleet-archives-stored is the archives fixture the filed row asked for by name). ` +
      `${bearing.length} scenario(s) derived. Either a fixture was renamed (update ` +
      `FLEET_PINNED_REPS deliberately) or the renderer regressed; a silently narrower axis is refused.`,
    );
  }

  // The skip ledger, checked BOTH ways before it is used.
  const skipByName = new Map();
  for (const e of FLEET_SCEN_SKIP) {
    if (!byName.has(e.scen)) {
      throw new Error(
        `fleet-scenarios: skip entry "${e.scen}" names a scenario that renders NO .fleet-row today — ` +
        `either the fixture was renamed or it stopped carrying boxes. An entry that matches nothing ` +
        `buys silence forever; DELETE it rather than carrying it.`,
      );
    }
    if (drivableAtFleetHash(SCENARIOS[e.scen])) {
      throw new Error(
        `fleet-scenarios: skip entry "${e.scen}" is DRIVABLE at #fleet (it carries no foreign pathname), ` +
        `so the only reason this ledger accepts does not apply to it. Drive it or say why in a NEW ` +
        `reason class; an exclusion this file cannot justify is refused.`,
      );
    }
    if (!e.why && !e.row) {
      throw new Error(`fleet-scenarios: skip entry "${e.scen}" carries neither a written reason nor a filed row id — a bare skip is refused.`);
    }
    skipByName.set(e.scen, e);
  }

  // ONE MEMBER PER DISTINCT RENDERED-ROW MARKUP. Pinned names win the
  // representative slot so the positive control is always the thing driven;
  // otherwise the alphabetically first drivable, unskipped member.
  const classes = new Map();
  for (const b of bearing) {
    if (!classes.has(b.sig)) classes.set(b.sig, { sig: b.sig, rows: b.rows, members: [] });
    classes.get(b.sig).members.push(b.name);
  }
  const drive = [];
  const skipped = [];
  for (const cls of classes.values()) {
    const candidates = cls.members.filter((n) => !skipByName.has(n) && drivableAtFleetHash(SCENARIOS[n]));
    const pinned = candidates.filter((n) => FLEET_PINNED_REPS.includes(n));
    cls.rep = pinned.length ? pinned[0] : candidates.length ? candidates[0] : null;
    if (cls.rep) drive.push(cls.rep);
    for (const n of cls.members) {
      if (n === cls.rep) continue;
      if (cls.rep) {
        skipped.push({ scen: n, sameAs: cls.rep, sig: cls.sig, why: `rendered-row markup byte-identical to ${cls.rep} (${cls.rows} row(s), sig ${cls.sig}) — the same bytes measured twice answer the same question twice` });
      } else {
        const e = skipByName.get(n);
        skipped.push({ scen: n, sameAs: null, sig: cls.sig, row: e && e.row, why: e ? (e.why || `filed as ${e.row}`) : null });
      }
    }
    if (!cls.rep) {
      // Every member of this class is out of the axis; each one owes an entry.
      const unaccounted = cls.members.filter((n) => !skipByName.has(n));
      if (unaccounted.length) {
        throw new Error(
          `fleet-scenarios: ${unaccounted.length} fleet-bearing scenario(s) the W15 leg has NO COVERAGE for: ` +
          `${unaccounted.join(", ")} — each renders .fleet-row markup (${cls.rows} row(s), sig ${cls.sig}) that no ` +
          `driven scenario reproduces, and none carries an itemised FLEET_SCEN_SKIP entry. Drive it, or itemise it ` +
          `with a written reason or a filed row id; an unaccounted scenario is refused, because a scenario that is ` +
          `not walked and not accounted for is measured by nobody and noticed by nobody.`,
        );
      }
    }
  }
  drive.sort((a, b) => {
    const ai = FLEET_PINNED_REPS.indexOf(a), bi = FLEET_PINNED_REPS.indexOf(b);
    if (ai !== bi) return (ai < 0 ? 99 : ai) - (bi < 0 ? 99 : bi);
    return a < b ? -1 : a > b ? 1 : 0;
  });
  skipped.sort((a, b) => (a.scen < b.scen ? -1 : a.scen > b.scen ? 1 : 0));

  // Total accounting: every derived scenario is on exactly one side.
  const accounted = new Set([...drive, ...skipped.map((s) => s.scen)]);
  const lost = bearing.map((b) => b.name).filter((n) => !accounted.has(n));
  if (lost.length) {
    throw new Error(`fleet-scenarios: ${lost.join(", ")} fell out of BOTH the driven set and the itemised skip list — the accounting does not close, so the axis cannot be trusted.`);
  }
  return { bearing, classes: [...classes.values()], drive, skipped, rowsByName: byName };
}
