// __constraint_slots.test.mjs — pdd-t20c: the PURE constraint-vocabulary matrix.
//
// constraints.js is DOM-free + ProseMirror-free (like locks.js), so its two
// decisions unit-test in plain Node: the calm veto (count floor + relative order)
// and the ghost-slot model. A fake PM-shaped doc is a plain object exposing the ONE
// structural contract the module assumes — `forEach((node, offset, index) => …)`
// over top-level children, each node `{ attrs }`.

import {
  parseConstraints,
  nodeRole,
  blockRole,
  ghostSlots,
  transactionVetoesConstraints,
} from "./canvas/constraints.js";

let failures = 0;
function ok(cond, msg) {
  if (cond) {
    console.log("PASS  " + msg);
  } else {
    failures++;
    console.error("FAIL  " + msg);
  }
}

// A fake top-level doc from a list of {role} (or full attrs) nodes.
function doc(...nodes) {
  const children = nodes.map((n) => ({ attrs: n }));
  return {
    childCount: children.length,
    forEach(fn) {
      children.forEach((node, i) => fn(node, i, i));
    },
  };
}
// A transaction: docChanged + the after-doc.
function tx(afterDoc, changed = true) {
  return { docChanged: changed, doc: afterDoc };
}
function state(beforeDoc) {
  return { doc: beforeDoc };
}

// The canonical current template re-expressed as declarations (byte-mirror of
// Template.paper_declarations/0): title required exactly-1 @top, ingress optional
// max-1 after(title) before(featured), featured optional max-1 after(title).
const DECLS = [
  {
    kind: "title",
    role: "title",
    presence: "required",
    count: { exactly: 1 },
    position: "top",
    locked: true,
  },
  {
    kind: "ingress",
    role: "ingress",
    presence: "optional",
    count: { max: 1 },
    position: { after: "title", before: "featured" },
    locked: false,
  },
  {
    kind: "featured",
    role: "featured",
    presence: "optional",
    count: { max: 1 },
    position: { after: "title" },
    locked: true,
  },
];

// ── parseConstraints ────────────────────────────────────────────────────────
ok(parseConstraints(null).length === 0, "parseConstraints(null) → [] (additive default)");
ok(parseConstraints("").length === 0, "parseConstraints('') → []");
ok(parseConstraints("not json").length === 0, "parseConstraints(garbage) → [] (never throws)");
ok(parseConstraints("{}").length === 0, "parseConstraints(non-array) → []");
ok(parseConstraints(JSON.stringify(DECLS)).length === 3, "parseConstraints(json) → the 3 decls");

// ── role extraction (dual home: prose attrs.role, opaque attrs.bpBlock.role) ──
ok(nodeRole({ attrs: { role: "title" } }) === "title", "nodeRole reads attrs.role");
ok(
  nodeRole({ attrs: { bpBlock: { role: "featured" } } }) === "featured",
  "nodeRole falls back to attrs.bpBlock.role (opaque/fleet)",
);
ok(nodeRole({ attrs: {} }) === null, "nodeRole → null when no role");
ok(nodeRole(null) === null, "nodeRole(null) → null");
ok(blockRole({ role: "ingress" }) === "ingress", "blockRole reads a plain block's role");
ok(blockRole({}) === null, "blockRole → null when absent");

// ── ghostSlots — the MODEL ────────────────────────────────────────────────────
{
  // A fresh doctrine paper: locked title + empty paragraph, both optionals ABSENT.
  const fresh = [{ role: "title", locked: true }, { type: "paragraph" }];
  const slots = ghostSlots(DECLS, fresh);
  ok(slots.length === 2, "ghostSlots: both optionals absent → 2 ghosts");
  ok(
    slots.map((s) => s.kind).join(",") === "ingress,featured",
    "ghostSlots: ordered by declaration order (ingress before featured)",
  );
  const featured = slots.find((s) => s.kind === "featured");
  ok(featured.after === "title" && featured.locked === true, "featured ghost: after(title) + locked");
  const ingress = slots.find((s) => s.kind === "ingress");
  ok(
    ingress.after === "title" && ingress.before === "featured" && ingress.locked === false,
    "ingress ghost: after(title) before(featured) + unlocked",
  );
}
{
  // Featured already present → only the ingress ghost remains.
  const withFeatured = [
    { role: "title", locked: true },
    { role: "featured", locked: true, type: "image" },
  ];
  const slots = ghostSlots(DECLS, withFeatured);
  ok(slots.length === 1 && slots[0].kind === "ingress", "ghostSlots: present optional drops its ghost");
}
{
  // Both optionals present → no ghosts (never an empty husk, never a duplicate slot).
  const full = [
    { role: "title", locked: true },
    { role: "ingress" },
    { role: "featured", locked: true },
  ];
  ok(ghostSlots(DECLS, full).length === 0, "ghostSlots: all optionals present → no ghosts");
}
ok(ghostSlots([], [{ role: "title" }]).length === 0, "ghostSlots: no declarations → no ghosts (D3)");
ok(ghostSlots(DECLS, []).length === 2, "ghostSlots: empty doc → both optional ghosts");

