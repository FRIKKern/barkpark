// smoke/markdown.mjs — the Phase-5 source-mode foundation: the PURE bidirectional
// blocks ⇄ MARKDOWN converter (markdown.js) hand cases (one per block type + per inline
// mark + adversarial text), plus the 2000-iter markdown FUZZ FIXED-POINT gate over the
// full block + inline vocabulary.
//
// VERBATIM extraction from src/__smoke.mjs: each markdown check moved unchanged (same
// name, body, assertions), carrying its section-local helpers (coalesceTextTree,
// mdRenderEqual, isSentinelSerialized) and the fuzz consts (MD_FUZZ_BASE_SEED,
// MD_FUZZ_ITERS) with it. The fuzz reuses the SAME genRun generator the projection fuzz
// uses, imported from the shared harness. Iteration count UNCHANGED: 2000. The shared
// check() runs through the harness so the aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, mulberry32, canonicalEqual, genRun } from "./harness.mjs";
import { inlineArrayToTiptap, tiptapInlineToPd } from "../convert.js";
import { normalizeTone } from "../tone.js";
import { blocksToMarkdown, markdownToBlocks } from "../markdown.js";

// ═══════════════════════════════════════════════════════════════════════════
// Phase-5 source-mode foundation — blocks ⇄ MARKDOWN converter (markdown.js)
//
// blocksToMarkdown / markdownToBlocks are a PURE, dependency-free projection of
// the PortableDoc BLOCK-AST to/from Markdown text. The gate has two tiers:
//
//   FIXED POINT (all blocks): blocks → md1 → blocks2 → md2  ⇒  md1 === md2, AND
//     blocks2 → md3 === md2 (the block list stabilized after ONE normalization
//     pass). Markdown is a fixed point after the first round-trip.
//   SENTINEL LOSSLESSNESS (non-prose / lossy blocks): the <!--bp:block …--> JSON
//     sentinel carries the WHOLE block verbatim → blocks2 holds the EXACT block.
//   PROSE RENDER-EQUIVALENCE (paragraph/heading/list/callout/code/diagram/divider
//     with representable inline): blocks2 is render-equal to the original on the
//     NORMALIZED inline tree — bold stays bold, links/wikilinks/tags/code survive,
//     nothing dropped/garbled. Markdown can't distinguish two abutting text leaves
//     from one, so the canonical compare COALESCES adjacent text (the documented
//     prose normalization), exactly as the canvas property tests normalize through
//     project→reconstruct.
// ═══════════════════════════════════════════════════════════════════════════

// Coalesce adjacent text leaves recursively — the markdown render-normalization.
// Two abutting { type:"text" } leaves render identically to one (markdown has no
// way to keep a boundary between them), and an empty text leaf renders as nothing.
// This is the prose half of the fidelity bar: NOT byte-equality (that is only for
// sentinel blocks), but render-equivalence on the normalized inline tree.
function coalesceTextTree(value) {
  if (Array.isArray(value)) {
    const mapped = value.map(coalesceTextTree);
    const out = [];
    for (const n of mapped) {
      if (n && n.type === "text") {
        if (n.value === "") continue;
        const last = out[out.length - 1];
        if (last && last.type === "text") {
          last.value += n.value;
          continue;
        }
        out.push({ type: "text", value: n.value });
      } else {
        out.push(n);
      }
    }
    return out;
  }
  if (value && typeof value === "object") {
    const o = {};
    for (const k of Object.keys(value)) o[k] = coalesceTextTree(value[k]);
    return o;
  }
  return value;
}

// canonical compare AFTER the text-coalesce normalization + id strip.
function mdRenderEqual(a, b) {
  const { id: _ai, ...ar } = a;
  const { id: _bi, ...br } = b;
  return canonicalEqual(coalesceTextTree(ar), coalesceTextTree(br));
}

