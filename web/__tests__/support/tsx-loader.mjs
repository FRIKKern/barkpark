/**
 * node:module loader hooks that let the golden-parity web leg import the REAL
 * reader render path (`components/portable-doc.tsx`) under `node --test` — no
 * browser, no bundler. Registered from the test via `module.register(...)`
 * BEFORE the dynamic `import()` of portable-doc, so only that graph is hooked;
 * the suite's own `.ts` imports keep using node's native type-stripping.
 *
 * Three jobs, all minimal and FAITHFUL to the code under test:
 *   1. Transpile `.ts`/`.tsx` through the bundled TypeScript compiler with the
 *      app's `jsx: react-jsx` setting (automatic runtime → `react/jsx-runtime`).
 *      This is the SAME JSX→DOM lowering Next/tsc applies; renderBlock's real
 *      JSX runs unchanged.
 *   2. Resolve the `@/*` path alias (tsconfig `paths`) to the web root, with
 *      `.ts`/`.tsx`/index probing, plus relative-specifier extension probing.
 *   3. Stub ONLY modules that are never on the component render path: the two
 *      client components (`sheet-grid`, `paper-editor-mount` — they render
 *      `sheet`/editor blocks, not any of the 12 component types) and the
 *      `@barkpark/core` HTTP client `papers.ts` imports for types. Stubbing
 *      these avoids `next/script` + the sheets subtree WITHOUT touching a single
 *      line of the render logic being asserted.
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import ts from "typescript";

const HERE = path.dirname(fileURLToPath(import.meta.url)); // web/__tests__/support
const WEB_ROOT = path.resolve(HERE, "..", ".."); // web/

/** Off-render-path modules replaced by inert stubs (see header, job 3). */
const STUB_SOURCE = {
  "stub:barkpark-core": "export function typedClient() { return {}; }\nexport default {};",
  "stub:next-script": "export default function Script() { return null; }",
  "stub:sheet-grid": "export function SheetSnapshot() { return null; }",
  "stub:paper-editor-mount": "export function PaperEditorMount() { return null; }",
};

const BARE_STUBS = {
  "@barkpark/core": "stub:barkpark-core",
  "next/script": "stub:next-script",
};

const ALIAS_STUBS = {
  "components/sheet-grid": "stub:sheet-grid",
  "components/paper-editor-mount": "stub:paper-editor-mount",
};

const EXTS = [".tsx", ".ts", ".jsx", ".js", ".mjs"];

/** Probe a base path for a concrete source file (exact, +ext, or /index+ext). */
function probe(base) {
  if (existsSync(base) && path.extname(base)) return base;
  for (const ext of EXTS) if (existsSync(base + ext)) return base + ext;
  for (const ext of EXTS) {
    const idx = path.join(base, "index" + ext);
    if (existsSync(idx)) return idx;
  }
  return null;
}

export async function resolve(specifier, context, nextResolve) {
  if (BARE_STUBS[specifier]) {
    return { url: BARE_STUBS[specifier], shortCircuit: true };
  }
  if (specifier.startsWith("@/")) {
    const rel = specifier.slice(2);
    if (ALIAS_STUBS[rel]) return { url: ALIAS_STUBS[rel], shortCircuit: true };
    const hit = probe(path.join(WEB_ROOT, rel));
    if (hit) return { url: pathToFileURL(hit).href, shortCircuit: true };
  }
  if (specifier.startsWith(".") && context.parentURL?.startsWith("file:")) {
    const base = path.resolve(
      path.dirname(fileURLToPath(context.parentURL)),
      specifier,
    );
    const hit = probe(base);
    if (hit) return { url: pathToFileURL(hit).href, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  if (url.startsWith("stub:")) {
    return { format: "module", source: STUB_SOURCE[url], shortCircuit: true };
  }
  if (url.startsWith("file:") && /\.(tsx|ts)$/.test(url)) {
    const filename = fileURLToPath(url);
    const { outputText } = ts.transpileModule(readFileSync(filename, "utf8"), {
      fileName: filename,
      compilerOptions: {
        module: ts.ModuleKind.ESNext,
        target: ts.ScriptTarget.ES2022,
        jsx: ts.JsxEmit.ReactJSX, // app's `jsx: react-jsx`
        esModuleInterop: true,
        verbatimModuleSyntax: false,
      },
    });
    return { format: "module", source: outputText, shortCircuit: true };
  }
  return nextLoad(url, context);
}
