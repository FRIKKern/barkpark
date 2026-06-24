// run-convert.js — Phase-4 Stage S0: the headless system-of-record projector.
//
// This is the SEED of the continuous canvas. It projects a portable-doc block
// LIST into a SINGLE ProseMirror-style doc JSON (one top-level node per block,
// in order) and diffs an edited doc back into the EXACT op vocabulary the
// server already folds (patch-block / insert-after / remove-block / move-block).
//
// It SHIPS DARK. Nothing imports it — not index.js, not the bundle, not the
// LiveView, not the server. The working per-block <bp-paper-editor> and its
// committed bundle literally cannot regress because this module is unreachable
// at runtime. S0 is the system-of-record proof BEFORE any caret touches a
// screen: it lets us prove the blocks ⇄ one-doc ⇄ ops projection is lossless
// in pure Node, on harness fixtures, with zero UI risk.
//
// PURE, DOM-free, TipTap-free, ProseMirror-free, Node-API-free. It imports
// ONLY from ../convert.js — the same pure converter index.js uses today, so an
// interior edit emitted here is BYTE-IDENTICAL to what the per-block editor
// emits (convert.js:331 buildPatchBlockOp is the shared path).
//
// ── shapes (verified against the real code) ───────────────────────────────
//
//   convert.js:252 blockToTiptap(block) → { type:"doc", content:[ node ] }
//       for a PROSE block (paragraph | heading | list). We lift content[0].
//   convert.js:331 buildPatchBlockOp(editorJSON, id, type)
//       → { op:"patch-block", id, patch:{ ...mutable fields only } }
//
//   patch.ex op wire shapes (api/lib/barkpark/portable_doc/patch.ex):
//       patch-block   patch.ex:153  { "op":"patch-block",  "id":…, "patch":{…} }
//       insert-after  patch.ex:140  { "op":"insert-after",  "afterId":…, "block":{…} }
//       append-block  patch.ex:132  { "op":"append-block",  "block":{…} }
//       remove-block  patch.ex:191  { "op":"remove-block",  "id":… }
//       move-block    patch.ex:203  { "op":"move-block",    "id":…, "after":… | null }
//
// The block kinds convert.js treats as PROSE are exactly paragraph | heading |
// list (convert.js:257-288 — the switch in blockToTiptap). Everything else is
// non-prose and is carried as an OPAQUE placeholder node, verbatim.

import {
  blockToTiptap,
  buildPatchBlockOp,
  inlineArrayToTiptap,
  tiptapInlineToPd,
} from "../convert.js";

// The doc-block kinds convert.js round-trips as prose (convert.js blockToTiptap
// switch). These project to a native ProseMirror textblock and diff via
// buildPatchBlockOp.
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

// S3: non-prose block kinds the canvas handles as ATOM nodes — leaf nodes that
// live INSIDE the canvas document (not run boundaries, not opaque carry-through).
// The divider is the first: a leaf with no content, so it NEVER reports an
// interior change. As later increments land callout/code/field/sheet atoms they
// join this set. A node is "canvas-handled" if it is PROSE or a canvas ATOM;
// only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_ATOM_TYPES = new Set(["divider"]);

// S3.2: non-prose block kinds the canvas handles as CONTENT nodes — nodes with an
// EDITABLE interior (a contentDOM) living INSIDE the canvas document, NOT atoms
// and NOT opaque. The callout is the first: its body is an editable inline region
// (compose.ex:155 feeds callout `content` through compose_inline_children → ONE
// inline PdText), so unlike the divider ATOM it CAN report an interior change and
// emits a patch-block on a body/tone/title/collapsed edit. As later increments
// land sheet/code/field as content node-views they join this set.
//
// A node is "canvas-handled" if it is PROSE, a canvas ATOM, or a canvas CONTENT
// node; only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_CONTENT_TYPES = new Set(["callout"]);

function isProseType(type) {
  return PROSE_TYPES.has(type);
}

function isCanvasAtomType(type) {
  return CANVAS_ATOM_TYPES.has(type);
}

