// constraints.js — pdd-t20c: the PURE constraint-vocabulary decisions for the canvas.
//
// The doctrine template (locked title @0, optional featured, optional ingress) is
// re-expressed as a CONSTRAINT VOCABULARY: a list of DECLARATIONS, each
//
//   { kind, role, presence: "required"|"optional",
//     count: { exactly|min|max: N }, position: "top" | { after, before },
//     locked: true|false }
//
// The server owns the declarations (Content.Papers.Template.paper_declarations/0);
// the LiveView stamps them JSON-encoded onto the canvas host as `data-constraints`
// (twin of `data-locked-tail`), and this module turns them into the two client
// decisions the canvas needs — WITHOUT any DOM or ProseMirror import, so it
// unit-tests in plain Node exactly like locks.js:
//
//   1. ghostSlots(declarations, blocks) — the GHOST-SLOT MODEL. For every OPTIONAL
//      declaration whose kind is ABSENT from the doc, which calm affordance to
//      offer and where (its enforced anchor). The t13 featured-placeholder pattern
//      generalized: an optional block is "absent, never an empty husk" until the
//      author fills its ghost, at which point it MATERIALIZES in its enforced place.
//
//   2. transactionVetoesConstraints(tr, state, declarations) — the CALM VETO
//      GENERALIZED. locks.js vetoes displacing a locked block; this vetoes a
//      transaction that would drop a required/min-count kind BELOW its floor or
//      REORDER a positioned kind against its before/after relation. Wired into the
//      SAME real PM Plugin that runs transactionVetoesLock (index.js), keeping the
//      _programmaticApply exemption — so a violation is a calm local no-op, never a
//      save error, and the server {:constraint}/{:locked_block} veto backstops what
//      a RUN-scoped view can't see (featured is a run boundary).
//
// Additive (D3): an empty / absent declaration list vetoes nothing and offers no
// ghost, so a paper with no template behaves byte-identically.

// The template ROLE of a top-level PM node, or null. A prose/field node carries
// attrs.role (BpAttrs / run-convert declare it, so it survives setContent→getJSON);
// an opaque/fleet node carries the whole block on attrs.bpBlock, so its role lives
// at attrs.bpBlock.role. Mirrors locks.js lockedNodeId's dual-home read.
export function nodeRole(node) {
  const a = node && node.attrs;
  if (!a) return null;
  if (a.role != null) return a.role;
  if (a.bpBlock && a.bpBlock.role != null) return a.bpBlock.role;
  return null;
}

// The role of a PLAIN source block (the ghost-slot model runs over the doc-shape
// block list the LiveView holds, not PM nodes).
export function blockRole(block) {
  return block && block.role != null ? block.role : null;
}

// Parse the JSON `data-constraints` payload into a declaration array. Malformed /
// absent → [] (vetoes nothing, offers no ghost — the additive default).
export function parseConstraints(json) {
  if (json == null || json === "") return [];
  try {
    const parsed = JSON.parse(json);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_e) {
    return [];
  }
}

// The count FLOOR a declaration must never drop below: an explicit min/exactly, or
// 1 for a bare `required`. `optional` with only a `max` has no floor (0).
function floorOf(decl) {
  const c = (decl && decl.count) || {};
  if (typeof c.min === "number") return c.min;
  if (typeof c.exactly === "number") return c.exactly;
  return decl && decl.presence === "required" ? 1 : 0;
}

// Iterate a ProseMirror-shaped doc's DIRECT children as (node, index). Same single
// structural assumption as locks.js — a `.forEach((node, offset, index) => …)`.
function forEachTop(doc, fn) {
  if (doc && typeof doc.forEach === "function") doc.forEach((node, _o, i) => fn(node, i));
}

// role → count of top-level instances in a PM doc.
function roleCounts(doc) {
  const m = new Map();
  forEachTop(doc, (node) => {
    const r = nodeRole(node);
    if (r != null) m.set(r, (m.get(r) || 0) + 1);
  });
  return m;
}