// True when a block is carried by the SENTINEL (non-prose kind OR a prose block
// whose serialized form is a sentinel). We detect it structurally: re-serialize
// the single block and check it is exactly one <!--bp:block …--> line.
function isSentinelSerialized(block) {
  const md = blocksToMarkdown([block]);
  return md.startsWith("<!--bp:block ") && md.endsWith("-->") && !md.includes("\n");
}

// ── hand cases: one per block type + per inline mark, plus adversarial text ───
check("markdown: paragraph with bold/italic/strike/code round-trips render-equal", () => {
  const block = {
    id: "p-1",
    type: "paragraph",
    content: tiptapInlineToPd(
      inlineArrayToTiptap([
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "bold" }] },
        { type: "text", value: " " },
        { type: "em", children: [{ type: "text", value: "ital" }] },
        { type: "text", value: " " },
        { type: "strikethrough", children: [{ type: "text", value: "struck" }] },
        { type: "text", value: " " },
        { type: "code", value: "x=1" },
      ]),
    ),
  };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "Hello **bold** *ital* ~~struck~~ `x=1`", "readable markdown");
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.ok(mdRenderEqual(back[0], block), "round-trips render-equal");
});

check("markdown: heading round-trips ('#'*level + text)", () => {
  const block = { id: "h-1", type: "heading", level: 3, text: "Section Title" };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "### Section Title");
  const back = markdownToBlocks(md);
  assert.deepEqual(back[0], { ...back[0], type: "heading", level: 3, text: "Section Title" });
  assert.equal(back[0].level, 3);
  assert.equal(back[0].text, "Section Title");
});

check("markdown: bullet + ordered lists round-trip", () => {
  const bullet = {
    id: "l-1",
    type: "list",
    ordered: false,
    items: [
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "alpha" }])),
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "strong", children: [{ type: "text", value: "beta" }] }])),
    ],
  };
  assert.equal(blocksToMarkdown([bullet]), "- alpha\n- **beta**");
  assert.ok(mdRenderEqual(markdownToBlocks(blocksToMarkdown([bullet]))[0], bullet));

  const ordered = {
    id: "l-2",
    type: "list",
    ordered: true,
    items: [
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "one" }])),
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "two" }])),
    ],
  };
  assert.equal(blocksToMarkdown([ordered]), "1. one\n2. two");
  assert.ok(mdRenderEqual(markdownToBlocks(blocksToMarkdown([ordered]))[0], ordered));
});

check("markdown: callout admonition (tone + title + collapsed) round-trips", () => {
  const block = {
    id: "c-1",
    type: "callout",
    tone: "warning",
    title: "Heads up",
    collapsible: true,
    collapsed: true,
    content: tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "body text" }])),
  };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "> [!warning]- Heads up\n> body text", "Obsidian admonition with - suffix");
  const back = markdownToBlocks(md)[0];
  assert.equal(back.tone, "warning");
  assert.equal(back.title, "Heads up");
  assert.equal(back.collapsible, true);
  assert.equal(back.collapsed, true);
  assert.ok(mdRenderEqual(back, block));
});

check("markdown: callout with a NON-CANONICAL tone ('note'/'tip') round-trips verbatim", () => {
  // The serializer emits the EXACT tone token and the parser reads it back literally
  // (NOT through normalizeTone), so a stored tone the canonical set doesn't contain
  // still round-trips byte-for-byte.
  for (const tone of ["note", "tip", "success", "neutral"]) {
    const block = { id: "c", type: "callout", tone, content: [{ type: "text", value: "x" }] };
    const back = markdownToBlocks(blocksToMarkdown([block]))[0];
    assert.equal(back.tone, tone, `tone ${tone} survives verbatim`);
  }
});

