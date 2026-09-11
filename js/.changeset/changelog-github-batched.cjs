// Why this file exists.
//
// `@changesets/changelog-github` resolves each changeset's commit through
// `@changesets/get-github-info`, which uses ONE module-level DataLoader.
// DataLoader collapses every `.load()` issued in the same tick into a SINGLE
// GraphQL query, and changesets asks for all pending release lines at once. With
// a large backlog that becomes one query carrying an alias per changeset, each
// with `associatedPullRequests(first: 50)`, and GitHub refuses to execute it.
//
// Measured against this repo (440 pending changesets, token valid for GraphQL):
//   N=1   rc 0
//   N=50  rc 0  (8s)
//   N=100 rc 1  {"message":"We couldn't respond to your request in time. ..."}
//   N=150 rc 1  FetchError: invalid json response body ... Unexpected token '<', "<html>
//   N=440 rc 1  same HTML error page
// So it is GitHub's server-side execution budget, degrading to an HTML 502 page
// once exceeded badly enough. That budget is TIME, not a fixed node count, so
// the boundary is not a hard number — hence a conservative cap.
//
// The gate has to sit on `getInfo`, not on the generator's two exported
// functions. `getDependencyReleaseLine` takes an ARRAY of changesets and does
// `Promise.all(changesets.map(...))` internally, so a single call to it fans out
// to as many lookups as there are changesets: gating the outer function still
// let a batch of 265 through (measured with a probe on the DataLoader). Gating
// `getInfo` bounds every load regardless of which generator function issued it.
//
// Bounding the batch turns one huge request into ~47 sequential ones, which
// exposes a second, independent failure: there is no retry anywhere in this
// stack, so ONE transient GitHub 5xx aborts the whole `changeset version`. Seen
// in a clean run that had already survived the batch problem:
//   FetchError: invalid json response body ... Unexpected token 'u', "upstream c"...
// (an edge "upstream connect error" page). So `getInfo` is also retried with
// backoff, and only for transport-shaped failures — a GraphQL `errors` payload
// or a bad token still fails immediately rather than being hammered.
//
// This does NOT change CHANGELOG content. Every line is still produced by the
// configured `@changesets/changelog-github` calling the real `getInfo`; we only
// bound how many of those calls are in flight, which bounds the query size, and
// retry the ones that fail for transport reasons.

const path = require("path");

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

  return async function run(fn) {
    if (active >= limit) {
      await new Promise((resolve) => waiting.push(resolve));
    }
    active += 1;
    try {
      return await fn();
    } finally {
      active -= 1;
      const next = waiting.shift();
      if (next) next();
    }
  };
}

const DEFAULT_MAX_ATTEMPTS = 5;

function readAttempts() {
  const raw = process.env.CHANGESET_GITHUB_MAX_ATTEMPTS;
  if (!raw) return DEFAULT_MAX_ATTEMPTS;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(
      `CHANGESET_GITHUB_MAX_ATTEMPTS must be a positive integer, got ${JSON.stringify(raw)}`
    );
  }
  return parsed;
}

// Transport-shaped: the response was not JSON at all (an HTML 502, an
// "upstream connect error" page), or GitHub said it ran out of time. A GraphQL
// `errors` payload, a bad token, or a bad repo name is NOT retried.
function isTransient(error) {
  if (!error) return false;
  if (error.type === "invalid-json") return true;
  if (error.name === "FetchError") return true;
  const message = typeof error.message === "string" ? error.message : "";
  return message.includes("We couldn't respond to your request in time");
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function withRetry(fn, maxAttempts) {
  let lastError;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt === maxAttempts || !isTransient(error)) throw error;
      const delayMs = 500 * 2 ** (attempt - 1);
      process.stderr.write(
        `changelog-github-batched: transient GitHub failure (${error.message.split("\n")[0]}); ` +
          `retrying in ${delayMs}ms (attempt ${attempt + 1}/${maxAttempts})\n`
      );
      await sleep(delayMs);
    }
  }
  throw lastError;
}

// `@changesets/get-github-info` is a transitive dependency (changelog-github
// depends on it, this workspace does not), so under pnpm's strict layout it is
// not resolvable from `.changeset/`. Resolve it from changelog-github's own
// directory to be sure we patch the SAME module instance changelog-github uses.
const changelogGithubEntry = require.resolve("@changesets/changelog-github");
const getGithubInfoPath = require.resolve("@changesets/get-github-info", {
  paths: [path.dirname(changelogGithubEntry)],
});
const getGithubInfo = require(getGithubInfoPath);

const gate = createGate(readCap());
const maxAttempts = readAttempts();

// changelog-github calls `getGithubInfo.getInfo(...)` as a property lookup at
// call time, so replacing the property is enough to gate it.
const realGetInfo = getGithubInfo.getInfo;
const realGetInfoFromPullRequest = getGithubInfo.getInfoFromPullRequest;
getGithubInfo.getInfo = (...args) =>
  gate(() => withRetry(() => realGetInfo(...args), maxAttempts));
getGithubInfo.getInfoFromPullRequest = (...args) =>
  gate(() => withRetry(() => realGetInfoFromPullRequest(...args), maxAttempts));

// Required only AFTER the patch is installed.
const upstream = require("@changesets/changelog-github").default;

module.exports = {
  getReleaseLine: upstream.getReleaseLine,
  getDependencyReleaseLine: upstream.getDependencyReleaseLine,
};
