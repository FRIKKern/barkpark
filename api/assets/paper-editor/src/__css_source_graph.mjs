import { existsSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE_ROOT = dirname(fileURLToPath(import.meta.url));
export const CSS_ROOT = resolve(SOURCE_ROOT, "styles.css");
export const CSS_AUTHORED_DIR = resolve(SOURCE_ROOT, "styles");
export const CSS_SHARED_INPUT = resolve(SOURCE_ROOT, "../../paper-surface/code-tokens.css");

const IMPORT = /@import\s+(["'])([^"']+)\1([^;]*);/g;

const stripComments = value => value.replace(/\/\*[\s\S]*?\*\//g, "");

const inside = (path, directory) => {
  const rel = relative(directory, path);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
};

const canonical = (path, label) => {
  if (!existsSync(path)) throw new Error(`css source graph: missing ${label}: ${path}`);
  const real = realpathSync(path);
  if (!statSync(real).isFile() && label !== "authored directory")
    throw new Error(`css source graph: ${label} is not a file: ${path}`);
  return real;
};

function parseImports(path, source) {
  const imports = [];
  let cursor = 0;
  for (const match of source.matchAll(IMPORT)) {
    const before = source.slice(cursor, match.index);
    if (stripComments(before).trim())
      throw new Error(`css source graph: late @import in ${path}`);
    const specifier = match[2];
    const qualifier = match[3].trim();
    if (qualifier)
      throw new Error(`css source graph: qualified @import in ${path}: ${match[0]}`);
    if (!specifier.startsWith(".") || specifier.includes("?") || specifier.includes("#"))
      throw new Error(`css source graph: non-local @import in ${path}: ${specifier}`);
    imports.push({ specifier, start: match.index, end: match.index + match[0].length });
    cursor = match.index + match[0].length;
  }
  const body = imports.reduceRight((text, item) => text.slice(0, item.start) + text.slice(item.end), source);
  if (/@import\b/i.test(stripComments(body)))
    throw new Error(`css source graph: unsupported @import syntax in ${path}`);
  return { imports, body };
}

export function readCssSourceGraph({
  rootPath = CSS_ROOT,
  authoredDir = CSS_AUTHORED_DIR,
  sharedPath = CSS_SHARED_INPUT,
} = {}) {
  const root = canonical(rootPath, "root stylesheet");
  const authored = realpathSync(authoredDir);
  if (!statSync(authored).isDirectory())
    throw new Error(`css source graph: authored directory is not a directory: ${authoredDir}`);
  const shared = canonical(sharedPath, "shared stylesheet");
  const seen = new Map();
  const active = new Set();
  const authoredFiles = [];
  const authoredChunks = [];

  function visit(path, importer) {
    const real = canonical(path, `import from ${importer}`);
    if (active.has(real)) throw new Error(`css source graph: cycle at ${real}`);
    if (seen.has(real))
      throw new Error(`css source graph: duplicate canonical target ${real} imported from ${importer}; first imported from ${seen.get(real)}`);
    if (!inside(real, authored))
      throw new Error(`css source graph: authored import escapes ${authored}: ${real}`);
    seen.set(real, importer);
    active.add(real);
    const source = readFileSync(real, "utf8");
    const parsed = parseImports(real, source);
    for (const item of parsed.imports) {
      const target = resolve(dirname(real), item.specifier);
      const resolved = canonical(target, `import ${item.specifier} from ${real}`);
      if (resolved === shared)
        throw new Error(`css source graph: shared stylesheet may only be the first root import: ${real}`);
      visit(resolved, real);
    }
    active.delete(real);
    authoredFiles.push(real);
    authoredChunks.push(parsed.body);
  }

  const rootSource = readFileSync(root, "utf8");
  const rootParsed = parseImports(root, rootSource);
  if (stripComments(rootParsed.body).trim())
    throw new Error(`css source graph: root stylesheet must contain imports and comments only: ${root}`);
  if (rootParsed.imports.length < 2)
    throw new Error(`css source graph: root must import the shared stylesheet first and at least one authored stylesheet`);

  rootParsed.imports.forEach((item, index) => {
    const target = resolve(dirname(root), item.specifier);
    const resolved = canonical(target, `root import ${item.specifier}`);
    if (index === 0) {
      if (resolved !== shared)
        throw new Error(`css source graph: first root import must be the shared stylesheet: ${shared}`);
      return;
    }
    if (resolved === shared)
      throw new Error(`css source graph: shared stylesheet imported more than once`);
    visit(resolved, root);
  });

  const authoredOnDisk = readdirSync(authored, { recursive: true, withFileTypes: true })
    .filter(entry => (entry.isFile() || entry.isSymbolicLink()) && entry.name.endsWith(".css"))
    .map(entry => canonical(resolve(entry.parentPath, entry.name), "authored stylesheet"));
  for (const path of authoredOnDisk) {
    if (!inside(path, authored))
      throw new Error(`css source graph: authored stylesheet escapes ${authored}: ${path}`);
    if (!seen.has(path))
      throw new Error(`css source graph: orphan authored stylesheet is not reachable from ${root}: ${path}`);
  }
  if (authoredOnDisk.length !== seen.size)
    throw new Error(`css source graph: authored file census disagrees with the import graph`);

  const authoredCss = authoredChunks.join("");
  const sharedCss = readFileSync(shared, "utf8");
  return {
    root,
    shared,
    authoredDir: authored,
    authoredFiles,
    authoredCss,
    sharedCss,
    buildCss: sharedCss + authoredCss,
  };
}

export const readAuthoredCss = options => readCssSourceGraph(options).authoredCss;
