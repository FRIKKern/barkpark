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

import { blockToTiptap, buildPatchBlockOp } from "../convert.js";

// The doc-block kinds convert.js round-trips as prose (convert.js blockToTiptap
// switch). Anything not in this set is carried opaquely.
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

function isProseType(type) {
  return PROSE_TYPES.has(type);
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
//   NON-PROSE block → an opaque placeholder:
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

    // Opaque carry-through: the original block JSON, deep-cloned (no shared refs).
    return {
      type: "bpOpaque",
      attrs: { bpId, bpType, bpBlock: deepClone(block) },
    };
  });

  return { type: "doc", content };
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

// The byte-significant projection of a prose node for change detection: its
// type, heading level (if any), and content — i.e. exactly the inputs to
// buildPatchBlockOp / tiptapToBlock. bpId/bpType are excluded so an identity
// move never looks like an edit.
function stableProseKey(node) {
  const level = node.attrs && node.attrs.level;
  return JSON.stringify({
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
    const bpType = (node.attrs && node.attrs.bpType) || node.type;
    const existing = bpId != null && prevIndex.has(bpId);
    const id = existing ? bpId : mintId(taken);
    return { id, bpType, node, isNew: !existing, isOpaque };
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

  // ── 4) PATCHES — surviving prose whose content changed ─────────────────────
  //
  // Byte-identical to the per-block editor's patch-block (buildPatchBlockOp).
  // A surviving opaque node is a no-op in v1 (opaque blocks just round-trip).
  for (const entry of nextSeq) {
    if (entry.isNew || entry.isOpaque) continue;
    const prevBlock = prevById.get(entry.id);
    const prevNode = runToTiptap([prevBlock]).content[0];
    if (proseNodeChanged(prevNode, entry.node)) {
      const bpType = entry.bpType || (prevBlock && prevBlock.type);
      ops.push(buildPatchBlockOp(nodeToDocEnvelope(entry.node), entry.id, bpType));
    }
  }

  return ops;
}

// Reconstruct a portable-doc block from a NEW nextSeq entry, carrying its
// CLIENT-MINTED id. PROSE → the convert.js patch fields plus { id, type };
// OPAQUE → its carried bpBlock verbatim, with the minted id stamped on (so
// move-block / later folds can key it). Every inserted block carries an id —
// that is what makes a front-insert / reorder expressible via move-block.
function nextNodeToBlock(entry) {
  const node = entry.node;
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