check("markdown: code fence (lang) + a value CONTAINING ``` bumps the fence length", () => {
  const block = { id: "cd-1", type: "code", value: "see ```js\ncode\n``` inside", lang: "md" };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("````md\n"), "fence bumped to 4 backticks");
  assert.ok(md.endsWith("\n````"));
  const back = markdownToBlocks(md)[0];
  assert.equal(back.type, "code");
  assert.equal(back.value, block.value, "value with inner ``` survives");
  assert.equal(back.lang, "md");
});

check("markdown: diagram fence (mermaid) round-trips source + caption losslessly", () => {
  const block = { id: "d-1", type: "diagram", source: "graph TD\n  A-->B", caption: "café & co. <x>" };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("```mermaid caption="), "mermaid fence carries the caption");
  const back = markdownToBlocks(md)[0];
  assert.equal(back.type, "diagram");
  assert.equal(back.source, "graph TD\n  A-->B");
  assert.equal(back.caption, "café & co. <x>", "caption round-trips lossless (no sentinel)");
});

check("markdown: a code block with lang='mermaid' sentinels (never becomes a diagram)", () => {
  // The fence info "mermaid" is the DIAGRAM marker — a code block carrying lang
  // "mermaid" must NOT silently round-trip into a diagram block. It sentinels.
  const block = { id: "cm-1", type: "code", value: "graph TD\n A-->B", lang: "mermaid" };
  assert.ok(isSentinelSerialized(block), "code lang=mermaid → sentinel");
  const back = markdownToBlocks(blocksToMarkdown([block]))[0];
  assert.equal(back.type, "code", "stays a code block, not a diagram");
  assert.deepEqual(back, block, "byte-lossless via the sentinel");
});

check("markdown: divider round-trips to ---", () => {
  const block = { id: "dv-1", type: "divider" };
  assert.equal(blocksToMarkdown([block]), "---");
  assert.equal(markdownToBlocks("---")[0].type, "divider");
});

// ── REGRESSION (Bug #1): nested SAME-FAMILY emphasis ("***x***" ambiguity) ─────
// A stored run with bold+italic is a real projection fixed point: strong>em (and
// the em>strong mirror, which MARK_ORDER folds to the same shape). The OLD
// serializer emitted "***x***", which the tokenizer mis-parsed as strong + a stray
// "*", garbling the run and oscillating the fixed point. The serializer now emits
// UNAMBIGUOUS nested delimiters (strong>em → "**_x_**"), so the tokenizer only ever
// sees single/double runs. Must round-trip strong>em, em>strong, plain strong,
// plain em, AND strong>strike (distinct delims, already worked) to a STABLE fixed
// point, render-equal.
check("markdown: nested same-family emphasis (***x*** bug) round-trips to a stable fixed point", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  const t = [{ type: "text", value: "x" }];
  const cases = [
    ["plain strong", [{ type: "strong", children: t }], "**x**"],
    ["plain em", [{ type: "em", children: t }], "*x*"],
    ["strong>em (bold+italic)", [{ type: "strong", children: [{ type: "em", children: t }] }], "**_x_**"],
    ["em>strong (mirror → strong>em)", [{ type: "em", children: [{ type: "strong", children: t }] }], "**_x_**"],
    ["em>em (same-mark nest)", [{ type: "em", children: [{ type: "em", children: t }] }], "*_x_*"],
    ["strong>strong (same-mark nest)", [{ type: "strong", children: [{ type: "strong", children: t }] }], "**__x__**"],
    ["strong>strike (distinct delims)", [{ type: "strong", children: [{ type: "strikethrough", children: t }] }], "**~~x~~**"],
  ];
  for (const [label, inline, expectedMd] of cases) {
    const block = { id: "p", type: "paragraph", content: norm(inline) };
    const md1 = blocksToMarkdown([block]);
    assert.equal(md1, expectedMd, `${label}: serializes unambiguously`);
    const back = markdownToBlocks(md1);
    assert.equal(back.length, 1, `${label}: stays one paragraph`);
    const md2 = blocksToMarkdown(back);
    assert.equal(md1, md2, `${label}: STABLE fixed point (md1 === md2)`);
    assert.ok(mdRenderEqual(back[0], block), `${label}: round-trips render-equal (no garble)`);
  }
});