function isCanvasContentType(type) {
  return CANVAS_CONTENT_TYPES.has(type);
}

// Structural deep clone, DOM-free and Node-API-free. structuredClone is a
// global in modern V8 (and browsers); fall back to JSON for older runtimes.
// Both are pure and create zero shared references with the source.
function deepClone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

// ── projection: blocks → one doc ───────────────────────────────────────────

// runToTiptap(blocks) → { type:"doc", content:[ node, … ] }
//
// One top-level node per block, IN ORDER. Every node is stamped with
// attrs:{ bpId, bpType } so the reverse diff can key by bpId.
//
//   PROSE block → blockToTiptap(block).content[0] (the single prose node),
//     with { bpId, bpType } MERGED into its attrs (preserving any attrs
//     blockToTiptap already set, e.g. heading level).
//   CANVAS ATOM block (S3: divider) → a native leaf node of that type carrying
//     ONLY { bpId, bpType } attrs — e.g. { type:"divider", attrs:{bpId,bpType} }.
//     No bpBlock: a divider is a content-free leaf, fully described by its type +
//     id, so it round-trips through the canvas schema's own node (divider-node.js)
//     rather than as an opaque blob.
//   OTHER NON-PROSE block → an opaque placeholder:
//       { type:"bpOpaque", attrs:{ bpId, bpType, bpBlock:<deep-cloned block> } }
//     carrying the original block JSON verbatim so it round-trips untouched.
export function runToTiptap(blocks) {
  const content = (blocks || []).map((block) => {
    const bpId = block && block.id;
    const bpType = block && block.type;

    if (isProseType(bpType)) {
      // Lift the single prose node convert.js produced and merge our stamp into
      // its attrs without clobbering blockToTiptap's own attrs (heading level).
      const node = blockToTiptap(block).content[0];
      const attrs = { ...(node.attrs || {}), bpId, bpType };
      return { ...node, attrs };
    }

    if (isCanvasAtomType(bpType)) {
      // A canvas atom (divider): a native leaf node of that type, stamped with
      // bpId/bpType only. The canvas schema (divider-node.js) declares the node,
      // so getJSON() round-trips it. No content, no bpBlock — a leaf is fully
      // described by type + id.
      return { type: bpType, attrs: { bpId, bpType } };
    }

    if (isCanvasContentType(bpType)) {
      // A canvas CONTENT node (S3.2: callout): a native node of that type whose
      // BODY is editable inline content and whose chrome (tone/title/collapsible/
      // collapsed) rides node attrs. The canvas schema (callout-node.js) declares
      // it, so getJSON() round-trips both the body and the chrome attrs.
      return calloutBlockToNode(block, bpId, bpType);
    }

    // Opaque carry-through: the original block JSON, deep-cloned (no shared refs).
    return {
      type: "bpOpaque",
      attrs: { bpId, bpType, bpBlock: deepClone(block) },
    };
  });

  return { type: "doc", content };
}

// ── callout ⇄ canvas content node (S3.2) ────────────────────────────────────
//
// convert.js has NO callout path (it only round-trips paragraph|heading|list), so
// the callout block ⇄ TipTap-node mapping lives HERE, mirroring how blockToTiptap
// /tiptapToBlock handle inline — REUSING convert.js's exported inlineArrayToTiptap
// /tiptapInlineToPd verbatim for the body (the body IS inline runs; do not
// reinvent inline serialization).
//
// The chrome rides node.attrs:
//   tone        — string, defaults "info" (compose.ex:157 `tone || "info"`)
//   title       — optional; ABSENT (null) round-trips as no `title` field
//   collapsible — boolean; ABSENT (false) → no `collapsible` field
//   collapsed   — boolean; ABSENT (false) → no `collapsed` field
// Omitting absent chrome fields is the byte-fidelity contract: compose.ex
// maybe_put / maybe_put_true only thread these when present, so a callout that
// never had a title must round-trip WITHOUT a title key (not title:"").

