import { test } from "node:test";
import assert from "node:assert/strict";

import {
  resetBlockIds,
  heading,
  paragraph,
  ingress,
  pullquote,
  eyebrow,
  byline,
  list,
  callout,
  action,
  code,
  diagram,
  asciicast,
  image,
  table,
  divider,
  section,
} from "../src/blocks.js";

test("heading mirrors {level,text} + unique id", () => {
  resetBlockIds();
  const h = heading(2, "Title");
  assert.deepEqual(h, { id: "b1", type: "heading", level: 2, text: "Title" });
});

test("paragraph reads 'content' as an inline-node array (string coerced)", () => {
  resetBlockIds();
  const p = paragraph("hi");
  assert.equal(p.type, "paragraph");
  assert.deepEqual(p.content, ["hi"]);
  assert.equal(p.id, "b1");
});

test("ingress + pullquote use 'content'", () => {
  resetBlockIds();
  assert.equal(ingress("lead").type, "ingress");
  assert.deepEqual(ingress("lead").content, ["lead"]);
  assert.equal(pullquote("quote").type, "pullquote");
});

test("eyebrow uses 'text'; byline uses 'items'", () => {
  resetBlockIds();
  assert.deepEqual(eyebrow("KICKER"), { id: "b1", type: "eyebrow", text: "KICKER" });
  assert.deepEqual(byline(["Knut", "2026"]), { id: "b2", type: "byline", items: ["Knut", "2026"] });
});

test("list uses {ordered, items: Inline[][]}", () => {
  resetBlockIds();
  const l = list(["one", "two"], { ordered: true });
  assert.equal(l.ordered, true);
  assert.deepEqual(l.items, [["one"], ["two"]]);
  // default ordered=false
  assert.equal(list(["x"]).ordered, false);
});

test("callout uses {tone, content, title?}", () => {
  resetBlockIds();
  const c = callout("info", "body", { title: "Note" });
  assert.equal(c.tone, "info");
  assert.deepEqual(c.content, ["body"]);
  assert.equal(c.title, "Note");
  // title omitted -> key absent
  assert.equal("title" in callout("warning", "x"), false);
});

test("action uses {href, label, priority?}", () => {
  resetBlockIds();
  const a = action("https://x.test", "Go", { priority: "primary" });
  assert.equal(a.href, "https://x.test");
  assert.equal(a.label, "Go");
  assert.equal(a.priority, "primary");
});

test("code uses 'value' (NOT lang/code)", () => {
  resetBlockIds();
  const c = code("$ ls -la");
  assert.deepEqual(c, { id: "b1", type: "code", value: "$ ls -la" });
  assert.equal("lang" in c, false);
});

test("diagram uses 'source' (NOT 'mermaid') + optional caption", () => {
  resetBlockIds();
  const d = diagram("graph TD; A-->B", "Figure 1.");
  assert.equal(d.source, "graph TD; A-->B");
  assert.equal(d.caption, "Figure 1.");
  assert.equal("mermaid" in d, false);
  assert.equal("caption" in diagram("x"), false);
});

test("asciicast uses {src, caption?}", () => {
  resetBlockIds();
  const a = asciicast("https://x.test/cast.json", "demo");
  assert.equal(a.src, "https://x.test/cast.json");
  assert.equal(a.caption, "demo");
});

test("image uses {src, alt, width?, height?}", () => {
  resetBlockIds();
  const i = image("https://x.test/p.png", "alt", { width: 100, height: 50 });
  assert.equal(i.src, "https://x.test/p.png");
  assert.equal(i.alt, "alt");
  assert.equal(i.width, 100);
  assert.equal(i.height, 50);
});

test("table uses {rows, head?} with cells as inline arrays", () => {
  resetBlockIds();
  const t = table([["a", "b"]], { head: ["H1", "H2"] });
  assert.deepEqual(t.rows, [[["a"], ["b"]]]);
  assert.deepEqual(t.head, [["H1"], ["H2"]]);
});

test("divider + section shapes", () => {
  resetBlockIds();
  assert.deepEqual(divider(), { id: "b1", type: "divider" });
  const s = section("Intro", [heading(2, "x")]);
  assert.equal(s.type, "section");
  assert.equal(s.title, "Intro");
  assert.equal(s.blocks.length, 1);
});

test("ids are deterministic + monotonic across mixed constructors", () => {
  resetBlockIds();
  const blocks = [heading(1, "a"), paragraph("b"), code("c"), divider()];
  assert.deepEqual(
    blocks.map((b) => b.id),
    ["b1", "b2", "b3", "b4"],
  );
});

test("explicit id overrides the counter", () => {
  resetBlockIds();
  const h = heading(1, "x", "intro");
  assert.equal(h.id, "intro");
  // counter not consumed by an explicit id -> next auto id is b1
  assert.equal(paragraph("y").id, "b1");
});

test("every block carries a non-empty unique id by default", () => {
  resetBlockIds();
  const blocks = [
    heading(1, "a"),
    paragraph("b"),
    ingress("c"),
    pullquote("d"),
    eyebrow("e"),
    byline(["f"]),
    list(["g"]),
    callout("info", "h"),
    action("https://x.test", "i"),
    code("j"),
    diagram("k"),
    asciicast("https://x.test/l.json"),
    image("https://x.test/m.png", "m"),
    table([["n"]]),
    divider(),
  ];
  const ids = blocks.map((b) => b.id);
  assert.equal(ids.length, new Set(ids).size, "ids must be unique");
  assert.ok(ids.every((id) => typeof id === "string" && id.length > 0));
});