// ── REGRESSION (Bug #2): paragraph led by a ≥3-backtick inline-code span ────────
// A paragraph whose first inline node is inline-code with a value forcing a 3+-
// backtick fence (e.g. value "```", serialized "``` ``` ```") used to begin with a
// bare "```" run → the block scanner re-read it as a fenced CODE BLOCK, dropping the
// paragraph. escapeBlockLeader now backslash-escapes the leading fence; the inline
// tokenizer inverts it, preserving the code value exactly.
check("markdown: paragraph led by a 3+-backtick inline-code span (fence-block bug) round-trips", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  for (const value of ["```", "``` ", "a``b", "ab```cd", "``"]) {
    const block = { id: "p", type: "paragraph", content: norm([{ type: "code", value }]) };
    const md = blocksToMarkdown([block]);
    const back = markdownToBlocks(md);
    assert.equal(back.length, 1, `value ${JSON.stringify(value)}: stays ONE block`);
    assert.equal(back[0].type, "paragraph", `value ${JSON.stringify(value)}: stays a PARAGRAPH (not a code block)`);
    assert.equal(back[0].content[0].type, "code", `value ${JSON.stringify(value)}: first node is inline-code`);
    assert.equal(back[0].content[0].value, value, `value ${JSON.stringify(value)}: inline-code value preserved exactly`);
    const md2 = blocksToMarkdown(back);
    assert.equal(md, md2, `value ${JSON.stringify(value)}: STABLE fixed point`);
  }
});

// ── REGRESSION (Bug #2 minimal): a paragraph that is JUST the 3-backtick span ───
check("markdown: a paragraph that is JUST a 3-backtick inline-code span round-trips", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  const block = { id: "p", type: "paragraph", content: norm([{ type: "code", value: "```" }]) };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("\\"), "the leading fence is backslash-escaped so it is not a code block");
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "paragraph");
  assert.ok(mdRenderEqual(back[0], block), "round-trips render-equal");
});

check("markdown: link / wikilink (alias) / tag inline round-trip", () => {
  const block = {
    id: "p-2",
    type: "paragraph",
    content: tiptapInlineToPd(
      inlineArrayToTiptap([
        { type: "link", href: "https://x.test", children: [{ type: "text", value: "site" }] },
        { type: "text", value: " " },
        { type: "wikilink", target: "Some Note", alias: "alias", children: [{ type: "text", value: "alias" }] },
        { type: "text", value: " " },
        { type: "wikilink", target: "setup", children: [{ type: "text", value: "setup" }] },
        { type: "text", value: " " },
        { type: "tag", name: "todo" },
      ]),
    ),
  };
  const md = blocksToMarkdown([block]);
  assert.ok(md.includes("[site](https://x.test)"), "link");
  assert.ok(md.includes("[[Some Note|alias]]"), "wikilink with alias");
  assert.ok(md.includes("[[setup]]"), "plain wikilink");
  assert.ok(md.includes("#todo"), "tag");
  assert.ok(mdRenderEqual(markdownToBlocks(md)[0], block));
});

check("markdown: adversarial literal markdown chars round-trip as TEXT, not markup", () => {
  // A paragraph whose text LOOKS like a heading / list / quote / rule / emphasis,
  // plus literal * _ ` [ ] # at line start. Escaping must make them literal text.
  const cases = [
    "# not a heading",
    "- not a list",
    "1. not ordered",
    "> not a quote",
    "--- not a rule",
    "a * b _ c ` d [ e ] f # g",
    "C# and F# are languages",
  ];
  for (const value of cases) {
    const block = {
      id: "adv",
      type: "paragraph",
      content: tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value }])),
    };
    const md = blocksToMarkdown([block]);
    const back = markdownToBlocks(md);
    assert.equal(back.length, 1, `"${value}" stays ONE block`);
    assert.equal(back[0].type, "paragraph", `"${value}" stays a paragraph`);
    assert.ok(mdRenderEqual(back[0], block), `"${value}" round-trips as text`);
  }
});

