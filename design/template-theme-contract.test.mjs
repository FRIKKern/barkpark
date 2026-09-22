#!/usr/bin/env node
// design/template-theme-contract.test.mjs — the TEMPLATE half of the theme
// matrix (stw-backlog-theme-matrix c0).
//
// THE CONTRACT, in one sentence: every supported search template stamps ONE
// documented `data-bp-theme` default and reacts consistently to
// `bp:themechange`.
//
// WHY THIS EXISTS. `design/theme-emit.test.mjs` proves the emitted CSS carries
// every theme; `design/check.mjs` proves the committed bytes are the emitter's.
// Neither looks at the RUNTIME half, and the runtime half had genuinely
// diverged: the Astro edition's graph pane pinned `theme: 'dark'` and
// registered no `bp:themechange` listener at all, while the byte-identical
// renderer in the Next edition resolved the mode from `data-theme` and re-skinned
// live. Two editions of the same flagship, one contract, two behaviours — and
// every CSS gate in the repo was green throughout.
//
// ENROLMENT IS A PREDICATE, NOT A LIST. A template is a "supported search
// template" when it SHIPS THE RENDERER (`public/bp-graph.js`) or its
// `barkpark.template.json` pins a `theme`. A sixth template that does either is
// enrolled by adding the file, not by editing this test — and a template that
// ships the renderer while FORGETTING the manifest theme is caught rather than
// excused, which a manifest-only predicate would have missed.
//
// THE POPULATION OF GRAPH HOSTS IS ALSO A PREDICATE: any file under the
// template (outside `public/`, which holds the renderer itself) that names
// `BarkparkGraphRenderer` and mentions a `theme:` option. That is exactly the
// set of files that hand the renderer a theme.
//
// Run: node design/template-theme-contract.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TEMPLATES = path.join(ROOT, "templates");
const THEMES_DIR = path.join(ROOT, "design", "themes");

/** The shipped palette roster, READ from design/themes/ — never enumerated. */
const SHIPPED_THEMES = fs
  .readdirSync(THEMES_DIR)
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.replace(/\.json$/, ""))
  .sort();

function readIfFile(p) {
  try {
    return fs.statSync(p).isFile() ? fs.readFileSync(p, "utf8") : null;
  } catch {
    return null;
  }
}

/** Every file under `dir`, skipping node_modules / .next / dist / build output. */
function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (["node_modules", ".next", "dist", ".astro", "vendor"].includes(e.name)) continue;
      walk(path.join(dir, e.name), out);
    } else if (e.isFile()) {
      out.push(path.join(dir, e.name));
    }
  }
  return out;
}

/** The enrolment predicate. Returns [{slug, dir, manifest, files}]. */
function supportedSearchTemplates() {
  const found = [];
  for (const e of fs.readdirSync(TEMPLATES, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name.startsWith("_")) continue;
    const dir = path.join(TEMPLATES, e.name);
    const manifestRaw = readIfFile(path.join(dir, "barkpark.template.json"));
    const manifest = manifestRaw ? JSON.parse(manifestRaw) : null;
    const shipsRenderer = readIfFile(path.join(dir, "public", "bp-graph.js")) !== null;
    if (!shipsRenderer && !(manifest && typeof manifest.theme === "string")) continue;
    found.push({ slug: e.name, dir, manifest, files: walk(dir) });
  }
  return found;
}

const enrolled = supportedSearchTemplates();

// ── CONTROL 0 ───────────────────────────────────────────────────────────────
// An empty population would make every per-template assertion below vacuously
// green — the exact "a green with no subject" failure. Print the population and
// refuse a run that measured nothing.
test("the enrolment predicate selects a non-empty population, and names it", () => {
  console.log(
    `# supported search templates: ${enrolled.map((t) => t.slug).join(", ") || "(none)"}`,
  );
  console.log(`# shipped palettes (design/themes/): ${SHIPPED_THEMES.join(", ")}`);
  assert.ok(
    enrolled.length >= 2,
    `expected at least the two flagship editions to enrol, got ${enrolled.length}`,
  );
  assert.ok(SHIPPED_THEMES.length >= 2, "design/themes/ holds fewer than two palettes");
});

