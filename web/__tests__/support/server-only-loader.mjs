// The real "server-only" package throws unless the "react-server" export
// condition is selected — only a bundler (Next.js webpack/turbopack) sets it,
// so any lib file starting with `import "server-only"` (bp-fetch.ts, find.ts,
// …) would abort under `node --test`. Short-circuit the specifier to an empty
// module here, in the test runner ONLY — the bundle-time guard on browser
// code is untouched.
//
// Two further resolutions below are BUNDLER-ONLY — Next.js webpack/turbopack
// performs them at build time and plain node cannot, so a route handler
// (`app/api/**/route.ts`) is unimportable under `node --test` without them.
// Both are strictly ADDITIVE: they fire only on specifiers no existing test
// uses, and everything else still falls through to `nextResolve` untouched.

import { statSync } from "node:fs";
import { fileURLToPath } from "node:url";

// `web/` itself — this file lives at web/__tests__/support/.
const WEB_ROOT = new URL("../../", import.meta.url);

// tsconfig.json `paths: {"@/*": ["./*"]}`. Node never reads tsconfig, and the
// alias is written extensionless in source, so the extension must be restored.
const TS_EXTENSIONS = ["", ".ts", ".tsx", ".mts", ".js"];

/** A FILE, specifically — `@/lib` must not resolve to the lib/ directory. */
function isFile(url) {
  try {
    return statSync(fileURLToPath(url)).isFile();
  } catch {
    return false;
  }
}

function resolveAlias(specifier) {
  const relative = specifier.slice(2); // drop the leading "@/"
  for (const ext of TS_EXTENSIONS) {
    const candidate = new URL(`${relative}${ext}`, WEB_ROOT);
    if (isFile(candidate)) return candidate.href;
  }
  return undefined;
}

/** Restore the extension Next's bundler would have supplied. */
function resolveRelative(specifier, parentURL) {
  if (/\.[mc]?[jt]sx?$/.test(specifier)) return undefined; // already explicit
  for (const ext of TS_EXTENSIONS) {
    if (ext === "") continue; // node already tried the bare form
    const candidate = new URL(`${specifier}${ext}`, parentURL);
    if (isFile(candidate)) return candidate.href;
  }
  return undefined;
}

export function resolve(specifier, context, nextResolve) {
  if (specifier === "server-only") {
    return { shortCircuit: true, url: "data:text/javascript," };
  }
  // next's package.json carries NO `exports` map, so bare ESM resolution of the
  // extensionless subpath `next/server` fails outright. Point at the real file.
  if (specifier === "next/server") {
    return nextResolve("next/server.js", context);
  }
  // Same shape, same reason: `next/cache` is an extensionless subpath of a
  // package with no `exports` map, so `lib/get-document.ts` (which imports
  // `unstable_cache`) is unimportable under `node --test` without this. Also
  // strictly additive — no existing test resolves this specifier.
  if (specifier === "next/cache") {
    return nextResolve("next/cache.js", context);
  }
  if (specifier.startsWith("@/")) {
    const aliased = resolveAlias(specifier);
    if (aliased) return nextResolve(aliased, context);
  }
  // Extensionless RELATIVE specifiers (`./barkpark-client`, `../lib/x`). Next's
  // bundler restores the extension; node refuses. Same restoration the `@/`
  // alias above already performs, applied to the relative form, and equally
  // additive: a specifier that already carries an extension resolves through
  // `nextResolve` untouched, and a miss falls through to node's own error.
  if (specifier.startsWith(".") && context.parentURL) {
    const relative = resolveRelative(specifier, context.parentURL);
    if (relative) return nextResolve(relative, context);
  }
  return nextResolve(specifier, context);
}
