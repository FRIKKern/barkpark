// Module-resolution hooks for the dep-free `lib/**/*.test.ts` suite.
//
// `bp-fetch.ts` is a server module: it imports `server-only` and `undici`. The
// CI job that runs these specs (search-starter-smoke.yml `finder-unit`) is
// DELIBERATELY dependency-free — no `npm ci`, node 22's native type-stripping
// and nothing else — so importing bp-fetch.ts there would die on module
// resolution before a single assertion ran.
//
// A test registers these hooks with `module.register()` and then dynamically
// imports the module under test. `server-only` becomes an empty module (its
// only job in a real build is to make a client import fail at BUILD time) and
// `undici` becomes the stub below, whose `fetch` the test drives directly. The
// rest of bp-fetch.ts — the retry ladder, the `res.ok` guard, the envelope
// decode, the throw — runs as written, unstubbed.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "server-only") {
    return { url: "data:text/javascript,export{}", shortCircuit: true };
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