for (const t of enrolled) {
  // ── ONE DOCUMENTED DEFAULT ────────────────────────────────────────────────
  test(`${t.slug}: pins exactly one data-bp-theme default, and it is a shipped palette`, () => {
    assert.ok(t.manifest, `${t.slug}/barkpark.template.json is missing`);
    assert.equal(
      typeof t.manifest.theme,
      "string",
      `${t.slug} ships the graph renderer but its manifest pins no \`theme\` — the ` +
        `data-bp-theme default would be undocumented`,
    );
    assert.ok(
      SHIPPED_THEMES.includes(t.manifest.theme),
      `${t.slug} pins theme "${t.manifest.theme}", which has no design/themes/ file ` +
        `(shipped: ${SHIPPED_THEMES.join(", ")})`,
    );
  });

  test(`${t.slug}: the manifest default and the code fallback are the same palette`, () => {
    // The manifest states the default; the boot script bakes one. A drift
    // between them is a default nobody can read off either surface.
    const quoted = [`'${t.manifest.theme}'`, `"${t.manifest.theme}"`];
    const carriers = t.files.filter(
      (f) => !f.endsWith(".css") && !f.endsWith(".json") && !f.endsWith(".md"),
    );
    const hit = carriers.find((f) => {
      const src = readIfFile(f) ?? "";
      return quoted.some((q) => src.includes(q));
    });
    assert.ok(
      hit,
      `${t.slug}: no source file carries the manifest default ${quoted[0]} as a ` +
        `literal fallback — the manifest and the built site can disagree silently`,
    );
  });

  test(`${t.slug}: stamps data-bp-theme exactly once, letting a visitor choice win`, () => {
    const sites = t.files.filter((f) => (readIfFile(f) ?? "").includes("dataset.bpTheme"));
    assert.equal(
      sites.length,
      1,
      `${t.slug}: expected ONE data-bp-theme stamp site, found ${sites.length}: ` +
        sites.map((f) => path.relative(ROOT, f)).join(", "),
    );
    const src = readIfFile(sites[0]);
    assert.match(
      src,
      /dataset\.bpTheme\s*=\s*localStorage\.getItem\(['"]bp_theme['"]\)\s*\|\|/,
      `${path.relative(ROOT, sites[0])}: the stamp must read localStorage.bp_theme ` +
        `first and fall back to the deploy default — a visitor's own choice wins`,
    );
    assert.match(
      src,
      /dataset\.theme\s*=/,
      `${path.relative(ROOT, sites[0])}: the same boot must seed the light/dark axis ` +
        `(data-theme) that the graph host resolves its mode from`,
    );
  });

  // ── REACTS CONSISTENTLY TO bp:themechange ─────────────────────────────────
  const graphHosts = t.files.filter((f) => {
    if (f.includes(`${path.sep}public${path.sep}`)) return false; // the renderer itself
    const src = readIfFile(f) ?? "";
    return src.includes("BarkparkGraphRenderer") && /\btheme\s*:/.test(src);
  });

  test(`${t.slug}: has at least one graph host that hands the renderer a theme`, () => {
    console.log(
      `# ${t.slug} graph hosts: ${graphHosts.map((f) => path.relative(ROOT, f)).join(", ") || "(none)"}`,
    );
    assert.ok(
      graphHosts.length >= 1,
      `${t.slug}: no graph host found — the assertions below would measure nothing`,
    );
  });

  for (const host of graphHosts) {
    const rel = path.relative(ROOT, host);
    test(`${rel}: resolves the mode from data-theme and re-skins on bp:themechange`, () => {
      const src = readIfFile(host);
      assert.match(
        src,
        /documentElement\.dataset\.theme/,
        `${rel}: must resolve the CURRENT mode from documentElement.dataset.theme — ` +
          `the attribute the root layout seeds before first paint`,
      );
      assert.match(
        src,
        /addEventListener\(\s*['"]bp:themechange['"]/,
        `${rel}: must register a bp:themechange listener — without it the graph is ` +
          `an island that never follows a runtime theme flip`,
      );
      assert.match(
        src,
        /setTheme/,
        `${rel}: the bp:themechange listener must forward the resolved mode to the ` +
          `controller's setTheme`,
      );
      assert.match(
        src,
        /removeEventListener\(\s*['"]bp:themechange['"]/,
        `${rel}: the listener must be torn down on unmount`,
      );
    });

    test(`${rel}: passes no hard-coded theme literal to the renderer`, () => {
      const src = readIfFile(host);
      const offenders = src
        .split("\n")
        .map((line, i) => [i + 1, line])
        // A `theme:` option whose value is a quoted mode and which ENDS the
        // property (comma or end of line). A TypeScript signature such as
        // `setTheme?: (theme: "dark" | "light") => void` continues with `|`
        // and is therefore not an option assignment.
        .filter(([, line]) => /\btheme\s*:\s*(['"])(dark|light)\1\s*(,\s*)?$/.test(line));
      assert.deepEqual(
        offenders,
        [],
        `${rel}: a hard-coded theme literal pins the graph to one mode forever:\n` +
          offenders.map(([n, l]) => `  line ${n}: ${l.trim()}`).join("\n"),
      );
    });
  }
}

// ── THE DOCUMENTED HALF ─────────────────────────────────────────────────────
// "Documented" is only true while the prose names the palettes that actually
// ship. Four surfaces enumerated `evergreen | ember | fjord | charple` after
// `iris` landed in design/themes/, so a deploy could pin a palette no document
// admitted existed. Compared as a SET against the directory, so the sixth
// palette reds these the day it lands.
const PALETTE_PROSE = [
  "templates/MANIFEST.md",
  "templates/search-starter/.env.example",
  "templates/astro-search-starter/.env.example",
  "templates/search-starter/next.config.mjs",
];

for (const relDoc of PALETTE_PROSE) {
  test(`${relDoc}: its palette enumeration equals the shipped roster`, () => {
    const src = readIfFile(path.join(ROOT, relDoc));
    assert.ok(src, `${relDoc} is missing`);
    // Any run of `name | name | name` built from the shipped vocabulary.
    const runs = [...src.matchAll(/([a-z]+(?:\s*\|\s*[a-z]+){2,})/g)]
      .map((m) => m[1].split("|").map((s) => s.trim()))
      .filter((names) => names.some((n) => SHIPPED_THEMES.includes(n)));
    assert.ok(
      runs.length >= 1,
      `${relDoc}: no palette enumeration found — it is supposed to document the ` +
        `data-bp-theme default's vocabulary`,
    );
    for (const names of runs) {
      assert.deepEqual(
        [...names].sort(),
        SHIPPED_THEMES,
        `${relDoc}: documents "${names.join(" | ")}" but design/themes/ ships ` +
          `"${SHIPPED_THEMES.join(" | ")}"`,
      );
    }
  });
}

// ── THE PREVIEWABILITY INVENTORY ────────────────────────────────────────────
// stw4-backlog-picker-thumbnails c0. A create-site picker wants to show a
// thumbnail per choice, and the first honest question is WHICH CHOICES DESERVE
// ONE. `templates/` holds seven directories but only five are deploy-UI
// templates; the other two are bare framework scaffolds with no manifest and no
// seeded content. Photographing those would advertise a designed option that
// does not exist — the criterion's "framework or infrastructure choices that
// should remain text-only".
//
// design/preview-inventory.json is that inventory, and these arms keep it from
// becoming an opinion. Every boolean in it is DERIVED from the tree, so the file
// carries the REASON (which a test cannot write) while the test owns the CLAIM.
//
// COVERAGE IS A PREDICATE, NOT A LIST: the inventory's key sets are compared as
// SETS against the directories under templates/ and the palette files under
// design/themes/. An eighth template or a sixth palette reds this the day it
// lands, rather than being silently absent from the picker's contract.
//
// The inventory deliberately holds NO image paths. A binary preview asset must
// not ride inside a published starter payload, so where the bytes live is the
// picker surface's problem, not the descriptor's.
const INVENTORY_PATH = path.join(ROOT, "design", "preview-inventory.json");
const inventory = JSON.parse(fs.readFileSync(INVENTORY_PATH, "utf8"));

/** Every directory under templates/ that a picker could conceivably list. */
const TEMPLATE_DIRS = fs
  .readdirSync(TEMPLATES, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith("_"))
  .map((e) => e.name)
  .sort();

/** The `theme` enum the versioned descriptor actually accepts. */
const SCHEMA_THEME_ENUM = (() => {
  const schema = JSON.parse(
    fs.readFileSync(path.join(TEMPLATES, "barkpark.template.schema.json"), "utf8"),
  );
  return [...(schema.properties?.theme?.enum ?? [])].sort();
})();

function manifestOf(slug) {
  const raw = readIfFile(path.join(TEMPLATES, slug, "barkpark.template.json"));
  return raw ? JSON.parse(raw) : null;
}

// ── CONTROL ─────────────────────────────────────────────────────────────────
// Every assertion below iterates the inventory. An empty or half-empty file
// would make them vacuously green, so print all four populations and refuse a
// run that measured nothing.
test("preview inventory: the populations are non-empty, and named", () => {
  const invTemplates = Object.keys(inventory.templates ?? {}).sort();
  const invThemes = Object.keys(inventory.themes ?? {}).sort();
  console.log(`# templates/ dirs:        ${TEMPLATE_DIRS.join(", ")}`);
  console.log(`# inventory templates:    ${invTemplates.join(", ") || "(none)"}`);
  console.log(`# design/themes/:         ${SHIPPED_THEMES.join(", ")}`);
  console.log(`# inventory themes:       ${invThemes.join(", ") || "(none)"}`);
  console.log(`# schema theme enum:      ${SCHEMA_THEME_ENUM.join(", ") || "(none)"}`);
  assert.equal(inventory.inventoryVersion, "1", "inventoryVersion must be \"1\"");
  assert.ok(invTemplates.length >= 2, `inventory names ${invTemplates.length} templates`);
  assert.ok(invThemes.length >= 2, `inventory names ${invThemes.length} themes`);
  assert.ok(TEMPLATE_DIRS.length >= 2, "templates/ holds fewer than two directories");
});

test("preview inventory: covers exactly the directories under templates/", () => {
  assert.deepEqual(
    Object.keys(inventory.templates).sort(),
    TEMPLATE_DIRS,
    "design/preview-inventory.json .templates must name every directory under " +
      "templates/ and nothing else — a template with no entry is a picker choice " +
      "with no ruling on whether it may show a thumbnail",
  );
});

test("preview inventory: covers exactly the palettes under design/themes/", () => {
  assert.deepEqual(
    Object.keys(inventory.themes).sort(),
    SHIPPED_THEMES,
    "design/preview-inventory.json .themes must name every design/themes/*.json " +
      "palette and nothing else",
  );
});

for (const slug of Object.keys(inventory.templates).sort()) {
  const entry = inventory.templates[slug];

  test(`preview inventory: ${slug}'s previewable flag is derived, not asserted`, () => {
    const manifest = manifestOf(slug);
    // The rule, stated on two grounds: a directory the deploy UI never
    // enumerates cannot be previewed, and a bare scaffold has no representative
    // output to photograph even when it IS enumerated.
    const expected = manifest !== null && manifest.demoContent === true;
    assert.equal(
      entry.previewable,
      expected,
      `${slug}: inventory says previewable=${entry.previewable} but the tree says ` +
        `${expected} (barkpark.template.json ${manifest ? "present" : "absent"}, ` +
        `demoContent=${manifest ? JSON.stringify(manifest.demoContent) : "n/a"})`,
    );
    assert.equal(
      entry.kind,
      expected ? "site" : "framework-scaffold",
      `${slug}: kind must follow previewable — "site" when there is output to ` +
        `show, "framework-scaffold" when the honest control is a text label`,
    );
  });

  test(`preview inventory: ${slug} carries a written reason`, () => {
    // The booleans are mechanical; the REASON is the half a test cannot write,
    // and the half that keeps a text-only ruling honest rather than arbitrary.
    assert.equal(typeof entry.reason, "string", `${slug}: reason must be a string`);
    assert.ok(
      entry.reason.trim().length >= 40,
      `${slug}: reason is ${entry.reason.trim().length} chars — too short to say ` +
        `WHY this choice does or does not deserve a preview`,
    );
  });
}

test("preview inventory: pinnable themes are exactly the descriptor's enum", () => {
  // A palette file that ships without joining the manifest enum cannot be
  // selected by any deploy, so a picker must not offer it as a preview axis.
  // Today design/themes/iris.json is in exactly that state, and the inventory
  // records it rather than papering over it. This reds the day the enum and the
  // directory move relative to each other.
  const pinnable = Object.keys(inventory.themes)
    .filter((n) => inventory.themes[n].pinnable === true)
    .sort();
  assert.deepEqual(
    pinnable,
    SCHEMA_THEME_ENUM,
    "the inventory's pinnable themes must equal the `theme` enum in " +
      "templates/barkpark.template.schema.json",
  );
  for (const name of Object.keys(inventory.themes)) {
    assert.ok(
      typeof inventory.themes[name].reason === "string" &&
        inventory.themes[name].reason.trim().length >= 40,
      `theme ${name}: reason is missing or too short`,
    );
  }
});

test("templates/MANIFEST.md documents the inventory by path", () => {
  // "A documented inventory" is only documented while the spec doc points at it.
  const src = readIfFile(path.join(TEMPLATES, "MANIFEST.md")) ?? "";
  assert.match(
    src,
    /design\/preview-inventory\.json/,
    "templates/MANIFEST.md must name design/preview-inventory.json — an inventory " +
      "no spec doc points at is not a documented one",
  );
});
