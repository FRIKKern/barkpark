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
// This does NOT change CHANGELOG content. Every line is still produced by the
// configured `@changesets/changelog-github` calling the real `getInfo`; we only
// bound how many of those calls are in flight, which bounds the query size.

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

// changelog-github calls `getGithubInfo.getInfo(...)` as a property lookup at
// call time, so replacing the property is enough to gate it.
const realGetInfo = getGithubInfo.getInfo;
const realGetInfoFromPullRequest = getGithubInfo.getInfoFromPullRequest;
getGithubInfo.getInfo = (...args) => gate(() => realGetInfo(...args));
getGithubInfo.getInfoFromPullRequest = (...args) =>
  gate(() => realGetInfoFromPullRequest(...args));

// Required only AFTER the patch is installed.
const upstream = require("@changesets/changelog-github").default;

module.exports = {
  getReleaseLine: upstream.getReleaseLine,
  getDependencyReleaseLine: upstream.getDependencyReleaseLine,
};