// calloutBlockToNode(block) → { type:"callout", attrs:{…}, content:[inline…] }
//
// The body inline array (block.content) → TipTap inline nodes via the shared
// serializer. Chrome fields → attrs (only the present ones; tone always present
// with its "info" default so a tone swap is always diffable).
function calloutBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    tone: (block && block.tone) || "info",
  };
  // Only carry title/collapsible/collapsed when PRESENT in the source block, so
  // an untouched callout's getJSON re-projection matches and emits zero ops.
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.collapsible === true) attrs.collapsible = true;
  if (block && block.collapsed === true) attrs.collapsed = true;

  const node = { type: bpType || "callout", attrs };
  const inline = inlineArrayToTiptap((block && block.content) || []);
  if (inline.length) node.content = inline;
  return node;
}

// calloutNodeToBlock(node, id) → { id, type:"callout", tone, title?, collapsible?,
//   collapsed?, content:[inline…] }
//
// Reconstruct the portable-doc callout block from a callout NODE (the inverse of
// calloutBlockToNode). Body inline ← tiptapInlineToPd (the shared deserializer).
// Chrome fields read off node.attrs, threaded ONLY when present/true so the
// reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray title:"" / collapsible:false).
function calloutNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "callout",
    tone: attrs.tone || "info",
    content: tiptapInlineToPd((node && node.content) || []),
  };
  if (attrs.title != null) block.title = attrs.title;
  if (attrs.collapsible === true) block.collapsible = true;
  if (attrs.collapsed === true) block.collapsed = true;
  return block;
}

// The mutable-fields PATCH for a callout (the analogue of buildPatchBlockOp's
// patch map for prose). It is calloutNodeToBlock MINUS id/type — patch.ex re-pins
// those (the same contract tiptapToBlock follows).
//
// CRITICAL: the patch emits the chrome fields (title/collapsible/collapsed)
// EXPLICITLY even when false/null. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) that can REPLACE or PRESERVE a key but never DELETE one — so
// OMITTING a now-false/null field would leave the STALE old value, silently
// reverting an EXPAND (collapsed true→false via the fold button), a TITLE-CLEAR
// (set→null), or a collapsible-off on persist/reload. An explicit collapsible/
// collapsed:false round-trips byte-identically (compose.ex), and title:null is
// dropped by compose maybe_put. The INSERT path (calloutNodeToBlock) correctly
// OMITS absent fields — only the patch is explicit, so removals actually land.
function calloutNodeToPatch(node) {
  const block = calloutNodeToBlock(node, null);
  const attrs = (node && node.attrs) || {};
  return {
    tone: block.tone,
    content: block.content,
    title: attrs.title == null ? null : attrs.title,
    collapsible: attrs.collapsible === true,
    collapsed: attrs.collapsed === true,
  };
}

// True when a callout node's body OR chrome changed (an interior edit). We
// compare the canonical (key-order-insensitive) projection of the diff-relevant
// fields — tone, title, collapsible, collapsed, content — so a tone swap, title
// edit, fold toggle, or body edit flips it, but a pure reorder (bpId/bpType only)
// does not. Uses the SAME canonicalJSON the prose path uses, so a node serialized
// by calloutBlockToNode and the SAME node from the live editor's getJSON compare
// EQUAL despite differing attr/text key order.
function calloutNodeChanged(prevNode, nextNode) {
  return stableCalloutKey(prevNode) !== stableCalloutKey(nextNode);
}

function stableCalloutKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    tone: a.tone || "info",
    title: a.title == null ? null : a.title,
    collapsible: a.collapsible === true,
    collapsed: a.collapsed === true,
    content: node.content || null,
  });
}

// ── reverse diff: prev blocks + edited doc → ordered ops ────────────────────

// Strip our { bpId, bpType } stamp back off a prose node so the node is the
// plain convert.js shape buildPatchBlockOp expects (it reads node.attrs.level
// for headings; the extra keys are harmless but we keep the doc tidy and the
// emitted op byte-identical to the per-block path by leaving level intact).
//
// We DON'T need to remove bpId/bpType for correctness — buildPatchBlockOp only
// reads top.type, top.attrs.level, top.content — but wrapping the node back in
// the {type:"doc",content:[node]} envelope is what it expects.
function nodeToDocEnvelope(node) {
  return { type: "doc", content: [node] };
}

