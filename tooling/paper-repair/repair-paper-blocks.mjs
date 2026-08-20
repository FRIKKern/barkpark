#!/usr/bin/env node
// repair-paper-blocks.mjs — make a paper whose `body` is a ProseMirror document
// readable again, by writing the top-level PortableDoc `blocks` array its reader
// needs. Dry-run by default; `--apply` writes.
//
//   node tooling/paper-repair/repair-paper-blocks.mjs <slug> [<slug>…] [--apply]
//
// For each slug: read it with `bp doc get`, refuse anything outside the repair's
// population, convert (tooling/paper-repair/prosemirror-to-blocks.mjs), prove
// text fidelity against the source, and — with --apply — patch + publish through
// `bp doc mutate`, then READ THE FIELD BACK from the published perspective and
// curl the web reader. A printed `rev` is not persistence; the read-back is.
//
// REFUSALS (both matter, neither is a nuisance):
//   • already has a top-level `blocks` list → nothing to repair.
//   • carries `body_html` → the html_only population. Those papers serve 200
//     today through the HTML fallback; writing `blocks` over them arms the
//     divergence 422 they currently dodge (stored HTML vs a fresh render with no
//     body_html_sv stamp ⇒ :divergent). Leave them alone.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  blocksText,
  isProseMirrorDoc,
  prosemirrorDocToBlocks,
  prosemirrorText,
} from "./prosemirror-to-blocks.mjs";

const args = process.argv.slice(2);
const apply = args.includes("--apply");
const slugs = args.filter((a) => !a.startsWith("--"));

if (slugs.length === 0) {
  console.error("usage: repair-paper-blocks.mjs <slug> [<slug>…] [--apply]");
  process.exit(2);
}

const bp = (argv) =>
  execFileSync("bp", argv, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

const getPaper = (slug, perspective) =>
  JSON.parse(
    bp(["doc", "get", "paper", slug, "-o", "json", ...(perspective ? ["--perspective", perspective] : [])]),
  );

const readerStatus = (slug) =>
  execFileSync(
    "curl",
    ["-s", "-o", "/dev/null", "-w", "%{http_code}", `https://guerrilla.barkpark.cloud/papers/${slug}`],
    { encoding: "utf8" },
  ).trim();

let failures = 0;

for (const slug of slugs) {
  console.log(`\n=== ${slug}`);
  const doc = getPaper(slug);

  if (Array.isArray(doc.blocks)) {
    // Already repaired (or authored with blocks). Re-running is then a VERIFY:
    // read-only, and it still answers the only question that matters — does the
    // stored blocks array carry the same prose the body does, and does the
    // reader serve it?
    // The body is compared when it still holds comparable prose: the original
    // ProseMirror doc, or the {blocks, html} envelope the server synthesises on
    // publish once a blocks array exists.
    const bodyBlocks = doc.body && Array.isArray(doc.body.blocks) ? doc.body.blocks : null;
    const src = isProseMirrorDoc(doc.body)
      ? prosemirrorText(doc.body)
      : bodyBlocks
        ? blocksText(bodyBlocks)
        : null;
    let verdict = "";
    if (src !== null) {
      const stored = blocksText(doc.blocks);
      verdict = ` · body text ${stored === src ? `identical (${src.length} chars)` : `DIVERGED (${src.length} vs ${stored.length})`}`;
      if (stored !== src) failures++;
    }
    const status = readerStatus(slug);
    if (status !== "200") failures++;
    console.log(
      `  VERIFY already carries a top-level blocks list (${doc.blocks.length} blocks)${verdict} · reader ${status}`,
    );
    continue;
  }
  if (doc.body_html) {
    console.log("  REFUSE html_only paper — it renders today; writing blocks would arm its divergence 422");
    continue;
  }
  if (!isProseMirrorDoc(doc.body)) {
    console.log(`  SKIP body is not a ProseMirror doc (${typeof doc.body})`);
    continue;
  }

  const srcText = prosemirrorText(doc.body);
  const { blocks, unsupported, droppedCalloutParagraphs } = prosemirrorDocToBlocks(doc.body);
  const naive = prosemirrorDocToBlocks(doc.body, { spillCallouts: false });

  const outText = blocksText(blocks);
  const naiveText = blocksText(naive.blocks);
  const exact = outText === srcText;

  console.log(`  blocks:   ${blocks.length}  (reader status before: ${readerStatus(slug)})`);
  console.log(`  fidelity: source ${srcText.length} chars · converted ${outText.length} chars · ${exact ? "IDENTICAL" : "MISMATCH"}`);
  console.log(`  naive (no callout spill): ${naiveText.length} chars · ${naiveText.length - outText.length} lost across ${naive.droppedCalloutParagraphs} dropped callout paragraph(s)`);
  if (unsupported.length) console.log(`  unsupported node types: ${unsupported.join(", ")}`);
  if (droppedCalloutParagraphs) console.log(`  BUG: spill mode dropped ${droppedCalloutParagraphs} paragraphs`);

  if (!exact) {
    console.log("  ABORT text fidelity is not exact — refusing to write");
    failures++;
    continue;
  }
  if (!apply) {
    console.log("  dry-run (pass --apply to write)");
    continue;
  }

  const payload = {
    mutations: [
      { patch: { id: slug, type: "paper", set: { blocks } } },
      { publish: { id: slug, type: "paper" } },
    ],
  };
  const file = path.join(os.tmpdir(), `paper-repair-${slug}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  bp(["doc", "mutate", "--file", file, "--yes", "--quiet"]);
  fs.unlinkSync(file);

  // READ IT BACK — from the published perspective, the one the reader uses.
  const after = getPaper(slug, "published");
  const ok =
    Array.isArray(after.blocks) &&
    after.blocks.length === blocks.length &&
    blocksText(after.blocks) === srcText;
  const status = readerStatus(slug);
  console.log(
    `  read-back: blocks=${Array.isArray(after.blocks) ? after.blocks.length : "ABSENT"} · text ${
      Array.isArray(after.blocks) && blocksText(after.blocks) === srcText ? "identical" : "DIVERGED"
    } · reader ${status}`,
  );
  if (!ok || status !== "200") failures++;
}

process.exit(failures ? 1 : 0);
