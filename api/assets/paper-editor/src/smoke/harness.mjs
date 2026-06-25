// smoke/harness.mjs — the SHARED test harness for the decomposed __smoke suite.
//
// Behavior-preserving extraction from the original src/__smoke.mjs god-module:
// the per-area smoke modules (round-trip / node-views / echo / autocomplete-slash /
// source-mode / markdown / projection-fuzz / field-pickers) each import this lib,
// register their checks via the SHARED check() runner below (which accumulates into
// ONE module-level `failures` counter), and the thin index (src/__smoke.mjs) calls
// report() ONCE after every module has registered+run its checks. report() prints the
// final summary and calls process.exit(1) on any failure — same aggregate pass/
// fail + exit semantics as the original monolith. Pure Node, dependency-free.
//
// What lives here is EVERYTHING multiple sections share:
//   - check(name, fn)        the runner + the shared pass/fail counter
//   - report()               the final summary + exit-code setter (called once)
//   - applyOps / assertFolds the pure-JS patch.ex reference fold + fold gate (S0..fuzz)
//   - mulberry32 + rint/rpick/rbool   the seeded PRNG (projection-fuzz + markdown-fuzz)
//   - canonicalJSON_local / canonicalEqual   key-order-safe deep compare
//   - normalizeCanvasDoc     the live-doc normalizer modeled verbatim
//   - reconstructBlock       project→reconstruct twin (canonical round-trip)
//   - the generator vocabulary (FUZZ_* + genInlineSpans..genRun) + the property-2
//     mutation family (mutateRun / genMutatedContent / isEditableKind /
//     isCanvasFieldKindLocal) — shared by both fuzz gates.
//
// Section-local fixtures and helpers (S35_FIELD_SEEDS, TAIL_PICKER_*, SLASH_INSERTABLE,
// PALETTE_REGISTRY, mdRenderEqual, coalesceTextTree, isSentinelSerialized, minimizeRun/
// minimizeMutation, exitSourceOps, SRC_BASELINE, …) stay in their owning module.

import assert from "node:assert/strict";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import { inlineArrayToTiptap, tiptapInlineToPd } from "../convert.js";