// ── id minting for new/split blocks ─────────────────────────────────────────
//
// The reverse diff MUST give every next-doc node a KNOWN id, because the op
// vocabulary can only express a front-insert / reorder via move-block, and
// move-block keys by a known id. So a new block (a split, a typed paragraph,
// anything with no surviving bpId) is CLIENT-MINTED an id here.
//
// The id must be unique within the call AND collision-free against every prev
// id and every other minted id — patch.ex rejects a duplicate id on both
// append-block and insert-after. We use a per-call monotonic counter prefixed
// "c-" plus a high-entropy nonce; the caller hands us a `taken` set so we can
// retry on the astronomically-unlikely collision.
function mintId(taken) {
  let id;
  do {
    mintCounter += 1;
    // Counter guarantees per-call uniqueness; the nonce guarantees the id can
    // never collide with a server/prev id of the conventional shape.
    id = "c-" + mintCounter.toString(36) + "-" + randomNonce();
  } while (taken.has(id));
  taken.add(id);
  return id;
}

let mintCounter = 0;

// A short high-entropy token. crypto.randomUUID is a global in modern V8 and
// browsers; fall back to Math.random (uniqueness within a call is all we need —
// the per-call counter already guarantees that, the nonce only widens the gap
// against externally-minted ids).
function randomNonce() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID().slice(0, 8);
  }
  return Math.random().toString(36).slice(2, 10);
}

// True when two prose nodes carry different content (an interior edit). We
// compare the node minus our bp* stamp via a stable JSON of the fields
// buildPatchBlockOp actually reads (type, attrs.level, content). Cheap + exact:
// any text/mark/level/list-shape change flips this; a pure reorder does not.
function proseNodeChanged(prevNode, nextNode) {
  return stableProseKey(prevNode) !== stableProseKey(nextNode);
}

// Order-insensitive deep stringify: sorts OBJECT keys recursively (array order
// is preserved — content/marks order is significant). Without this, two
// semantically-identical text nodes that differ only in KEY ORDER would hash
// differently — exactly the runToTiptap `{type,text,marks}` vs ProseMirror
// getJSON `{type,marks,text}` mismatch that otherwise flags EVERY marked block
// as "changed" on every keystroke.
function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJSON).join(",") + "]";
  }
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}

// The byte-significant projection of a prose node for change detection: its
// type, heading level (if any), and content — i.e. exactly the inputs to
// buildPatchBlockOp / tiptapToBlock. bpId/bpType are excluded so an identity
// move never looks like an edit. Canonicalized (key-order-insensitive) so a
// node serialized by runToTiptap and the SAME node serialized by the live
// editor's getJSON compare EQUAL despite their differing attr/text key order.
function stableProseKey(node) {
  const level = node.attrs && node.attrs.level;
  return canonicalJSON({
    type: node.type,
    level: level == null ? null : level,
    content: node.content || null,
  });
}

