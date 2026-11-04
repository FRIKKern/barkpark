import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { BUNDLE_PATH } from "../../../design/paper-editor-mirror.mjs";
import { readCssSourceGraph } from "../paper-editor/src/__css_source_graph.mjs";
import { CODE_TOKENS_PROVENANCE } from "../paper-editor/src/code-tokens.provenance.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const digest = value => createHash("sha256").update(value).digest("hex");
const repoPath = path => relative(REPO, path).split(sep).join("/");
const graph = readCssSourceGraph();

assert.equal(CODE_TOKENS_PROVENANCE.source, "api/assets/paper-surface/code-tokens.css");
const canonical = readFileSync(resolve(REPO, CODE_TOKENS_PROVENANCE.source));
const consumedPath = resolve(REPO, "api/assets/paper-editor/src", CODE_TOKENS_PROVENANCE.consumer);
const consumed = readFileSync(consumedPath);
assert.equal(graph.shared, realpathSync(consumedPath), "the graph consumes the package-local token capsule");
assert.equal(consumed.toString("utf8"), canonical.toString("utf8"), "the package consumes the canonical token bytes");
assert.equal(graph.sharedCss, consumed.toString("utf8"));
assert.equal(digest(canonical), CODE_TOKENS_PROVENANCE.sha256, "the canonical token source matches provenance");

const markerStart = "/* BEGIN GENERATED: paper-surface";
const markerEnd = "/* END GENERATED: paper-surface */";
assert.equal(graph.authoredCss.split(markerStart).length - 1, 1, "one generated mirror start marker");
assert.equal(graph.authoredCss.split(markerEnd).length - 1, 1, "one generated mirror end marker");
assert.equal(graph.authoredFiles.filter(path => repoPath(path) === BUNDLE_PATH).length, 1,
  "BUNDLE_PATH is one reachable authored leaf");
const starts = graph.authoredFiles.filter(path => readFileSync(path, "utf8").includes(markerStart));
const ends = graph.authoredFiles.filter(path => readFileSync(path, "utf8").includes(markerEnd));
assert.deepEqual(starts.map(repoPath), [BUNDLE_PATH], "BUNDLE_PATH owns the generated start marker");
assert.deepEqual(ends.map(repoPath), [BUNDLE_PATH], "BUNDLE_PATH owns the generated end marker");

console.log("ok css source ownership: local capsule equals canonical source; BUNDLE_PATH owns one generated mirror");