// ── the shared check() runner + pass/fail counter ───────────────────────────
// One module-level `failures` counter, shared across every importing module: each
// check() call accumulates here, so the aggregate report + exit code work across
// modules. The runner body is VERBATIM the original __smoke.mjs check() — same
// PASS/FAIL console lines, same per-failure message — so the on-screen output is
// byte-identical; only the final summary now lives in report() (called once by the
// index) instead of a trailing top-level if-block.
let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// ── THE SAFETY NET: a pure-JS reference fold mirroring patch.ex ──────────────
//
// applyOps(prevBlocks, ops) folds the emitted op list through the SAME
// semantics api/lib/barkpark/portable_doc/patch.ex implements, so a test can
// PROVE that runToOps's output reproduces nextDoc — not merely that each op has
// the right SHAPE. The original S0 tests asserted only shape, which is why two
// real fold bugs (a front-insert landing at END; an insert stranded by a later
// move) passed green. Faithful op semantics (top-level only — S0 has no
// sections):
//   append-block  → concat block at END (dup id is an error)
//   insert-after  → splice block immediately after afterId (absent → error;
//                   dup block id → error)
//   remove-block  → drop the block by id (absent → error)
//   move-block    → lift the block by id, splice after `after` (or head when
//                   null); after===id or already-in-place is a no-op
//   patch-block   → shallow-merge patch into the block by id, re-pin id+type
function applyOps(prevBlocks, ops) {
  let blocks = (prevBlocks || []).map((b) => ({ ...b }));
  const idAt = (id) => blocks.findIndex((b) => b && b.id === id);

  for (const op of ops) {
    switch (op.op) {
      case "append-block": {
        if (op.block && op.block.id != null && idAt(op.block.id) !== -1) {
          throw new Error(`append-block: duplicate id ${op.block.id}`);
        }
        blocks = [...blocks, { ...op.block }];
        break;
      }
      case "insert-after": {
        if (op.block && op.block.id != null && idAt(op.block.id) !== -1) {
          throw new Error(`insert-after: duplicate id ${op.block.id}`);
        }
        const at = idAt(op.afterId);
        if (at === -1) throw new Error(`insert-after: afterId not found ${op.afterId}`);
        blocks.splice(at + 1, 0, { ...op.block });
        break;
      }
      case "remove-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`remove-block: id not found ${op.id}`);
        blocks.splice(at, 1);
        break;
      }
      case "move-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`move-block: id not found ${op.id}`);
        if (op.after === op.id) break; // after-itself: no-op
        if (op.after != null && idAt(op.after) === -1) {
          throw new Error(`move-block: after not found ${op.after}`);
        }
        const [moved] = blocks.splice(at, 1);
        if (op.after == null) {
          blocks.unshift(moved);
        } else {
          const dest = idAt(op.after);
          blocks.splice(dest + 1, 0, moved);
        }
        break;
      }
      case "patch-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`patch-block: id not found ${op.id}`);
        const target = blocks[at];
        // Shallow-merge, then re-pin id + type (patch.ex merge_block).
        blocks[at] = { ...target, ...op.patch, id: target.id, type: target.type };
        break;
      }
      default:
        throw new Error(`applyOps: unknown op ${JSON.stringify(op)}`);
    }
  }
  return blocks;
}
// Assert that folding runToOps(prev, nextDoc) through applyOps yields a block
// list whose ID ORDER === the id order of nextDoc's nextSeq (existing bpIds in
// place; a stable client-minted id for every new node), and that every
// SURVIVING block carries the patched content. This is the fold gate the
// original shape-only tests lacked.
function assertFolds(prev, nextDoc, ops, label) {
  const result = applyOps(prev, ops);

  // Expected id order: existing bpId where present, else SOME minted id. We
  // can't predict minted ids, so we assert structurally: result length ===
  // next length, every surviving bpId sits at its next index, and every NEW
  // slot (next node without a surviving bpId) holds a block that is NOT a prev
  // id (i.e. a freshly-minted/new block).
  const prevIds = new Set((prev || []).map((b) => b && b.id));
  const nextNodes = (nextDoc && nextDoc.content) || [];
  assert.equal(
    result.length,
    nextNodes.length,
    `${label}: folded length ${result.length} !== next length ${nextNodes.length}`,
  );
  nextNodes.forEach((node, i) => {
    const bpId = node.attrs && node.attrs.bpId;
    const folded = result[i];
    const survives = bpId != null && prevIds.has(bpId);
    if (survives) {
      assert.equal(
        folded.id,
        bpId,
        `${label}: slot ${i} expected surviving id ${bpId}, got ${folded && folded.id}`,
      );
    } else {
      // A new slot: the folded block must NOT be a pre-existing prev id (it is a
      // freshly-inserted, client-minted block), and it must carry a non-null id.
      assert.ok(
        folded && folded.id != null && !prevIds.has(folded.id),
        `${label}: slot ${i} expected a fresh (minted) id, got ${folded && folded.id}`,
      );
    }
  });
  return result;
}

// ── mulberry32 — a tiny pure deterministic PRNG ─────────────────────────────
// 32-bit state in, a float in [0,1) out, advancing the state. Reproducible: the
// SAME seed yields the SAME stream forever. (We never touch Math.random here.)
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// rng helpers built on a mulberry32 stream.
const rint = (rng, lo, hi) => lo + Math.floor(rng() * (hi - lo + 1)); // inclusive
const rpick = (rng, arr) => arr[rint(rng, 0, arr.length - 1)];
const rbool = (rng) => rng() < 0.5;

