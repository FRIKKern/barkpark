import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { BUNDLE_PATH } from "../../../../design/paper-editor-mirror.mjs";
import { CSS_AUTHORED_DIR, CSS_ROOT, CSS_SHARED_INPUT, readCssSourceGraph } from "./__css_source_graph.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const graph = readCssSourceGraph();
const relativeAuthored = graph.authoredFiles.map(path => relative(REPO, path).split(sep).join("/"));
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
  assert.ok(lines <= 800, `${relative(REPO, file)} has ${lines} physical lines (max 800)`);
}
assert.equal(graph.authoredCss, graph.authoredFiles.map(path => readFileSync(path, "utf8")).join(""),
  "the authored view is the ordered byte concatenation of every authored leaf");
assert.equal(graph.buildCss, graph.sharedCss + graph.authoredCss, "the full view is shared first, then authored bytes");

const markerStart = "/* BEGIN GENERATED: paper-surface";
const markerEnd = "/* END GENERATED: paper-surface */";
assert.equal(graph.authoredCss.split(markerStart).length - 1, 1, "one generated mirror start marker");
assert.equal(graph.authoredCss.split(markerEnd).length - 1, 1, "one generated mirror end marker");
assert.equal(relativeAuthored.filter(path => path === BUNDLE_PATH).length, 1, "BUNDLE_PATH is one reachable authored leaf");
const markerFile = graph.authoredFiles.find(path => readFileSync(path, "utf8").includes(markerStart));
assert.equal(relative(REPO, markerFile).split(sep).join("/"), BUNDLE_PATH, "BUNDLE_PATH owns the generated marker");

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

console.log(`styles source graph: ${graph.authoredFiles.length} authored file(s), ${Buffer.byteLength(graph.authoredCss)} authored bytes, shared first`);