// role → sorted list of top-level indices in a PM doc.
function roleIndices(doc) {
  const m = new Map();
  forEachTop(doc, (node, i) => {
    const r = nodeRole(node);
    if (r != null) {
      if (!m.has(r)) m.set(r, []);
      m.get(r).push(i);
    }
  });
  return m;
}

// Whether a declaration's RELATIVE ORDER holds in a doc. `after: X` — every instance
// of the declared role must sit after the first X; `before: Y` — every instance must
// sit before the last Y. Not-checkable (subject absent, or the anchor kind isn't in
// THIS run) counts as satisfied — the server backstops cross-run order (t20b).
function orderSatisfied(doc, decl) {
  const pos = decl && decl.position;
  if (!pos || typeof pos !== "object") return true; // "top"/none — not a relative rule
  const byRole = roleIndices(doc);
  const subject = byRole.get(decl.role || decl.kind) || [];
  if (subject.length === 0) return true;
  if (pos.after) {
    const anchor = byRole.get(pos.after) || [];
    if (anchor.length > 0) {
      const anchorFirst = Math.min.apply(null, anchor);
      if (subject.some((i) => i < anchorFirst)) return false;
    }
  }
  if (pos.before) {
    const anchor = byRole.get(pos.before) || [];
    if (anchor.length > 0) {
      const anchorLast = Math.max.apply(null, anchor);
      if (subject.some((i) => i > anchorLast)) return false;
    }
  }
  return true;
}

// THE CALM VETO, generalized. True when the transaction would either
//   (a) drop a required/min-count kind BELOW its floor (a remove that breaks min-N),
//       having been at/above it before — a delete the doctrine forbids; or
//   (b) BREAK a positioned kind's before/after relation that held before the tx — a
//       move that misplaces an optional-but-positioned block.
// Selection-only / doc-unchanged transactions and programmatic applies pass (the
// latter is exempted by the caller in index.js, exactly like the lock veto).
export function transactionVetoesConstraints(tr, state, declarations) {
  if (!tr || !tr.docChanged) return false;
  const decls = Array.isArray(declarations) ? declarations : [];
  if (decls.length === 0) return false;
  const before = state && state.doc;
  const after = tr.doc;

  // (a) count floor
  const beforeCounts = roleCounts(before);
  const afterCounts = roleCounts(after);
  for (const d of decls) {
    const floor = floorOf(d);
    if (floor <= 0) continue;
    const role = d.role || d.kind;
    const bc = beforeCounts.get(role) || 0;
    const ac = afterCounts.get(role) || 0;
    if (bc >= floor && ac < floor) return true;
  }

  // (b) relative order — only newly-broken relations veto (a relation already
  // broken before the tx isn't made worse by allowing a calm content edit).
  for (const d of decls) {
    if (orderSatisfied(before, d) && !orderSatisfied(after, d)) return true;
  }

  return false;
}

// THE GHOST-SLOT MODEL. For every OPTIONAL declaration whose kind is ABSENT from the
// doc, an affordance descriptor: what to offer and its enforced anchor(s). Ordered
// by declaration order (the enforced document order), so the LiveView paints ghosts
// in the sequence they'd occupy. Pure over the plain source-block list.
export function ghostSlots(declarations, blocks) {
  const decls = Array.isArray(declarations) ? declarations : [];
  const present = new Set();
  for (const b of blocks || []) {
    const r = blockRole(b);
    if (r != null) present.add(r);
  }
  return decls
    .filter((d) => d && d.presence === "optional" && !present.has(d.role || d.kind))
    .map((d) => {
      const pos = d.position && typeof d.position === "object" ? d.position : {};
      return {
        kind: d.kind || d.role,
        role: d.role || d.kind,
        after: pos.after || null,
        before: pos.before || null,
        locked: d.locked === true,
      };
    });
}
