// Stand-in for `undici` under the dep-free test suite (see __test-stub-hooks.mjs).
//
// `Agent` only has to be constructible — bp-fetch.ts builds one at module load
// and passes it through as `dispatcher`, which this `fetch` ignores.
// `setFetch()` lets a test install the response (or rejection) the module under
// test will see, so a spec drives the real error path without a network.
export class Agent {
  constructor(opts) {
    this.opts = opts;
  }
}

let impl = async () => {
  throw new Error("undici stub: no fetch installed — call setFetch() first");
};

/** Install the fetch the module under test will call. */
export function setFetch(next) {
  impl = next;
}

export const fetch = (...args) => impl(...args);
