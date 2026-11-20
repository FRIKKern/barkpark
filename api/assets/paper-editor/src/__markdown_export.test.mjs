// __markdown_export.test.mjs — task-a5ba0a62b64635ac: a paper left the Studio only
// as JSON. markdown/export.js writes the Markdown a writer downloads or copies:
// one way, text first, and no block dropped without a line.
//
// Pure: blocks in, a string out. Source mode keeps its own serializer, whose
// output must still parse back to the same blocks; the last case holds that.
//
// Run: node src/__markdown_export.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { blocksToExportMarkdown, blocksToMarkdown, markdownToBlocks } from "./markdown.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${String(error.message).split("\n").join("\n      ")}`);
  }
}

const t = (value) => ({ type: "text", value });
const md = (blocks, options) => blocksToExportMarkdown(blocks, options);

check("prose keeps its marks: bold, italic, strike, code and links, nested or flat", () => {
  const paragraph = {
    type: "paragraph",
    content: [
      t("A "),
      { type: "strong", children: [t("bold")] },
      t(", an "),
      { type: "em", children: [t("italic")] },
      t(", a "),
      { type: "strikethrough", children: [t("struck")] },
      t(" word, "),
      { type: "code", value: "bp task next" },
      t(" and "),
      { type: "link", href: "/papers/guide", children: [t("a link")] },
      t(". Flat: "),
      { type: "text", value: "marked", marks: [{ type: "bold" }, { type: "link", attrs: { href: "https://example.com/a b" } }] },
      t(". Plain: "),
      { type: "underline", children: [t("underlined")] },
      t(", "),
      { type: "wikilink", target: "Field notes", docId: "doc-1", children: [t("Field notes")] },
      t(", 2 * 3 #tag"),
    ],
  };
  assert.equal(
    md([{ type: "heading", level: 2, text: "A #1 heading" }, paragraph], { baseUrl: "https://studio.example/w/a/p/b/studio" }),
    "## A \\#1 heading\n\n" +
      "A **bold**, an *italic*, a ~~struck~~ word, `bp task next` and [a link](https://studio.example/papers/guide). " +
      "Flat: [**marked**](https://example.com/a%20b). Plain: underlined, Field notes, 2 \\* 3 \\#tag",
  );
});

check("a table is a GFM table with its alignment, and a table without a header gets an empty one", () => {
  const table = {
    type: "table",
    head: [[t("Surface")], { content: [t("Lines")], align: "right" }],
    rows: [
      [[t("Phoenix")], { content: [{ type: "strong", children: [t("1 200")] }], align: "right" }],
      [[t("a | b")], [t("two\nlines")]],
    ],
  };
  assert.equal(
    md([table]),
    "| Surface | Lines |\n| --- | ---: |\n| Phoenix | **1 200** |\n| a \\| b | two<br>lines |",
  );
  assert.equal(md([{ type: "table", rows: [["a", "b"]] }]), "|  |  |\n| --- | --- |\n| a | b |");
});

check("lists: bullets, numbers from their start, a checklist, and a nested list under its item", () => {
  assert.equal(
    md([
      { type: "list", ordered: false, items: [[t("One")], { content: [t("Two")], children: [{ type: "list", ordered: true, start: 3, items: ["Deep"] }] }] },
      { type: "list", task: true, items: [{ content: [t("Done")], checked: true }, { content: [t("Open")], checked: false }] },
    ]),
    "- One\n- Two\n  3. Deep\n\n- [x] Done\n- [ ] Open",
  );
});

check("code keeps its language, a fence inside it gets a longer fence, a diagram is a mermaid fence", () => {
  assert.equal(
    md([
      { type: "code", lang: "elixir", value: "def hello, do: :world" },
      { type: "code", value: "```\ninner\n```" },
      { type: "diagram", source: "graph TD; A --> B", caption: "The flow" },
    ]),
    "```elixir\ndef hello, do: :world\n```\n\n````\n```\ninner\n```\n````\n\n```mermaid\ngraph TD; A --> B\n```\n\n*The flow*",
  );
});

check("quotes, callouts and notes are quotes with a label; a divider and an image are Markdown's own", () => {
  assert.equal(
    md(
      [
        { type: "blockquote", content: [t("Invent it.")], cite: "Alan Kay" },
        { type: "callout", tone: "warn", title: "Heads up", content: [t("Mind the gap.")] },
        { type: "callout", tone: "info", content: [t("No title.")] },
        { type: "note", label: "Why", lead: "Trust", text: "You feel progress." },
        { type: "divider" },
        { type: "image", src: "/media/cover (1).png", alt: "Cover [art]", width: 640 },
      ],
      { baseUrl: "https://studio.example/x" },
    ),
    "> Invent it.\n>\n> — Alan Kay\n\n" +
      "> **Warning:** Heads up\n>\n> Mind the gap.\n\n" +
      "> **Note**\n>\n> No title.\n\n" +
      "> **Why:** *Trust* You feel progress.\n\n" +
      "---\n\n" +
      "![Cover art](https://studio.example/media/cover%20%281%29.png)",
  );
});

