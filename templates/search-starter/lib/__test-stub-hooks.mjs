// Module-resolution hooks for the dep-free `lib/**/*.test.ts` suite.
//
// `bp-fetch.ts` is a server module: it imports `server-only` and `undici`. The
// CI job that runs these specs (search-starter-smoke.yml `finder-unit`) is
// DELIBERATELY dependency-free — no `npm ci`, node 22's native type-stripping
// and nothing else — so importing bp-fetch.ts there would die on module
// resolution before a single assertion ran.
//
// `doc-absence.ts` is in the same position for a different dependency: it
// imports `isBarkparkError` from `@barkpark/core`, which ships as a `file:`
// vendor tarball and so is equally unresolvable without an install.
//
// A test registers these hooks with `module.register()` and then dynamically
// imports the module under test. `server-only` becomes an empty module (its
// only job in a real build is to make a client import fail at BUILD time),
// `@barkpark/core` becomes a four-line port of its `isBarkparkError` plus the
// error class, and `undici` becomes the stub below, whose `fetch` the test
// drives directly. The rest of the module under test — bp-fetch.ts's retry
// ladder, `res.ok` guard, envelope decode and throw; doc-absence.ts's entire
// ruling — runs as written, unstubbed.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "server-only") {
    return { url: "data:text/javascript,export{}", shortCircuit: true };
  }
  if (specifier === "@barkpark/core") {
    return {
      url: new URL("./__test-stub-barkpark-core.mjs", import.meta.url).href,
      shortCircuit: true,
    };
  }
  if (specifier === "undici") {
    return {
      url: new URL("./__test-stub-undici.mjs", import.meta.url).href,
      shortCircuit: true,
    };
  }
  // Next/TS resolve `./bp-env` extensionlessly; node ESM does not. Re-point a
  // relative specifier that has no extension at its `.ts` sibling so the module
  // graph under test is the SHIPPED one, not a rewritten copy.
  if (specifier.startsWith(".") && !/\.[cm]?[jt]sx?$/.test(specifier)) {
    return nextResolve(specifier + ".ts", context);
  }
  return nextResolve(specifier, context);
}
