// __host_profiles.test.mjs — Barkpark's own hosts match their profiles, and the
// checker every host copies (host-profile/check.mjs) fails on what it claims to.
//
// Part 1 checks studio.json, reader.json and web.json against the committed
// surface.json. Part 2 runs check() on a synthetic host in a temp folder against a
// synthetic surface, one claimed failure per case, each naming the name and the
// file:line; the temp folder is removed after every case.
//
// Run: node src/__host_profiles.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { check } from "../host-profile/check.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const profiles = path.join(root, "host-profile");
const checker = path.join(profiles, "check.mjs");

let failures = 0;
const test = (name, fn) => {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};

for (const file of ["../host-profile/studio.json", "../host-profile/reader.json", "../host-profile/web.json"]) {
  test(`${path.basename(file)}: that Barkpark host uses only what its profile lists`, () => {
    const profile = JSON.parse(readFileSync(new URL(file, import.meta.url), "utf8"));
    const surface = JSON.parse(readFileSync(path.join(profiles, "surface.json"), "utf8"));
    assert.deepEqual(check(profile, surface, profiles), []);
  });
}

const surface = {
  contract: "1.22.0",
  build: "000000000000",
  declared: {
    canvas: {
      member: ["blocks", "focusSelection", "state"],
      attribute: ["block-cards", "editable", "x-data-mode"],
      "ancestor attribute": ["data-theme"],
      "DOM attribute": ["data-bp-id", "target"],
      event: ["bp-canvas-ops"],
      "inbound event": ["bp-fleet-paint"],
      "host class": ["bp-paper-editor"],
    },
    both: { static: ["CONTRACT_VERSION"] },
    window: { global: ["BP_PAPER_EDITOR_NO_INJECT"] },
    css: { token: ["--paper-ink"] },
  },
  internal: {
    members: { canvas: ["_editor", "_mount"], editor: ["_editor"] },
    classes: ["ProseMirror", "bp-slash-item", "is-active"],
    attributes: ["data-bp-type", "data-field"],
    events: ["bp-flush-node"],
  },
};

const baseFiles = {
  "app.js": [
    `const canvas = document.querySelector("bp-paper-canvas");`,
    `canvas.blocks = [];`,
    `canvas.addEventListener("bp-canvas-ops", () => canvas.focusSelection());`,
  ].join("\n"),
};
const baseProfile = {
  host: "Fixture",
  root: ".",
  minContract: "1.0.0",
  fleet: false,
  sources: ["."],
  uses: { canvas: { member: ["blocks", "focusSelection"], event: ["bp-canvas-ops"] } },
  internals: [],
};

