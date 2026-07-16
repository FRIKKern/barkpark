// The real "server-only" package throws unless the "react-server" export
// condition is selected — only a bundler (Next.js webpack/turbopack) sets it,
// so any lib file starting with `import "server-only"` (bp-fetch.ts, find.ts,
// …) would abort under `node --test`. Short-circuit the specifier to an empty
// module here, in the test runner ONLY — the bundle-time guard on browser
// code is untouched.
export function resolve(specifier, context, nextResolve) {
  if (specifier === "server-only") {
    return { shortCircuit: true, url: "data:text/javascript," };
  }
  return nextResolve(specifier, context);
}
