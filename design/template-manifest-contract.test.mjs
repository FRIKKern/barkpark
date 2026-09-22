#!/usr/bin/env node
// design/template-manifest-contract.test.mjs — the CATALOG half of the template
// family (stw-backlog-catalog-family).
//
// THE CONTRACT, in one sentence: every `barkpark.template.json` in the repo
// satisfies `templates/barkpark.template.schema.json`, and every starter tree
// the scaffolder ships is enrolled in the catalogs that must carry it.
//
// WHY THIS EXISTS. The template catalog is REPLICATED on purpose: the same
// manifest is mirrored into the embedded Go provisioner catalog, the Cloud
// control plane, and the published `create-barkpark-app` package. Every one of
// those mirrors is kept honest by a byte-drift gate — and NOT ONE of them ever
// reads the JSON Schema that the manifests declare with `$schema`. The schema
// was widened (astro/phoenix, an optional `theme`) with nothing in the repo
// able to tell whether a manifest still conformed: the Go side validates its
// OWN hand-written struct over its OWN embedded copies, so a manifest that
// never reaches Go — a create-barkpark-app starter's, say — is unvalidated by
// anything at all. This test is the missing reader.
//
// ENROLMENT IS A PREDICATE, NOT A LIST. A manifest is enrolled by BEING a file
// named `barkpark.template.json` anywhere in the repo (build output pruned).
// A new template, a new mirror root, a sixth edition — all enrol themselves by
// existing. There is no roster here to forget to update, which is exactly how
// five of ten themed surfaces went unguarded in design/check.mjs Part G.
//
// THE ONE LIST THAT REMAINS — `create-barkpark-app`'s AVAILABLE_TEMPLATES — is
// a published TypeScript union and cannot become a directory read without
// losing its literal type. So it gets the other half of the rule: the arm that
// REDS when a starter tree exists and the list does not name it (and when the
// list names a tree that does not exist). The list may stay; silently drifting
// from the filesystem may not.
//
// THE UN-SPLITTABLE COUPLING is asserted here too, and locally. A starter tree
// under js/packages/create-barkpark-app/templates/ MUST have its composed
// mirror under cloud/priv/templates/ in the SAME commit — otherwise
// BarkparkCloud.Templates.AppFilesDriftTest reds the REQUIRED `Cloud gate`.
// That failure arrives minutes later in another lane's job; this one arrives in
// a second, naming the missing mirror.
//
// Run: node design/template-manifest-contract.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCHEMA_PATH = path.join(ROOT, "templates", "barkpark.template.schema.json");
const CBA = path.join(ROOT, "js", "packages", "create-barkpark-app");
const CBA_TEMPLATES = path.join(CBA, "templates");
const CLOUD_MIRROR = path.join(ROOT, "cloud", "priv", "templates");

/** Directories that never hold authored source — pruning them keeps the walk cheap. */
const PRUNE = new Set([
  "node_modules",
  ".git",
  ".next",
  ".astro",
  ".turbo",
  "dist",
  "build",
  "_build",
  "deps",
  "coverage",
  "tmp",
]);

const MANIFEST = "barkpark.template.json";

/** Every manifest in the repo, found by NAME — the enrolment predicate. */
function findManifests(dir, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (PRUNE.has(e.name)) continue;
      findManifests(path.join(dir, e.name), out);
    } else if (e.isFile() && e.name === MANIFEST) {
      out.push(path.join(dir, e.name));
    }
  }
  return out;
}

// ── A draft-07 SUBSET validator ─────────────────────────────────────────────
// Only the keywords templates/barkpark.template.schema.json actually uses. An
// UNKNOWN keyword is a hard error rather than a silent skip: the day someone
// widens the schema with `oneOf` or `minimum`, this test must announce that it
// can no longer read the schema instead of quietly validating less of it. A
// validator that silently ignores what it does not understand is the "green
// with no subject" failure wearing a schema's clothes.
const KNOWN = new Set([
  "$schema",
  "$id",
  "title",
  "description",
  "default",
  "type",
  "const",
  "enum",
  "pattern",
  "minLength",
  "minItems",
  "required",
  "properties",
  "additionalProperties",
  "items",
  "allOf",
  "if",
  "then",
]);

