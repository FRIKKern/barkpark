import assert from "node:assert/strict";
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { STEPS, globToRegExp, ordered, reached } from "./derived-files.mjs";
import { commandsFor, isTest } from "./reach.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const names = (paths) => reached(paths).map((s) => s.name);
const CONFORMANCE = ["elixir", "editor-canvas", "react", "pdrender", "pdrender-wasm", "mobile"].map(
  (r) => `conformance-${r}`,
);

test("globs: ** spans directories, * stays inside one", () => {
  assert.ok(globToRegExp("api/priv/gettext/**/*.po").test("api/priv/gettext/nb_NO/LC_MESSAGES/default.po"));
  assert.ok(globToRegExp("api/lib/x/**").test("api/lib/x/a/b.ex"));
  assert.ok(globToRegExp("a/*.ex").test("a/b.ex"));
  assert.ok(!globToRegExp("a/*.ex").test("a/b/c.ex"));
  assert.ok(!globToRegExp("a/b.ex").test("a/bxex"));
});

test("a .po edit reaches the golden pack, all six reports and the editor snapshot", () => {
  const hit = names(["api/priv/gettext/nb_NO/LC_MESSAGES/default.po"]);
  for (const n of ["golden-pack", ...CONFORMANCE, "studio-snapshot"]) assert.ok(hit.includes(n), n);
  assert.ok(!hit.includes("paper-editor"));
});

test("#25094's first head reaches the three files that cost it three rounds", () => {
  const hit = names([
    "api/lib/barkpark_web/live/studio/studio_live/blocks.ex",
    "api/lib/barkpark_web/studio_locale.ex",
    "api/priv/gettext/default.pot",
    "api/priv/gettext/en/LC_MESSAGES/default.po",
    "api/priv/gettext/nb_NO/LC_MESSAGES/default.po",
    "api/priv/static/assets/bp-paper-editor-hooks.js",
    "api/test/barkpark_web/live/paper_toc_depth_form_test.exs",
  ]);
  for (const n of ["golden-pack", ...CONFORMANCE, "studio-snapshot"]) assert.ok(hit.includes(n), n);
});

test("an editor source edit reaches the bundle, surface.json and only the canvas report", () => {
  const hit = names(["api/assets/paper-editor/src/canvas/caret-before-keys.js"]);
  assert.deepEqual(hit, ["paper-editor", "conformance-editor-canvas"]);
});

test("a render edit reaches the pack, every report, surface.json and the HTML goldens", () => {
  const hit = names(["api/lib/barkpark/portable_doc/render/blocks.ex"]);
  for (const n of ["golden-pack", ...CONFORMANCE, "paper-editor", "email-golden", "studio-snapshot", "reader-style-goldens"])
    assert.ok(hit.includes(n), n);
});

test("a React renderer edit reaches only the React and mobile reports", () => {
  assert.deepEqual(names(["js/packages/react/src/blocks/Toc.tsx"]), ["conformance-react", "conformance-mobile"]);
});

test("a design token edit reaches everything built from the tokens", () => {
  const hit = names(["design/tokens.json"]);
  for (const n of ["design-emit", "paper-editor", "golden-pack", ...CONFORMANCE, "studio-snapshot"]) assert.ok(hit.includes(n), n);
});

test("a change outside every input reaches nothing", () => {
  assert.deepEqual(names(["README.md", "api/lib/barkpark/accounts.ex"]), []);
});

test("a Bulldocs layout edit reaches the pack's pages and all six reports, not the editor", () => {
  for (const path of [
    "api/lib/barkpark_web/layouts/bulldocs.html.heex",
    "api/lib/barkpark_web/layouts.ex",
    "api/lib/barkpark_web/components/share_meta.ex",
    "api/lib/barkpark/tenancy.ex",
  ]) {
    const hit = names([path]);
    for (const n of ["golden-pack", ...CONFORMANCE]) assert.ok(hit.includes(n), `${path}: ${n}`);
    assert.ok(!hit.includes("paper-editor") && !hit.includes("studio-snapshot"), path);
  }
});

test("a module a rendered block reads outside render/ reaches every HTML golden", () => {
  for (const path of [
    "api/lib/barkpark/portable_doc/constraints.ex",
    "api/lib/barkpark/portable_doc/validate.ex",
    "api/lib/barkpark/portable_doc/text_diff.ex",
    "api/lib/barkpark/chat/tool_rows.ex",
  ]) {
    const hit = names([path]);
    for (const n of ["golden-pack", "email-golden", "conformance-elixir", "studio-snapshot", "reader-style-goldens"])
      assert.ok(hit.includes(n), `${path}: ${n}`);
  }
});

