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

import { blocksToMarkdown, markdownToBlocks, markdownToBlockSpans } from "../markdown.js";
import { idCarriesKind } from "./run-convert.js";

// A block's Markdown without its id. A <!--bp:block--> line holds the id, and a
// block the writer typed (a soft line break, a table) parses under a minted one, so
// every "is it the same block" check compares this.
function contentSig(block) {
  return blocksToMarkdown([{ ...block, id: "" }]);
}

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

  // Per-block signature: the markdown of that single block, without its id.
  // Identical md ⇒ an identical block (the converter is a fixed point), so this
  // keys the anchors.
  const baseSig = baseline.map(contentSig);
  const parsedSig = parsed.map(contentSig);

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
  // matching signature, an upper bound and a kind the donor's id can carry over to
  // `block` (idCarriesKind: a paragraph a half-typed fence turned into code is a new
  // block, not a typeless patch the server would merge into the paragraph). Returns
  // -1 when none. This is the single
  // positional-nearest rule shared by the anchor (duplicate) and non-anchor branches.
  const nearestDonor = (from, sig, upper, block) => {
    for (let bi = from; bi < upper; bi++) {
      if (consumed.has(bi)) continue;
      if (sig != null && baseSig[bi] !== sig) continue;
      if (block && !idCarriesKind(baseline[bi], block)) continue;
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
    const donor = nearestDonor(baseCursor, null, nextAnchorBase, parsed[k]);
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
// REALIGN across source commits (1.20.0). A source session commits many times, so
// a parsed block has two possible donors: the LAST commit (lastBlocks) and the
// ENTER baseline (enterBlocks). The last commit goes first: it is the text the
// writer is typing on, so a block born in this session keeps the id it was sent
// with (a patch-block, not remove + insert on every flush), and a block typed into
// never trades ids with its neighbour. Then every block still holding a freshly
// minted id is realigned against the enter blocks the last commit lacks, so a block
// a half-typed construct swallowed in an earlier commit gets its original id back.
// With one commit (lastBlocks = the enter baseline) the second pass has no donors,
// so this is realignBlockIds exactly.
export function realignAcrossCommits(enterBlocks, lastBlocks, parsedBlocks) {
  const first = realignBlockIds(lastBlocks, parsedBlocks);
  const lastIds = new Set(lastBlocks.map((b) => b.id));
  const fresh = first.flatMap((b, i) => (lastIds.has(b.id) ? [] : [i]));
  if (fresh.length === 0) return first;
  const donors = enterBlocks.filter((b) => !lastIds.has(b.id));
  const again = realignBlockIds(donors, fresh.map((i) => first[i]));
  fresh.forEach((i, k) => { first[i] = again[k]; });
  return first;
}

// The source text for `blocks` that keeps the writer's own text (1.20.0). `before`
// are the blocks `text` was last saved as; realignBlockIds gives each block of
// `text` its id (the clamp of a locked title can make the two differ). Each block
// whose id and Markdown are unchanged keeps its original lines; every other block is
// written as blocksToMarkdown writes it. A block keeps its lines only if they end it
// on their own (an unclosed fence runs to the end of the text and would swallow
// whatever the merge puts after it). So a server change rewrites only the blocks it
// touched, and `* item` or `__bold__` the writer typed elsewhere stays as typed.
//
// The writer's blank lines stay with the block above them: the lines above the first
// block always stay; the lines after the last block always travel with it, plus one
// blank line when a block now follows it; the lines after any other block travel
// with it when they hold a blank line, when the next block is kept and still its
// neighbour, or when it ends the text. Elsewhere a block is followed by one blank
// line, and a new last block by none. So a caret on a blank line the writer opened
// stays on a blank line, and the next key starts a new block.
//
// `map(at, stayBefore)` moves an offset of `text` into the new text by block id: in
// an unchanged block it keeps its place in that block wherever the block moved; in a
// changed block it maps through the change (before it, it stays; at or after its
// end, it moves with the text; inside it, it goes to the end of the new text, or
// stays before an insertion at its own place when `stayBefore`), and never between
// the halves of a surrogate pair. An offset above the first block stays; one in the
// blank lines after a block keeps its place in them (lines that hold an offset hold a
// blank line, so they always travel). In a deleted block it goes to the end of the
// nearest block a typed letter only lengthens (not a divider, not a closed fence),
// looking back first.
export function mergeSourceText(text, before, blocks) {
  const { blocks: parsed, spans } = markdownToBlockSpans(text);
  const offsets = [0];
  for (const line of text.split("\n")) offsets.push(offsets[offsets.length - 1] + line.length + 1);
  const start = (k) => offsets[spans[k][0]];
  const end = (k) => offsets[spans[k][1]] - 1;
  const sig = (block) => blocksToMarkdown([block]);
  const was = new Map(realignBlockIds(before, parsed).map((block, k) => [block.id, k]));
  const endsItself = (k) => {
    const alone = markdownToBlocks(text.slice(start(k), end(k)) + "\n\n.");
    return alone.length === 2 && contentSig(alone[0]) === contentSig(parsed[k]);
  };
  const pieces = blocks.map((block) => {
    const k = was.get(block.id) ?? -1;
    const own = k !== -1 && contentSig(parsed[k]) === contentSig(block) && endsItself(k);
    return { k, own, text: own ? text.slice(start(k), end(k)) : sig(block) };
  });
  const gapAfter = (k) => text.slice(end(k), k + 1 < parsed.length ? start(k + 1) : text.length);
  const seps = pieces.map((piece, j) => {
    const next = pieces[j + 1];
    if (piece.k === -1) return next ? "\n\n" : "";
    const gap = gapAfter(piece.k);
    if (piece.k + 1 === parsed.length) return next ? gap + "\n\n" : gap;
    const travels = !next || gap.split("\n").length > 2 || (piece.own && next.own && next.k === piece.k + 1);
    return travels ? gap : "\n\n";
  });
  const lead = parsed.length ? text.slice(0, start(0)) : text;
  let out = lead;
  const at = [];
  pieces.forEach((piece, j) => {
    at.push(out.length);
    out += piece.text + seps[j];
  });
  const lengthens = (i) => blocksToMarkdown(markdownToBlocks(pieces[i].text + "x")) === sig(blocks[i]) + "x";
  const landNear = (k) => {
    const near = pieces.map((piece, i) => i).sort((x, y) => rank(pieces[x].k, k) - rank(pieces[y].k, k));
    const i = near.find(lengthens) ?? near[0];
    return at[i] + pieces[i].text.length;
  };
  const map = (offset, stayBefore) => {
    let k = -1;
    while (k + 1 < parsed.length && start(k + 1) <= offset) k++;
    if (k === -1) return offset;
    const j = pieces.findIndex((piece) => piece.k === k);
    if (j === -1) return landNear(k);
    if (offset > end(k)) return at[j] + pieces[j].text.length + offset - end(k);
    const own = text.slice(start(k), end(k));
    return at[j] + through(sig(parsed[k]), pieces[j].text, through(own, sig(parsed[k]), offset - start(k), stayBefore), stayBefore);
  };
  return { text: out, map };
}

// Which block a caret from deleted block `k` goes to first: the blocks before it,
// nearest first, then the ones after it, then the new ones.
function rank(from, k) {
  if (from === -1) return Number.MAX_SAFE_INTEGER;
  return from < k ? k - from : from;
}

function through(before, after, at, stayBefore) {
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  let tail = 0;
  while (tail < before.length - start && tail < after.length - start &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  if (tail > 0 && /[\udc00-\udfff]/.test(before[before.length - tail])) tail--;
  if (at <= start && (stayBefore || at < before.length - tail)) return at;
  if (at >= before.length - tail) return at + after.length - before.length;
  return after.length - tail;
}

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
  for (const base of prefix) {
    if (takers.has(base.id)) continue;
    const baseSig = contentSig(base);
    const copyAt = tail.findIndex(
      (b) => b && !baselineIds.has(b.id) && contentSig(b) === baseSig,
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