const run = (files = {}, profile = {}) => {
  const dir = mkdtempSync(path.join(tmpdir(), "host-profile-"));
  try {
    for (const [name, text] of Object.entries({ ...baseFiles, ...files })) writeFileSync(path.join(dir, name), text);
    return check({ ...baseProfile, ...profile }, surface, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};
const line = (text) => ({ "extra.js": `\n\n${text}\n` });
const fails = (errors, expected) => assert.ok(errors.includes(expected), `expected ${JSON.stringify(expected)} in ${JSON.stringify(errors, null, 1)}`);

test("a host that uses only what it lists passes", () => {
  assert.deepEqual(run(), []);
});

test("undeclared contract names fail with the name and file:line, one per kind", () => {
  fails(run(line("canvas.state();")), "undeclared canvas member state at extra.js:3");
  fails(run({ "page.heex": `<bp-paper-canvas editable="false"></bp-paper-canvas>` }), "undeclared canvas attribute editable at page.heex:1");
  fails(run({ "page.heex": `<bp-paper-canvas block-cards></bp-paper-canvas>` }), "undeclared canvas attribute block-cards at page.heex:1");
  fails(run({ "page.css": `[data-theme="dark"] bp-paper-canvas { color: red; }` }), "undeclared canvas ancestor attribute data-theme at page.css:1");
  fails(run(line(`el.dataset.bpId;`)), "undeclared canvas DOM attribute data-bp-id at extra.js:3");
  fails(run(line(`hole.dispatchEvent(new CustomEvent("bp-fleet-paint"));`)), "undeclared canvas inbound event bp-fleet-paint at extra.js:3");
  fails(run({ "page.css": `.bp-paper-editor .x { color: red; }` }), "undeclared canvas host class bp-paper-editor at page.css:1");
  fails(run(line(`if (C.CONTRACT_VERSION) {}`)), "undeclared both static CONTRACT_VERSION at extra.js:3");
  fails(run(line(`window.BP_PAPER_EDITOR_NO_INJECT = true;`)), "undeclared window global BP_PAPER_EDITOR_NO_INJECT at extra.js:3");
  fails(run({ "page.css": `.x { color: var(--paper-ink); }` }), "undeclared css token --paper-ink at page.css:1");
});

test("look-alikes are not uses: a comparison, an assignment, the tag name, a comment (in a file whose name holds .ex too), a dataset key of a non-data attribute", () => {
  assert.deepEqual(run(line(`if (options.target == null) { const target = 1; }`)), []);
  assert.deepEqual(run({ "page.heex": `<bp-paper-editor></bp-paper-editor>` }), []);
  assert.deepEqual(run(line(`// canvas.state() and canvas._editor\n/* canvas._mount() */`)), []);
  assert.deepEqual(run({ "widget.exports.js": `// canvas.state()` }), []);
  assert.deepEqual(run(line(`el.dataset.xDataMode;`)), []);
});

test("the first use reported is the first file by name, whatever order the folder lists", () => {
  fails(run({ "z.js": `canvas.state();`, "b.js": `canvas.state();` }), "undeclared canvas member state at b.js:1");
});

test("a */* inside a line comment does not hide the code after it", () => {
  fails(run(line(`// Accept: */*\ncanvas.state();`)), "undeclared canvas member state at extra.js:4");
});

test("a class inside a class attribute or classList is a use; HEEx and Elixir strings too", () => {
  fails(run({ "page.heex": `<div class="x bp-paper-editor"></div>` }), "undeclared canvas host class bp-paper-editor at page.heex:1");
  fails(run(line(`el.classList.add("bp-paper-editor");`)), "undeclared canvas host class bp-paper-editor at extra.js:3");
  fails(run({ "view.ex": `~s(<div class=\\"bp-paper-editor\\">)` }), "undeclared canvas host class bp-paper-editor at view.ex:1");
});

test("members are matched in scripts, HTML and HEEx, not in Elixir", () => {
  fails(run({ "page.heex": `<script>canvas.state()</script>` }), "undeclared canvas member state at page.heex:1");
  assert.deepEqual(run({ "view.ex": `socket.assigns.state` }), []);
});

test("reach-ins fail with what they touch and file:line", () => {
  fails(run(line(`canvas._editor.commands;`)), "reach-in: private member _editor at extra.js:3");
  fails(run({ "page.css": `bp-paper-canvas .ProseMirror { margin: 0; }` }), "reach-in: internal class ProseMirror at page.css:1");
  fails(run(line(`el.closest("[data-bp-type]");`)), "reach-in: internal attribute data-bp-type at extra.js:3");
  fails(run(line(`node.dispatchEvent(new CustomEvent("bp-flush-node"));`)), "reach-in: internal event bp-flush-node at extra.js:3");
  fails(run(line(`el.editor.view.domObserver.flush();`)), "reach-in: engine internal domObserver at extra.js:3");
  fails(run(line(`canvas.querySelector('[contenteditable="true"]').focus();`)), "reach-in: the editor's own DOM [contenteditable] query at extra.js:3");
  fails(run(line("const li = `[data-bp-id=\"x\"] > li:nth-child(2)`;")), "reach-in: the editor's own DOM [data-bp-id] > child at extra.js:3");
});

test("a host's own names are not reach-ins: a private member it defines, an unprefixed class, a data-* without bp- or pm-", () => {
  assert.deepEqual(run(line(`const hook = { _mount() { this._mount = 1; } };\nhook._mount();`)), []);
  assert.deepEqual(run({ "page.css": `.is-active { color: red; }` }), []);
  assert.deepEqual(run({ "page.heex": `<input data-field="x">` }), []);
});

test("internals lets a listed reach-in through, and fails when it lies or has no reason", () => {
  const files = line(`canvas._editor.commands;`);
  assert.deepEqual(run({}, { internals: undefined }), []);
  assert.deepEqual(run(files, { internals: [{ names: ["_editor"], why: "title row" }] }), []);
  fails(run(files, { internals: [{ names: ["_editor"] }] }), "internals entry without a why: _editor");
  fails(run({}, { internals: [{ names: ["_editor"], why: "gone" }] }), "internals lists _editor but no source touches it");
  fails(run({}, { internals: [{ names: ["_nothing"], why: "?" }] }), "internals lists _nothing, which is not internal to build 000000000000");
});

test("uses fails on a name the contract lacks or no source uses", () => {
  fails(run({}, { uses: { ...baseProfile.uses, editor: { member: ["blocks"] } } }), "not in contract 1.22.0: editor member blocks");
  fails(run({}, { uses: { canvas: { ...baseProfile.uses.canvas, attribute: ["editable"] } } }), "listed but no source uses it: canvas attribute editable");
});

test("notEditor silences a contract name used for something else (an attribute in CSS too), and fails when it lies or has no reason", () => {
  const files = line(`const s = history.state;`);
  assert.deepEqual(run(files, { notEditor: [{ names: ["state"], why: "history.state" }] }), []);
  assert.deepEqual(run({ "page.css": `a[target] { color: red; }` }, { notEditor: [{ names: ["target"], why: "link targets" }] }), []);
  fails(run(files, { notEditor: [{ names: ["state"] }] }), "notEditor entry without a why: state");
  fails(run({}, { notEditor: [{ names: ["state"], why: "?" }] }), "notEditor lists state but no source uses it");
  fails(run(files, { notEditor: [{ names: ["status"], why: "?" }] }), "notEditor lists status, which is not a contract name");
  fails(run({}, { notEditor: [{ names: ["blocks"], why: "?" }] }), "notEditor lists blocks, which uses also lists");
});

test("fleet must match whether the profile lists bp-fleet-paint", () => {
  fails(run({}, { fleet: true }), "fleet is true but the profile does not list bp-fleet-paint");
  const paints = line(`hole.dispatchEvent(new CustomEvent("bp-fleet-paint"));`);
  const uses = { canvas: { ...baseProfile.uses.canvas, "inbound event": ["bp-fleet-paint"] } };
  fails(run(paints, { uses }), "fleet is false but the profile lists bp-fleet-paint");
  assert.deepEqual(run(paints, { uses, fleet: true }), []);
});

test("minContract must be major.minor.patch and not above the build's contract", () => {
  assert.deepEqual(run({}, { minContract: "1.22.0" }), []);
  fails(run({}, { minContract: "1.22.1" }), "minContract 1.22.1 is above the build's contract 1.22.0");
  fails(run({}, { minContract: "1.23.0" }), "minContract 1.23.0 is above the build's contract 1.22.0");
  fails(run({}, { minContract: "2.0.0" }), "minContract 2.0.0 is above the build's contract 1.22.0");
  fails(run({}, { minContract: "1.22" }), "minContract 1.22 is not major.minor.patch");
});

test("a profile whose sources hold no scanned file, or name a missing one, fails", () => {
  fails(run({ "app.js": "" , "notes.txt": "canvas.state()" }, { sources: ["notes.txt"] }), "no source files under notes.txt");
  assert.deepEqual(run({}, { sources: [".", "gone/"] }), ["no such source: gone/"]);
});

test("a profile missing a required key fails with each missing key", () => {
  for (const key of ["host", "root", "minContract", "fleet", "sources", "uses"]) {
    assert.deepEqual(run({}, { [key]: undefined }), [`profile has no ${key}`]);
  }
});

test("the CLI exits 0 on a pass, 1 on a failure, 2 without a profile or with one it cannot read", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "host-profile-cli-"));
  const cli = (args) => spawnSync(process.execPath, [checker, ...args], { encoding: "utf8" });
  const exit = (args) => cli(args).status;
  try {
    writeFileSync(path.join(dir, "app.js"), baseFiles["app.js"]);
    writeFileSync(path.join(dir, "surface.json"), JSON.stringify(surface));
    writeFileSync(path.join(dir, "ok.json"), JSON.stringify(baseProfile));
    writeFileSync(path.join(dir, "bad.json"), JSON.stringify({ ...baseProfile, uses: {} }));
    assert.equal(exit([path.join(dir, "ok.json"), path.join(dir, "surface.json")]), 0);
    assert.equal(exit([path.join(dir, "bad.json"), path.join(dir, "surface.json")]), 1);
    assert.deepEqual([exit([]), cli([]).stderr], [2, "usage: node check.mjs <host-profile.json> [surface.json]\n"]);
    assert.equal(exit([path.join(dir, "missing.json"), path.join(dir, "surface.json")]), 2);
    writeFileSync(path.join(dir, "broken.json"), "{");
    assert.equal(exit([path.join(dir, "ok.json"), path.join(dir, "broken.json")]), 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

if (failures) {
  console.log(`\n${failures} host profile check(s) FAILED`);
  process.exit(1);
}
console.log("\nall host profile checks PASS");
