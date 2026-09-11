// Why this file exists.
//
// `@changesets/changelog-github` looks each changeset's commit up on GitHub's
// GraphQL API through `@changesets/get-github-info`, which uses a module-level
// DataLoader. DataLoader batches every `.load()` issued in one tick into a
// SINGLE GraphQL query, and changesets calls `getReleaseLine` for all pending
// changesets concurrently. With a large backlog that becomes one query with
// hundreds of `repository { object(expression: <sha>) { associatedPullRequests(first: 50) } }`
// aliases, and GitHub refuses to execute it.
//
// Measured against this repo (440 pending changesets, token valid for GraphQL):
//   N=1   rc 0
//   N=50  rc 0
//   N=100 rc 1 — {"message":"We couldn't respond to your request in time. ..."}
//   N=150 rc 1 — FetchError: invalid json response body ... Unexpected token '<', "<html>
//   N=440 rc 1 — same HTML error page
// i.e. GitHub's GraphQL server-side execution budget, degrading to an HTML 502
// page once it is exceeded badly enough. It is a TIME budget, not a fixed node
// count, so the boundary is not a hard number — hence the conservative cap.
//
// The fix is a concurrency gate, not a different generator: we delegate to the
// real `@changesets/changelog-github` for every line, so CHANGELOG content is
// byte-for-byte what the configured generator produces. We only bound how many
// of its calls are in flight at once, which bounds the DataLoader batch and so
// the size of each GraphQL query.

const upstream = require("@changesets/changelog-github");

const DEFAULT_MAX_CONCURRENT_LOOKUPS = 25;

function readCap() {
  const raw = process.env.CHANGESET_GITHUB_BATCH_SIZE;
  if (!raw) return DEFAULT_MAX_CONCURRENT_LOOKUPS;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(
      `CHANGESET_GITHUB_BATCH_SIZE must be a positive integer, got ${JSON.stringify(raw)}`
    );
  }
  return parsed;
}

function createGate(limit) {
  let active = 0;
  const waiting = [];

  const release = () => {
    active -= 1;
    const next = waiting.shift();
    if (next) next();
  };

  return async function run(fn) {
    if (active >= limit) {
      await new Promise((resolve) => waiting.push(resolve));
    }
    active += 1;
    try {
      return await fn();
    } finally {
      release();
    }
  };
}

const gate = createGate(readCap());

const getReleaseLine = (...args) => gate(() => upstream.default.getReleaseLine(...args));
const getDependencyReleaseLine = (...args) =>
  gate(() => upstream.default.getDependencyReleaseLine(...args));

module.exports = { getReleaseLine, getDependencyReleaseLine };