test("a Sheets plugin edit does not reach unrelated HTML goldens", () => {
  assert.deepEqual(names(["api/lib/barkpark/plugins/sheets/core.ex"]), []);
});

test("a Studio component the editor renders reaches the snapshot only", () => {
  assert.deepEqual(names(["api/lib/barkpark_web/components/field_inputs.ex"]), ["studio-snapshot"]);
});

test("the paper editor's server dependencies reach the Studio snapshot", () => {
  for (const path of [
    "api/lib/barkpark/content.ex",
    "api/lib/barkpark/content/papers/block_ops.ex",
    "api/lib/barkpark/portable_doc/block_ids.ex",
  ])
    assert.ok(names([path]).includes("studio-snapshot"), path);
  assert.ok(names(["api/lib/barkpark/content/papers/block_ops.ex"]).includes("golden-pack"));
});

test("every input glob matches a tracked file", () => {
  const files = execSync("git ls-files", { cwd: root, encoding: "utf8", maxBuffer: 1 << 28 }).split("\n");
  for (const s of STEPS)
    for (const glob of s.inputs) assert.ok(files.some((file) => globToRegExp(glob).test(file)), `${s.name}: ${glob}`);
});

test("every step comes after the steps it waits for", () => {
  const order = ordered().map((s) => s.name);
  assert.equal(order.length, STEPS.length);
  for (const s of STEPS) for (const d of s.after) assert.ok(order.indexOf(d) < order.indexOf(s.name), `${d} before ${s.name}`);
});

test("every gate file and every mix task a step names exists", () => {
  for (const s of STEPS) {
    for (const g of s.gates.filter((g) => !g.includes(".yml: "))) assert.ok(existsSync(join(root, g)), `${s.name}: ${g}`);
    for (const cmd of [s.check, s.write].filter(Boolean)) {
      for (const [, task] of cmd.matchAll(/mix (barkpark\.[\w.]+)/g))
        assert.ok(existsSync(join(root, "api/lib/mix/tasks", `${task}.ex`)), `${s.name}: mix ${task}`);
      for (const [, file] of cmd.matchAll(/mix test (test\/\S+?\.exs)/g))
        assert.ok(existsSync(join(root, "api", file)), `${s.name}: ${file}`);
    }
  }
});

test("every command changes directory at most once (each runs from the repo root)", () => {
  for (const s of STEPS)
    for (const cmd of [s.check, s.write].filter(Boolean))
      assert.ok((cmd.match(/(^|&& |\()cd /g) || []).length <= 1, `${s.name}: ${cmd}`);
});

test("an env switch sits next to the command it is for, never in front of a cd", () => {
  for (const s of STEPS)
    for (const cmd of [s.check, s.write].filter(Boolean)) assert.doesNotMatch(cmd, /[A-Z_]+=\S+ cd /, s.name);
});

test("reach names the command that runs each kind of test", () => {
  assert.deepEqual(
    commandsFor([
      "api/test/a_test.exs",
      "api/test/b_test.exs",
      "cloud/test/c_test.exs",
      "internal/pdrender/conformance_test.go",
      "apps/mobile/__tests__/conformance.test.tsx",
      "js/packages/react/tests/conformance.test.tsx",
      "api/assets/paper-editor/src/__surface.test.mjs",
      ".github/workflows/x.yml: Step",
    ]),
    [
      "cd api && mix test test/a_test.exs test/b_test.exs",
      "cd cloud && mix test test/c_test.exs",
      "go test ./internal/pdrender -count=1",
      "cd apps/mobile && pnpm exec jest __tests__/conformance.test.tsx",
      "cd js && pnpm --filter @barkpark/react exec vitest run tests/conformance.test.tsx",
      "cd api/assets/paper-editor && node src/__surface.test.mjs",
    ],
  );
});

test("reach lists a changed test file as one to run", () => {
  assert.ok(isTest("api/test/x_test.exs"));
  assert.ok(isTest("api/assets/paper-editor/src/__reader_hooks.test.mjs"));
  assert.ok(!isTest("api/lib/x.ex"));
});
