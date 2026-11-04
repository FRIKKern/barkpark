// __contract_truth.test.mjs — the package's declared surface is the real one.
//
// This suite owns the package contract, types, source API, events, attributes,
// classes and package stylesheet reads. Barkpark's reader, canonical surface
// styles and committed bundle are checked by paper-editor-host-tests.
//
// Run: node src/__contract_truth.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  ancestorReadNames,
  appears,
  contract,
  dispatched,
  instances,
  isDomEvent,
  js,
  known,
  listened,
  md,
  missing,
  names,
  packageCss,
  packageSource,
  pkg,
  publicMembers,
  publicStatics,
  read,
  sourceWrites,
  types,
  window,
} from "./__contract_truth_support.mjs";

let failures = 0;
let checks = 0;
const check = (name, fn) => {
  checks++;
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};

check("index.d.ts declares every name EMBED-CONTRACT.md indexes", () => {
  assert.deepEqual(missing(contract, types), []);
});

check("EMBED-CONTRACT.md indexes every name index.d.ts declares", () => {
  assert.deepEqual(missing(types, contract), []);
});

check("EMBED-CONTRACT.md describes every indexed name outside the index", () => {
  const body = md.slice(0, md.indexOf("## Surface index")) + md.slice(md.indexOf("## Known reach-ins"));
  const undescribed = [...contract].map((key) => key.split("|")[2]).filter((name) => !new RegExp("`(window\\.|\\[|\\.|<)?" + name.replace(/[$]/g, "\\$") + "[`( =\\]>.]").test(body));
  assert.deepEqual([...new Set(undescribed)].sort(), []);
});

for (const [tag, element] of [["bp-paper-canvas", "canvas"], ["bp-paper-editor", "editor"]]) {
  const cls = window.customElements.get(tag);
  const declared = new Set(names("member", element));
  check(`every public member of <${tag}> is declared`, () => {
    assert.deepEqual(publicMembers(cls).filter((name) => !declared.has(name)).sort(), []);
  });
  check(`every public own property of a newly created and of a connected <${tag}> is declared`, () => {
    assert.ok(instances[tag].mounted, "the connected element did not mount");
    assert.deepEqual([...new Set([...instances[tag].created, ...instances[tag].connected])].filter((name) => !declared.has(name)).sort(), []);
  });
  check(`<${tag}> has every member declared for it`, () => {
    assert.deepEqual([...declared].filter((name) => !(name in cls.prototype)).sort(), []);
  });
  check(`<${tag}>'s public statics are the declared ones, with this source's versions`, () => {
    assert.deepEqual(publicStatics(cls).sort(), names("static", "both").sort());
    assert.equal(cls.CONTRACT_VERSION, pkg.barkpark.contractVersion);
    assert.equal(cls.EDITOR_VERSION, pkg.version);
    assert.equal(cls.BUILD_SHA, null, "unbuilt source has no BUILD_SHA");
  });
}

check("EMBED-CONTRACT.md's title and opening name this CONTRACT_VERSION", () => {
  const version = pkg.barkpark.contractVersion;
  assert.ok(md.startsWith(`# \`<bp-paper-editor>\` and \`<bp-paper-canvas>\` — Embed Contract (v${version})`), "title");
  assert.ok(md.includes(`\`BpPaperEditor.CONTRACT_VERSION === "${version}"\``), "opening line");
  assert.ok(read("index.d.ts").includes(`EMBED-CONTRACT.md\n// (v${version})`), "index.d.ts header");
});

check("every declared outbound event is dispatched by the source", () => {
  const silent = [...names("event", "canvas"), ...names("event", "editor")].filter((event) => !dispatched(event));
  assert.deepEqual([...new Set(silent)].sort(), []);
});

check("every declared inbound event is listened for by the source", () => {
  assert.deepEqual(names("inbound event", "canvas").filter((event) => !listened(event)).sort(), []);
});

check("every declared package attribute and class appears in the package source", () => {
  const all = ["attribute|canvas", "attribute|editor", "ancestor attribute|canvas", "DOM attribute|canvas", "class|canvas"]
    .flatMap((group) => names(...group.split("|")));
  assert.deepEqual(all.filter((name) => !appears(name, packageSource)).sort(), []);
});

check("every declared DOM attribute is written by the source", () => {
  assert.deepEqual(names("DOM attribute", "canvas").filter((name) => !sourceWrites.has(name)).sort(), []);
});

check("every declared host class appears in the source", () => {
  assert.deepEqual(names("host class", "canvas").filter((name) => !appears(name, packageSource)).sort(), []);
});

check("every declared global is read by the source", () => {
  assert.deepEqual(names("global", "window").filter((global) => !appears(`window.${global}`, js)).sort(), []);
});

check("every name a host supplies (picker, mermaid) is used by the source", () => {
  const unused = [
    ...names("tag", "picker").filter((tag) => !new RegExp(`createElement\\(\\s*["'\`]${tag}["'\`]`).test(js)),
    ...[...names("member", "picker"), ...names("member", "mermaid")].filter((member) => !new RegExp(`\\.${member}\\b`).test(js)),
    ...names("attribute", "picker").filter((attribute) => !sourceWrites.has(attribute)),
  ];
  assert.deepEqual(unused.sort(), []);
});

check("every event the source dispatches is declared, editor-internal or a reach-in", () => {
  const literal = [...js.matchAll(/new\s+CustomEvent\(\s*(["'`])([\w-]+)\1/g)].map((match) => match[2]);
  assert.ok(literal.length > 0, "found no dispatched events");
  assert.equal(literal.length, [...js.matchAll(/new\s+CustomEvent\(/g)].length, "a CustomEvent whose name is not a plain literal");
  assert.deepEqual([...new Set(literal)].filter((event) => !known(event)).sort(), []);
});

check("every event the source listens for by a literal name is a DOM event, declared, editor-internal or a reach-in", () => {
  const heard = new Set([...js.matchAll(/addEventListener\(\s*(["'`])([^"'`$]+)\1/g)].map((match) => match[2]));
  assert.ok(heard.has("bp-fleet-paint") && heard.has("keydown"), "found no listeners");
  assert.deepEqual([...heard].filter((event) => !isDomEvent(event) && !known(event)).sort(), []);
});

check("every package attribute and class the source reads off an ancestor or the document is declared, editor-internal or a reach-in", () => {
  const reads = ancestorReadNames(packageCss);
  assert.ok(reads.has("data-paper-palette") && reads.has("data-theme"), "the selector scan found nothing");
  assert.deepEqual([...reads].filter((name) => !known(name)).sort(), []);
});

if (failures) {
  console.log(`\n${failures} package contract truth check(s) FAILED`);
  process.exit(1);
}
if (checks !== 22) throw new Error(`expected 22 package checks, ran ${checks}`);
console.log("\nall 22 package contract truth checks (36 assertions) PASS");