check("markdown: empty paragraph + empty block edge cases round-trip", () => {
  const empty = { id: "e-1", type: "paragraph", content: [] };
  const md = blocksToMarkdown([empty]);
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "paragraph");
  assert.deepEqual(back[0].content, []);
});

check("markdown: NON-PROSE blocks (field-*/sheet/embed) ride a byte-lossless sentinel", () => {
  const field = { id: "f-1", type: "field-string", label: "Title", value: "hi", fieldName: "title" };
  const select = {
    id: "f-2",
    type: "field-select",
    value: "draft",
    options: [{ value: "draft", label: "Draft" }],
    label: "Status",
  };
  const sheet = { id: "s-1", type: "sheet", ref: "a/b", snapshot: { rows: [["x", "y"]], head: ["x", "y"] } };
  const embed = { id: "e-2", type: "embed", target: "Linked Note" };
  for (const block of [field, select, sheet, embed]) {
    assert.ok(isSentinelSerialized(block), `${block.type} → sentinel`);
    const back = markdownToBlocks(blocksToMarkdown([block]));
    assert.equal(back.length, 1);
    assert.deepEqual(back[0], block, `${block.type} sentinel is BYTE-lossless (incl. id)`);
  }
});

check("markdown: LOSSY prose (underline / wikilink+docId / blockref) falls back to the sentinel", () => {
  const underline = {
    id: "u-1",
    type: "paragraph",
    content: [{ type: "underline", children: [{ type: "text", value: "u" }] }],
  };
  const wikiDoc = {
    id: "w-1",
    type: "paragraph",
    content: [{ type: "wikilink", target: "t", docId: "doc-7", children: [{ type: "text", value: "t" }] }],
  };
  for (const block of [underline, wikiDoc]) {
    assert.ok(isSentinelSerialized(block), `${block.id} → sentinel (lossy inline)`);
    const back = markdownToBlocks(blocksToMarkdown([block]));
    assert.deepEqual(back[0], block, `${block.id} sentinel is byte-lossless`);
  }
});

check("markdown: a multi-block doc round-trips block-for-block + is a FIXED POINT", () => {
  const blocks = [
    { id: "h", type: "heading", level: 1, text: "Title" },
    { id: "p", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "dv", type: "divider" },
    { id: "c", type: "code", value: "x=1", lang: "js" },
    { id: "f", type: "field-boolean", value: true, label: "On" },
  ];
  const md1 = blocksToMarkdown(blocks);
  const blocks2 = markdownToBlocks(md1);
  const md2 = blocksToMarkdown(blocks2);
  assert.equal(md1, md2, "markdown is a fixed point after one pass");
  assert.equal(blocksToMarkdown(blocks2), md2, "blocks stabilized (md3 === md2)");
  assert.equal(blocks2.length, blocks.length);
});

// ── the FUZZ FIXED-POINT gate over genRun (reuse the existing generator) ──────
//
// 2000 random runs over the FULL block + inline vocabulary. Each asserts:
//   • FIXED POINT       — md1 === md2 (markdown stable after one normalization),
//                         and blocks2 → md3 === md2 (blocks stabilized).
//   • COUNT             — blocks2 has the same block count (no block dropped/split).
//   • SENTINEL LOSSLESS — every sentinel-serialized block reconstructs BYTE-exact.
//   • PROSE RENDER-EQ   — every prose block reconstructs render-equal on the
//                         coalesce-normalized inline tree.
// A failure prints the SEED + the run + the diverging markdown for repro
// (deterministic mulberry32 stream → same seed reproduces the run exactly).
const MD_FUZZ_BASE_SEED = 0x5eed1;
const MD_FUZZ_ITERS = 2000;

