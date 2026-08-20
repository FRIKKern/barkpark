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

export function resolve(specifier, context, nextResolve) {
  if (specifier === "server-only") {
    return { shortCircuit: true, url: "data:text/javascript," };
  }
  // next's package.json carries NO `exports` map, so bare ESM resolution of the
  // extensionless subpath `next/server` fails outright. Point at the real file.
  if (specifier === "next/server") {
    return nextResolve("next/server.js", context);
  }
  if (specifier.startsWith("@/")) {
    const aliased = resolveAlias(specifier);
    if (aliased) return nextResolve(aliased, context);
  }
  return nextResolve(specifier, context);
}