function typeOf(v) {
  if (Array.isArray(v)) return "array";
  if (v === null) return "null";
  return typeof v;
}

/** Returns a list of human-readable violations. Empty = valid. */
function validate(schema, value, at, errs = []) {
  for (const k of Object.keys(schema)) {
    if (!KNOWN.has(k)) {
      errs.push(`${at}: schema uses unsupported keyword "${k}" — this validator cannot read it`);
    }
  }
  if (schema.type && typeOf(value) !== schema.type) {
    errs.push(`${at}: expected ${schema.type}, got ${typeOf(value)}`);
    return errs; // every further keyword would be noise
  }
  if ("const" in schema && value !== schema.const) {
    errs.push(`${at}: expected const ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)}`);
  }
  if (schema.enum && !schema.enum.includes(value)) {
    errs.push(`${at}: ${JSON.stringify(value)} is not one of ${schema.enum.join(" | ")}`);
  }
  if (schema.pattern && typeof value === "string" && !new RegExp(schema.pattern).test(value)) {
    errs.push(`${at}: ${JSON.stringify(value)} does not match /${schema.pattern}/`);
  }
  if (schema.minLength !== undefined && typeof value === "string" && value.length < schema.minLength) {
    errs.push(`${at}: shorter than minLength ${schema.minLength}`);
  }
  if (schema.minItems !== undefined && Array.isArray(value) && value.length < schema.minItems) {
    errs.push(`${at}: fewer than minItems ${schema.minItems}`);
  }
  if (Array.isArray(value) && schema.items) {
    value.forEach((v, i) => validate(schema.items, v, `${at}[${i}]`, errs));
  }
  if (typeOf(value) === "object") {
    for (const req of schema.required ?? []) {
      if (!(req in value)) errs.push(`${at}: missing required property "${req}"`);
    }
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(value)) {
      if (props[k]) validate(props[k], v, `${at}.${k}`, errs);
      else if (schema.additionalProperties === false && schema.properties) {
        errs.push(`${at}: unknown property "${k}" (additionalProperties: false)`);
      }
    }
  }
  for (const sub of schema.allOf ?? []) {
    if (sub.if) {
      if (validate(sub.if, value, at, []).length === 0) {
        validate(sub.then ?? {}, value, at, errs);
      }
    } else {
      validate(sub, value, at, errs);
    }
  }
  return errs;
}

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8"));
const manifests = findManifests(ROOT)
  .map((p) => path.relative(ROOT, p))
  .sort();

// ── CONTROL 0 ───────────────────────────────────────────────────────────────
// An empty population makes every per-manifest assertion vacuously green. Print
// what was measured and refuse a run that measured nothing.
test("the manifest predicate selects a non-empty population, and names it", () => {
  console.log(`# manifests found (${manifests.length}):`);
  for (const m of manifests) console.log(`#   ${m}`);
  assert.ok(
    manifests.length >= 5,
    `expected at least the five repo-root templates to be found, got ${manifests.length}`,
  );
  // The roots that MUST be represented — not a roster of templates, a roster of
  // MIRRORS. A mirror root that stops contributing manifests has been emptied
  // or renamed, and the sweep above would go quietly narrower.
  for (const root of [
    "templates/",
    "js/packages/create-barkpark-app/templates/",
    "internal/provisioner/catalog/templates/",
    "cloud/priv/templates/",
  ]) {
    assert.ok(
      manifests.some((m) => m.startsWith(root)),
      `no manifest found under ${root} — a catalog mirror has gone silent`,
    );
  }
});

