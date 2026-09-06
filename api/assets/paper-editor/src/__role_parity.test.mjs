// __role_parity.test.mjs — W1.2 role edit-DOM binding gate.
//
// The four article-chrome ROLE canvas nodes (eyebrow / byline / ingress /
// pullquote) in canvas/role-nodes.js must emit the SAME styled element the
// /papers article reader emits, so the byte-locked `.bp-role-*` CSS (frozen in
// test/barkpark_web/live/studio/view_edit_parity_test.exs §7) actually applies
// on the edit surface. The existing __role.test.mjs proves only the block ⇄ ops
// ROUND-TRIP (it imports run-convert.js, never role-nodes.js) — nothing asserts
// role-nodes.js still emits `<p class="bp-role-<name>">`, so a refactor could
// drop the class and stay green while Edit silently drifts from View. This gate
// closes that hole.
//
// Reader target — Barkpark.PortableDoc.Render.Walk.apply_text_role/4 (:article)
// (walk.ex:379-387) picks the class per role, and paragraph/3 (walk.ex:298-329)
// emits the element:
//   eyebrow   → <p class="bp-role-eyebrow">…</p>
//   byline    → <p class="bp-role-byline">…</p>
//   ingress   → <p class="bp-role-ingress">…</p>
//   pullquote → <p class="bp-role-pullquote" style="font-style:italic">…</p>
//              (compose.ex stamps italic:true → walk.ex paragraph/3:309 renders
//               `font-style:italic` INLINE, an author mark, NOT in the class)
// The reader roles carry ZERO chrome (no icon / fold / frame) — the node-view is
// a plain Node.create returning a `["p", {class}, 0]` DOMOutputSpec, so this test
// asserts the renderHTML spec directly (the __divider_parity.test.mjs technique;
// no jsdom — the node-view never mounts headless anyway).
//
// Run: node src/__role_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Eyebrow, Byline, Ingress, Pullquote } from "./canvas/role-nodes.js";

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

check("opening canvas preserves paragraph rhythm in both editor stylesheets", () => {
  for (const path of ["./styles.css", "../../../priv/static/assets/bp-paper-editor-shell.css"]) {
    const css = readFileSync(new URL(path, import.meta.url), "utf8");
    const openingRule = css.match(/\.bp-paper-editor > \.bp-paper-edit-canvas:nth-child\(1 of[^}]+\}/)?.[0];
    assert.ok(openingRule, `${path}: opening canvas rule must be present`);
    assert.match(openingRule, /> :first-child:not\(p\)\s*\{\s*margin-top: 0;/,
      `${path}: the reader retains its opening paragraph margin; only non-paragraph nodes may be clamped`);
  }
});

// The reader ground truth, per role: element + bp-role-* class + any inline
// author-mark style the reader (walk.ex paragraph/3) emits on the element.
const ROLES = [
  { node: Eyebrow, name: "eyebrow", cls: "bp-role-eyebrow", inlineStyle: null },
  { node: Byline, name: "byline", cls: "bp-role-byline", inlineStyle: null },
  { node: Ingress, name: "ingress", cls: "bp-role-ingress", inlineStyle: null },
  {
    node: Pullquote,
    name: "pullquote",
    cls: "bp-role-pullquote",
    inlineStyle: "font-style:italic",
  },
];

for (const { node, name, cls, inlineStyle } of ROLES) {
  // Feed the bp-attrs stamp the live renderHTML would receive (the id/type attrs
  // BpAttrs derives) so we can prove it SURVIVES onto the emitted element.
  const spec = node.config.renderHTML({
    HTMLAttributes: { "data-bp-id": `${name}-1`, "data-bp-type": name },
  });
  const attrs = spec[1];

  check(`${name}: renderHTML emits the reader's <p> element (walk.ex paragraph/3)`, () => {
    assert.equal(
      spec[0],
      "p",
      `${name} node-view no longer emits a <p> — the reader (walk.ex apply_text_role) ` +
        `paints every role as a <p class="${cls}">; a different tag drops the ` +
        `.bp-paper-surface p rhythm + the .bp-role-* rule.`,
    );
  });

  check(`${name}: element carries the reader's ${cls} class (byte-locked in view_edit_parity_test §7)`, () => {
    assert.ok(
      String(attrs.class).split(/\s+/).includes(cls),
      `${name} node-view dropped the "${cls}" class — the byte-locked ` +
        `.bp-role-* CSS would stop resolving and Edit would drift from View.`,
    );
  });

  check(`${name}: the reader class is the ONLY class — no edit-only chrome leaks`, () => {
    // Reader roles carry ZERO chrome (unlike the callout's tone frame). The class
    // list must be exactly the one bp-role-* token so no icon/fold/frame class
    // sneaks onto the edit element.
    assert.deepEqual(
      String(attrs.class).split(/\s+/).filter(Boolean),
      [cls],
      `${name} node-view emits extra classes beyond "${cls}" — a role element is ` +
        `chrome-free in the reader; an edit-only class would be a View⇄Edit divergence.`,
    );
  });

  check(`${name}: bp-attrs id/type stamp survives onto the emitted element`, () => {
    assert.equal(
      attrs["data-bp-type"],
      name,
      `${name} node-view dropped data-bp-type — run-convert.js keys the diff by the ` +
        `bp-attrs stamp; losing it orphans the block on save.`,
    );
    assert.equal(
      attrs["data-bp-id"],
      `${name}-1`,
      `${name} node-view dropped the incoming data-bp-id — the id must ride through ` +
        `to getJSON so the round-trip identifies the block.`,
    );
  });

  check(`${name}: renderHTML exposes a "0" content hole (editable prose, matches reader inline body)`, () => {
    // The reader body is inline runs; the edit node must expose PM's content hole
    // (the trailing 0) so the block is edited in place, not an atom island.
    assert.equal(
      spec[spec.length - 1],
      0,
      `${name} node-view lost its "0" content hole — the role body would stop being ` +
        `editable prose and could not round-trip its inline runs.`,
    );
  });

  check(`${name}: inline author-mark style matches the reader (${inlineStyle ?? "none"})`, () => {
    if (inlineStyle) {
      assert.ok(
        String(attrs.style || "").includes(inlineStyle),
        `${name} node-view no longer emits inline "${inlineStyle}" — the reader ` +
          `(walk.ex paragraph/3) renders it as an INLINE author mark, not in the class; ` +
          `dropping it diverges Edit from View byte-for-byte.`,
      );
    } else {
      // eyebrow/byline/ingress carry NO inline role style — all typography rides
      // the class. An inline style here would mean the class stopped owning it.
      assert.ok(
        attrs.style == null || attrs.style === "",
        `${name} node-view emits an inline style="${attrs.style}" — this role's ` +
          `typography must ride the "${cls}" class only (the reader emits no inline ` +
          `style for it), or the single-source class token silently drifts.`,
      );
    }
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
