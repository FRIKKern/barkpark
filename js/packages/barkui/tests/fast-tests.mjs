// The fast test files: vitest.config.ts runs these, and the walk of every part count (tests/counts.mjs) runs the
// same list in each copy of the package. One list, so the two cannot drift.
export const FAST_TESTS = ['tests/**/*.test.mjs']