// A callout's words: markdown/callout-words.js.
check("a callout holding content and a different body exports both, content first, then every body block", () => {
  const p = (text) => ({ type: "paragraph", content: [t(text)] });
  assert.equal(
    md([{ type: "callout", tone: "note", content: [t("head words")], slots: { body: [p("body words"), { type: "list", items: [[t("body item")]] }] } }]),
    "> **Note**\n>\n> head words\n>\n> body words\n>\n> - body item",
  );
  // Two fields holding the same words are both exported: nothing is skipped as equal.
  assert.equal(
    md([{ type: "callout", tone: "note", content: [t("same words")], slots: { body: [p("same words")] } }]),
    "> **Note**\n>\n> same words\n>\n> same words",
  );
  assert.equal(md([{ type: "callout", tone: "note", slots: { body: [p("only the body")] } }]), "> **Note**\n>\n> only the body");
});

const underItem = (child) => ({ type: "list", items: [{ content: [t("item")], children: [child] }] });

check("a list item keeps every word of a heading under it, indented", () => {
  assert.equal(md([underItem({ type: "heading", level: 3, text: "child heading" })]), "- item\n  ### child heading");
});

check("a list item keeps every word of a code block under it, indented", () => {
  assert.equal(md([underItem({ type: "code", lang: "js", value: "child code" })]), "- item\n  ```js\n  child code\n  ```");
});

check("a list item keeps every word of a callout under it, its body too, indented", () => {
  assert.equal(
    md([underItem({ type: "callout", tone: "note", content: [t("child head")], slots: { body: [{ type: "paragraph", content: [t("child body")] }] } })]),
    "- item\n  > **Note**\n  >\n  > child head\n  >\n  > child body",
  );
});

check("steps, tabs and columns keep every block inside them, in order", () => {
  const p = (text) => ({ type: "paragraph", content: [t(text)] });
  assert.equal(
    md([
      { type: "steps", steps: [{ title: "Claim", blocks: [p("Run it."), { type: "code", value: "bp task next" }] }, { title: "Close" }] },
      { type: "tabs", tabs: [{ label: "macOS", blocks: [p("brew")] }, { label: "Linux", blocks: [p("curl")] }] },
      { type: "columns", columns: [[p("Left")], [p("Right")]] },
    ]),
    "1. **Claim**\n\n   Run it.\n\n   ```\n   bp task next\n   ```\n\n2. **Close**\n\n" +
      "**macOS**\n\nbrew\n\n**Linux**\n\ncurl\n\n" +
      "Left\n\nRight",
  );
});

check("a block Markdown cannot say leaves a line naming it, with its words; the host can word the line", () => {
  const chart = { type: "chart", kind: "line", caption: "Coverage over time", series: [{ label: "Covered", points: [1, 2] }] };
  assert.equal(md([chart]), "> [Chart: not included in Markdown export]\n> Coverage over time\n> Covered");
  assert.equal(md([{ type: "heatmap", cells: [[0.1]] }]), "> [Heatmap: not included in Markdown export]");
  assert.equal(md([{ type: "task-board", snapshot: [] }], { placeholder: "%{block}: ikke med i Markdown-eksporten" }), "> [Task board: ikke med i Markdown-eksporten]");
  assert.equal(md([{ type: "sheet", ref: "budget", snapshot: { head: ["Item", "Cost"], rows: [["Hosting", 42]] } }]), "| Item | Cost |\n| --- | --- |\n| Hosting | 42 |");
  assert.equal(md([{ type: "field-number", label: "Weight", value: 2.5, unit: "kg" }]), "**Weight:** 2.5 kg");
});

check("nothing rides an HTML comment, an empty paragraph is left out, and a line that looks like a marker stays text", () => {
  const out = md([
    { type: "paragraph", content: [] },
    { type: "paragraph", content: [t("- not a list")] },
    { type: "paragraph", content: [t("1. not a list either")] },
    { type: "heading", level: 2, text: "Aligned", align: "center" },
    { type: "embed", target: "Field notes" },
  ]);
  assert.equal(out, "\\- not a list\n\n1\\. not a list either\n\n## Aligned\n\n> [Embed: not included in Markdown export]\n> Field notes");
  assert.ok(!out.includes("<!--"));
});

check("source mode's serializer is unchanged: a table still rides its sentinel and parses back", () => {
  const blocks = [
    { id: "h", type: "heading", level: 2, text: "Title" },
    { id: "t", type: "table", head: [[t("A")]], rows: [[[t("1")]]] },
    { id: "p", type: "paragraph", content: [{ type: "strong", children: [t("bold")] }] },
  ];
  const source = blocksToMarkdown(blocks);
  assert.ok(source.includes("<!--bp:block "));
  const noIds = (list) => list.map(({ id: _id, ...rest }) => rest);
  assert.deepEqual(noIds(markdownToBlocks(source)), noIds(blocks));
});

if (failures) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log("\nmarkdown export: all passed");
