// A dep-free stand-in for the sliver of `@barkpark/core` that `barkpark.ts`
// imports as VALUES. See `__test-stub-hooks.mjs` for why the bare specifier
// cannot resolve in the dependency-free CI job.
//
// `BarkparkNotFoundError` is the shape core throws on a 404:
// `BarkparkNotFoundError extends BarkparkAPIError extends BarkparkError`
// (js/packages/core/src/errors.ts:146). `fetchFlagshipDoc` branches on
// `instanceof` — the SAME class object the template imports, because the hook
// short-circuits every `@barkpark/core` specifier to this one module — so the
// branch under test is the real one, not a string comparison standing in.
export class BarkparkError extends Error {}
export class BarkparkAPIError extends BarkparkError {
  constructor(message, opts) {
    super(message)
    this.name = 'BarkparkAPIError'
    this.code = 'BarkparkAPIError'
    this.status = opts?.status
    if (opts?.serverCode !== undefined) this.serverCode = opts.serverCode
  }
}
export class BarkparkNotFoundError extends BarkparkAPIError {
  constructor(message, opts) {
    super(message, { status: 404, ...opts })
    this.name = 'BarkparkNotFoundError'
    this.code = 'BarkparkNotFoundError'
  }
}

// `createBarkparkClient` is exercised for its CONFIG SHAPE only (the
// scoped-vs-unscoped `projectUrl` decision), so the stub records what it was
// handed and returns it. The real client's transport is out of scope here —
// `fetchFlagshipDoc` takes the client as a parameter precisely so a test can
// hand it a double.
export function createClient(config) {
  return { __config: config }
}
