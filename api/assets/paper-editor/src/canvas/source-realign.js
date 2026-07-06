// canvas/source-realign.js — PURE, DOM-free helpers for the P5 Markdown SOURCE-MODE
// id realignment. Split out of canvas/index.js (which calls customElements.define at
// module load and so cannot be imported in plain Node) so the realigner unit-tests in
// the smoke without a DOM — the SAME split-for-testability pattern as slash-insert.js.
//
// markdownToBlocks mints a FRESH id ("m-…") for every NATURAL block (heading /
// paragraph / list / callout / code / diagram / divider); only SENTINEL blocks carry
// their original id. So a blocksToMarkdown → markdownToBlocks round-trip is id-LOSSY
// for the common prose kinds. realignBlockIds maps the parsed blocks back onto the
// source baseline ids so runToOps emits a PATCH for an in-place edit (not a
// remove+insert storm) and NO op for an unchanged block.

import { blocksToMarkdown } from "../markdown.js";

// Structural deep clone of a block array — DOM/Node-API-free. Used to snapshot the
// source baseline so a later parse + realign never mutates the live this._blocks.
export function deepCloneBlocks(blocks) {
  const arr = Array.isArray(blocks) ? blocks : [];
  if (typeof structuredClone === "function") return structuredClone(arr);
  return JSON.parse(JSON.stringify(arr));
}

// REALIGN the ids of markdown-parsed blocks against the source baseline.
//
// Align the parsed blocks to the baseline by an LCS over a per-block SIGNATURE that is
// STABLE under an in-place text edit at the right granularity: the block's serialized
// markdown (blocksToMarkdown of the single block). Byte-identical blocks are LCS
// anchors and inherit their baseline id directly. The blocks BETWEEN two anchors (or
// before the first / after the last) are aligned POSITIONALLY: the k-th unmatched
// parsed block inherits the k-th unmatched baseline block's id in that gap. So:
//   • an UNCHANGED block (same md) → same id → runToOps sees no change → NO op;
//   • an in-place EDITED block (e.g. a heading whose text changed) sits alone in a gap
//     between unchanged anchors → it inherits the baseline id at its slot → runToOps
//     sees the SAME id with changed content → exactly ONE patch-block;
//   • an INSERTED block has no baseline slot in its gap → it KEEPS its minted id →
//     runToOps mints/inserts it (one insert-after);
//   • a REMOVED block leaves a baseline id with no parsed taker → runToOps removes it.
// An id is never assigned twice (each baseline id is consumed at most once), so the
// "duplicate id" guard runToOps relies on holds.
export function realignBlockIds(baselineBlocks, parsedBlocks) {
  const baseline = Array.isArray(baselineBlocks) ? baselineBlocks : [];
  const parsed = Array.isArray(parsedBlocks) ? parsedBlocks : [];
  if (parsed.length === 0) return parsed;

  // Per-block signature: the markdown of that single block. Identical md ⇒ an
  // identical block (the converter is a fixed point), so this keys the anchors.
  const sig = (b) => blocksToMarkdown([b]);
  const baseSig = baseline.map(sig);
  const parsedSig = parsed.map(sig);

  // LCS DP over the two signature sequences.
  const n = baseSig.length;
  const m = parsedSig.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] =
        baseSig[i] === parsedSig[j]
          ? dp[i + 1][j + 1] + 1
          : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  // Walk the LCS: matchedBaseForParsed[j] = the baseline index parsed[j] anchors to
  // (or -1 when parsed[j] is not part of the common subsequence).
  const matchedBaseForParsed = new Array(m).fill(-1);
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (baseSig[i] === parsedSig[j]) {
      matchedBaseForParsed[j] = i;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }

  // Signature multiplicity in the baseline — a sig appearing more than once is a
  // DUPLICATE (e.g. two byte-identical paragraphs). For a unique sig the LCS anchor
  // index is unambiguous; for a duplicate it is NOT (the LCS greedy walk may pin the
  // anchor to a FAR instance, stranding a NEAR one for a later non-anchor to grab and
  // forcing a spurious move). For duplicates we therefore IGNORE the LCS-chosen index
  // and break the tie POSITIONALLY: donate the nearest still-unconsumed baseline id of
  // that signature at or after baseCursor. Each baseline id is consumed at most once
  // (the `consumed` set), so the duplicate-id guard runToOps relies on still holds.
  const sigCount = new Map();
  for (const s of baseSig) sigCount.set(s, (sigCount.get(s) || 0) + 1);
  const isDuplicateSig = (s) => (sigCount.get(s) || 0) > 1;

  const out = parsed.map((b) => ({ ...b }));
  const consumed = new Set(); // baseline indices whose id has been donated
  let baseCursor = 0; // next baseline index to consider as a positional donor

  // Nearest unconsumed baseline index AT OR AFTER `from`, optionally requiring a
  // matching signature and an upper bound. Returns -1 when none. This is the single
  // positional-nearest rule shared by the anchor (duplicate) and non-anchor branches.
  const nearestDonor = (from, sig, upper) => {
    for (let bi = from; bi < upper; bi++) {
      if (consumed.has(bi)) continue;
      if (sig != null && baseSig[bi] !== sig) continue;
      return bi;
    }
    return -1;
  };

  for (let k = 0; k < m; k++) {
    const anchor = matchedBaseForParsed[k];
    if (anchor !== -1) {
      // Anchor. For a UNIQUE sig the LCS index is the right (only) one. For a
      // DUPLICATE sig, redirect to the NEAREST unconsumed baseline of that sig at or
      // after baseCursor (positional tie-break), so an equal-signature run never
      // churns. Fall back to the LCS index if (impossibly) none is free.
      const sig = parsedSig[k];
      let donor = anchor;
      if (isDuplicateSig(sig)) {
        const near = nearestDonor(baseCursor, sig, n);
        if (near !== -1) donor = near;
      }
      out[k].id = baseline[donor].id;
      consumed.add(donor);
      baseCursor = donor + 1;
      continue;
    }
    // Non-anchor (edit or insert). The gap's upper bound is the NEXT anchored baseline
    // index after baseCursor; donate the first UNCONSUMED baseline id at or after
    // baseCursor that is below that bound. If none exists, this parsed block is a
    // genuine INSERT — keep its minted id.
    let nextAnchorBase = n;
    for (let p = k + 1; p < m; p++) {
      if (matchedBaseForParsed[p] !== -1) {
        nextAnchorBase = matchedBaseForParsed[p];
        break;
      }
    }
    const donor = nearestDonor(baseCursor, null, nextAnchorBase);
    if (donor !== -1) {
      out[k].id = baseline[donor].id;
      consumed.add(donor);
      baseCursor = donor + 1;
    }
    // else: genuine insert → keep the minted id (out[k].id already the minted one).
  }

  return out;
}