// runToOps(prevBlocks, nextDoc) → [ op, … ] (ordered)
//
// Diff the ORIGINAL block list against the edited doc (the runToTiptap shape
// after edits) and emit an ordered op set in the EXISTING vocabulary that, when
// FOLDED through patch.ex left-to-right, reproduces nextDoc EXACTLY — id order
// and surviving content both.
//
// The pivot that makes this provable: EVERY new block (a split, a typed
// paragraph, anything with no surviving bpId) is CLIENT-MINTED a unique id up
// front, so every next node has a KNOWN id. The op vocabulary has no
// prepend / insert-before — a front-insert or any reorder can ONLY be expressed
// via move-block, which keys by a known id. Minting closes that gap.
//
// Emission order: removes → inserts → moves → patches.
//   1. removes shrink the running list to the surviving prev ids.
//   2. inserts graft every new block in (anchored to the FIRST surviving prev
//      block, or appended when nothing survives). Position here does NOT matter.
//   3. moves permute the running list — now exactly nextSeq's id SET in some
//      order — into nextSeq ORDER. An already-correct subsequence emits nothing.
//   4. interior patches mutate surviving prose content in place (order-free).
export function runToOps(prevBlocks, nextDoc) {
  const prev = prevBlocks || [];
  const nextNodes = (nextDoc && nextDoc.content) || [];

  // prev id → index, and the block.
  const prevIndex = new Map();
  const prevById = new Map();
  prev.forEach((block, i) => {
    const id = block && block.id;
    if (id != null) {
      prevIndex.set(id, i);
      prevById.set(id, block);
    }
  });

  // ── 0) BUILD nextSeq: every next node gets a KNOWN id (existing or minted) ──
  //
  // `taken` seeds with every prev id so a minted id can never collide with a
  // surviving block (patch.ex rejects duplicate ids on append/insert-after).
  const taken = new Set();
  prevById.forEach((_block, id) => taken.add(id));

  const nextSeq = nextNodes.map((node) => {
    const bpId = node.attrs && node.attrs.bpId;
    const isOpaque = node.type === "bpOpaque";
    // A canvas atom (S3: divider) is a content-free leaf — like opaque, it never
    // emits an interior patch, but unlike opaque it reconstructs as a real block
    // of its type (not a carried bpBlock). Detect by the node TYPE itself.
    const isAtom = isCanvasAtomType(node.type);
    // A canvas CONTENT node (S3.2: callout) HAS an editable interior — unlike the
    // atom it CAN emit a patch on a body/chrome change, and unlike opaque it
    // reconstructs as a real block of its type via calloutNodeToBlock.
    const isContent = isCanvasContentType(node.type);
    const bpType = (node.attrs && node.attrs.bpType) || node.type;
    const existing = bpId != null && prevIndex.has(bpId);
    const id = existing ? bpId : mintId(taken);
    return { id, bpType, node, isNew: !existing, isOpaque, isAtom, isContent };
  });

  const nextIds = new Set(nextSeq.map((e) => e.id));

  const ops = [];

  // ── 1) REMOVES — prev id not present in nextSeq (a merge/delete) ───────────
  for (const block of prev) {
    const id = block && block.id;
    if (id != null && !nextIds.has(id)) {
      ops.push({ op: "remove-block", id });
    }
  }

  // The running fold's id order, tracked as WE apply our own ops so move
  // emission can skip no-ops. After removes it is the surviving prev ids in
  // prev order.
  let running = prev
    .map((b) => b && b.id)
    .filter((id) => id != null && nextIds.has(id));

  // ── 2) INSERTS — each NEW entry grafted in with its MINTED id ──────────────
  //
  // Anchor every insert to the FIRST surviving prev block (guaranteed present
  // through the whole insert pass — inserts never remove it). When nothing
  // survives (prev empty or all-removed) the first insert appends and each
  // subsequent insert anchors after the previously-inserted block. Final
  // position is irrelevant — the moves pass fixes order.
  let firstSurvivor = running.length > 0 ? running[0] : null;
  for (const entry of nextSeq) {
    if (!entry.isNew) continue;
    const block = nextNodeToBlock(entry);
    if (firstSurvivor == null) {
      // No anchor yet: append the first new block at the end, then use it as the
      // anchor for the rest so every later insert has a present afterId.
      ops.push({ op: "append-block", block });
      running.push(entry.id);
      firstSurvivor = entry.id;
    } else {
      ops.push({ op: "insert-after", afterId: firstSurvivor, block });
      // insert-after splices directly after firstSurvivor; reflect that in the
      // running order (position irrelevant for correctness — moves fix it).
      const at = running.indexOf(firstSurvivor);
      running.splice(at + 1, 0, entry.id);
    }
  }

  // ── 3) MOVES — permute `running` (now exactly nextSeq's id SET) into order ──
  //
  // Walk nextSeq left-to-right. For each entry, the target predecessor is the
  // previous entry's id (or null for the first). Emit a move ONLY when the entry
  // is not ALREADY immediately after that predecessor in the running order — so
  // an already-correct subsequence (e.g. a pure interior edit) emits zero moves.
  // We apply each move to `running` as we go, so subsequent checks see the
  // post-move order and we never emit a redundant move.
  for (let i = 0; i < nextSeq.length; i++) {
    const id = nextSeq[i].id;
    const after = i === 0 ? null : nextSeq[i - 1].id;
    const curIdx = running.indexOf(id);
    const afterIdx = after == null ? -1 : running.indexOf(after);
    // Already correctly placed iff it sits exactly one slot after its target
    // predecessor (or at the head when there is no predecessor).
    if (curIdx === afterIdx + 1) continue;
    ops.push({ op: "move-block", id, after });
    // Mirror patch.ex move-block on `running`: lift the id, splice after `after`
    // (or head when null).
    running.splice(curIdx, 1);
    const dest = after == null ? 0 : running.indexOf(after) + 1;
    running.splice(dest, 0, id);
  }

  // ── 4) PATCHES — surviving prose / content nodes whose interior changed ─────
  //
  // PROSE → byte-identical to the per-block editor's patch-block (buildPatchBlockOp).
  // CANVAS CONTENT (S3.2: callout) → a patch-block carrying the changed body/chrome
  //   fields (calloutNodeToPatch), keyed by id. An UNCHANGED callout emits NO op
  //   (canonical key-order-insensitive compare, same as prose).
  // A surviving opaque node is a no-op (opaque blocks just round-trip).
  // A surviving canvas ATOM (S3: divider) is likewise a no-op: a leaf has no
  // interior to change, so it NEVER reports an interior patch.
  for (const entry of nextSeq) {
    if (entry.isNew || entry.isOpaque || entry.isAtom) continue;
    const prevBlock = prevById.get(entry.id);
    const prevNode = runToTiptap([prevBlock]).content[0];

    if (entry.isContent) {
      // Canvas content node (callout): diff body + chrome; emit one patch-block
      // carrying ONLY the mutable fields when anything changed.
      if (calloutNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: calloutNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (proseNodeChanged(prevNode, entry.node)) {
      const bpType = entry.bpType || (prevBlock && prevBlock.type);
      ops.push(buildPatchBlockOp(nodeToDocEnvelope(entry.node), entry.id, bpType));
    }
  }

  return ops;
}

// Reconstruct a portable-doc block from a NEW nextSeq entry, carrying its
// CLIENT-MINTED id. PROSE → the convert.js patch fields plus { id, type };
// CANVAS ATOM (S3: divider) → a bare { id, type } leaf block (no body); the id
// is minted on insert and the leaf carries no other fields. OPAQUE → its carried
// bpBlock verbatim, with the minted id stamped on (so move-block / later folds
// can key it). Every inserted block carries an id — that is what makes a
// front-insert / reorder expressible via move-block.
function nextNodeToBlock(entry) {
  const node = entry.node;
  if (entry.isAtom) {
    // Canvas atom insert (divider): a content-free leaf, fully described by its
    // type + the minted id. No body fields to reconstruct.
    return { id: entry.id, type: entry.bpType || node.type };
  }
  if (entry.isContent) {
    // Canvas content insert (callout): reconstruct the full callout block from
    // the node (body + chrome) with the minted id, via the dedicated mapper.
    return calloutNodeToBlock(node, entry.id);
  }
  if (entry.isOpaque) {
    // Opaque insert: the carried block JSON, deep-cloned, with the minted id.
    const block = deepClone((node.attrs && node.attrs.bpBlock) || {});
    block.id = entry.id;
    return block;
  }
  const bpType = entry.bpType || node.type;
  // buildPatchBlockOp().patch is exactly the mutable-fields map — the body of a
  // new block of this type. Stamp the minted id + type.
  const op = buildPatchBlockOp(nodeToDocEnvelope(node), entry.id, bpType);
  return { id: entry.id, type: bpType, ...op.patch };
}
