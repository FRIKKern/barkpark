import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cpSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CSS_AUTHORED_DIR, CSS_ROOT, CSS_SHARED_INPUT, readAuthoredCss, readCssSourceGraph } from "./__css_source_graph.mjs";
import { CODE_TOKENS_PROVENANCE } from "./code-tokens.provenance.mjs";

const SOURCE = dirname(fileURLToPath(import.meta.url));
const PKG = resolve(SOURCE, "..");
const sha256 = value => createHash("sha256").update(value).digest("hex");
const graph = readCssSourceGraph();
const productionCss = readdirSync(CSS_AUTHORED_DIR, { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith(".css"))
  .map(entry => realpathSync(join(entry.parentPath, entry.name)))
  .sort();

assert.equal(graph.root, realpathSync(CSS_ROOT));
assert.equal(graph.shared, realpathSync(CSS_SHARED_INPUT));
assert.deepEqual([...graph.authoredFiles].sort(), productionCss, "every authored CSS file is reachable exactly once");
assert.ok(graph.authoredFiles.length > 0, "the authored graph is non-vacuous");
for (const file of graph.authoredFiles) {
  const lines = readFileSync(file, "utf8").split("\n").length - 1;
  assert.ok(lines <= 800, `${relative(PKG, file)} has ${lines} physical lines (max 800)`);
}
assert.equal(graph.authoredCss, graph.authoredFiles.map(path => readFileSync(path, "utf8")).join(""),
  "the authored view is the ordered byte concatenation of every authored leaf");
assert.equal(graph.buildCss, graph.sharedCss + graph.authoredCss, "the full view is shared first, then authored bytes");
assert.deepEqual(Object.keys(CODE_TOKENS_PROVENANCE).sort(), ["consumer", "schemaVersion", "sha256", "source"]);
assert.equal(Object.isFrozen(CODE_TOKENS_PROVENANCE), true);
assert.equal(CODE_TOKENS_PROVENANCE.schemaVersion, 1);
assert.equal(CODE_TOKENS_PROVENANCE.consumer, "code-tokens.css");
assert.equal(CODE_TOKENS_PROVENANCE.source, "api/assets/paper-surface/code-tokens.css");
assert.match(CODE_TOKENS_PROVENANCE.sha256, /^[0-9a-f]{64}$/);
assert.equal(sha256(readFileSync(CSS_SHARED_INPUT)), CODE_TOKENS_PROVENANCE.sha256);
assert.equal(readAuthoredCss(), graph.authoredCss, "the default authored reader uses the production graph");
assert.throws(() => readCssSourceGraph({ extra: CSS_ROOT }), /unknown option/);
assert.throws(() => readCssSourceGraph(null), /options must be an object/);

const fixture = mkdtempSync(join(tmpdir(), "pd-css-source-graph-"));
try {
  const source = join(fixture, "src");
  const styles = join(source, "styles");
  const shared = join(fixture, "shared.css");
  mkdirSync(styles, { recursive: true });
  writeFileSync(shared, ":root { --shared: 1; }\n");
  writeFileSync(join(styles, "a.css"), ".a { color: red; }\n");
  writeFileSync(join(styles, "b.css"), ".b { color: blue; }\n");
  const root = join(source, "styles.css");
  const rootText = (imports = ['@import "../shared.css";', '@import "./styles/a.css";', '@import "./styles/b.css";']) =>
    `${imports.join("\n")}\n`;
  writeFileSync(root, rootText());
  const read = () => readCssSourceGraph({ rootPath: root, authoredDir: styles, sharedPath: shared });
  assert.equal(read().authoredCss, ".a { color: red; }\n.b { color: blue; }\n");

  const rejects = (message, mutate) => {
    const before = new Map([[root, readFileSync(root)], [join(styles, "a.css"), readFileSync(join(styles, "a.css"))], [join(styles, "b.css"), readFileSync(join(styles, "b.css"))]]);
    try { mutate(); assert.throws(read, message); }
    finally { for (const [path, bytes] of before) writeFileSync(path, bytes); }
  };
  rejects(/missing/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/missing.css";'])));
  rejects(/duplicate canonical target/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/a.css";', '@import "./styles/\.\/a.css";'])));
  rejects(/qualified @import/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/a.css" screen;'])));
  rejects(/unsupported @import syntax|root stylesheet must contain imports and comments only/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import url("./styles/a.css");'])));
  rejects(/unsupported @import syntax/, () => {
    writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/a.css";']));
    writeFileSync(join(styles, "a.css"), '@import "./b.css";\n@import url("https://example.invalid/remote.css");\n.a{}\n');
  });
  rejects(/non-local @import/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import "https://example.invalid/a.css";'])));
  rejects(/root stylesheet must contain imports and comments only/, () => writeFileSync(root, `${rootText()}body { color: red; }\n`));
  rejects(/first root import must be the shared stylesheet/, () => writeFileSync(root, rootText(['@import "./styles/a.css";', '@import "../shared.css";'])));
  rejects(/shared stylesheet imported more than once/, () => writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/a.css";', '@import "../shared.css";'])));
  rejects(/cycle/, () => writeFileSync(join(styles, "a.css"), '@import "./b.css";\n.a{}\n') || writeFileSync(join(styles, "b.css"), '@import "./a.css";\n.b{}\n'));
  rejects(/late @import/, () => writeFileSync(join(styles, "a.css"), '.a{}\n@import "./b.css";\n'));
  rejects(/authored import escapes/, () => writeFileSync(join(styles, "a.css"), '@import "../../outside.css";\n') || writeFileSync(join(fixture, "outside.css"), ".outside{}\n"));
  const orphan = join(styles, "orphan.css");
  writeFileSync(orphan, ".orphan{}\n");
  assert.throws(read, /orphan authored stylesheet/);
  rmSync(orphan);
  const escape = join(fixture, "escape.css");
  writeFileSync(escape, ".escape{}\n");
  const link = join(styles, "link.css");
  symlinkSync(escape, link);
  writeFileSync(root, rootText(['@import "../shared.css";', '@import "./styles/link.css";']));
  assert.throws(() => readCssSourceGraph({ rootPath: root, authoredDir: styles, sharedPath: shared }), /authored import escapes|orphan/);
} finally {
  rmSync(fixture, { recursive: true, force: true });
}

async function productionRejects(name, expected, mutate, invoke = module => module.readCssSourceGraph()) {
  const scratch = mkdtempSync(join(tmpdir(), `pd-css-production-${name}-`));
  try {
    const source = join(scratch, "api/assets/paper-editor/src");
    const canonical = join(scratch, "api/assets/paper-surface/code-tokens.css");
    mkdirSync(source, { recursive: true });
    mkdirSync(dirname(canonical), { recursive: true });
    for (const file of ["__css_source_graph.mjs", "code-tokens.provenance.mjs", "styles.css", "code-tokens.css"])
      cpSync(join(SOURCE, file), join(source, file));
    cpSync(join(SOURCE, "styles"), join(source, "styles"), { recursive: true });
    cpSync(join(SOURCE, "code-tokens.css"), canonical);
    const paths = { scratch, source, canonical, root: join(source, "styles.css"), shared: join(source, "code-tokens.css") };
    await mutate(paths);
    const module = await import(`${pathToFileURL(join(source, "__css_source_graph.mjs"))}?case=${name}`);
    await assert.rejects(async () => invoke(module, paths), expected);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

await productionRejects("capsule-digest", /digest/, ({ shared }) => writeFileSync(shared, `${readFileSync(shared, "utf8")} `));
await productionRejects("provenance-digest", /digest/, ({ source }) => {
  const file = join(source, "code-tokens.provenance.mjs");
  writeFileSync(file, readFileSync(file, "utf8").replace(CODE_TOKENS_PROVENANCE.sha256, "0".repeat(64)));
});
await productionRejects("external-root-import", /first root import/, ({ root }) => {
  writeFileSync(root, readFileSync(root, "utf8").replace('@import "./code-tokens.css";', '@import "../../paper-surface/code-tokens.css";'));
});
await productionRejects("shared-symlink", /regular physical file|symlink/, ({ shared, canonical }) => {
  rmSync(shared); symlinkSync(canonical, shared);
});
await productionRejects("root-symlink", /regular physical file|symlink/, ({ root }) => {
  const target = `${root}.physical`; cpSync(root, target); rmSync(root); symlinkSync(target, root);
});
await productionRejects("partial-override", /all three/, () => {}, (module, paths) => module.readCssSourceGraph({ sharedPath: paths.canonical }));
await productionRejects("mixed-production", /outside production|production path/, () => {}, (module, paths) => module.readCssSourceGraph({
  rootPath: module.CSS_ROOT, authoredDir: join(paths.source, "styles"), sharedPath: paths.canonical,
}));
await productionRejects("explicit-production", /outside production|production path/, () => {}, module => module.readCssSourceGraph({
  rootPath: module.CSS_ROOT, authoredDir: module.CSS_AUTHORED_DIR, sharedPath: module.CSS_SHARED_INPUT,
}));

console.log(`styles source graph: ${graph.authoredFiles.length} authored file(s), ${Buffer.byteLength(graph.authoredCss)} authored bytes, shared first`);
