// Module-resolution hooks for the dep-free `src/lib/**/*.test.ts` suite.
//
// `barkpark.ts` imports `createClient` and `BarkparkNotFoundError` from
// `@barkpark/core` as VALUES, so node cannot even build the module graph
// without an `npm ci` in this template. The CI job that runs these specs
// (search-template-gates.yml, `astro-starter-content-link`) is DELIBERATELY
// dependency-free — node 22's native type-stripping and nothing else — exactly
// like the search-starter's `finder-unit` job this mirrors.
//
// A test registers these hooks with `module.register()` and then dynamically
// imports the module under test. Only `@barkpark/core` is stubbed; every line
// of `barkpark.ts` — `resolveEnv`, `isScopedUrl`, `toFlagship`, the whole
// `fetchFlagshipDoc` try/catch and `flagshipMarkers` — runs as written.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === '@barkpark/core') {
    return {
      url: new URL('./__test-stub-barkpark-core.mjs', import.meta.url).href,
      shortCircuit: true,
    }
  }
  // Astro/TS resolve `./barkpark` extensionlessly; node ESM does not.
  if (specifier.startsWith('.') && !/\.[cm]?[jt]sx?$/.test(specifier)) {
    return nextResolve(specifier + '.ts', context)
  }
  return nextResolve(specifier, context)
}