// ── transactionVetoesConstraints — count floor ────────────────────────────────
ok(
  transactionVetoesConstraints(tx(doc({ role: "title" }), false), state(doc({ role: "title" })), DECLS) ===
    false,
  "veto: a doc-unchanged tx never vetoes",
);
ok(
  transactionVetoesConstraints(null, state(doc()), DECLS) === false,
  "veto: a null tx never vetoes",
);
ok(
  transactionVetoesConstraints(tx(doc()), state(doc()), []) === false,
  "veto: no declarations → no veto (additive)",
);
{
  // Removing the required title (floor 1: 1 → 0) is vetoed.
  const before = state(doc({ role: "title" }, { type: "paragraph" }));
  const after = tx(doc({ type: "paragraph" }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === true,
    "veto: removing the required title (1→0 below floor) is vetoed",
  );
}
{
  // A pure content edit (title stays, count unchanged) passes.
  const before = state(doc({ role: "title" }, { type: "paragraph" }));
  const after = tx(doc({ role: "title" }, { type: "paragraph" }, { type: "paragraph" }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === false,
    "veto: growing the run without dropping a floored kind passes",
  );
}
{
  // A min-2 declaration: removing from 2 → 1 (below floor) is vetoed; 3 → 2 is not.
  const minDecl = [{ kind: "para", role: "body", presence: "required", count: { min: 2 } }];
  const twoToOne = transactionVetoesConstraints(
    tx(doc({ role: "body" })),
    state(doc({ role: "body" }, { role: "body" })),
    minDecl,
  );
  ok(twoToOne === true, "veto: min-2 kind dropping 2→1 is vetoed");
  const threeToTwo = transactionVetoesConstraints(
    tx(doc({ role: "body" }, { role: "body" })),
    state(doc({ role: "body" }, { role: "body" }, { role: "body" })),
    minDecl,
  );
  ok(threeToTwo === false, "veto: min-2 kind dropping 3→2 (still at floor) passes");
}
{
  // Removing an OPTIONAL max-1 kind (featured 1→0) is never a floor breach.
  const before = state(doc({ role: "title" }, { role: "featured" }));
  const after = tx(doc({ role: "title" }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === false,
    "veto: removing an optional (no floor) is allowed",
  );
}

// ── transactionVetoesConstraints — relative order ─────────────────────────────
{
  // Ingress currently after title, before featured (satisfied). A move that puts
  // ingress BEFORE the title breaks after(title) → vetoed.
  const before = state(doc({ role: "title" }, { role: "ingress" }, { role: "featured" }));
  const after = tx(doc({ role: "ingress" }, { role: "title" }, { role: "featured" }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === true,
    "veto: moving ingress before the title breaks after(title) → vetoed",
  );
}
{
  // A move that puts ingress AFTER featured breaks before(featured) → vetoed.
  const before = state(doc({ role: "title" }, { role: "ingress" }, { role: "featured" }));
  const after = tx(doc({ role: "title" }, { role: "featured" }, { role: "ingress" }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === true,
    "veto: moving ingress after featured breaks before(featured) → vetoed",
  );
}
{
  // Reordering blocks that carry NO positioned role (plain paragraphs) is fine.
  const before = state(doc({ role: "title" }, { type: "p", n: 1 }, { type: "p", n: 2 }));
  const after = tx(doc({ role: "title" }, { type: "p", n: 2 }, { type: "p", n: 1 }));
  ok(
    transactionVetoesConstraints(after, before, DECLS) === false,
    "veto: reordering unpositioned prose passes",
  );
}
{
  // Run-scoped blindness: if the anchor (featured) isn't in THIS run, before(featured)
  // is not-checkable → not vetoed here (the server backstops cross-run order).
  const before = state(doc({ role: "title" }, { role: "ingress" }));
  const after = tx(doc({ role: "ingress" }, { role: "title" }));
  // after(title) IS checkable in-run and broken → still vetoed on that rule.
  ok(
    transactionVetoesConstraints(after, before, DECLS) === true,
    "veto: in-run after(title) still enforced even when featured is out of run",
  );
}

if (failures > 0) {
  console.error(`\n${failures} constraint-slots check(s) FAILED`);
  process.exit(1);
}
console.log("\nall constraint-slots checks passed");