check(`markdown FUZZ FIXED-POINT: ${MD_FUZZ_ITERS} random runs are a stable fixed point + lossless`, () => {
  for (let i = 0; i < MD_FUZZ_ITERS; i++) {
    // Offset the seed space from the canvas fuzz so these exercise their own runs.
    const seed = (MD_FUZZ_BASE_SEED + 2000000 + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);

    let md1, blocks2, md2, md3;
    try {
      md1 = blocksToMarkdown(run);
      blocks2 = markdownToBlocks(md1);
      md2 = blocksToMarkdown(blocks2);
      md3 = blocksToMarkdown(markdownToBlocks(md2));
    } catch (e) {
      throw new Error(
        `markdown round-trip THREW at seed=${seed}: ${e.message}\n  run=${JSON.stringify(run)}`,
      );
    }

    // FIXED POINT — markdown stable after one normalization pass.
    if (md1 !== md2) {
      const lines1 = md1.split("\n");
      const lines2 = md2.split("\n");
      let diff = "";
      for (let k = 0; k < Math.max(lines1.length, lines2.length); k++) {
        if (lines1[k] !== lines2[k]) {
          diff = `\n  first diverging line ${k}:\n    md1: ${JSON.stringify(lines1[k])}\n    md2: ${JSON.stringify(lines2[k])}`;
          break;
        }
      }
      throw new Error(
        `markdown FIXED-POINT FAILED at seed=${seed} (md1 !== md2)${diff}\n` +
          `  run: ${JSON.stringify(run)}\n  md1: ${JSON.stringify(md1)}\n  md2: ${JSON.stringify(md2)}`,
      );
    }
    // blocks stabilized.
    if (md3 !== md2) {
      throw new Error(
        `markdown BLOCKS-NOT-STABILIZED at seed=${seed} (md3 !== md2)\n` +
          `  run: ${JSON.stringify(run)}\n  md2: ${JSON.stringify(md2)}\n  md3: ${JSON.stringify(md3)}`,
      );
    }
    // COUNT — no block dropped or split.
    if (blocks2.length !== run.length) {
      throw new Error(
        `markdown COUNT MISMATCH at seed=${seed}: ${blocks2.length} !== ${run.length}\n` +
          `  run: ${JSON.stringify(run)}\n  md1: ${JSON.stringify(md1)}\n  out: ${JSON.stringify(blocks2)}`,
      );
    }
    // PER-BLOCK — sentinel byte-lossless OR prose render-equal.
    for (let j = 0; j < run.length; j++) {
      const orig = run[j];
      const back = blocks2[j];
      if (isSentinelSerialized(orig)) {
        // Byte-lossless: the EXACT original block (id and all) survives.
        if (!canonicalEqual(orig, back)) {
          throw new Error(
            `markdown SENTINEL NOT BYTE-LOSSLESS at seed=${seed} slot ${j} (${orig.type})\n` +
              `  in : ${JSON.stringify(orig)}\n  out: ${JSON.stringify(back)}\n  md1: ${JSON.stringify(md1)}`,
          );
        }
      } else if (!mdRenderEqual(back, orig)) {
        throw new Error(
          `markdown PROSE NOT RENDER-EQUAL at seed=${seed} slot ${j} (${orig.type})\n` +
            `  in : ${JSON.stringify(orig)}\n  out: ${JSON.stringify(back)}\n  md1: ${JSON.stringify(md1)}`,
        );
      }
    }
  }
});

check("markdown FUZZ determinism: same seed → identical run + identical markdown", () => {
  const seed = (MD_FUZZ_BASE_SEED + 2000000 + 7) >>> 0;
  const a = blocksToMarkdown(genRun(mulberry32(seed)));
  const b = blocksToMarkdown(genRun(mulberry32(seed)));
  assert.equal(a, b, "same seed must yield byte-identical markdown");
});