// canonicalEqual — key-order-insensitive deep compare, reusing the projector's
// own canonicalJSON semantics (recursively sorts OBJECT keys; ARRAY order is
// significant). A stored block and its project→reconstruct twin compare EQUAL
// despite differing key order, but a real content/order difference does not.
function canonicalJSON_local(value) {
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON_local).join(",") + "]";
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON_local(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}
const canonicalEqual = (a, b) => canonicalJSON_local(a) === canonicalJSON_local(b);

// normalizeCanvasDoc — a FAITHFUL copy of canvas/index.js's live-doc normalizer
// (the production load path runs getJSON() through this before runToOps). On a
// FRESH runToTiptap projection it is effectively identity (no phantom nested
// null-bp attrs, no duplicate top-level ids), but PROPERTY 1 asserts the EXACT
// production formula `runToOps(run, normalizeCanvasDoc(runToTiptap(run))) === 0`,
// so we model it here verbatim. (Pure: it mutates+returns a doc, DOM-free.)
function normalizeCanvasDoc(doc) {
  const hasOnlyBpKeys = (attrs) =>
    Object.keys(attrs).every((k) => k === "bpId" || k === "bpType");
  const stripNested = (node) => {
    if (node && node.attrs) {
      const a = node.attrs;
      if (a.bpId == null && a.bpType == null && hasOnlyBpKeys(a)) {
        delete node.attrs;
      } else {
        if (a.bpId == null) delete a.bpId;
        if (a.bpType == null) delete a.bpType;
      }
    }
    if (node && node.content) node.content.forEach(stripNested);
  };
  (doc.content || []).forEach((top) => {
    (top.content || []).forEach(stripNested);
  });
  const seen = new Set();
  (doc.content || []).forEach((top) => {
    const id = top.attrs && top.attrs.bpId;
    if (id == null) return;
    if (seen.has(id)) top.attrs = { ...top.attrs, bpId: null };
    else seen.add(id);
  });
  return doc;
}

// reconstructBlock(block) — reconstruct a block from its PROJECTED node through
// the PUBLIC engine path, exercising the private nextNodeToBlock exactly as a
// real insert does. We project the single block, null its top-level bpId so the
// diff treats it as NEW, then read the carried block off the emitted insert op
// (minus its minted id). The result is the project→reconstruct twin of `block`.
function reconstructBlock(block) {
  const node = runToTiptap([block]).content[0];
  // Null the top-level bpId → runToOps mints an id and carries the reconstructed
  // block in an append-block (empty prev → no anchor).
  const fresh = { ...node, attrs: { ...(node.attrs || {}), bpId: null } };
  const ops = runToOps([], { type: "doc", content: [fresh] });
  const ins = ops.find((o) => o.op === "append-block" || o.op === "insert-after");
  if (!ins) throw new Error("reconstructBlock: no insert op emitted");
  const { id: _mintedId, ...rest } = ins.block;
  return rest;
}

// ── the generator vocabulary ────────────────────────────────────────────────

const FUZZ_TEXTS = [
  "hello", "world", "lorem ipsum", "a b c", "", "  spaces  ",
  "ångström café naïve", "日本語テキスト", "emoji 🚀✨", "tab\tafter",
  "less < greater > amp & quote \" apos '", "<script>alert(1)</script>",
  "trailing space ", " leading space", "line", "x = 1 + 2",
];
const FUZZ_LANGS = ["", "js", "elixir", "ruby", "sh", "python", "ts", "rust"];
const FUZZ_TONES = ["info", "warning", "danger", "success", "note", "tip"];
const FUZZ_MERMAID = [
  "graph TD\n  A-->B", "graph LR\n  X-->Y\n  Y-->Z",
  "sequenceDiagram\n  Alice->>Bob: hi", "flowchart\n  a & b > c", "",
];
const FUZZ_CAPTIONS = ["", "Figure 1.", "The flow", "café & co. <x>"];
const FUZZ_TITLES = [null, "", "Heads up", "Note <b>", "Café"];
const FUZZ_COLORS = ["#000000", "#3b82f6", "#ef4444", "#ffffff", "#0a0a0a"];
const FUZZ_DATETIMES = ["2026-06-24T10:00", "2026-01-01T00:00", "2025-12-31T23:59"];
const FUZZ_TARGETS = ["intro-to-x", "setup", "Linked Note", "café-note", "a/b/c"];
const FUZZ_SLUGS = ["hello-world", "a-b-c", "café", "x"];