// CLAMP the doctrine locked-template PREFIX after a source-mode round-trip.
//
// Markdown SOURCE mode (Mod-Shift-m) lets the user edit the raw markdown of a run
// freely — including the locked title block that opens a doctrine template
// (Content.Papers.Template: locked title @0, featured image @1). The SERVER rejects
// any op that removes / moves / displaces a locked block (the `{:locked_block, id,
// op}` class in patch.ex) — but without this clamp the CLIENT view DIVERGES until
// reload: the rich editor would show the user's deleted / reordered title even
// though the save was vetoed server-side.
//
// This is the FELT half of D4 for source mode — the twin of locks.js
// `transactionVetoesLock` (which vetoes the same displacements at the rich editor's
// filterTransaction layer). Locks are PLACEMENT locks (doctrine rule 2): the server
// strips only `locked`/`role` from a patch-block and ACCEPTS a content edit, and the
// rich editor passes a pure content edit too ("A pure content edit keeps the locked
// node's id + index, so it passes"). The clamp therefore pins the locked run's
// PLACEMENT + template identity (id / type / locked / role, at the head) while a
// same-type CONTENT edit rides through as the exact patch-block the server accepts —
// a source-mode retitle behaves like a rich-mode retitle, one surface (rule 5).
//
// Behaviors:
//   • title text EDITED in source       → edit KEPT (server-accepted patch-block);
//     the template identity (id/type/locked/role) and head position are restored,
//     so the md round-trip dropping `locked` never blinds the live veto;
//   • title DELETED in source            → restored verbatim (delete dropped);
//   • title MOVED below a paragraph       → pinned back to the head (move dropped);
//   • a block INSERTED before the title   → lands AFTER it (the prefix holds pos 0);
//   • title RETYPED to another block kind → the locked block is restored verbatim
//     (the server would veto the swap) and the user's block SURVIVES in place under
//     a fresh id — never silent data loss;
//   • body edits (non-locked blocks)      → preserved unchanged.
//
// Additive (D3): a baseline with NO leading locked block returns `realigned`
// untouched — a template-free paper's source round-trip stays byte-identical.
export function clampLockedPrefix(baselineBlocks, realignedBlocks) {
  const baseline = Array.isArray(baselineBlocks) ? baselineBlocks : [];
  const realigned = Array.isArray(realignedBlocks) ? realignedBlocks : [];

  // The leading RUN of locked blocks in the baseline — the doctrine template
  // prefix. A block carries `locked === true` at the top level (the bp-attrs
  // round-trip; D3-additive, so an unlocked block has no `locked` key at all).
  const prefix = [];
  for (const b of baseline) {
    if (b && b.locked === true) prefix.push(b);
    else break;
  }
  if (prefix.length === 0) return realigned; // no template → nothing to clamp

  // realignBlockIds may have DONATED a locked id to a parsed block: the in-place
  // content edit of that locked block (same type — its TAKER), or, when the user
  // deleted the locked block and typed something new in its slot, an unrelated
  // block that merely inherited the id positionally (type mismatch). Split the
  // realigned list: same-type takers fold into the restored prefix (content edit
  // kept); a type-mismatched id-squatter is USER CONTENT — re-mint its id and keep
  // it in place (runToOps inserts it; the restored prefix stays the sole carrier
  // of each locked id, so the duplicate-id guard holds).
  const baseById = new Map(prefix.map((b) => [b.id, b]));
  const takers = new Map();
  let tail = [];
  for (const b of realigned) {
    if (!(b && baseById.has(b.id))) {
      tail.push(b);
    } else if (b.type === baseById.get(b.id).type && !takers.has(b.id)) {
      takers.set(b.id, b);
    } else {
      tail.push({ ...b, id: mintClampId() });
    }
  }

  // A PURE MOVE of a locked block leaves its byte-identical copy in the tail
  // under a freshly MINTED id (realignBlockIds anchors the other survivors, so
  // the displaced copy gets no baseline id). Restoring the prefix without
  // dropping that copy would DUPLICATE the block (one restored + one inserted).
  // For each locked block with no taker, drop the first minted tail block whose
  // per-block markdown signature is byte-identical — that IS the moved copy. A
  // same-text block the user already had in the body keeps its baseline id and
  // is never touched.
  const baselineIds = new Set(baseline.map((b) => b && b.id));
  const sig = (b) => blocksToMarkdown([b]);
  for (const base of prefix) {
    if (takers.has(base.id)) continue;
    const baseSig = sig(base);
    const copyAt = tail.findIndex(
      (b) => b && !baselineIds.has(b.id) && sig(b) === baseSig,
    );
    if (copyAt !== -1) tail = tail.slice(0, copyAt).concat(tail.slice(copyAt + 1));
  }

  // Rebuild the locked prefix AT THE HEAD (deep-cloned so the caller never shares
  // structure with this._sourceBaselineBlocks). A taker's content edit overlays the
  // baseline block; the template identity keys are then re-stamped from the
  // baseline — the md round-trip drops `locked`/`role` for natural blocks, and the
  // server strips them from patches anyway, so the baseline is their one truth.
  const head = prefix.map((base) => {
    const taker = takers.get(base.id);
    const [cleanBase] = deepCloneBlocks([base]);
    if (!taker) return cleanBase; // deleted (or untouched-sentinel) → verbatim
    const [cleanTaker] = deepCloneBlocks([taker]);
    const merged = { ...cleanBase, ...cleanTaker, id: base.id, type: base.type };
    merged.locked = true;
    if (base.role != null) merged.role = base.role;
    else delete merged.role;
    return merged;
  });

  return [...head, ...tail];
}

// Mint an id for a block that positionally inherited a LOCKED id in source mode
// (its slot's block was locked; the user's replacement is ordinary content). The
// "s-" prefix marks a source-clamp mint (parallels markdown.js "m-" and
// run-convert.js "c-"); high-entropy nonce so it never collides with a server id.
let clampMintCounter = 0;
function mintClampId() {
  clampMintCounter += 1;
  const nonce =
    typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
      ? crypto.randomUUID().slice(0, 8)
      : Math.random().toString(36).slice(2, 10);
  return "s-" + clampMintCounter.toString(36) + "-" + nonce;
}