// ── EVERY MANIFEST CONFORMS ─────────────────────────────────────────────────
for (const rel of manifests) {
  test(`${rel}: conforms to templates/barkpark.template.schema.json`, () => {
    const raw = fs.readFileSync(path.join(ROOT, rel), "utf8");
    let doc;
    try {
      doc = JSON.parse(raw);
    } catch (e) {
      assert.fail(`${rel}: not valid JSON — ${e.message}`);
    }
    const errs = validate(schema, doc, rel);
    assert.deepEqual(errs, [], `${rel} violates the manifest schema:\n  ${errs.join("\n  ")}`);
  });

  test(`${rel}: its \`name\` is the directory it lives in`, () => {
    // The slug is the deploy-UI key AND the catalog key. A manifest whose name
    // disagrees with its directory routes one way and is mirrored another.
    const doc = JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
    assert.equal(
      doc.name,
      path.basename(path.dirname(rel)),
      `${rel}: name "${doc.name}" but the directory is "${path.basename(path.dirname(rel))}"`,
    );
  });
}

// ── THE ONE REMAINING LIST GETS THE ARM THAT REDS ───────────────────────────
const cbaStarters = fs
  .readdirSync(CBA_TEMPLATES, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith("_"))
  .map((e) => e.name)
  .sort();

const constantsSrc = fs.readFileSync(path.join(CBA, "src", "constants.ts"), "utf8");
const listed = (() => {
  const m = constantsSrc.match(/AVAILABLE_TEMPLATES\s*=\s*\[([^\]]*)\]/);
  if (!m) return null;
  return [...m[1].matchAll(/['"]([^'"]+)['"]/g)].map((x) => x[1]).sort();
})();

test("create-barkpark-app: AVAILABLE_TEMPLATES is parseable and non-empty", () => {
  console.log(`# starter dirs:          ${cbaStarters.join(", ") || "(none)"}`);
  console.log(`# AVAILABLE_TEMPLATES:   ${(listed ?? []).join(", ") || "(unparseable)"}`);
  assert.ok(listed, "could not parse AVAILABLE_TEMPLATES out of src/constants.ts");
  assert.ok(listed.length >= 1, "AVAILABLE_TEMPLATES is empty");
  assert.ok(cbaStarters.length >= 1, "no starter directories found — the arms below measure nothing");
});

test("create-barkpark-app: every starter tree is named by AVAILABLE_TEMPLATES", () => {
  const missing = cbaStarters.filter((s) => !listed.includes(s));
  assert.deepEqual(
    missing,
    [],
    `these starter trees ship but no user can pick them — add them to ` +
      `AVAILABLE_TEMPLATES in js/packages/create-barkpark-app/src/constants.ts: ${missing.join(", ")}`,
  );
});

test("create-barkpark-app: every AVAILABLE_TEMPLATES entry has a starter tree", () => {
  const phantom = listed.filter((s) => !cbaStarters.includes(s));
  assert.deepEqual(
    phantom,
    [],
    `AVAILABLE_TEMPLATES offers templates with no tree behind them — the scaffold ` +
      `would refuse at run time: ${phantom.join(", ")}`,
  );
});

test("create-barkpark-app: every starter ships its own barkpark.template.json", () => {
  const bare = cbaStarters.filter(
    (s) => !fs.existsSync(path.join(CBA_TEMPLATES, s, MANIFEST)),
  );
  assert.deepEqual(
    bare,
    [],
    `a scaffolded app with no manifest cannot be bootstrapped by the provisioner: ${bare.join(", ")}`,
  );
});

test("create-barkpark-app: every starter has its composed cloud/priv/templates mirror", () => {
  // `make cloud-templates-sync` composes _shared + the starter into the mirror
  // the control plane pushes. AppFilesDriftTest asserts byte-identity in BOTH
  // directions and feeds the REQUIRED `Cloud gate`, so a starter landed on the
  // js side alone reds a required context. Catch it here, by name, in a second.
  const unmirrored = cbaStarters.filter(
    (s) => !fs.existsSync(path.join(CLOUD_MIRROR, s, MANIFEST)),
  );
  assert.deepEqual(
    unmirrored,
    [],
    `these starters have no cloud/priv/templates mirror — run \`make cloud-templates-sync\` ` +
      `IN THE SAME COMMIT or BarkparkCloud.Templates.AppFilesDriftTest reds the required ` +
      `Cloud gate: ${unmirrored.join(", ")}`,
  );
});