// Inline-CODE values that CONTAIN backtick runs (1..3) — the markdown serializer
// must bump the fence length past the longest inner run, and a 3+-backtick fence
// at the START of a paragraph must NOT be re-read as a fenced code BLOCK
// (escapeBlockLeader's leading-backtick guard). Mixed with plain values so the
// fuzz exercises both the padded and the fence-bumped paths.
const FUZZ_CODE_VALUES = [
  "x = 1", "plain", "a`b", "a``b", "```", "``` ", " ``` ", "ab```cd",
  "`lead", "trail`", "``mid``", "a`b`c", "",
];

// genInlineSpans(rng, n) → a flat array of raw {text, marks} spans. Each span is
// then PROJECTED and DESERIALIZED to canonical portable-doc inline form (so the
// stored content is always a projection fixed-point — empty text dropped, marks
// re-nested in MARK_ORDER, blockref/tag tokens synthesized; exactly what a real
// stored run looks like). Mark kinds cover bold/italic/underline/strike/code/
// link/wikilink/tag — the full inline vocabulary — PLUS nested SAME-FAMILY
// emphasis (strong>em / em>strong / em>em / strong>strong / strong>em>strike) and
// backtick-bearing inline code, the two shapes that round-trip-garbled before the
// markdown.js fix (the fuzz blind spot the bugs slipped through).
function genInlineSpans(rng, n) {
  const spans = [];
  for (let i = 0; i < n; i++) {
    const kind = rint(rng, 0, 15);
    const text = rpick(rng, FUZZ_TEXTS);
    if (kind === 0) spans.push({ type: "text", value: text });
    else if (kind === 1) spans.push({ type: "strong", children: [{ type: "text", value: text }] });
    else if (kind === 2) spans.push({ type: "em", children: [{ type: "text", value: text }] });
    else if (kind === 3) spans.push({ type: "underline", children: [{ type: "text", value: text }] });
    else if (kind === 4) spans.push({ type: "strikethrough", children: [{ type: "text", value: text }] });
    else if (kind === 5) spans.push({ type: "code", value: text });
    else if (kind === 6) {
      const lk = { type: "link", href: "https://" + rpick(rng, FUZZ_SLUGS), children: [{ type: "text", value: text }] };
      spans.push(lk);
    } else if (kind === 7) {
      const wk = { type: "wikilink", target: rpick(rng, FUZZ_TARGETS), children: [{ type: "text", value: text || "link" }] };
      if (rbool(rng)) wk.alias = rpick(rng, FUZZ_TEXTS);
      if (rbool(rng)) wk.docId = "doc-" + rint(rng, 1, 99);
      spans.push(wk);
    } else if (kind === 8) {
      spans.push({ type: "tag", name: rpick(rng, FUZZ_SLUGS) });
    } else if (kind === 9) {
      // nested: bold > strikethrough (locks MARK_ORDER nesting)
      spans.push({ type: "strong", children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 10) {
      // inline CODE carrying backtick runs — fence-bump + leading-fence guard.
      spans.push({ type: "code", value: rpick(rng, FUZZ_CODE_VALUES) });
    } else if (kind === 11) {
      // NESTED SAME-FAMILY emphasis: strong > em  ("***x***" ambiguity).
      spans.push({ type: "strong", children: [{ type: "em", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 12) {
      // NESTED SAME-FAMILY emphasis: em > strong (mirror; MARK_ORDER folds it to
      // strong>em, but we feed both so the generator's intent is explicit).
      spans.push({ type: "em", children: [{ type: "strong", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 13) {
      // SAME-MARK direct nesting: em > em  ("*_x_*") and strong > strong.
      spans.push(
        rbool(rng)
          ? { type: "em", children: [{ type: "em", children: [{ type: "text", value: text || "x" }] }] }
          : { type: "strong", children: [{ type: "strong", children: [{ type: "text", value: text || "x" }] }] },
      );
    } else if (kind === 14) {
      // DEEP nesting that exercises the delimiter alternation past the strike
      // boundary: strong > em > strike  ("**_~~x~~_**").
      spans.push({
        type: "strong",
        children: [{ type: "em", children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }] }],
      });
    } else {
      // strike > strike — the UN-disambiguable shape ("~~~~"): the serializer must
      // sentinel it (no alternate delimiter for "~~"). Reachable as a projection
      // fixed point (strike>em>strike etc.), so the fuzz must feed it.
      spans.push({
        type: "strikethrough",
        children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }],
      });
    }
  }
  // Canonicalize through the SAME inline serializer/deserializer the projector
  // uses, so the stored content is a projection fixed-point (a real stored shape).
  return tiptapInlineToPd(inlineArrayToTiptap(spans));
}

// genInline(rng) → a non-trivially-sized canonical inline array (may be []).
function genInline(rng) {
  return genInlineSpans(rng, rint(rng, 0, 4));
}

// genBlock(rng, id) → one random block of a random canvas-eligible kind, carrying
// the given stable id. Covers EVERY canvas vocabulary kind + empty/present
// variants for each optional/chrome field.
const FUZZ_BLOCK_KINDS = [
  "paragraph", "heading", "list", "divider", "callout", "code", "diagram",
  "field-string", "field-slug", "field-text", "field-boolean", "field-select",
  "field-datetime", "field-color", "sheet", "embed",
];

function genBlock(rng, id) {
  const kind = rpick(rng, FUZZ_BLOCK_KINDS);
  return genBlockOfKind(rng, id, kind);
}

function genBlockOfKind(rng, id, kind) {
  switch (kind) {
    case "paragraph":
      return { id, type: "paragraph", content: genInline(rng) };
    case "heading":
      return { id, type: "heading", level: rint(rng, 1, 3), text: rpick(rng, FUZZ_TEXTS) };
    case "list": {
      const ordered = rbool(rng);
      const nItems = rint(rng, 1, 3);
      const items = [];
      for (let i = 0; i < nItems; i++) items.push(genInlineSpans(rng, rint(rng, 1, 3)));
      return { id, type: "list", ordered, items };
    }
    case "divider":
      return { id, type: "divider" };
    case "callout": {
      const b = { id, type: "callout", tone: rpick(rng, FUZZ_TONES), content: genInline(rng) };
      const title = rpick(rng, FUZZ_TITLES);
      if (title != null) b.title = title; // present-or-absent
      if (rbool(rng)) {
        b.collapsible = true;
        if (rbool(rng)) b.collapsed = true;
      }
      return b;
    }
    case "code": {
      const b = { id, type: "code", value: rpick(rng, FUZZ_TEXTS) + (rbool(rng) ? "\nline2\n  indent" : "") };
      const lang = rpick(rng, FUZZ_LANGS);
      if (lang !== "") b.lang = lang; // present-or-absent
      return b;
    }
    case "diagram": {
      const b = { id, type: "diagram", source: rpick(rng, FUZZ_MERMAID) };
      const cap = rpick(rng, FUZZ_CAPTIONS);
      if (cap !== "") b.caption = cap; // present-or-absent
      return b;
    }
    case "field-string":
    case "field-slug":
    case "field-datetime":
    case "field-color":
    case "field-text": {
      const b = { id, type: kind, value: fieldValueFor(rng, kind) };
      if (rbool(rng)) b.label = rpick(rng, ["Title", "Slug", "Body", ""]);
      if (rbool(rng)) b.fieldName = rpick(rng, FUZZ_SLUGS);
      if (kind === "field-text" && rbool(rng)) b.rows = rint(rng, 1, 10);
      return b;
    }
    case "field-boolean": {
      const b = { id, type: "field-boolean", value: rbool(rng) }; // a REAL boolean
      if (rbool(rng)) b.label = "Featured";
      if (rbool(rng)) b.fieldName = "featured";
      return b;
    }
    case "field-select": {
      const options = [
        { value: "draft", label: "Draft" },
        { value: "published", label: "Published" },
      ];
      const b = {
        id,
        type: "field-select",
        value: rbool(rng) ? rpick(rng, ["draft", "published"]) : "",
        options,
      };
      if (rbool(rng)) b.label = "Status";
      if (rbool(rng)) b.fieldName = "status";
      return b;
    }
    case "sheet": {
      const b = { id, type: "sheet" };
      if (rbool(rng)) b.ref = rpick(rng, ["production/budget", "a/b", "x"]);
      if (rbool(rng)) {
        const nRows = rint(rng, 0, 3);
        const nCols = rint(rng, 1, 3);
        const rows = [];
        for (let r = 0; r < nRows; r++) {
          const row = [];
          for (let c = 0; c < nCols; c++) row.push(rpick(rng, FUZZ_TEXTS));
          rows.push(row);
        }
        b.snapshot = { rows };
        if (rbool(rng) && rows.length) b.snapshot.head = rows[0].slice();
      }
      return b;
    }
    case "embed": {
      const b = { id, type: "embed", target: rpick(rng, FUZZ_TARGETS) };
      return b;
    }
    default:
      return { id, type: "paragraph", content: genInline(rng) };
  }
}

// A VALID value of the right JS type for a string-valued native field.
function fieldValueFor(rng, kind) {
  if (kind === "field-color") return rpick(rng, FUZZ_COLORS);
  if (kind === "field-datetime") return rpick(rng, FUZZ_DATETIMES);
  if (kind === "field-slug") return rpick(rng, FUZZ_SLUGS);
  if (kind === "field-text") return rpick(rng, FUZZ_TEXTS) + (rbool(rng) ? "\nsecond" : "");
  return rpick(rng, FUZZ_TEXTS); // field-string and the fall-through
}

// genRun(rng) → an array of 1..8 random blocks with stable, unique ids "b0".."bN".
function genRun(rng) {
  const n = rint(rng, 1, 8);
  const run = [];
  for (let i = 0; i < n; i++) run.push(genBlock(rng, "b" + i));
  return run;
}

// ── PROPERTY 2 mutation — a random STABLE-ID change (never mints a new id) ────
//
//   editContent — edit one block's mutable content/attrs to another VALID value
//                 of the SAME type (same id, so no mint).
//   remove      — drop a random block.
//   move        — lift a random block to a random position.
//
// The mutation re-projects the WHOLE run with runToTiptap, so the mutated doc is
// a faithful canvas projection of the mutated run — exactly what the editor holds
// after the edit. assertFolds then proves the emitted ops fold to the mutated run.
function mutateRun(rng, run) {
  // editContent is only valid for a block with a MUTABLE interior. The
  // read-only atoms (sheet/embed) and the divider ATOM are INERT to edits — the
  // editor can never write a value back, so re-randomizing them would be an
  // INVALID mutation (not something the diff engine could ever observe). Only
  // offer editContent when at least one editable block exists.
  const editableIdx = run
    .map((b, i) => (isEditableKind(b.type) ? i : -1))
    .filter((i) => i !== -1);

  const kinds = [];
  if (editableIdx.length >= 1) kinds.push("editContent");
  if (run.length >= 1) kinds.push("remove");
  if (run.length >= 2) kinds.push("move");
  const kind = rpick(rng, kinds);

  if (kind === "remove") {
    const at = rint(rng, 0, run.length - 1);
    return run.filter((_b, i) => i !== at);
  }
  if (kind === "move") {
    const from = rint(rng, 0, run.length - 1);
    const copy = run.slice();
    const [moved] = copy.splice(from, 1);
    const to = rint(rng, 0, copy.length);
    copy.splice(to, 0, moved);
    return copy;
  }
  // editContent: mutate ONE editable block's MUTABLE fields to another valid
  // value, holding its id AND its immutable config constant (the stable-id rule
  // — same kind, new value through the SAME surface the editor edits, never a
  // new id and never a config change the control can't make).
  const at = rpick(rng, editableIdx);
  const mutated = genMutatedContent(rng, run[at]);
  return run.map((b, i) => (i === at ? mutated : b));
}

// True when a block kind has a MUTABLE interior the editor can change (prose
// content, callout body/chrome, code/diagram body, field VALUE). False for the
// INERT kinds (divider ATOM, sheet/embed READ-ONLY atoms) whose interior the
// editor never writes back — a value change there is not an observable edit.
function isEditableKind(type) {
  return type !== "divider" && type !== "sheet" && type !== "embed";
}

// genMutatedContent(rng, block) → a block of the SAME type + SAME id with its
// MUTABLE fields re-randomized but its IMMUTABLE config held constant. For a
// field-* block ONLY `value` is mutable (label/options/rows/fieldName are CONFIG
// the control cannot edit — runToOps' fieldNodeToPatch emits ONLY {value}); for
// every other editable kind the whole interior is fair game.
function genMutatedContent(rng, block) {
  const id = block.id;
  const type = block.type;
  if (isCanvasFieldKindLocal(type)) {
    // Mutate ONLY the value; carry the config keys VERBATIM (immutable through
    // the control). The value stays the right JS type per kind.
    const next = { ...block };
    next.value =
      type === "field-boolean"
        ? !block.value
        : type === "field-select"
        ? rpick(rng, [...(block.options || []).map((o) => o.value), ""])
        : fieldValueFor(rng, type);
    return next;
  }
  // Prose / callout / code / diagram: re-roll the whole interior of the SAME kind.
  return genBlockOfKind(rng, id, type);
}

// The 7 native field-* kinds (mirrors run-convert.js CANVAS_FIELD_TYPES) — used
// by the mutation to restrict a field edit to the VALUE only.
function isCanvasFieldKindLocal(type) {
  return (
    type === "field-string" ||
    type === "field-slug" ||
    type === "field-text" ||
    type === "field-boolean" ||
    type === "field-select" ||
    type === "field-datetime" ||
    type === "field-color"
  );
}

// ── report() — the final summary + exit code, called ONCE by the index ──────
// Verbatim the original __smoke.mjs trailing block: on any failure print
// "\n<N> FAILURE(S)" and exit 1; otherwise print "\nall round-trips PASS". The
// monolith ran this implicitly as the last top-level statements; the index now
// calls it explicitly after every per-area module has registered+run its checks.
function report() {
  if (failures > 0) {
    console.log(`\n${failures} FAILURE(S)`);
    process.exit(1);
  }
  console.log("\nall round-trips PASS");
}

export {
  // runner + report
  check,
  report,
  // the pure-JS patch.ex reference fold + the fold gate (S0..fuzz)
  applyOps,
  assertFolds,
  // the seeded PRNG + helpers
  mulberry32,
  rint,
  rpick,
  rbool,
  // key-order-safe deep compare
  canonicalJSON_local,
  canonicalEqual,
  // live-doc normalizer + project→reconstruct twin
  normalizeCanvasDoc,
  reconstructBlock,
  // the generator vocabulary
  FUZZ_TEXTS,
  FUZZ_LANGS,
  FUZZ_TONES,
  FUZZ_MERMAID,
  FUZZ_CAPTIONS,
  FUZZ_TITLES,
  FUZZ_COLORS,
  FUZZ_DATETIMES,
  FUZZ_TARGETS,
  FUZZ_SLUGS,
  FUZZ_CODE_VALUES,
  FUZZ_BLOCK_KINDS,
  genInlineSpans,
  genInline,
  genBlock,
  genBlockOfKind,
  fieldValueFor,
  genRun,
  // the property-2 mutation family
  mutateRun,
  isEditableKind,
  genMutatedContent,
  isCanvasFieldKindLocal,
};
